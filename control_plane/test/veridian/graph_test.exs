defmodule Veridian.GraphTest do
  @moduledoc """
  What the code must refuse. Trace replay shows the code can follow the model;
  it cannot show the code refuses what the model forbids, so the guards behind
  the model's safety properties are tested directly.
  """
  use ExUnit.Case, async: true

  alias Veridian.Graph

  defp ok!({:ok, g}), do: g
  defp ok!({:ok, g, _}), do: g

  # One request with steps a, then b (needs a).
  defp graph(max \\ 2) do
    Graph.new(max) |> Graph.submit(:r, %{a: [], b: [:a]}) |> ok!()
  end

  defp running_node(g, step, id), do: g |> Graph.bind(step, id) |> ok!()

  defp complete(g, id, hash \\ 9) do
    g |> Graph.dispatch(id) |> ok!() |> Graph.succeed(id, hash) |> ok!()
  end

  test "a request and its steps can be submitted once" do
    assert {:error, :request_exists} = Graph.submit(graph(), :r, %{c: []})
    assert {:error, :step_exists} = Graph.submit(graph(), :s, %{a: []})
    assert {:error, :unknown_prerequisite} = Graph.submit(Graph.new(2), :s, %{x: [:nope]})
  end

  test "a step binds only when its prerequisites are done, and only once" do
    g = graph()
    assert {:error, :not_ready} = Graph.bind(g, :b, :nb)
    g = running_node(g, :a, :na)
    assert {:error, :step_not_waiting} = Graph.bind(g, :a, :na)
  end

  test "attempts are bounded: a node is dispatched at most max_attempts times" do
    g = graph(2) |> running_node(:a, :na)
    g = g |> Graph.dispatch(:na) |> ok!() |> Graph.crash(:na) |> ok!()
    g = g |> Graph.dispatch(:na) |> ok!()
    assert {:error, :node_not_pending} = Graph.dispatch(g, :na)
    g = Graph.crash(g, :na) |> ok!()
    assert g.nodes[:na].status == :failed
    assert {:error, :node_not_pending} = Graph.dispatch(g, :na)
  end

  test "a payload is not purged under a running step, nor before it is cold" do
    g = graph() |> running_node(:a, :na) |> complete(:na)
    assert {:error, :payload_not_cold} = Graph.purge(g, :na)
    g = Graph.cool(g, :na) |> ok!()
    assert {:error, :step_running_on_node} = Graph.purge(g, :na)
    g = Graph.step_done(g, :a) |> ok!()
    assert {:ok, _} = Graph.purge(g, :na)
  end

  test "one recomputation however many steps wait for a purged payload (D-062)" do
    g =
      Graph.new(2) |> Graph.submit(:r1, %{a: []}) |> ok!() |> Graph.submit(:r2, %{c: []}) |> ok!()

    g = running_node(g, :a, :n) |> complete(:n)
    g = g |> Graph.step_done(:a) |> ok!() |> Graph.cool(:n) |> ok!() |> Graph.purge(:n) |> ok!()
    g = running_node(g, :c, :n)
    assert g.nodes[:n].remat_in_flight == 1
    assert g.steps[:c].status == :running

    # A second step binding to the same purged node does not start another one.
    g = Graph.submit(g, :r3, %{d: []}) |> ok!() |> then(&running_node(&1, :d, :n))
    assert g.nodes[:n].remat_in_flight == 1
    assert {:error, :rerun_not_allowed} = Graph.rerun(g, :n)
  end

  test "a failed or irreproducible node abandons its steps at binding, no recomputation" do
    g =
      Graph.new(1) |> Graph.submit(:r1, %{a: []}) |> ok!() |> Graph.submit(:r2, %{c: []}) |> ok!()

    g = running_node(g, :a, :n) |> Graph.dispatch(:n) |> ok!() |> Graph.reject(:n) |> ok!()
    g = running_node(g, :c, :n)
    assert g.steps[:c].status == :abandoned
    assert g.nodes[:n].remat_in_flight == 0
  end

  test "a request is fulfilled only when every step is done, failed only with an abandoned step" do
    g = graph()
    assert {:error, :steps_not_done} = Graph.request_fulfil(g, :r)
    assert {:error, :no_abandoned_step} = Graph.request_fail(g, :r)
    assert {:error, :unknown_request} = Graph.cancel(g, :nope)
  end

  test "a step is cancelled only when waiting, under an unfulfilled request" do
    g = graph()
    assert {:error, :request_not_unfulfilled} = Graph.step_cancel(g, :a)
    g = g |> running_node(:a, :na) |> Graph.cancel(:r) |> ok!()
    assert {:error, :step_not_waiting} = Graph.step_cancel(g, :a)
    assert {:ok, g2} = Graph.step_cancel(g, :b)
    assert g2.steps[:b].status == :cancelled
  end

  test "a step is done only when its node's result is available" do
    g = graph() |> running_node(:a, :na)
    assert {:error, :node_result_not_available} = Graph.step_done(g, :a)
    assert {:error, :node_not_failed} = Graph.step_abandon(g, :a)
    assert {:error, :step_not_running} = Graph.step_done(g, :b)
  end
end
