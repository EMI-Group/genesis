defmodule EvoGit.RemoteConnection do
  @moduledoc """
  GenServer managing the lifecycle of a single SSH remote connection.

  There are two distinct operations, kept deliberately separate:

    * **Bootstrap** (`bootstrap/1`) — "first time setup": pushes the local
      `genesis_remote` tarball to the remote host via CLI `scp`, extracts it
      on the remote, sets the launcher executable via `ssh chmod +x`, detects
      the remote OS, and launches it as a daemon (`systemd-run --user` on
      Linux, `launchctl` on macOS). The daemon then runs independently and
      stays up even after the local side disconnects. Bootstrap does NOT
      connect.

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
  @tunnel_settle_ms 500
  @launch_receive_timeout_ms 5_000
  @bootstrap_call_timeout_ms 120_000

  # Default per-command timeout (30s). SCP gets a longer timeout.
  @cmd_timeout_ms 30_000
  @scp_timeout_ms 120_000

  # The remote daemon always binds loopback; the SSH tunnel forwards the dist
  # port to loopback on both sides. The remote daemon listens on port 9000 by
  # default (hardcoded in rel/genesis_remote/vm.args.eex, overridable via
  # GENESIS_REMOTE_DIST_PORT env var). The local end of the tunnel uses a
  # dynamically-assigned free port to avoid conflicts with the local node's
  # own distribution port.
  @remote_node_base "genesis_remote@127.0.0.1"
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

  @type bootstrap_stage :: :uploading | :extracting | :setting_permissions | :detecting_os | :starting_daemon | nil

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
      GenServer.call(pid, :connect)
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
    call_registered(target_id, :status, %{phase: :disconnected, node: nil, last_error: nil, target: nil})
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
  Executes the bootstrap process ONLY (upload tarball + launch daemon).

  Does NOT connect. Looks up the target, finds-or-starts the manager, then
  performs the first-time setup using CLI `scp` and `ssh`.

  Returns `{:ok, :daemon_started}` on success or `{:error, reason}`.
  """
  @spec bootstrap(String.t()) :: {:ok, :daemon_started} | {:error, term()}
  def bootstrap(target_id) do
    with {:ok, target} <- fetch_target(target_id),
         {:ok, pid} <- ensure_started(target) do
      # 120s timeout — tarball upload via scp can be slow.
      GenServer.call(pid, :bootstrap, @bootstrap_call_timeout_ms)
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def init(target) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{target: target, node: @remote_node_base}}
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

  def handle_call(:bootstrap, _from, %__MODULE__{} = state) do
    case do_bootstrap(state) do
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
    cookie =
      System.get_env("RELEASE_COOKIE", "genesis_remote_cookie")
      |> String.to_atom()

    Node.set_cookie(cookie)

    # Remote port: the port the remote daemon actually listens on.
    remote_port = Map.get(target, :dist_port) || @default_remote_dist_port

    # Find a free local port for the SSH tunnel so we never conflict with
    # the local node's own Erlang distribution port.
    case find_free_port() do
      {:ok, local_port} ->
        cmd = build_tunnel_command(target, local_port, remote_port)
        port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stream])

        # Give the SSH tunnel time to establish.
        Process.sleep(@tunnel_settle_ms)

        # Register the SSH tunnel's local port with our EPMD-less module so
        # that when Node.connect asks port_please for this node name, EpmdDist
        # returns local_port (which the SSH tunnel forwards to remote_port 9000).
        EvoGit.EpmdDist.register_target(@remote_node_base, local_port)

        # The node name is just name@host — NO port suffix. The port is
        # resolved by EpmdDist.port_please/2 via the registration above.
        remote_node = :"#{@remote_node_base}"

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
            EvoGit.EpmdDist.unregister_target(@remote_node_base)
            close_port(port)
            reason = {:node_connect_failed, inspect(remote_node)}
            new_state = %{connecting | phase: :error, last_error: format_error(reason)}
            {:error, reason, new_state}
        end

      {:error, reason} ->
        new_state = %{connecting | phase: :error, last_error: format_error(reason)}
        {:error, reason, new_state}
    end
  end

  # ── Bootstrap ──────────────────────────────────────────────────────

  defp do_bootstrap(%__MODULE__{} = state) do
    target = state.target
    local_path = Map.get(target, :local_binary_path)

    cond do
      is_nil(local_path) or local_path == "" ->
        {:error, :no_tarball_path, state}

      not File.exists?(local_path) ->
        {:error, :tarball_not_found, state}

      true ->
        do_bootstrap_with_tarball(state, target, local_path)
    end
  end

  defp do_bootstrap_with_tarball(%__MODULE__{} = state, target, local_path) do
    ssh_target = target.ssh_target
    remote_path = Map.get(target, :remote_path) || "/tmp/genesis_remote"

    # The tarball is uploaded to a temp path, then extracted into remote_path's
    # parent. The tarball contains a top-level genesis_remote/ directory.
    remote_tarball = remote_tarball_path(remote_path)
    remote_dir = Path.dirname(remote_path)
    launcher_path = Path.join(remote_path, "bin/genesis_remote")

    # :uploading stage
    state = %{state | phase: :bootstrapping, bootstrap_stage: :uploading}
    broadcast_status(target, state)

    case scp_tarball(ssh_target, local_path, remote_tarball) do
      :ok ->
        # :extracting stage
        state = %{state | bootstrap_stage: :extracting}
        broadcast_status(target, state)

        case extract_tarball(ssh_target, remote_tarball, remote_dir) do
          :ok ->
            # :setting_permissions stage
            state = %{state | bootstrap_stage: :setting_permissions}
            broadcast_status(target, state)

            case chmod_executable(ssh_target, launcher_path) do
              :ok ->
                # :detecting_os stage
                state = %{state | bootstrap_stage: :detecting_os}
                broadcast_status(target, state)

                case detect_os(ssh_target) do
                  {:ok, os} ->
                    # :starting_daemon stage
                    state = %{state | bootstrap_stage: :starting_daemon}
                    broadcast_status(target, state)

                    case maybe_start_daemon(ssh_target, launcher_path, os) do
                      :ok ->
                        EvoGit.RemoteConnections.touch(target.id)
                        completed = %{state | phase: :disconnected, bootstrap_stage: nil}
                        broadcast_status(target, completed)
                        {:ok, completed}

                      {:error, reason} ->
                        error_state = error_state(state, target, reason)
                        {:error, reason, error_state}
                    end

                  {:error, reason} ->
                    error_state = error_state(state, target, reason)
                    {:error, reason, error_state}
                end

              {:error, reason} ->
                error_state = error_state(state, target, reason)
                {:error, reason, error_state}
            end

          {:error, reason} ->
            error_state = error_state(state, target, reason)
            {:error, reason, error_state}
        end

      {:error, reason} ->
        error_state = error_state(state, target, reason)
        {:error, reason, error_state}
    end
  end

  # Constructs the error state, broadcasts it, and returns it.
  defp error_state(state, target, reason) do
    error_state = %{state | phase: :error, bootstrap_stage: nil, last_error: format_error(reason)}
    broadcast_status(target, error_state)
    error_state
  end

  # Computes the temp tarball path on the remote from the remote_path.
  defp remote_tarball_path(remote_path) do
    "#{remote_path}.tar.gz"
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
    cmd = "ssh #{ssh_target} 'mkdir -p #{extract_dir} && tar -xzf #{remote_tarball} -C #{extract_dir}'"

    case run_cmd(cmd, @scp_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:extract_failed, status}}
      :timeout -> {:error, {:extract_failed, :timeout}}
    end
  end

  # Sets the remote launcher executable via `ssh <target> 'chmod +x <path>'`.
  defp chmod_executable(ssh_target, launcher_path) do
    cmd = "ssh #{ssh_target} 'chmod +x #{launcher_path}'"

    case run_cmd(cmd, @cmd_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:chmod_failed, status}}
      :timeout -> {:error, {:chmod_failed, :timeout}}
    end
  end

  # Detects the remote OS via `ssh <target> 'uname -s'`.
  # Returns {:ok, "Linux"} or {:ok, "Darwin"} or {:error, :unsupported_os, os}.
  defp detect_os(ssh_target) do
    cmd = "ssh #{ssh_target} 'uname -s'"

    case run_cmd(cmd, @cmd_timeout_ms) do
      {:ok, output, 0} ->
        os = String.trim(output)

        cond do
          os == "Linux" -> {:ok, "Linux"}
          os == "Darwin" -> {:ok, "Darwin"}
          true -> {:error, {:unsupported_os, os}}
        end

      {:ok, _output, status} ->
        {:error, {:unsupported_os, {:exit_status, status}}}

      :timeout ->
        {:error, {:unsupported_os, :timeout}}
    end
  end

  # Checks if the daemon is already running; starts it only if not.
  defp maybe_start_daemon(ssh_target, launcher_path, os) do
    if daemon_running?(ssh_target, os) do
      :ok
    else
      start_daemon(ssh_target, launcher_path, os)
    end
  end

  # Checks if the genesis-remote daemon is already running on the remote.
  defp daemon_running?(ssh_target, "Linux") do
    cmd = "ssh #{ssh_target} 'systemctl --user is-active genesis-remote 2>/dev/null'"

    case run_cmd(cmd, @cmd_timeout_ms) do
      {:ok, output, _status} -> String.trim(output) == "active"
      :timeout -> false
    end
  end

  defp daemon_running?(ssh_target, "Darwin") do
    cmd = "ssh #{ssh_target} 'launchctl list com.genesis.remote 2>/dev/null'"

    case run_cmd(cmd, @cmd_timeout_ms) do
      {:ok, output, _status} -> String.trim(output) != ""
      :timeout -> false
    end
  end

  # Starts the daemon on the remote.
  # Linux: systemd-run --user --unit=genesis-remote <launcher_path> start
  # macOS: write launchd plist, scp it, load it via launchctl.
  defp start_daemon(ssh_target, launcher_path, "Linux") do
    cmd = "ssh #{ssh_target} 'systemd-run --user --unit=genesis-remote #{launcher_path} start'"

    case run_cmd(cmd, @launch_receive_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, _output, status} -> {:error, {:daemon_launch_failed, status}}
      :timeout ->
        # systemd-run may keep the SSH channel open; assume success.
        :ok
    end
  end

  defp start_daemon(ssh_target, launcher_path, "Darwin") do
    plist_path = write_launchd_plist(launcher_path)

    if plist_path == nil do
      {:error, {:daemon_launch_failed, :plist_write_failed}}
    else
      result = deploy_launchd_plist(ssh_target, plist_path)
      File.rm(plist_path)
      result
    end
  end

  # Writes the launchd plist to a local temp file. Returns the path or nil.
  defp write_launchd_plist(launcher_path) do
    plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.genesis.remote</string>
        <key>ProgramArguments</key>
        <array>
            <string>#{launcher_path}</string>
            <string>start</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
    </plist>
    """

    tmp_path = Path.join(System.tmp_dir!(), "genesis-remote-plist-#{System.unique_integer([:positive])}.plist")

    case File.write(tmp_path, plist) do
      :ok -> tmp_path
      {:error, _reason} -> nil
    end
  end

  # SCPs the plist to ~/Library/LaunchAgents/ and loads it via launchctl.
  defp deploy_launchd_plist(ssh_target, plist_path) do
    remote_plist = "~/Library/LaunchAgents/com.genesis.remote.plist"

    scp_cmd = "scp #{plist_path} #{ssh_target}:#{remote_plist}"

    with {:ok, _output, 0} <- run_cmd(scp_cmd, @scp_timeout_ms) do
      load_cmd =
        "ssh #{ssh_target} 'launchctl unload #{remote_plist} 2>/dev/null; launchctl load #{remote_plist}'"

      case run_cmd(load_cmd, @cmd_timeout_ms) do
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

  defp transition_to_error(%__MODULE__{} = state, error_msg) do
    cancel_heartbeat(state.heartbeat_ref)
    disconnect_node(state.node)
    close_port(state.ssh_tunnel_port)

    new_state = %__MODULE__{
      state
      | phase: :error,
        last_error: error_msg,
        ssh_tunnel_port: nil,
        tunnel_local_port: nil,
        heartbeat_ref: nil
    }

    broadcast_status(state.target, new_state)
    new_state
  end

  defp cleanup(%__MODULE__{} = state) do
    cancel_heartbeat(state.heartbeat_ref)
    disconnect_node(state.node)
    close_port(state.ssh_tunnel_port)

    broadcast_status(state.target, %{state | phase: :disconnected})

    %__MODULE__{
      state
      | phase: :disconnected,
        ssh_tunnel_port: nil,
        tunnel_local_port: nil,
        heartbeat_ref: nil
    }
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

  # ── Helpers ────────────────────────────────────────────────────────

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
end
