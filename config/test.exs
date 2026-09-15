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

# Use a temporary directory for the SQLite database in tests.
# This is the primary isolation mechanism — it ensures tests NEVER
# write to the production database (~/.local/share/genesis/tasks.sqlite).
# The XDG_DATA_HOME redirect in test_helper.exs serves as a belt-and-suspenders
# fallback, but this config key is the canonical guard.
#
# The directory is UNIQUE PER BEAM (OS pid + a positive unique integer) so
# concurrent `mix test` runs — sibling Genesis worker worktrees on one machine,
# or a CI shard — can never share the same tasks.sqlite and contaminate each
# other's whole-table assertions. Both apps in one umbrella run share the single
# unique dir (intended); only cross-run isolation is added. Each run's
# after_suite hook removes ONLY its own dir, never the shared parent.
#
# NOTE: Store and TaskRegistry were migrated from evo_dash to evo_git, so the
# key must be :evo_git (the Store reads Application.get_env(:evo_git, :data_dir)).
# This app-env override must stay ABOVE any file-config fallback (it is the test
# isolation guard — no user/TOML `[data] dir` value may shadow it).
config :evo_git,
       :data_dir,
       Path.join(
         System.tmp_dir!(),
         "evogit_test_data/genesis-#{System.pid()}-#{:erlang.unique_integer([:positive])}"
       )

# SystemSampler tick disabled in tests (the sampler's own test suite manages its interval)
config :evo_git, :system_sample_interval_ms, 86_400_000

# Short stuck-finalizing watchdog grace (1 minute) so tests exercise the watchdog fast
config :evo_git, :finalizing_watchdog_grace_minutes, 1

# Never open a real wx directory dialog during tests (a modal native dialog
# would block the suite). test_helper.exs sets the same flag as a
# belt-and-suspenders fallback; the picker module short-circuits on it.
config :evo_dash, :directory_picker, enabled: false
