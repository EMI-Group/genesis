import Config

# ── Dev-only onboarding reset ────────────────────────────────────────────
# GENESIS_DEV_RESET_ONBOARDING=1 时（仅 dev 环境），每次启动前把 config.toml
# 中的 LLM 模型配置剥离（原始文件备份为 config.toml.onboarding-backup），
# 使应用以"首次配置"状态启动 —— /welcome 始终显示初始设置流程。
# 注意：runtime.exs 会被每个 mix 命令求值，所以**不做自动还原**（否则一次
# 不带环境变量的 `mix compile` 就会悄悄还原）。要恢复配置时，手动把
# config.toml.onboarding-backup 复制回 config.toml 即可。
if config_env() == :dev do
  config_dir = EvoGit.Platform.config_dir()
  config_path = Path.join(config_dir, "config.toml")
  backup_path = config_path <> ".onboarding-backup"

  # 剥离 [llm] 表中的 model/models 键以及所有 [[llm.models]] 表
  strip_llm_model_config = fn content ->
    {out, _section} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], :other}, fn line, {acc, section} ->
        trimmed = String.trim(line)

        cond do
          # [[llm.models]] 数组表及其全部子表（如 [llm.models.model]）
          String.starts_with?(trimmed, "[[llm.models") or
              String.starts_with?(trimmed, "[llm.models") ->
            {acc, :llm_models}

          trimmed == "[llm]" ->
            {acc ++ [line], :llm}

          String.starts_with?(trimmed, "[") ->
            {acc ++ [line], :other}

          section == :llm_models ->
            {acc, section}

          section == :llm and
              (String.starts_with?(trimmed, "model =") or String.starts_with?(trimmed, "models =")) ->
            {acc, section}

          true ->
            {acc ++ [line], section}
        end
      end)

    Enum.join(out, "\n")
  end

  if System.get_env("GENESIS_DEV_RESET_ONBOARDING") == "1" and File.exists?(config_path) do
    unless File.exists?(backup_path), do: File.cp!(config_path, backup_path)
    File.write!(config_path, strip_llm_model_config.(File.read!(config_path)))
  end
end

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
if System.get_env("PHX_SERVER") || Application.get_env(:evo_dash, :desktop_release, false) do
  config :evo_dash, EvoDashWeb.Endpoint, server: true
end

# ── ReqLLM HTTP Connection Pool ─────────────────────────────────────
# Dynamically size the ReqLLM Finch streaming pool to handle the **total
# LLM parallelism** across all configured model profiles. Each model gets
# its own concurrency slot pool (config.toml → [[llm.models]] → concurrency),
# so the HTTP connection pool must be sized to the SUM of all per-model
# concurrencies — otherwise concurrent stream_text/3 calls queue waiting
# for a free connection when multiple models are active simultaneously.
#
# This runs before :req_llm starts its Finch pool, so the pool is sized
# correctly at boot.
#
# ReqLLM defaults to stream_pool_count: 8 with HTTP/1-only pools. We add
# a small buffer (+2) on top of the summed concurrency for auxiliary
# (non-slot-gated) LLM calls (context compression, evolution synthesis,
# novelty metrics, etc.).
resolved = EvoGit.Config.resolve()

total_concurrency =
  case EvoGit.Config.Schema.model_profiles(resolved) do
    [] ->
      # No model profiles configured (fresh install / legacy single-model
      # config with flat [llm] fields). Fall back to scheduler.max_concurrency.
      EvoGit.Config.resolve([:scheduler, :max_concurrency])

    profiles ->
      profiles
      |> Enum.map(fn profile -> Map.get(profile, :concurrency, 3) end)
      |> Enum.sum()
  end

stream_pool_count = max(total_concurrency + 2, 8)

config :req_llm,
  stream_pool_count: stream_pool_count,
  stream_pool_size: 1,
  stream_pool_protocols: [:http1],
  stream_pool_timeout: 120_000

# The genesis_remote release is a headless evo_git-only daemon for SSH remote
# development. It has NO Phoenix/evo_dash, so SECRET_KEY_BASE and endpoint config
# are not needed. Detection uses RELEASE_NAME env var (automatically set by the
# release boot script) as the primary signal; the compile-time `remote_release`
# config flag from mix.exs serves as a secondary fallback.
if config_env() == :prod and
     not (System.get_env("RELEASE_NAME") == "genesis_remote" or
            Application.get_env(:evo_git, :remote_release, false)) do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # Desktop releases use a fixed local key (set by the Tauri sidecar via
  # SECRET_KEY_BASE env var). Fall back to the same hardcoded key so the
  # backend can still boot. This is safe for local, single-user desktop usage
  # only and is never used for real prod.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if Application.get_env(:evo_dash, :desktop_release, false) do
        "GenesisDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890"
      else
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
      end

  port =
    case System.get_env("PORT") do
      nil ->
        if Application.get_env(:evo_dash, :desktop_release, false) do
          # Desktop release: PORT env var not forwarded by the launcher — use
          # the fixed desktop port (must match Tauri WebView's localhost:9999).
          9999
        else
          EvoGit.Config.resolve([:server, :listen_port])
        end

      port_str ->
        String.to_integer(port_str)
    end

  # Detect desktop mode from two independent signals so detection is robust:
  #   1. The compile-time `:desktop_release` flag baked into sys.config by the
  #      genesis_desktop release definition in mix.exs (loaded before
  #      runtime.exs evaluates).
  #   2. The EVOGIT_DESKTOP env var set by the Tauri sidecar (sidecar.rs).
  desktop_mode =
    Application.get_env(:evo_dash, :desktop_release, false) or
      System.get_env("EVOGIT_DESKTOP") == "1"

  # In desktop mode the backend runs as a Tauri sidecar process with no
  # visible console — stdout is captured by the sidecar but the user has no
  # terminal to read it. Redirect the Erlang/Elixir logger to a rotating log
  # file in the platform data directory so logs are still accessible (e.g.
  # for debugging via the filesystem). The default_formatter configured in
  # config/config.exs is preserved — only the handler destination changes
  # from stdout to a file.
  if desktop_mode do
    log_dir = Path.join(EvoGit.Platform.data_dir(), "logs")

    case File.mkdir_p(log_dir) do
      :ok ->
        log_file_path = Path.join(log_dir, "backend.log")

        # Configure the default logger handler (:logger_std_h) to write to a
        # file instead of stdout. The file path MUST be a charlist because
        # Erlang's logger expects charlists for paths, not Elixir binaries.
        # max_no_bytes/max_no_files enable built-in log rotation (10 MB per
        # file × 5 files = 50 MB max disk usage).
        config :logger, :default_handler,
          config: [
            type: :file,
            file: String.to_charlist(log_file_path),
            max_no_bytes: 10_000_000,
            max_no_files: 5
          ]

        # Announce the log path — visible in the captured stdout, useful for
        # terminal debugging when running the backend manually.
        IO.puts("[desktop] Logging to file: #{log_file_path}")

      {:error, reason} ->
        # If the log directory can't be created (e.g. permissions issue),
        # fall back to console logging rather than crashing — the desktop app
        # must still be able to boot.
        IO.warn(
          "[desktop] Could not create log directory #{inspect(log_dir)} " <>
            "(#{inspect(reason)}); logging will fall back to console."
        )
    end
  end

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
