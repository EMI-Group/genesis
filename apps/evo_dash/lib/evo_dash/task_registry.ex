defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and tracked in-memory via ETS.
  """
  use GenServer

  @table_name :evo_dash_tasks

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

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for in-memory task tracking
    :ets.new(@table_name, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_task, task_id, task_type, opts}, _from, state) do
    # Start the task under the Task.Supervisor
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
  def handle_cast({:update_status, task_id, status, result}, state) do
    case :ets.lookup(@table_name, task_id) do
      [{^task_id, %TaskInfo{} = task}] ->
        updated = %{task | status: status, result: result, finished_at: DateTime.utc_now()}
        :ets.insert(@table_name, {task_id, updated})

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

  ## Public Task Functions

  @doc """
  Execute a task. This function runs in a separate process under Task.Supervisor.
  """
  def execute_task(:genesis, opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    prompt = Keyword.get(opts, :prompt, "")
    mode = Keyword.get(opts, :mode, :new)
    concurrency = Keyword.fetch!(opts, :concurrency)
    retries = Keyword.fetch!(opts, :retries)
    agent_max_retries = Keyword.fetch!(opts, :agent_max_retries)

    # Ensure evo_git app is started
    Application.ensure_all_started(:evo_git)

    # Update scheduler config at runtime (no restart needed)
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

    EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
  end

  def execute_task(:evolve, opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    objective = Keyword.get(opts, :objective, "")
    mode = Keyword.get(opts, :mode, "simple")
    concurrency = Keyword.fetch!(opts, :concurrency)
    retries = Keyword.fetch!(opts, :retries)
    agent_max_retries = Keyword.fetch!(opts, :agent_max_retries)

    Application.ensure_all_started(:evo_git)

    # Update scheduler config at runtime (no restart needed)
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

    EvoGit.Runtime.Evolution.run(objective, runtime_opts)
  end

  ## Private Functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Find the task with this ref
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

    # Clean up the demonitor (Task async_nolink doesn't auto-demonitor on reply)
    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task process exited - handle unexpected failures
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
