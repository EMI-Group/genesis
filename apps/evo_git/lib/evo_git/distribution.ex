defmodule EvoGit.Distribution do
  @moduledoc """
  Runtime-configurable distributed Erlang support.

  When the user enables distribution in their config (the [node] category),
  this module starts EPMD from the running ERTS, enables the distributed
  node via :net_kernel, and sets the magic cookie — all at application startup.

  This allows the local dashboard node to participate in Erlang distribution
  and connect to remote genesis_server nodes via SSH tunnels managed by
  EvoGit.RemoteConnection.
  """

  require Logger

  # Shape accepted by enable_runtime/3's `node_name` argument: `name@host`, both
  # parts restricted to the characters an Erlang node name can actually carry.
  # Validated BEFORE any String.to_atom/1 so a malformed CLI-supplied name can
  # never create an unbounded atom, nor reach :net_kernel.
  @runtime_node_name ~r/\A[A-Za-z0-9][A-Za-z0-9_.\-]*@[A-Za-z0-9][A-Za-z0-9_.\-]*\z/

  @doc """
  Enables distributed Erlang at application startup if configured.

  Reads the `[node]` config category. When `node.enabled` is true, this
  function starts EPMD (if configured), enables distribution via
  `:net_kernel`, and sets the magic cookie.

  If the node is already running in distributed mode (started with
  `-sname`/`-name` via release env vars), only the cookie is set — we do
  not attempt to re-start distribution.

  Returns:
  - `:ok` on success
  - `{:ok, :already_distributed}` if the node was already distributed
  - `{:error, reason}` on failure (a warning is logged but the application
    is NOT crashed)
  """
  @spec maybe_enable() :: :ok | {:ok, :already_distributed} | {:error, term()}
  def maybe_enable do
    config = EvoGit.Config.resolve()

    node_config = config |> Map.get(:node, %{})
    enabled = Map.get(node_config, :enabled, false)

    if not enabled do
      :ok
    else
      enable(node_config)
    end
  end

  @doc """
  Returns `true` if the local node is already running in distributed mode
  (i.e., the node name is not `:nonode@nohost`).
  """
  @spec distributed?() :: boolean()
  def distributed? do
    node() != :nonode@nohost
  end

  @doc """
  Enables Erlang distribution **at runtime**, pinning ONE listen port.

  This is the daemon-side runtime toggle: it starts distribution on an
  already-running, non-distributed BEAM so the SAME `genesis_server` instance
  can keep serving HTTP and additionally become reachable over distribution,
  without a daemon restart (and therefore without a second daemon unit).

  The `:kernel` distribution envs are pinned UNCONDITIONALLY (before any
  start attempt) to `inet_dist_listen_min = inet_dist_listen_max = dist_port`,
  and `epmd_module` is set to `EvoGit.EpmdDist` (EPMD-less), so a subsequent
  `Node.connect/1` from a local dashboard resolves the listen port through
  `EvoGit.EpmdDist`'s registry.

  Idempotent: when the node is already distributed under exactly `node_name`
  the cookie is re-applied and the call succeeds. When the node is already
  distributed under a DIFFERENT name it is stopped first and restarted under
  the requested one — deliberately: this is the "switch remote identity
  without restarting the daemon" path, so any existing cross-node links of the
  old identity are dropped.

  Returns `{:ok, %{node: actual_node, dist_port: dist_port}}` (the ACTUAL
  `node()`, as a string) or `{:error, reason}`. Never raises.
  """
  @spec enable_runtime(String.t(), String.t(), pos_integer()) ::
          {:ok, %{node: String.t(), dist_port: integer()}} | {:error, term()}
  def enable_runtime(node_name, cookie, dist_port) do
    with {:ok, name} <- runtime_node_atom(node_name),
         {:ok, port} <- runtime_dist_port(dist_port) do
      # Centralised boundary around VM-global distribution state and an
      # externally supplied node name: `:net_kernel`/`Node` calls exit on a
      # malformed name or a socket that cannot be bound, and the CONTROL PLANE
      # that calls this must report a failure, never crash on it.
      try do
        pin_dist_port(port)
        ensure_epmd_module()

        cond do
          distributed?() and to_string(node()) == node_name ->
            apply_runtime_cookie(cookie)
            {:ok, %{node: to_string(node()), dist_port: port}}

          distributed?() ->
            # Identity takeover: drop the current distribution first (its links
            # die with it) and come back up under the requested name.
            Logger.info(
              "Distribution runtime takeover: stopping #{node()} to become #{node_name}"
            )

            _ = Node.stop()
            start_runtime_node(name, cookie, port)

          true ->
            start_runtime_node(name, cookie, port)
        end
      rescue
        error ->
          Logger.warning(
            "Failed to enable distribution at runtime (#{node_name}): " <>
              Exception.message(error)
          )

          {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason ->
          Logger.warning(
            "Failed to enable distribution at runtime (#{node_name}): #{inspect({kind, reason})}"
          )

          {:error, {kind, reason}}
      end
    end
  end

  @doc """
  Disables Erlang distribution at runtime.

  `:ok` whether or not the node was distributed (idempotent). The pinned
  `:kernel` listen port is deliberately left in place — `active/0` keeps
  reporting it, and the next `enable_runtime/3` pins it again anyway.
  """
  @spec disable_runtime() :: :ok
  def disable_runtime do
    if distributed?() do
      case Node.stop() do
        :ok ->
          :ok

        other ->
          Logger.warning("Failed to stop distribution: #{inspect(other)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Reports the ACTUAL current distribution state.

  `enabled` is `distributed?/0`; `node` is the real `node()` as a string
  (`"nonode@nohost"` when distribution is off); `dist_port` is the pinned
  `:kernel` `inet_dist_listen_min` (which a release booted with
  `RELEASE_DISTRIBUTION=name` also sets via its vm.args), or `nil`.
  """
  @spec active() :: %{enabled: boolean(), node: String.t(), dist_port: integer() | nil}
  def active do
    %{
      enabled: distributed?(),
      node: to_string(node()),
      dist_port: Application.get_env(:kernel, :inet_dist_listen_min)
    }
  end

  @doc """
  Enables distribution on-demand for SSH remote connection.

  Called by `EvoGit.RemoteConnection` when the local node is not yet
  distributed. Sets up EPMD-less distribution with a free port range for
  the local side (9100-9200) and the cookie matching the remote daemon.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec enable_for_remote(map()) :: :ok | {:error, term()}
  def enable_for_remote(_target) do
    # Deliberately NOT delegated to enable_runtime/3: this dashboard path uses
    # the fixed `genesis@127.0.0.1` identity with the 9100-9200 listen RANGE
    # and the `[node] cookie` from config, whereas enable_runtime/3 pins ONE
    # explicit port/cookie for the daemon.

    if distributed?() do
      # Already-distributed nodes (booted via maybe_enable/0 or started with
      # -sname/-name) registered themselves with the REAL epmd daemon, not
      # with EvoGit.EpmdDist. Outbound SSH-tunnel connects resolve the remote
      # daemon's port through EpmdDist's persistent-term registry (see
      # EvoGit.RemoteConnection.do_connect_distributed/1), so ensure the
      # kernel `epmd_module` env points at EpmdDist here too.
      ensure_epmd_module()
      :ok
    else
      enable_for_connection()
    end
  end

  @doc false
  # Ensures the kernel `epmd_module` env is EvoGit.EpmdDist so outbound
  # distribution connection attempts (Node.connect/1) resolve remote ports
  # through EpmdDist's persistent-term registry instead of the real epmd
  # daemon. Idempotent; net_kernel:epmd_module/0 reads this env PER connection
  # attempt (it is not cached at net_kernel init), so flipping it at runtime —
  # after the local node already booted distributed with the default
  # erl_epmd — takes effect for the next outbound connect without disturbing
  # the local node's existing registration with the real epmd daemon.
  def ensure_epmd_module do
    Application.put_env(:kernel, :epmd_module, Elixir.EvoGit.EpmdDist)
  end

  # Pins a SINGLE distribution listen port (as opposed to the 9100-9200 RANGE
  # enable_for_connection/0 leaves in place) so the daemon's advertised port is
  # exactly the one the caller asked for.
  defp pin_dist_port(port) do
    Application.put_env(:kernel, :inet_dist_listen_min, port)
    Application.put_env(:kernel, :inet_dist_listen_max, port)
    :ok
  end

  defp start_runtime_node(name, cookie, port) do
    case start_net_kernel([name, :longnames]) do
      {:ok, _pid} ->
        finalize_runtime_start(name, cookie, port)

      :already_started ->
        finalize_runtime_start(name, cookie, port)

      {:error, reason} ->
        Logger.warning("Failed to start distribution at runtime: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp finalize_runtime_start(name, cookie, port) do
    apply_runtime_cookie(cookie)
    requested = Atom.to_string(name)

    case to_string(node()) do
      ^requested ->
        Logger.info("Distribution enabled at runtime: #{requested}:#{port}")
        {:ok, %{node: requested, dist_port: port}}

      actual ->
        Logger.warning("Distribution is active as #{actual}, not the requested #{requested}")
        {:error, {:wrong_node_name, actual, requested}}
    end
  end

  # `Node.set_cookie/1` crashes on a non-distributed node and on an empty
  # cookie, so it only runs for a non-empty binary — after distribution started.
  defp apply_runtime_cookie(cookie) when is_binary(cookie) and cookie != "" do
    Node.set_cookie(String.to_atom(cookie))
    :ok
  end

  defp apply_runtime_cookie(_cookie), do: :ok

  # String.to_atom/1 is bounded here: the name must match @runtime_node_name
  # first, so only a realistically-shaped `name@host` becomes an atom.
  defp runtime_node_atom(node_name) when is_binary(node_name) do
    if Regex.match?(@runtime_node_name, node_name) do
      {:ok, String.to_atom(node_name)}
    else
      {:error, {:invalid_node_name, node_name}}
    end
  end

  defp runtime_node_atom(node_name), do: {:error, {:invalid_node_name, node_name}}

  defp runtime_dist_port(port) when is_integer(port) and port > 0, do: {:ok, port}
  defp runtime_dist_port(port), do: {:error, {:invalid_dist_port, port}}

  defp enable(node_config) do
    cond do
      distributed?() ->
        # Node started with -sname/-name via release env vars. Don't try
        # to re-start distribution; just ensure the cookie is set.
        set_cookie(node_config)
        Logger.info("Distribution already active (node: #{node()}); cookie applied from config.")
        {:ok, :already_distributed}

      true ->
        start_epmd_if_configured(node_config)

        case enable_distribution(node_config) do
          :ok ->
            set_cookie(node_config)
            Logger.info("Distribution enabled: node #{node_name_from_config(node_config)}")
            :ok

          {:error, reason} = error ->
            Logger.warning("Failed to enable distribution: #{inspect(reason)}")
            error
        end
    end
  end

  defp enable_for_connection do
    # Configure EPMD-less distribution listen ports for the local side.
    # The remote daemon listens on 9000; we use 9100-9200 locally to avoid
    # conflict. The SSH tunnel forwards local_port -> remote_port 9000.
    # (The cookie comes from the config [node] category, not the target map,
    # which has no :cookie field.)
    unless Application.get_env(:kernel, :inet_dist_listen_min) do
      Application.put_env(:kernel, :inet_dist_listen_min, 9100)
    end

    unless Application.get_env(:kernel, :inet_dist_listen_max) do
      Application.put_env(:kernel, :inet_dist_listen_max, 9200)
    end

    # Always use our EPMD-less module when starting distribution on-demand.
    ensure_epmd_module()

    case start_net_kernel([:"genesis@127.0.0.1", :longnames]) do
      {:ok, _pid} ->
        # Set the distribution cookie to match the remote daemon. Must be
        # done after :net_kernel.start succeeds — set_cookie/1 crashes on
        # a non-distributed node (:nonode@nohost). The cookie is read from
        # the persisted config [node] cookie — the SAME source bootstrap
        # writes via ensure_cookie! (the target map has no :cookie field;
        # the old Map.get(target, :cookie) branch was always nil).
        config = EvoGit.Config.resolve()
        cookie = get_in(config, [:node, :cookie])

        case cookie do
          nil ->
            Logger.debug(
              "Skipping Node.set_cookie/1 in enable_for_connection: no [node] cookie configured"
            )

          "" ->
            Logger.debug(
              "Skipping Node.set_cookie/1 in enable_for_connection: [node] cookie is empty"
            )

          cookie when is_binary(cookie) ->
            Node.set_cookie(String.to_atom(cookie))
        end

        Logger.info("Distribution enabled for remote connection: #{node()}")
        :ok

      :already_started ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to enable distribution for remote: #{inspect(reason)}")
        error
    end
  end

  @doc false
  def start_epmd_if_configured(node_config) do
    if Map.get(node_config, :start_epmd, false) do
      start_epmd()
    else
      :ok
    end
  end

  # Starts the EPMD (Erlang Port Mapper Daemon) from the running ERTS.
  #
  # The epmd binary is located relative to :code.root_dir() — this is the
  # ERTS root that the current BEAM is actually running, so it works in
  # releases where epmd may not be on PATH. EPMD is started as a daemon
  # (`epmd -daemon`). If EPMD is already running, `epmd -daemon` returns a
  # non-zero exit; this is expected and not an error, so we return :ok.
  #
  # The try/catch :exit here is justified because:
  #   1. We DO expect this to fail when EPMD is already running — it's an
  #      external process, not an Elixir function with a clean return value.
  #   2. This is a fire-and-forget daemon start; there is no clean process
  #      structure to supervise it, and failure (already running) is benign.
  defp start_epmd do
    epmd_path = epmd_binary_path()

    try do
      System.cmd(epmd_path, ["-daemon"], [])
    catch
      :exit, reason ->
        Logger.debug("EPMD start returned (already running or external exit): #{inspect(reason)}")
    end

    :ok
  end

  defp epmd_binary_path do
    erts_version = :erlang.system_info(:version)
    Path.join([:code.root_dir() |> to_string(), "erts-#{erts_version}", "bin", "epmd"])
  end

  defp enable_distribution(node_config) do
    # Configure EPMD-less distribution: set the listen port range so that
    # :net_kernel.start uses inet_dist without EPMD. Only set these if not
    # already configured (e.g. via vm.args). The remote daemon listens on
    # port 9000 by default, so we use the same port locally for outgoing
    # connections to succeed (EPMD-less requires the connect port to match
    # the listen port of the remote).
    dist_port = Map.get(node_config, :dist_port, 9000)

    if Application.get_env(:kernel, :inet_dist_listen_min) == nil do
      Application.put_env(:kernel, :inet_dist_listen_min, dist_port)
    end

    if Application.get_env(:kernel, :inet_dist_listen_max) == nil do
      Application.put_env(:kernel, :inet_dist_listen_max, dist_port)
    end

    name = node_name_from_config(node_config) |> String.to_atom()
    mode = if Map.get(node_config, :shortnames, false), do: :shortnames, else: :longnames

    case start_net_kernel([name, mode]) do
      {:ok, _pid} ->
        :ok

      :already_started ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Starts `:net_kernel` and normalizes its "already started" results (both the
  # 2-tuple and 3-tuple mode variants) to `:already_started` so callers can treat
  # an already-running distribution as success.
  defp start_net_kernel(args) do
    case :net_kernel.start(args) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        :already_started

      {:error, {:already_started, _pid}, _mode} ->
        :already_started

      other ->
        other
    end
  end

  @doc false
  def set_cookie(node_config) do
    case Map.get(node_config, :cookie) do
      nil ->
        Logger.debug("Skipping Node.set_cookie/1: no cookie configured")
        :ok

      cookie when is_binary(cookie) ->
        Node.set_cookie(String.to_atom(cookie))
        :ok
    end
  end

  defp node_name_from_config(node_config) do
    Map.get(node_config, :node_name, "genesis@127.0.0.1")
  end
end
