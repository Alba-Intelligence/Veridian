defmodule Veridian.Store do
  @moduledoc """
  The ledger's Ash domain: requests, planned steps and calculation nodes
  (specs 02, 02b, 02c; D-018, D-072), and the bitemporal inputs they read (spec
  01, D-082). The state machine rules live in `Veridian.Graph`;
  `Veridian.Ledger` applies them to the ledger tables, one transaction per
  ledger step, and `Veridian.Inputs` records and resolves input versions.
  """
  use Ash.Domain

  resources do
    resource Veridian.Store.Request
    resource Veridian.Store.Step
    resource Veridian.Store.Node
    resource Veridian.Store.InputSeries
    resource Veridian.Store.InputVersion
  end
end
