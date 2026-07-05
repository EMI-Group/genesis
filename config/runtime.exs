import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/evo_dash start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :evo_dash, EvoDashWeb.Endpoint, server: true
end

# ── ReqLLM HTTP Connection Pool ─────────────────────────────────────
# Dynamically size the ReqLLM Finch streaming pool based on the user's
# configured LLM concurrency (config.toml → [scheduler] max_concurrency).
# This runs before :req_llm starts its Finch pool, so the pool is sized
# correctly at boot.
#
# ReqLLM defaults to stream_pool_count: 8 with HTTP/1-only pools. When
# max_concurrency exceeds that, the default pool becomes a bottleneck:
# concurrent stream_text/3 calls queue waiting for a free connection.
# We size the pool to match the configured concurrency plus a small buffer
# for auxiliary (non-slot-gated) LLM calls (context compression, evolution
# synthesis, etc.).
max_concurrency = EvoGit.Config.resolve([:scheduler, :max_concurrency])
stream_pool_count = max(max_concurrency + 2, 8)

config :req_llm,
  stream_pool_count: stream_pool_count,
  stream_pool_size: 1,
  stream_pool_protocols: [:http1],
  stream_pool_timeout: 120_000

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  port =
    case System.get_env("PORT") do
      nil -> EvoGit.Config.resolve([:server, :listen_port])
      port_str -> String.to_integer(port_str)
    end

  # Detect desktop mode from two independent signals so detection is robust
  # against env var forwarding issues through the Burrito Zig wrapper:
  #   1. The compile-time `:desktop_release` flag baked into sys.config by the
  #      genesis_desktop release definition in mix.exs (loaded before
  #      runtime.exs evaluates).
  #   2. The EVOGIT_DESKTOP env var set by the Tauri sidecar (sidecar.rs).
  desktop_mode =
    Application.get_env(:evo_dash, :desktop_release, false) or
      System.get_env("EVOGIT_DESKTOP") == "1"

  # Bind address for the desktop server. Defaults to loopback (localhost only)
  # so the dashboard is never exposed to the network without explicit opt-in.
  # Priority: PHX_IP env var → config.toml [server] listen_ip → loopback default.
  desktop_ip_str =
    System.get_env("PHX_IP") || EvoGit.Config.resolve([:server, :listen_ip])

  desktop_ip =
    case :inet.parse_address(String.to_charlist(desktop_ip_str)) do
      {:ok, ip} ->
        ip

      {:error, _} ->
        IO.warn(
          "Invalid listen IP #{inspect(desktop_ip_str)}, falling back to loopback (127.0.0.1)"
        )

        {127, 0, 0, 1}
    end

  if desktop_mode do
    # Desktop mode: local single-user server accessed via Tauri WebView.
    # check_origin is disabled because the WebView connects over plain HTTP
    # to localhost, which would otherwise be rejected by Phoenix's origin check.
    # The bind address defaults to loopback (127.0.0.1) for security; set
    # PHX_IP to expose the server on other interfaces (e.g. for remote access).
    config :evo_dash, EvoDashWeb.Endpoint,
      url: [host: "localhost", port: port, scheme: "http"],
      http: [
        ip: desktop_ip,
        port: port
      ],
      check_origin: false,
      secret_key_base: secret_key_base
  else
    host = System.get_env("PHX_HOST") || "example.com"

    config :evo_dash, EvoDashWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        # Enable IPv6 and bind on all interfaces.
        # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
        # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
        # for details about using IPv6 vs IPv4 and loopback vs public addresses.
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: port
      ],
      secret_key_base: secret_key_base
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :evo_dash, EvoDashWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :evo_dash, EvoDashWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
