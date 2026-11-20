defmodule Veridian.Test.Itf do
  @moduledoc """
  Reads Quint traces in ITF (Informal Trace Format) written with `quint run
  --out-itf --mbt` (policy section 7, D-059). Test support, not production code.

  Decoding: `#bigint` is an integer, `#map` a map, `#set` a MapSet, `#tup` a
  tuple, a `{"tag": T, "value": V}` variant becomes `{snake_case(T), V}` (a
  variant with an empty tuple payload becomes the bare atom).
  """

  @type state :: %{String.t() => term()}

  @doc "Loads a trace file; returns the states with variable names stripped of their module prefix."
  @spec load!(Path.t()) :: [state()]
  def load!(path) do
    path |> File.read!() |> Jason.decode!() |> Map.fetch!("states") |> Enum.map(&state/1)
  end

  defp state(raw) do
    raw
    |> Map.delete("#meta")
    |> Map.new(fn {k, v} -> {short(k), decode(v)} end)
  end

  defp short(name), do: name |> String.split("::") |> List.last()

  @spec decode(term()) :: term()
  def decode(%{"#bigint" => s}), do: String.to_integer(s)
  def decode(%{"#map" => pairs}), do: Map.new(pairs, fn [k, v] -> {decode(k), decode(v)} end)
  def decode(%{"#set" => xs}), do: MapSet.new(xs, &decode/1)
  def decode(%{"#tup" => xs}), do: xs |> Enum.map(&decode/1) |> List.to_tuple()
  def decode(%{"tag" => tag, "value" => %{"#tup" => []}}), do: snake(tag)
  def decode(%{"tag" => tag, "value" => v}), do: {snake(tag), decode(v)}
  def decode(xs) when is_list(xs), do: Enum.map(xs, &decode/1)
  def decode(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, decode(v)} end)
  def decode(other), do: other

  defp snake(tag), do: tag |> Macro.underscore() |> String.to_atom()
end
