defmodule Veridian.SchemaModelTraceTest do
  @moduledoc """
  The ledger's schema, the Ash resources and the Quint model say the same thing
  (D-080). Ash owns the schema: every database check constraint is declared in
  a resource and the migration is generated from the resources. This test ties
  each constraint to what it enforces:

    * a property of `models/calc_graph.qnt` (a `val` that is part of `safety`),
    * a type of the model (the allowed values must be the type's variants, less
      the model's "none" variant), or
    * the identifier code (`Veridian.Id`, D-041), for what the model abstracts.

  It fails when a constraint is added without saying what it enforces, when a
  mapping names something the model does not have, when the allowed values
  drift from the model's type, or when the database lacks a declared constraint.
  (That model states fit the constraints at all is shown by the trace replays,
  which write every model state into the database.)
  """
  use Veridian.DataCase, async: false

  alias Veridian.Store.{InputSeries, InputVersion, Node, Request, Step}

  @model Path.expand("../../../models/calc_graph.qnt", __DIR__)
  @specs Path.expand("../../../specs", __DIR__)
  @spec01 "01-bitemporal-data"

  # {resource, constraint} => what it enforces.
  @mapping %{
    {Request, "status_known"} => {:model_type, "ReqSt", :status},
    {Step, "status_known"} => {:model_type, "StepSt", :status},
    {Step, "node_is_whole"} => {:code, Veridian.Id},
    {Node, "digest_is_32_bytes"} => {:code, Veridian.Id},
    {Node, "status_known"} => {:model_type, "NodeSt", :status},
    {Node, "tier_known"} => {:model_type, "Tier", :tier},
    {Node, "result_iff_complete"} => {:model_val, "resultIffComplete"},
    {Node, "complete_is_whole"} => {:model_val, "resultIffComplete"},
    {Node, "counters_not_negative"} => {:model_val, "countersNotNegative"},
    # Spec 01 has no Quint model (no concurrent protocol): its constraints are
    # tied to the Allium spec itself (D-082).
    {InputSeries, "data_class_known"} => {:spec_enum, @spec01, "DataClass", :data_class},
    {InputVersion, "content_digest_is_32_bytes"} => {:code, Veridian.Id},
    {InputVersion, "status_known"} => {:spec_field, @spec01, "InputVersion", "status", :status},
    {InputVersion, "origin_known"} => {:spec_enum, @spec01, "VersionOrigin", :origin},
    {InputVersion, "effective_range_ordered"} => {:spec, @spec01, "EffectiveRangeOrdered"},
    {InputVersion, "only_corrections_await_approval"} =>
      {:spec, @spec01, "OnlyCorrectionsAwaitApproval"},
    {InputVersion, "recorded_iff_authoritative"} =>
      {:spec_text, @spec01, "recorded_at: Timestamp when status = active | superseded"},
    {InputVersion, "superseded_iff_superseded"} =>
      {:spec_text, @spec01, "superseded_at: Timestamp when status = superseded"}
  }

  # Keys that are model properties too: one node per calc_id is the primary key.
  @keys %{{Node, :calc_digest} => {:model_val, "oneNodePerCalcId"}}

  @resources [Request, Step, Node, InputSeries, InputVersion]

  defp declared do
    for r <- @resources,
        c <- AshPostgres.DataLayer.Info.check_constraints(r),
        into: MapSet.new() do
      {r, c.name}
    end
  end

  defp model_source, do: File.read!(@model)

  defp safety_block do
    [_, block] = Regex.run(~r/val safety = and \{(.*?)\}/s, model_source())
    block
  end

  # The variants of `type Name = | A | B | ...`, lower-cased, without the
  # model's "none" variant (NoNode, NoStep, ...).
  defp model_variants(type) do
    [_, body] = Regex.run(~r/type #{type} = ([^\n]+)/, model_source())

    body
    |> String.split("|", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(&1, "No"))
    |> Enum.map(&Macro.underscore/1)
    |> MapSet.new()
  end

  defp allowed_values(resource, attribute) do
    resource
    |> Ash.Resource.Info.attribute(attribute)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
    |> Enum.map(&Atom.to_string/1)
    |> MapSet.new()
  end

  test "every database constraint says what it enforces, and nothing else is mapped" do
    assert declared() == MapSet.new(Map.keys(@mapping))
  end

  test "every model property named exists and is part of the model's safety" do
    for {_, {:model_val, name}} <- Map.to_list(@mapping) ++ Map.to_list(@keys) do
      assert model_source() =~ ~r/val #{name} =/, "calc_graph.qnt has no val #{name}"
      assert safety_block() =~ name, "#{name} is not part of calc_graph.qnt safety"
    end
  end

  test "the values a status or tier may take are exactly the model type's" do
    for {{resource, _}, {:model_type, type, attribute}} <- @mapping do
      assert allowed_values(resource, attribute) == model_variants(type),
             "#{inspect(resource)}.#{attribute} differs from calc_graph #{type}"
    end
  end

  defp spec_source(spec), do: File.read!(Path.join(@specs, spec <> ".allium"))

  defp literals(text) do
    text
    |> String.split("|", trim: true)
    |> Enum.map(&String.trim/1)
    |> MapSet.new()
  end

  # The literals of `enum Name { a | b | c }`.
  defp spec_enum(spec, name) do
    [_, body] = Regex.run(~r/enum #{name} \{([^}]*)\}/, spec_source(spec))
    literals(body)
  end

  # The literals of an inline enum field `field: a | b | c` inside `entity Name { ... }`.
  defp spec_field(spec, entity, field) do
    [_, block] = Regex.run(~r/entity #{entity} \{(.*?)\n\}/s, spec_source(spec))
    [_, body] = Regex.run(~r/\n\s+#{field}: ([a-z_ |]+)\n/, block)
    literals(body)
  end

  test "every spec construct or text named exists in the Allium spec" do
    for {_, target} <- @mapping do
      case target do
        {:spec, spec, construct} ->
          assert spec_source(spec) =~ ~r/(invariant|rule|@invariant)\s+#{construct}\b/,
                 "#{spec}.allium has no #{construct}"

        {:spec_text, spec, text} ->
          assert String.contains?(spec_source(spec), text), "#{spec}.allium lacks: #{text}"

        _ ->
          :ok
      end
    end
  end

  test "the values an enum column may take are exactly the spec's" do
    for {{resource, _}, target} <- @mapping do
      case target do
        {:spec_enum, spec, name, attribute} ->
          assert allowed_values(resource, attribute) == spec_enum(spec, name),
                 "#{inspect(resource)}.#{attribute} differs from #{spec} enum #{name}"

        {:spec_field, spec, entity, field, attribute} ->
          assert allowed_values(resource, attribute) == spec_field(spec, entity, field),
                 "#{inspect(resource)}.#{attribute} differs from #{spec} #{entity}.#{field}"

        _ ->
          :ok
      end
    end
  end

  test "the node's primary key is its calc_id digest" do
    assert Ash.Resource.Info.primary_key(Node) == [:calc_digest]
  end

  test "the database has exactly the declared constraints" do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Veridian.Repo,
        """
        SELECT t.relname, c.conname FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE c.contype = 'c' AND t.relname IN
          ('ledger_requests', 'ledger_steps', 'ledger_nodes', 'input_series', 'input_versions')
        """,
        []
      )

    in_db = MapSet.new(rows, fn [table, name] -> {table, name} end)

    expected =
      MapSet.new(declared(), fn {r, name} -> {AshPostgres.DataLayer.Info.table(r), name} end)

    assert in_db == expected
  end
end
