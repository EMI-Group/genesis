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
  Returns the FULL resolved user configuration on the given node.

  This is exactly what `EvoGit.Config.resolve/0` returns: the merged
  defaults + user config as an atom-keyed nested map (e.g.
  `%{scheduler: %{...}, llm: %{models: [...], ...}, tools: %{...}, ...}`).
  On the local node the function is called directly; on a remote node it is
  routed through `EvoGit.RemoteNode.call_remote/4`.

  Returns `{:ok, config}` on success or `{:error, {kind, reason}}` on
  transport failure (node down, timeout). Unlike `get_remote_config/1`, a
  failure is NOT silently collapsed to `%{}` — callers can distinguish a
  genuinely unconfigured node from an unreachable one.
  """
  @spec get_resolved_config(node()) :: {:ok, map()} | {:error, term()}
  def get_resolved_config(node) do
    EvoGit.RemoteNode.call_remote(node, EvoGit.Config, :resolve, [])
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
  Saves a user config map to the config file on the given node.

  Delegates to `EvoGit.RemoteNode.save_user_config/2`. Returns `:ok` on
  success or an error tuple.
  """
  @spec save_user_config(node(), map()) :: :ok | {:error, term()}
  def save_user_config(node, config) do
    EvoGit.RemoteNode.save_user_config(node, config)
  end

  @doc """
  Saves credentials to the credentials file on the given node.

  Delegates to `EvoGit.RemoteNode.save_credentials/2`. Returns `:ok` on
  success or an error tuple.
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

  @doc """
  Restarts the remote node's BEAM VM via RPC.

  Calls `System.restart/0` on the remote node through `:erpc`. The remote node
  tears down mid-call (it's restarting), so the RPC failure is EXPECTED and
  not an error — the restart command has been received. Always returns `:ok`.

  For the local node, this function should not be called (the system page uses
  `System.restart/0` directly for local nodes).
  """
  @spec restart_remote(node()) :: :ok
  def restart_remote(node) do
    # System.restart/0 on the remote node tears down the VM mid-RPC. The
    # :erpc call will fail with an exit — this is expected, not an error.
    _ = call_remote(node, System, :restart, [])
    :ok
  end

  @doc """
  Stops the remote node's BEAM VM via RPC.

  Calls `System.stop/0` on the remote node through `:erpc`. The remote node
  shuts down mid-call, so the RPC failure is EXPECTED and not an error — the
  stop command has been received. Always returns `:ok`.

  For the local node, this function should not be called (the system page uses
  `System.stop/0` directly for local nodes).
  """
  @spec stop_remote(node()) :: :ok
  def stop_remote(node) do
    # System.stop/0 on the remote node shuts down the VM mid-RPC. The
    # :erpc call will fail with an exit — this is expected, not an error.
    _ = call_remote(node, System, :stop, [])
    :ok
  end

  @doc """
  Lists tasks on the given node as lightweight summary maps.

  Delegates to `EvoGit.RemoteNode.list_tasks_summary/2`. Returns `[]` if the
  remote call fails. The summary maps omit heavy JSON fields (logs, usage,
  archive_metadata) and are suitable for sidebar/list displays.

  `statuses` filters by task status (atoms such as `:running`, `:pending`,
  `:finalizing`, `:completed`); `[]` (the default) returns all statuses.
  """
  @spec list_tasks_summary(node(), [atom()]) :: [map()]
  def list_tasks_summary(node, statuses \\ []) do
    EvoGit.RemoteNode.list_tasks_summary(node, statuses)
  end

  @doc """
  Lists minimal task projections (id, status, updated_at) on the given node.

  Delegates to `EvoGit.RemoteNode.list_task_ids/2`. Returns `[]` if the
  remote call fails. The returned maps have `id`, `status` (atom), and
  `updated_at` (raw ISO string) only — no heavy JSON fields are decoded — and
  are suitable for dirty-tracker baselines and other lightweight change
  detection.

  `statuses` filters by task status (atoms such as `:running`, `:pending`,
  `:finalizing`, `:completed`); `[]` (the default) returns all statuses.
  """
  @spec list_task_ids(node(), [atom()]) :: [map()]
  def list_task_ids(node, statuses \\ []) do
    EvoGit.RemoteNode.list_task_ids(node, statuses)
  end

  @doc """
  Returns a paginated slice of tasks on the given node.

  Delegates to `EvoGit.RemoteNode.list_tasks_paginated/2`. Returns `{[], 0}`
  if the remote call fails.
  """
  @spec list_tasks_paginated(node(), keyword()) ::
          {[EvoGit.TaskInfo.t()], non_neg_integer()}
  def list_tasks_paginated(node, opts \\ []) do
    EvoGit.RemoteNode.list_tasks_paginated(node, opts)
  end

  @doc """
  Returns lightweight task summaries updated since an ISO-8601 timestamp on
  the given node.

  Delegates to `EvoGit.RemoteNode.list_tasks_changed_since/2`. Returns `[]`
  if the remote call fails. `since_iso` is a fixed-precision ISO-8601 string;
  the returned summary maps include an `updated_at` key.
  """
  @spec list_tasks_changed_since(node(), String.t()) :: [map()]
  def list_tasks_changed_since(node, since_iso) do
    EvoGit.RemoteNode.list_tasks_changed_since(node, since_iso)
  end

  @doc """
  Returns the set of unique project paths with tasks on the given node.

  Delegates to `EvoGit.RemoteNode.get_unique_paths/1`. Returns `[]` if the
  remote call fails.
  """
  @spec get_unique_paths(node()) :: [String.t()]
  def get_unique_paths(node) do
    EvoGit.RemoteNode.get_unique_paths(node)
  end

  @doc """
  Cancels a task on the given node.

  Delegates to `EvoGit.RemoteNode.cancel_task/2`. Returns `:ok` on success
  or `{:error, reason}` on failure.
  """
  @spec cancel_task(node(), String.t()) :: :ok | {:error, term()}
  def cancel_task(node, task_id) do
    EvoGit.RemoteNode.cancel_task(node, task_id)
  end

  @doc """
  Force-kills a task on the given node.

  Delegates to `EvoGit.RemoteNode.force_kill_task/2`. Immediately stops the
  task and all of its agents, discarding all progress. The task is persisted
  with status `:failed` and its result discarded (all progress lost). Returns
  `:ok` on success or `{:error, reason}` on failure. Can be used to escalate
  a task that is already in the `:cancelling` state.
  """
  @spec force_kill_task(node(), String.t()) :: :ok | {:error, term()}
  def force_kill_task(node, task_id) do
    EvoGit.RemoteNode.force_kill_task(node, task_id)
  end

  @doc """
  Deletes a task on the given node.

  Delegates to `EvoGit.RemoteNode.delete_task/2`. Returns `:ok` on success
  or `{:error, reason}` on failure.
  """
  @spec delete_task(node(), String.t()) :: :ok | {:error, term()}
  def delete_task(node, task_id) do
    EvoGit.RemoteNode.delete_task(node, task_id)
  end

  @doc """
  Clears all finished tasks on the given node.

  Delegates to `EvoGit.RemoteNode.clear_finished_tasks/1`. Returns `:ok` on
  success or `{:error, reason}` on failure.
  """
  @spec clear_finished_tasks(node()) :: :ok | {:error, term()}
  def clear_finished_tasks(node) do
    EvoGit.RemoteNode.clear_finished_tasks(node)
  end

  @doc """
  Lists recent projects on the given node.

  Delegates to `EvoGit.RemoteNode.list_recent_projects/1`. Returns `[]` if the
  remote call fails.
  """
  @spec list_recent_projects(node()) :: [EvoGit.RecentProject.t()]
  def list_recent_projects(node) do
    EvoGit.RemoteNode.list_recent_projects(node)
  end

  @doc """
  Adds a recent project on the given node.

  Delegates to `EvoGit.RemoteNode.add_recent_project/3`. Returns `:ok` on
  success or `{:error, term()}` on failure.
  """
  @spec add_recent_project(node(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_recent_project(node, path, name) do
    EvoGit.RemoteNode.add_recent_project(node, path, name)
  end

  @doc """
  Returns filesystem path suggestions for the given node.

  Delegates to `EvoGit.RemoteNode.list_path_suggestions/2` — the remote daemon
  resolves paths against its own filesystem. Returns `[]` if the remote call
  fails.
  """
  @spec list_path_suggestions(node(), String.t() | nil) :: [String.t()]
  def list_path_suggestions(node, value) do
    EvoGit.RemoteNode.list_path_suggestions(node, value)
  end

  @doc """
  Returns whether `path` is a directory on the given node.

  Delegates to `EvoGit.RemoteNode.dir?/2` — the check runs on the remote
  daemon's filesystem. Returns `false` if the remote call fails.
  """
  @spec dir?(node(), String.t()) :: boolean()
  def dir?(node, path) do
    EvoGit.RemoteNode.dir?(node, path)
  end

  @doc """
  Starts a task on the given node.

  Delegates to `EvoGit.RemoteNode.start_task/3`. Returns `{:ok, task}` on success
  or `{:error, reason}` on failure.
  """
  @spec start_task(node(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_task(node, task_type, opts) do
    EvoGit.RemoteNode.start_task(node, task_type, opts)
  end

  @doc """
  Returns whether a file exists at `path` on the given node.

  Delegates to `EvoGit.RemoteNode.file_exists?/2`. Returns `false` if the remote
  call fails.
  """
  @spec file_exists?(node(), String.t()) :: boolean()
  def file_exists?(node, path) do
    EvoGit.RemoteNode.file_exists?(node, path)
  end

  @doc """
  Lists directory contents at `path` on the given node.

  Delegates to `EvoGit.RemoteNode.ls/2`. Returns `{:ok, [String.t()]} | {:error, term()}`.
  """
  @spec ls(node(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(node, path) do
    EvoGit.RemoteNode.ls(node, path)
  end

  @doc """
  Reads the project configuration (genesis.toml) from the given path on the given node.

  Delegates to `EvoGit.RemoteNode.read_project_config/2`. Returns the parsed
  config map or `nil` if the file doesn't exist or the remote call fails.
  """
  @spec read_project_config(node(), String.t()) :: map() | nil
  def read_project_config(node, path) do
    EvoGit.RemoteNode.read_project_config(node, path)
  end

  @doc """
  Lists task summaries filtered by project path on the given node.

  Delegates to `EvoGit.RemoteNode.list_tasks_summary_by_path/3`. Returns `[]` if
  the remote call fails.
  """
  @spec list_tasks_summary_by_path(node(), String.t(), [atom()]) :: [map()]
  def list_tasks_summary_by_path(node, path, statuses \\ []) do
    EvoGit.RemoteNode.list_tasks_summary_by_path(node, path, statuses)
  end

  # ── Task review operations ───────────────────────────────────────
  #
  # Delegates to EvoGit.RemoteNode's node-first review wrappers so the code
  # review git operations run on the TARGET node's filesystem (local → direct
  # call, remote → routed through `:erpc`). Return values follow the RemoteNode
  # envelope convention: the VERBATIM underlying value in BOTH paths; only
  # transport failures surface as `{:error, {kind, reason}}`.

  @doc """
  Fetches a single task by id on the given node.

  Delegates to `EvoGit.RemoteNode.get_task/2`. Returns the `%EvoGit.TaskInfo{}`
  or `nil` if the task does not exist (or the remote call fails).
  """
  @spec get_task(node(), String.t()) :: EvoGit.TaskInfo.t() | nil
  def get_task(node, task_id) do
    EvoGit.RemoteNode.get_task(node, task_id)
  end

  @doc """
  Sets the review status for a task on the given node.

  Delegates to `EvoGit.RemoteNode.set_review_status/3`. Returns `:ok` on
  success or `{:error, reason}` on failure (including RPC failures).
  """
  @spec set_review_status(node(), String.t(), atom()) :: :ok | {:error, term()}
  def set_review_status(node, task_id, status) do
    EvoGit.RemoteNode.set_review_status(node, task_id, status)
  end

  @doc """
  Sets the review metadata (base and commit SHAs) for a task on the given node.

  Delegates to `EvoGit.RemoteNode.set_review_metadata/4`. Returns `:ok` on
  success or `{:error, reason}` on failure (including RPC failures).
  """
  @spec set_review_metadata(node(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def set_review_metadata(node, task_id, base_sha, commit_sha) do
    EvoGit.RemoteNode.set_review_metadata(node, task_id, base_sha, commit_sha)
  end

  @doc """
  Lists commits between the merge-base and a branch tip on the given node.

  Delegates to `EvoGit.RemoteNode.list_commits/3`. Returns
  `{:ok, [%EvoGit.Review.CommitInfo{}]}` or `{:error, reason}`. On RPC
  failure, returns `{:error, {kind, reason}}`.
  """
  @spec list_commits(node(), String.t(), String.t()) ::
          {:ok, [EvoGit.Review.CommitInfo.t()]} | {:error, term()}
  def list_commits(node, repo_path, branch_name) do
    EvoGit.RemoteNode.list_commits(node, repo_path, branch_name)
  end

  @doc """
  Loads all review data (diff stat, full diff, parsed files) for a branch on
  the given node.

  Delegates to `EvoGit.RemoteNode.load_review_data/3`. Returns
  `{:ok, review_data_map}` or an error tuple. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_review_data(node(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_review_data(node, repo_path, branch_name) do
    EvoGit.RemoteNode.load_review_data(node, repo_path, branch_name)
  end

  @doc """
  Loads review metadata only (file list with counts, no diffs) for a branch
  on the given node.

  Delegates to `EvoGit.RemoteNode.load_review_metadata/3`. Returns
  `{:ok, review_data_map}` or an error tuple. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_review_metadata(node(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_review_metadata(node, repo_path, branch_name) do
    EvoGit.RemoteNode.load_review_metadata(node, repo_path, branch_name)
  end

  @doc """
  Loads the diff of a single file between two commits on the given node.

  Delegates to `EvoGit.RemoteNode.load_file_diff/5`. Returns the diff result
  from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_file_diff(node(), String.t(), String.t(), String.t(), String.t()) :: term()
  def load_file_diff(node, repo_path, base_sha, commit_sha, file_path) do
    EvoGit.RemoteNode.load_file_diff(node, repo_path, base_sha, commit_sha, file_path)
  end

  @doc """
  Loads the diff of a single file between two commits on the given node,
  with options.

  Delegates to `EvoGit.RemoteNode.load_file_diff/6`. `opts` is a keyword
  list of options (e.g. context lines). Returns the diff result from
  `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_file_diff(node(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          term()
  def load_file_diff(node, repo_path, base_sha, commit_sha, file_path, opts) do
    EvoGit.RemoteNode.load_file_diff(node, repo_path, base_sha, commit_sha, file_path, opts)
  end

  @doc """
  Loads review metadata from explicit base/commit SHAs on the given node (no
  branch resolution).

  Delegates to `EvoGit.RemoteNode.load_review_metadata_from_shas/4`. Returns
  the result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_review_metadata_from_shas(node(), String.t(), String.t(), String.t()) :: term()
  def load_review_metadata_from_shas(node, repo_path, base_sha, commit_sha) do
    EvoGit.RemoteNode.load_review_metadata_from_shas(node, repo_path, base_sha, commit_sha)
  end

  @doc """
  Lists commits between explicit base/commit SHAs on the given node (no
  branch resolution).

  Delegates to `EvoGit.RemoteNode.list_commits_from_shas/4`. Returns the
  result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec list_commits_from_shas(node(), String.t(), String.t(), String.t()) :: term()
  def list_commits_from_shas(node, repo_path, base_sha, commit_sha) do
    EvoGit.RemoteNode.list_commits_from_shas(node, repo_path, base_sha, commit_sha)
  end

  @doc """
  Lists the files changed in a single commit on the given node.

  Delegates to `EvoGit.RemoteNode.load_commit_files/3`. Returns the result
  from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_commit_files(node(), String.t(), String.t()) :: term()
  def load_commit_files(node, repo_path, commit_sha) do
    EvoGit.RemoteNode.load_commit_files(node, repo_path, commit_sha)
  end

  @doc """
  Loads the diff of a single file within a single commit on the given node.

  Delegates to `EvoGit.RemoteNode.load_commit_file_diff/4`. Returns the
  result from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec load_commit_file_diff(node(), String.t(), String.t(), String.t()) :: term()
  def load_commit_file_diff(node, repo_path, commit_sha, file_path) do
    EvoGit.RemoteNode.load_commit_file_diff(node, repo_path, commit_sha, file_path)
  end

  @doc """
  Merges an agent branch into the repository's default merge target on the
  given node.

  Delegates to `EvoGit.RemoteNode.merge_branch/3`. Returns `{:ok, sha}` on
  success, `{:conflict, details}` on a merge conflict, or `{:error, reason}`
  on failure. On RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec merge_branch(node(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def merge_branch(node, repo_path, branch_name) do
    EvoGit.RemoteNode.merge_branch(node, repo_path, branch_name)
  end

  @doc """
  Merges an agent branch into an explicit target branch on the given node.

  Delegates to `EvoGit.RemoteNode.merge_branch/4`. Returns `{:ok, sha}` on
  success, `{:conflict, details}` on a merge conflict, or `{:error, reason}`
  on failure. On RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec merge_branch(node(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def merge_branch(node, repo_path, branch_name, target_branch) do
    EvoGit.RemoteNode.merge_branch(node, repo_path, branch_name, target_branch)
  end

  @doc """
  Resolves the default merge target branch for a repository on the given node.

  Delegates to `EvoGit.RemoteNode.default_merge_target/2`. Returns the branch
  name (`main` → `master` → `dev` → `prod` → current → first local branch) or
  `{:error, :no_branch_found}`. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec default_merge_target(node(), String.t()) :: String.t() | {:error, term()}
  def default_merge_target(node, repo_path) do
    EvoGit.RemoteNode.default_merge_target(node, repo_path)
  end

  @doc """
  Lists all local branches in a repository on the given node.

  Delegates to `EvoGit.RemoteNode.list_branches/2`. Returns
  `{:ok, [String.t()]}` or `{:error, {tag, output}}`. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec list_branches(node(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_branches(node, repo_path) do
    EvoGit.RemoteNode.list_branches(node, repo_path)
  end

  @doc """
  Rejects (deletes) an agent branch in a repository on the given node.

  Delegates to `EvoGit.RemoteNode.reject_branch/3`. Returns the result from
  `EvoGit.Review` verbatim. On RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec reject_branch(node(), String.t(), String.t()) :: term()
  def reject_branch(node, repo_path, branch_name) do
    EvoGit.RemoteNode.reject_branch(node, repo_path, branch_name)
  end

  @doc """
  Creates a GitHub pull request for an agent branch on the given node.

  Delegates to `EvoGit.RemoteNode.create_github_pr/5`. Returns the result
  from `EvoGit.Review` verbatim. On RPC failure, returns
  `{:error, {kind, reason}}`.
  """
  @spec create_github_pr(node(), String.t(), String.t(), String.t(), String.t()) :: term()
  def create_github_pr(node, repo_path, branch_name, objective, result) do
    EvoGit.RemoteNode.create_github_pr(node, repo_path, branch_name, objective, result)
  end

  @doc """
  Checks whether a branch exists in a repository on the given node.

  Delegates to `EvoGit.RemoteNode.branch_exists?/3`. Returns a boolean. On
  RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec branch_exists?(node(), String.t(), String.t()) :: boolean() | {:error, term()}
  def branch_exists?(node, repo_path, branch_name) do
    EvoGit.RemoteNode.branch_exists?(node, repo_path, branch_name)
  end

  @doc """
  Dry-runs merging a branch into an explicit target branch on the given node
  WITHOUT mutating the repository.

  Delegates to `EvoGit.RemoteNode.check_merge/4`. Returns `{:ok, :clean}`
  when the merge applies cleanly, `{:ok, {:conflict, files}}` with the list of
  conflicting file paths when it does not, or `{:error, reason}` on failure.
  On RPC failure, returns `{:error, {kind, reason}}`.
  """
  @spec check_merge(node(), String.t(), String.t(), String.t()) ::
          {:ok, :clean} | {:ok, {:conflict, [String.t()]}} | {:error, term()}
  def check_merge(node, repo_path, branch, target) do
    EvoGit.RemoteNode.check_merge(node, repo_path, branch, target)
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
