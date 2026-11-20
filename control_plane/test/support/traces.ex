defmodule Veridian.Test.Traces do
  @moduledoc "Where the committed Quint traces are, and what they must cover. Test support."

  @dir Path.expand("../../fixtures/traces", __DIR__)

  # Every action of the model except `init`.
  @all_actions ~w(submit bindNew bindExisting dispatch succeed crash reject cool purge
                  rematAnswer rematCrash rerun stepDone stepAbandon requestFulfil
                  requestFail cancel stepCancel)

  def all_actions, do: @all_actions

  def random, do: wildcard("calc_graph/*.itf.json")
  def scenarios, do: wildcard("calc_graph_scenarios/*.itf.json")

  defp wildcard(pattern), do: @dir |> Path.join(pattern) |> Path.wildcard() |> Enum.sort()

  @doc "Hash of the model files now; the traces are valid for exactly these."
  def current_models_hash do
    Path.expand("../../../models", __DIR__)
    |> Path.join("calc_graph*.qnt")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map_join(&File.read!/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def recorded_models_hash do
    @dir |> Path.join("calc_graph.models.sha256") |> File.read!() |> String.trim()
  end
end
