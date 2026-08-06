defmodule EvoGit.AgentScheduler.RemoteAPI do
  @moduledoc """
  RPC-accessible API over scheduler ETS state (read-only state queries + config write).

  This module exposes pure functions that read the scheduler's global ETS
  tables (`:evogit_sched_meta` and `:evogit_agent_state`) and return
  **native Elixir terms** (atoms, structs, maps, lists, tuples). It is
  designed to be invoked from a local dashboard process via
  `:erpc.call(remote_node, EvoGit.AgentScheduler.RemoteAPI, function, args)`.

  ## Native term transfer via :erpc

  The `:erpc.call/5` mechanism used for cross-node RPC transfers all native
  BEAM terms (atoms, structs, maps, lists, tuples, PIDs) natively across
  Erlang distribution. There is no JSON/HTTP serialization boundary, so no
  conversion to "plain maps" is needed. Module atoms, `%Usage{}` structs,
  `ReqLLM.Message` structs, and `%ValidationError{}` structs are all
  transferred as-is. **No serialization safety conversion is performed.**

  ## Non-crashing access pattern

  ETS table reads are guarded with `:ets.whereis/1` (returns `:undefined`
  before the scheduler has started). No `try/rescue` blocks are used.
  """

  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Returns a list of agent summary maps.

  Joins `:evogit_sched_meta` (master list) with `:evogit_agent_state` on
  `agent_id`. Each map contains native Elixir terms:

    * `:id` — agent ID (integer)
    * `:task_local_id` — per-task agent number (integer | nil)
    * `:repo_id` — repo identifier string (`"primary"` or a foreign id)
    * `:status` — `:pending | :running | :waiting | :ready | :blocked`
    * `:depth` — recursion depth (integer)
    * `:parent_id` — parent agent ID (integer | nil)
    * `:usage` — `%Usage{}` struct (native)
    * `:total_tokens` — cumulative tokens since last compression (integer)
    * `:compression_count` — context compression count (integer)
    * `:objective` — the agent's objective string
    * `:result` — `nil` (no clean source in sched_meta)
    * `:agent_module` — module atom (e.g. `EvoGit.Agents.Manager`)
    * `:started_at` — `nil` (no direct field)
    * `:model_id` — model profile id string
    * `:repo_root` — absolute path to the repo root (string | nil)
    * `:context_path` — the spatial node path the agent is targeting (string)
    * `:worktree` — path to the assigned worktree (string | nil)
    * `:current_commit` — current git commit SHA (string)
    * `:base_commit` — base git commit SHA (string)
    * `:task_id` — task group ID string (string | nil)
    * `:task_number` — short task number for naming (integer | nil)
    * `:retries` — crash-retry count (integer)

  Returns `[]` when no agents are registered or the ETS tables don't exist yet.
  """
  @spec list_agents() :: [map()]
  def list_agents do
    sched_metas = read_table(:evogit_sched_meta)
    agent_states = read_table(:evogit_agent_state)

    states_by_id = Map.new(agent_states, fn {id, state} -> {id, state} end)

    Enum.map(sched_metas, fn {id, meta} ->
      build_agent_summary(id, meta, Map.get(states_by_id, id))
    end)
  end

  @doc """
  Returns the conversation history for an agent as a list of native
  `ReqLLM.Message` structs.

  Because `:erpc.call/5` transfers all BEAM terms natively, the messages
  are returned directly without any conversion.

  Returns `[]` if the agent has no context yet or doesn't exist.
  """
  @spec get_agent_history(agent_id :: pos_integer()) :: [ReqLLM.Message.t()]
  def get_agent_history(agent_id) do
    case lookup_agent_state(agent_id) do
      nil ->
        []

      %AgentState{context: nil} ->
        []

      %AgentState{context: %ReqLLM.Context{messages: messages}} ->
        messages
    end
  end

  @doc """
  Returns the native `%AgentState{}` struct for the given id.

  The `:context` field is dropped (it can be large — use
  `get_agent_history/1` for conversation access). All other fields are kept
  as native structs.

  Returns `nil` if the agent doesn't exist.
  """
  @spec get_agent_state(agent_id :: pos_integer()) :: AgentState.t() | nil
  def get_agent_state(agent_id) do
    case lookup_agent_state(agent_id) do
      nil -> nil
      %AgentState{} = state -> %{state | context: nil}
    end
  end

  @doc """
  Returns the current resolved scheduler configuration as a map.

  Delegates to `EvoGit.AgentScheduler.get_config/0` (a `GenServer.call`).
  Called on the remote node, so the result is already local to that node.
  """
  @spec get_config() :: map()
  def get_config do
    EvoGit.AgentScheduler.get_config()
  end

  @doc """
  Re-reads the config file from disk and applies the relevant settings to
  the running AgentScheduler.

  Calls `EvoGit.Config.resolve/0` to get a fresh config from disk, extracts
  scheduler-relevant keys (model profiles, concurrency limits, retry/turn
  settings, sandbox configuration), and delegates to
  `EvoGit.AgentScheduler.update_config/1` to apply them.

  Node-level distribution settings (`[node]` section) are intentionally
  skipped — they cannot be changed at runtime.

  Returns `:ok` on success, or `{:error, reason}` if the update fails.
  """
  @spec reload_config() :: :ok | {:error, String.t()}
  def reload_config do
    config = EvoGit.Config.resolve()
    opts = build_reload_opts(config)
    EvoGit.AgentScheduler.update_config(opts)
  end

  @doc """
  Writes a config map to disk on this node.

  Delegates to `EvoGit.Config.save_user_config/1`, which validates the config,
  stringifies keys, encodes to TOML, and writes to `~/.config/genesis/config.toml`.
  This runs on the REMOTE node when called via `:erpc.call/5`, so the file is
  written to the remote host's filesystem.

  Returns `:ok` on success, or `{:error, reason}` if validation or the file
  write fails.
  """
  @spec save_user_config(map()) :: :ok | {:error, term()}
  def save_user_config(config) when is_map(config) do
    case EvoGit.Config.save_user_config(config) do
      :ok ->
        reload_config()
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Writes a credentials map to disk on this node.

  Delegates to `EvoGit.Config.save_credentials/1`, which merges and writes to
  `~/.config/genesis/credentials.toml`. This runs on the REMOTE node when called
  via `:erpc.call/5`, so the file is written to the remote host's filesystem.

  Returns `:ok` on success, or `{:error, reason}` if the file write fails.
  """
  @spec save_credentials(map()) :: :ok | {:error, term()}
  def save_credentials(creds) when is_map(creds) do
    EvoGit.Config.save_credentials(creds)
  end

  @doc false
  # Builds the keyword list passed to `AgentScheduler.update_config/1` from
  # a resolved config map. Extracted for testability.
  #
  # Follows the same model-profile construction as `AgentScheduler.init/1`:
  # when `[[llm.models]]` is empty/unset, a single legacy "default" profile
  # is synthesized from the flat `llm.model` / `scheduler.max_concurrency`.
  @spec build_reload_opts(map()) :: keyword()
  def build_reload_opts(config) when is_map(config) do
    scheduler = Map.get(config, :scheduler, %{})

    # Build model profiles (same pattern as AgentScheduler.init/1)
    raw_model_profiles = EvoGit.Config.Schema.model_profiles(config)

    model_profiles =
      case raw_model_profiles do
        [] ->
          [EvoGit.Config.Schema.LLM.build_legacy_default_profile(config)]

        profiles ->
          profiles
      end

    sandbox = Map.get(config, :sandbox, %{})

    [
      model_profiles: model_profiles,
      max_tool_concurrency: Map.get(scheduler, :max_tool_concurrency),
      agent_max_retries: Map.get(scheduler, :agent_max_retries),
      max_depth: Map.get(scheduler, :max_agent_depth),
      max_retries: Map.get(scheduler, :max_retries),
      max_turns: Map.get(scheduler, :max_turns),
      max_turns_root: Map.get(scheduler, :max_turns_root),
      sandbox_mode: Map.get(sandbox, :mode),
      sandbox_resources: Map.get(sandbox, :resources),
      sandbox_process_resources: Map.get(sandbox, :process)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Returns the config health status.

  Delegates to `EvoGit.Config.config_status/0` and returns it directly.
  The `:validation_errors` field contains `%ValidationError{}` structs,
  which are transferred natively via `:erpc.call/5`.

  The returned map has:
    * `:missing` — list of missing config keys (atoms)
    * `:warnings` — list of human-readable warning strings
    * `:ok?` — boolean
    * `:validation_errors` — list of `%ValidationError{}` structs
  """
  @spec get_config_status() :: map()
  def get_config_status do
    EvoGit.Config.config_status()
  end

  @doc """
  Returns `true` if the scheduler is paused, `false` otherwise.

  Delegates to `EvoGit.AgentScheduler.paused?/0` (a `GenServer.call`).
  """
  @spec paused?() :: boolean()
  def paused? do
    EvoGit.AgentScheduler.paused?()
  end

  @doc """
  Sends a user message to a running agent via RPC.

  Routes the append through `AgentScheduler.send_user_message/2` (GenServer call)
  so appends are serialized. Returns `:ok` on success, `{:error, :not_found}` if
  the agent doesn't exist, or `{:error, :scheduler_not_started}` if the scheduler
  hasn't started yet.

  Designed to be called via `:erpc.call/5` from the local dashboard for a remote
  node.
  """
  @spec send_agent_message(pos_integer(), String.t()) :: :ok | {:error, term()}
  def send_agent_message(agent_id, message) when is_binary(message) do
    case :ets.whereis(:evogit_agent_state) do
      :undefined -> {:error, :scheduler_not_started}
      _ -> EvoGit.AgentScheduler.send_user_message(agent_id, message)
    end
  end

  @doc """
  Lists all tasks from the TaskRegistry.

  Delegates to `EvoGit.TaskRegistry.list_tasks/0` (a `GenServer.call`). This
  runs on the REMOTE node when called via `:erpc.call/5`, returning native
  `%TaskInfo{}` structs.

  Returns `[%TaskInfo{}]` (empty list when no tasks exist).
  """
  @spec list_tasks() :: [EvoGit.TaskInfo.t()]
  def list_tasks do
    EvoGit.TaskRegistry.list_tasks()
  end

  @doc """
  Returns a paginated slice of tasks with the total count.

  Delegates to `EvoGit.TaskRegistry.list_tasks_paginated/1` (a `GenServer.call`).
  `opts` is a keyword list accepting `:limit`, `:offset`, and `:filters`. This
  runs on the REMOTE node when called via `:erpc.call/5`. Both the keyword list
  opts and the returned `%TaskInfo{}` structs transfer natively via `:erpc`.

  Returns `{[%TaskInfo{}], total_count}`.
  """
  @spec list_tasks_paginated(keyword()) :: {[EvoGit.TaskInfo.t()], non_neg_integer()}
  def list_tasks_paginated(opts \\ []) do
    EvoGit.TaskRegistry.list_tasks_paginated(opts)
  end

  @doc """
  Returns the set of unique project paths that have tasks.

  Delegates to `EvoGit.TaskRegistry.get_unique_paths/0` (a `GenServer.call`).
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `[String.t()]`.
  """
  @spec get_unique_paths() :: [String.t()]
  def get_unique_paths do
    EvoGit.TaskRegistry.get_unique_paths()
  end

  @doc """
  Returns lightweight task summaries for all tasks.

  Delegates to `EvoGit.TaskRegistry.list_tasks_summary/1`. Returns a list of
  plain maps with only the columns needed for the dashboard sidebar.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses. When
  non-empty, the status filter is pushed into SQL.
  """
  @spec list_tasks_summary([atom()]) :: [map()]
  def list_tasks_summary(statuses \\ []) do
    EvoGit.TaskRegistry.list_tasks_summary(statuses)
  end

  @doc """
  Returns lightweight task summaries filtered to a specific project_path.

  Delegates to `EvoGit.TaskRegistry.list_tasks_summary_by_path/2`.
  """
  @spec list_tasks_summary_by_path(String.t(), [atom()]) :: [map()]
  def list_tasks_summary_by_path(path, statuses \\ []) do
    EvoGit.TaskRegistry.list_tasks_summary_by_path(path, statuses)
  end

  @doc """
  Returns lightweight task summaries for tasks whose `updated_at` is strictly
  newer than `since_iso` (a fixed-precision ISO-8601 string).

  Delegates to `EvoGit.TaskRegistry.list_tasks_changed_since/1`. Returns a list
  of plain maps (same projection as `list_tasks_summary/1`, including the
  `updated_at` key). This runs on the REMOTE node when called via `:erpc.call/5`.
  """
  @spec list_tasks_changed_since(String.t()) :: [map()]
  def list_tasks_changed_since(since_iso) do
    EvoGit.TaskRegistry.list_tasks_changed_since(since_iso)
  end

  @doc """
  Cancels a running task by id.

  Delegates to `EvoGit.TaskRegistry.cancel_task/1` (a `GenServer.call`). This
  runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok` on success or `{:error, reason}` if the task can't be cancelled.
  """
  @spec cancel_task(String.t()) :: :ok | {:error, term()}
  def cancel_task(task_id) do
    EvoGit.TaskRegistry.cancel_task(task_id)
  end

  @doc """
  Deletes a task by id.

  Delegates to `EvoGit.TaskRegistry.delete_task/1` (a `GenServer.cast`). This
  runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok` (fire-and-forget cast).
  """
  @spec delete_task(String.t()) :: :ok
  def delete_task(task_id) do
    EvoGit.TaskRegistry.delete_task(task_id)
  end

  @doc """
  Clears all finished tasks from the registry.

  Delegates to `EvoGit.TaskRegistry.clear_finished_tasks/0` (a `GenServer.call`).
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok`.
  """
  @spec clear_finished_tasks() :: :ok
  def clear_finished_tasks do
    EvoGit.TaskRegistry.clear_finished_tasks()
  end

  @doc """
  Lists recent projects from the TaskRegistry.

  Delegates to `EvoGit.TaskRegistry.list_recent_projects/0` (a `GenServer.call`).
  This runs on the REMOTE node when called via `:erpc.call/5`, returning native
  `%EvoGit.RecentProject{}` structs.

  Returns `[%EvoGit.RecentProject{}]` (empty list when no projects exist).
  """
  @spec list_recent_projects() :: [EvoGit.RecentProject.t()]
  def list_recent_projects do
    EvoGit.TaskRegistry.list_recent_projects()
  end

  @doc """
  Adds or updates a recent project entry on the remote node.

  Delegates to `EvoGit.TaskRegistry.add_recent_project/2` (a `GenServer.call`).
  `path` is the project path (string), `name` is the display name (string). This
  runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok`.
  """
  @spec add_recent_project(String.t(), String.t()) :: :ok
  def add_recent_project(path, name) do
    EvoGit.TaskRegistry.add_recent_project(path, name)
  end

  # ── Private: ETS access ────────────────────────────────────────────

  # Reads all `{key, value}` pairs from a named ETS table.
  # Returns `[]` when the table doesn't exist yet (e.g. before scheduler start).
  defp read_table(name) do
    case :ets.whereis(name) do
      :undefined -> []
      _ -> :ets.tab2list(name)
    end
  end

  # Looks up a single agent state by id.
  # Returns `%AgentState{}` or `nil` (table missing or key not found).
  defp lookup_agent_state(agent_id) do
    case :ets.whereis(:evogit_agent_state) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(:evogit_agent_state, agent_id) do
          [{^agent_id, state}] -> state
          [] -> nil
        end
    end
  end

  # ── Private: agent summary builder ─────────────────────────────────

  defp build_agent_summary(id, %SchedMeta{} = meta, nil) do
    # Agent registered in sched_meta but not yet dispatched (no agent_state).
    spec = meta.spec

    %{
      id: id,
      task_local_id: nil,
      repo_id: nil,
      status: meta.status,
      depth: meta.depth,
      parent_id: meta.parent_id,
      usage: Usage.zero(),
      total_tokens: 0,
      compression_count: 0,
      objective: spec.objective,
      result: nil,
      agent_module: spec.agent_module,
      started_at: nil,
      model_id: nil,
      repo_root: nil,
      context_path: spec.context_node.path,
      worktree: meta.worktree,
      current_commit: spec.phylo_node.current_commit,
      base_commit: spec.phylo_node.base_commit,
      task_id: meta.task_id,
      task_number: meta.task_number,
      retries: meta.retries
    }
  end

  defp build_agent_summary(id, %SchedMeta{} = meta, %AgentState{} = state) do
    usage = state.usage || Usage.zero()
    objective = state.objective || meta.spec.objective

    # Prefer the live phylo_node (worktree-bound, advancing commit); fall back
    # to the spec's phylo_node which is always populated.
    phylo = state.phylo_node || meta.spec.phylo_node

    %{
      id: id,
      task_local_id: state.task_local_id,
      repo_id: state.repo_id,
      status: meta.status,
      depth: meta.depth,
      parent_id: meta.parent_id,
      usage: usage,
      total_tokens: state.total_tokens,
      compression_count: state.compression_count,
      objective: objective,
      result: nil,
      agent_module: meta.spec.agent_module,
      started_at: nil,
      model_id: state.model_id,
      repo_root: state.repo_root,
      context_path: state.context_node.path,
      worktree: meta.worktree,
      current_commit: phylo.current_commit,
      base_commit: phylo.base_commit,
      task_id: meta.task_id,
      task_number: meta.task_number,
      retries: meta.retries
    }
  end
end
