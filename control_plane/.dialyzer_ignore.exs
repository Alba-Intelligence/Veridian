# Each entry needs a reason. An unnecessary entry is reported by dialyxir
# ("Unnecessary Skips"), so this list cannot silently grow stale.
[
  # `use AshPostgres.Repo` generates all_tenants/0, which raises unless the
  # application overrides it (multitenancy is not used here, D-072).
  {"lib/veridian/repo.ex", :no_return}
]
