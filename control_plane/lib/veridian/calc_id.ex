defmodule Veridian.CalcId do
  @moduledoc """
  The calc_id of a calculation node, scheme `:sha256_v1` (spec 02, D-003, D-041).

      calc_id = sha256(preimage)

  ## Inputs (D-003; user's answer of 2026-11-20: no calculation context in v1)

    * `model_code` - the `:model_code` identifier of the model version. Identity
      is the code, not the release or the version label (spec 02, D-060).
    * `as_of` - UTC instant, microsecond precision (D-015).
    * `inputs` - `:content` identifiers of the resolved input versions.
    * `prerequisites` - `:result` identifiers of each prerequisite node. Result
      hashes, not calc_ids, so an upstream change that leaves a result
      byte-identical leaves every downstream calc_id unchanged (early cutoff).

  `known_at` is deliberately not an input: identical data reached at different
  times reuses results.

  ## Preimage layout (frozen; changing any byte is a new scheme, D-041)

  All integers big-endian. `field(b)` is a 64-bit unsigned byte length followed
  by the bytes. `list(xs)` is a 64-bit unsigned count followed by the elements,
  each as `field(to_string(element))`.

      field("veridian/calc_id/sha256_v1")
      field(to_string(model_code))
      <<as_of_microseconds_since_unix_epoch::signed-64>>
      list(inputs sorted by sort_key)
      list(prerequisites sorted by sort_key)

  Inputs and prerequisites are **multisets, not sets**: they are sorted and
  duplicates are kept, so `{A, A}` and `{A}` have different calc_ids. Two
  distinct input versions with identical content must not collapse into one.
  Callers pass any order; the encoding is order-independent (spec 02,
  `CanonicalInputOrdering`).

  The length prefixes make the encoding injective: no two different argument
  tuples produce the same preimage.
  """

  alias Veridian.Id

  @scheme :sha256_v1
  @domain "veridian/calc_id/sha256_v1"
  @min_micros -9_223_372_036_854_775_808
  @max_micros 9_223_372_036_854_775_807

  @type args :: %{
          model_code: Id.t(),
          as_of: DateTime.t(),
          inputs: [Id.t()],
          prerequisites: [Id.t()]
        }

  @doc "Computes the calc_id, or an error naming the first invalid argument."
  @spec compute(args()) :: {:ok, Id.t()} | {:error, term()}
  def compute(%{model_code: mc, as_of: as_of, inputs: inputs, prerequisites: prereqs}) do
    with :ok <- check_all([mc], :model_code, :model_code),
         {:ok, micros} <- micros(as_of),
         :ok <- check_all(inputs, :content, :inputs),
         :ok <- check_all(prereqs, :result, :prerequisites) do
      digest = :crypto.hash(:sha256, preimage(mc, micros, inputs, prereqs))
      Id.new(:calc, @scheme, digest)
    end
  end

  def compute(_), do: {:error, :missing_arguments}

  @doc "The exact bytes hashed. Exposed so golden vectors can be checked independently."
  @spec preimage(Id.t(), integer(), [Id.t()], [Id.t()]) :: binary()
  def preimage(model_code, micros, inputs, prerequisites) do
    IO.iodata_to_binary([
      field(@domain),
      field(Id.to_string(model_code)),
      <<micros::signed-big-64>>,
      list(inputs),
      list(prerequisites)
    ])
  end

  defp list(ids) do
    sorted = Enum.sort_by(ids, &Id.sort_key/1)
    [<<length(sorted)::unsigned-big-64>> | Enum.map(sorted, &field(Id.to_string(&1)))]
  end

  defp field(bin), do: [<<byte_size(bin)::unsigned-big-64>>, bin]

  defp micros(%DateTime{time_zone: "Etc/UTC"} = dt) do
    micros = DateTime.to_unix(dt, :microsecond)

    if micros >= @min_micros and micros <= @max_micros do
      {:ok, micros}
    else
      {:error, {:as_of, :out_of_range}}
    end
  end

  defp micros(_), do: {:error, {:as_of, :must_be_utc_datetime}}

  # Kind only: schemes are per identifier (D-041). A dependent keeps its own
  # calc_id scheme while a prerequisite's result hash moves to a newer scheme;
  # the preimage embeds each identifier's full text, scheme included, so ids
  # under different schemes encode differently.
  defp check_all(ids, kind, field) when is_list(ids) do
    if Enum.all?(ids, &match?(%Id{kind: ^kind}, &1)) do
      :ok
    else
      {:error, {field, :wrong_kind}}
    end
  end

  defp check_all(_ids, _kind, field), do: {:error, {field, :not_a_list}}
end
