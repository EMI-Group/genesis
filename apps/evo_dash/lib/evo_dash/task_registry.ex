defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and persisted to DETS (the single source of truth).
  Runtime-only task references (`%Task{}`) are kept in-memory in `task_refs`.
  Supports configurable persistence of finished tasks and
  recently opened projects to DETS (platform data directory via EvoGit.Platform).
  """
  use GenServer

  require Logger

  @dets_tasks :evo_dash_tasks_dets
  @dets_projects :evo_dash_projects_dets
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
      :started_at,
      :finished_at,
      status: :pending,
      logs: [],
      result: nil,
      review_status: nil,
      usage: nil,
      agent_count: nil,
      base_sha: nil,
      commit_sha: nil
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            type: atom() | nil,
            status: :pending | :running | :finalizing | :completed | :failed | :cancelled,
            opts: keyword() | nil,
            ref: Task.t() | nil,
            started_at: DateTime.t() | nil,
            finished_at: DateTime.t() | nil,
            logs: [String.t()],
            result: term(),
            review_status: atom() | nil,
            usage: EvoGit.Agent.Usage.t() | nil,
            agent_count: pos_integer() | nil,
            base_sha: String.t() | nil,
            commit_sha: String.t() | nil
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

    # Allow table names to be overridden via opts (for test isolation)
    dets_tasks = Keyword.get(opts, :dets_tasks, @dets_tasks)
    dets_projects = Keyword.get(opts, :dets_projects, @dets_projects)

    # Open or create DETS tables (auto-recover from corruption)
    open_or_reset_dets(dets_tasks, Path.join(data_dir, "tasks.dets"))
    open_or_reset_dets(dets_projects, Path.join(data_dir, "recent_projects.dets"))

    state = %{
      data_dir: data_dir,
      dets_tasks: dets_tasks,
      dets_projects: dets_projects,
      task_refs: %{}
    }

    # Normalize DETS entries in place (backfill fields, reset crashed tasks)
    normalize_tasks_in_dets(state)

    # Cleanup expired tasks on startup
    cleanup_expired_tasks(state)

    # Subscribe to task status events from EvoGit.PubSub
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.dets_tasks)
    :dets.close(state.dets_projects)
    :ok
  end

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
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil
    }

    # Persist to DETS with ref nulled (ref is runtime-only data)
    :dets.insert(state.dets_tasks, {task_id, %{task | ref: nil}})

    # Keep the runtime ref in-memory only
    state = %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, {:ok, task}, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task =
      case safe_lookup(state.dets_tasks, task_id) do
        [{^task_id, task_data}] -> task_data
        [] -> nil
      end

    {:reply, task, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks = safe_match_object(state.dets_tasks) |> Enum.map(fn {_id, task} -> task end)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    {result, state} =
      case safe_lookup(state.dets_tasks, task_id) do
        [{^task_id, %TaskInfo{status: :running} = task}] ->
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
                :dets.insert(state.dets_tasks, {task_id, updated})
                cleanup_expired_tasks(state)
                state = %{state | task_refs: Map.delete(state.task_refs, task_id)}
                {:ok, state}
              else
                {{:error, :not_running}, state}
              end

            nil ->
              {{:error, :not_running}, state}
          end

        [{^task_id, %TaskInfo{}}] ->
          {{:error, :not_running}, state}

        [] ->
          {{:error, :not_found}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tasks_by_path, path}, _from, state) do
    expanded = Path.expand(path)

    tasks =
      safe_match_object(state.dets_tasks)
      |> Enum.filter(fn {_id, task} ->
        task.opts[:path] && Path.expand(task.opts[:path]) == expanded
      end)
      |> Enum.map(fn {_id, task} -> task end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:get_unique_paths, _from, state) do
    paths =
      safe_match_object(state.dets_tasks)
      |> Enum.map(fn {_id, task} -> task.opts[:path] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:reply, paths, state}
  end

  @impl true
  def handle_call(:clear_finished_tasks, _from, state) do
    safe_match_object(state.dets_tasks)
    |> Enum.each(fn {id, task} ->
      unless task.status in [:running, :pending] do
        :dets.delete(state.dets_tasks, id)
      end
    end)

    cleanup_expired_tasks(state)
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, :ok, state}
  end

  ## Recent Projects Handlers

  @impl true
  def handle_call({:add_recent_project, path, name}, _from, state) do
    now = DateTime.utc_now()

    # Remove existing entry for this path (if any), then add updated entry
    :dets.delete(state.dets_projects, path)

    :dets.insert(
      state.dets_projects,
      {path, %{path: path, name: name, last_opened_at: now}}
    )

    # Enforce max limit
    trim_recent_projects(state)

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_recent_projects, _from, state) do
    projects =
      safe_match_object(state.dets_projects)
      |> Enum.map(fn {_path, project} -> project end)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    {:reply, projects, state}
  end

  @impl true
  def handle_call({:remove_recent_project, path}, _from, state) do
    :dets.delete(state.dets_projects, path)
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result, opts}, state) do
    usage = Keyword.get(opts, :usage)
    agent_count = Keyword.get(opts, :agent_count)
    commit_sha = Keyword.get(opts, :commit_sha)

    state =
      case safe_lookup(state.dets_tasks, task_id) do
        [{^task_id, %TaskInfo{} = task}] ->
          finished_at =
            if status in [:completed, :failed, :cancelled],
              do: DateTime.utc_now(),
              else: task.finished_at

          updated = %{task | status: status, result: result, finished_at: finished_at}
          updated = if usage, do: %{updated | usage: usage}, else: updated
          updated = if agent_count, do: %{updated | agent_count: agent_count}, else: updated
          updated = if commit_sha, do: %{updated | commit_sha: commit_sha}, else: updated
          :dets.insert(state.dets_tasks, {task_id, updated})

          if status in [:completed, :failed, :cancelled] do
            cleanup_expired_tasks(state)
            %{state | task_refs: Map.delete(state.task_refs, task_id)}
          else
            state
          end

        _ ->
          state
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:append_log, task_id, log_entry}, state) do
    case safe_lookup(state.dets_tasks, task_id) do
      [{^task_id, %TaskInfo{logs: logs} = task}] ->
        updated = %{task | logs: [log_entry | logs]}
        :dets.insert(state.dets_tasks, {task_id, updated})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    :dets.delete(state.dets_tasks, task_id)
    cleanup_expired_tasks(state)
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_status, task_id, status}, state) do
    case safe_lookup(state.dets_tasks, task_id) do
      [{^task_id, %TaskInfo{} = task}] ->
        updated = %{task | review_status: status}
        :dets.insert(state.dets_tasks, {task_id, updated})
        cleanup_expired_tasks(state)
        Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_metadata, task_id, base_sha, commit_sha}, state) do
    case safe_lookup(state.dets_tasks, task_id) do
      [{^task_id, %TaskInfo{} = task}] ->
        updated = %{task | base_sha: base_sha, commit_sha: commit_sha}
        :dets.insert(state.dets_tasks, {task_id, updated})
        cleanup_expired_tasks(state)
        Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})

      _ ->
        :ok
    end

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

  defp tasks_dets_path(data_dir), do: Path.join(data_dir, "tasks.dets")

  # --- DETS Corruption Recovery ---

  defp open_or_reset_dets(table_name, file_path) do
    case :dets.open_file(table_name, type: :set, file: to_charlist(file_path)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to open DETS file #{file_path}: #{inspect(reason)}. " <>
            "Attempting repair before recreating."
        )

        # Try opening with auto-repair — this can often recover data from an unclean shutdown
        case :dets.open_file(table_name,
               type: :set,
               file: to_charlist(file_path),
               repair: :auto
             ) do
          {:ok, _} ->
            Logger.warning("DETS auto-repair succeeded for #{file_path}")
            :ok

          {:error, repair_reason} ->
            Logger.error(
              "DETS auto-repair failed for #{file_path}: #{inspect(repair_reason)}. " <>
                "Backing up corrupted file to #{file_path}.bak and recreating. " <>
                "DATA LOSS HAS OCCURRED — recent projects and/or tasks have been lost."
            )

            # Backup the corrupted file before deletion so data can potentially be recovered
            _ = File.cp(file_path, file_path <> ".bak")

            _ = File.rm(file_path)
            {:ok, _} = :dets.open_file(table_name, type: :set, file: to_charlist(file_path))
            :ok
        end
    end
  end

  defp reset_dets_table(table_name, file_path) do
    :dets.close(table_name)
    _ = File.rm(file_path)
    {:ok, _} = :dets.open_file(table_name, type: :set, file: to_charlist(file_path))
    :ok
  end

  def safe_match_object(table_name) do
    case :dets.match_object(table_name, {:_, :_}) do
      {:error, reason} ->
        Logger.error(
          "DETS read failed for table #{inspect(table_name)}: #{inspect(reason)}. " <>
            "Returning empty result to avoid crash; table will auto-repair on next open."
        )

        []

      objects when is_list(objects) ->
        objects
    end
  end

  def safe_lookup(table_name, key) do
    case :dets.lookup(table_name, key) do
      {:error, reason} ->
        Logger.error(
          "DETS lookup failed for table #{inspect(table_name)} key #{inspect(key)}: " <>
            "#{inspect(reason)}. Returning empty result to avoid crash; " <>
            "table will auto-repair on next open."
        )

        []

      objects when is_list(objects) ->
        objects
    end
  end

  # --- Task Normalization (DETS in-place) ---

  defp normalize_tasks_in_dets(state) do
    try do
      :dets.foldl(
        fn
          {_key, %TaskInfo{} = task}, acc ->
            # Backfill any missing struct fields (e.g. review_status added after initial persist)
            task = Map.merge(%TaskInfo{}, task)
            # Reset non-persistable fields
            task = %{task | ref: nil, status: maybe_reset_status(task.status)}
            task = set_crash_details(task)
            :dets.insert(state.dets_tasks, {task.id, task})
            acc

          _other, acc ->
            acc
        end,
        :ok,
        state.dets_tasks
      )
    rescue
      error ->
        Logger.error(
          "Failed to normalize tasks in DETS: #{inspect(error)}. " <>
            "Resetting corrupted tasks store."
        )

        reset_dets_table(state.dets_tasks, tasks_dets_path(state.data_dir))
        :ok
    end
  end

  defp maybe_reset_status(:running), do: :failed
  defp maybe_reset_status(:pending), do: :failed
  defp maybe_reset_status(status), do: status

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
    config = task_history_config()
    max_age_days = config.max_age_days
    max_tasks = config.max_tasks
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 24 * 60 * 60, :second)

    # Delete tasks older than cutoff (only finished tasks)
    all_tasks = safe_match_object(state.dets_tasks) |> Enum.map(&elem(&1, 1))

    for task <- all_tasks,
        task.finished_at != nil,
        DateTime.compare(task.finished_at, cutoff) == :lt do
      :dets.delete(state.dets_tasks, task.id)
    end

    # Enforce max_tasks limit (keep newest finished tasks)
    remaining = safe_match_object(state.dets_tasks) |> Enum.map(&elem(&1, 1))

    finished =
      remaining
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})

    if length(finished) > max_tasks do
      to_delete = Enum.drop(finished, max_tasks)
      for task <- to_delete, do: :dets.delete(state.dets_tasks, task.id)
    end

    :ok
  end

  # --- Recent Projects ---

  defp trim_recent_projects(state) do
    projects =
      safe_match_object(state.dets_projects)
      |> Enum.map(fn {_path, project} -> project end)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    case Enum.split(projects, @max_recent_projects) do
      {_kept, []} ->
        :ok

      {_kept, to_remove} ->
        for project <- to_remove do
          :dets.delete(state.dets_projects, project.path)
        end
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
      mode: String.to_atom(mode),
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

    {nil, runtime_opts}
  end

  ## GenServer Info Handlers

  @impl true
  def handle_info({:task_status, task_id, status}, state) do
    state =
      case safe_lookup(state.dets_tasks, task_id) do
        [{^task_id, %TaskInfo{} = task}] ->
          finished_at =
            if status in [:completed, :failed, :cancelled],
              do: DateTime.utc_now(),
              else: task.finished_at

          updated = %{task | status: status, finished_at: finished_at}
          :dets.insert(state.dets_tasks, {task_id, updated})

          if status in [:completed, :failed, :cancelled] do
            cleanup_expired_tasks(state)
            %{state | task_refs: Map.delete(state.task_refs, task_id)}
          else
            state
          end

        _ ->
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

      update_task_status(task_id, status, result,
        usage: task_usage,
        agent_count: task_agent_count,
        commit_sha: task_commit_sha
      )
    end

    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
