# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :evo_dash,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :evo_dash, EvoDashWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EvoDashWeb.ErrorHTML, json: EvoDashWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EvoDash.PubSub,
  live_view: [signing_salt: "KUBoevuK"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  evo_dash: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/evo_dash/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  evo_dash: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/evo_dash", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# EvoGit configuration
config :evo_git,
  max_concurrency: 3,
  max_retries: 15,
  agent_max_retries: 3,
  max_agent_depth: 5,
  llm_model: "zai_coding_plan:glm-5",
  compression_threshold_tokens: 100_000

# config/config.exs
config :req_llm,
  # HTTP timeouts (all values in milliseconds)
  # Default response timeout
  receive_timeout: 600_000,
  # Streaming metadata collection timeout
  metadata_timeout: 600_000,
  # Extended timeout for reasoning models
  thinking_timeout: 1_000_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
