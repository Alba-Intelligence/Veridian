defmodule Veridian.Repo do
  @moduledoc "The ledger's PostgreSQL repo (D-014, D-072)."
  # The ash-functions SQL helpers (atomics, `||`) are not installed: the ledger
  # applies its own locked read-modify-write steps and needs none of them.
  use AshPostgres.Repo, otp_app: :veridian, warn_on_missing_ash_functions?: false

  @impl true
  def installed_extensions, do: []

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
