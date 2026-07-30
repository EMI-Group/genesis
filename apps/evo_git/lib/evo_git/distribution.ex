defmodule EvoGit.Distribution do
  @moduledoc """
  Runtime-configurable distributed Erlang support.

  When the user enables distribution in their config (the [node] category),
  this module starts EPMD from the running ERTS, enables the distributed
  node via :net_kernel, and sets the magic cookie — all at application startup.

  This allows the local dashboard node to participate in Erlang distribution
  and connect to remote genesis_remote nodes via SSH tunnels managed by
  EvoGit.RemoteConnection.
  """

  require Logger

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
  Enables distribution on-demand for SSH remote connection.

  Called by `EvoGit.RemoteConnection` when the local node is not yet
  distributed. Sets up EPMD-less distribution with a free port range for
  the local side (9100-9200) and the cookie matching the remote daemon.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec enable_for_remote(map()) :: :ok | {:error, term()}
  def enable_for_remote(target) do
    if distributed?() do
      :ok
    else
      enable_for_connection(target)
    end
  end

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

  defp enable_for_connection(target) do
    # Configure EPMD-less distribution listen ports for the local side.
    # The remote daemon listens on 9000; we use 9100-9200 locally to avoid
    # conflict. The SSH tunnel forwards local_port → remote_port 9000.
    unless Application.get_env(:kernel, :inet_dist_listen_min) do
      Application.put_env(:kernel, :inet_dist_listen_min, 9100)
    end

    unless Application.get_env(:kernel, :inet_dist_listen_max) do
      Application.put_env(:kernel, :inet_dist_listen_max, 9200)
    end

    # Always use our EPMD-less module when starting distribution on-demand.
    Application.put_env(:kernel, :epmd_module, Elixir.EvoGit.EpmdDist)

    case :net_kernel.start([:"genesis@127.0.0.1", :longnames]) do
      {:ok, _pid} ->
        # Set the distribution cookie to match the remote daemon. Must be
        # done after :net_kernel.start succeeds — set_cookie/1 crashes on
        # a non-distributed node (:nonode@nohost).
        case Map.get(target, :cookie) do
          nil ->
            Logger.debug("Skipping Node.set_cookie/1 in enable_for_connection: no cookie in target map")

          cookie when is_binary(cookie) ->
            Node.set_cookie(String.to_atom(cookie))
        end
        Logger.info("Distribution enabled for remote connection: #{node()}")
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {:already_started, _pid}, _mode} ->
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

    case :net_kernel.start([name, mode]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {:already_started, _pid}, _mode} ->
        :ok

      {:error, reason} ->
        {:error, reason}
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
