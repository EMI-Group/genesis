defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and tracked in-memory via ETS.
  Supports persistence of the 10 most recent finished tasks and
  recently opened projects to disk (~/.local/share/evogit/).
  """
  use GenServer

  @table_name :evo_dash_tasks
  @recent_projects_table :evo_dash_recent_projects
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
    :ets.new(@table_name, [:named_table, :public, :set])
    :ets.new(@recent_projects_table, [:named_table, :public, :set])

    # Ensure data directory exists
    File.mkdir_p!(data_dir())

    # Load persisted data from disk
    load_tasks_from_disk()
    load_recent_projects_from_disk()

    {:ok, %{}}
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
            persist_tasks_to_disk()
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
    save_recent_projects_to_disk()

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
    save_recent_projects_to_disk()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result}, state) do
    case :ets.lookup(@table_name, task_id) do
      [{^task_id, %TaskInfo{} = task}] ->
        updated = %{task | status: status, result: result, finished_at: DateTime.utc_now()}
        :ets.insert(@table_name, {task_id, updated})

        if status in [:completed, :failed, :cancelled] do
          persist_tasks_to_disk()
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
    Path.join([System.user_home!(), ".local", "share", "evogit"])
  end

  defp tasks_file, do: Path.join(data_dir(), "tasks.json")
  defp recent_projects_file, do: Path.join(data_dir(), "recent_projects.json")

  # --- Task Persistence ---

  defp load_tasks_from_disk do
    try do
      case File.read(tasks_file()) do
        {:ok, content} ->
          tasks = JSON.decode!(content)
          now = DateTime.utc_now()

          for task_map <- tasks do
            task = deserialize_task(task_map, now)
            :ets.insert(@table_name, {task.id, task})
          end

        {:error, _} ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp persist_tasks_to_disk do
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

      serialized = Enum.map(tasks_to_save, &serialize_task/1)
      File.write!(tasks_file(), JSON.encode!(serialized))
    rescue
      _ -> :ok
    end
  end

  defp serialize_task(%TaskInfo{} = task) do
    task
    |> Map.from_struct()
    |> Map.drop([:ref])
    |> serialize_datetime_field(:started_at)
    |> serialize_datetime_field(:finished_at)
    |> serialize_opts()
  end

  defp serialize_datetime_field(map, field) do
    case Map.get(map, field) do
      %DateTime{} = dt -> Map.put(map, field, DateTime.to_iso8601(dt))
      _ -> map
    end
  end

  defp serialize_opts(%{opts: opts} = map) when is_list(opts) do
    # Convert keyword list to list of [key, value] pairs for JSON compatibility
    serialized =
      Enum.map(opts, fn
        {k, v} when is_atom(k) -> [Atom.to_string(k), serialize_opt_value(v)]
        other -> other
      end)

    Map.put(map, :opts, serialized)
  end

  defp serialize_opts(map), do: map

  defp serialize_opt_value(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_opt_value(v), do: v

  defp deserialize_task(map, now) do
    %TaskInfo{
      id: map["id"],
      type: deserialize_atom(map["type"]),
      status: deserialize_atom(map["status"]) || :pending,
      opts: deserialize_opts(map["opts"]),
      ref: nil,
      started_at: parse_datetime(map["started_at"]) || now,
      finished_at: parse_datetime(map["finished_at"]),
      logs: map["logs"] || [],
      result: nil
    }
  end

  defp deserialize_opts(nil), do: []

  defp deserialize_opts(opts) when is_list(opts) do
    Enum.map(opts, fn
      [k, v] when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
      other -> other
    end)
  end

  defp deserialize_atom(nil), do: nil
  defp deserialize_atom(s) when is_binary(s), do: String.to_atom(s)
  defp deserialize_atom(a) when is_atom(a), do: a

  defp parse_datetime(nil), do: nil

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  # --- Recent Projects ---

  defp load_recent_projects_from_disk do
    try do
      case File.read(recent_projects_file()) do
        {:ok, content} ->
          projects = JSON.decode!(content)

          for project_map <- projects do
            project = %{
              path: project_map["path"],
              name: project_map["name"],
              last_opened_at: parse_datetime(project_map["last_opened_at"]) || DateTime.utc_now()
            }

            :ets.insert(@recent_projects_table, {project.path, project})
          end

        {:error, _} ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp save_recent_projects_to_disk do
    try do
      projects =
        :ets.tab2list(@recent_projects_table)
        |> Enum.map(fn {_path, project} -> project end)
        |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})
        |> Enum.take(@max_recent_projects)
        |> Enum.map(&serialize_recent_project/1)

      File.write!(recent_projects_file(), JSON.encode!(projects))
    rescue
      _ -> :ok
    end
  end

  defp serialize_recent_project(%{path: path, name: name, last_opened_at: dt}) do
    %{
      "path" => path,
      "name" => name,
      "last_opened_at" => DateTime.to_iso8601(dt)
    }
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
