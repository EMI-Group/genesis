defmodule EvoGit.RemoteNode do
  @moduledoc """
  Core-runtime cross-node RPC helper for remote (SSH) dashboard connections.

  Thin wrappers over `:erpc.call/5` that let a caller read scheduler state
  (agents, config, paused?) from a *remote* node exactly as it reads it
  locally. Local calls go directly to `EvoGit.AgentScheduler.RemoteAPI` /
  `EvoGit.AgentScheduler`; remote calls are routed through `:erpc` with a
  bounded timeout.

  All functions are safe to call from any process.
  """

  # RPC timeout (milliseconds) for cross-node :erpc.call/5.
  @default_rpc_timeout 10_000

  @doc """
  Evaluates `apply(module, function, args)` on the given node, returning
  `{:ok, result}` on success or `{:error, reason}` on any failure.

  For the **local node** (`node == node()`), the function is called directly
  via `apply/3` and the result wrapped in `{:ok, result}` — no error catching,
  so local bugs surface truthfully.

  For a **remote node**, the call is routed through `:erpc.call/5` with a
  bounded timeout (`#{@default_rpc_timeout}` ms). `:erpc.call/5` returns the
  bare result on success, but *raises/throws* on every failure mode: an erpc
  failure (node down, timeout) raises `{erpc, reason}`, and a remote-function
  failure re-raises the original exception/exit/throw. All of these are
  normalized into `{:error, reason}` here.
  """
  @spec call_remote(node(), module(), atom(), [term()]) ::
          {:ok, term()} | {:error, term()}
  def call_remote(node, module, function, args) do
    if node == node() do
      # Local node — call directly. Do NOT catch errors; let local bugs
      # surface. The only normalization is wrapping the bare result.
      {:ok, apply(module, function, args)}
    else
      # Remote node — route through :erpc.call/5.
      #
      # Justified try/catch — cross-node RPC boundary. :erpc.call/5 returns
      # the bare result on success but raises/throws on ANY failure (erpc
      # failure such as node-down/timeout, or a remote exception/exit/throw).
      # The API contract is to return {:ok, _} | {:error, _}, so every failure
      # mode is normalized into {:error, reason} here. This is the correct
      # pattern for a boundary with untrusted/remote execution.
      try do
        result = :erpc.call(node, module, function, args, @default_rpc_timeout)
        {:ok, result}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end
  end

  @doc """
  Lists agent summaries for the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_agents/0`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns `[]` if the remote call fails.
  """
  @spec list_agents(node()) :: [map()]
  def list_agents(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_agents()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_agents, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns the conversation history for an agent on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.get_agent_history/1` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. Returns `[]` if
  the remote call fails.
  """
  @spec get_agent_history(node(), pos_integer()) :: [map()]
  def get_agent_history(node, agent_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_agent_history(agent_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_agent_history, [
             agent_id
           ]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns a plain-map snapshot of the full agent state on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_agent_state/1`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`. Returns `nil` if the remote call fails.
  """
  @spec get_agent_state(node(), pos_integer()) :: map() | nil
  def get_agent_state(node, agent_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_agent_state(agent_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_agent_state, [
             agent_id
           ]) do
        {:ok, map} when is_map(map) -> map
        {:ok, _other} -> nil
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Returns the resolved scheduler configuration on the given node.

  On the local node, calls `EvoGit.AgentScheduler.get_config/0` directly (a
  GenServer call on the local scheduler). On a remote node, routes the call
  through `:erpc` via `call_remote/4`. Returns `%{}` if the remote call fails.
  """
  @spec get_config(node()) :: map()
  def get_config(node) do
    if node == node() do
      EvoGit.AgentScheduler.get_config()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_config, []) do
        {:ok, map} when is_map(map) -> map
        {:ok, _other} -> %{}
        {:error, _reason} -> %{}
      end
    end
  end

  @doc """
  Triggers a config reload on the given node's AgentScheduler.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.reload_config/0`
  directly. On a remote node, routes the call through `:erpc` via
  `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec reload_config(node()) :: :ok | {:error, term()}
  def reload_config(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.reload_config()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :reload_config, []) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns the config health status on the given node.

  On the local node, calls `EvoGit.Config.config_status/0` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`. Returns a
  safe degraded status map if the remote call fails.
  """
  @spec get_config_status(node()) :: map()
  def get_config_status(node) do
    if node == node() do
      EvoGit.Config.config_status()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_config_status, []) do
        {:ok, map} when is_map(map) -> map
        {:ok, _other} -> degraded_config_status()
        {:error, _reason} -> degraded_config_status()
      end
    end
  end

  @doc """
  Returns `true` if the scheduler on the given node is paused.

  On the local node, calls `EvoGit.AgentScheduler.paused?/0` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`. Returns
  `false` if the remote call fails.
  """
  @spec paused?(node()) :: boolean()
  def paused?(node) do
    if node == node() do
      EvoGit.AgentScheduler.paused?()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :paused?, []) do
        {:ok, bool} when is_boolean(bool) -> bool
        {:ok, _other} -> false
        {:error, _reason} -> false
      end
    end
  end

  @doc """
  Runs an LLM connectivity test on the given node.

  On the local node, calls `EvoGit.SystemCheck.llm_test/2` directly. On a
  remote node, routes the call through `:erpc` via `call_remote/4`. Returns the
  result tuple `{:ok, _} | {:error, _}` directly.
  """
  @spec llm_test(node(), term(), term()) :: {:ok, term()} | {:error, term()}
  def llm_test(node, model, gen_opts) do
    if node == node() do
      EvoGit.SystemCheck.llm_test(model, gen_opts)
    else
      case call_remote(node, EvoGit.SystemCheck, :llm_test, [model, gen_opts]) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Safe degraded config-status map returned when a remote config-status RPC
  # fails. Matches the shape of EvoGit.Config.config_status/0 so callers see a
  # well-formed (but unhealthy) status rather than a crash.
  defp degraded_config_status do
    %{ok?: false, missing: [], warnings: [], validation_errors: []}
  end
end
