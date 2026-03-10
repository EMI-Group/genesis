defmodule EvoGit.WorkerPool do
  use GenServer
  require Logger
  alias EvoGit.Adapters.Git

  @moduledoc """
  Manages a pool of persistent Git worktrees for evogit agents.
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
    # Lazy initialization: just store config, don't create worktrees yet.
    max_concurrency = Keyword.get(opts, :max_concurrency) || Application.get_env(:evo_git, :max_concurrency, 3)
    max_retries = Keyword.get(opts, :max_retries) || Application.get_env(:evo_git, :max_retries, 3)

    {:ok,
     %{
       initialized: false,
       workers: [],
       active: %{},
       queue: :queue.new(),
       repo_root: nil,
       base_sha: nil,
       max_retries: max_retries,
       max_concurrency: max_concurrency
     }}
  end

  @impl true
  def handle_call({:run, fun}, from, state) do
    state = ensure_initialized(state)
    dispatch(fun, from, 0, state)
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task succeeded and returned a result
    case Map.get(state.active, ref) do
      %{from: from} = meta ->
        GenServer.reply(from, result)
        new_active = Map.put(state.active, ref, %{meta | result_sent: true})
        {:noreply, %{state | active: new_active}}

      nil ->
        # Received message for unknown task (maybe already processed DOWN?)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task finished (normal) or crashed
    case Map.pop(state.active, ref) do
      {meta, new_active} when not is_nil(meta) ->
        %{
          path: path,
          from: from,
          fun: fun,
          retries: retries,
          result_sent: result_sent
        } = meta

        if reason == :normal or result_sent do
          # Success case
          # Return worker to pool
          new_state = %{state | active: new_active, workers: [path | state.workers]}
          process_queue(new_state)
        else
          # Crash case
          Logger.error(
            "Worker crashed on #{path}: #{inspect(reason)}. Retry #{retries}/#{state.max_retries}"
          )

          # 1. Reset Worktree
          reset_worktree(path, state.repo_root, state.base_sha)

          # 2. Retry Logic
          if retries < state.max_retries do
            # Re-queue with incremented retries
            # We treat the reset worker as "available" now.
            new_state = %{state | active: new_active, workers: [path | state.workers]}
            # Add to queue
            queue = :queue.in({fun, from, retries + 1}, state.queue)
            process_queue(%{new_state | queue: queue})
          else
            # Max retries exceeded
            msg =
              "Worker failed after #{state.max_retries} retries. Last reason: #{inspect(reason)}"

            Logger.error(msg)
            # Reply error to caller so they aren't stuck forever?
            # Or crash the program as requested.
            GenServer.reply(from, {:error, :max_retries_exceeded})
            raise RuntimeError, message: msg
          end
        end

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp ensure_initialized(%{initialized: true} = state), do: state

  defp ensure_initialized(state) do
    repo_root = Application.get_env(:evo_git, :repo_path, File.cwd!()) |> Path.expand()
    worker_base = Path.join(repo_root, ".evogit/workers")
    max_concurrency = state.max_concurrency

    Logger.info("Initializing Worker Pool with #{max_concurrency} workers at #{worker_base}")

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

    %{state | initialized: true, workers: workers, repo_root: repo_root, base_sha: current_sha}
  end

  defp dispatch(fun, from, retries, %{workers: [path | rest], active: active} = state) do
    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        if retries > 0 do
          Logger.info("Retrying task on #{path}, attempt #{retries}")
          # Exponential backoff
          Process.sleep(30_000 * retries)
        end

        fun.(path)
      end)

    meta =
      %{
        path: path,
        from: from,
        fun: fun,
        retries: retries,
        result_sent: false
      }

    new_active = Map.put(active, task.ref, meta)
    {:noreply, %{state | workers: rest, active: new_active}}
  end

  defp dispatch(fun, from, retries, %{workers: [], queue: queue} = state) do
    {:noreply, %{state | queue: :queue.in({fun, from, retries}, queue)}}
  end

  defp process_queue(%{workers: [_path | _], queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, {fun, from, retries}}, new_queue} ->
        dispatch(fun, from, retries, %{state | queue: new_queue})

      {:empty, _} ->
        {:noreply, state}
    end
  end

  defp process_queue(state), do: {:noreply, state}

  defp reset_worktree(path, repo_root, base_sha) do
    Logger.info("Resetting worktree #{path}...")
    File.rm_rf!(path)
    # Prune is global, might affect others?
    # git worktree prune removes information about missing worktrees.
    # Since we rm_rf'd it, prune should clean it up.
    Git.prune_worktrees(repo_root)
    Git.add_worktree(repo_root, path, base_sha)
  end
end
