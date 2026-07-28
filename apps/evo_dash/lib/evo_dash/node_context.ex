defmodule EvoDash.NodeContext do
  @moduledoc """
  Thin client for the dashboard's SSH remote-development feature.

  This module wraps three layers of the `:evo_git` core, presenting a single
  coherent API to the dashboard LiveViews:

    1. **`EvoGit.RemoteConnections`** — connection-target *persistence* (a TOML
       file store of pure functions). Delegated to directly for
       list/get/save/delete of target definitions.

    2. **`EvoGit.RemoteConnection`** — connection *lifecycle* (a GenServer that
       manages the live SSH tunnel + Erlang distribution). Because this GenServer
       ships as parallel Phase 2 work, it may not be compiled or started yet.
       All lifecycle calls degrade gracefully when the module or process is
       unavailable (see `with_remote_connection/4`).

    3. **Cross-node RPC helpers** — delegates to `EvoGit.RemoteNode` (the
       core-runtime RPC helper), which wraps `:erpc.call/5` to let the dashboard
       read scheduler state (agents, config, paused?) from a *remote* node
       exactly as it reads it locally. Local calls go directly to
       `EvoGit.AgentScheduler.RemoteAPI` / `EvoGit.AgentScheduler`; remote calls
       are routed through `:erpc` with a bounded timeout.

  All functions are safe to call from a LiveView process.
  """

  require Logger

  # ── Connection-target management ──────────────────────────────────
  #
  # Delegates to EvoGit.RemoteConnections, a collection of pure functions over
  # a TOML file store. No guards needed — these always work.

  @doc """
  Lists all stored connection targets.

  Delegates to `EvoGit.RemoteConnections.list/0`.
  """
  @spec list_targets() :: [map()]
  def list_targets do
    EvoGit.RemoteConnections.list()
  end

  @doc """
  Fetches a single connection target by its id.

  Delegates to `EvoGit.RemoteConnections.get/1`.
  """
  @spec get_target(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_target(id) do
    EvoGit.RemoteConnections.get(id)
  end

  @doc """
  Creates or updates a connection target.

  Delegates to `EvoGit.RemoteConnections.save/1`.
  """
  @spec save_target(map()) :: {:ok, map()} | {:error, term()}
  def save_target(target) do
    EvoGit.RemoteConnections.save(target)
  end

  @doc """
  Deletes a connection target by its id.

  Delegates to `EvoGit.RemoteConnections.delete/1`.
  """
  @spec delete_target(String.t()) :: :ok | {:error, :not_found}
  def delete_target(id) do
    EvoGit.RemoteConnections.delete(id)
  end

  # ── Connection lifecycle ─────────────────────────────────────────
  #
  # These delegate to EvoGit.RemoteConnection, a GenServer that manages the live
  # SSH tunnel and Erlang distribution. Because that module ships as parallel
  # Phase 2 work, it may not be compiled or the process may not be started yet.
  # Every call degrades to a safe value via with_remote_connection/4.

  @doc """
  Initiates a connection to the given target.

  Delegates to `EvoGit.RemoteConnection.connect/1`. Returns
  `{:error, :remote_connection_unavailable}` when the connection subsystem is
  not compiled or its process is not started.
  """
  @spec connect(String.t()) :: term() | {:error, :remote_connection_unavailable}
  def connect(target_id) do
    with_remote_connection(
      EvoGit.RemoteConnection,
      :connect,
      [target_id],
      {:error, :remote_connection_unavailable}
    )
  end

  @doc """
  Disconnects from the given target.

  Delegates to `EvoGit.RemoteConnection.disconnect/1`. Returns
  `{:error, :remote_connection_unavailable}` when the connection subsystem is
  not compiled or its process is not started.
  """
  @spec disconnect(String.t()) :: term() | {:error, :remote_connection_unavailable}
  def disconnect(target_id) do
    with_remote_connection(
      EvoGit.RemoteConnection,
      :disconnect,
      [target_id],
      {:error, :remote_connection_unavailable}
    )
  end

  @doc """
  Bootstraps the Genesis runtime on the remote host for the given target.

  Delegates to `EvoGit.RemoteConnection.bootstrap/1`. Returns
  `{:error, :remote_connection_unavailable}` when the connection subsystem is
  not compiled or its process is not started.
  """
  @spec bootstrap(String.t()) :: term() | {:error, :remote_connection_unavailable}
  def bootstrap(target_id) do
    with_remote_connection(
      EvoGit.RemoteConnection,
      :bootstrap,
      [target_id],
      {:error, :remote_connection_unavailable}
    )
  end

  @doc """
  Returns the connection status of all targets as a map of
  `target_id => status`.

  Delegates to `EvoGit.RemoteConnection.list_connections/0`. Returns `%{}`
  when the connection subsystem is not compiled or its process is not started.
  """
  @spec connection_status() :: map()
  def connection_status do
    with_remote_connection(EvoGit.RemoteConnection, :list_connections, [], %{})
  end

  @doc """
  Returns the connection status for a single target.

  Delegates to `EvoGit.RemoteConnection.status/1`. Returns `:disconnected`
  when the connection subsystem is not compiled or its process is not started.
  """
  @spec connection_status(String.t()) :: term() | :disconnected
  def connection_status(target_id) do
    with_remote_connection(EvoGit.RemoteConnection, :status, [target_id], :disconnected)
  end

  @doc """
  Returns `true` if the given target is currently connected.

  Delegates to `EvoGit.RemoteConnection.connected?/1`. Returns `false` when
  the connection subsystem is not compiled or its process is not started.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(target_id) do
    with_remote_connection(EvoGit.RemoteConnection, :connected?, [target_id], false)
  end

  # ── Cross-node RPC helpers ───────────────────────────────────────
  #
  # These delegate to EvoGit.RemoteNode (the core-runtime RPC helper). The
  # public signatures are preserved so the six web files that use NodeContext
  # need no changes.

  @doc """
  Evaluates `apply(module, function, args)` on the given node, returning
  `{:ok, result}` on success or `{:error, reason}` on any failure.

  Delegates to `EvoGit.RemoteNode.call_remote/4`.
  """
  @spec call_remote(node(), module(), atom(), [term()]) ::
          {:ok, term()} | {:error, term()}
  def call_remote(node, module, function, args) do
    EvoGit.RemoteNode.call_remote(node, module, function, args)
  end

  @doc """
  Lists agent summaries for the given node.

  Delegates to `EvoGit.RemoteNode.list_agents/1`. Returns `[]` if the remote
  call fails.
  """
  @spec list_agents(node()) :: [map()]
  def list_agents(node) do
    EvoGit.RemoteNode.list_agents(node)
  end

  @doc """
  Returns the conversation history for an agent on the given node.

  Delegates to `EvoGit.RemoteNode.get_agent_history/2`. Returns `[]` if the
  remote call fails.
  """
  @spec get_agent_history(node(), pos_integer()) :: [map()]
  def get_agent_history(node, agent_id) do
    EvoGit.RemoteNode.get_agent_history(node, agent_id)
  end

  @doc """
  Returns a plain-map snapshot of the full agent state on the given node.

  Delegates to `EvoGit.RemoteNode.get_agent_state/2`. Returns `nil` if the
  remote call fails.
  """
  @spec get_agent_state(node(), pos_integer()) :: map() | nil
  def get_agent_state(node, agent_id) do
    EvoGit.RemoteNode.get_agent_state(node, agent_id)
  end

  @doc """
  Returns the resolved scheduler configuration on the given node.

  Delegates to `EvoGit.RemoteNode.get_config/1`. Returns `%{}` if the remote
  call fails.
  """
  @spec get_remote_config(node()) :: map()
  def get_remote_config(node) do
    EvoGit.RemoteNode.get_config(node)
  end

  @doc """
  Returns the config health status on the given node.

  Delegates to `EvoGit.RemoteNode.get_config_status/1`. Returns a safe
  degraded status map if the remote call fails.
  """
  @spec get_remote_config_status(node()) :: map()
  def get_remote_config_status(node) do
    EvoGit.RemoteNode.get_config_status(node)
  end

  @doc """
  Returns `true` if the scheduler on the given node is paused.

  Delegates to `EvoGit.RemoteNode.paused?/1`. Returns `false` if the remote
  call fails.
  """
  @spec paused?(node()) :: boolean()
  def paused?(node) do
    EvoGit.RemoteNode.paused?(node)
  end

  @doc """
  Triggers a config reload on the given node, re-reading the config file
  from disk and applying relevant settings to the running scheduler.

  Delegates to `EvoGit.RemoteNode.reload_config/1`. Returns `:ok` on
  success or an error tuple.
  """
  @spec reload_remote_config(node()) :: :ok | {:error, term()}
  def reload_remote_config(node) do
    EvoGit.RemoteNode.reload_config(node)
  end

  @doc """
  Saves a user config map to the config file on the given node, then returns.

  On the local node, calls `EvoGit.Config.save_user_config/1` directly. On a
  remote node, routes the call through `:erpc` via `EvoGit.RemoteNode.save_user_config/2`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec save_user_config(node(), map()) :: :ok | {:error, term()}
  def save_user_config(node, config) do
    EvoGit.RemoteNode.save_user_config(node, config)
  end

  @doc """
  Saves credentials to the credentials file on the given node.

  On the local node, calls `EvoGit.Config.save_credentials/1` directly. On a
  remote node, routes the call through `:erpc` via `EvoGit.RemoteNode.save_credentials/2`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec save_credentials(node(), map()) :: :ok | {:error, term()}
  def save_credentials(node, credentials) do
    EvoGit.RemoteNode.save_credentials(node, credentials)
  end

  @doc """
  Sends a user message to an agent on the given node.

  Delegates to `EvoGit.RemoteNode.send_agent_message/3`.
  """
  @spec send_user_message(node(), pos_integer(), String.t()) :: {:ok, term()} | {:error, term()}
  def send_user_message(node, agent_id, message) do
    EvoGit.RemoteNode.send_agent_message(node, agent_id, message)
  end

  # ── Private helpers ──────────────────────────────────────────────

  # Invokes `apply(EvoGit.RemoteConnection, function, args)`, returning
  # `fallback` when the module is not compiled or the process is not started.
  #
  # `Code.ensure_loaded?/1` is non-crashing (returns false for missing
  # modules). `apply/3` keeps the call dynamic so the compiler does not warn
  # about the not-yet-existing EvoGit.RemoteConnection module at compile time
  # (it ships as parallel Phase 2 work). The `catch :exit` covers the
  # GenServer-not-started case — a GenServer call to a dead process raises an
  # exit, not a rescue-able exception (per the codebase's accepted catch :exit
  # pattern for cross-app GenServer calls to a possibly-dead process). This is
  # the single guard point so the degradation logic is not duplicated across
  # the six lifecycle functions.
  defp with_remote_connection(module, function, args, fallback) do
    if Code.ensure_loaded?(module) do
      try do
        apply(module, function, args)
      catch
        :exit, reason ->
          Logger.warning(
            "NodeContext: #{inspect(module)}.#{function} call failed (exit): #{inspect(reason)}"
          )

          fallback
      end
    else
      fallback
    end
  end
end
