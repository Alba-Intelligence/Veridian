defmodule Veridian.Store.Node do
  @moduledoc """
  A calculation node (spec 02 `CalculationNode`), keyed by its calc_id.

  Identifiers are stored as the 32-byte digest plus the scheme name, not as the
  79-byte text form: the primary key index of 100 M nodes was 5.6 GB at about
  190 bytes per node (docs/design/local-measurements.md), and the text form would
  roughly double it. `Veridian.Ledger` converts to and from `Veridian.Id`.

  `as_of` is on the row because the caller always knows it (it is part of the
  calc_id) and a partition rule may need it (open question, M1).
  """
  use Ash.Resource,
    domain: Veridian.Store,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ledger_nodes"
    repo Veridian.Repo

    check_constraints do
      check_constraint :calc_digest, "digest_is_32_bytes",
        check: "octet_length(calc_digest) = 32",
        message: "a calc_id digest is 32 bytes"

      check_constraint :status, "status_known",
        check: "status IN ('pending', 'computing', 'complete', 'failed')",
        message: "unknown node status"

      check_constraint :tier, "tier_known",
        check: "tier IS NULL OR tier IN ('hot', 'cold', 'purged')",
        message: "unknown payload tier"

      # A node has a result exactly when it is complete, and a complete node has
      # a complete result (digest and scheme) and a payload tier.
      check_constraint :result_digest, "result_iff_complete",
        check: "(status = 'complete') = (result_digest IS NOT NULL)",
        message: "a node has a result exactly when it is complete"

      check_constraint :status, "complete_is_whole",
        check: "status <> 'complete' OR (result_scheme IS NOT NULL AND tier IS NOT NULL)",
        message: "a complete node has a result scheme and a payload tier"

      check_constraint :attempts, "counters_not_negative",
        check: "attempts >= 0 AND remat_in_flight >= 0 AND remat_attempts >= 0",
        message: "counters are never negative"
    end
  end

  attributes do
    attribute :calc_digest, :binary, primary_key?: true, allow_nil?: false, public?: true
    attribute :calc_scheme, :string, allow_nil?: false, public?: true
    attribute :as_of, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:pending, :computing, :complete, :failed]],
      allow_nil?: false,
      default: :pending,
      public?: true

    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true
    attribute :result_digest, :binary, public?: true
    attribute :result_scheme, :string, public?: true
    attribute :reproducible, :boolean, allow_nil?: false, default: true, public?: true

    attribute :tier, :atom,
      constraints: [one_of: [:hot, :cold, :purged]],
      public?: true

    attribute :remat_in_flight, :integer, allow_nil?: false, default: 0, public?: true
    attribute :remat_attempts, :integer, allow_nil?: false, default: 0, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
