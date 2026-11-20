defmodule Veridian.LedgerConcurrencyTest do
  @moduledoc """
  The ledger's own concurrency (policy section 7: trace replay does not cover
  it). Real commits, real races: many processes act on the same rows at once,
  and the invariants the Quint model states for single atomic steps must still
  hold: one node per calc_id, one recomputation per purged payload, a payload
  never purged under a running step, a bundle all or nothing (D-056, D-063).
  """
  use Veridian.DataCase, async: false

  alias Veridian.{Id, Ledger}
  alias Veridian.Store.{Node, Step}

  @as_of ~U[2026-11-20 00:00:00.000000Z]

  defp calc(n), do: Id.new!(:calc, :sha256_v1, :crypto.hash(:sha256, "calc-#{n}"))
  defp result(n), do: Id.new!(:result, :sha256_v1, :crypto.hash(:sha256, "result-#{n}"))

  # A request with one step, returns the step id.
  defp one_step_request do
    {req, step} = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    {:ok, :ok} = Ledger.submit(req, %{step => []})
    {req, step}
  end

  defp parallel(items, fun) do
    items
    |> Task.async_stream(fun, max_concurrency: 10, timeout: 60_000, ordered: false)
    |> Enum.map(fn {:ok, v} -> v end)
  end

  defp node_rows, do: Ash.read!(Node)
  defp steps, do: Ash.read!(Step)

  # A completed node that has been through cold storage to purged, with no step on it.
  defp purged_node(n) do
    {_req, step} = one_step_request()
    {:ok, :created} = Ledger.bind(step, calc(n), @as_of)
    {:ok, _} = Ledger.dispatch(calc(n))
    {:ok, _} = Ledger.complete_bundle([{calc(n), result(n)}])
    {:ok, _} = Ledger.step_done(step)
    {:ok, _} = Ledger.cool(calc(n))
    {:ok, _} = Ledger.purge(calc(n))
  end

  test "many steps binding the same calc_id at once make one node (OneNodePerCalcId)" do
    stepids = for _ <- 1..30, do: elem(one_step_request(), 1)
    outcomes = parallel(stepids, &Ledger.bind(&1, calc(1), @as_of))

    assert Enum.count(outcomes, &(&1 == {:ok, :created})) == 1
    assert Enum.count(outcomes, &(&1 == {:ok, :existing})) == 29
    assert [%Node{status: :pending}] = node_rows()
    assert Enum.all?(steps(), &(&1.status == :running))
  end

  test "many steps binding a purged payload start one recomputation (D-062)" do
    purged_node(2)
    stepids = for _ <- 1..30, do: elem(one_step_request(), 1)

    outcomes = parallel(stepids, &Ledger.bind(&1, calc(2), @as_of))
    assert Enum.all?(outcomes, &(&1 == {:ok, :existing}))

    [node] = Enum.filter(node_rows(), &(&1.calc_digest == calc(2).digest))
    assert node.tier == :purged
    assert node.remat_in_flight == 1
    assert node.remat_attempts == 1
    assert Enum.count(steps(), &(&1.status == :running)) == 30
  end

  test "a payload is never purged under a running step, however the race goes (D-063)" do
    for round <- 1..25 do
      n = 100 + round
      {_req, step} = one_step_request()
      {:ok, :created} = Ledger.bind(step, calc(n), @as_of)
      {:ok, _} = Ledger.dispatch(calc(n))
      {:ok, _} = Ledger.complete_bundle([{calc(n), result(n)}])
      {:ok, _} = Ledger.cool(calc(n))

      # The step is still running on a cold payload: purge and step_done race.
      outcomes =
        parallel([:purge, :step_done], fn
          :purge -> Ledger.purge(calc(n))
          :step_done -> Ledger.step_done(step)
        end)

      [node] = Enum.filter(node_rows(), &(&1.calc_digest == calc(n).digest))
      [s] = Enum.filter(steps(), &(&1.id == step))

      # Never: a running step on a purged payload with nobody recomputing it.
      refute s.status == :running and node.tier == :purged and node.remat_in_flight == 0,
             "round #{round}: #{inspect(outcomes)}"

      # Purge wins only if the step had already finished.
      if node.tier == :purged, do: assert(s.status == :done)
    end
  end

  # One request with many independent steps, the shape of an end-of-day run.
  defp big_request(count) do
    req = Ecto.UUID.generate()
    ids = for _ <- 1..count, do: Ecto.UUID.generate()
    {:ok, :ok} = Ledger.submit(req, Map.new(ids, &{&1, []}))
    {req, ids}
  end

  test "the steps of one large request bind concurrently, one node per calc_id" do
    {_req, ids} = big_request(80)
    # 40 distinct calc_ids, each wanted by two steps.
    outcomes =
      ids
      |> Enum.with_index()
      |> parallel(fn {step, i} -> Ledger.bind(step, calc(1000 + rem(i, 40)), @as_of) end)

    assert Enum.count(outcomes, &(&1 == {:ok, :created})) == 40
    assert Enum.count(outcomes, &(&1 == {:ok, :existing})) == 40
    assert length(node_rows()) == 40
    assert Enum.all?(steps(), &(&1.status == :running))
  end

  test "a cancel racing the binds of one request: no deadlock, and no bind after it" do
    for round <- 1..10 do
      {req, ids} = big_request(40)

      outcomes =
        parallel([:cancel | ids], fn
          :cancel ->
            {:cancel, Ledger.cancel(req)}

          step ->
            {:bind,
             Ledger.bind(step, calc(2000 + round * 100 + :erlang.phash2(step, 1000)), @as_of)}
        end)

      assert {:cancel, {:ok, :ok}} in outcomes
      # Each bind either happened before the cancel or was refused by it.
      assert Enum.all?(outcomes, fn
               {:cancel, _} -> true
               {:bind, {:ok, :created}} -> true
               # Two steps may pick the same calc_id: the later one meets the node.
               {:bind, {:ok, :existing}} -> true
               {:bind, {:error, :request_not_open}} -> true
               _ -> false
             end)

      # After the cancel has committed, binding is refused.
      waiting = Enum.filter(steps(), &(&1.request_id == req and &1.status == :waiting))

      for s <- waiting do
        assert {:error, :request_not_open} = Ledger.bind(s.id, calc(9_000_000 + round), @as_of)
      end
    end
  end

  test "binding a calc_id again with another as_of is refused and changes nothing" do
    {_r, step1} = one_step_request()
    {_r, step2} = one_step_request()
    {:ok, :created} = Ledger.bind(step1, calc(7), @as_of)

    other = ~U[2026-11-21 00:00:00.000000Z]
    assert {:error, :as_of_mismatch} = Ledger.bind(step2, calc(7), other)
    assert [%Node{as_of: kept}] = node_rows()
    assert DateTime.compare(kept, @as_of) == :eq
    assert Enum.find(steps(), &(&1.id == step2)).status == :waiting
  end

  test "the bundle path: bind, dispatch, commit, finish, each in one transaction" do
    {_req, ids} = big_request(30)
    items = ids |> Enum.with_index() |> Enum.map(fn {s, i} -> {s, calc(500 + i), @as_of} end)

    assert {:ok, kinds} = Ledger.bind_bundle(items)
    assert Enum.all?(kinds, &(&1 == :created))
    assert {:ok, :ok} = Ledger.dispatch_bundle(for i <- 0..29, do: calc(500 + i))
    assert {:ok, :ok} = Ledger.complete_bundle(for i <- 0..29, do: {calc(500 + i), result(i)})
    assert {:ok, :ok} = Ledger.step_done_bundle(ids)

    assert Enum.all?(steps(), &(&1.status == :done))
    assert Enum.all?(node_rows(), &(&1.status == :complete))
  end

  test "a bind bundle with one refused item changes nothing" do
    {_req, ids} = big_request(5)
    {_r, other} = one_step_request()
    items = for {s, i} <- Enum.with_index(ids), do: {s, calc(600 + i), @as_of}
    bad = {other, calc(600), ~U[2026-11-21 00:00:00.000000Z]}
    # calc(600) is created by the first item, so the last item's as_of disagrees.
    assert {:error, :as_of_mismatch} = Ledger.bind_bundle(items ++ [bad])
    assert node_rows() == []
    assert Enum.all?(steps(), &(&1.status == :waiting))
  end

  test "finish bundles over shared nodes, committed at once, do not deadlock" do
    # 20 steps on 5 nodes, finished by 4 bundles in different orders.
    {_req, ids} = big_request(20)

    items =
      ids |> Enum.with_index() |> Enum.map(fn {s, i} -> {s, calc(700 + rem(i, 5)), @as_of} end)

    {:ok, _} = Ledger.bind_bundle(items)
    {:ok, _} = Ledger.dispatch_bundle(for i <- 0..4, do: calc(700 + i))
    {:ok, _} = Ledger.complete_bundle(for i <- 0..4, do: {calc(700 + i), result(i)})

    bundles = [ids, Enum.reverse(ids), Enum.shuffle(ids), Enum.take(ids, 7)]
    outcomes = parallel(bundles, fn b -> {b, Ledger.step_done_bundle(b)} end)

    # A bundle that meets an already finished step is refused whole, so which
    # steps end up done depends on who committed first. Whatever the order: no
    # deadlock, at least one bundle commits, and the done steps are exactly the
    # ones a committed bundle covered.
    assert Enum.all?(outcomes, fn {_, o} -> o == {:ok, :ok} or match?({:error, _}, o) end)

    covered = for({b, {:ok, :ok}} <- outcomes, s <- b, into: MapSet.new(), do: s)
    assert MapSet.size(covered) > 0
    done = for s <- steps(), s.status == :done, into: MapSet.new(), do: s.id
    assert done == covered
    assert Enum.all?(steps(), &(&1.status in [:done, :running]))
  end

  test "a bundle is all or nothing: one bad node rolls the whole bundle back (D-056)" do
    ids = for n <- 200..204, do: elem(one_step_request(), 1) |> then(&{n, &1})

    for {n, step} <- ids do
      {:ok, :created} = Ledger.bind(step, calc(n), @as_of)
      {:ok, _} = Ledger.dispatch(calc(n))
    end

    # Node 204 is crashed first, so it can no longer succeed.
    {:ok, _} = Ledger.crash(calc(204))

    bundle = for {n, _} <- ids, do: {calc(n), result(n)}
    assert {:error, :node_not_computing} = Ledger.complete_bundle(bundle)

    complete = Enum.count(node_rows(), &(&1.status == :complete))
    assert complete == 0, "a failed bundle left #{complete} nodes complete"
  end

  test "overlapping bundles committed at once neither deadlock nor complete a node twice" do
    ids = for n <- 300..329, do: elem(one_step_request(), 1) |> then(&{n, &1})

    for {n, step} <- ids do
      {:ok, :created} = Ledger.bind(step, calc(n), @as_of)
      {:ok, _} = Ledger.dispatch(calc(n))
    end

    all = for {n, _} <- ids, do: {calc(n), result(n)}
    # Three bundles over overlapping ranges, in different orders.
    bundles = [Enum.take(all, 20), Enum.take(Enum.reverse(all), 20), Enum.shuffle(all)]
    outcomes = parallel(bundles, fn b -> {b, Ledger.complete_bundle(b)} end)

    assert Enum.count(outcomes, &match?({_, {:ok, :ok}}, &1)) >= 1
    assert Enum.all?(outcomes, fn {_, o} -> o in [{:ok, :ok}, {:error, :node_not_computing}] end)

    # Every node a committed bundle covered is complete exactly once with its
    # result; a refused bundle changed nothing.
    rows = Enum.filter(node_rows(), &(&1.status == :complete))
    assert Enum.all?(rows, &(&1.attempts == 1 and &1.tier == :hot))

    covered =
      for({b, {:ok, :ok}} <- outcomes, {c, _} <- b, into: MapSet.new(), do: c.digest)

    assert MapSet.new(rows, & &1.calc_digest) == covered
  end
end
