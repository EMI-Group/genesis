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

  defp start_epmd_if_configured(node_config) do
    if Map.get(node_config, :start_epmd, true) do
      start_epmd()
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
    name = node_name_from_config(node_config) |> String.to_atom()
    mode = if Map.get(node_config, :shortnames, false), do: :shortnames, else: :longnames

    case :net_kernel.start({name, mode}) do
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

  defp set_cookie(node_config) do
    cookie = Map.get(node_config, :cookie, "genesis_cookie")
    Node.set_cookie(String.to_atom(cookie))
    :ok
  end

  defp node_name_from_config(node_config) do
    Map.get(node_config, :node_name, "genesis@127.0.0.1")
  end
end
