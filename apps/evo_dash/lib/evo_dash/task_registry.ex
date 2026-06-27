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

    tasks_file = Path.join(data_dir, "tasks.dets")
    projects_file = Path.join(data_dir, "recent_projects.dets")

    # Open or create DETS tables (auto-recover from corruption)
    log_open_result(open_or_reset_dets(dets_tasks, tasks_file), tasks_file)
    log_open_result(open_or_reset_dets(dets_projects, projects_file), projects_file)

    state = %{
      data_dir: data_dir,
      dets_tasks: dets_tasks,
      dets_projects: dets_projects,
      dets_tasks_file: tasks_file,
      dets_projects_file: projects_file,
      task_refs: %{},
      recovering: MapSet.new()
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
    safe_insert(state.dets_tasks, {task_id, %{task | ref: nil}})

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
                safe_insert(state.dets_tasks, {task_id, updated})
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
        safe_delete(state.dets_tasks, id)
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
    safe_delete(state.dets_projects, path)

    safe_insert(
      state.dets_projects,
      {path, %{path: path, name: name, last_opened_at: now}}
    )

    # Enforce max limit
    trim_recent_projects(state)

    sync_dets(state.dets_projects)

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
    safe_delete(state.dets_projects, path)
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
          safe_insert(state.dets_tasks, {task_id, updated})
          sync_dets(state.dets_tasks)

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
        safe_insert(state.dets_tasks, {task_id, updated})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    safe_delete(state.dets_tasks, task_id)
    sync_dets(state.dets_tasks)
    cleanup_expired_tasks(state)
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_status, task_id, status}, state) do
    case safe_lookup(state.dets_tasks, task_id) do
      [{^task_id, %TaskInfo{} = task}] ->
        updated = %{task | review_status: status}
        safe_insert(state.dets_tasks, {task_id, updated})
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
        safe_insert(state.dets_tasks, {task_id, updated})
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

  # --- DETS Corruption Recovery ---

  defp log_open_result(result, file_path) do
    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "CRITICAL: DETS table for #{file_path} could not be opened/recovered: #{inspect(reason)}. " <>
            "Proceeding with a stale table reference; future operations will trigger recovery messages."
        )

        :ok
    end
  end

  defp open_or_reset_dets(table_name, file_path) do
    case :dets.open_file(table_name, type: :set, file: to_charlist(file_path)) do
      {:ok, _} ->
        # Verify the table is actually readable (repair may have succeeded at open
        # but corruption can surface during reads).
        if dets_readable?(table_name) do
          :ok
        else
          Logger.warning(
            "DETS table #{inspect(table_name)} opened but reads fail (corruption). " <>
              "Attempting recovery for #{file_path}."
          )

          recover_dets_table(table_name, file_path)
        end

      {:error, reason} ->
        Logger.error(
          "Failed to open DETS file #{file_path}: #{inspect(reason)}. " <>
            "Attempting recovery."
        )

        recover_dets_table(table_name, file_path)
    end
  end

  defp dets_readable?(table_name) do
    with n when is_integer(n) <- :dets.info(table_name, :size),
         true <- dets_foldl_works?(table_name) do
      true
    else
      _ -> false
    end
  end

  # Verify foldl actually works - catches :bad_object errors that :size alone misses
  defp dets_foldl_works?(table_name) do
    try do
      :dets.foldl(fn _obj, acc -> acc + 1 end, 0, table_name)
      true
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp recover_dets_table(table_name, file_path) do
    # Close the current (corrupt) handle first.
    _ = :dets.close(table_name)

    # Back up the original corrupt file BEFORE any repair, to preserve the evidence.
    backup_path = corrupt_backup_path(file_path)
    _ = File.cp(file_path, backup_path)
    Logger.warning("Backed up corrupt DETS file to #{backup_path}")

    # Primary path: reopen with repair: :force which repairs the file IN-PLACE
    # (does NOT delete it), preserving as much data as possible.
    case :dets.open_file(table_name, type: :set, file: to_charlist(file_path), repair: :force) do
      {:ok, _} ->
        # Count records to verify; the repair: :force already wrote fixes in-place.
        size = :dets.info(table_name, :size)

        Logger.info(
          "Recovered DETS table #{inspect(table_name)} in-place via repair: force " <>
            "(#{size} record(s)). Backup at #{backup_path}."
        )

        :ok

      {:error, reason} ->
        # repair: :force failed — fall back to salvage approach, writing to the SAME file.
        Logger.error(
          "repair: force failed for #{file_path}: #{inspect(reason)}. Falling back to salvage."
        )

        salvaged = salvage_dets_objects(table_name, file_path)
        _ = :dets.close(table_name)
        _ = File.rm(file_path)

        case :dets.open_file(table_name, type: :set, file: to_charlist(file_path)) do
          {:ok, _} ->
            for obj <- salvaged, do: :dets.insert(table_name, obj)
            count = length(salvaged)

            if count > 0 do
              Logger.info(
                "Salvaged #{count} record(s) into DETS table #{inspect(table_name)}. " <>
                  "Backup at #{backup_path}."
              )
            else
              Logger.error(
                "No records could be salvaged from corrupt DETS file #{file_path}. " <>
                  "Starting empty. Backup preserved at #{backup_path}."
              )
            end

            :ok

          {:error, reason2} ->
            Logger.error(
              "CRITICAL: Could not recreate DETS file #{file_path}: #{inspect(reason2)}. " <>
                "Backup at #{backup_path}."
            )

            {:error, reason2}
        end
    end
  end

  # Close the current handle, reopen with explicit repair, and salvage as many
  # records as possible. Closes the repaired table before returning so the caller
  # can delete the file and reopen fresh.
  defp salvage_dets_objects(table_name, file_path) do
    _ = :dets.close(table_name)

    salvaged =
      case :dets.open_file(table_name, type: :set, file: to_charlist(file_path), repair: true) do
        {:ok, _} ->
          try_match_object(table_name)

        {:error, reason} ->
          Logger.warning("Could not reopen for repair: #{inspect(reason)}")
          []
      end

    _ = :dets.close(table_name)
    salvaged
  end

  # Attempt a full match_object; on failure fall back to per-object foldl iteration.
  defp try_match_object(table_name) do
    case safe_match_object_attempt(table_name) do
      {:ok, objects} -> objects
      {:error, _} -> salvage_via_foldl(table_name)
    end
  end

  defp safe_match_object_attempt(table_name) do
    try do
      {:ok, :dets.foldl(fn obj, acc -> [obj | acc] end, [], table_name)}
    rescue
      _ -> {:error, :rescued}
    catch
      _, _ -> {:error, :caught}
    end
  end

  defp salvage_via_foldl(table_name) do
    try do
      :dets.foldl(fn obj, acc -> [obj | acc] end, [], table_name)
    rescue
      _ -> []
    end
  end

  defp corrupt_backup_path(file_path) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d-%H%M%S")

    "#{file_path}.corrupt.#{timestamp}"
  end

  def safe_match_object(table_name) do
    # Use foldl to iterate all objects safely - :dets.match_object with {:_, :_} pattern
    # creates invalid tuple of atoms, not a pattern wildcard, and raises ArgumentError.
    # If we encounter :bad_object errors, trigger recovery and retry.
    case try_foldl(table_name) do
      {:ok, objects} -> objects
      {:error, reason} ->
        # Check if this is a bad_object error (corruption) or other read failure
        if bad_object_error?(reason) do
          Logger.error(
            "DETS match_object encountered corrupted object in #{inspect(table_name)}: #{inspect(reason)}. " <>
            "Triggering recovery."
          )
          send(self(), {:recover_dets, table_name})
        else
          Logger.warning(
            "DETS match_object read failed for #{inspect(table_name)}: #{inspect(reason)}. Returning empty."
          )
        end
        []
    end
  end

  defp bad_object_error?({:bad_object, _}), do: true
  defp bad_object_error?(_), do: false

  defp try_foldl(table_name) do
    try do
      result = :dets.foldl(fn obj, acc -> [obj | acc] end, [], table_name)
      case result do
        {:error, _} = error -> error
        objects when is_list(objects) -> {:ok, objects}
      end
    rescue
      e -> {:error, {:rescued, e}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  def safe_lookup(table_name, key) do
    from_dets(table_name, :dets.lookup(table_name, key), "lookup(#{inspect(key)})")
  end

  defp safe_insert(table_name, object) do
    result =
      try do
        :dets.insert(table_name, object)
      rescue
        e -> {:error, {:rescued, e}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "DETS insert failed for table #{inspect(table_name)}: #{inspect(reason)}. " <>
            "Triggering runtime recovery."
        )

        send(self(), {:recover_dets, table_name})
        {:error, reason}
    end
  end

  defp safe_delete(table_name, key) do
    result =
      try do
        :dets.delete(table_name, key)
      rescue
        e -> {:error, {:rescued, e}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "DETS delete failed for table #{inspect(table_name)}: #{inspect(reason)}. " <>
            "Triggering runtime recovery."
        )

        send(self(), {:recover_dets, table_name})
        {:error, reason}
    end
  end

  defp sync_dets(table_name) do
    case :dets.sync(table_name) do
      :ok -> :ok
      {:error, _} = e ->
        Logger.warning("DETS sync failed for table #{inspect(table_name)}: #{inspect(e)}")
        e
    end
  end

  # Pure dispatcher over a :dets read result. Public + documented as internal so the
  # error branch (a `{:error, {:bad_object, ...}}` return from mid-read corruption) can
  # be unit-tested deterministically — that tuple cannot be reliably reproduced against a
  # real open table (OTP's in-memory cache usually masks it) and closed/never-opened
  # tables raise `:badarg` rather than returning `{:error, _}`.
  @doc false
  def from_dets(table_name, {:error, reason}, op) do
    Logger.error(
      "DETS #{op} failed for table #{inspect(table_name)}: #{inspect(reason)}. " <>
        "Returning empty result to avoid crash. (Read errors do not trigger recovery; " <>
        "only write/open failures do.)"
    )

    []
  end

  @doc false
  def from_dets(_table_name, objects, _op) when is_list(objects) do
    objects
  end

  # --- Task Normalization (DETS in-place) ---

  defp normalize_tasks_in_dets(state) do
    objects = safe_match_object(state.dets_tasks)

    try do
      for {_key, %TaskInfo{} = task} <- objects do
        # Backfill any missing struct fields (e.g. review_status added after initial persist)
        task = Map.merge(%TaskInfo{}, task)
        # Reset non-persistable fields
        task = %{task | ref: nil, status: maybe_reset_status(task.status)}
        task = set_crash_details(task)
        safe_insert(state.dets_tasks, {task.id, task})
      end

      :ok
    rescue
      error ->
        Logger.error(
          "Failed to normalize tasks in DETS: #{inspect(error)}. " <>
            "Skipping normalization — existing records preserved."
        )

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
      safe_delete(state.dets_tasks, task.id)
    end

    # Enforce max_tasks limit (keep newest finished tasks)
    remaining = safe_match_object(state.dets_tasks) |> Enum.map(&elem(&1, 1))

    finished =
      remaining
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})

    if length(finished) > max_tasks do
      to_delete = Enum.drop(finished, max_tasks)
      for task <- to_delete, do: safe_delete(state.dets_tasks, task.id)
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
          safe_delete(state.dets_projects, project.path)
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
          safe_insert(state.dets_tasks, {task_id, updated})
          sync_dets(state.dets_tasks)

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
  def handle_info({:recover_dets, table_name}, state) do
    file_path =
      cond do
        MapSet.member?(state.recovering, table_name) ->
          nil

        table_name == state.dets_tasks ->
          state.dets_tasks_file

        table_name == state.dets_projects ->
          state.dets_projects_file

        true ->
          Logger.warning(
            "Received recovery request for unknown DETS table #{inspect(table_name)}; skipping."
          )

          nil
      end

    if file_path do
      # Check if the table is actually still corrupt. A previous recovery in the
      # queue may have already repaired it — in that case skip to avoid creating
      # spurious backup files of a now-healthy table.
      if dets_readable?(table_name) do
        Logger.info(
          "DETS table #{inspect(table_name)} is already readable; skipping redundant recovery."
        )

        {:noreply, state}
      else
        # Guard the table so concurrent recovery signals are skipped.
        recovering = MapSet.put(state.recovering, table_name)
        result = recover_dets_table(table_name, file_path)

        # The table name atom stays the same after reopen, so the state references
        # remain valid — only the recovering guard is cleared.
        if result != :ok do
          Logger.error("Runtime DETS recovery for #{inspect(table_name)} did not fully succeed.")
        end

        {:noreply, %{state | recovering: MapSet.delete(recovering, table_name)}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
