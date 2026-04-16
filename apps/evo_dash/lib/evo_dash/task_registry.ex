defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and tracked in-memory via ETS.
  """
  use GenServer

  @table_name :evo_dash_tasks

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

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for in-memory task tracking
    :ets.new(@table_name, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_task, task_id, task_type, opts}, _from, state) do
    # Start the task in a separate process
    task_pid = start_task_process(task_id, task_type, opts)

    task = %{
      id: task_id,
      type: task_type,
      status: :running,
      opts: opts,
      pid: task_pid,
      started_at: DateTime.utc_now(),
      logs: [],
      result: nil
    }

    :ets.insert(@table_name, {task_id, task})
    {:reply, {:ok, task}, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task = case :ets.lookup(@table_name, task_id) do
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
    result = case :ets.lookup(@table_name, task_id) do
      [{^task_id, %{status: :running, pid: pid} = task}] ->
        if Process.alive?(pid) do
          Process.exit(pid, :cancelled)
          updated = %{task | status: :cancelled, finished_at: DateTime.utc_now()}
          :ets.insert(@table_name, {task_id, updated})
          :ok
        else
          {:error, :not_running}
        end
      [{^task_id, _}] ->
        {:error, :not_running}
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result}, state) do
    case :ets.lookup(@table_name, task_id) do
      [{^task_id, task}] ->
        updated = task
          |> Map.put(:status, status)
          |> Map.put(:result, result)
          |> Map.put(:finished_at, DateTime.utc_now())
        :ets.insert(@table_name, {task_id, updated})
      _ -> :ok
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast({:append_log, task_id, log_entry}, state) do
    case :ets.lookup(@table_name, task_id) do
      [{^task_id, task}] ->
        updated = update_in(task.logs, fn logs -> [log_entry | logs] end)
        :ets.insert(@table_name, {task_id, updated})
      _ -> :ok
    end
    {:noreply, state}
  end

  ## Private Functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp start_task_process(task_id, task_type, opts) do
    parent = self()

    spawn_link(fn ->
      result = execute_task(task_type, opts, parent, task_id)
      send(parent, {:task_complete, task_id, result})
    end)
  end

  defp execute_task(:genesis, opts, _parent, task_id) do
    repo_path = Keyword.get(opts, :path, File.cwd!())
    prompt = Keyword.get(opts, :prompt, "")
    mode = Keyword.get(opts, :mode, :new)

    # Ensure evo_git app is started
    Application.ensure_all_started(:evo_git)

    runtime_opts = [
      repo_path: repo_path,
      mode: String.to_atom(mode),
      event_sink: {EvoDash.TaskRegistry, :update_task_log, [task_id]}
    ]

    try do
      result = EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
      {:ok, result}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  defp execute_task(:evolve, opts, _parent, task_id) do
    repo_path = Keyword.get(opts, :path, File.cwd!())
    objective = Keyword.get(opts, :objective, "")
    mode = Keyword.get(opts, :mode, "simple")

    Application.ensure_all_started(:evo_git)

    runtime_opts = [
      repo_path: repo_path,
      mode: String.to_atom(mode),
      event_sink: {EvoDash.TaskRegistry, :update_task_log, [task_id]}
    ]

    try do
      result = EvoGit.Runtime.Evolution.run(objective, runtime_opts)
      {:ok, result}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  @impl true
  def handle_info({:task_complete, task_id, result}, state) do
    status = case result do
      {:ok, _} -> :completed
      {:error, _} -> :failed
      _ -> :failed
    end
    update_task_status(task_id, status, result)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
