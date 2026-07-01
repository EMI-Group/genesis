defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and persisted to SQLite (the single source of truth)
  under namespaced keys `{:task, task_id}`.
  Runtime-only task references (`%Task{}`) are kept in-memory in `task_refs`.
  Supports configurable persistence of finished tasks and
  recently opened projects to SQLite (platform data directory via EvoGit.Platform),
  using namespaced keys `{:project, path}`.
  """
  use GenServer

  require Logger

  @max_recent_projects 10

  defmodule TaskInfo do
    @moduledoc """
    Struct representing a task in the registry.
    """
    defstruct [
      :id,
      :type,
      :opts,
      :ref,
      :pid,
      :started_at,
      :finished_at,
      status: :pending,
      logs: [],
      result: nil,
      review_status: nil,
      usage: nil,
      agent_count: nil,
      base_sha: nil,
      commit_sha: nil,
      archive_metadata: nil
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            type: atom() | nil,
            status: :pending | :running | :finalizing | :completed | :failed | :cancelled,
            opts: keyword() | nil,
            ref: Task.t() | nil,
            pid: pid() | nil,
            started_at: DateTime.t() | nil,
            finished_at: DateTime.t() | nil,
            logs: [String.t()],
            result: term(),
            review_status: atom() | nil,
            usage: EvoGit.Agent.Usage.t() | nil,
            agent_count: pos_integer() | nil,
            base_sha: String.t() | nil,
            commit_sha: String.t() | nil,
            archive_metadata: [map()] | nil
          }
  end

  ## Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_task(task_type, opts) do
    task_id = generate_id()
    GenServer.call(__MODULE__, {:start_task, task_id, task_type, opts})
  end

  def get_task(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id})
  end

  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  def cancel_task(task_id) do
    GenServer.call(__MODULE__, {:cancel_task, task_id})
  end

  def update_task_status(task_id, status, result \\ nil, opts \\ []) do
    GenServer.cast(__MODULE__, {:update_status, task_id, status, result, opts})
  end

  def update_task_log(task_id, log_entry) do
    GenServer.cast(__MODULE__, {:append_log, task_id, log_entry})
  end

  def set_review_status(task_id, status) do
    GenServer.cast(__MODULE__, {:set_review_status, task_id, status})
  end

  def set_review_metadata(task_id, base_sha, commit_sha) do
    GenServer.cast(__MODULE__, {:set_review_metadata, task_id, base_sha, commit_sha})
  end

  def list_tasks_by_path(path) do
    GenServer.call(__MODULE__, {:list_tasks_by_path, path})
  end

  def get_unique_paths do
    GenServer.call(__MODULE__, :get_unique_paths)
  end

  def delete_task(task_id) do
    GenServer.cast(__MODULE__, {:delete_task, task_id})
  end

  def clear_finished_tasks do
    GenServer.call(__MODULE__, :clear_finished_tasks)
  end

  ## Recent Projects Client API

  @doc """
  Adds or updates a project in the recently opened list.
  Moves it to the top with the current timestamp.
  """
  def add_recent_project(path, name) do
    GenServer.call(__MODULE__, {:add_recent_project, path, name})
  end

  @doc """
  Returns the list of recently opened projects, sorted by last_opened_at descending.
  """
  def list_recent_projects do
    GenServer.call(__MODULE__, :list_recent_projects)
  end

  @doc """
  Removes a project from the recent list by path.
  """
  def remove_recent_project(path) do
    GenServer.call(__MODULE__, {:remove_recent_project, path})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Allow data_dir to be overridden via opts (for testing), fallback to platform default
    data_dir = Keyword.get(opts, :data_dir, EvoGit.Platform.data_dir())
    File.mkdir_p!(data_dir)

    # The TaskStore is started by the supervisor; here just reference by name.
    # Tests may pass their own task_store: name pointing to a test store.
    task_store = Keyword.get(opts, :task_store, EvoDash.TaskStore)

    state = %{
      data_dir: data_dir,
      task_store: task_store,
      task_refs: %{}
    }

    # Repair the store from any corrupt (un-deserializable) entries before we
    # read or normalize anything. Best-effort: never let this crash init.
    try do
      EvoDash.TaskStore.integrity_check(task_store)
    rescue
      error ->
        Logger.warning("TaskRegistry init: integrity check failed: #{inspect(error)}")
    end

    # One-time best-effort DETS→SQLite migration (before normalize).
    maybe_migrate_from_dets(state)

    # NOTE: CubDB→SQLite migration is intentionally skipped. CubDB is no longer
    # a dependency, so we cannot read old CubDB files at runtime. Old task
    # history stored under a legacy "tasks.cubdb" directory is orphaned but
    # harmless (it is non-critical, auto-expiring data). We only log a note.
    maybe_note_legacy_cubdb()

    # Normalize SQLite entries in place (backfill fields, reset crashed tasks,
    # and re-monitor any tasks whose processes are still alive under the sibling
    # TaskSupervisor).
    state = normalize_tasks(state)

    # Cleanup expired tasks on startup
    cleanup_expired_tasks(state)

    # Subscribe to task status events from EvoGit.PubSub
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:start_task, task_id, task_type, opts}, _from, state) do
    task_ref =
      Task.Supervisor.async_nolink(
        EvoDash.TaskSupervisor,
        __MODULE__,
        :execute_task,
        [task_type, opts, task_id]
      )

    task = %TaskInfo{
      id: task_id,
      type: task_type,
      status: :running,
      opts: opts,
      ref: task_ref,
      pid: task_ref.pid,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil
    }

    # Persist to SQLite with ref nulled (ref is runtime-only data)
    EvoDash.TaskStore.put(state.task_store, {:task, task_id}, %{task | ref: nil})

    # Keep the runtime ref in-memory only
    state = %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, {:ok, task}, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task = task_get(state, task_id)
    {:reply, task, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks = select_all_tasks(state) |> Enum.map(fn {_key, task} -> task end)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    {result, state} =
      case task_get(state, task_id) do
        %TaskInfo{status: :running} = task ->
          case Map.get(state.task_refs, task_id) do
            %Task{pid: pid} = task_ref ->
              if Process.alive?(pid) do
                # Notify the AgentScheduler to cancel all agents for this task
                # before killing the wrapper process. The scheduler uses the caller PID
                # to find the matching top-level agent and cascade cleanup to subagents.
                try do
                  EvoGit.AgentScheduler.cancel_task_agents(pid)
                rescue
                  _ -> :ok
                catch
                  _, _ -> :ok
                end

                Task.shutdown(task_ref, :brutal_kill)
                updated = %{task | status: :cancelled, finished_at: DateTime.utc_now()}
                EvoDash.TaskStore.put(state.task_store, {:task, task_id}, updated)
                cleanup_expired_tasks(state)
                state = %{state | task_refs: Map.delete(state.task_refs, task_id)}
                {:ok, state}
              else
                {{:error, :not_running}, state}
              end

            nil ->
              {{:error, :not_running}, state}
          end

        %TaskInfo{} ->
          {{:error, :not_running}, state}

        nil ->
          {{:error, :not_found}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tasks_by_path, path}, _from, state) do
    expanded = Path.expand(path)

    tasks =
      select_all_tasks(state)
      |> Enum.filter(fn {_key, task} ->
        task.opts[:path] && Path.expand(task.opts[:path]) == expanded
      end)
      |> Enum.map(fn {_key, task} -> task end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:get_unique_paths, _from, state) do
    paths =
      select_all_tasks(state)
      |> Enum.map(fn {_key, task} -> task.opts[:path] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:reply, paths, state}
  end

  @impl true
  def handle_call(:clear_finished_tasks, _from, state) do
    keys =
      select_all_tasks(state)
      |> Enum.filter(fn {{:task, _id}, task} -> task.status not in [:running, :pending] end)
      |> Enum.map(fn {{:task, id}, _task} -> {:task, id} end)

    EvoDash.TaskStore.delete_multi(state.task_store, keys)

    cleanup_expired_tasks(state)
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, :ok, state}
  end

  ## Recent Projects Handlers

  @impl true
  def handle_call({:add_recent_project, path, name}, _from, state) do
    {reply, state} =
      try do
        do_add_recent_project(state, path, name)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: add_recent_project failed for path #{inspect(path)}: " <>
              "#{Exception.message(error)}"
          )

          {{:error, Exception.message(error)}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list_recent_projects, _from, state) do
    reply =
      try do
        do_list_recent_projects(state)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: list_recent_projects failed: " <>
              "#{Exception.message(error)}"
          )

          []
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:remove_recent_project, path}, _from, state) do
    {reply, state} =
      try do
        do_remove_recent_project(state, path)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: remove_recent_project failed for path #{inspect(path)}: " <>
              "#{Exception.message(error)}"
          )

          {{:error, Exception.message(error)}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result, opts}, state) do
    state =
      try do
        do_handle_update_status(state, task_id, status, result, opts)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: update_status failed for task #{inspect(task_id)}: " <>
              "#{Exception.message(error)}"
          )

          state
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:append_log, task_id, log_entry}, state) do
    state =
      try do
        do_append_log(state, task_id, log_entry)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: append_log failed for task #{inspect(task_id)}: " <>
              "#{Exception.message(error)}"
          )

          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    state =
      try do
        do_delete_task(state, task_id)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: delete_task failed for task #{inspect(task_id)}: " <>
              "#{Exception.message(error)}"
          )

          state
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_status, task_id, status}, state) do
    state =
      try do
        do_set_review_status(state, task_id, status)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: set_review_status failed for task #{inspect(task_id)}: " <>
              "#{Exception.message(error)}"
          )

          state
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_metadata, task_id, base_sha, commit_sha}, state) do
    state =
      try do
        do_set_review_metadata(state, task_id, base_sha, commit_sha)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: set_review_metadata failed for task #{inspect(task_id)}: " <>
              "#{Exception.message(error)}"
          )

          state
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  ## Public Task Functions

  @doc """
  Execute a task. This function runs in a separate process under Task.Supervisor.
  """
  def execute_task(:genesis, opts, task_id) do
    {_input_arg, runtime_opts} = build_common_runtime_opts(opts, task_id)
    prompt = Keyword.get(opts, :prompt, "")
    EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
  end

  def execute_task(:evolve, opts, task_id) do
    {_input_arg, runtime_opts} = build_common_runtime_opts(opts, task_id)
    objective = Keyword.get(opts, :objective, "")
    EvoGit.Runtime.Evolution.run(objective, runtime_opts)
  end

  def execute_task(:extract_skills, opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    Application.ensure_all_started(:evo_git)

    runtime_opts = [repo_path: repo_path, task_id: task_id]

    # Pass through PR context keys to the runtime
    pr_context_keys = [
      :pr_title,
      :pr_objective,
      :pr_summary,
      :pr_commit_history,
      :base_sha,
      :commit_sha,
      :user_note,
      :foreign_repos
    ]

    runtime_opts =
      Enum.reduce(pr_context_keys, runtime_opts, fn key, acc ->
        case Keyword.get(opts, key) do
          nil -> acc
          value -> Keyword.put(acc, key, value)
        end
      end)

    EvoGit.Runtime.SkillExtraction.run(runtime_opts)
  end

  ## Private Functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # --- TaskStore Read Helpers ---

  defp task_get(state, task_id) do
    EvoDash.TaskStore.safe_get(state.task_store, {:task, task_id})
  end

  defp select_all_tasks(state) do
    state.task_store
    |> EvoDash.TaskStore.safe_select_all()
    |> Enum.filter(fn
      {{:task, _id}, %TaskInfo{}} -> true
      _ -> false
    end)
  end

  defp select_all_projects(state) do
    state.task_store
    |> EvoDash.TaskStore.safe_select_all()
    |> Enum.filter(fn
      {{:project, _path}, %{path: _, name: _, last_opened_at: _}} -> true
      _ -> false
    end)
  end

  # --- Crash-safe callback bodies ---
  # These private helpers contain the logic extracted from the handle_cast /
  # handle_call / handle_info callbacks above, so the callbacks can wrap them
  # in try/rescue without crashing the GenServer.

  defp do_add_recent_project(state, path, name) do
    now = DateTime.utc_now()

    EvoDash.TaskStore.put(
      state.task_store,
      {:project, path},
      %{path: path, name: name, last_opened_at: now}
    )

    # Enforce max limit
    trim_recent_projects(state)

    {:ok, state}
  end

  defp do_list_recent_projects(state) do
    select_all_projects(state)
    |> Enum.map(fn {_key, project} -> project end)
    |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})
  end

  defp do_remove_recent_project(state, path) do
    EvoDash.TaskStore.delete(state.task_store, {:project, path})
    {:ok, state}
  end

  defp do_handle_update_status(state, task_id, status, result, opts) do
    usage = Keyword.get(opts, :usage)
    agent_count = Keyword.get(opts, :agent_count)
    commit_sha = Keyword.get(opts, :commit_sha)
    archive_records = Keyword.get(opts, :archive_records)

    case task_get(state, task_id) do
      %TaskInfo{} = task ->
        finished_at =
          if status in [:completed, :failed, :cancelled],
            do: DateTime.utc_now(),
            else: task.finished_at

        updated = %{task | status: status, result: result, finished_at: finished_at}
        updated = if usage, do: %{updated | usage: usage}, else: updated
        updated = if agent_count, do: %{updated | agent_count: agent_count}, else: updated
        updated = if commit_sha, do: %{updated | commit_sha: commit_sha}, else: updated

        updated =
          if archive_records, do: %{updated | archive_metadata: archive_records}, else: updated

        EvoDash.TaskStore.put(state.task_store, {:task, task_id}, updated)

        if status in [:completed, :failed, :cancelled] do
          cleanup_expired_tasks(state)
          %{state | task_refs: Map.delete(state.task_refs, task_id)}
        else
          state
        end

      nil ->
        state
    end
  end

  defp do_append_log(state, task_id, log_entry) do
    case task_get(state, task_id) do
      %TaskInfo{logs: logs} = task ->
        updated = %{task | logs: [log_entry | logs]}
        EvoDash.TaskStore.put(state.task_store, {:task, task_id}, updated)

      nil ->
        :ok
    end

    state
  end

  defp do_delete_task(state, task_id) do
    EvoDash.TaskStore.delete(state.task_store, {:task, task_id})
    state
  end

  defp do_set_review_status(state, task_id, status) do
    case task_get(state, task_id) do
      %TaskInfo{} = task ->
        updated = %{task | review_status: status}
        EvoDash.TaskStore.put(state.task_store, {:task, task_id}, updated)

      nil ->
        :ok
    end

    state
  end

  defp do_set_review_metadata(state, task_id, base_sha, commit_sha) do
    case task_get(state, task_id) do
      %TaskInfo{} = task ->
        updated = %{task | base_sha: base_sha, commit_sha: commit_sha}
        EvoDash.TaskStore.put(state.task_store, {:task, task_id}, updated)

      nil ->
        :ok
    end

    state
  end

  defp do_handle_task_status(state, task_id, status) do
    case task_get(state, task_id) do
      %TaskInfo{} = task ->
        finished_at =
          if status in [:completed, :failed, :cancelled],
            do: DateTime.utc_now(),
            else: task.finished_at

        updated = %{task | status: status, finished_at: finished_at}
        EvoDash.TaskStore.put(state.task_store, {:task, task_id}, updated)

        if status in [:completed, :failed, :cancelled] do
          cleanup_expired_tasks(state)
          %{state | task_refs: Map.delete(state.task_refs, task_id)}
        else
          state
        end

      nil ->
        state
    end
  end

  # --- One-time DETS→SQLite Migration (best-effort) ---

  defp maybe_migrate_from_dets(state) do
    if EvoDash.TaskStore.size(state.task_store) == 0 do
      migrate_dets_to_store(state.data_dir, state.task_store)
    end
  end

  defp migrate_dets_to_store(data_dir, task_store) do
    migrate_tasks_dets(data_dir, task_store)
    migrate_projects_dets(data_dir, task_store)
  end

  # NOTE: There is NO CubDB→SQLite migration. CubDB is no longer a dependency,
  # so we cannot read old CubDB data files at runtime. This helper merely logs
  # an informational note if a legacy CubDB directory is detected, so users
  # know why their old task history is not carried over. Old CubDB directories
  # are orphaned but harmless (they contain non-critical, auto-expiring data).
  defp maybe_note_legacy_cubdb do
    old_cubdb_path = Path.join(EvoGit.Platform.data_dir(), "tasks.cubdb")

    if File.dir?(old_cubdb_path) do
      Logger.info(
        "Detected legacy CubDB directory at #{old_cubdb_path}. " <>
          "Old CubDB task history is not migrated to SQLite and will be ignored."
      )
    end
  end

  defp migrate_tasks_dets(data_dir, task_store) do
    path = Path.join(data_dir, "tasks.dets")

    if File.exists?(path) do
      try do
        case :dets.open_file(:evo_dash_tasks_dets,
               type: :set,
               file: to_charlist(path),
               repair: true
             ) do
          {:ok, table} ->
            records =
              :dets.foldl(
                fn {_id, %TaskInfo{} = task} = _obj, acc ->
                  EvoDash.TaskStore.put(task_store, {:task, task.id}, task)
                  acc + 1
                end,
                0,
                table
              )

            _ = :dets.close(table)

            Logger.info("DETS→SQLite migration: migrated #{records} task(s) from #{path}.")

          {:error, reason} ->
            Logger.warning(
              "DETS→SQLite migration: could not open tasks DETS file #{path}: " <>
                "#{inspect(reason)}. Starting fresh."
            )
        end
      catch
        kind, reason ->
          Logger.warning(
            "DETS→SQLite migration: failed to read tasks DETS file #{path}: " <>
              "#{kind}: #{inspect(reason)}. Starting fresh."
          )
      after
        # Rename the old DETS file so we don't retry every launch.
        rename_migrated_file(path)
      end
    end
  end

  defp migrate_projects_dets(data_dir, task_store) do
    path = Path.join(data_dir, "recent_projects.dets")

    if File.exists?(path) do
      try do
        case :dets.open_file(:evo_dash_projects_dets,
               type: :set,
               file: to_charlist(path),
               repair: true
             ) do
          {:ok, table} ->
            records =
              :dets.foldl(
                fn {proj_path, project}, acc ->
                  EvoDash.TaskStore.put(task_store, {:project, proj_path}, project)
                  acc + 1
                end,
                0,
                table
              )

            _ = :dets.close(table)

            Logger.info("DETS→SQLite migration: migrated #{records} project(s) from #{path}.")

          {:error, reason} ->
            Logger.warning(
              "DETS→SQLite migration: could not open projects DETS file #{path}: " <>
                "#{inspect(reason)}. Starting fresh."
            )
        end
      catch
        kind, reason ->
          Logger.warning(
            "DETS→SQLite migration: failed to read projects DETS file #{path}: " <>
              "#{kind}: #{inspect(reason)}. Starting fresh."
          )
      after
        # Rename the old DETS file so we don't retry every launch.
        rename_migrated_file(path)
      end
    end
  end

  defp rename_migrated_file(path) do
    migrated_path = path <> ".migrated"

    case File.rename(path, migrated_path) do
      :ok ->
        Logger.info("DETS→SQLite migration: renamed #{path} → #{migrated_path}.")

      {:error, reason} ->
        Logger.warning(
          "DETS→SQLite migration: could not rename #{path} to #{migrated_path}: " <>
            "#{inspect(reason)}. The file will be retried on next launch."
        )
    end
  end

  # --- Task Normalization ---

  defp normalize_tasks(state) do
    objects = select_all_tasks(state)

    Enum.reduce(objects, state, fn {_key, %TaskInfo{} = task}, acc ->
      try do
        task = Map.merge(%TaskInfo{}, task)
        {task, acc} = reconcile_task_status(task, acc)
        # Persist with ref nulled (ref is runtime-only data)
        EvoDash.TaskStore.put(state.task_store, {:task, task.id}, %{task | ref: nil})
        acc
      rescue
        error ->
          Logger.warning(
            "normalize_tasks: failed to normalize task #{inspect(task.id)}: #{inspect(error)}"
          )

          acc
      end
    end)
  end

  # Reconcile a task's status after a registry restart.
  # Running/pending tasks that are still alive (pid exists and Process.alive?/1)
  # are kept as :running and re-monitored. Dead or pid-less tasks are marked
  # :failed (they crashed or were orphaned by a VM restart). Other statuses
  # are left unchanged.
  defp reconcile_task_status(%TaskInfo{status: status} = task, state)
       when status in [:running, :pending] do
    if task.pid != nil and Process.alive?(task.pid) do
      # Task process is still alive under the sibling TaskSupervisor.
      ref = Process.monitor(task.pid)
      # Construct a %Task{} matching the shape of a Task.Supervisor task ref so
      # that the existing pattern matches (%Task{pid:, ref:, owner:}) keep
      # working. :mfa is required by the struct but unused for re-monitors.
      task_ref = %Task{pid: task.pid, ref: ref, owner: self(), mfa: nil}

      Logger.warning("TaskRegistry: re-monitoring still-running task #{task.id} after restart")

      {%{task | status: :running, ref: nil},
       %{state | task_refs: Map.put(state.task_refs, task.id, task_ref)}}
    else
      # Pid is nil or dead — actual crash / orphan. Mark as failed.
      {%{task | status: :failed, ref: nil} |> set_crash_details(), state}
    end
  end

  defp reconcile_task_status(%TaskInfo{} = task, state) do
    {%{task | ref: nil}, state}
  end

  defp set_crash_details(%{status: :failed, finished_at: nil} = task) do
    %{task | finished_at: DateTime.utc_now(), result: "Process crashed while task was running"}
  end

  defp set_crash_details(task), do: task

  defp task_history_config do
    defaults = %{max_tasks: 100, max_age_days: 14}
    config = EvoGit.Config.resolve()[:task_history] || %{}
    Map.merge(defaults, config)
  end

  defp cleanup_expired_tasks(state) do
    try do
      do_cleanup_expired_tasks(state)
    rescue
      error ->
        Logger.warning("cleanup_expired_tasks failed (non-fatal): #{inspect(error)}")
        :ok
    end
  end

  defp do_cleanup_expired_tasks(state) do
    config = task_history_config()
    max_age_days = config.max_age_days
    max_tasks = config.max_tasks
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 24 * 60 * 60, :second)

    all_tasks = select_all_tasks(state) |> Enum.map(fn {_key, task} -> task end)

    # Partition: age-expired finished tasks vs everything else
    {age_expired, remaining} =
      Enum.split_with(all_tasks, fn task ->
        task.finished_at != nil and DateTime.compare(task.finished_at, cutoff) == :lt
      end)

    age_expired_keys = Enum.map(age_expired, fn task -> {:task, task.id} end)

    # From remaining finished tasks, enforce max_tasks limit (keep newest)
    over_limit_keys =
      remaining
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
      |> Enum.drop(max_tasks)
      |> Enum.map(fn task -> {:task, task.id} end)

    all_keys = age_expired_keys ++ over_limit_keys

    if all_keys != [] do
      EvoDash.TaskStore.delete_multi(state.task_store, all_keys)
    end

    :ok
  end

  # --- Recent Projects ---

  defp trim_recent_projects(state) do
    projects =
      select_all_projects(state)
      |> Enum.map(fn {_key, project} -> project end)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    case Enum.split(projects, @max_recent_projects) do
      {_kept, []} ->
        :ok

      {_kept, to_remove} ->
        keys = Enum.map(to_remove, fn project -> {:project, project.path} end)
        EvoDash.TaskStore.delete_multi(state.task_store, keys)
        :ok
    end
  end

  # --- Task Execution Helpers ---

  defp build_common_runtime_opts(opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    mode = Keyword.get(opts, :mode, "simple")
    node_path = Keyword.get(opts, :node_path)

    Application.ensure_all_started(:evo_git)

    runtime_opts = [
      repo_path: repo_path,
      mode: evolution_mode_atom(mode),
      task_id: task_id
    ]

    runtime_opts =
      if node_path, do: Keyword.put(runtime_opts, :node_path, node_path), else: runtime_opts

    seed_content = Keyword.get(opts, :seed_content)

    runtime_opts =
      if seed_content,
        do: Keyword.put(runtime_opts, :seed_content, seed_content),
        else: runtime_opts

    starting_commit = Keyword.get(opts, :starting_commit)

    runtime_opts =
      if starting_commit,
        do: Keyword.put(runtime_opts, :starting_commit, starting_commit),
        else: runtime_opts

    # Foreign repos are passed through opts from the dashboard (per-task scoping)
    foreign_repos = Keyword.get(opts, :foreign_repos)

    runtime_opts =
      if foreign_repos,
        do: Keyword.put(runtime_opts, :foreign_repos, foreign_repos),
        else: runtime_opts

    archive = Keyword.get(opts, :archive)

    runtime_opts =
      if archive,
        do: Keyword.put(runtime_opts, :archive, archive),
        else: runtime_opts

    {nil, runtime_opts}
  end

  defp evolution_mode_atom("simple"), do: :simple
  defp evolution_mode_atom("complex"), do: :complex
  defp evolution_mode_atom(other), do: raise(ArgumentError, "invalid evolution mode: #{inspect(other)}")

  ## GenServer Info Handlers

  @impl true
  def handle_info({:task_status, task_id, status}, state) do
    state =
      try do
        do_handle_task_status(state, task_id, status)
      rescue
        error ->
          Logger.error(
            "TaskRegistry: task_status handler failed for task #{inspect(task_id)}: " <>
              "#{Exception.message(error)}"
          )

          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Search the in-memory task_refs map for the matching task reference
    task_id =
      Enum.find_value(state.task_refs, fn {id, %Task{ref: task_ref}} ->
        if task_ref == ref, do: id
      end)

    if task_id do
      status =
        case result do
          {:ok, _} -> :completed
          {:error, _} -> :failed
          {:exit, _} -> :failed
          _ -> :failed
        end

      task_usage =
        case result do
          {:ok, %{usage: %EvoGit.Agent.Usage{} = u}} -> u
          _ -> nil
        end

      task_agent_count =
        case result do
          {:ok, %{agent_count: count}} when is_integer(count) -> count
          _ -> nil
        end

      task_commit_sha =
        case result do
          {:ok, %{commit_sha: sha}} when is_binary(sha) -> sha
          _ -> nil
        end

      task_archive_records =
        case result do
          {:ok, %{archive_records: records}} when is_list(records) -> records
          _ -> nil
        end

      update_task_status(task_id, status, result,
        usage: task_usage,
        agent_count: task_agent_count,
        commit_sha: task_commit_sha,
        archive_records: task_archive_records
      )
    end

    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    task_id =
      Enum.find_value(state.task_refs, fn {id, %Task{ref: task_ref}} ->
        if task_ref == ref, do: id
      end)

    if task_id do
      status = if reason == :normal, do: :completed, else: :failed
      result = if reason == :normal, do: nil, else: "Task process exited: #{inspect(reason)}"
      update_task_status(task_id, status, result)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
