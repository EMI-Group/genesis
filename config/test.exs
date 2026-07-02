import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :evo_dash, EvoDashWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vCv3gpepylQQ9k01zsQNk7fFVtFbYc7zdD43FTMQ5o/kuulG43J9n1aaTRIPXrJ6",
  server: false

# Capture Logger output during tests; logs are only shown when a test fails.
# This keeps test output clean while preserving diagnostics on failure.
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
