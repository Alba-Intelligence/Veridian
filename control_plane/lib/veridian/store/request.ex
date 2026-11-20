defmodule Veridian.Store.Request do
  @moduledoc "A calculation request (spec 02 `CalculationRequest`), reduced to what the ledger rules need."
  use Ash.Resource,
    domain: Veridian.Store,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ledger_requests"
    repo Veridian.Repo

    # Each constraint names what it enforces (D-080): see SchemaModelTraceTest.
    check_constraints do
      check_constraint :status, "status_known",
        check: "status IN ('open', 'fulfilled', 'unfulfilled')",
        message: "unknown request status"
    end
  end

  attributes do
    # The caller chooses the id (the request's identity outside the ledger).
    uuid_primary_key :id, writable?: true, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:open, :fulfilled, :unfulfilled]],
      allow_nil?: false,
      default: :open,
      public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
