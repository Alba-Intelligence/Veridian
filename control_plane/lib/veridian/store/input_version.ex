defmodule Veridian.Store.InputVersion do
  @moduledoc """
  One immutable statement about a series over an effective period (spec 01
  `InputVersion`).

  Its content is identified by a typed `content` identifier (D-041), stored as
  the 32-byte digest plus the scheme name, computed by the Julia canonical form
  and recorded as given (D-081). The content id is deliberately not unique: a
  remainder version keeps its predecessor's content hash, which is how calc_ids
  survive partial corrections (D-006).

  Effective periods are half-open: `effective_from` is included,
  `effective_to` excluded, and a null `effective_to` is open-ended.

  Not yet here: who submitted or approved it (until identities exist, spec 04),
  corrections, four-eyes approval and succession (D-082).
  """
  use Ash.Resource,
    domain: Veridian.Store,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "input_versions"
    repo Veridian.Repo

    references do
      reference :series, on_delete: :restrict
    end

    # Each constraint names what it enforces (D-080, D-082): see SchemaModelTraceTest.
    check_constraints do
      check_constraint :content_digest, "content_digest_is_32_bytes",
        check: "octet_length(content_digest) = 32",
        message: "a content digest is 32 bytes"

      check_constraint :status, "status_known",
        check: "status IN ('proposed', 'active', 'superseded', 'rejected')",
        message: "unknown input version status"

      check_constraint :origin, "origin_known",
        check: "origin IN ('original', 'correction', 'succession', 'remainder')",
        message: "unknown input version origin"

      check_constraint :effective_to, "effective_range_ordered",
        check: "effective_to IS NULL OR effective_to > effective_from",
        message: "an effective period ends after it starts"

      check_constraint :status, "only_corrections_await_approval",
        check: "status <> 'proposed' OR origin = 'correction'",
        message: "only a correction awaits approval"

      check_constraint :recorded_at, "recorded_iff_authoritative",
        check: "(recorded_at IS NOT NULL) = (status IN ('active', 'superseded'))",
        message: "a version has a record time exactly when it is or was authoritative"

      check_constraint :superseded_at, "superseded_iff_superseded",
        check: "(superseded_at IS NOT NULL) = (status = 'superseded')",
        message: "a version has a supersession time exactly when it is superseded"
    end

    custom_indexes do
      # Point-in-time resolution reads one series at a time.
      index [:series_id, :effective_from]
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :content_digest, :binary, allow_nil?: false, public?: true
    attribute :content_scheme, :string, allow_nil?: false, public?: true
    attribute :effective_from, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :effective_to, :utc_datetime_usec, public?: true
    attribute :submitted_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :recorded_at, :utc_datetime_usec, public?: true
    attribute :superseded_at, :utc_datetime_usec, public?: true
    attribute :lineage_ref, :string, public?: true

    attribute :origin, :atom,
      constraints: [one_of: [:original, :correction, :succession, :remainder]],
      allow_nil?: false,
      public?: true

    attribute :status, :atom,
      constraints: [one_of: [:proposed, :active, :superseded, :rejected]],
      allow_nil?: false,
      public?: true
  end

  relationships do
    belongs_to :series, Veridian.Store.InputSeries, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, create: :*]
  end
end
