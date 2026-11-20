defmodule Veridian.Store.InputSeries do
  @moduledoc """
  A logical input whose value changes over time (spec 01 `InputSeries`), for
  example "trade IRS-000042" or "EUR ESTR OIS par quotes". What its content means
  is given only by `schema_ref`, a schema generated from Julia types (D-018).

  The series row is the serialisation point for recording its versions: a
  writer takes it `FOR UPDATE` before checking for overlaps (D-082).

  Not yet here: who created it (`created_by`), until identities exist (spec 04).
  """
  use Ash.Resource,
    domain: Veridian.Store,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "input_series"
    repo Veridian.Repo

    check_constraints do
      check_constraint :data_class, "data_class_known",
        check: "data_class IN ('production', 'golden', 'synthetic', 'test', 'whatif', 'impact')",
        message: "unknown data class"
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :schema_ref, :string, allow_nil?: false, public?: true

    attribute :data_class, :atom,
      constraints: [one_of: [:production, :golden, :synthetic, :test, :whatif, :impact]],
      allow_nil?: false,
      public?: true

    attribute :created_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  identities do
    # RegisterInputSeries requires that no series has the key.
    identity :unique_key, [:key]
  end

  actions do
    defaults [:read, create: :*]
  end
end
