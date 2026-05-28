defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and tracked in-memory via ETS.
  Supports persistence of the 10 most recent finished tasks and
  recently opened projects to DETS (platform data directory via EvoGit.Platform).
  """
  use GenServer

  require Logger

  @table_name :evo_dash_tasks
  @recent_projects_table :evo_dash_recent_projects
  @dets_tasks :evo_dash_tasks_dets
  @dets_projects :evo_dash_projects_dets
  @max_persisted_tasks 10
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
      result: nil
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            type: atom() | nil,
            status: :pending | :running | :completed | :failed | :cancelled,
            opts: keyword() | nil,
            ref: Task.t() | nil,
            started_at: DateTime.t() | nil,
            finished_at: DateTime.t() | nil,
            logs: [String.t()],
            result: term()
          }
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  def update_task_status(task_id, status, result \\ nil) do
    GenServer.cast(__MODULE__, {:update_status, task_id, status, result})
  end

  def update_task_log(task_id, log_entry) do
    GenServer.cast(__MODULE__, {:append_log, task_id, log_entry})
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
  def init(_opts) do
    # Ensure data directory exists
    File.mkdir_p!(data_dir())

    # Open or create DETS tables (auto-recover from corruption)
    open_or_reset_dets(@dets_tasks, tasks_dets_path())
    open_or_reset_dets(@dets_projects, recent_projects_dets_path())

    # Create ETS tables for fast in-memory access
    :ets.new(@table_name, [:named_table, :public, :set])
    :ets.new(@recent_projects_table, [:named_table, :public, :set])

    # Load persisted data from DETS into ETS
    load_tasks_from_dets()
    load_recent_projects_from_dets()

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@dets_tasks)
    :dets.close(@dets_projects)
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

    :ets.insert(@table_name, {task_id, task})
    persist_tasks_to_dets()
    {:reply, {:ok, task}, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task =
      case :ets.lookup(@table_name, task_id) do
        [{^task_id, task_data}] -> task_data
        [] -> nil
      end

    {:reply, task, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks = :ets.tab2list(@table_name) |> Enum.map(fn {_id, task} -> task end)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    result =
      case :ets.lookup(@table_name, task_id) do
        [{^task_id, %TaskInfo{status: :running, ref: %Task{pid: pid} = task_ref} = task}] ->
          if Process.alive?(pid) do
            Task.shutdown(task_ref, :brutal_kill)
            updated = %{task | status: :cancelled, finished_at: DateTime.utc_now()}
            :ets.insert(@table_name, {task_id, updated})
            persist_tasks_to_dets()
            :ok
          else
            {:error, :not_running}
          end

        [{^task_id, %TaskInfo{}}] ->
          {:error, :not_running}

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tasks_by_path, path}, _from, state) do
    expanded = Path.expand(path)

    tasks =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_id, task} ->
        task.opts[:path] && Path.expand(task.opts[:path]) == expanded
      end)
      |> Enum.map(fn {_id, task} -> task end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:get_unique_paths, _from, state) do
    paths =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, task} -> task.opts[:path] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:reply, paths, state}
  end

  ## Recent Projects Handlers

  @impl true
  def handle_call({:add_recent_project, path, name}, _from, state) do
    now = DateTime.utc_now()

    # Remove existing entry for this path (if any), then add updated entry
    :ets.delete(@recent_projects_table, path)
    :ets.insert(@recent_projects_table, {path, %{path: path, name: name, last_opened_at: now}})

    # Enforce max limit
    trim_recent_projects()
    save_recent_projects_to_dets()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_recent_projects, _from, state) do
    projects =
      :ets.tab2list(@recent_projects_table)
      |> Enum.map(fn {_path, project} -> project end)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    {:reply, projects, state}
  end

  @impl true
  def handle_call({:remove_recent_project, path}, _from, state) do
    :ets.delete(@recent_projects_table, path)
    save_recent_projects_to_dets()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result}, state) do
    case :ets.lookup(@table_name, task_id) do
      [{^task_id, %TaskInfo{} = task}] ->
        updated = %{task | status: status, result: result, finished_at: DateTime.utc_now()}
        :ets.insert(@table_name, {task_id, updated})

        if status in [:completed, :failed, :cancelled] do
          persist_tasks_to_dets()
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:append_log, task_id, log_entry}, state) do
    case :ets.lookup(@table_name, task_id) do
      [{^task_id, %TaskInfo{logs: logs} = task}] ->
        updated = %{task | logs: [log_entry | logs]}
        :ets.insert(@table_name, {task_id, updated})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    :ets.delete(@table_name, task_id)
    persist_tasks_to_dets()
    {:noreply, state}
  end

  ## Public Task Functions

  @doc """
  Execute a task. This function runs in a separate process under Task.Supervisor.
  """
  def execute_task(:genesis, opts, task_id) do
    {input_arg, runtime_opts} = build_common_runtime_opts(opts, task_id)
    prompt = Keyword.get(opts, :prompt, input_arg)
    EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
  end

  def execute_task(:evolve, opts, task_id) do
    {input_arg, runtime_opts} = build_common_runtime_opts(opts, task_id)
    objective = Keyword.get(opts, :objective, input_arg)
    EvoGit.Runtime.Evolution.run(objective, runtime_opts)
  end

  ## Private Functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp data_dir do
    EvoGit.Platform.data_dir()
  end

  defp tasks_dets_path, do: Path.join(data_dir(), "tasks.dets")
  defp recent_projects_dets_path, do: Path.join(data_dir(), "recent_projects.dets")

  # --- DETS Corruption Recovery ---

  defp open_or_reset_dets(table_name, file_path) do
    case :dets.open_file(table_name, type: :set, file: to_charlist(file_path)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to open DETS file #{file_path}: #{inspect(reason)}. Recreating."
        )

        _ = File.rm(file_path)
        {:ok, _} = :dets.open_file(table_name, type: :set, file: to_charlist(file_path))
        :ok
    end
  end

  defp reset_dets_table(table_name, file_path) do
    :dets.close(table_name)
    _ = File.rm(file_path)
    {:ok, _} = :dets.open_file(table_name, type: :set, file: to_charlist(file_path))
    :ok
  end

  # --- Task Persistence (DETS) ---

  defp load_tasks_from_dets do
    try do
      :dets.foldl(
        fn
          {_key, %TaskInfo{} = task}, acc ->
            # Reset non-persistable fields
            task = %{task | ref: nil, status: maybe_reset_status(task.status)}
            :ets.insert(@table_name, {task.id, task})
            acc

          _other, acc ->
            acc
        end,
        :ok,
        @dets_tasks
      )
    rescue
      error ->
        Logger.error(
          "Failed to load tasks from DETS: #{inspect(error)}. " <>
            "Resetting corrupted tasks store."
        )

        reset_dets_table(@dets_tasks, tasks_dets_path())
        :ok
    end
  end

  defp maybe_reset_status(:running), do: :pending
  defp maybe_reset_status(:pending), do: :pending
  defp maybe_reset_status(status), do: status

  defp persist_tasks_to_dets do
    try do
      all_tasks =
        :ets.tab2list(@table_name)
        |> Enum.map(fn {_id, task} -> task end)

      running_tasks = Enum.filter(all_tasks, &(&1.status in [:pending, :running]))

      finished_tasks =
        all_tasks
        |> Enum.reject(&(&1.status in [:pending, :running]))
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
        |> Enum.take(@max_persisted_tasks)

      tasks_to_save = running_tasks ++ finished_tasks

      # Clear existing DETS data and write new data
      :dets.delete_all_objects(@dets_tasks)

      for task <- tasks_to_save do
        # Drop non-serializable ref field before persisting
        persistable = %{task | ref: nil}
        :dets.insert(@dets_tasks, {task.id, persistable})
      end

      :dets.sync(@dets_tasks)

      :ok
    rescue
      error ->
        Logger.error("Failed to persist tasks: #{inspect(error)}")
        :ok
    end
  end

  # --- Recent Projects (DETS) ---

  defp load_recent_projects_from_dets do
    try do
      :dets.foldl(
        fn
          {_path, %{last_opened_at: %DateTime{}} = project}, acc ->
            :ets.insert(@recent_projects_table, {project.path, project})
            acc

          _other, acc ->
            acc
        end,
        :ok,
        @dets_projects
      )
    rescue
      error ->
        Logger.error(
          "Failed to load recent projects from DETS: #{inspect(error)}. " <>
            "Resetting corrupted projects store."
        )

        reset_dets_table(@dets_projects, recent_projects_dets_path())
        :ok
    end
  end

  defp save_recent_projects_to_dets do
    try do
      projects =
        :ets.tab2list(@recent_projects_table)
        |> Enum.map(fn {_path, project} -> project end)
        |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})
        |> Enum.take(@max_recent_projects)

      # Clear existing DETS data and write new data
      :dets.delete_all_objects(@dets_projects)

      for project <- projects do
        :dets.insert(@dets_projects, {project.path, project})
      end

      :dets.sync(@dets_projects)

      :ok
    rescue
      error ->
        Logger.error("Failed to save recent projects to DETS: #{inspect(error)}")
        :ok
    end
  end

  defp trim_recent_projects do
    projects =
      :ets.tab2list(@recent_projects_table)
      |> Enum.map(fn {_path, project} -> project end)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    case Enum.split(projects, @max_recent_projects) do
      {_kept, []} ->
        :ok

      {_kept, to_remove} ->
        for project <- to_remove do
          :ets.delete(@recent_projects_table, project.path)
        end
    end
  end

  # --- Task Execution Helpers ---

  defp build_common_runtime_opts(opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    mode = Keyword.get(opts, :mode, "simple")
    concurrency = Keyword.fetch!(opts, :concurrency)
    retries = Keyword.fetch!(opts, :retries)
    agent_max_retries = Keyword.fetch!(opts, :agent_max_retries)

    Application.ensure_all_started(:evo_git)

    EvoGit.AgentScheduler.update_config(
      max_concurrency: concurrency,
      agent_max_retries: agent_max_retries
    )

    runtime_opts = [
      repo_path: repo_path,
      mode: String.to_atom(mode),
      concurrency: concurrency,
      retries: retries,
      agent_max_retries: agent_max_retries,
      event_sink: {EvoDash.TaskRegistry, :update_task_log, [task_id]}
    ]

    {nil, runtime_opts}
  end

  ## GenServer Info Handlers

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    task_id =
      case :ets.tab2list(@table_name)
           |> Enum.find(fn {_id, task} ->
             match?(%TaskInfo{ref: %{ref: ^ref}}, task)
           end) do
        {id, _task} -> id
        nil -> nil
      end

    if task_id do
      status =
        case result do
          {:ok, _} -> :completed
          {:error, _} -> :failed
          {:exit, _} -> :failed
          _ -> :failed
        end

      update_task_status(task_id, status, result)
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
