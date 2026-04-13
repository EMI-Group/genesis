defmodule EvoGit.AgentScheduler do
  @moduledoc """
  Global agent scheduler managing agent lifecycles and worktree assignments.

  Agents are first-class entities tracked by the scheduler. The scheduler is
  responsible for:
  - Managing the worktree pool (creation, assignment, reclamation)
  - Spawning and tracking agents (both top-level and sub-agents)
  - Transitioning agents between :running and :waiting states
  - Lazy reclamation of worktrees from waiting agents when the pool is exhausted
  """

  use GenServer
  require Logger
  alias EvoGit.Adapters.Git

  @default_max_depth 5

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Spawns a top-level agent. Blocks the caller until the agent completes.
  The function receives the assigned worktree path and must return a result.
  """
  def run_agent(fun, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:run_agent, fun}, timeout)
  end

  @doc """
  Called from within a running agent to spawn sub-agents concurrently.
  Marks the calling agent as :waiting (worktree becomes reclaimable).
  Blocks until all sub-agents complete. Returns a list of results in the
  same order as the input functions.

  Returns `{:error, :max_depth_exceeded}` if the calling agent has reached
  the maximum recursion depth and cannot spawn further sub-agents.

  Each function in `funs` receives a worktree path.
  """
  def spawn_sub_agents(funs, timeout \\ :infinity) do
    parent_id = current_agent_id()

    unless parent_id do
      raise "spawn_sub_agents/2 must be called from within a scheduled agent"
    end

    GenServer.call(__MODULE__, {:spawn_sub_agents, parent_id, funs}, timeout)
  end

  @doc """
  Returns the current agent's scheduler-assigned ID, or nil if not in a scheduled agent.
  """
  def current_agent_id do
    Process.get(:evogit_agent_id)
  end

  @doc """
  Returns the current agent's call depth, or 0 if not in a scheduled agent.
  """
  def current_depth do
    Process.get(:evogit_agent_depth, 0)
  end

  @doc """
  Returns the configured maximum agent recursion depth.
  """
  def max_depth do
    Application.get_env(:evo_git, :max_agent_depth, @default_max_depth)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency) || Application.get_env(:evo_git, :max_concurrency, 3)

    max_retries =
      Keyword.get(opts, :max_retries) || Application.get_env(:evo_git, :max_retries, 3)

    max_depth =
      Keyword.get(opts, :max_depth) || Application.get_env(:evo_git, :max_agent_depth, @default_max_depth)

    {:ok,
     %{
       initialized: false,
       repo_root: nil,
       base_sha: nil,
       max_concurrency: max_concurrency,
       max_retries: max_retries,
       max_depth: max_depth,
       next_agent_id: 1,
       available_worktrees: [],
       agents: %{},
       ref_to_agent: %{},
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:run_agent, fun}, from, state) do
    state = ensure_initialized(state)
    {agent_id, state} = register_agent(state, fun, from, _parent_id = nil, _depth = 0)
    state = try_dispatch(state, agent_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:spawn_sub_agents, parent_id, funs}, from, state) do
    state = ensure_initialized(state)
    parent = state.agents[parent_id]

    # Enforce recursion depth limit
    if parent.depth >= state.max_depth do
      Logger.warning(
        "AgentScheduler: Rejecting spawn_sub_agents from agent #{parent_id} " <>
          "(depth #{parent.depth} >= max #{state.max_depth})"
      )

      {:reply, {:error, :max_depth_exceeded}, state}
    else
      # Mark parent as :waiting
      state = update_agent(state, parent_id, :waiting)

      # Register each sub-agent (depth = parent.depth + 1)
      {sub_ids, state} =
        Enum.map_reduce(funs, state, fn fun, acc ->
          {id, acc} = register_agent(acc, fun, _from = nil, parent_id, parent.depth + 1)
          {id, acc}
        end)

      # Track pending sub-agents on the parent
      parent = state.agents[parent_id]

      parent = %{
        parent
        | sub_agent_from: from,
          pending_sub_agents: MapSet.new(sub_ids),
          sub_agent_results: %{}
      }

      state = put_in(state.agents[parent_id], parent)

      # Dispatch all sub-agents
      state = Enum.reduce(sub_ids, state, &try_dispatch(&2, &1))

      {:noreply, state}
    end
  end

  # Task returned a result
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.get(state.ref_to_agent, ref) do
      nil ->
        {:noreply, state}

      agent_id ->
        agent = state.agents[agent_id]
        state = put_in(state.agents[agent_id].result_sent, true)

        if agent.parent_id do
          # Sub-agent completed: store result, check parent
          state = store_sub_result(state, agent.parent_id, agent_id, result)
          state = maybe_resume_parent(state, agent.parent_id)
          {:noreply, state}
        else
          # Top-level agent completed: reply to original caller
          GenServer.reply(agent.from, result)
          {:noreply, state}
        end
    end
  end

  # Task process exited
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.ref_to_agent, ref) do
      {nil, _} ->
        {:noreply, state}

      {agent_id, ref_to_agent} ->
        state = %{state | ref_to_agent: ref_to_agent}
        agent = state.agents[agent_id]

        if reason == :normal or agent.result_sent do
          # Clean exit: return worktree to pool, process queue
          state = recycle_agent(state, agent_id)
          state = process_queue(state)
          {:noreply, state}
        else
          # Crash: retry or fail
          handle_agent_crash(state, agent_id, reason)
        end
    end
  end

  # --- Initialization ---

  defp ensure_initialized(%{initialized: true} = state), do: state

  defp ensure_initialized(state) do
    repo_root = Application.get_env(:evo_git, :repo_path, File.cwd!()) |> Path.expand()
    worker_base = Path.join(repo_root, ".evogit/workers")
    max_concurrency = state.max_concurrency

    Logger.info(
      "AgentScheduler: Initializing with #{max_concurrency} worktrees at #{worker_base}"
    )

    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)
    File.mkdir_p!(worker_base)

    {:ok, current_sha} = Git.rev_parse(repo_root)

    worktrees =
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

    %{
      state
      | initialized: true,
        available_worktrees: worktrees,
        repo_root: repo_root,
        base_sha: current_sha
    }
  end

  # --- Agent Registry ---

  defp register_agent(state, fun, from, parent_id, depth) do
    id = state.next_agent_id

    agent = %{
      id: id,
      depth: depth,
      status: :pending,
      worktree: nil,
      task_ref: nil,
      from: from,
      parent_id: parent_id,
      fun: fun,
      retries: 0,
      result_sent: false,
      # Sub-agent tracking (used when this agent is a parent)
      sub_agent_from: nil,
      pending_sub_agents: MapSet.new(),
      sub_agent_results: %{}
    }

    state = %{state | next_agent_id: id + 1, agents: Map.put(state.agents, id, agent)}
    {id, state}
  end

  # --- Dispatch ---

  defp try_dispatch(%{available_worktrees: [wt | rest]} = state, agent_id) do
    agent = state.agents[agent_id]
    retries = agent.retries

    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, agent.depth)

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        end

        agent.fun.(wt)
      end)

    agent = %{agent | status: :running, worktree: wt, task_ref: task.ref}

    %{
      state
      | available_worktrees: rest,
        agents: Map.put(state.agents, agent_id, agent),
        ref_to_agent: Map.put(state.ref_to_agent, task.ref, agent_id)
    }
  end

  defp try_dispatch(%{available_worktrees: []} = state, agent_id) do
    # Try to reclaim a worktree from a waiting agent
    case find_reclaimable_worktree(state) do
      {:ok, worktree, state} ->
        state = %{state | available_worktrees: [worktree]}
        try_dispatch(state, agent_id)

      :none ->
        # No worktrees available, queue the agent
        %{state | queue: :queue.in(agent_id, state.queue)}
    end
  end

  defp find_reclaimable_worktree(state) do
    waiting_with_wt =
      state.agents
      |> Enum.find(fn {_id, agent} ->
        agent.status == :waiting and agent.worktree != nil
      end)

    case waiting_with_wt do
      {donor_id, donor} ->
        Logger.info(
          "AgentScheduler: Reclaiming worktree #{donor.worktree} from waiting agent #{donor_id}"
        )

        state = put_in(state.agents[donor_id].worktree, nil)
        {:ok, donor.worktree, state}

      nil ->
        :none
    end
  end

  # --- Queue Processing ---

  defp process_queue(%{queue: queue, available_worktrees: [_ | _]} = state) do
    case :queue.out(queue) do
      {{:value, agent_id}, new_queue} ->
        state = %{state | queue: new_queue}
        state = try_dispatch(state, agent_id)
        process_queue(state)

      {:empty, _} ->
        state
    end
  end

  defp process_queue(state), do: state

  # --- Sub-Agent Result Tracking ---

  defp store_sub_result(state, parent_id, sub_id, result) do
    parent = state.agents[parent_id]
    results = Map.put(parent.sub_agent_results, sub_id, result)
    put_in(state.agents[parent_id].sub_agent_results, results)
  end

  defp maybe_resume_parent(state, parent_id) do
    parent = state.agents[parent_id]
    pending = parent.pending_sub_agents

    # Check if all sub-agents have results
    all_done? =
      Enum.all?(pending, fn sub_id ->
        Map.has_key?(parent.sub_agent_results, sub_id)
      end)

    if all_done? do
      # Collect results in original order (sub_ids are sequential)
      ordered_ids = pending |> MapSet.to_list() |> Enum.sort()
      results = Enum.map(ordered_ids, &parent.sub_agent_results[&1])

      # Reply to the parent's spawn_sub_agents call
      GenServer.reply(parent.sub_agent_from, results)

      # Reset parent state
      parent = %{
        parent
        | status: :running,
          sub_agent_from: nil,
          pending_sub_agents: MapSet.new(),
          sub_agent_results: %{}
      }

      put_in(state.agents[parent_id], parent)
    else
      state
    end
  end

  # --- Agent Lifecycle ---

  defp update_agent(state, agent_id, new_status) do
    put_in(state.agents[agent_id].status, new_status)
  end

  defp recycle_agent(state, agent_id) do
    agent = state.agents[agent_id]

    state =
      if agent.worktree do
        reset_worktree(agent.worktree, state.repo_root, state.base_sha)
        %{state | available_worktrees: [agent.worktree | state.available_worktrees]}
      else
        state
      end

    %{state | agents: Map.delete(state.agents, agent_id)}
  end

  defp handle_agent_crash(state, agent_id, reason) do
    agent = state.agents[agent_id]

    Logger.error(
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{agent.retries}/#{state.max_retries}"
    )

    # Reset worktree
    if agent.worktree do
      reset_worktree(agent.worktree, state.repo_root, state.base_sha)
    end

    if agent.retries < state.max_retries do
      # Return worktree, increment retries, re-queue
      state =
        if agent.worktree do
          %{state | available_worktrees: [agent.worktree | state.available_worktrees]}
        else
          state
        end

      agent = %{agent | retries: agent.retries + 1, worktree: nil, task_ref: nil}
      state = put_in(state.agents[agent_id], agent)
      state = try_dispatch(state, agent_id)
      state = process_queue(state)
      {:noreply, state}
    else
      msg =
        "Agent #{agent_id} failed after #{state.max_retries} retries. Last: #{inspect(reason)}"

      Logger.error("AgentScheduler: #{msg}")

      # Return worktree to pool
      state =
        if agent.worktree do
          %{state | available_worktrees: [agent.worktree | state.available_worktrees]}
        else
          state
        end

      state = %{state | agents: Map.delete(state.agents, agent_id)}

      if agent.parent_id do
        # Sub-agent max retries: store error as result
        state = store_sub_result(state, agent.parent_id, agent_id, {:error, :max_retries_exceeded})
        state = maybe_resume_parent(state, agent.parent_id)
        state = process_queue(state)
        {:noreply, state}
      else
        GenServer.reply(agent.from, {:error, :max_retries_exceeded})
        state = process_queue(state)
        {:noreply, state}
      end
    end
  end

  defp reset_worktree(path, repo_root, base_sha) do
    Logger.info("AgentScheduler: Resetting worktree #{path}")
    File.rm_rf!(path)
    Git.prune_worktrees(repo_root)
    Git.add_worktree(repo_root, path, base_sha)
  end
end
