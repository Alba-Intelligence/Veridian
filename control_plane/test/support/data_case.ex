defmodule Veridian.DataCase do
  @moduledoc """
  Tests that use the ledger database. They run with real commits, not the SQL
  sandbox: the sandbox puts every process in one transaction, so lock and
  unique-key races (which the ledger must survive) could not happen and such
  tests would pass falsely. Hence `async: false` and a truncate before each test.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :db
    end
  end

  setup do
    Ecto.Adapters.SQL.query!(
      Veridian.Repo,
      "TRUNCATE ledger_steps, ledger_requests, ledger_nodes, input_versions, input_series",
      []
    )

    :ok
  end
end
