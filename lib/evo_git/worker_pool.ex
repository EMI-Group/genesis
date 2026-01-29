defmodule EvoGit.WorkerPool do
  use GenServer
  require Logger
  alias EvoGit.Adapters.Git

  @moduledoc """
  Manages a pool of persistent Git worktrees for Gemini agents.
  """

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run(fun, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:run, fun}, timeout)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)
    repo_root = File.cwd!()
    worker_base = Path.join(repo_root, ".evogit/workers")

    Logger.info("Initializing Gemini Pool with #{max_concurrency} workers at #{worker_base}")

    # cleanup old workers
    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)
    File.mkdir_p!(worker_base)

    # Resolve HEAD sha
    {:ok, current_sha} = Git.rev_parse(repo_root)

    workers =
      for i <- 1..max_concurrency do
        path = Path.join(worker_base, "worker_#{i}")

        case Git.add_worktree(repo_root, path, current_sha) do
          {:ok, _} ->
            path

          {:error, _, msg} ->
            Logger.error("Failed to create worktree #{path}: #{msg}")
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    {:ok,
     %{
       workers: workers,
       # ref => path
       active: %{},
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:run, fun}, from, state) do
    dispatch(fun, from, state)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Worker process finished or crashed
    case Map.pop(state.active, ref) do
      {path, new_active} when not is_nil(path) ->
        # Reclaim worker
        # Clean it up slightly (optional but good practice)
        # Git.clean(path)
        # Git.reset_hard(path)

        # We put it back in the pool
        new_state = %{state | active: new_active, workers: [path | state.workers]}
        process_queue(new_state)

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp dispatch(fun, from, %{workers: [path | rest], active: active} = state) do
    {_pid, ref} =
      spawn_monitor(fn ->
        try do
          result = fun.(path)
          GenServer.reply(from, result)
        catch
          kind, reason ->
            Logger.error("Worker crashed: #{inspect(reason)}")
            GenServer.reply(from, {:error, {kind, reason}})
        end
      end)

    new_active = Map.put(active, ref, path)
    {:noreply, %{state | workers: rest, active: new_active}}
  end

  defp dispatch(fun, from, %{workers: [], queue: queue} = state) do
    {:noreply, %{state | queue: :queue.in({fun, from}, queue)}}
  end

  defp process_queue(%{workers: [_path | _], queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, {fun, from}}, new_queue} ->
        dispatch(fun, from, %{state | queue: new_queue})

      {:empty, _} ->
        {:noreply, state}
    end
  end

  defp process_queue(state), do: {:noreply, state}
end
