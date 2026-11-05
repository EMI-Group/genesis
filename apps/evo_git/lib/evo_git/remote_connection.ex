defmodule EvoGit.RemoteConnection do
  @moduledoc """
  GenServer managing the lifecycle of a single SSH remote connection.

  There are two distinct operations, kept deliberately separate:

    * **Bootstrap** (`bootstrap/1`, `bootstrap/2`) — "first time setup": gets a
      `genesis_server` release tarball onto the remote host, extracts it to the
      target's `remote_path`, patches its ELF binaries when the host is NixOS,
      and then invokes that release's OWN CLI —
      `<remote_path>/bin/genesis_server remote start` — which makes the host's
      Genesis server instance available as a remote node: the CLI starts the
      instance when none is running (`genesis start` semantics) and enables
      Erlang distribution on it at RUNTIME. There is exactly ONE instance per
      host and it always serves HTTP — distribution is a toggle inside that
      same BEAM, so the instance and every task running on it survive the local
      side disconnecting. Bootstrap does NOT connect. Bootstrap NEVER detaches
      or re-points distribution on an already-running instance without explicit
      user permission — see the `:on_running` option of `bootstrap/2`.

      Deployment mechanics belong to the release CLI, not to this module: it
      decides the systemd scope (`--user`, or SYSTEM scope with `--collect`
      when the remote login is root), writes and loads the launchd plist on
      macOS, and carries a `setsid`/`nohup` fallback. Bootstrap only
      orchestrates staging plus the `remote start` / `remote stop` /
      `remote status` calls, so no systemd or launchd command is ever built
      here.

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

  `:starting_daemon` covers both shapes of the release CLI's `remote start`: a
  first start of the instance on a cold host, and enabling distribution at
  runtime on an instance that is already serving HTTP.

  Before any staging, bootstrap performs a silent pre-flight: it resolves the
  remote OS (the target's optional `platform` field, else one
  `uname -s && uname -m` probe — no login-user probe, because the CLI owns the
  systemd scope decision) and asks the release CLI whether distribution is
  already enabled on the host's Genesis server instance
  (`<launcher> remote status --unit genesis-remote-<id>`; the unit string is
  the `--unit` IDENTITY argument, not a per-target process). When it is:

    * with `on_running: :refuse` (the default), bootstrap refuses without
      touching anything — no staging, no stop, no broadcast — and returns
      `{:error, {:daemon_running, details}}`; going ahead would re-stage the
      release and re-point the instance's distribution identity. The caller
      should show a permission dialog from this tuple;
    * with `on_running: :restart`, the `:stopping_daemon` stage is broadcast
      and `<launcher> remote stop --unit genesis-remote-<id>` is run before the
      normal staging flow re-enables distribution with the current contract.
      `remote stop` only DETACHES distribution — the instance keeps serving
      HTTP and its tasks keep running (`genesis stop` is what stops the
      instance itself).

  `:patching_binaries` is broadcast only when the remote is NixOS (Linux + not
  yet distribution-enabled for this target + NixOS detected) and is skipped
  otherwise: on NixOS hosts the extracted release's ELF binaries are patched on
  the fly with a Nix-built `patchelf` (the glibc tarball cannot execute there
  without it). A release whose instance already has distribution enabled is
  never patched — that live instance keeps running its already-loaded code.

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

  ## Async connect (event-driven, non-blocking)

  `connect/1` is NON-BLOCKING: it replies `{:ok, :connecting}` (or
  `{:ok, :connected}` when already connected) as soon as the connect is
  initiated and returns control to the caller immediately. The blocking I/O —
  `Distribution.enable_for_remote/1`, the ssh spawn, the tunnel-readiness poll
  (`wait_for_tunnel/4`) and `Node.connect/1` — runs in a MONITORED worker
  process started by the GenServer, so the manager stays responsive
  (`status/1`/`connected?/1`/`disconnect/1`/`list_connections/0`) for the whole
  connect. The GenServer remains the SINGLE owner of phase state: every phase
  transition happens in the GenServer process, which broadcasts it on
  `"remote_connections"` as `{:remote_connection_status, target_id, status_map}`.

  Lifecycle broadcasts (same topic/shape as bootstrap):

    * `:connecting` — emitted when a connect starts (in `handle_call(:connect)`)
    * `:connected` — emitted on success (existing behavior)
    * `:error` with `last_error` populated — emitted on EVERY failure arm
      (distribution failed, no free port, tunnel not ready / ssh exited,
      node connect failed, worker crash)
    * `:disconnected` — emitted when `disconnect/1` aborts an in-flight connect

  Duplicate connects are idempotent: a second `connect/1` while the target is
  already `:connecting` (or `:connected`) is a no-op that acks promptly and
  never spawns a second tunnel.

  ### Internal message protocol

  Connect worker → GenServer:

    * `{:connect_result, worker_pid, {:ok, %{port:, local_port:, node_name:}}}`
      — connect succeeded. The worker transfers the tunnel `Port` to the
      GenServer (`Port.connect/2`) BEFORE sending this message, so the tunnel
      survives the worker's exit; the GenServer records the port, arms the
      heartbeat and broadcasts `:connected`.
    * `{:connect_result, worker_pid, {:error, message}}` — connect failed. The
      worker already closed the tunnel port itself. The GenServer stores
      `message` as `last_error` and broadcasts `:error`.

  The GenServer monitors the worker (`Process.monitor/1`, stored in
  `state.connect_worker`); a `:DOWN` for the current worker with no result
  having arrived means the worker crashed → `:error` broadcast.

  GenServer → worker: none required — the worker exits on its own after
  reporting. Killing the worker (`Process.exit(pid, :kill)`) is how
  `disconnect/1` aborts an in-flight connect: the worker owns the tunnel port
  until success, so killing it closes the ssh tunnel; if the worker already
  transferred the port, the GenServer's own termination (disconnect stops the
  manager) closes it.

  ## Port monitoring

  While `:connected`, the SSH tunnel `Port` is owned by this (GenServer)
  process. With `Process.flag(:trap_exit, true)` set in `init/1`, tunnel death
  arrives as a `{:EXIT, port, reason}` message, triggering a transition to
  `:error`. During `:connecting` the port is owned by the connect worker (see
  above); the GenServer only takes ownership once the connect succeeds.

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
  # Poll interval of the tunnel-readiness wait (`wait_for_tunnel/4`) in the
  # connect worker. Overridable at runtime via the app-env seam
  # :remote_tunnel_poll_interval_ms (read per call) — production keeps the
  # 100ms cadence, while a test whose fake ssh opens its forwarded port a few
  # milliseconds late does not have to pay a full production poll interval
  # before `Node.connect` runs.
  @tunnel_poll_interval_ms 100
  # SSH's own connection-establishment timeout (-o ConnectTimeout), kept
  # consistent with (slightly under) the @tunnel_wait_timeout_ms tunnel budget
  # so an unreachable/dead host fails inside the budget instead of hanging on
  # the OS TCP timeout. The tunnel wait budget itself is the hard cap either way.
  @ssh_connect_timeout_ms 8_000
  # Budget for the release CLI's `remote start`, which BLOCKS until the
  # instance has distribution enabled and answers (its own `--wait` readiness
  # budget) — on a cold host that includes the BEAM boot. The CLI's exit status
  # IS the health signal — there is no separate health poll on this side.
  @daemon_start_timeout_ms 120_000
  # The CLI's own readiness budget (seconds) passed via `--wait`.
  @daemon_start_wait_s 30
  # 900s — bootstrap now stages the release either by uploading a local tarball
  # (scp) OR by probing the remote platform and downloading the release tarball
  # (curl then wget on the remote, with a local curl + scp fallback); both can
  # be slow.
  @bootstrap_call_timeout_ms 900_000

  # Default per-command timeout (30s). SCP gets a longer timeout.
  @cmd_timeout_ms 30_000
  @scp_timeout_ms 120_000

  # Backoff before the single retry of an IDEMPOTENT remote command that failed
  # with ssh's OWN transport exit code 255 (see `run_ssh_command_retry/4`).
  # Overridable per call via the app-env seam :remote_ssh_retry_backoff_ms
  # (tests set it to 0).
  @remote_ssh_retry_backoff_ms 400

  # Timeout for release-tarball downloads (tens of MB) — curl then wget on the
  # remote host, or the local curl fallback. Generous to handle slow links.
  @download_timeout_ms 300_000

  # Timeout for the NixOS on-the-fly patch script (nix-build can be slow on
  # first run — cache.nixos.org). Fits comfortably inside the 900s bootstrap
  # call timeout alongside the other stages (the patch dir persists as a GC
  # root, so re-bootstrap nix-builds are instant).
  @patch_timeout_ms 600_000

  # The remote node's distribution listener binds loopback; the SSH tunnel
  # forwards the dist port to loopback on both sides. The port is pinned inside
  # the running instance at ENABLE time (the CLI receives it as `--dist-port`),
  # so a target whose `dist_port` changed must be re-bootstrapped to re-enable
  # distribution on the new port. The local end of the tunnel uses a
  # dynamically-assigned free port to avoid conflicts with the local node's own
  # distribution port.
  @default_remote_dist_port 9000

  # ── State ──────────────────────────────────────────────────────────

  defstruct target: nil,
            node: nil,
            phase: :disconnected,
            ssh_tunnel_port: nil,
            tunnel_local_port: nil,
            last_error: nil,
            heartbeat_ref: nil,
            bootstrap_stage: nil,
            connect_worker: nil

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
          bootstrap_stage: bootstrap_stage() | nil,
          connect_worker: {pid(), reference()} | nil
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
  Initiates a connection to the remote node — the host's Genesis server
  instance with distribution enabled — for the given `target_id`.

  Looks up the target via `EvoGit.RemoteConnections.get/1`, finds-or-starts the
  connection manager GenServer, then requests a connection.

  NON-BLOCKING: replies promptly once the connect is initiated. The blocking
  work (ssh tunnel + `Node.connect`) runs in a monitored worker, and the
  terminal outcome is delivered via `{:remote_connection_status, ...}`
  broadcasts on `"remote_connections"` (`:connecting` on start, `:connected`
  on success, `:error` with `last_error` on failure, `:disconnected` when
  cancelled) — callers should watch those (or poll `status/1`) rather than
  block on this call.

  Returns:

    * `{:ok, :connecting}` — connect initiated (or already in progress; a
      duplicate connect while `:connecting` is an idempotent no-op)
    * `{:ok, :connected}` — the target is already connected (idempotent no-op)
    * `{:error, reason}` — target not found / manager could not be started
  """
  @spec connect(String.t()) :: {:ok, :connecting | :connected} | {:error, term()}
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
  Executes the bootstrap process ONLY (stage the `genesis_server` release +
  bring the host's Genesis server instance up as a remote node).

  Does NOT connect. Looks up the target, finds-or-starts the manager, then
  performs the first-time setup using CLI `scp`/`ssh` and — when no usable
  `local_binary_path` is set — automatic platform probing + release download.

  Delegates to `bootstrap/2` with the default `on_running: :refuse`:
  distribution that is already enabled is never detached or re-pointed without
  explicit permission.

  Returns `{:ok, :daemon_started}` on success or `{:error, reason}`.
  """
  @spec bootstrap(String.t()) :: {:ok, :daemon_started} | {:error, term()}
  def bootstrap(target_id) do
    bootstrap(target_id, [])
  end

  @doc """
  Executes the bootstrap process ONLY (stage the `genesis_server` release +
  make the host's Genesis server instance a remote node), with options.

  Same as `bootstrap/1` plus the `:on_running` option. Before any staging a
  silent pre-flight resolves the remote OS and asks the release CLI whether
  distribution is already enabled on the host's Genesis server instance:

    * `:on_running: :refuse` (default) — when distribution is already enabled,
      refuse without touching anything: no staging, no stop, no broadcast.
      Returns `{:error, {:daemon_running, details}}` where `details` is a
      human-readable explanation. The caller should ask the user for
      permission and, if granted, re-invoke with `on_running: :restart`.
    * `:on_running: :restart` — detach distribution first (broadcasting the
      `:stopping_daemon` stage and running `<launcher> remote stop --unit
      genesis-remote-<id>`), then proceed with the normal staging +
      distribution-enable flow. Detaching distribution does NOT stop the
      instance or interrupt its tasks: the same Genesis server keeps serving
      HTTP throughout.
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
  def handle_call(:connect, _from, %__MODULE__{phase: phase} = state)
      when phase in [:connecting, :connected] do
    # Idempotent duplicate-connect guard: an in-flight (:connecting) or
    # established (:connected) connection must not spawn a second tunnel or
    # clobber state. Ack promptly with the actual phase.
    {:reply, {:ok, phase}, state}
  end

  def handle_call(:connect, _from, %__MODULE__{} = state) do
    # Initiate an async connect: broadcast :connecting, then hand the blocking
    # I/O (distribution setup, ssh spawn, tunnel wait, Node.connect) to a
    # monitored worker so this GenServer stays responsive. The worker reports
    # back via {:connect_result, ...} messages (see moduledoc).
    connecting = %{state | phase: :connecting, last_error: nil}
    broadcast_status(state.target, connecting)

    # Capture the GenServer pid BEFORE the Task closure: inside the anonymous
    # function self() would be the WORKER process, and connect_worker/2 sends
    # its {:connect_result, ...} to the server argument — a worker sending to
    # itself would lose the result when it exits, leaving only the :DOWN
    # (misreported as "connect worker crashed").
    server = self()
    {:ok, worker} = Task.start_link(fn -> connect_worker(server, connecting) end)
    ref = Process.monitor(worker)

    {:reply, {:ok, :connecting}, %{connecting | connect_worker: {worker, ref}}}
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

  def handle_call(:disconnect, _from, %__MODULE__{phase: :connecting} = state) do
    # Disconnect during an in-flight connect: terminate the connect worker
    # (it owns the tunnel port until success, so killing it closes the ssh
    # tunnel; if it already transferred the port to us, our own termination
    # below closes it), then run the normal teardown + :disconnected broadcast.
    state =
      case state.connect_worker do
        {worker, _ref} ->
          Process.exit(worker, :kill)
          clear_connect_worker(state)

        nil ->
          state
      end

    {:stop, :normal, :ok, cleanup(state)}
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

  # ── Connect-worker result / death (async connect protocol, see moduledoc) ──

  def handle_info(
        {:connect_result, worker, {:ok, %{port: port} = details}},
        %__MODULE__{connect_worker: {worker, _ref}} = state
      ) do
    state = clear_connect_worker(state)

    if Port.info(port) == nil do
      # The tunnel died after the worker's success report but before we could
      # record it (e.g. ssh exited in the transfer window) — fail rather than
      # arm a :connected state on a dead port.
      {:noreply, fail_connect(state, "ssh tunnel closed before connect completed")}
    else
      ref = schedule_heartbeat()

      new_state = %{
        state
        | phase: :connected,
          ssh_tunnel_port: port,
          tunnel_local_port: details.local_port,
          node: details.node_name,
          heartbeat_ref: ref,
          last_error: nil
      }

      broadcast_status(state.target, new_state)
      {:noreply, new_state}
    end
  end

  def handle_info(
        {:connect_result, worker, {:error, message}},
        %__MODULE__{connect_worker: {worker, _ref}} = state
      ) do
    # Connect failed — the worker already closed its tunnel port. Broadcast
    # :error with the failure detail populated.
    {:noreply, fail_connect(state, message)}
  end

  def handle_info(
        {:DOWN, ref, :process, worker, reason},
        %__MODULE__{connect_worker: {worker, ref}} = state
      ) do
    # The connect worker died without reporting a result (crash) — surface it
    # as a connect failure. Killing it via disconnect/1 never reaches here: the
    # disconnect handler clears connect_worker before stopping the manager.
    Logger.error("RemoteConnection: connect worker crashed: #{inspect(reason)}")
    {:noreply, fail_connect(state, "connect worker crashed: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Connection ─────────────────────────────────────────────────────

  # Entry point of the async connect worker (spawned by handle_call(:connect),
  # runs in a DEDICATED process — never the GenServer). Runs the blocking
  # connect I/O and reports the outcome to the manager via a
  # {:connect_result, self(), result} message (see moduledoc). The result is
  # {:ok, %{port:, local_port:, node_name:}} on success or {:error, message}.
  #
  # The worker is LINKED to the manager (Task.start_link) and MONITORED by it:
  # if the manager dies the worker dies with it (closing any port it owns); if
  # the worker crashes the manager's :DOWN handler broadcasts :error.
  defp connect_worker(server, %__MODULE__{} = state) do
    target = state.target

    result =
      case ensure_connect_distribution(target) do
        :ok ->
          case establish_tunnel_and_node(target) do
            {:ok, %{port: port} = details} ->
              # Transfer the tunnel Port to the manager BEFORE reporting
              # success: from this instant the Port is owned by the manager and
              # survives this worker's exit (an owner-exiting port would close
              # the tunnel with us). All subsequent port messages (data,
              # exit_status, EXIT) route to the manager.
              Port.connect(port, server)
              {:ok, details}

            {:error, _message} = error ->
              error
          end

        {:error, _message} = error ->
          error
      end

    send(server, {:connect_result, self(), result})
  end

  # Auto-enables distribution on-demand when the local node is not distributed
  # yet. Runs in the connect worker — never blocks the GenServer.
  defp ensure_connect_distribution(target) do
    if node() == :nonode@nohost do
      case EvoGit.Distribution.enable_for_remote(target) do
        :ok ->
          :ok

        {:error, reason} ->
          message = format_reason({:distribution_failed, reason})
          Logger.error("Remote connection distribution setup failed: #{message}")
          {:error, message}
      end
    else
      :ok
    end
  end

  # The blocking connect flow, run inside the connect worker: ensure the
  # outbound EpmdDist resolution, set the cookie, open the ssh tunnel, poll
  # its local port until ready, register the tunnel port with EpmdDist and
  # Node.connect to the remote node.
  #
  # Returns {:ok, %{port: port, local_port: local_port, node_name: node_name}}
  # (the worker STILL owns `port` at this point — the caller transfers it to
  # the manager) or {:error, message} (the worker has already closed the port
  # on every failure arm, so no tunnel is left behind).
  #
  # The connect-failure diagnostics are built from the target's own contract
  # (ssh target, launcher path, unit name) — the instance's deployment shape
  # lives behind the release CLI, so nothing here names a systemd or launchd
  # command.
  defp establish_tunnel_and_node(target) do
    # Outbound tunnel connects must resolve the remote node's dist port through
    # EvoGit.EpmdDist's persistent-term registry (register_target below feeds
    # exactly that registry). When the local node booted distributed via
    # Distribution.maybe_enable/0 (or -sname/-name), the kernel `epmd_module`
    # env is still the default erl_epmd — the node registered with the real
    # epmd daemon and net_kernel's outbound port_please would ask that daemon
    # for a name it never registered, failing with noport (no remote journal
    # entry: the handshake never starts). net_kernel:epmd_module/0 reads the
    # kernel env PER connection attempt (inet_tcp_dist fam_setup), so flipping
    # it here — after boot — takes effect for this Node.connect. We
    # deliberately do NOT change the boot path: the local node must keep its
    # registration with the real epmd daemon for inbound discovery; only the
    # outbound resolution of tunnel-registered names needs EpmdDist.
    EvoGit.Distribution.ensure_epmd_module()

    # Set the distribution cookie to match the remote node (the host's Genesis
    # server instance with distribution enabled).
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

    # Remote port: the dist port the remote node's listener was enabled on.
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
               poll_interval: tunnel_poll_interval_ms()
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
                {:ok, %{port: port, local_port: local_port, node_name: node_name}}

              result when result in [false, :ignored] ->
                EvoGit.EpmdDist.unregister_target(node_name)
                close_port(port)

                diagnostics =
                  node_connect_failed_diagnostics(
                    node_name,
                    local_port,
                    remote_port,
                    node_cookie,
                    target
                  )

                Logger.error("Remote connection to #{node_name} failed: #{diagnostics}")
                {:error, diagnostics}
            end

          {:error, reason} ->
            close_port(port)
            error = {:tunnel_not_ready, reason}
            {:error, format_reason(error)}
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  # ── Bootstrap ──────────────────────────────────────────────────────

  # Entry point for the bootstrap GenServer call. Silent pre-flight BEFORE any
  # staging: resolve the launch OS (target `platform` override, else one
  # `uname -s && uname -m` probe — no broadcast yet), then check whether
  # distribution is already enabled on the host's Genesis server instance. When
  # it is: `on_running: :refuse` (default) refuses without touching anything
  # (no staging, no stop, no broadcast — the caller shows a permission dialog
  # from the {:daemon_running, details} tuple); `on_running: :restart`
  # broadcasts the :stopping_daemon stage, DETACHES distribution (the instance
  # and its tasks keep running), then proceeds with the normal staging flow
  # (which re-enables distribution with the current contract).
  defp do_bootstrap(%__MODULE__{} = state, opts) do
    on_running = normalize_on_running(Keyword.get(opts, :on_running, :refuse))
    target = state.target
    ssh_target = target.ssh_target
    %{launcher_path: launcher_path} = remote_paths(target)
    unit = daemon_unit(target)

    case resolve_platform(target, ssh_target) do
      {:ok, daemon_os, platform} ->
        # The release CLI owns the systemd scope decision, so the pre-flight no
        # longer probes the login user — it just asks the CLI whether
        # distribution is enabled on the instance.
        case remote_status(ssh_target, launcher_path, unit) do
          {:running, _node, _port} ->
            case on_running do
              :refuse ->
                # State returned EXACTLY as received — no mutation, no broadcast.
                {:error, {:daemon_running, daemon_running_details(target)}, state}

              :restart ->
                # :stopping_daemon stage, then detach distribution (the
                # instance keeps serving HTTP and its tasks keep running), then
                # stage a fresh release and re-enable distribution with the
                # current contract. A failed stop is non-fatal — the start
                # below surfaces any real failure.
                state = set_stage(%{state | phase: :bootstrapping}, target, :stopping_daemon)
                stop_daemon_via_cli(ssh_target, launcher_path, unit)
                do_bootstrap_staging(state, target, daemon_os, platform)
            end

          :stopped ->
            do_bootstrap_staging(state, target, daemon_os, platform)

          {:error, reason} ->
            # A first-time bootstrap has no launcher on the remote yet, so a
            # failing status call must never fail bootstrap — log and stage.
            Logger.warning(
              "RemoteConnection: daemon status check failed for target " <>
                "#{target_label(target)}: #{format_reason(reason)}; continuing with bootstrap"
            )

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
            "falling back to automatic download of the genesis_server release."
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
    %{ssh_target: ssh_target, remote_tarball: remote_tarball} = paths = remote_paths(target)

    # :probing_platform stage — the pre-flight probe already resolved the OS,
    # but the stage is the visible "we probed" marker and keeps the two paths'
    # stage sequences aligned.
    state = set_stage(%{state | phase: :bootstrapping}, target, :probing_platform)
    state = set_stage(state, target, :uploading)

    case scp_tarball(ssh_target, local_path, remote_tarball) do
      :ok ->
        launch_after_staging(state, target, paths, daemon_os)

      {:error, reason} ->
        error_state = error_state(state, target, reason)
        {:error, reason, error_state}
    end
  end

  # Auto-download bootstrap path (no usable local_binary_path): download the
  # tarball for the pre-flight-resolved platform (curl then wget on the remote,
  # local curl + scp fallback) → launch via the shared post-staging sequence.
  defp do_bootstrap_auto(%__MODULE__{} = state, target, daemon_os, platform) do
    %{ssh_target: ssh_target, remote_tarball: remote_tarball} = paths = remote_paths(target)

    # :probing_platform stage — the pre-flight probe already resolved the OS,
    # but the stage is the visible "we probed" marker and keeps the two paths'
    # stage sequences aligned.
    state = set_stage(%{state | phase: :bootstrapping}, target, :probing_platform)
    state = set_stage(state, target, :downloading)

    case download_tarball(state, target, ssh_target, platform, remote_tarball) do
      {:ok, state} ->
        launch_after_staging(state, target, paths, daemon_os)

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # Resolves the remote platform. Uses the target's optional `platform` field
  # (validated locally, no SSH probe at all) when set; otherwise probes the
  # remote via one `uname -s && uname -m` SSH call. Returns
  # {:ok, daemon_os, platform} where daemon_os is the canonical
  # "Linux" | "Darwin" string. Asset selection is handled by
  # EvoGit.RemoteBootstrap — glibc is the default and only published Linux
  # variant, so tarball names are never suffixed.
  defp resolve_platform(target, ssh_target) do
    case Map.get(target, :platform) do
      platform when is_binary(platform) and platform != "" ->
        with {:ok, %{os: _os, arch: _arch}} <- EvoGit.RemoteBootstrap.parse_platform(platform),
             {:ok, daemon_os} <- EvoGit.RemoteBootstrap.daemon_os(platform) do
          {:ok, daemon_os, platform}
        end

      _ ->
        probe_platform(ssh_target)
    end
  end

  # Probes the remote OS + architecture via a single SSH call
  # (`uname -s && uname -m`). Returns {:ok, daemon_os, platform} or
  # {:error, reason}.
  defp probe_platform(ssh_target) do
    command = "uname -s && uname -m"

    case run_ssh_command_retry(ssh_target, command, @cmd_timeout_ms) do
      {:ok, output, 0} ->
        case String.split(String.trim(output), "\n") do
          [os, arch | _rest] ->
            with {:ok, platform} <-
                   EvoGit.RemoteBootstrap.parse_uname(String.trim(os), String.trim(arch)),
                 {:ok, daemon_os} <- EvoGit.RemoteBootstrap.daemon_os(platform) do
              {:ok, daemon_os, platform}
            end

          _ ->
            {:error, {:probe_failed, {:unexpected_output, String.trim(output)}}}
        end

      {:ok, output, status} ->
        {:error, {:probe_failed, {:exit_status, status, output_tail(output)}}}

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
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        {:error, {:download_failed, {:exit_status, status, output_tail(output)}}}

      :timeout ->
        {:error, {:download_failed, :timeout}}
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
            {:ok, output, status} -> {:error, {:exit_status, status, output_tail(output)}}
            :timeout -> {:error, :timeout}
          end

        {:error, reason} ->
          {:error, {:mkdir_failed, reason}}
      end
    end
  end

  # Runs the post-staging launch sequence shared by both bootstrap paths:
  # extract + chmod (ONE ssh round trip) → config copy → cookie → (NixOS patch)
  # → distribution enable (the CLI's exit status IS the health signal). `os` is
  # the launch OS resolved during pre-flight (probed or platform override) —
  # `:detecting_os` no longer exists as a stage. `paths` is the
  # `remote_paths/1` map shared with the remote-node helpers.
  defp launch_after_staging(%__MODULE__{} = state, target, paths, os) do
    %{ssh_target: ssh_target, launcher_path: launcher_path} = paths

    with {:ok, state} <- stage_extract_and_set_permissions(state, target, paths),
         {:ok, state} <-
           run_stage(state, target, :copying_config, fn ->
             copy_config_to_remote(ssh_target, os)
           end) do
      # :generating_cookie stage — the cookie is generated right after the
      # stage broadcast so the resolved value reaches the launch steps below.
      state = set_stage(state, target, :generating_cookie)
      cookie = ensure_cookie!()

      # NixOS on-the-fly patching (Linux only; skipped when distribution is
      # already enabled for this target or the remote is not NixOS). Broadcasts
      # :patching_binaries only when the patch actually runs.
      case maybe_patch_nixos(state, target, ssh_target, os, launcher_path) do
        {:ok, state} ->
          case maybe_start_daemon(ssh_target, launcher_path, target, cookie, state) do
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

  # Extract + chmod in ONE ssh round trip, still broadcast as the two
  # dashboard progress steps: :extracting is set BEFORE the command, and
  # :setting_permissions is set after it succeeds (the dashboard maps them to
  # progress steps 2 and 3).
  defp stage_extract_and_set_permissions(state, target, paths) do
    state = set_stage(state, target, :extracting)

    case extract_and_set_permissions(paths) do
      :ok -> {:ok, set_stage(state, target, :setting_permissions)}
      {:error, reason} -> {:error, reason, error_state(state, target, reason)}
    end
  end

  # Constructs the error state, LOGS the failure once (with the remote output
  # tail carried by the reason) and broadcasts it. The `{:error, reason}` tuple
  # returned to callers keeps its shape — only `last_error` becomes the
  # readable message.
  defp error_state(state, target, reason) do
    message = format_reason(reason)

    Logger.error(
      "RemoteConnection: bootstrap failed for target #{target_label(target)}: #{message}"
    )

    error_state = %{state | phase: :error, bootstrap_stage: nil, last_error: message}
    broadcast_status(target, error_state)
    error_state
  end

  defp target_label(%{id: id}), do: to_string(id)
  defp target_label(_target), do: "?"

  # Resolves the remote paths shared by both staging paths and the remote-node
  # helpers. The tarball is uploaded to `<remote_path>.tar.xz`, then extracted
  # into `remote_path`'s parent: the tarball contains a top-level
  # `genesis_server/` directory.
  #
  # `remote_path` is usually the default `/tmp/genesis_server`, in which case
  # the extracted directory IS `remote_path`. A legacy/custom path (e.g.
  # `/opt/genesis`) needs one extra move after extraction — `move_into_place?`
  # records that, computed HERE rather than as a shell `[ ... ]` test so the
  # remote command stays a plain `&&` chain (and so the default path never gets
  # an `rm -rf` on the tree that was just extracted).
  defp remote_paths(target) do
    remote_path = Map.get(target, :remote_path) || "/tmp/genesis_server"
    parent = Path.dirname(remote_path)
    extracted = Path.join(parent, "genesis_server")

    %{
      ssh_target: target.ssh_target,
      remote_path: remote_path,
      remote_tarball: remote_path <> ".tar.xz",
      parent: parent,
      extracted: extracted,
      move_into_place?: extracted != remote_path,
      launcher_path: Path.join(remote_path, "bin/genesis_server")
    }
  end

  # SCPs the local tarball to the remote temp path.
  defp scp_tarball(ssh_target, local_path, remote_tarball) do
    cmd = "scp #{local_path} #{ssh_target}:#{remote_tarball}"

    case run_cmd(cmd, @scp_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:scp_failed, status, output_tail(output)}}
      :timeout -> {:error, {:scp_failed, :timeout}}
    end
  end

  # Extracts the uploaded tarball, puts it in place and makes the launcher
  # executable in ONE ssh round trip. Two separate round trips (tar then chmod)
  # let a dropped ssh session surface as an opaque `chmod` failure (ssh's own
  # 255) against a half-extracted tree; here the chain stops at the FIRST
  # failing step and the final `test -x` self-verifies the result. `chmod` only
  # runs when the extracted launcher is not already executable, so the tarball's
  # own exec bit is respected.
  #
  # Every path is DOUBLE-quoted: a custom `remote_path` may contain spaces, and
  # double quotes keep the whole command single-quote-free (so the
  # `RemoteBootstrap.sh_wrap/1` form stays safe in any remote login shell).
  #
  # `merge_stderr: true` — the failure tail is the whole point of the 3-element
  # `{:staging_failed, status, tail}`: tar/chmod errors AND ssh's own transport
  # diagnostics ("Connection reset by peer") are written to stderr.
  defp extract_and_set_permissions(
         %{
           ssh_target: ssh_target,
           remote_tarball: remote_tarball,
           parent: parent,
           launcher_path: launcher_path
         } = paths
       ) do
    command =
      "mkdir -p \"#{parent}\" && tar -xJf \"#{remote_tarball}\" -C \"#{parent}\" && " <>
        move_into_place_command(paths) <>
        "{ test -x \"#{launcher_path}\" || chmod +x \"#{launcher_path}\"; } && " <>
        "test -x \"#{launcher_path}\""

    case run_ssh_command_retry(ssh_target, command, @scp_timeout_ms, merge_stderr: true) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:staging_failed, status, output_tail(output)}}
      :timeout -> {:error, {:staging_failed, :timeout}}
    end
  end

  # The `rm -rf "<remote_path>" && mv "<extracted>" "<remote_path>" && ` step
  # needed when the tarball's top-level directory is not already the target
  # `remote_path`. Empty for the default path, where the extracted tree IS
  # `remote_path` — an `rm -rf` there would delete what was just extracted.
  defp move_into_place_command(%{
         move_into_place?: true,
         remote_path: remote_path,
         extracted: extracted
       }) do
    "rm -rf \"#{remote_path}\" && mv \"#{extracted}\" \"#{remote_path}\" && "
  end

  defp move_into_place_command(%{move_into_place?: false}), do: ""

  # Copies local config.toml and credentials.toml to the remote host.
  # Best-effort: missing local files are skipped; copy errors are logged but
  # do not fail the bootstrap (the instance boots fine without config).
  # Files that already exist on the remote are NOT overwritten.
  #
  # When config.toml is copied to a remote that has none, a locally-staged
  # variant is uploaded instead (see `copy_config_file/3`): its
  # [appearance] accent_color is set to a palette color that differs from the
  # local node's effective accent, so a freshly-bootstrapped remote node is
  # visually distinguishable from the local node in the dashboard. The accent
  # tweak is strictly best-effort and never changes bootstrap behavior.
  defp copy_config_to_remote(ssh_target, os) do
    remote_config_dir = remote_config_dir(os)

    # Ensure the remote config directory exists. The path is DOUBLE-quoted
    # because macOS's `Library/Application Support/genesis` contains a space;
    # `$HOME` (never `~`, which does not expand inside quotes) roots it.
    run_ssh_command_retry(ssh_target, "mkdir -p \"#{remote_config_dir}\"", @cmd_timeout_ms)

    for path <- [EvoGit.Config.config_path(), EvoGit.Config.credentials_path()] do
      if File.exists?(path) do
        remote_file = Path.join(remote_config_dir, Path.basename(path))

        if remote_file_exists?(ssh_target, remote_file) do
          # The remote already has this file; don't overwrite.
          :ok
        else
          copy_config_file(ssh_target, path, remote_file)
        end
      end
    end

    :ok
  end

  # Computes the remote config directory for a given OS. Mirrors the
  # platform logic in `EvoGit.Config.config_dir/0`.
  #
  # `$HOME`-rooted, NOT `~`: every caller interpolates this into a remote
  # command inside double quotes (macOS's `Application Support` makes the path
  # contain a space), and `~` does not expand inside quotes.
  defp remote_config_dir("Darwin") do
    Path.join(["$HOME", "Library", "Application Support", "genesis"])
  end

  defp remote_config_dir(_os) do
    Path.join(["$HOME", ".config", "genesis"])
  end

  # Checks whether a file exists on the remote host. The path is
  # double-quoted so a space in it (macOS) cannot word-split the probe.
  defp remote_file_exists?(ssh_target, remote_file) do
    case run_ssh_command_retry(
           ssh_target,
           "test -f \"#{remote_file}\" && echo yes || echo no",
           @cmd_timeout_ms
         ) do
      {:ok, output, 0} -> String.trim(output) == "yes"
      _ -> false
    end
  end

  # Rewrites a `$HOME`-rooted remote path into the `~` form for the scp
  # destination. scp re-parses the destination on the REMOTE side, and the
  # modern SFTP-speaking scp sends the path verbatim (no shell expansion), so
  # `$HOME` would be taken literally; `~` is expanded by scp itself. This keeps
  # the scp command byte-identical to the pre-quoting-fix behavior.
  #
  # Known limitation (deliberate, out of scope): a remote path containing a
  # space (macOS) is still not handled for scp — see the limits note in
  # `lib/evo_git/CONTEXT.md`.
  defp scp_remote_path("$HOME" <> rest), do: "~" <> rest
  defp scp_remote_path(remote_file), do: remote_file

  # ── Accent-variant config.toml copy ───────────────────────────────
  #
  # The remote does NOT already have `remote_file` (checked by the caller).
  # For config.toml a locally-staged variant whose [appearance] accent_color
  # differs from the local node's effective accent is uploaded first, so a
  # freshly-bootstrapped remote node is visually distinguishable from the
  # local node in the dashboard. Strictly best-effort: any failure in the
  # variant path (config read, rewrite, temp write, variant scp) logs a
  # warning and falls back to the plain scp of the unmodified local file —
  # bootstrap never fails or changes behavior because of the accent tweak.
  defp copy_config_file(ssh_target, path, remote_file) do
    display = Path.basename(path)

    case maybe_stage_accent_variant(path, ssh_target) do
      {:ok, tmp_path} ->
        result =
          case scp_config_file(ssh_target, tmp_path, remote_file) do
            :ok ->
              :ok

            :error ->
              Logger.warning(
                "Failed to copy accent variant of #{display} to remote; copying the original instead."
              )

              scp_original_config(ssh_target, path, remote_file, display)
          end

        File.rm(tmp_path)
        result

      :error ->
        scp_original_config(ssh_target, path, remote_file, display)
    end
  end

  # Stages the accent variant of the local config.toml at a local temp path
  # when `path` IS config.toml; returns :error for any other file and for any
  # failure along the way (read/rewrite/temp write), never raising.
  defp maybe_stage_accent_variant(path, ssh_target) do
    if path == EvoGit.Config.config_path() do
      stage_accent_variant(path, ssh_target)
    else
      :error
    end
  end

  # Reads the local config.toml, rewrites its accent color to the remote's
  # chosen one (see `remote_accent_for/2`), and writes the result to a fresh
  # temp file. Returns {:ok, tmp_path} or :error (with a logged warning).
  defp stage_accent_variant(path, ssh_target) do
    case File.read(path) do
      {:ok, contents} ->
        variant = rewrite_config_accent(contents, remote_accent_for(ssh_target, local_accent()))

        tmp_path =
          Path.join(
            System.tmp_dir!(),
            "genesis-remote-config-#{System.unique_integer([:positive])}.toml"
          )

        case File.write(tmp_path, variant) do
          :ok ->
            {:ok, tmp_path}

          {:error, reason} ->
            Logger.warning(
              "Failed to write remote accent variant of config.toml to #{tmp_path} " <>
                "(#{inspect(reason)}); copying the original instead."
            )

            :error
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to read config.toml for remote accent variant " <>
            "(#{inspect(reason)}); copying the original instead."
        )

        :error
    end
  end

  # SCPs `source` to the remote config file. Returns :ok on success, :error
  # on scp failure/timeout (never raises). The destination goes through
  # `scp_remote_path/1` so it stays in scp's `~` form (behavior unchanged).
  defp scp_config_file(ssh_target, source, remote_file) do
    cmd = "scp #{source} #{ssh_target}:#{scp_remote_path(remote_file)}"

    case run_cmd(cmd, @cmd_timeout_ms) do
      {:ok, _output, 0} -> :ok
      _ -> :error
    end
  end

  # SCPs the unmodified local file, logging (but never propagating) failures —
  # the original best-effort behavior: the instance boots fine without config.
  defp scp_original_config(ssh_target, path, remote_file, display) do
    case scp_config_file(ssh_target, path, remote_file) do
      :ok -> :ok
      :error -> Logger.warning("Failed to copy #{display} to remote; continuing.")
    end
  end

  @doc false
  # Picks the accent color a freshly-bootstrapped remote should carry: the
  # palette minus the local node's accent, deterministically indexed by a
  # stable hash of the `ssh_target` string — so the remote always differs
  # from the local node, and distinct targets tend to differ from each other.
  # The palette comes from `EvoGit.Config.Schema.Definitions.accent_palette/0`
  # (the single source of truth — the `[appearance] accent_color` schema's
  # `in:` validation whitelist).
  @spec remote_accent_for(String.t(), String.t()) :: String.t()
  def remote_accent_for(ssh_target, local_accent) do
    candidates =
      EvoGit.Config.Schema.Definitions.accent_palette() -- [local_accent]

    Enum.at(candidates, :erlang.phash2(ssh_target, length(candidates)))
  end

  # The local node's effective accent color — absent/unset falls back to the
  # schema default "blue". Never returns nil.
  defp local_accent do
    case EvoGit.Config.resolve([:appearance, :accent_color]) do
      accent when is_binary(accent) and accent != "" -> accent
      _ -> "blue"
    end
  end

  @doc false
  # Rewrites config.toml text so its [appearance] section carries the given
  # accent_color, preserving everything else verbatim: an existing
  # `accent_color = "..."` line inside the [appearance] section has only its
  # value replaced; an [appearance] section without such a line gets one
  # inserted right after the section header; when no [appearance] section
  # exists at all, a new one is appended at the end of the file. Matching is
  # confined to the [appearance] section region so `accent_color` keys in
  # other sections are never touched.
  @spec rewrite_config_accent(String.t(), String.t()) :: String.t()
  def rewrite_config_accent(contents, accent) do
    lines = String.split(contents, "\n")

    lines =
      case appearance_header_index(lines) do
        nil ->
          append_appearance_section(lines, accent)

        header_index ->
          region_end = next_table_header_index(lines, header_index + 1) || length(lines)

          case accent_line_index(lines, header_index + 1, region_end) do
            nil ->
              List.insert_at(lines, header_index + 1, ~s(accent_color = "#{accent}"))

            line_index ->
              List.replace_at(
                lines,
                line_index,
                replace_accent_value(Enum.at(lines, line_index), accent)
              )
          end
      end

    Enum.join(lines, "\n")
  end

  @accent_header_re ~r/^[ \t]*\[[ \t]*appearance[ \t]*\][ \t]*(?:#.*)?$/
  @table_header_re ~r/^[ \t]*\[/
  @accent_value_re ~r/^([ \t]*)accent_color([ \t]*=[ \t]*)"[^"]*"/

  # Index of the first `[appearance]` table-header line, or nil.
  defp appearance_header_index(lines) do
    Enum.find_index(lines, &Regex.match?(@accent_header_re, &1))
  end

  # Index of the next table-header line at or after `from`, or nil (EOF).
  defp next_table_header_index(lines, from) do
    case Enum.find_index(Enum.drop(lines, from), &Regex.match?(@table_header_re, &1)) do
      nil -> nil
      offset -> from + offset
    end
  end

  # Index of the first accent_color line within [start_idx, end_idx), or nil.
  defp accent_line_index(lines, start_idx, end_idx) do
    case Enum.find_index(
           Enum.slice(lines, start_idx, end_idx - start_idx),
           &Regex.match?(@accent_value_re, &1)
         ) do
      nil -> nil
      offset -> start_idx + offset
    end
  end

  # Replaces the quoted value of an `accent_color = "..."` line, preserving
  # its leading whitespace and any trailing comment.
  defp replace_accent_value(line, accent) do
    Regex.replace(@accent_value_re, line, ~s(\\1accent_color\\2"#{accent}"), global: false)
  end

  # Appends a fresh `[appearance]` section with the accent_color line,
  # separated from any prior content by a blank line.
  defp append_appearance_section(lines, accent) do
    tail = ["[appearance]", ~s(accent_color = "#{accent}")]

    case List.last(lines) do
      nil -> tail
      last -> if String.trim(last) == "", do: lines ++ tail, else: lines ++ ["" | tail]
    end
  end

  # Race safety net after the pre-flight gate: checks whether distribution is
  # enabled for the expected node and enables it only if not. Distribution may
  # legitimately be enabled between the pre-flight check in do_bootstrap/2 and
  # this launch point (another bootstrap, a manual `remote start`), so the
  # decision is re-checked here — this function is no longer the primary
  # running/not-running decision. When distribution IS enabled, its identity is
  # verified against the current contract before declaring success: the cookie
  # is fixed per machine at enable time and cannot be compared, so the identity
  # check is the node name reported by `<launcher> remote status`. Distribution
  # enabled for another target, or enabled manually, would otherwise silently
  # "succeed" and then fail every connect. A mismatch is NOT auto-repaired (the
  # instance may be serving another local node's session) — it fails loudly
  # with remediation. The :starting_daemon stage is broadcast only on the enable
  # path — an already-enabled, identity-matching instance completes without any
  # broadcast.
  defp maybe_start_daemon(ssh_target, launcher_path, target, cookie, state) do
    unit = daemon_unit(target)
    expected_node = remote_node_name(target)

    case remote_status(ssh_target, launcher_path, unit) do
      {:running, ^expected_node, _port} ->
        :ok

      {:running, found_node, found_port} ->
        {:error,
         {:daemon_identity_mismatch,
          daemon_identity_mismatch_details(
            launcher_path,
            unit,
            found_node,
            found_port,
            expected_node
          )}}

      _not_running ->
        # `:stopped`, or a status call that could not run at all (a first-time
        # host has no launcher yet) — either way the CLI must be asked to enable
        # distribution (starting the instance first when none is running). The
        # `remote start` itself is the health signal: the CLI waits for the
        # answer and its exit status is the outcome, so there is no poll loop
        # here.
        set_stage(state, target, :starting_daemon)
        start_daemon_via_cli(ssh_target, launcher_path, target, cookie)
    end
  end

  # On-the-fly NixOS support: the genesis_server release is a glibc-linked
  # tarball that cannot execute on NixOS hosts (no /lib64/ld-linux-x86-64.so.2).
  # For Linux remotes where distribution is not already enabled, detect NixOS
  # (one SSH round trip) and — when detected — patch the extracted release's ELF
  # binaries with a Nix-built patchelf, mirroring the NixOS vscode-remote-ssh
  # extension patch pattern. A release whose instance already has distribution
  # enabled is NEVER patched; non-Linux hosts are untouched. Returns
  # {:ok, state} (patched or skipped) or
  # {:error, {:nixos_patch_failed, details}}.
  #
  # The enabled check goes through the release CLI's `remote status`: on a fresh
  # NixOS host the unpatched launcher cannot execute at all, so a status ERROR
  # has to mean "not enabled, patch it".
  defp maybe_patch_nixos(state, target, ssh_target, "Linux", launcher_path) do
    case remote_status(ssh_target, launcher_path, daemon_unit(target)) do
      {:running, _node, _port} ->
        {:ok, state}

      _not_running ->
        case run_ssh_command_retry(
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

  # Number of output characters carried on error tuples — enough for the remote
  # command's own error line(s) without flooding a toast/`last_error`.
  @output_tail_chars 600

  # Last ~600 characters of the remote command output (`stdout`, plus `stderr`
  # for the calls that pass `merge_stderr: true`), trimmed; `""` when the output
  # is blank or absent.
  defp output_tail(output) when is_binary(output) do
    output |> String.trim() |> String.slice(-@output_tail_chars, @output_tail_chars)
  end

  defp output_tail(_output), do: ""

  # The per-target identity token — the ONE place it is formatted. The release
  # CLI accepts it as `--unit` and derives nothing else from it: distribution
  # runs on the host's ONE Genesis server instance, so the unit string is an
  # IDENTITY (and, on `remote start`, the name used to clean up a legacy
  # per-target daemon unit left behind by an older bootstrap), never a process
  # this module starts or stops.
  defp daemon_unit(target), do: "genesis-remote-#{target.id}"

  # Asks the release CLI whether distribution is enabled on the host's Genesis
  # server instance: `"<launcher>" remote status --unit <unit>`.
  #
  # Returns:
  #
  #   * `{:running, node, dist_port}` — exit 0 and a parseable status line
  #     (`running node=<node> dist_port=<port>`): distribution IS enabled.
  #     Unparsable output is reported as `{:running, nil, nil}` so the identity
  #     check fails loudly instead of silently trusting it.
  #   * `:stopped` — a non-zero exit whose output says `stopped` (the CLI's
  #     documented "not enabled" answer; the instance itself may well still be
  #     serving HTTP).
  #   * `{:error, {:daemon_status_failed, status, tail}}` — any other non-zero
  #     exit (an absent launcher on a first-time host, a broken install, …).
  #   * `{:error, :daemon_status_timeout}` — no answer within `@cmd_timeout_ms`.
  #
  # The parse is deliberately PURE and local: the CLI's stdout contract is the
  # only source of truth here.
  defp remote_status(ssh_target, launcher_path, unit) do
    command = "\"#{launcher_path}\" remote status --unit #{unit}"

    # `merge_stderr: true` — the failure tail is the useful part of a broken
    # status call (ssh's transport diagnostics and the shell's "not found" line
    # are on stderr).
    case run_ssh_command_retry(ssh_target, command, @cmd_timeout_ms, merge_stderr: true) do
      {:ok, output, 0} ->
        parse_daemon_status(output)

      {:ok, output, status} ->
        if String.contains?(String.trim(output), "stopped") do
          :stopped
        else
          {:error, {:daemon_status_failed, status, output_tail(output)}}
        end

      :timeout ->
        {:error, :daemon_status_timeout}
    end
  end

  @daemon_status_re ~r/^running\s+node=(\S+)\s+dist_port=(\d+)/m

  # Parses the CLI's `running node=<node> dist_port=<port>` line. An exit-0
  # answer with no parseable line still counts as running — with nil identity,
  # which the caller reports as an identity mismatch.
  defp parse_daemon_status(output) when is_binary(output) do
    case Regex.run(@daemon_status_re, output) do
      [_line, node, port] -> {:running, node, String.to_integer(port)}
      nil -> {:running, nil, nil}
    end
  end

  # Human-readable details for the {:daemon_running, details} refusal returned
  # when bootstrap is called with on_running: :refuse while distribution is
  # already enabled on the host's Genesis server instance. The caller
  # (dashboard) shows a permission dialog from this tuple.
  #
  # Wording note: the unit string is an IDENTITY (the node name / `--unit`
  # argument), not a process — re-bootstrapping DETACHES that distribution
  # identity and re-enables it under this connection's node name. Nothing is
  # killed: the host's single Genesis server instance keeps serving HTTP and its
  # tasks keep running.
  defp daemon_running_details(target) do
    "the remote host already has Erlang distribution enabled for " <>
      "#{daemon_unit(target)}; re-bootstrapping would disconnect that node and " <>
      "re-enable distribution with this connection's identity — the server and " <>
      "its tasks keep running (pass on_running: :restart to proceed)"
  end

  # Plain-string details for {:daemon_identity_mismatch, details}: what
  # `remote status` reported vs the node the current contract requires, plus
  # the exact remediation. Distribution enabled under a mismatched node is
  # NEVER auto-detached — the instance may be serving another local node's
  # session — so the message names the one command the user (or a later
  # bootstrap with permission) must run.
  #
  # `remote stop` only DISABLES Erlang distribution for that identity: the
  # host's single Genesis server instance keeps serving HTTP and its tasks keep
  # running. Stopping the instance itself is `genesis stop`, which this message
  # mentions only so the two actions are not confused.
  defp daemon_identity_mismatch_details(
         launcher_path,
         unit,
         found_node,
         found_port,
         expected_node
       ) do
    reported =
      case {found_node, found_port} do
        {nil, _port} -> "`running` with no parseable node line"
        {node, nil} -> "node=#{node}"
        {node, port} -> "node=#{node} dist_port=#{port}"
      end

    "the remote Genesis server instance reports #{reported} for #{unit}, but " <>
      "the current contract requires node #{expected_node}. That distribution " <>
      "identity was established by an older bootstrap or enabled manually; " <>
      "detach it with `\"#{launcher_path}\" remote stop --unit #{unit}` (this " <>
      "only disables Erlang distribution — the server and its tasks keep " <>
      "running) and re-run bootstrap. Use `genesis stop` on the remote host only " <>
      "if you actually want to stop the server instance."
  end

  # Detaches distribution through the release CLI:
  # `"<launcher>" remote stop --unit <unit>`, which is idempotent. It only
  # clears the runtime distribution toggle — the host's Genesis server instance
  # keeps serving HTTP and its tasks keep running (`genesis stop` is what stops
  # the instance itself).
  #
  # Best-effort: only reached when the user permitted the re-point
  # (`on_running: :restart`). A failed stop is logged as a warning and bootstrap
  # continues — the `remote start` below surfaces any real failure.
  defp stop_daemon_via_cli(ssh_target, launcher_path, unit) do
    command = "\"#{launcher_path}\" remote stop --unit #{unit}"

    # `merge_stderr: true` — the output only feeds the warning tail below, and a
    # stop failure's useful text (permission denied, no such unit) is on stderr.
    case run_ssh_command_retry(ssh_target, command, @cmd_timeout_ms, merge_stderr: true) do
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

  # Enables distribution through the release CLI and waits for its answer:
  #
  #   "<launcher>" remote start --node <node> --cookie <cookie> \
  #     --dist-port <port> --unit <unit> --wait 30
  #
  # On a cold host the CLI brings the host's Genesis server instance up first
  # (exactly like `genesis start`), then enables distribution on that same BEAM
  # at runtime; when the instance is already serving HTTP only the toggle
  # changes. The CLI blocks until the instance answers (its own `--wait`
  # budget), and it picks the systemd scope / launchd plist / setsid fallback
  # itself, so its EXIT STATUS is the health signal — there is no separate
  # health poll on this side.
  #
  # NOT retried: this is the ONE state-changing call of the flow (start the
  # instance when needed + enable distribution), so it does not go through the
  # transport-retry seam `run_ssh_command_retry/4` that idempotent read/verify
  # commands use (`remote status`, probes). `merge_stderr: true` so a failure
  # tail carries ssh's own transport diagnostics as well as the CLI's stderr.
  defp start_daemon_via_cli(ssh_target, launcher_path, target, cookie) do
    node = remote_node_name(target)
    port = Map.get(target, :dist_port) || @default_remote_dist_port
    unit = daemon_unit(target)

    command =
      "\"#{launcher_path}\" remote start --node #{node} --cookie #{cookie} " <>
        "--dist-port #{port} --unit #{unit} --wait #{@daemon_start_wait_s}"

    case run_ssh_command(ssh_target, command, @daemon_start_timeout_ms, merge_stderr: true) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        {:error, {:daemon_launch_failed, status, output_tail(output)}}

      :timeout ->
        # The CLI blocks for its whole `--wait` budget plus the instance's boot
        # on a cold host, so a transport timeout can still be a successful
        # enable. ONE cheap confirm via `remote status` — never a poll loop (the
        # CLI already waited).
        case remote_status(ssh_target, launcher_path, unit) do
          {:running, ^node, _port} -> :ok
          _not_started -> {:error, {:daemon_launch_failed, :timeout}}
        end
    end
  end

  # Tunnel-readiness poll cadence of the connect worker. Read per call from the
  # app-env seam :remote_tunnel_poll_interval_ms (default = production 100ms).
  defp tunnel_poll_interval_ms do
    Application.get_env(:evo_git, :remote_tunnel_poll_interval_ms, @tunnel_poll_interval_ms)
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

  # Clears the connect-worker bookkeeping ({pid, monitor_ref}) from state,
  # demonitoring the worker and flushing any already-delivered :DOWN so a late
  # crash report can't double-fire after a result was processed.
  defp clear_connect_worker(%__MODULE__{connect_worker: nil} = state), do: state

  defp clear_connect_worker(%__MODULE__{connect_worker: {_worker, ref}} = state) do
    Process.demonitor(ref, [:flush])
    %{state | connect_worker: nil}
  end

  # GenServer-side handling of a failed connect (error result or worker crash):
  # clears the worker bookkeeping, disconnects any half-established remote node
  # (harmless no-op when never connected), sets phase :error with the failure
  # detail and BROADCASTS it — every connect failure arm must surface on
  # "remote_connections" so the UI can leave the connecting state.
  #
  # During :connecting the GenServer owns no tunnel Port (the worker does, and
  # either closed it on the error path or died with it on the crash path), so
  # there is nothing else to tear down here.
  defp fail_connect(%__MODULE__{} = state, error_msg) do
    state = clear_connect_worker(state)
    disconnect_node(state.node)
    new_state = %{state | phase: :error, last_error: error_msg}
    broadcast_status(state.target, new_state)
    new_state
  end

  # ── Command runner ─────────────────────────────────────────────────

  # Runs a command via Port.open and collects stdout output, waiting for the
  # exit status. Returns {:ok, output, exit_status} or :timeout.
  #
  # stderr is merged into the captured output (`:stderr_to_stdout`): every caller
  # here (scp of the tarball / the config files, the local curl download)
  # discards stdout on success and only reports a failure TAIL, and scp/curl
  # write their diagnostics to stderr — without the merge that tail is always
  # empty.
  #
  # The port is linked to this process (trap_exit is set in init/1), but we
  # explicitly receive data and exit_status messages rather than relying on
  # EXIT messages, so we can collect stdout.
  defp run_cmd(cmd, timeout) do
    port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stream, :stderr_to_stdout])
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
  # (`$SHELL -c "<command>"`), the command is additionally wrapped by
  # `EvoGit.RemoteBootstrap.sh_wrap/1` as `/bin/sh -c '<script>'` — a plain
  # command word plus ONE single-quoted word, the only construction that parses
  # identically in a fish, nushell, tcsh, zsh, bash or plain POSIX login shell.
  # The inner script is POSIX sh and SINGLE-QUOTE-FREE BY CONSTRUCTION (a
  # single quote would be unparseable in nushell/tcsh), which is what makes the
  # plain quoted form safe. The interpreter is `/bin/sh` and NOT
  # `/usr/bin/env bash`: NixOS has no `/usr/bin/env`, while `/bin/sh` is the
  # POSIX-mandated absolute path and is NixOS's `environment.binsh`. The
  # interpreter string comes from the app env `:remote_shell` (test seam).
  #
  # Options:
  #   * `:merge_stderr` (default `false`) — capture the child's stderr into the
  #     returned output. ssh sends BOTH its own transport diagnostics
  #     ("Permission denied (publickey)", "Connection reset by peer", a
  #     first-connect "Warning: Permanently added ...") and the remote
  #     command's stderr there, so without it a failure tail is empty. It is
  #     OPT-IN because the merged text is noise to a caller that
  #     content-matches stdout (the platform probe, `test -f` + echo), so only
  #     the diagnostic paths that consume the tail (staging, `remote status`,
  #     `remote stop`, `remote start`) enable it. The local `run_cmd/2` always
  #     merges (`:stderr_to_stdout`).
  @doc false
  def run_ssh_command(ssh_target, remote_cmd, timeout, opts \\ []) do
    ssh = System.find_executable("ssh") || "ssh"
    remote_cmd = EvoGit.RemoteBootstrap.sh_wrap(remote_cmd)

    port_opts =
      if Keyword.get(opts, :merge_stderr, false),
        do: [:binary, :exit_status, :stream, :stderr_to_stdout],
        else: [:binary, :exit_status, :stream]

    port = Port.open({:spawn_executable, ssh}, port_opts ++ [{:args, [ssh_target, remote_cmd]}])

    collect_port_output(port, timeout, "")
  end

  # Runs an IDEMPOTENT remote command, retrying ONCE when the first attempt
  # fails with ssh's OWN exit code 255 (dropped session / too-many-fast
  # connections — ssh's transport-level errors; chmod itself exits 1, so 255 is
  # never the remote command's own status). A `:timeout` is NOT retried: the
  # command may still be running remotely.
  #
  # The backoff is read per call from the app-env seam
  # :remote_ssh_retry_backoff_ms (default 400ms; tests set it to 0) and can be
  # overridden with `backoff_ms: <ms>` in `opts`. Every other `opts` key is
  # forwarded to `run_ssh_command/4` (notably `merge_stderr: true`).
  #
  # ONLY idempotent / read-only commands go through here — never `remote start`
  # (the one state-changing call: it starts the instance when needed and enables
  # distribution at runtime), `scp`, the download commands or the NixOS patch
  # script.
  @doc false
  @spec run_ssh_command_retry(String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t(), non_neg_integer()} | :timeout
  def run_ssh_command_retry(ssh_target, remote_cmd, timeout, opts \\ []) do
    case run_ssh_command(ssh_target, remote_cmd, timeout, opts) do
      {:ok, output, 255} ->
        Logger.warning(
          "RemoteConnection: ssh #{ssh_target} exited 255 (transport error) running " <>
            "#{truncate_command(remote_cmd)}#{tail_suffix(output)} — retrying once"
        )

        backoff = Keyword.get(opts, :backoff_ms, remote_ssh_retry_backoff_ms())

        if is_integer(backoff) and backoff > 0, do: Process.sleep(backoff)

        run_ssh_command(ssh_target, remote_cmd, timeout, opts)

      result ->
        result
    end
  end

  defp remote_ssh_retry_backoff_ms do
    Application.get_env(:evo_git, :remote_ssh_retry_backoff_ms, @remote_ssh_retry_backoff_ms)
  end

  # Shortens a remote command for a log line (NixOS/staging commands are long).
  defp truncate_command(command) when is_binary(command) do
    if String.length(command) > 120, do: String.slice(command, 0, 120) <> "…", else: command
  end

  # ": <tail>" for a non-blank output excerpt, "" otherwise.
  defp tail_suffix(output) do
    case output_tail(output) do
      "" -> ""
      tail -> ": " <> tail
    end
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
    # ConnectTimeout bounds ssh's own connection-establishment phase so an
    # unreachable/dead host fails inside the @tunnel_wait_timeout_ms tunnel
    # budget instead of hanging on the OS TCP timeout (seconds...minutes).
    parts =
      [
        "ssh",
        "-L #{local_port}:127.0.0.1:#{remote_port}",
        "-N",
        "-o ServerAliveInterval=30",
        "-o ServerAliveCountMax=3",
        "-o ConnectTimeout=#{div(@ssh_connect_timeout_ms, 1000)}",
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
  # timeouts; it is an implementation detail of the connect worker's
  # `establish_tunnel_and_node/1`.
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

  @doc """
  Renders a bootstrap/connect failure reason as a human-readable message.

  Every reason the bootstrap chain can return is covered, including the remote
  output tail (stdout+stderr merged by `run_ssh_command/3`) carried by the
  3-element error shapes:

    * `{:scp_failed, 1, tail}` → `"scp upload failed (exit 1): <tail>"`
    * `{:staging_failed, 255, tail}` →
      `"extracting/setting permissions failed (ssh exit 255): <tail>"`
    * `{:daemon_launch_failed, 1, tail}` → `"daemon launch failed (exit 1): <tail>"`
    * `{:probe_failed, {:exit_status, 9, tail}}` →
      `"platform probe failed (exit 9): <tail>"`
    * `{:download_failed, ...}` → a nested download / scp / local-curl message

  The older 2-element shapes are accepted too. An already-formatted binary
  reason is returned unchanged, and an unknown reason falls back to `inspect/1`
  — this function never raises.
  """
  @spec format_reason(term()) :: String.t()

  # An already-formatted message (e.g. a reason rendered by a nested formatter)
  # passes through verbatim — quoting it via `inspect/1` would mangle the text.
  def format_reason(reason) when is_binary(reason), do: reason

  def format_reason({:distribution_failed, reason}) do
    "distribution setup failed: " <> format_reason(reason)
  end

  def format_reason({:tunnel_not_ready, reason}) do
    "SSH tunnel did not become ready: " <> tunnel_failure(reason)
  end

  def format_reason({:port_bind_failed, reason}) do
    "could not find a free local port (#{inspect(reason)})"
  end

  # ── staging / upload ────────────────────────────────────────────────

  def format_reason({:staging_failed, status, tail}) do
    append_tail("extracting/setting permissions failed (ssh exit #{status})", tail)
  end

  def format_reason({:staging_failed, :timeout}), do: "extracting/setting permissions timed out"

  def format_reason({:staging_failed, status}) do
    "extracting/setting permissions failed (ssh exit #{status})"
  end

  # Legacy chmod/extract reasons (the two former separate round trips).
  def format_reason({:chmod_failed, status, tail}) do
    append_tail("setting permissions failed (ssh exit #{status})", tail)
  end

  def format_reason({:chmod_failed, :timeout}), do: "setting permissions timed out"

  def format_reason({:chmod_failed, status}),
    do: "setting permissions failed (ssh exit #{status})"

  def format_reason({:extract_failed, status, tail}) do
    append_tail("extracting the release tarball failed (ssh exit #{status})", tail)
  end

  def format_reason({:extract_failed, :timeout}), do: "extracting the release tarball timed out"

  def format_reason({:extract_failed, status}) do
    "extracting the release tarball failed (ssh exit #{status})"
  end

  def format_reason({:scp_failed, status, tail}) do
    append_tail("scp upload failed (exit #{status})", tail)
  end

  def format_reason({:scp_failed, :timeout}), do: "scp upload timed out"
  def format_reason({:scp_failed, status}), do: "scp upload failed (exit #{status})"

  # ── download ────────────────────────────────────────────────────────

  def format_reason({:download_failed, detail}), do: download_failure(detail)

  # ── daemon launch ───────────────────────────────────────────────────

  def format_reason({:daemon_launch_failed, status, tail}) when is_integer(status) do
    append_tail("daemon launch failed (exit #{status})", tail)
  end

  def format_reason({:daemon_launch_failed, status}) when is_integer(status) do
    "daemon launch failed (exit #{status})"
  end

  def format_reason({:daemon_launch_failed, :timeout}), do: "daemon launch timed out"

  # The release CLI's `remote status` failed (only ever logged — a failing
  # status call never fails bootstrap, see do_bootstrap/2).
  def format_reason({:daemon_status_failed, status, tail}) when is_integer(status) do
    append_tail("daemon status check failed (exit #{status})", tail)
  end

  def format_reason({:daemon_status_failed, status}) when is_integer(status) do
    "daemon status check failed (exit #{status})"
  end

  def format_reason(:daemon_status_timeout), do: "daemon status check timed out"

  # ── platform probe ──────────────────────────────────────────────────

  def format_reason({:probe_failed, {:exit_status, status, tail}}) do
    append_tail("platform probe failed (exit #{status})", tail)
  end

  def format_reason({:probe_failed, {:exit_status, status}}) do
    "platform probe failed (exit #{status})"
  end

  def format_reason({:probe_failed, {:unexpected_output, output}}) do
    "platform probe returned unexpected output: #{output}"
  end

  def format_reason({:probe_failed, :timeout}), do: "platform probe timed out"

  def format_reason({:probe_failed, reason}),
    do: "platform probe failed: #{format_reason(reason)}"

  # ── reasons that already carry their own actionable text ────────────

  def format_reason({:daemon_running, details}) when is_binary(details), do: details

  def format_reason({:daemon_identity_mismatch, details}) when is_binary(details), do: details

  def format_reason({:nixos_patch_failed, details}) when is_binary(details), do: details

  # ── platform resolution ─────────────────────────────────────────────

  def format_reason({:invalid_platform, platform}), do: "invalid platform #{inspect(platform)}"
  def format_reason(:unsupported_platform), do: "unsupported platform"
  def format_reason(:target_not_found), do: "remote target not found"

  def format_reason(reason), do: inspect(reason)

  # Appends a remote-output excerpt to a human message; a blank tail adds
  # nothing.
  defp append_tail(message, tail) when is_binary(tail) do
    case String.trim(tail) do
      "" -> message
      trimmed -> "#{message}: #{trimmed}"
    end
  end

  defp append_tail(message, _tail), do: message

  # Tunnel-readiness failure detail (`wait_for_tunnel/4` reasons).
  defp tunnel_failure({:timeout, output}), do: append_tail("timed out", output)

  defp tunnel_failure({:ssh_exited, status, output}) when is_integer(status) do
    append_tail("ssh exited with status #{status}", output)
  end

  defp tunnel_failure({:ssh_exited, reason, output}) do
    append_tail("ssh exited (#{inspect(reason)})", output)
  end

  defp tunnel_failure(other), do: format_reason(other)

  # Download failure detail shapes: remote curl/wget exit, local curl exit,
  # the local scp arm and the local cache mkdir arm.
  defp download_failure({:exit_status, status, tail}) do
    append_tail("download failed (exit #{status})", tail)
  end

  defp download_failure({:exit_status, status}), do: "download failed (exit #{status})"
  defp download_failure(:timeout), do: "download timed out"

  defp download_failure({:local, reason}) do
    case reason do
      {:exit_status, status, tail} ->
        append_tail("local download failed (exit #{status})", tail)

      {:exit_status, status} ->
        "local download failed (exit #{status})"

      :timeout ->
        "local download timed out"

      {:mkdir_failed, why} ->
        "local download failed: could not create the cache directory (#{inspect(why)})"

      other ->
        "local download failed: #{inspect(other)}"
    end
  end

  defp download_failure({:local_scp, reason}), do: format_reason(reason)
  defp download_failure(other), do: "download failed: #{inspect(other)}"

  # Builds an actionable multi-line diagnostics string for a failed
  # Node.connect — assigned to `last_error` (what the dashboard's connection
  # gate renders) and logged via Logger.error. The public reason tuple stays
  # {:node_connect_failed, inspect(remote_node)} — no caller destructures the
  # inner tuple, and the reason shape is part of the public contract.
  #
  # The remediation is expressed through the release CLI, using the target's own
  # configured launcher path, ssh target and unit name — no systemd or launchd
  # command is named here, because the CLI owns that decision.
  defp node_connect_failed_diagnostics(node_name, local_port, remote_port, node_cookie, target) do
    cookie_status =
      cond do
        is_binary(node_cookie) and node_cookie != "" ->
          "set (#{String.slice(node_cookie, 0, 6)}...)"

        true ->
          "not set — run bootstrap first to auto-generate one"
      end

    ssh_target = target.ssh_target
    launcher_path = remote_paths(target).launcher_path
    unit = daemon_unit(target)

    status_hint = "ssh #{ssh_target} '\"#{launcher_path}\" remote status --unit #{unit}'"
    logs_hint = "ssh #{ssh_target} '\"#{launcher_path}\" remote logs --unit #{unit}'"
    stop_hint = "ssh #{ssh_target} '\"#{launcher_path}\" remote stop --unit #{unit}'"

    """
    Could not connect to remote Erlang node #{node_name}.
      Tunnel:       127.0.0.1:#{local_port} -> 127.0.0.1:#{remote_port}
      Local cookie: #{cookie_status}
    The remote Genesis server instance has Erlang distribution enabled under
    whatever node name its unit was started with. A mismatch means it was
    launched for another target (or by an older bootstrap) — compare with:
      #{status_hint}
      #{logs_hint}
    Then detach that distribution identity (`#{stop_hint}` — this only disables
    Erlang distribution; the server and its tasks keep running) and re-run
    bootstrap. Stopping the instance itself is `genesis stop` on the remote host.
    The distribution port is pinned when the unit is started, so a target whose
    dist_port changed must be re-bootstrapped (with permission) to move it.
    """
  end
end
