import Config
config :firstmate_port, :public_url, "http://localhost:4002"
config :firstmate_port, Oban, testing: :inline
config :firstmate_port, FirstmatePort.NATS.Connection, enabled: false, replicas: 1

config :firstmate_port, FirstmatePort.Vault, key: "Zmlyc3RtYXRlLXBvcnQgdGVzdCB2YXVsdCBrZXkgISE="

config :firstmate_port, FirstmatePort.Auth.Guardian,
  issuer: "firstmate_port",
  secret_key: "test-guardian-secret-not-for-prod",
  ttl: {1, :hour}

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :firstmate_port, FirstmatePort.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "firstmate_port_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :firstmate_port, FirstmatePortWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IW8Kv49BJkjM3u+46Ua4DapgSy1BpwMHLDnQl3nwSySf9jb4pYIuDhuAwgG/Bi/N",
  server: false

# In test we don't send emails
config :firstmate_port, FirstmatePort.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
