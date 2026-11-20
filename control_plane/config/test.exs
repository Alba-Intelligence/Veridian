import Config

# The test database is a throwaway cluster that `veridian-test` starts outside
# the synced tree and reaches over a unix socket (no TCP port, no password).
# Pool settings follow the spike (docs/design/local-measurements.md): durable
# commits can stall for seconds under I/O pressure, so the pool must not shed
# load on a 50 ms queue target.
config :veridian, Veridian.Repo,
  socket_dir: System.get_env("VERIDIAN_PG_SOCKET_DIR", "/tmp"),
  port: String.to_integer(System.get_env("VERIDIAN_PG_PORT", "55432")),
  username: System.get_env("USER", "postgres"),
  database: "veridian_test",
  pool_size: 10,
  timeout: 300_000,
  queue_target: 60_000,
  queue_interval: 120_000

# Matches the Quint model's instance (calc_graph_fixed: MAX_ATTEMPTS = 2);
# production defaults to 3 (spec 02 config).
config :veridian, max_attempts: 2

config :logger, level: :warning
