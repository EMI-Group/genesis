defmodule EvoGit.RemoteConnection do
  @moduledoc """
  GenServer managing the lifecycle of a single SSH remote connection.

  There are two distinct operations, kept deliberately separate:

    * **Bootstrap** (`bootstrap/1`) — "first time setup": pushes the local
      `genesis_remote` binary to the remote host over SFTP and launches it as a
      `systemd-run --user` daemon. The daemon then runs independently and stays
      up even after the local side disconnects. Bootstrap does NOT connect.

    * **Connection** (`connect/1`) — establishes an SSH tunnel forwarding the
      remote distribution port to loopback, then performs Erlang distribution
      (`Node.connect/1`) to the remote node so that RPC (`:erpc.call/4`) and
      PubSub can flow over the tunnel.

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

  import Bitwise

  @registry EvoGit.RemoteConnection.Registry
  @supervisor EvoGit.RemoteConnection.Supervisor
  @pubsub_topic "remote_connections"
  @heartbeat_interval_ms 10_000
  @tunnel_settle_ms 500
  @launch_receive_timeout_ms 5_000

  # The remote daemon always binds loopback; the SSH tunnel forwards the dist
  # port to loopback on both sides, so the node name is fixed.
  @remote_node_name "genesis_remote@127.0.0.1"

  # ── State ──────────────────────────────────────────────────────────

  defstruct target: nil,
            node: nil,
            phase: :disconnected,
            ssh_tunnel_port: nil,
            last_error: nil,
            heartbeat_ref: nil,
            bootstrap_port: nil

  @type phase :: :disconnected | :bootstrapping | :connecting | :connected | :error

  @type t :: %__MODULE__{
          target: map() | nil,
          node: String.t() | nil,
          phase: phase(),
          ssh_tunnel_port: port() | nil,
          last_error: String.t() | nil,
          heartbeat_ref: reference() | nil,
          bootstrap_port: port() | nil
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
    case Registry.lookup(@registry, target_id) do
      [{pid, _}] -> GenServer.call(pid, :disconnect)
      [] -> :ok
    end
  end

  @doc """
  Returns the status of the connection manager for `target_id`.

  When no manager exists, returns the disconnected default:

      %{phase: :disconnected, node: nil, last_error: nil, target: nil}
  """
  @spec status(String.t()) :: map()
  def status(target_id) do
    case Registry.lookup(@registry, target_id) do
      [{pid, _}] -> GenServer.call(pid, :status)
      [] -> %{phase: :disconnected, node: nil, last_error: nil, target: nil}
    end
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
    |> Map.new(fn {target_id, pid} -> {target_id, GenServer.call(pid, :status)} end)
  end

  @doc """
  Executes the bootstrap process ONLY (push binary + launch daemon).

  Does NOT connect. Looks up the target, finds-or-starts the manager, then
  performs the first-time setup.

  Returns `{:ok, :daemon_started}` on success or `{:error, reason}`.
  """
  @spec bootstrap(String.t()) :: {:ok, :daemon_started} | {:error, term()}
  def bootstrap(target_id) do
    with {:ok, target} <- fetch_target(target_id),
         {:ok, pid} <- ensure_started(target) do
      GenServer.call(pid, :bootstrap)
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def init(target) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{target: target, node: @remote_node_name}}
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

  def handle_info({:EXIT, port, _reason}, %__MODULE__{bootstrap_port: port} = state) do
    # Bootstrap launch port exited — expected (fire-and-forget).
    {:noreply, %{state | bootstrap_port: nil}}
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
      {:error, :local_node_not_distributed, state}
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

    cmd = build_tunnel_command(target)
    port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stream])

    # Give the SSH tunnel time to establish.
    Process.sleep(@tunnel_settle_ms)

    remote = String.to_atom(state.node)

    case Node.connect(remote) do
      true ->
        ref = schedule_heartbeat()

        new_state = %__MODULE__{
          connecting
          | phase: :connected,
            ssh_tunnel_port: port,
            heartbeat_ref: ref,
            last_error: nil
        }

        broadcast_status(state.target, new_state)
        {:ok, new_state}

      result when result in [false, :ignored] ->
        close_port(port)
        reason = {:node_connect_failed, state.node}
        new_state = %{connecting | phase: :error, last_error: format_error(reason)}
        {:error, reason, new_state}
    end
  end

  # ── Bootstrap ──────────────────────────────────────────────────────

  defp do_bootstrap(%__MODULE__{} = state) do
    case Application.get_env(:evo_git, :remote_binary_path) do
      nil -> {:error, :no_binary_configured, state}
      "" -> {:error, :no_binary_configured, state}
      local_path -> do_bootstrap_with_binary(state, local_path)
    end
  end

  defp do_bootstrap_with_binary(%__MODULE__{} = state, local_path) do
    target = state.target
    bootstrapping = %{state | phase: :bootstrapping}
    host = String.to_charlist(target.host)
    ssh_port = Map.get(target, :port) || 22
    ssh_opts = build_ssh_opts(target)
    remote_path_cl = String.to_charlist(Map.get(target, :remote_path) || "/tmp/genesis_engine")

    case :ssh.connect(host, ssh_port, ssh_opts) do
      {:ok, ssh_conn} ->
        result = upload_and_launch(bootstrapping, ssh_conn, local_path, remote_path_cl, target)
        :ssh.close(ssh_conn)
        result

      {:error, reason} ->
        {:error, reason, %{bootstrapping | phase: :error, last_error: format_error(reason)}}
    end
  end

  defp upload_and_launch(state, ssh_conn, local_path, remote_path_cl, target) do
    case :ssh_sftp.start_channel(ssh_conn) do
      {:ok, channel} ->
        result = do_upload(state, channel, local_path, remote_path_cl, target)
        :ssh_sftp.stop_channel(channel)
        result

      {:error, reason} ->
        {:error, reason, %{state | phase: :error, last_error: format_error(reason)}}
    end
  end

  defp do_upload(state, channel, local_path, remote_path_cl, target) do
    with {:ok, binary} <- File.read(local_path),
         :ok <- :ssh_sftp.write_file(channel, remote_path_cl, binary),
         :ok <- set_executable(channel, remote_path_cl) do
      launch_daemon(state, target)
    else
      {:error, reason} ->
        {:error, reason, %{state | phase: :error, last_error: format_error(reason)}}
    end
  end

  # Sets the remote file permissions to 0o755 by reading the existing
  # file_info record and replacing the permission bits while preserving the
  # file-type bits.
  defp set_executable(channel, remote_path_cl) do
    case :ssh_sftp.read_file_info(channel, remote_path_cl) do
      {:ok, info} ->
        # The :file_info tuple is {:file_info, size, type, access, atime, mtime,
        # ctime, mode, links, major_device, minor_device, inode, uid, gid}.
        # Index 7 is the mode. Preserve type bits (0o777000), set perms to 0o755.
        old_mode = elem(info, 7)
        new_mode = (old_mode &&& 0o777000) ||| 0o755
        new_info = put_elem(info, 7, new_mode)
        :ssh_sftp.write_file_info(channel, remote_path_cl, new_info)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Launches the remote daemon via `systemd-run --user`. This is fire-and-forget:
  # systemd-run returns once the unit is queued. We do a short receive to check
  # for immediate failure, then succeed.
  defp launch_daemon(state, target) do
    cmd = build_launch_command(target)
    port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stream])

    case drain_port_exit(port, @launch_receive_timeout_ms) do
      {:ok, 0} ->
        EvoGit.RemoteConnections.touch(target.id)
        {:ok, %{state | bootstrap_port: nil}}

      {:ok, status} ->
        reason = {:daemon_launch_failed, status}
        {:error, reason, %{state | phase: :error, last_error: format_error(reason)}}

      :timeout ->
        # systemd-run may keep the SSH channel open; assume success.
        close_port(port)
        EvoGit.RemoteConnections.touch(target.id)
        {:ok, %{state | bootstrap_port: nil}}
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
        heartbeat_ref: nil
    }

    broadcast_status(state.target, new_state)
    new_state
  end

  defp cleanup(%__MODULE__{} = state) do
    cancel_heartbeat(state.heartbeat_ref)
    disconnect_node(state.node)
    close_port(state.ssh_tunnel_port)
    close_port(state.bootstrap_port)

    broadcast_status(state.target, %{state | phase: :disconnected})

    %__MODULE__{
      state
      | phase: :disconnected,
        ssh_tunnel_port: nil,
        heartbeat_ref: nil,
        bootstrap_port: nil
    }
  end

  # ── Command builders ───────────────────────────────────────────────

  defp build_tunnel_command(target) do
    dist_port = Map.get(target, :dist_port) || 9000
    ssh_port = Map.get(target, :port) || 22

    parts =
      [
        "ssh",
        "-L #{dist_port}:127.0.0.1:#{dist_port}",
        "-N",
        "-o ServerAliveInterval=30",
        "-o ServerAliveCountMax=3",
        identity_flag(target),
        "-p #{ssh_port}",
        user_host(target)
      ]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, " ")
  end

  defp build_launch_command(target) do
    remote_path = Map.get(target, :remote_path) || "/tmp/genesis_engine"
    ssh_port = Map.get(target, :port) || 22

    parts =
      [
        "ssh",
        identity_flag(target),
        "-p #{ssh_port}",
        user_host(target),
        "'systemd-run --user --unit=genesis-remote #{remote_path} start'"
      ]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, " ")
  end

  defp build_ssh_opts(target) do
    base = [silently_accept_hosts: true]

    base =
      case Map.get(target, :user) do
        user when is_binary(user) and user != "" -> [{:user, String.to_charlist(user)} | base]
        _ -> base
      end

    case Map.get(target, :identity_file) do
      path when is_binary(path) and path != "" ->
        dir = path |> Path.dirname() |> String.to_charlist()
        [{:user_dir, dir} | base]

      _ ->
        base
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp via(target_id) do
    {:via, Registry, {@registry, target_id}}
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
      target: state.target
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

  # Drains the exit_status message from a port with a timeout.
  # Returns {:ok, status} or :timeout.
  defp drain_port_exit(port, timeout) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      timeout -> :timeout
    end
  end

  defp identity_flag(target) do
    case Map.get(target, :identity_file) do
      path when is_binary(path) and path != "" -> "-i #{path}"
      _ -> ""
    end
  end

  defp user_host(target) do
    host = Map.get(target, :host)

    case Map.get(target, :user) do
      user when is_binary(user) and user != "" -> "#{user}@#{host}"
      _ -> host
    end
  end

  defp format_error(reason) do
    inspect(reason)
  end
end
