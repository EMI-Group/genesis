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
  Saves a config map to the given node's config file on disk.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.save_user_config/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec save_user_config(node(), map()) :: :ok | {:error, term()}
  def save_user_config(node, config) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.save_user_config(config)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :save_user_config, [config]) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Saves a credentials map to the given node's credentials file on disk.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.save_credentials/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec save_credentials(node(), map()) :: :ok | {:error, term()}
  def save_credentials(node, creds) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.save_credentials(creds)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :save_credentials, [creds]) do
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

  @doc """
  Sends a user message to a running agent on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.send_agent_message/2` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure (including
  RPC failures such as node down or timeout).
  """
  @spec send_agent_message(node(), pos_integer(), String.t()) :: {:ok, term()} | {:error, term()}
  def send_agent_message(node, agent_id, message) do
    if node == node() do
      {:ok, EvoGit.AgentScheduler.RemoteAPI.send_agent_message(agent_id, message)}
    else
      call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :send_agent_message, [agent_id, message])
    end
  end

  @doc """
  Lists all tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_tasks/0` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`. Returns
  `[]` if the remote call fails.
  """
  @spec list_tasks(node()) :: [EvoGit.TaskInfo.t()]
  def list_tasks(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns a paginated slice of tasks on the given node.

  On the local node, calls
  `EvoGit.AgentScheduler.RemoteAPI.list_tasks_paginated/1` directly. On a remote
  node, routes the call through `:erpc` via `call_remote/4`. Returns `{[], 0}`
  if the remote call fails.
  """
  @spec list_tasks_paginated(node(), keyword()) ::
          {[EvoGit.TaskInfo.t()], non_neg_integer()}
  def list_tasks_paginated(node, opts \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_paginated(opts)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_paginated, [
             opts
           ]) do
        {:ok, {list, count}} when is_list(list) -> {list, count}
        {:ok, _other} -> {[], 0}
        {:error, _reason} -> {[], 0}
      end
    end
  end

  @doc """
  Returns the set of unique project paths with tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.get_unique_paths/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.
  """
  @spec get_unique_paths(node()) :: [String.t()]
  def get_unique_paths(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.get_unique_paths()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :get_unique_paths, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns lightweight task summaries on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary/1` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`. Returns
  `[]` if the remote call fails.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses.
  """
  @spec list_tasks_summary(node(), [atom()]) :: [map()]
  def list_tasks_summary(node, statuses \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary(statuses)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_summary, [statuses]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns a minimal id/status/updated_at projection for tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_task_ids/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses. The
  returned maps have `id`, `status` (atom), and `updated_at` (raw ISO string).
  """
  @spec list_task_ids(node(), [atom()]) :: [map()]
  def list_task_ids(node, statuses \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_task_ids(statuses)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_task_ids, [statuses]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns lightweight task summaries filtered to a specific project_path on the given node.
  """
  @spec list_tasks_summary_by_path(node(), String.t(), [atom()]) :: [map()]
  def list_tasks_summary_by_path(node, path, statuses \\ []) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary_by_path(path, statuses)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_summary_by_path, [
             path,
             statuses
           ]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Returns lightweight task summaries updated since an ISO-8601 timestamp on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_tasks_changed_since/1`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.

  `since_iso` is a fixed-precision ISO-8601 string; the returned summary-shaped
  maps include an `updated_at` key.
  """
  @spec list_tasks_changed_since(node(), String.t()) :: [map()]
  def list_tasks_changed_since(node, since_iso) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_tasks_changed_since(since_iso)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_tasks_changed_since, [
             since_iso
           ]) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Cancels a task on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.cancel_task/1` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec cancel_task(node(), String.t()) :: :ok | {:error, term()}
  def cancel_task(node, task_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.cancel_task(task_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :cancel_task, [task_id]) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes a task on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.delete_task/1` directly.
  On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec delete_task(node(), String.t()) :: :ok | {:error, term()}
  def delete_task(node, task_id) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.delete_task(task_id)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :delete_task, [task_id]) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Clears all finished tasks on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.clear_finished_tasks/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.

  Returns `:ok` on success or `{:error, reason}` on failure (including RPC
  failures such as node down or timeout).
  """
  @spec clear_finished_tasks(node()) :: :ok | {:error, term()}
  def clear_finished_tasks(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.clear_finished_tasks()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :clear_finished_tasks, []) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Lists recent projects on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.list_recent_projects/0`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `[]` if the remote call fails.
  """
  @spec list_recent_projects(node()) :: [EvoGit.RecentProject.t()]
  def list_recent_projects(node) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.list_recent_projects()
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :list_recent_projects, []) do
        {:ok, list} when is_list(list) -> list
        {:ok, _other} -> []
        {:error, _reason} -> []
      end
    end
  end

  @doc """
  Adds or updates a recent project entry on the given node.

  On the local node, calls `EvoGit.AgentScheduler.RemoteAPI.add_recent_project/2`
  directly. On a remote node, routes the call through `:erpc` via `call_remote/4`.
  Returns `:ok` even if the remote call fails (fire-and-forget semantics for
  recent-project tracking).

  Returns `:ok`.
  """
  @spec add_recent_project(node(), String.t(), String.t()) :: :ok
  def add_recent_project(node, path, name) do
    if node == node() do
      EvoGit.AgentScheduler.RemoteAPI.add_recent_project(path, name)
    else
      case call_remote(node, EvoGit.AgentScheduler.RemoteAPI, :add_recent_project, [path, name]) do
        {:ok, _} -> :ok
        {:error, _reason} -> :ok
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
