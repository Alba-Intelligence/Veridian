defmodule Veridian.Inputs do
  @moduledoc """
  Bitemporal input versions (spec 01, D-082): registering a series, recording a
  version, and point-in-time resolution.

  A version's content is a typed `content` identifier computed by the Julia
  canonical form (D-081); this module records it and never computes one.

  ## Times

    * effective period `[effective_from, effective_to)`: half-open, a null end
      is open-ended;
    * `recorded_at`: when the version became authoritative knowledge;
    * `superseded_at`: when it stopped being so.

  Resolution uses only these times, never the current time or status alone, so
  a superseded version still answers for a knowledge time before its
  supersession (spec 01, worked example D-007).

  ## Locks

  Recording takes the series row `FOR UPDATE` before checking for overlapping
  versions: the series is the serialisation point, as the node row is for the
  ledger. These tables share no locks with the ledger's.

  Not yet here: rights (`permitted`, spec 04), corrections, four-eyes approval
  and succession.
  """

  alias Veridian.{Id, Repo}
  alias Veridian.Store.{InputSeries, InputVersion}
  require Ash.Query

  @type data_class :: :production | :golden | :synthetic | :test | :whatif | :impact

  @typedoc "A resolved version: what a calculation's calc_id needs, and where it came from."
  @type resolved :: %{
          version_id: Ecto.UUID.t(),
          content: Id.t(),
          effective_from: DateTime.t(),
          effective_to: DateTime.t() | nil
        }

  @data_classes [:production, :golden, :synthetic, :test, :whatif, :impact]

  @doc "RegisterInputSeries: a new series with a unique key."
  @spec register_series(String.t(), String.t(), data_class()) ::
          {:ok, Ecto.UUID.t()} | {:error, :series_exists | :unknown_data_class}
  def register_series(key, schema_ref, data_class)
      when is_binary(key) and is_binary(schema_ref) do
    cond do
      data_class not in @data_classes ->
        {:error, :unknown_data_class}

      series_by_key(key) != nil ->
        {:error, :series_exists}

      true ->
        attrs = %{
          key: key,
          schema_ref: schema_ref,
          data_class: data_class,
          created_at: DateTime.utc_now()
        }

        case Ash.create(InputSeries, attrs) do
          {:ok, series} -> {:ok, series.id}
          # Lost a race on the unique key.
          {:error, _} -> {:error, :series_exists}
        end
    end
  end

  @doc """
  RecordInputVersion: an original version, authoritative on receipt. Refused
  when its effective period overlaps an active version of the series
  (NoOverlappingActiveVersions) or does not end after it starts.
  """
  @spec record_version(String.t(), Id.t(), DateTime.t(), DateTime.t() | nil, String.t() | nil) ::
          {:ok, Ecto.UUID.t()}
          | {:error, :unknown_series | :overlap | :bad_range}
  def record_version(
        key,
        %Id{kind: :content} = content,
        %DateTime{} = effective_from,
        effective_to \\ nil,
        lineage_ref \\ nil
      ) do
    if effective_to != nil and DateTime.compare(effective_to, effective_from) != :gt do
      {:error, :bad_range}
    else
      Repo.transaction(fn ->
        series = lock_series!(key)

        if overlapping_active(series.id, effective_from, effective_to) != [],
          do: Repo.rollback(:overlap)

        now = DateTime.utc_now()

        version =
          Ash.create!(InputVersion, %{
            series_id: series.id,
            content_digest: content.digest,
            content_scheme: Atom.to_string(content.scheme),
            effective_from: effective_from,
            effective_to: effective_to,
            submitted_at: now,
            recorded_at: now,
            lineage_ref: lineage_ref,
            origin: :original,
            status: :active
          })

        version.id
      end)
    end
  end

  @doc """
  Point-in-time resolution (spec 01): the version of the series that was
  authoritative at `known_at` for the instant `as_of`. Exactly one version or
  an error: `:unresolvable` when there is none (a request then fails up front,
  D-008), `{:ambiguous, n}` when the data breaks NoOverlappingActiveVersions.
  """
  @spec resolve(String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, resolved()} | {:error, :unresolvable | {:ambiguous, pos_integer()}}
  def resolve(key, %DateTime{} = as_of, %DateTime{} = known_at) do
    case series_by_key(key) do
      nil ->
        {:error, :unresolvable}

      series ->
        InputVersion
        |> Ash.Query.filter(
          series_id == ^series.id and status in [:active, :superseded] and
            recorded_at <= ^known_at and
            (is_nil(superseded_at) or superseded_at > ^known_at) and
            effective_from <= ^as_of and
            (is_nil(effective_to) or effective_to > ^as_of)
        )
        |> Ash.read!()
        |> case do
          [] -> {:error, :unresolvable}
          [v] -> {:ok, to_resolved(v)}
          many -> {:error, {:ambiguous, length(many)}}
        end
    end
  end

  # Internals --------------------------------------------------------------------

  defp series_by_key(key),
    do: Ash.read_one!(InputSeries |> Ash.Query.filter(key == ^key))

  defp lock_series!(key) do
    case InputSeries
         |> Ash.Query.filter(key == ^key)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one!() do
      nil -> Repo.rollback(:unknown_series)
      series -> series
    end
  end

  # Active versions whose half-open period meets [from, to).
  defp overlapping_active(series_id, from, to) do
    query =
      InputVersion
      |> Ash.Query.filter(
        series_id == ^series_id and status == :active and
          (is_nil(effective_to) or effective_to > ^from)
      )

    query =
      if to == nil,
        do: query,
        else: Ash.Query.filter(query, effective_from < ^to)

    Ash.read!(query)
  end

  defp to_resolved(%InputVersion{} = v) do
    %{
      version_id: v.id,
      content: Id.new!(:content, scheme_atom(v.content_scheme), v.content_digest),
      effective_from: v.effective_from,
      effective_to: v.effective_to
    }
  end

  defp scheme_atom(text) do
    Enum.find(Id.schemes(), &(Atom.to_string(&1) == text)) ||
      raise ArgumentError, "unknown hash scheme in inputs: #{inspect(text)}"
  end
end
