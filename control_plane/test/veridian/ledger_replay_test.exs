defmodule Veridian.LedgerReplayTest do
  @moduledoc """
  Replays the model's traces against the PostgreSQL ledger (`Veridian.Ledger`),
  after every step comparing the model's state with the database projected back
  to the model's variables (policy section 7, D-059). The pure `Veridian.Graph`
  has the same traces replayed in `Veridian.GraphReplayTest`; this shows the
  storage layer keeps the same behaviour, sequentially. Races are tested in
  `Veridian.LedgerConcurrencyTest`.
  """
  use Veridian.DataCase, async: false

  alias Veridian.Test.{CalcGraphLedgerAdapter, Replay, Traces}

  for trace <- Traces.random() do
    @trace trace
    test "random trace #{Path.basename(trace)}" do
      Replay.named(CalcGraphLedgerAdapter, @trace)
    end
  end

  for trace <- Traces.scenarios() do
    @trace trace
    test "scenario #{Path.basename(trace)}" do
      assert Replay.inferred(CalcGraphLedgerAdapter, @trace) != []
    end
  end
end
