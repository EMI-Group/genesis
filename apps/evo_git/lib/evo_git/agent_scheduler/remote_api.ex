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
  Returns recent system samples from `EvoGit.SystemSampler`'s ring buffer.

  `{:ok, samples}` when the sampler is running; `{:error, :sampler_down}`
  when the sampler process is not running (checked locally before calling —
  `Process.whereis/1`, no try/rescue); `{:error, :not_found}` in the rare
  race where the sampler dies between the liveness check and the call
  (surfaced verbatim from `EvoGit.SystemSampler.get_recent_samples/0`).
  """
  @spec get_recent_system_samples() :: {:ok, [map()]} | {:error, :not_found | :sampler_down}
  def get_recent_system_samples do
    case Process.whereis(EvoGit.SystemSampler) do
      nil -> {:error, :sampler_down}
      _pid -> EvoGit.SystemSampler.get_recent_samples()
    end
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
  # is synthesized from the flat `llm.model` / `scheduler.default_llm_max_concurrency`.
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
      default_llm_max_concurrency: Map.get(scheduler, :default_llm_max_concurrency),
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
  Returns a minimal id/status/updated_at projection for tasks matching
  `statuses` (atoms; `[]` = all tasks).

  Delegates to `EvoGit.TaskRegistry.list_task_ids/1`. Returns a list of plain
  maps with `id`, `status` (atom), and `updated_at` (raw fixed-precision ISO
  string). This runs on the REMOTE node when called via `:erpc.call/5`.
  """
  @spec list_task_ids([atom()]) :: [map()]
  def list_task_ids(statuses \\ []) do
    EvoGit.TaskRegistry.list_task_ids(statuses)
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
  Gracefully cancels a running or pending task by id.

  Delegates to `EvoGit.TaskRegistry.cancel_task/1` (a `GenServer.call`). This
  runs on the REMOTE node when called via `:erpc.call/5`. The task enters a
  `:cancelling` grace period — agents are notified to save their work and
  finish cleanly; the task is finally persisted `:cancelled` when the wrapper
  completes.

  Returns `:ok` on success or `{:error, reason}` if the task can't be cancelled.
  """
  @spec cancel_task(String.t()) :: :ok | {:error, term()}
  def cancel_task(task_id) do
    EvoGit.TaskRegistry.cancel_task(task_id)
  end

  @doc """
  Force-kills a running or cancelling task by id — the BRUTAL cancellation
  path (no grace period): agents are killed, the wrapper is brutal-killed, and
  the task is immediately persisted `:failed`.

  Delegates to `EvoGit.TaskRegistry.force_kill_task/1` (a `GenServer.call`).
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok` on success or `{:error, reason}` if the task can't be cancelled.
  """
  @spec force_kill_task(String.t()) :: :ok | {:error, term()}
  def force_kill_task(task_id) do
    EvoGit.TaskRegistry.force_kill_task(task_id)
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
  Returns a single task by id from the TaskRegistry.

  Delegates to `EvoGit.TaskRegistry.get_task/1` (a `GenServer.call`). This
  runs on the REMOTE node when called via `:erpc.call/5`, returning a native
  `%TaskInfo{}` struct.

  Returns `%TaskInfo{}` or `nil` if the task does not exist.
  """
  @spec get_task(String.t()) :: EvoGit.TaskInfo.t() | nil
  def get_task(task_id) do
    EvoGit.TaskRegistry.get_task(task_id)
  end

  @doc """
  Sets the review status for a task.

  Delegates to `EvoGit.TaskRegistry.set_review_status/2` (a `GenServer.cast`).
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok` (fire-and-forget cast).
  """
  @spec set_review_status(String.t(), atom()) :: :ok
  def set_review_status(task_id, status) do
    EvoGit.TaskRegistry.set_review_status(task_id, status)
  end

  @doc """
  Sets the review metadata (base and commit SHAs) for a task.

  Delegates to `EvoGit.TaskRegistry.set_review_metadata/3` (a `GenServer.cast`).
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok` (fire-and-forget cast).
  """
  @spec set_review_metadata(String.t(), String.t(), String.t()) :: :ok
  def set_review_metadata(task_id, base_sha, commit_sha) do
    EvoGit.TaskRegistry.set_review_metadata(task_id, base_sha, commit_sha)
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

  # ── Custom agents (delegated to EvoGit.CustomAgents) ───────────────
  #
  # The custom-agent config lives in `agents.toml` — a per-node file sitting
  # next to `config.toml` in the node's config dir. These functions therefore
  # run ON the node being configured: a direct local call for the local node,
  # an `:erpc.call/5` for a remote node (via `EvoGit.RemoteNode`).

  @doc """
  Returns the node's custom-agent configuration from `agents.toml`.

  Reads the per-node `agents.toml` (which lives next to `config.toml` in the
  same config dir). This runs on the REMOTE node when called via
  `:erpc.call/5`, so the remote node's own agents.toml is read — exactly
  right, because the file lives per-node next to config.toml.

  Returns `{:ok, %{agents: [...], model_selection_script: script_or_nil,
  script_status: status}}` — `script_status` is `:ok` or
  `{:error, {:compile_error, msg}}` (ModelSelector.status/0).
  """
  @spec list_custom_agents() :: {:ok, map()}
  def list_custom_agents do
    {:ok,
     %{
       agents: EvoGit.CustomAgents.list(),
       model_selection_script: EvoGit.CustomAgents.model_selection_script(),
       script_status: EvoGit.CustomAgents.ModelSelector.status()
     }}
  end

  @doc """
  Saves a custom agent definition to this node's `agents.toml`.

  Delegates to `EvoGit.CustomAgents.save/1` (upsert by id; a missing id is
  auto-generated by slugifying the name). This runs on the REMOTE node when
  called via `:erpc.call/5`, so the definition is written to the remote
  host's per-node agents.toml.

  Returns `{:ok, definition}` on success or `{:error, reason}` on validation
  failure (e.g. `:missing_name`, `:missing_prompt`, `:duplicate_id`).
  """
  @spec save_custom_agent(map()) :: {:ok, map()} | {:error, atom()}
  def save_custom_agent(def), do: EvoGit.CustomAgents.save(def)

  @doc """
  Deletes a custom agent definition from this node's `agents.toml`.

  Delegates to `EvoGit.CustomAgents.delete/1`. This runs on the REMOTE node
  when called via `:erpc.call/5`.

  Returns `:ok` on success or `{:error, :not_found}` if no agent has that id.
  """
  @spec delete_custom_agent(String.t()) :: :ok | {:error, :not_found}
  def delete_custom_agent(id), do: EvoGit.CustomAgents.delete(id)

  @doc """
  Saves the model-selection script to this node's `agents.toml`.

  Delegates to `EvoGit.CustomAgents.save_model_selection_script/1` (an empty
  string removes the script). This runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns `:ok` on success or `{:error, reason}` on write failure.
  """
  @spec save_model_selection_script(String.t()) :: :ok | {:error, term()}
  def save_model_selection_script(script),
    do: EvoGit.CustomAgents.save_model_selection_script(script)

  @doc """
  Invalidates the node's model-selector compile cache.

  Delegates to `EvoGit.CustomAgents.reload/0`, which erases the
  `EvoGit.CustomAgents.ModelSelector` compile-cache entry so the next
  `status/0`/`select_model/1` call re-reads and re-compiles the script.
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `:ok`.
  """
  @spec reload_custom_agents() :: :ok
  def reload_custom_agents, do: EvoGit.CustomAgents.reload()

  @doc """
  Starts a task on the remote node.

  Delegates to `EvoGit.TaskRegistry.start_task/2` (a `GenServer.call`).
  `task_type` is an atom (`:genesis` or `:evolve`), `opts` is a keyword list.
  This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `{:ok, %EvoGit.TaskInfo{}}` on success or `{:error, reason}` on failure.
  """
  @spec start_task(atom(), keyword()) :: {:ok, EvoGit.TaskInfo.t()} | {:error, term()}
  def start_task(task_type, opts) do
    EvoGit.TaskRegistry.start_task(task_type, opts)
  end

  # ── Review operations (delegated to EvoGit.Review) ─────────────────
  #
  # Function-for-function mirrors of EvoGit.Review's public API. These run
  # on the REMOTE node when called via `:erpc.call/5`, so review operations
  # execute inside the remote VM against the remote filesystem. Return
  # values pass through UNCHANGED — whatever `EvoGit.Review` returns is
  # returned verbatim.

  @doc """
  Fetches the full content of a file at a specific commit on the remote node.

  Delegates to `EvoGit.Review.get_file_content/3`. `repo_path` is the absolute
  path of the repository, `commit_sha` the commit to read from, `file_path`
  the file within the repository. Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns `{:ok, content}` if the file exists at that commit, or
  `{:error, {tag, output}}` if not.
  """
  @spec get_file_content(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {atom(), String.t()}}
  def get_file_content(repo_path, commit_sha, file_path) do
    EvoGit.Review.get_file_content(repo_path, commit_sha, file_path)
  end

  @doc """
  Lists commits between the merge-base and a branch tip on the remote node.

  Delegates to `EvoGit.Review.list_commits/2`. `repo_path` is the absolute
  path of the repository, `branch_name` the branch whose commits to list.
  Runs on the REMOTE node when called via `:erpc.call/5`.

  Returns `{:ok, [%EvoGit.Review.CommitInfo{}]}` or `{:error, reason}`.
  """
  @spec list_commits(String.t(), String.t()) ::
          {:ok, [EvoGit.Review.CommitInfo.t()]} | {:error, term()}
  def list_commits(repo_path, branch_name) do
    EvoGit.Review.list_commits(repo_path, branch_name)
  end

  @doc """
  Loads all review data (diff stat, full diff, parsed files) for a branch on
  the remote node.

  Delegates to `EvoGit.Review.load_review_data/2`. `repo_path` is the absolute
  path of the repository, `branch_name` the branch to review. Runs on the
  REMOTE node when called via `:erpc.call/5`.

  Returns `{:ok, review_data_map}` where the map has `:commit_sha`,
  `:base_sha`, `:diff_stat`, `:diff`, `:files`, `:changed_files_count`,
  `:total_additions`, `:total_deletions`, or an error tuple.
  """
  @spec load_review_data(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_review_data(repo_path, branch_name) do
    EvoGit.Review.load_review_data(repo_path, branch_name)
  end

  @doc """
  Loads review metadata only (file list with counts, no diffs) for a branch
  on the remote node.

  Delegates to `EvoGit.Review.load_review_metadata/2`. `repo_path` is the
  absolute path of the repository, `branch_name` the branch to review. Runs
  on the REMOTE node when called via `:erpc.call/5`.

  Same return shape as `load_review_data/2` but the `:diff` field on each
  file is `nil` and the top-level `:diff` field is `nil`.
  """
  @spec load_review_metadata(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_review_metadata(repo_path, branch_name) do
    EvoGit.Review.load_review_metadata(repo_path, branch_name)
  end

  @doc """
  Loads the diff of a single file between two commits on the remote node.

  Delegates to `EvoGit.Review.load_file_diff/4`. `repo_path` is the absolute
  path of the repository, `base_sha` and `commit_sha` the revision range,
  `file_path` the file within the repository. Runs on the REMOTE node when
  called via `:erpc.call/5`.

  Returns the diff result from `EvoGit.Review` verbatim.
  """
  @spec load_file_diff(String.t(), String.t(), String.t(), String.t()) :: term()
  def load_file_diff(repo_path, base_sha, commit_sha, file_path) do
    EvoGit.Review.load_file_diff(repo_path, base_sha, commit_sha, file_path)
  end

  @doc """
  Loads the diff of a single file between two commits on the remote node,
  with options.

  Delegates to `EvoGit.Review.load_file_diff/5`. `repo_path` is the absolute
  path of the repository, `base_sha` and `commit_sha` the revision range,
  `file_path` the file within the repository, `opts` a keyword list of
  options (e.g. context lines). Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns the diff result from `EvoGit.Review` verbatim.
  """
  @spec load_file_diff(String.t(), String.t(), String.t(), String.t(), keyword()) :: term()
  def load_file_diff(repo_path, base_sha, commit_sha, file_path, opts) when is_list(opts) do
    EvoGit.Review.load_file_diff(repo_path, base_sha, commit_sha, file_path, opts)
  end

  @doc """
  Loads review metadata from explicit base/commit SHAs on the remote node
  (no branch resolution).

  Delegates to `EvoGit.Review.load_review_metadata_from_shas/3`. `repo_path`
  is the absolute path of the repository, `base_sha` and `commit_sha` the
  revision range. Runs on the REMOTE node when called via `:erpc.call/5`.

  Returns the result from `EvoGit.Review` verbatim.
  """
  @spec load_review_metadata_from_shas(String.t(), String.t(), String.t()) :: term()
  def load_review_metadata_from_shas(repo_path, base_sha, commit_sha) do
    EvoGit.Review.load_review_metadata_from_shas(repo_path, base_sha, commit_sha)
  end

  @doc """
  Lists commits between explicit base/commit SHAs on the remote node (no
  branch resolution).

  Delegates to `EvoGit.Review.list_commits_from_shas/3`. `repo_path` is the
  absolute path of the repository, `base_sha` and `commit_sha` the revision
  range. Runs on the REMOTE node when called via `:erpc.call/5`.

  Returns the result from `EvoGit.Review` verbatim.
  """
  @spec list_commits_from_shas(String.t(), String.t(), String.t()) :: term()
  def list_commits_from_shas(repo_path, base_sha, commit_sha) do
    EvoGit.Review.list_commits_from_shas(repo_path, base_sha, commit_sha)
  end

  @doc """
  Lists the files changed in a single commit on the remote node.

  Delegates to `EvoGit.Review.load_commit_files/2`. `repo_path` is the
  absolute path of the repository, `commit_sha` the commit to inspect. Runs
  on the REMOTE node when called via `:erpc.call/5`.

  Returns the result from `EvoGit.Review` verbatim.
  """
  @spec load_commit_files(String.t(), String.t()) :: term()
  def load_commit_files(repo_path, commit_sha) do
    EvoGit.Review.load_commit_files(repo_path, commit_sha)
  end

  @doc """
  Loads the diff of a single file within a single commit on the remote node.

  Delegates to `EvoGit.Review.load_commit_file_diff/3`. `repo_path` is the
  absolute path of the repository, `commit_sha` the commit, `file_path` the
  file within the repository. Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns the result from `EvoGit.Review` verbatim.
  """
  @spec load_commit_file_diff(String.t(), String.t(), String.t()) :: term()
  def load_commit_file_diff(repo_path, commit_sha, file_path) do
    EvoGit.Review.load_commit_file_diff(repo_path, commit_sha, file_path)
  end

  @doc """
  Merges an agent branch into the repository's default merge target on the
  remote node.

  Delegates to `EvoGit.Review.merge_branch/2`. `repo_path` is the absolute
  path of the repository, `branch_name` the branch to merge. Runs on the
  REMOTE node when called via `:erpc.call/5`.

  Returns `{:ok, sha}` on success, `{:conflict, details}` on a merge
  conflict, or `{:error, reason}` on failure.
  """
  @spec merge_branch(String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def merge_branch(repo_path, branch_name) do
    EvoGit.Review.merge_branch(repo_path, branch_name)
  end

  @doc """
  Merges an agent branch into an explicit target branch on the remote node.

  Delegates to `EvoGit.Review.merge_branch/3`. `repo_path` is the absolute
  path of the repository, `branch_name` the branch to merge, `target_branch`
  the branch to merge into. Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns `{:ok, sha}` on success, `{:conflict, details}` on a merge
  conflict, or `{:error, reason}` on failure.
  """
  @spec merge_branch(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def merge_branch(repo_path, branch_name, target_branch) do
    EvoGit.Review.merge_branch(repo_path, branch_name, target_branch)
  end

  @doc """
  Checks whether merging a branch or commit into a target branch on the remote
  node would be clean.

  Delegates to `EvoGit.Review.check_merge/3`. `repo_path` is the absolute path
  of the repository, `branch_or_sha` the branch or commit SHA to merge,
  `target_branch` the branch to merge into. Runs on the REMOTE node when
  called via `:erpc.call/5`.

  Returns `{:ok, :clean}` when the merge would succeed cleanly,
  `{:ok, {:conflict, files}}` when it would conflict, or `{:error, reason}`
  on failure.
  """
  @spec check_merge(String.t(), String.t(), String.t()) ::
          {:ok, :clean} | {:ok, {:conflict, list()}} | {:error, term()}
  def check_merge(repo_path, branch_or_sha, target_branch) do
    EvoGit.Review.check_merge(repo_path, branch_or_sha, target_branch)
  end

  @doc """
  Resolves the default merge target branch for a repository on the remote node.

  Delegates to `EvoGit.Review.default_merge_target/1`. `repo_path` is the
  absolute path of the repository. Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns `{:ok, branch_name}` (`main` → `master` → `dev` → `prod` → current
  → first local branch) or `{:error, :no_branch_found}`.
  """
  @spec default_merge_target(String.t()) :: {:ok, String.t()} | {:error, :no_branch_found}
  def default_merge_target(repo_path) do
    EvoGit.Review.default_merge_target(repo_path)
  end

  @doc """
  Lists all local branches in a repository on the remote node.

  Delegates to `EvoGit.Review.list_branches/1`. `repo_path` is the absolute
  path of the repository. Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns `{:ok, [String.t()]}` or `{:error, {tag, output}}`.
  """
  @spec list_branches(String.t()) :: {:ok, [String.t()]} | {:error, {atom(), String.t()}}
  def list_branches(repo_path) do
    EvoGit.Review.list_branches(repo_path)
  end

  @doc """
  Rejects (deletes) an agent branch in a repository on the remote node.

  Delegates to `EvoGit.Review.reject_branch/2`. `repo_path` is the absolute
  path of the repository, `branch_name` the branch to reject. Runs on the
  REMOTE node when called via `:erpc.call/5`.

  Returns the result from `EvoGit.Review` verbatim.
  """
  @spec reject_branch(String.t(), String.t()) :: term()
  def reject_branch(repo_path, branch_name) do
    EvoGit.Review.reject_branch(repo_path, branch_name)
  end

  @doc """
  Creates a GitHub pull request for an agent branch on the remote node.

  Delegates to `EvoGit.Review.create_github_pr/4`. `repo_path` is the
  absolute path of the repository, `branch_name` the branch to open the PR
  for, `objective` the task objective string, `result` the task result
  string. Runs on the REMOTE node when called via `:erpc.call/5`.

  Returns the result from `EvoGit.Review` verbatim.
  """
  @spec create_github_pr(String.t(), String.t(), String.t(), String.t()) :: term()
  def create_github_pr(repo_path, branch_name, objective, result) do
    EvoGit.Review.create_github_pr(repo_path, branch_name, objective, result)
  end

  @doc """
  Gets the GitHub upstream information (owner/repo parsed from the `origin`
  remote URL) for a repository on the remote node.

  Delegates to `EvoGit.Adapters.GitHub.github_upstream/1`. `repo_path` is the
  absolute path of the repository. Runs on the REMOTE node when called via
  `:erpc.call/5`.

  Returns `{:ok, %{owner: String.t(), repo: String.t(), url: String.t(),
  gh_available: boolean()}}` on success, or `{:error, {:enoent, repo_path}}`
  / `{:error, :no_github_upstream}` / `{:error, {:code, code, output}}`.
  """
  @spec github_upstream(String.t()) ::
          {:ok, %{owner: String.t(), repo: String.t(), url: String.t(), gh_available: boolean()}}
          | {:error, term()}
  def github_upstream(repo_path) do
    EvoGit.Adapters.GitHub.github_upstream(repo_path)
  end

  @doc """
  Lists GitHub issues of a repository's upstream on the remote node.

  Delegates to `EvoGit.Adapters.GitHub.list_github_issues/2`. `repo_path` is
  the absolute path of the repository, `opts` the option list (`:state`
  default `"open"`, `:limit` default 100). Runs on the REMOTE node when
  called via `:erpc.call/5`.

  Returns `{:ok, [issue_map]}` on success; the error shapes of
  `EvoGit.Adapters.GitHub.list_github_issues/2` are passed through verbatim.
  """
  @spec list_github_issues(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_github_issues(repo_path, opts \\ []) do
    EvoGit.Adapters.GitHub.list_github_issues(repo_path, opts)
  end

  @doc """
  Fetches a GitHub issue of a repository's upstream on the remote node and
  composes it into a deterministic Markdown string.

  Delegates to `EvoGit.Adapters.GitHub.github_issue_markdown/2`. `repo_path`
  is the absolute path of the repository, `number` the issue number. Runs on
  the REMOTE node when called via `:erpc.call/5`.

  Returns `{:ok, markdown}` on success; the error shapes of
  `EvoGit.Adapters.GitHub.github_issue_markdown/2` are passed through
  verbatim.
  """
  @spec github_issue_markdown(String.t(), integer() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def github_issue_markdown(repo_path, number) do
    EvoGit.Adapters.GitHub.github_issue_markdown(repo_path, number)
  end

  @doc """
  Checks whether a branch exists in a repository on the remote node.

  Delegates to `EvoGit.Review.branch_exists?/2`. `repo_path` is the absolute
  path of the repository, `branch_name` the branch to check. Runs on the
  REMOTE node when called via `:erpc.call/5`.

  Returns a boolean.
  """
  @spec branch_exists?(String.t(), String.t()) :: boolean()
  def branch_exists?(repo_path, branch_name) do
    EvoGit.Review.branch_exists?(repo_path, branch_name)
  end

  @doc """
  Checks whether a file exists on the remote node's filesystem.

  Delegates to `File.exists?/1`. `path` is an absolute path string. This runs
  on the REMOTE node when called via `:erpc.call/5`.

  Returns a boolean.
  """
  @spec file_exists?(String.t()) :: boolean()
  def file_exists?(path) do
    File.exists?(path)
  end

  @doc """
  Lists files and directories in a given path on the remote node's filesystem.

  Delegates to `File.ls/1`. `path` is an absolute path string. This runs on the
  REMOTE node when called via `:erpc.call/5`.

  Returns `{:ok, [String.t()]}` on success or `{:error, atom()}` on failure.
  """
  @spec ls(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def ls(path) do
    File.ls(path)
  end

  @doc """
  Reads and parses the `genesis.toml` project config from the given project root.

  Delegates to `EvoGit.ProjectConfig.read/1`. `path` is the absolute project
  root path string. This runs on the REMOTE node when called via `:erpc.call/5`.

  Returns the parsed config map or `nil` if the config file does not exist.
  """
  @spec read_project_config(String.t()) :: map() | nil
  def read_project_config(path) do
    EvoGit.ProjectConfig.read(path)
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
      message_count: 0,
      objective: spec.objective,
      result: nil,
      agent_module: spec.agent_module,
      started_at: nil,
      model_id: nil,
      repo_root: nil,
      context_path: safe_context_path(spec.context_node),
      worktree: meta.worktree,
      current_commit: safe_phylo_commit(spec.phylo_node, :current_commit),
      base_commit: safe_phylo_commit(spec.phylo_node, :base_commit),
      task_id: meta.task_id,
      task_number: meta.task_number,
      retries: meta.retries
    }
  end

  defp build_agent_summary(id, %SchedMeta{} = meta, %AgentState{} = state) do
    usage = state.usage || Usage.zero()
    objective = state.objective || meta.spec.objective

    # Prefer the live phylo_node (worktree-bound, advancing commit); fall back
    # to the spec's phylo_node. For repo-less agents BOTH are nil (no worktree,
    # no commits) — emit nil commits rather than crashing.
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
      message_count:
        case state.context do
          %ReqLLM.Context{messages: messages} -> length(messages)
          _ -> 0
        end,
      objective: objective,
      result: nil,
      agent_module: meta.spec.agent_module,
      started_at: nil,
      model_id: state.model_id,
      repo_root: state.repo_root,
      context_path: safe_context_path(state.context_node),
      worktree: meta.worktree,
      current_commit: safe_phylo_commit(phylo, :current_commit),
      base_commit: safe_phylo_commit(phylo, :base_commit),
      task_id: meta.task_id,
      task_number: meta.task_number,
      retries: meta.retries
    }
  end

  # Nil-tolerant phylo_node field read: repo-less agents carry a nil
  # phylo_node (no worktree, no commits) — return nil instead of raising a
  # KeyError on nil.
  defp safe_phylo_commit(nil, _field), do: nil
  defp safe_phylo_commit(phylo, field), do: Map.get(phylo, field)

  # Nil-tolerant context_node path read (repo-less specs may carry a nil
  # context_node).
  defp safe_context_path(nil), do: nil
  defp safe_context_path(node), do: node.path
end
