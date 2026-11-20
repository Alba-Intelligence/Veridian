defmodule Veridian.Store.Step do
  @moduledoc """
  A planned step (spec 02 `PlannedStep`). `prerequisite_ids` are the steps it
  needs; `node_digest` is the node it is bound to once bound.
  """
  use Ash.Resource,
    domain: Veridian.Store,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ledger_steps"
    repo Veridian.Repo

    references do
      reference :request, on_delete: :delete
    end

    check_constraints do
      check_constraint :status, "status_known",
        check: "status IN ('waiting', 'running', 'done', 'abandoned', 'cancelled')",
        message: "unknown step status"

      check_constraint :node_digest, "node_is_whole",
        check: "(node_digest IS NULL) = (node_scheme IS NULL)",
        message: "a node reference needs both digest and scheme"
    end

    custom_indexes do
      index [:request_id]
      # Purge looks for steps running on a node (D-063).
      index [:node_digest], where: "node_digest IS NOT NULL"
    end
  end

  attributes do
    # The planner chooses the id: dependent steps name their prerequisites by it.
    uuid_primary_key :id, writable?: true, public?: true

    attribute :prerequisite_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :status, :atom,
      constraints: [one_of: [:waiting, :running, :done, :abandoned, :cancelled]],
      allow_nil?: false,
      default: :waiting,
      public?: true

    attribute :node_digest, :binary, public?: true
    attribute :node_scheme, :string, public?: true
  end

  relationships do
    belongs_to :request, Veridian.Store.Request, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
