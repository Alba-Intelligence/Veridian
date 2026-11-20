defmodule Veridian.LedgerBundleModelTest do
  @moduledoc """
  The bundle engine (D-078) against the pure graph. A bundle reads and writes
  whole tables at a time; this checks that it still means exactly "apply the
  graph's step to each item in order, all or nothing": after every random
  bundle operation the database, read back as a graph, equals the pure graph
  folded over the same items, and both accept or refuse the same operations.
  """
  use Veridian.DataCase, async: false
  use ExUnitProperties

  alias Veridian.{Graph, Id, Ledger}

  @as_of ~U[2026-11-20 00:00:00.000000Z]
  @steps 6

  defp calc(n), do: Id.new!(:calc, :sha256_v1, :crypto.hash(:sha256, "model-calc-#{n}"))
  defp result(n), do: Id.new!(:result, :sha256_v1, :crypto.hash(:sha256, "model-result-#{n}"))

  # Six steps of one request; step i >= 3 waits for step i - 3.
  defp plan do
    ids = for _ <- 1..@steps, do: Ecto.UUID.generate()

    prereqs =
      for {id, i} <- Enum.with_index(ids), into: %{} do
        {id, if(i >= 3, do: [Enum.at(ids, i - 3)], else: [])}
      end

    {ids, prereqs}
  end

  defp op_gen do
    step = StreamData.integer(0..(@steps - 1))
    cid = StreamData.integer(0..3)
    some = fn g -> StreamData.list_of(g, max_length: 4) end

    StreamData.one_of([
      StreamData.tuple({StreamData.constant(:bind), some.(StreamData.tuple({step, cid}))}),
      StreamData.tuple({StreamData.constant(:dispatch), some.(cid)}),
      StreamData.tuple({StreamData.constant(:complete), some.(cid)}),
      StreamData.tuple({StreamData.constant(:done), some.(step)}),
      StreamData.tuple({StreamData.constant(:abandon), some.(step)})
    ])
  end

  # A coherent round: bind some steps, dispatch and complete their nodes, finish
  # the steps. Random operation lists seldom get that far on their own.
  defp round_gen do
    step = StreamData.integer(0..(@steps - 1))
    cid = StreamData.integer(0..3)

    StreamData.bind(
      StreamData.list_of(StreamData.tuple({step, cid}), min_length: 1, max_length: 6),
      fn items ->
        cs = items |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        ss = items |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        # Other steps then meet the nodes that now exist (memo hits).
        again = for {s, c} <- items, do: {rem(s + 1, @steps), c}

        StreamData.constant([
          {:bind, items},
          {:dispatch, cs},
          {:complete, cs},
          {:done, ss},
          {:bind, again},
          {:done, Enum.map(again, &elem(&1, 0))}
        ])
      end
    )
  end

  defp ops_gen do
    StreamData.one_of([
      StreamData.list_of(op_gen(), max_length: 10),
      StreamData.map(StreamData.list_of(round_gen(), max_length: 3), &Enum.concat/1)
    ])
  end

  # The same operation on the pure graph: every item in order, or nothing.
  defp pure(g, ids, {:bind, items}),
    do: fold(g, items, fn g, {s, c} -> Graph.bind(g, Enum.at(ids, s), calc(c)) end)

  defp pure(g, _ids, {:dispatch, cs}), do: fold(g, cs, fn g, c -> Graph.dispatch(g, calc(c)) end)

  defp pure(g, _ids, {:complete, cs}),
    do: fold(g, cs, fn g, c -> Graph.succeed(g, calc(c), result(c)) end)

  defp pure(g, ids, {:done, ss}),
    do: fold(g, ss, fn g, s -> Graph.step_done(g, Enum.at(ids, s)) end)

  defp pure(g, ids, {:abandon, ss}),
    do: fold(g, ss, fn g, s -> Graph.step_abandon(g, Enum.at(ids, s)) end)

  defp fold(g, items, fun) do
    Enum.reduce_while(items, {:ok, g}, fn item, {:ok, g} ->
      case fun.(g, item) do
        {:ok, g2} -> {:cont, {:ok, g2}}
        {:ok, g2, _} -> {:cont, {:ok, g2}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp ledger(ids, {:bind, items}),
    do: Ledger.bind_bundle(for {s, c} <- items, do: {Enum.at(ids, s), calc(c), @as_of})

  defp ledger(_ids, {:dispatch, cs}), do: Ledger.dispatch_bundle(Enum.map(cs, &calc/1))

  defp ledger(_ids, {:complete, cs}),
    do: Ledger.complete_bundle(for c <- cs, do: {calc(c), result(c)})

  defp ledger(ids, {:done, ss}), do: Ledger.step_done_bundle(Enum.map(ss, &Enum.at(ids, &1)))

  defp ledger(ids, {:abandon, ss}),
    do: Ledger.step_abandon_bundle(Enum.map(ss, &Enum.at(ids, &1)))

  property "bundle operations equal the pure graph folded over their items" do
    max_attempts = Application.get_env(:veridian, :max_attempts, 3)

    check all(ops <- ops_gen(), max_runs: 80) do
      Ecto.Adapters.SQL.query!(
        Veridian.Repo,
        "TRUNCATE ledger_steps, ledger_requests, ledger_nodes",
        []
      )

      {ids, prereqs} = plan()
      req = Ecto.UUID.generate()
      {:ok, :ok} = Ledger.submit(req, prereqs)
      {:ok, model} = Graph.submit(Graph.new(max_attempts), req, prereqs)

      Enum.reduce(ops, model, fn op, model ->
        expected = pure(model, ids, op)
        actual = ledger(ids, op)

        model2 =
          case {expected, actual} do
            {{:ok, g2}, {:ok, _}} -> g2
            {{:error, _}, {:error, _}} -> model
            other -> flunk("#{inspect(op)}: pure and ledger disagree: #{inspect(other)}")
          end

        snap = Ledger.snapshot()
        assert snap.requests == model2.requests, "requests after #{inspect(op)}"
        assert snap.steps == model2.steps, "steps after #{inspect(op)}"
        assert snap.nodes == model2.nodes, "nodes after #{inspect(op)}"
        model2
      end)
    end
  end
end
