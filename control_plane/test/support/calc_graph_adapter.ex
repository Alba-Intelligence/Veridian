defmodule Veridian.Test.CalcGraphAdapter do
  @moduledoc """
  Maps the actions of `models/calc_graph.qnt` (instance `calc_graph_fixed`) to
  calls on `Veridian.Graph`, and projects the real state back to the model's
  variables (policy section 7, D-059). Test support, not production code.

  The model's world is two evaluation steps per request: A (keyed by the
  request's input) and B (needs A's result). Its calc_ids are toy integers: an
  A node's id is its input, a B node's id is `100 + result_hash(A)`, which is
  the early-cutoff rule. That toy hashing lives here; `Veridian.Graph` only
  sees opaque keys.
  """

  alias Veridian.Graph

  @reqs [1, 2, 3]
  @input %{1 => 1, 2 => 2, 3 => 1}
  @result %{1 => 7, 2 => 7}
  @max_attempts 2

  @nodes [1, 2, 107, 0]
  @steps for r <- @reqs, k <- [0, 1], do: {r, k}

  @spec init() :: Graph.t()
  def init, do: Graph.new(@max_attempts)

  @doc "Applies one model action with its picked arguments; returns the next graph or raises."
  @spec apply_action!(Graph.t(), String.t(), map()) :: Graph.t()
  def apply_action!(g, "init", _picks), do: g

  def apply_action!(g, "submit", %{r: r}) do
    ok!(Graph.submit(g, r, %{{r, 0} => [], {r, 1} => [{r, 0}]}), "submit")
  end

  def apply_action!(g, "bindNew", %{r: r, k: k}), do: bind!(g, r, k, :created)
  def apply_action!(g, "bindExisting", %{r: r, k: k}), do: bind!(g, r, k, :existing)
  def apply_action!(g, "dispatch", %{n: n}), do: ok!(Graph.dispatch(g, n), "dispatch")

  def apply_action!(g, "succeed", %{n: n}),
    do: ok!(Graph.succeed(g, n, compute_result(n)), "succeed")

  def apply_action!(g, "crash", %{n: n}), do: ok!(Graph.crash(g, n), "crash")
  def apply_action!(g, "reject", %{n: n}), do: ok!(Graph.reject(g, n), "reject")
  def apply_action!(g, "cool", %{n: n}), do: ok!(Graph.cool(g, n), "cool")
  def apply_action!(g, "purge", %{n: n}), do: ok!(Graph.purge(g, n), "purge")

  def apply_action!(g, "rematAnswer", %{n: n, same: same}),
    do: ok!(Graph.remat_answer(g, n, same), "rematAnswer")

  def apply_action!(g, "rematCrash", %{n: n}), do: ok!(Graph.remat_crash(g, n), "rematCrash")
  def apply_action!(g, "rerun", %{n: n}), do: ok!(Graph.rerun(g, n), "rerun")
  def apply_action!(g, "stepDone", %{r: r, k: k}), do: ok!(Graph.step_done(g, {r, k}), "stepDone")

  def apply_action!(g, "stepAbandon", %{r: r, k: k}),
    do: ok!(Graph.step_abandon(g, {r, k}), "stepAbandon")

  def apply_action!(g, "requestFulfil", %{r: r}),
    do: ok!(Graph.request_fulfil(g, r), "requestFulfil")

  def apply_action!(g, "requestFail", %{r: r}), do: ok!(Graph.request_fail(g, r), "requestFail")
  def apply_action!(g, "cancel", %{r: r}), do: ok!(Graph.cancel(g, r), "cancel")

  def apply_action!(g, "stepCancel", %{r: r, k: k}),
    do: ok!(Graph.step_cancel(g, {r, k}), "stepCancel")

  defp bind!(g, r, k, expected) do
    id = calc_id(g, r, k)

    case Graph.bind(g, {r, k}, id) do
      {:ok, g2, ^expected} -> g2
      {:ok, _, other} -> raise "bind(#{r},#{k}): model took #{expected}, code did #{other}"
      {:error, reason} -> raise "bind(#{r},#{k}) refused: #{inspect(reason)}"
    end
  end

  defp ok!({:ok, g}, _action), do: g
  defp ok!({:error, reason}, action), do: raise("#{action} refused: #{inspect(reason)}")

  # The model's idOf: A from its input, B from the result hash of A's node.
  defp calc_id(_g, r, 0), do: Map.fetch!(@input, r)

  defp calc_id(g, r, 1) do
    case Graph.step_result_hash(g, {r, 0}) do
      {:ok, h} -> 100 + h
      {:error, reason} -> raise "no calc_id for step (#{r},1) yet: #{inspect(reason)}"
    end
  end

  defp compute_result(n) when n < 100, do: Map.fetch!(@result, n)
  defp compute_result(n), do: n + 1000

  @doc "The projection `action` would give, without keeping its effect (the state is immutable)."
  @spec try_action(Graph.t(), String.t(), map()) :: {:ok, map()} | :error
  def try_action(g, action, picks) do
    {:ok, project(apply_action!(g, action, picks))}
  rescue
    RuntimeError -> :error
  end

  @doc "Every action with its arguments, for traces without action names."
  @spec candidates() :: [{String.t(), map()}]
  def candidates do
    per_req =
      for r <- @reqs, a <- ["submit", "requestFulfil", "requestFail", "cancel"], do: {a, %{r: r}}

    per_step =
      for {r, k} <- @steps,
          a <- ["bindNew", "bindExisting", "stepDone", "stepAbandon", "stepCancel"],
          do: {a, %{r: r, k: k}}

    per_node =
      for n <- [1, 2, 107],
          a <- ~w(dispatch succeed crash reject cool purge rematCrash rerun),
          do: {a, %{n: n}}

    remat = for n <- [1, 2, 107], same <- [true, false], do: {"rematAnswer", %{n: n, same: same}}
    per_req ++ per_step ++ per_node ++ remat
  end

  @doc "The model's variables, projected from the real state, in the same shape as a decoded ITF state."
  @spec project(Graph.t()) :: map()
  def project(g) do
    %{
      "reqSt" => Map.new(@reqs, &{&1, get(g.requests, &1, :status, :no_req)}),
      "stepSt" => Map.new(@steps, &{&1, get(g.steps, &1, :status, :no_step)}),
      "stepNode" => Map.new(@steps, &{&1, get(g.steps, &1, :node, nil) || 0}),
      "nodeSt" => node_map(g, :status, :no_node),
      "attempts" => node_map(g, :attempts, 0),
      "resultHash" => node_map(g, :result_hash, 0),
      "reproducible" => node_map(g, :reproducible, true),
      "tier" => node_map(g, :tier, :no_payload),
      "rematInFlight" => node_map(g, :remat_in_flight, 0),
      "rematAttempts" => node_map(g, :remat_attempts, 0)
    }
  end

  defp node_map(g, field, default) do
    Map.new(@nodes, fn n ->
      value = if n == 0, do: default, else: get(g.nodes, n, field, default)
      {n, if(value == nil, do: default, else: value)}
    end)
  end

  defp get(map, key, field, default) do
    case map do
      %{^key => entry} -> Map.fetch!(entry, field)
      _ -> default
    end
  end

  @doc "The variables of a decoded model state that the projection covers."
  @spec model_view(map()) :: map()
  def model_view(state) do
    Map.take(state, [
      "reqSt",
      "stepSt",
      "stepNode",
      "nodeSt",
      "attempts",
      "resultHash",
      "reproducible",
      "tier",
      "rematInFlight",
      "rematAttempts"
    ])
  end
end
