defmodule Veridian.Id do
  @moduledoc """
  A typed, scheme-named identifier (spec 02, `VersionedHashScheme`, D-041).

  Every calc_id, content_hash and result_hash is a digest together with the
  kind of thing it names and the hashing scheme that produced it. A new scheme
  arrives only through a reviewed release; identifiers under an old scheme stay
  valid and are never rewritten. Scheme `:sha256_v1` is SHA-256 over the
  canonical encoding documented in `Veridian.CalcId`.

  The text form is `"<kind>/<scheme>/<64 lowercase hex digits>"`, for example
  `"calc/sha256_v1/9f2c..."`. Parsing is strict: anything else is an error, so
  a malformed identifier cannot reach the ledger.
  """

  @kinds [:calc, :content, :result, :model_code]
  @schemes [:sha256_v1]
  @digest_bytes 32

  @enforce_keys [:kind, :scheme, :digest]
  defstruct [:kind, :scheme, :digest]

  @type kind :: :calc | :content | :result | :model_code
  @type scheme :: :sha256_v1
  @type t :: %__MODULE__{kind: kind(), scheme: scheme(), digest: binary()}

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec schemes() :: [scheme()]
  def schemes, do: @schemes

  @doc "Builds an identifier from a 32-byte digest."
  @spec new(kind(), scheme(), binary()) :: {:ok, t()} | {:error, term()}
  def new(kind, scheme, digest) when kind in @kinds and scheme in @schemes do
    if is_binary(digest) and byte_size(digest) == @digest_bytes do
      {:ok, %__MODULE__{kind: kind, scheme: scheme, digest: digest}}
    else
      {:error, {:bad_digest, :expected_32_bytes}}
    end
  end

  def new(kind, scheme, _digest) when scheme in @schemes, do: {:error, {:unknown_kind, kind}}
  def new(_kind, scheme, _digest), do: {:error, {:unknown_scheme, scheme}}

  @doc "Like `new/3` but raises; for tests and values built by this library."
  @spec new!(kind(), scheme(), binary()) :: t()
  def new!(kind, scheme, digest) do
    case new(kind, scheme, digest) do
      {:ok, id} -> id
      {:error, reason} -> raise ArgumentError, "invalid identifier: #{inspect(reason)}"
    end
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{kind: k, scheme: s, digest: d}) do
    "#{k}/#{s}/#{Base.encode16(d, case: :lower)}"
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with [k, s, hex] <- String.split(text, "/"),
         {:ok, kind} <- one_of(k, @kinds, :unknown_kind),
         {:ok, scheme} <- one_of(s, @schemes, :unknown_scheme),
         {:ok, digest} <- decode(hex) do
      new(kind, scheme, digest)
    else
      {:error, _} = e -> e
      _ -> {:error, :malformed}
    end
  end

  def parse(_), do: {:error, :malformed}

  @doc "Total order used for canonical sorting: scheme, then digest bytes."
  @spec sort_key(t()) :: {String.t(), binary()}
  def sort_key(%__MODULE__{scheme: s, digest: d}), do: {Atom.to_string(s), d}

  defp one_of(text, allowed, tag) do
    case Enum.find(allowed, &(Atom.to_string(&1) == text)) do
      nil -> {:error, {tag, text}}
      atom -> {:ok, atom}
    end
  end

  # Lowercase only: Base.decode16 with case: :lower rejects upper-case digits,
  # so one identifier has exactly one text form.
  defp decode(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:bad_digest, :not_lowercase_hex}}
    end
  end

  defimpl String.Chars do
    def to_string(id), do: Veridian.Id.to_string(id)
  end
end
