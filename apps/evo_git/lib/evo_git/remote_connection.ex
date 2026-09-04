defmodule EvoGit.RemoteConnection do
  @moduledoc """
  GenServer managing the lifecycle of a single SSH remote connection.

  There are two distinct operations, kept deliberately separate:

    * **Bootstrap** (`bootstrap/1`, `bootstrap/2`) — "first time setup": gets a
      `genesis_remote` release tarball onto the remote host and launches it as
      a daemon (`systemd-run --user` on Linux, `launchctl` on macOS). The
      daemon then runs independently and stays up even after the local side
      disconnects. Bootstrap does NOT connect. Bootstrap NEVER stops an
      already-running daemon without explicit user permission — see the
      `:on_running` option of `bootstrap/2`.

      The tarball comes from one of two sources:

        * **Local tarball** — when the target's `local_binary_path` is set and
          the file exists, it is uploaded via CLI `scp` (unchanged behavior).
          When set but missing, a warning is logged and bootstrap falls back
          to automatic download — a stale path should not hard-fail bootstrap
          (VS Code Remote-SSH semantics).

        * **Automatic download** (no usable `local_binary_path`) — mirrors
          VS Code Remote-SSH: bootstrap probes the remote platform
          (`uname -s && uname -m`, or the target's optional `platform` field
          when set, which skips the probe), resolves the matching release
          tarball from GitHub, and downloads it (curl on the remote host,
          falling back to wget on the remote host when curl is missing or
          fails, then to a local curl into a data-dir cache followed by
          `scp`). It then proceeds with the same extract / chmod / config-copy
          / cookie / launch steps.

  ## Bootstrap stages

  Progress is broadcast via `Phoenix.PubSub` on `"remote_connections"` as
  `{:remote_connection_status, target_id, %{bootstrap_stage: stage, ...}}`:

  Local-tarball path: `:probing_platform` → `:uploading` → `:extracting` →
  `:setting_permissions` → `:copying_config` → `:generating_cookie` →
  (`:patching_binaries` only on NixOS) → `:starting_daemon`.

  Auto-download path: `:probing_platform` → `:downloading` (→
  `:downloading_locally` when both the remote curl and wget attempts fail and
  the local fallback kicks in) → `:extracting` → `:setting_permissions` →
  `:copying_config` → `:generating_cookie` → (`:patching_binaries` only on
  NixOS) → `:starting_daemon`.

  Before any staging, bootstrap performs a silent pre-flight: it resolves the
  remote OS (the target's optional `platform` field, else one
  `uname -s && uname -m` probe) and checks whether the daemon is already
  running. When it is:

    * with `on_running: :refuse` (the default), bootstrap refuses without
      touching anything — no staging, no kill, no broadcast — and returns
      `{:error, {:daemon_running, details}}`; re-bootstrapping would stop the
      running daemon and any tasks running on it. The caller should show a
      permission dialog from this tuple;
    * with `on_running: :restart`, the `:stopping_daemon` stage is broadcast
      and the running daemon is stopped (`systemctl --user stop` on Linux,
      `launchctl unload` on macOS) before the normal staging flow starts a
      fresh daemon with the current contract.

  `:patching_binaries` is broadcast only when the remote is NixOS (Linux +
  daemon not already running + NixOS detected) and is skipped otherwise: on
  NixOS hosts the extracted release's ELF binaries are patched on the fly
  with a Nix-built `patchelf` (the glibc tarball cannot execute there without
  it). A live daemon is never patched.

    * **Connection** (`connect/1`) — establishes an SSH tunnel forwarding the
      remote distribution port to loopback, then performs Erlang distribution
      (`Node.connect/1`) to the remote node so that RPC (`:erpc.call/4`) and
      PubSub can flow over the tunnel.

  All SSH operations use CLI `ssh`/`scp` via `Port.open` — no Erlang `:ssh`
  or `:ssh_sftp` modules are used. The `ssh_target` field is just a string
  (host alias or `user@host`); port and identity file are handled by the
  user's `~/.ssh/config`.

  One `EvoGit.RemoteConnection` GenServer is started per active connection
  target (looked up / started on demand via the `EvoGit.RemoteConnection.Registry`
  and the `EvoGit.RemoteConnection.Supervisor` DynamicSupervisor).

  ## Port monitoring

  The SSH tunnel is an OS `Port` linked to this process. With
  `Process.flag(:trap_exit, true)` set in `init/1`, tunnel death arrives as a
  `{:EXIT, port, reason}` message, triggering a transition to `:error`.

  No `try/rescue` blocks are used — all fallible operations use `case`/`with`
  with non-crashing variants.
  """

  use GenServer

  require Logger

  @registry EvoGit.RemoteConnection.Registry
  @supervisor EvoGit.RemoteConnection.Supervisor
  @pubsub_topic "remote_connections"
  @heartbeat_interval_ms 10_000
  # Wait budget for the SSH tunnel to start forwarding the local port before
  # Node.connect. Measured need is ~1.5s (an `ssh -L` forward can take that
  # long to start listening on the local port); a fixed 500ms sleep made
  # Node.connect fail instantly with econnrefused on slower tunnels.
  @tunnel_wait_timeout_ms 10_000
  @tunnel_poll_interval_ms 100
  # The :connect handler can legitimately block for up to @tunnel_wait_timeout_ms
  # while the tunnel becomes ready, so the GenServer.call in connect/1 must
  # allow that budget plus headroom (a default 5s call timeout would exit with
  # :timeout while the handler is still waiting for the tunnel).
  @connect_call_timeout_ms @tunnel_wait_timeout_ms + 15_000
  @launch_receive_timeout_ms 5_000
  # 900s — bootstrap now stages the release either by uploading a local tarball
  # (scp) OR by probing the remote platform and downloading the release tarball
  # (curl then wget on the remote, with a local curl + scp fallback); both can
  # be slow.
  @bootstrap_call_timeout_ms 900_000

  # Default per-command timeout (30s). SCP gets a longer timeout.
  @cmd_timeout_ms 30_000
  @scp_timeout_ms 120_000

  # Timeout for release-tarball downloads (tens of MB) — curl then wget on the
  # remote host, or the local curl fallback. Generous to handle slow links.
  @download_timeout_ms 300_000

  # Timeout for the NixOS on-the-fly patch script (nix-build can be slow on
  # first run — cache.nixos.org). Fits comfortably inside the 900s bootstrap
  # call timeout alongside the other stages (the patch dir persists as a GC
  # root, so re-bootstrap nix-builds are instant).
  @patch_timeout_ms 600_000

  # The remote daemon always binds loopback; the SSH tunnel forwards the dist
  # port to loopback on both sides. The remote daemon is hard-pinned to port
  # 9000 (rel/genesis_remote/vm.args.eex — no code reads a
  # GENESIS_REMOTE_DIST_PORT env var). The local end of the tunnel uses a
  # dynamically-assigned free port to avoid conflicts with the local node's
  # own distribution port.
  @default_remote_dist_port 9000

  # ── State ──────────────────────────────────────────────────────────

  defstruct target: nil,
            node: nil,
            phase: :disconnected,
            ssh_tunnel_port: nil,
            tunnel_local_port: nil,
            last_error: nil,
            heartbeat_ref: nil,
            bootstrap_stage: nil

  @type phase :: :disconnected | :bootstrapping | :connecting | :connected | :error

  @type bootstrap_stage ::
          :uploading
          | :probing_platform
          | :downloading
          | :downloading_locally
          | :extracting
          | :setting_permissions
          | :stopping_daemon
          | :copying_config
          | :generating_cookie
          | :patching_binaries
          | :starting_daemon
          | nil

  @type t :: %__MODULE__{
          target: map() | nil,
          node: String.t() | nil,
          phase: phase(),
          ssh_tunnel_port: port() | nil,
          tunnel_local_port: non_neg_integer() | nil,
          last_error: String.t() | nil,
          heartbeat_ref: reference() | nil,
          bootstrap_stage: bootstrap_stage() | nil
        }

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Child spec for this GenServer.

  `restart: :transient` — a `:normal` exit (e.g. graceful disconnect via
  `handle_call(:disconnect, ...)` → `{:stop, :normal, ...}`) does NOT trigger a
  restart, so disconnects don't count toward the DynamicSupervisor's restart
  intensity. Abnormal exits still restart, preserving crash recovery.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @doc """
  Starts a connection manager for the given target map.

  Registered under `#{inspect(@registry)}` with key `target.id`.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(target) do
    GenServer.start_link(__MODULE__, target, name: via(target.id))
  end

  @doc """
  Initiates a connection to the remote daemon for the given `target_id`.

  Looks up the target via `EvoGit.RemoteConnections.get/1`, finds-or-starts the
  connection manager GenServer, then requests a connection.

  Returns `{:ok, :connected}` on success or `{:error, reason}`.
  """
  @spec connect(String.t()) :: {:ok, :connected} | {:error, term()}
  def connect(target_id) do
    with {:ok, target} <- fetch_target(target_id),
         {:ok, pid} <- ensure_started(target) do
      GenServer.call(pid, :connect, @connect_call_timeout_ms)
    end
  end

  @doc """
  Gracefully disconnects from (and stops) the connection manager for
  `target_id`.

  Closes the SSH tunnel port, disconnects the remote Erlang node, and stops the
  GenServer. Returns `:ok` even when no manager exists (graceful no-op).
  """
  @spec disconnect(String.t()) :: :ok
  def disconnect(target_id) do
    call_registered(target_id, :disconnect, :ok)
  end

  @doc """
  Returns the status of the connection manager for `target_id`.

  When no manager exists, returns the disconnected default:

      %{phase: :disconnected, node: nil, last_error: nil, target: nil}
  """
  @spec status(String.t()) :: map()
  def status(target_id) do
    call_registered(target_id, :status, %{
      phase: :disconnected,
      node: nil,
      last_error: nil,
      target: nil
    })
  end

  @doc """
  Returns `true` if the connection manager for `target_id` is connected.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(target_id) do
    case status(target_id) do
      %{phase: :connected} -> true
      _ -> false
    end
  end

  @doc """
  Lists the status of every active connection manager as a map of
  `target_id => status_map`.
  """
  @spec list_connections() :: %{String.t() => map()}
  def list_connections do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {target_id, pid} ->
      # Justified try/catch :exit: we iterate Registry entries whose processes
      # may terminate concurrently (e.g. another caller invoked disconnect/1).
      # This is a concurrency boundary, not error masking — a GenServer that
      # exits between Registry.select and our call is expected during teardown.
      if Process.alive?(pid) do
        try do
          [{target_id, GenServer.call(pid, :status)}]
        catch
          :exit, _ -> []
        end
      else
        []
      end
    end)
    |> Map.new()
  end

  @doc """
  Executes the bootstrap process ONLY (stage the `genesis_remote` release +
  launch daemon).

  Does NOT connect. Looks up the target, finds-or-starts the manager, then
  performs the first-time setup using CLI `scp`/`ssh` and — when no usable
  `local_binary_path` is set — automatic platform probing + release download.

  Delegates to `bootstrap/2` with the default `on_running: :refuse`: a daemon
  that is already running is never stopped without explicit permission.

  Returns `{:ok, :daemon_started}` on success or `{:error, reason}`.
  """
  @spec bootstrap(String.t()) :: {:ok, :daemon_started} | {:error, term()}
  def bootstrap(target_id) do
    bootstrap(target_id, [])
  end

  @doc """
  Executes the bootstrap process ONLY (stage the `genesis_remote` release +
  launch daemon), with options.

  Same as `bootstrap/1` plus the `:on_running` option. Before any staging a
  silent pre-flight resolves the remote OS and checks whether the daemon is
  already running:

    * `:on_running: :refuse` (default) — when the remote daemon is already
      running, refuse without touching anything: no staging, no kill, no
      broadcast. Returns `{:error, {:daemon_running, details}}` where
      `details` is a human-readable explanation. The caller should ask the
      user for permission and, if granted, re-invoke with
      `on_running: :restart`.
    * `:on_running: :restart` — stop the running daemon first (broadcasting
      the `:stopping_daemon` stage via `systemctl --user stop` on Linux /
      `launchctl unload` on macOS), then proceed with the normal staging +
      fresh-daemon flow.
    * Any other value behaves as `:refuse` (a warning is logged for unknown
      values).

  Returns `{:ok, :daemon_started}` on success or `{:error, reason}`.
  """
  @spec bootstrap(String.t(), keyword()) :: {:ok, :daemon_started} | {:error, term()}
  def bootstrap(target_id, opts) do
    with {:ok, target} <- fetch_target(target_id),
         {:ok, pid} <- ensure_started(target) do
      # 900s timeout — staging the release (upload or download) can be slow.
      GenServer.call(pid, {:bootstrap, opts}, @bootstrap_call_timeout_ms)
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def init(target) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{target: target, node: remote_node_name(target)}}
  end

  @impl true
  def handle_call(:connect, _from, %__MODULE__{} = state) do
    case do_connect(state) do
      {:ok, new_state} ->
        {:reply, {:ok, :connected}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:bootstrap, opts}, _from, %__MODULE__{} = state) do
    case do_bootstrap(state, opts) do
      {:ok, new_state} ->
        {:reply, {:ok, :daemon_started}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply, status_map(state), state}
  end

  def handle_call(:disconnect, _from, %__MODULE__{} = state) do
    {:stop, :normal, :ok, cleanup(state)}
  end

  @impl true
  def handle_info(:heartbeat, %__MODULE__{phase: :connected} = state) do
    remote = String.to_atom(state.node)

    if remote in Node.list() do
      ref = schedule_heartbeat()
      {:noreply, %{state | heartbeat_ref: ref}}
    else
      Logger.warning("RemoteConnection: heartbeat lost node #{state.node}")
      new_state = transition_to_error(state, "heartbeat: remote node #{state.node} is down")
      {:noreply, new_state}
    end
  end

  def handle_info(:heartbeat, state) do
    # Heartbeat received while not connected — stale timer, ignore.
    {:noreply, state}
  end

  def handle_info({:EXIT, port, reason}, %__MODULE__{ssh_tunnel_port: port} = state) do
    Logger.warning("RemoteConnection: ssh tunnel port exited: #{inspect(reason)}")

    new_state =
      case state.phase do
        :connected ->
          transition_to_error(state, "ssh tunnel closed: #{inspect(reason)}")

        _ ->
          %{state | ssh_tunnel_port: nil}
      end

    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, _status}}, %__MODULE__{ssh_tunnel_port: port} = state) do
    # Tunnel exit status — the {:EXIT, ...} handler manages state transitions.
    {:noreply, state}
  end

  def handle_info({port, {:data, _data}}, state) when is_port(port) do
    # Port output (ssh stderr, etc.) — ignored.
    {:noreply, state}
  end

  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Connection ─────────────────────────────────────────────────────

  defp do_connect(%__MODULE__{} = state) do
    if node() == :nonode@nohost do
      # Auto-enable distribution on-demand instead of failing.
      case EvoGit.Distribution.enable_for_remote(state.target) do
        :ok ->
          do_connect_distributed(state)

        {:error, reason} ->
          {:error, {:distribution_failed, reason}, state}
      end
    else
      do_connect_distributed(state)
    end
  end

  defp do_connect_distributed(%__MODULE__{} = state) do
    target = state.target
    connecting = %{state | phase: :connecting}

    # Set the distribution cookie to match the remote daemon.
    # Read from the persisted config; auto-generated during bootstrap.
    config = EvoGit.Config.resolve()
    node_cookie = get_in(config, [:node, :cookie])

    case node_cookie do
      nil ->
        Logger.warning(
          "No distribution cookie configured. Run bootstrap first to auto-generate one. " <>
            "Node.set_cookie/1 skipped — connection may fail."
        )

      "" ->
        Logger.warning(
          "Distribution cookie is empty. Run bootstrap first to auto-generate one. " <>
            "Node.set_cookie/1 skipped — connection may fail."
        )

      cookie when is_binary(cookie) ->
        Node.set_cookie(String.to_atom(cookie))
    end

    # Remote port: the port the remote daemon actually listens on.
    remote_port = Map.get(target, :dist_port) || @default_remote_dist_port

    # Find a free local port for the SSH tunnel so we never conflict with
    # the local node's own Erlang distribution port.
    case find_free_port() do
      {:ok, local_port} ->
        cmd = build_tunnel_command(target, local_port, remote_port)
        port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stream])

        # Give the SSH tunnel time to establish: poll the local forwarded port
        # for TCP readiness (bounded) instead of a fixed sleep — `ssh -L` can
        # take well over a second to start listening, and a too-early
        # Node.connect fails instantly with econnrefused.
        case wait_for_tunnel(port, local_port, @tunnel_wait_timeout_ms,
               poll_interval: @tunnel_poll_interval_ms
             ) do
          :ok ->
            # Register the SSH tunnel's local port with our EPMD-less module so
            # that when Node.connect asks port_please for this node name, EpmdDist
            # returns local_port (which the SSH tunnel forwards to remote_port 9000).
            node_name = remote_node_name(target)
            EvoGit.EpmdDist.register_target(node_name, local_port)

            # The node name is just name@host — NO port suffix. The port is
            # resolved by EpmdDist.port_please/2 via the registration above.
            remote_node = String.to_atom(node_name)

            case Node.connect(remote_node) do
              true ->
                ref = schedule_heartbeat()

                new_state = %__MODULE__{
                  connecting
                  | phase: :connected,
                    ssh_tunnel_port: port,
                    tunnel_local_port: local_port,
                    node: Atom.to_string(remote_node),
                    heartbeat_ref: ref,
                    last_error: nil
                }

                broadcast_status(state.target, new_state)
                {:ok, new_state}

              result when result in [false, :ignored] ->
                EvoGit.EpmdDist.unregister_target(node_name)
                close_port(port)
                reason = {:node_connect_failed, inspect(remote_node)}

                diagnostics =
                  node_connect_failed_diagnostics(node_name, local_port, remote_port, node_cookie)

                Logger.error("Remote connection to #{node_name} failed: #{diagnostics}")
                new_state = %{connecting | phase: :error, last_error: diagnostics}
                {:error, reason, new_state}
            end

          {:error, reason} ->
            close_port(port)
            error = {:tunnel_not_ready, reason}
            new_state = %{connecting | phase: :error, last_error: format_error(error)}
            {:error, error, new_state}
        end

      {:error, reason} ->
        new_state = %{connecting | phase: :error, last_error: format_error(reason)}
        {:error, reason, new_state}
    end
  end

  # ── Bootstrap ──────────────────────────────────────────────────────

  # Entry point for the bootstrap GenServer call. Silent pre-flight BEFORE any
  # staging: resolve the daemon OS (target `platform` override, else one
  # `uname -s && uname -m` probe — no broadcast yet), then check whether the
  # daemon is already running. When it is: `on_running: :refuse` (default)
  # refuses without touching anything (no staging, no kill, no broadcast —
  # the caller shows a permission dialog from the {:daemon_running, details}
  # tuple); `on_running: :restart` broadcasts the :stopping_daemon stage,
  # stops the daemon, then proceeds with the normal staging flow (which
  # starts a fresh daemon with the current contract).
  defp do_bootstrap(%__MODULE__{} = state, opts) do
    on_running = normalize_on_running(Keyword.get(opts, :on_running, :refuse))
    target = state.target
    ssh_target = target.ssh_target

    case resolve_platform(target, ssh_target) do
      {:ok, daemon_os, platform} ->
        if daemon_running?(ssh_target, daemon_os, target) do
          case on_running do
            :refuse ->
              # State returned EXACTLY as received — no mutation, no broadcast.
              {:error, {:daemon_running, daemon_running_details(target)}, state}

            :restart ->
              # :stopping_daemon stage, then stop the daemon, then stage a
              # fresh one with the current contract. A failed stop is
              # non-fatal — the start below surfaces any real failure.
              state = set_stage(%{state | phase: :bootstrapping}, target, :stopping_daemon)
              stop_daemon(ssh_target, daemon_os, target)
              do_bootstrap_staging(state, target, daemon_os, platform)
          end
        else
          do_bootstrap_staging(state, target, daemon_os, platform)
        end

      {:error, reason} ->
        error_state = error_state(state, target, reason)
        {:error, reason, error_state}
    end
  end

  # Picks the staging path based on local_binary_path, threaded with the
  # pre-flight-resolved daemon_os (and platform for the auto-download path,
  # which needs it for the asset URL).
  defp do_bootstrap_staging(%__MODULE__{} = state, target, daemon_os, platform) do
    local_path = Map.get(target, :local_binary_path)

    cond do
      is_binary(local_path) and local_path != "" and File.exists?(local_path) ->
        do_bootstrap_with_tarball(state, target, local_path, daemon_os)

      is_binary(local_path) and local_path != "" ->
        # Set-but-missing: warn and fall back to auto-download (VS Code
        # Remote-SSH semantics — a stale path shouldn't hard-fail bootstrap).
        Logger.warning(
          "RemoteConnection: local_binary_path #{inspect(local_path)} does not exist; " <>
            "falling back to automatic download of the genesis_remote release."
        )

        do_bootstrap_auto(state, target, daemon_os, platform)

      true ->
        do_bootstrap_auto(state, target, daemon_os, platform)
    end
  end

  # Normalizes the :on_running option. Only :restart is special; every other
  # value (including unknown atoms/strings) behaves as :refuse, with a warning
  # logged for unknown values.
  defp normalize_on_running(:restart), do: :restart
  defp normalize_on_running(:refuse), do: :refuse
  defp normalize_on_running(nil), do: :refuse

  defp normalize_on_running(other) do
    Logger.warning(
      "RemoteConnection: unknown on_running value #{inspect(other)}; treating as :refuse"
    )

    :refuse
  end

  defp do_bootstrap_with_tarball(%__MODULE__{} = state, target, local_path, daemon_os) do
    %{
      ssh_target: ssh_target,
      remote_tarball: remote_tarball,
      remote_dir: remote_dir,
      launcher_path: launcher_path
    } = remote_paths(target)

    # :probing_platform stage — the pre-flight probe already resolved the OS,
    # but the stage is the visible "we probed" marker and keeps the two paths'
    # stage sequences aligned.
    state = set_stage(%{state | phase: :bootstrapping}, target, :probing_platform)
    state = set_stage(state, target, :uploading)

    case scp_tarball(ssh_target, local_path, remote_tarball) do
      :ok ->
        launch_after_staging(
          state,
          target,
          ssh_target,
          daemon_os,
          launcher_path,
          remote_dir,
          remote_tarball
        )

      {:error, reason} ->
        error_state = error_state(state, target, reason)
        {:error, reason, error_state}
    end
  end

  # Auto-download bootstrap path (no usable local_binary_path): download the
  # tarball for the pre-flight-resolved platform (curl then wget on the remote,
  # local curl + scp fallback) → launch via the shared post-staging sequence.
  defp do_bootstrap_auto(%__MODULE__{} = state, target, daemon_os, platform) do
    %{
      ssh_target: ssh_target,
      remote_tarball: remote_tarball,
      remote_dir: remote_dir,
      launcher_path: launcher_path
    } = remote_paths(target)

    # :probing_platform stage — the pre-flight probe already resolved the OS,
    # but the stage is the visible "we probed" marker and keeps the two paths'
    # stage sequences aligned.
    state = set_stage(%{state | phase: :bootstrapping}, target, :probing_platform)
    state = set_stage(state, target, :downloading)

    case download_tarball(state, target, ssh_target, platform, remote_tarball) do
      {:ok, state} ->
        launch_after_staging(
          state,
          target,
          ssh_target,
          daemon_os,
          launcher_path,
          remote_dir,
          remote_tarball
        )

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # Resolves the remote platform. Uses the target's optional `platform` field
  # (skipping the SSH probe entirely) when set; otherwise probes the remote
  # via SSH. Returns {:ok, daemon_os, platform} where daemon_os is the
  # canonical "Linux" | "Darwin" string used by the launcher functions. Asset
  # selection is handled by EvoGit.RemoteBootstrap — glibc is the default and
  # only published Linux variant, so tarball names are never suffixed.
  defp resolve_platform(target, ssh_target) do
    case Map.get(target, :platform) do
      platform when is_binary(platform) and platform != "" ->
        with {:ok, %{os: _os, arch: _arch}} <- EvoGit.RemoteBootstrap.parse_platform(platform),
             {:ok, daemon_os} <- EvoGit.RemoteBootstrap.daemon_os(platform) do
          {:ok, daemon_os, platform}
        end

      _ ->
        with {:ok, daemon_os, platform} <- probe_platform(ssh_target) do
          {:ok, daemon_os, platform}
        end
    end
  end

  # Probes the remote OS + architecture via a single SSH call
  # (`uname -s && uname -m`). Returns {:ok, daemon_os, platform} or
  # {:error, reason}.
  defp probe_platform(ssh_target) do
    case run_ssh_command(ssh_target, "uname -s && uname -m", @cmd_timeout_ms) do
      {:ok, output, 0} ->
        case String.split(String.trim(output), "\n") do
          [os, arch] ->
            with {:ok, platform} <-
                   EvoGit.RemoteBootstrap.parse_uname(String.trim(os), String.trim(arch)),
                 {:ok, daemon_os} <- EvoGit.RemoteBootstrap.daemon_os(platform) do
              {:ok, daemon_os, platform}
            end

          _ ->
            {:error, {:probe_failed, {:unexpected_output, String.trim(output)}}}
        end

      {:ok, _output, status} ->
        {:error, {:probe_failed, {:exit_status, status}}}

      :timeout ->
        {:error, {:probe_failed, :timeout}}
    end
  end

  # Downloads the release tarball for the platform to the remote temp path.
  # Primary: curl directly on the remote host (with a wget fallback when curl
  # is missing or fails). Fallback: curl locally into the data-dir cache, then
  # scp to the remote temp path. Returns
  # {:ok, state} | {:error, reason, state}.
  defp download_tarball(state, target, ssh_target, platform, remote_tarball) do
    # download_url/1 is deterministic — always the direct Cloudflare-worker
    # "smart download" URL (https://genesis.evox.group/dl/...), which proxies
    # the latest GitHub release asset; version is always "latest" and keys the
    # local cache. Names are never suffixed (glibc is the default and only
    # published Linux variant; the musl build is disabled for now).
    {:ok, url, version} = EvoGit.RemoteBootstrap.download_url(platform)

    case download_on_remote(ssh_target, url, remote_tarball) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning(
          "RemoteConnection: remote curl/wget download failed (#{inspect(reason)}); " <>
            "falling back to local download + scp."
        )

        local_state = set_stage(state, target, :downloading_locally)

        case download_locally_and_scp(ssh_target, url, platform, version, remote_tarball) do
          :ok ->
            {:ok, local_state}

          {:error, reason} ->
            error_state = error_state(local_state, target, reason)
            {:error, reason, error_state}
        end
    end
  end

  # Downloads the tarball directly on the remote host — `curl -fL` first, with
  # a `wget -O` fallback when curl is missing (default Ubuntu installs ship
  # without curl) or fails. wget follows redirects by default (matching curl
  # -L) and exits non-zero on HTTP errors (matching curl -f). Only reports a
  # download failure when BOTH tools fail on the remote.
  defp download_on_remote(ssh_target, url, remote_tarball) do
    case run_remote_download(ssh_target, "curl", "-fL -o #{remote_tarball} #{url}") do
      :ok ->
        :ok

      _ ->
        Logger.info(
          "RemoteConnection: remote curl download failed; retrying with wget on the remote host."
        )

        run_remote_download(ssh_target, "wget", "-O #{remote_tarball} #{url}")
    end
  end

  # Runs a single downloader invocation (`curl` or `wget`) on the remote host
  # via ssh and maps the result to :ok | {:error, {:download_failed, ...}}.
  defp run_remote_download(ssh_target, tool, args) do
    case run_ssh_command(ssh_target, "#{tool} #{args}", @download_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:download_failed, {:exit_status, status}}}
      :timeout -> {:error, {:download_failed, :timeout}}
    end
  end

  # Fallback download: curls the tarball into a cache file under the platform
  # data dir (reusing a cached copy when present), then scps it to the remote
  # temp path.
  defp download_locally_and_scp(ssh_target, url, platform, version, remote_tarball) do
    cache_file = EvoGit.RemoteBootstrap.cache_path(platform, version)

    case download_locally(cache_file, url) do
      :ok ->
        case scp_tarball(ssh_target, cache_file, remote_tarball) do
          :ok -> :ok
          {:error, reason} -> {:error, {:download_failed, {:local_scp, reason}}}
        end

      {:error, reason} ->
        {:error, {:download_failed, {:local, reason}}}
    end
  end

  # Curls the tarball into the local cache file. Reuses the file when present.
  defp download_locally(cache_file, url) do
    if File.exists?(cache_file) do
      :ok
    else
      case File.mkdir_p(Path.dirname(cache_file)) do
        :ok ->
          cmd = "curl -fL -o #{cache_file} #{url}"

          case run_cmd(cmd, @download_timeout_ms) do
            {:ok, _output, 0} -> :ok
            {:ok, _output, status} -> {:error, {:exit_status, status}}
            :timeout -> {:error, :timeout}
          end

        {:error, reason} ->
          {:error, {:mkdir_failed, reason}}
      end
    end
  end

  # Runs the post-staging launch sequence shared by both bootstrap paths:
  # extract → chmod → config copy → cookie → (NixOS patch) → daemon start →
  # health verify. `os` is the daemon OS resolved during pre-flight (probed or
  # platform override) — `:detecting_os` no longer exists as a stage.
  defp launch_after_staging(
         %__MODULE__{} = state,
         target,
         ssh_target,
         os,
         launcher_path,
         remote_dir,
         remote_tarball
       ) do
    with {:ok, state} <-
           run_stage(state, target, :extracting, fn ->
             extract_tarball(ssh_target, remote_tarball, remote_dir)
           end),
         {:ok, state} <-
           run_stage(state, target, :setting_permissions, fn ->
             chmod_executable(ssh_target, launcher_path)
           end),
         {:ok, state} <-
           run_stage(state, target, :copying_config, fn ->
             copy_config_to_remote(ssh_target, os)
           end) do
      # :generating_cookie stage — the cookie is generated right after the
      # stage broadcast so the resolved value reaches the launch steps below.
      state = set_stage(state, target, :generating_cookie)
      cookie = ensure_cookie!()

      # NixOS on-the-fly patching (Linux only; skipped when the daemon is
      # already running or the remote is not NixOS). Broadcasts
      # :patching_binaries only when the patch actually runs.
      case maybe_patch_nixos(state, target, ssh_target, os, launcher_path) do
        {:ok, state} ->
          case maybe_start_daemon(ssh_target, launcher_path, os, target, cookie, state) do
            :ok ->
              EvoGit.RemoteConnections.touch(target.id)
              completed = %{state | phase: :disconnected, bootstrap_stage: nil}
              broadcast_status(target, completed)
              {:ok, completed}

            {:error, reason} ->
              {:error, reason, error_state(state, target, reason)}
          end

        {:error, reason} ->
          {:error, reason, error_state(state, target, reason)}
      end
    else
      {:error, reason, err_state} -> {:error, reason, err_state}
    end
  end

  # Runs a single staging step under its broadcast stage marker: sets +
  # broadcasts the stage, runs the step fun, and returns {:ok, state} on
  # success or {:error, reason, error_state} on failure (the error_state is
  # built from the stage-set state, exactly like the original inline error
  # arms).
  defp run_stage(state, target, stage, fun) do
    state = set_stage(state, target, stage)

    case fun.() do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, error_state(state, target, reason)}
    end
  end

  # Constructs the error state, broadcasts it, and returns it.
  defp error_state(state, target, reason) do
    error_state = %{state | phase: :error, bootstrap_stage: nil, last_error: format_error(reason)}
    broadcast_status(target, error_state)
    error_state
  end

  # Resolves the remote paths shared by both staging paths. The tarball is
  # uploaded to a temp path, then extracted into remote_path's parent (the
  # tarball contains a top-level genesis_remote/ directory).
  defp remote_paths(target) do
    ssh_target = target.ssh_target
    remote_path = Map.get(target, :remote_path) || "/tmp/genesis_remote"
    remote_tarball = remote_tarball_path(remote_path)
    remote_dir = Path.dirname(remote_path)
    launcher_path = Path.join(remote_path, "bin/genesis_remote")

    %{
      ssh_target: ssh_target,
      remote_tarball: remote_tarball,
      remote_dir: remote_dir,
      launcher_path: launcher_path
    }
  end

  # Computes the temp tarball path on the remote from the remote_path.
  defp remote_tarball_path(remote_path) do
    "#{remote_path}.tar.xz"
  end

  # SCPs the local tarball to the remote temp path.
  defp scp_tarball(ssh_target, local_path, remote_tarball) do
    cmd = "scp #{local_path} #{ssh_target}:#{remote_tarball}"

    case run_cmd(cmd, @scp_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:scp_failed, status}}
      :timeout -> {:error, {:scp_failed, :timeout}}
    end
  end

  # Extracts the uploaded tarball on the remote host.
  defp extract_tarball(ssh_target, remote_tarball, extract_dir) do
    case run_ssh_command(
           ssh_target,
           "mkdir -p #{extract_dir} && tar -xJf #{remote_tarball} -C #{extract_dir}",
           @scp_timeout_ms
         ) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:extract_failed, status}}
      :timeout -> {:error, {:extract_failed, :timeout}}
    end
  end

  # Sets the remote launcher executable via `ssh <target> 'chmod +x <path>'`.
  defp chmod_executable(ssh_target, launcher_path) do
    case run_ssh_command(ssh_target, "chmod +x #{launcher_path}", @cmd_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:chmod_failed, status}}
      :timeout -> {:error, {:chmod_failed, :timeout}}
    end
  end

  # Copies local config.toml and credentials.toml to the remote host.
  # Best-effort: missing local files are skipped; copy errors are logged but
  # do not fail the bootstrap (the daemon boots fine without config).
  # Files that already exist on the remote are NOT overwritten.
  defp copy_config_to_remote(ssh_target, os) do
    remote_config_dir = remote_config_dir(os)

    # Ensure the remote config directory exists.
    run_ssh_command(ssh_target, "mkdir -p #{remote_config_dir}", @cmd_timeout_ms)

    for path <- [EvoGit.Config.config_path(), EvoGit.Config.credentials_path()] do
      if File.exists?(path) do
        remote_file = Path.join(remote_config_dir, Path.basename(path))

        if remote_file_exists?(ssh_target, remote_file) do
          # The remote already has this file; don't overwrite.
          :ok
        else
          cmd = "scp #{path} #{ssh_target}:#{remote_file}"

          case run_cmd(cmd, @cmd_timeout_ms) do
            {:ok, _output, 0} -> :ok
            _ -> Logger.warning("Failed to copy #{Path.basename(path)} to remote; continuing.")
          end
        end
      end
    end

    :ok
  end

  # Computes the remote config directory for a given OS. Mirrors the
  # platform logic in `EvoGit.Config.config_dir/0`.
  defp remote_config_dir("Darwin") do
    Path.join(["~", "Library", "Application Support", "genesis"])
  end

  defp remote_config_dir(_os) do
    Path.join("~/.config", "genesis")
  end

  # Checks whether a file exists on the remote host.
  defp remote_file_exists?(ssh_target, remote_file) do
    case run_ssh_command(
           ssh_target,
           "test -f #{remote_file} && echo yes || echo no",
           @cmd_timeout_ms
         ) do
      {:ok, output, 0} -> String.trim(output) == "yes"
      _ -> false
    end
  end

  # Race safety net after the pre-flight gate: checks if the daemon is running
  # and starts it only if not. A daemon may legitimately start between the
  # pre-flight check in do_bootstrap/2 and this launch point (another
  # bootstrap, a manual start), so the running-daemon decision is re-checked
  # here — this function is no longer the primary running-daemon decision.
  # When the daemon IS running, its launch identity (RELEASE_NODE/RELEASE_COOKIE
  # — fixed at launch time) is verified against the current contract before
  # declaring success: a daemon launched by an older bootstrap (stale cookie)
  # or started manually would otherwise silently "succeed" and then fail every
  # connect. A mismatch is NOT auto-repaired (the running daemon may serve an
  # old session; a plain `restart` re-runs the old unit Environment without
  # fixing the cookie) — it fails loudly with remediation. The :starting_daemon
  # stage is broadcast only on the start path — an already-running,
  # identity-matching daemon completes without any broadcast.
  defp maybe_start_daemon(ssh_target, launcher_path, os, target, cookie, state) do
    if daemon_running?(ssh_target, os, target) do
      case verify_daemon_identity(ssh_target, os, target, cookie) do
        :ok -> :ok
        {:error, _reason} = error -> error
      end
    else
      # :starting_daemon stage — broadcast only on the start path.
      set_stage(state, target, :starting_daemon)

      case start_daemon(ssh_target, launcher_path, os, target, cookie) do
        :ok -> verify_daemon_healthy(ssh_target, os, target)
        {:error, _} = error -> error
      end
    end
  end

  # On-the-fly NixOS support: the genesis_remote release is a glibc-linked
  # tarball that cannot execute on NixOS hosts (no /lib64/ld-linux-x86-64.so.2).
  # For Linux remotes whose daemon is not already running, detect NixOS (one
  # SSH round trip) and — when detected — patch the extracted release's ELF
  # binaries with a Nix-built patchelf, mirroring the NixOS vscode-remote-ssh
  # extension patch pattern. A live daemon is NEVER patched; non-Linux hosts
  # are untouched. Returns {:ok, state} (patched or skipped) or
  # {:error, {:nixos_patch_failed, details}}.
  defp maybe_patch_nixos(state, target, ssh_target, "Linux", launcher_path) do
    if daemon_running?(ssh_target, "Linux", target) do
      {:ok, state}
    else
      case run_ssh_command(
             ssh_target,
             EvoGit.RemoteBootstrap.nixos_detect_command(),
             @cmd_timeout_ms
           ) do
        {:ok, output, 0} ->
          if nixos_detected?(output) do
            # :patching_binaries stage — broadcast only when the patch actually runs
            state = set_stage(state, target, :patching_binaries)
            run_patch_script(state, ssh_target, launcher_path)
          else
            {:ok, state}
          end

        {:ok, output, status} ->
          details = "NixOS detection failed: ssh exit #{status}: #{tail_of(output, 500)}"
          {:error, {:nixos_patch_failed, details}}

        :timeout ->
          {:error, {:nixos_patch_failed, "NixOS detection failed: timeout"}}
      end
    end
  end

  defp maybe_patch_nixos(state, _target, _ssh_target, _os, _launcher_path) do
    {:ok, state}
  end

  # Runs the NixOS patch script in a single SSH round trip — the whole script
  # is ONE argv element (never quote-wrapped, never {:spawn, String}) so the
  # remote shell interprets it. The bootstrap stage stays :patching_binaries
  # through the run; failures propagate with the failing step's stdout tail.
  defp run_patch_script(state, ssh_target, launcher_path) do
    script = EvoGit.RemoteBootstrap.nixos_patch_script(launcher_path)

    case run_ssh_command(ssh_target, script, @patch_timeout_ms) do
      {:ok, _output, 0} ->
        {:ok, state}

      {:ok, output, status} ->
        details = "patch script failed (exit #{status}): #{tail_of(output, 500)}"
        {:error, {:nixos_patch_failed, details}}

      :timeout ->
        {:error, {:nixos_patch_failed, "patch script timed out after #{@patch_timeout_ms} ms"}}
    end
  end

  # The detection command prints `yes` (NixOS) or `no` (not NixOS). Due to
  # shell `&&`/`||` left-associativity the /etc/nixos branch echoes `yes`
  # twice — the contains-check is robust against both forms.
  defp nixos_detected?(output) do
    String.contains?(String.trim(output), "yes")
  end

  # Last ~n characters of trimmed output — the failing step's stdout.
  defp tail_of(output, n) do
    String.slice(String.trim(output), -n, n)
  end

  # Checks if the genesis-remote daemon is already running on the remote.
  defp daemon_running?(ssh_target, "Linux", target) do
    unit = "genesis-remote-#{target.id}"

    case run_ssh_command(
           ssh_target,
           "systemctl --user is-active #{unit} 2>/dev/null",
           @cmd_timeout_ms
         ) do
      {:ok, output, _status} -> String.trim(output) == "active"
      :timeout -> false
    end
  end

  defp daemon_running?(ssh_target, "Darwin", target) do
    label = "com.genesis.remote.#{target.id}"

    case run_ssh_command(
           ssh_target,
           "launchctl list #{label} 2>/dev/null",
           @cmd_timeout_ms
         ) do
      {:ok, output, _status} -> String.trim(output) != ""
      :timeout -> false
    end
  end

  # Human-readable details for the {:daemon_running, details} refusal returned
  # when bootstrap is called with on_running: :refuse while the daemon is
  # already running. The caller (dashboard) shows a permission dialog from
  # this tuple.
  defp daemon_running_details(target) do
    "the remote daemon genesis-remote-#{target.id} is already running; " <>
      "re-bootstrapping would stop it and any tasks running on it — " <>
      "call bootstrap with on_running: :restart to proceed"
  end

  # Stops a running daemon on the remote. Only reached when bootstrap was
  # called with on_running: :restart — the user explicitly permitted stopping
  # it. Best-effort: a failed stop is logged as a warning and bootstrap
  # continues (the subsequent start surfaces any real failure); the
  # :stopping_daemon stage broadcast is kept regardless.
  defp stop_daemon(ssh_target, "Linux", target) do
    unit = "genesis-remote-#{target.id}"

    case run_ssh_command(ssh_target, "systemctl --user stop #{unit}", @cmd_timeout_ms) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        Logger.warning(
          "RemoteConnection: failed to stop daemon unit #{unit} (exit #{status}): " <>
            tail_of(output, 500)
        )

        :ok

      :timeout ->
        Logger.warning("RemoteConnection: timed out stopping daemon unit #{unit}")
        :ok
    end
  end

  defp stop_daemon(ssh_target, "Darwin", target) do
    label = "com.genesis.remote.#{target.id}"
    remote_plist = "~/Library/LaunchAgents/#{label}.plist"

    case run_ssh_command(ssh_target, "launchctl unload #{remote_plist}", @cmd_timeout_ms) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        Logger.warning(
          "RemoteConnection: failed to unload launchd plist #{label} (exit #{status}): " <>
            tail_of(output, 500)
        )

        :ok

      :timeout ->
        Logger.warning("RemoteConnection: timed out unloading launchd plist #{label}")
        :ok
    end
  end

  defp stop_daemon(_ssh_target, os, target) do
    Logger.warning(
      "RemoteConnection: cannot stop daemon for unsupported OS #{inspect(os)} " <>
        "(target #{target.id}); continuing bootstrap"
    )

    :ok
  end

  # Verifies a RUNNING daemon's launch identity matches the current contract:
  # RELEASE_NODE = remote_node_name(target) and RELEASE_COOKIE = the `cookie`
  # arg (the same value `ensure_cookie!` persisted and `start_daemon` passed at
  # launch). One SSH round trip. Returns :ok (matches) or
  # {:error, {:daemon_identity_mismatch, details}} where details is a
  # plain-string actionable message. Missing keys, differing values, empty
  # output (stale daemon, no env) and :timeout are all mismatches.
  defp verify_daemon_identity(ssh_target, "Linux", target, cookie) do
    unit = "genesis-remote-#{target.id}"
    expected_node = remote_node_name(target)

    case run_ssh_command(
           ssh_target,
           "systemctl --user show #{unit} -p Environment --value",
           @cmd_timeout_ms
         ) do
      {:ok, output, _status} ->
        env = EvoGit.RemoteBootstrap.parse_unit_environment(output)
        found_node = Map.get(env, "RELEASE_NODE")
        found_cookie = Map.get(env, "RELEASE_COOKIE")

        if found_node == expected_node and found_cookie == cookie do
          :ok
        else
          {:error,
           {:daemon_identity_mismatch,
            unit_env_mismatch_details(unit, found_node, found_cookie, expected_node, cookie)}}
        end

      :timeout ->
        {:error,
         {:daemon_identity_mismatch,
          "could not verify the running daemon's launch identity for unit #{unit} " <>
            "(`systemctl --user show` timed out). The daemon may be from an older " <>
            "bootstrap — stop it with `systemctl --user stop #{unit}` (a plain " <>
            "`restart` re-runs the old unit Environment and does NOT help) and " <>
            "re-run bootstrap."}}
    end
  end

  defp verify_daemon_identity(ssh_target, "Darwin", target, cookie) do
    label = "com.genesis.remote.#{target.id}"
    expected_node = remote_node_name(target)

    case run_ssh_command(
           ssh_target,
           "cat ~/Library/LaunchAgents/#{label}.plist",
           @cmd_timeout_ms
         ) do
      {:ok, output, _status} ->
        # The deployed plist is generated by write_launchd_plist/3, so string
        # containment of the expected RELEASE_NODE/RELEASE_COOKIE values is
        # reliable.
        if String.contains?(output, "<string>#{expected_node}</string>") and
             String.contains?(output, "<string>#{cookie}</string>") do
          :ok
        else
          {:error,
           {:daemon_identity_mismatch,
            "the running daemon's launchd plist (#{label}) does not carry the " <>
              "current RELEASE_NODE/RELEASE_COOKIE — it was launched by an older " <>
              "bootstrap or started manually. Unload it with " <>
              "`launchctl unload ~/Library/LaunchAgents/#{label}.plist` and re-run " <>
              "bootstrap."}}
        end

      :timeout ->
        {:error,
         {:daemon_identity_mismatch,
          "could not verify the running daemon's launch identity for label #{label} " <>
            "(plist read timed out). The daemon may be from an older bootstrap — " <>
            "unload it with `launchctl unload ~/Library/LaunchAgents/#{label}.plist` " <>
            "and re-run bootstrap."}}
    end
  end

  defp verify_daemon_identity(_ssh_target, _os, _target, _cookie) do
    # Unknown OS — do not block bootstrap for unsupported platforms.
    :ok
  end

  # Builds the plain-string mismatch details for the Linux unit check: what was
  # found vs expected, plus the exact remediation.
  defp unit_env_mismatch_details(unit, found_node, found_cookie, expected_node, expected_cookie) do
    "the running daemon's systemd unit #{unit} reports " <>
      "RELEASE_NODE=#{env_value_or_missing(found_node)} and " <>
      "RELEASE_COOKIE=#{env_value_or_missing(found_cookie)}, but the current " <>
      "contract requires RELEASE_NODE=#{expected_node} and " <>
      "RELEASE_COOKIE=#{expected_cookie}. The daemon was launched by an older " <>
      "bootstrap or started manually; stop it with `systemctl --user stop #{unit}` " <>
      "(a plain `restart` re-runs the old unit Environment and does NOT help), " <>
      "then re-run bootstrap."
  end

  defp env_value_or_missing(nil), do: "(missing)"
  defp env_value_or_missing(""), do: "(empty)"
  defp env_value_or_missing(value), do: value
  # Verifies the daemon reached 'active' state after launch. Retries a few
  # times with a short delay so the BEAM VM has time to boot. Returns :ok or
  # {:error, {:daemon_not_healthy, details}}.
  defp verify_daemon_healthy(ssh_target, os, target) do
    case wait_daemon_active(ssh_target, os, 3, 1000, target) do
      :ok ->
        :ok

      :not_active ->
        details = fetch_daemon_status(ssh_target, os, target)
        {:error, {:daemon_not_healthy, details}}
    end
  end

  defp wait_daemon_active(_ssh_target, _os, 0, _delay, _target), do: :not_active

  defp wait_daemon_active(ssh_target, os, attempts, delay, target) do
    Process.sleep(delay)

    if daemon_running?(ssh_target, os, target) do
      :ok
    else
      wait_daemon_active(ssh_target, os, attempts - 1, delay, target)
    end
  end

  # Fetches diagnostic status output for inclusion in the error reason.
  defp fetch_daemon_status(ssh_target, "Linux", target) do
    unit = "genesis-remote-#{target.id}"

    case run_ssh_command(
           ssh_target,
           "systemctl --user status #{unit} 2>&1 | tail -20",
           @cmd_timeout_ms
         ) do
      {:ok, output, _status} -> String.trim(output)
      :timeout -> "status unavailable (timeout)"
    end
  end

  defp fetch_daemon_status(_ssh_target, "Darwin", target) do
    label = "com.genesis.remote.#{target.id}"
    "daemon not active after launch (macOS launchctl, label: #{label})"
  end

  defp fetch_daemon_status(_ssh_target, os, _target) do
    "daemon not active after launch (os: #{os})"
  end

  # Starts the daemon on the remote.
  # Linux: systemd-run --user --unit=genesis-remote-<target_id> --setenv=RELEASE_NODE=<node> --setenv=RELEASE_COOKIE=<cookie> <launcher_path> start
  # macOS: write launchd plist (per-target label), scp it, load it via launchctl.
  defp start_daemon(ssh_target, launcher_path, "Linux", target, cookie) do
    unit = "genesis-remote-#{target.id}"
    node = remote_node_name(target)

    # Clear any stale failed/inactive unit so systemd-run can create a fresh one.
    # reset-failed is idempotent: exits 0 if nothing to clear, non-zero if unit
    # never existed — both are acceptable here.
    run_ssh_command(
      ssh_target,
      "systemctl --user reset-failed #{unit} 2>/dev/null; true",
      @cmd_timeout_ms
    )

    case run_ssh_command(
           ssh_target,
           "systemd-run --user --unit=#{unit} --setenv=RELEASE_NODE=#{node} --setenv=RELEASE_COOKIE=#{cookie} #{launcher_path} start",
           @launch_receive_timeout_ms
         ) do
      {:ok, _output, 0} ->
        :ok

      {:ok, _output, status} ->
        {:error, {:daemon_launch_failed, status}}

      :timeout ->
        # systemd-run may keep the SSH channel open; assume success.
        :ok
    end
  end

  defp start_daemon(ssh_target, launcher_path, "Darwin", target, cookie) do
    plist_path = write_launchd_plist(launcher_path, target, cookie)

    if plist_path == nil do
      {:error, {:daemon_launch_failed, :plist_write_failed}}
    else
      result = deploy_launchd_plist(ssh_target, plist_path, target)
      File.rm(plist_path)
      result
    end
  end

  # Writes the launchd plist to a local temp file. Returns the path or nil.
  defp write_launchd_plist(launcher_path, target, cookie) do
    label = "com.genesis.remote.#{target.id}"
    node = remote_node_name(target)

    plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>#{label}</string>
        <key>ProgramArguments</key>
        <array>
            <string>#{launcher_path}</string>
            <string>start</string>
        </array>
        <key>EnvironmentVariables</key>
        <dict>
            <key>RELEASE_NODE</key>
            <string>#{node}</string>
            <key>RELEASE_COOKIE</key>
            <string>#{cookie}</string>
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
    </plist>
    """

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "genesis-remote-plist-#{System.unique_integer([:positive])}.plist"
      )

    case File.write(tmp_path, plist) do
      :ok -> tmp_path
      {:error, _reason} -> nil
    end
  end

  # SCPs the plist to ~/Library/LaunchAgents/ and loads it via launchctl.
  defp deploy_launchd_plist(ssh_target, plist_path, target) do
    label = "com.genesis.remote.#{target.id}"
    remote_plist = "~/Library/LaunchAgents/#{label}.plist"

    scp_cmd = "scp #{plist_path} #{ssh_target}:#{remote_plist}"

    with {:ok, _output, 0} <- run_cmd(scp_cmd, @scp_timeout_ms) do
      case run_ssh_command(
             ssh_target,
             "launchctl unload #{remote_plist} 2>/dev/null; launchctl load #{remote_plist}",
             @cmd_timeout_ms
           ) do
        {:ok, _output, 0} -> :ok
        {:ok, _output, status} -> {:error, {:daemon_launch_failed, status}}
        :timeout -> {:error, {:daemon_launch_failed, :timeout}}
      end
    else
      {:ok, _output, status} -> {:error, {:daemon_launch_failed, {:scp_plist, status}}}
      :timeout -> {:error, {:daemon_launch_failed, {:scp_plist, :timeout}}}
    end
  end

  # ── State transitions / cleanup ────────────────────────────────────

  # Shared teardown: cancels the heartbeat timer, disconnects the remote node,
  # and closes the SSH tunnel port — in that order — returning the state with
  # the teardown-tracked fields reset.
  defp teardown(%__MODULE__{} = state) do
    cancel_heartbeat(state.heartbeat_ref)
    disconnect_node(state.node)
    close_port(state.ssh_tunnel_port)

    %__MODULE__{
      state
      | ssh_tunnel_port: nil,
        tunnel_local_port: nil,
        heartbeat_ref: nil
    }
  end

  defp transition_to_error(%__MODULE__{} = state, error_msg) do
    new_state = %{teardown(state) | phase: :error, last_error: error_msg}
    broadcast_status(state.target, new_state)
    new_state
  end

  defp cleanup(%__MODULE__{} = state) do
    new_state = %{teardown(state) | phase: :disconnected}
    broadcast_status(state.target, new_state)
    new_state
  end

  # ── Command runner ─────────────────────────────────────────────────

  # Runs a command via Port.open and collects stdout output, waiting for the
  # exit status. Returns {:ok, output, exit_status} or :timeout.
  #
  # The port is linked to this process (trap_exit is set in init/1), but we
  # explicitly receive data and exit_status messages rather than relying on
  # EXIT messages, so we can collect stdout.
  defp run_cmd(cmd, timeout) do
    port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stream])
    collect_port_output(port, timeout, "")
  end

  # Runs a REMOTE command over SSH by passing it as a single argv element to
  # the `ssh` executable (`{:spawn_executable, ...}` — no local shell
  # involved). Remote commands must NEVER be wrapped in single/double quotes
  # inside a `{:spawn, String}`: on Windows the CRT argv parser only consumes
  # DOUBLE quotes, so single quotes travel to ssh.exe and the remote shell
  # parses the whole quoted string as ONE command name ("No such file or
  # directory"); on Unix spawn strings go through `/bin/sh -c`, so double
  # quotes would trigger local `$` expansion. OpenSSH joins its argv entries
  # with single spaces and the remote shell re-parses them, preserving the
  # command verbatim.
  #
  # Because OpenSSH executes the command via the REMOTE user's login shell
  # (`$SHELL -c "<command>"`), the command is additionally wrapped as
  # `/usr/bin/env bash -c '<escaped>'` by `EvoGit.RemoteBootstrap.bash_wrap/1`
  # (single quotes escaped as `'\''`), so it executes under bash regardless of
  # the remote login shell — fixing the NixOS bootstrap failure where a fish
  # login shell rejects the POSIX `VAR=...` assignments in the patch script at
  # parse time. This is safe for all commands: the remote commands used here
  # (incl. the NixOS patch script, which contains `$`, `$(...)` and single
  # quotes) are POSIX-ish scripts that bash parses identically.
  @doc false
  def run_ssh_command(ssh_target, remote_cmd, timeout) do
    ssh = System.find_executable("ssh") || "ssh"
    remote_cmd = EvoGit.RemoteBootstrap.bash_wrap(remote_cmd)

    port =
      Port.open(
        {:spawn_executable, ssh},
        [:binary, :exit_status, :stream, {:args, [ssh_target, remote_cmd]}]
      )

    collect_port_output(port, timeout, "")
  end

  defp collect_port_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, timeout, acc <> data)

      {^port, {:exit_status, status}} ->
        close_port(port)
        {:ok, acc, status}
    after
      timeout ->
        close_port(port)
        :timeout
    end
  end

  # ── Command builders ───────────────────────────────────────────────

  defp build_tunnel_command(target, local_port, remote_port) do
    ssh_target = target.ssh_target

    parts =
      [
        "ssh",
        "-L #{local_port}:127.0.0.1:#{remote_port}",
        "-N",
        "-o ServerAliveInterval=30",
        "-o ServerAliveCountMax=3",
        ssh_target
      ]

    Enum.join(parts, " ")
  end

  # ── Port utilities ─────────────────────────────────────────────────

  @doc """
  Finds a free TCP port on loopback by binding to port 0 and reading the
  assigned port number.

  Returns `{:ok, port}` or `{:error, reason}`.
  """
  @spec find_free_port() :: {:ok, non_neg_integer()} | {:error, term()}
  def find_free_port do
    case :gen_tcp.listen(0, [:inet, {:ip, {127, 0, 0, 1}}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, reason} ->
        {:error, {:port_bind_failed, reason}}
    end
  end

  # Waits (bounded) for the SSH tunnel's local forwarded port to accept TCP
  # connections, so Node.connect doesn't race the `ssh -L` startup.
  #
  # Polls `local_port` every `poll_interval` ms (opts, default 100) until a
  # TCP connect succeeds — the probe socket is closed immediately, which the
  # `ssh -N` forward handles gracefully. Fails fast when the tunnel Port
  # dies: `Port.info/1` returning nil (works regardless of the caller's
  # trap_exit flag), a received `{:exit_status, status}`, or a received
  # `{:EXIT, port, reason}` (only delivered to trap_exit processes). Port
  # output (`{port, {:data, data}}`) is drained into the error reason so ssh
  # stderr is available for diagnosability.
  #
  # Returns `:ok` | `{:error, reason}`:
  #
  #   * `{:ssh_exited, status_or_reason, ssh_output}` — tunnel port died early
  #   * `{:timeout, ssh_output}` — budget exhausted, port still alive
  #
  # `@doc false`: public only so tests can drive it directly with tiny
  # timeouts; it is an implementation detail of `do_connect_distributed/1`.
  @doc false
  @spec wait_for_tunnel(port(), :inet.port_number(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def wait_for_tunnel(port, local_port, timeout_ms, opts \\ []) do
    poll_interval = Keyword.get(opts, :poll_interval, 100)
    wait_for_tunnel(port, local_port, timeout_ms, poll_interval, "")
  end

  defp wait_for_tunnel(port, local_port, remaining_ms, poll_interval, ssh_output) do
    if Port.info(port) == nil do
      {:error, {:ssh_exited, :port_info_nil, ssh_output}}
    else
      case tcp_ready?(local_port) do
        :ok ->
          :ok

        :not_ready ->
          wait = min(poll_interval, remaining_ms)

          receive do
            {^port, {:data, data}} ->
              wait_for_tunnel(port, local_port, remaining_ms, poll_interval, ssh_output <> data)

            {^port, {:exit_status, status}} ->
              {:error, {:ssh_exited, status, ssh_output}}

            {:EXIT, ^port, reason} ->
              {:error, {:ssh_exited, reason, ssh_output}}
          after
            wait ->
              remaining = remaining_ms - wait

              if remaining <= 0 do
                {:error, {:timeout, ssh_output}}
              else
                wait_for_tunnel(port, local_port, remaining, poll_interval, ssh_output)
              end
          end
      end
    end
  end

  defp tcp_ready?(local_port) do
    case :gen_tcp.connect({127, 0, 0, 1}, local_port, [:inet, :binary, {:active, false}], 250) do
      {:ok, socket} ->
        # Readiness probe — close immediately, we only need to know the
        # forwarded port is accepting connections.
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        :not_ready
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp remote_node_name(target) do
    "genesis_remote_#{target.id}@127.0.0.1"
  end

  # ── Cookie helpers ──────────────────────────────────────────────────

  # Generates a cryptographically secure random cookie string.
  #
  # Uses `:crypto.strong_rand_bytes/1` (32 bytes = 64 hex chars) suitable
  # for Erlang distribution authentication.
  defp generate_secure_cookie do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  # Ensures a distribution cookie exists in the user config.
  #
  # 1. Resolves the current config via `EvoGit.Config.resolve()`
  # 2. Checks `get_in(config, [:node, :cookie])` — if non-nil and non-empty, return it
  # 3. If nil/empty: generates a secure cookie, merges it into the resolved config,
  #    and persists via `EvoGit.Config.save_user_config/1`
  # 4. Raises `RuntimeError` if save fails — bootstrap must NOT proceed without a persisted cookie
  defp ensure_cookie! do
    config = EvoGit.Config.resolve()

    case get_in(config, [:node, :cookie]) do
      nil ->
        generate_and_persist_cookie!(config)

      "" ->
        generate_and_persist_cookie!(config)

      cookie when is_binary(cookie) ->
        cookie
    end
  end

  defp generate_and_persist_cookie!(config) do
    new_cookie = generate_secure_cookie()
    updated = put_in(config, [:node, :cookie], new_cookie)

    case EvoGit.Config.save_user_config(updated) do
      :ok ->
        Logger.info("Generated and persisted new secure distribution cookie")
        new_cookie

      {:error, reason} ->
        raise RuntimeError,
              "Failed to persist generated distribution cookie: #{inspect(reason)}. " <>
                "Bootstrap cannot proceed without a persisted cookie."
    end
  end

  defp via(target_id) do
    {:via, Registry, {@registry, target_id}}
  end

  # Justified try/catch :exit: concurrency boundary — the GenServer may
  # terminate between Registry.lookup and the call (e.g. supervisor teardown
  # with reason :shutdown, or another caller invoked disconnect/1). A call to
  # a dying process is expected during teardown and should not crash the
  # caller; it degrades gracefully instead of masking an unexpected error.
  defp call_registered(target_id, request, default) do
    case Registry.lookup(@registry, target_id) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          try do
            GenServer.call(pid, request)
          catch
            :exit, _ -> default
          end
        else
          default
        end

      [] ->
        default
    end
  end

  defp fetch_target(target_id) do
    case EvoGit.RemoteConnections.get(target_id) do
      {:ok, target} -> {:ok, target}
      {:error, :not_found} -> {:error, :target_not_found}
    end
  end

  defp ensure_started(target) do
    target_id = target.id

    case Registry.lookup(@registry, target_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, target}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp status_map(%__MODULE__{} = state) do
    %{
      phase: state.phase,
      node: state.node,
      last_error: state.last_error,
      target: state.target,
      bootstrap_stage: state.bootstrap_stage
    }
  end

  defp broadcast_status(nil, _state), do: :ok

  defp broadcast_status(target, state) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      @pubsub_topic,
      {:remote_connection_status, target.id, status_map(state)}
    )
  end

  # Updates the bootstrap stage and broadcasts the new status, returning the
  # updated state. Every stage transition goes through here so the update +
  # broadcast ordering stays consistent.
  defp set_stage(state, target, stage) do
    state = %{state | bootstrap_stage: stage}
    broadcast_status(target, state)
    state
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp cancel_heartbeat(nil), do: :ok

  defp cancel_heartbeat(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp disconnect_node(nil), do: :ok

  defp disconnect_node(node_name) do
    remote = String.to_atom(node_name)
    Node.disconnect(remote)
    :ok
  end

  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end

  defp format_error(reason) do
    inspect(reason)
  end

  # Builds an actionable multi-line diagnostics string for a failed
  # Node.connect — assigned to `last_error` (what the dashboard's connection
  # gate renders) and logged via Logger.error. The public reason tuple stays
  # {:node_connect_failed, inspect(remote_node)} — no caller destructures the
  # inner tuple, and the reason shape is part of the public contract.
  defp node_connect_failed_diagnostics(node_name, local_port, remote_port, node_cookie) do
    cookie_status =
      cond do
        is_binary(node_cookie) and node_cookie != "" ->
          "set (#{String.slice(node_cookie, 0, 6)}...)"

        true ->
          "not set — run bootstrap first to auto-generate one"
      end

    """
    Could not connect to remote Erlang node #{node_name}.
      Tunnel:       127.0.0.1:#{local_port} -> 127.0.0.1:#{remote_port}
      Local cookie: #{cookie_status}
    The daemon's RELEASE_NODE/RELEASE_COOKIE are fixed at LAUNCH time. If they differ
    from your local config.toml [node] cookie, the daemon is stale — compare with:
      ssh <target> 'systemctl --user show genesis-remote-<id> -p Environment'   (Linux)
      cat ~/Library/LaunchAgents/com.genesis.remote.<id>.plist                  (macOS)
    Stop the stale daemon (`systemctl --user stop genesis-remote-<id>` / launchctl unload)
    and re-run bootstrap. If the target's dist_port was edited away from 9000, the tunnel
    forwards to a dead remote port — the daemon is hard-pinned to 9000.
    """
  end
end
