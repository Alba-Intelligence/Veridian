import Config

config :veridian,
  ecto_repos: [Veridian.Repo],
  ash_domains: [Veridian.Store]

# Counts unicode codepoints, as SQL data layers do (Ash's recommended setting).
config :ash, default_string_length_count: :codepoints

# Only the test environment has a database configuration so far.
env_config = Path.join(__DIR__, "#{config_env()}.exs")
if File.exists?(env_config), do: import_config(env_config)
