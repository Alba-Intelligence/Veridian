defmodule Veridian.Test.Replay do
  @moduledoc """
  Replays Quint traces (ITF) against an adapter (policy section 7, D-059).
  Test support, not production code.

  An adapter module provides:

    * `init/0` - the starting state (for the database adapter, an emptied database);
    * `apply_action!/3` - applies one model action for real, returns the next state;
    * `try_action/3` - the projection the action would give, without keeping its
      effect: `{:ok, projection}` or `:error`;
    * `project/1` - the model's variables projected from the real state;
    * `model_view/1` - the variables of a decoded model state the projection covers;
    * `candidates/0` - every action with arguments, for traces without action names.
  """
  import ExUnit.Assertions
  alias Veridian.Test.Itf

  @doc "Deterministic replay of an `--mbt` trace; returns the actions taken."
  def named(adapter, path) do
    [init | steps] = Itf.load!(path)
    s0 = adapter.init()
    assert adapter.model_view(init) == adapter.project(s0)

    {_s, actions} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({s0, []}, fn {state, i}, {s, acts} ->
        action = Map.fetch!(state, "actionTaken")
        s2 = adapter.apply_action!(s, action, picks(state))

        assert adapter.project(s2) == adapter.model_view(state),
               "state differs from the model after step #{i} (#{action})"

        {s2, [action | acts]}
      end)

    Enum.reverse(actions)
  end

  @doc """
  Replay of a trace without action names (`quint test` has no `--mbt`): each
  step is inferred, some action must reproduce the model's next state.
  """
  def inferred(adapter, path) do
    [init | steps] = Itf.load!(path)
    s0 = adapter.init()
    assert adapter.model_view(init) == adapter.project(s0)

    {_s, actions} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({s0, []}, fn {state, i}, {s, acts} ->
        target = adapter.model_view(state)

        if adapter.project(s) == target do
          {s, acts}
        else
          found =
            Enum.find(adapter.candidates(), fn {action, picks} ->
              adapter.try_action(s, action, picks) == {:ok, target}
            end)

          case found do
            {action, picks} -> {adapter.apply_action!(s, action, picks), [action | acts]}
            nil -> flunk("no action of the code reproduces the model's step #{i}")
          end
        end
      end)

    Enum.reverse(actions)
  end

  @doc "Decodes the picks of an `--mbt` state; every nondet appears, only the action's are used."
  def picks(state) do
    for {name, {:some, v}} <- Map.get(state, "nondetPicks", %{}), into: %{} do
      {String.to_atom(name), v}
    end
  end
end
