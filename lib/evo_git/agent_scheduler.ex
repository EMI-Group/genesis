defmodule EvoGit.AgentScheduler do
  @moduledoc """
  Global agent scheduler managing agent lifecycles and worktree assignments.

  The scheduler is the single owner of worktree lifecycle. Callers provide a
  structured agent specification — spatial state (ContextNode), temporal state
  (PhyloGraphNode), agent module, and objective — and the scheduler handles:

  - Managing the worktree pool (creation, assignment, reclamation)
  - Preparing worktrees (Git clean/checkout) before agent execution
  - Storing all agent records in ETS so both agent processes and the scheduler
    can access them
  - Spawning and tracking agents (both top-level and sub-agents)
  - Transitioning agents between :running and :waiting states
  - Lazy reclamation of worktrees from waiting agents when the pool is exhausted

  ## ETS Agent Record

  Each agent record in the `:evogit_agent_state` ETS table contains both
  scheduler metadata (id, depth, status, worktree, task_ref, from, etc.) and
  core state (context_node, phylo_node). The agent process reads its
  `context_node` and `phylo_node` from ETS at the start of **every turn**,
  ensuring it always sees the correct worktree path even after being
  rescheduled to a different worktree.
  """

  use GenServer
  require Logger
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentSpec
  alias EvoGit.Core.PhyloGraphNode

  @default_max_depth 5
  @ets_table :evogit_agent_state

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Spawns a top-level agent. Blocks the caller until the agent completes.

  Accepts an `%AgentSpec{}` struct containing the spatial state (ContextNode),
  temporal state (PhyloGraphNode), agent module, objective, and options.

  The scheduler handles worktree preparation (clean + checkout) and stores
  the agent's full record in ETS for the agent process to read.
  """
  @spec run_agent(AgentSpec.t(), timeout()) :: term()
  def run_agent(%AgentSpec{} = spec, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:run_agent, spec}, timeout)
  end

  @doc """
  Called from within a running agent to spawn sub-agents concurrently.
  Marks the calling agent as :waiting (worktree becomes reclaimable).
  Blocks until all sub-agents complete. Returns a list of results in the
  same order as the input specs.

  Returns `{:error, :max_depth_exceeded}` if the calling agent has reached
  the maximum recursion depth and cannot spawn further sub-agents.

  Each spec must be an `%AgentSpec{}` struct.
  """
  @spec spawn_sub_agents([AgentSpec.t()], timeout()) :: [term()] | {:error, :max_depth_exceeded}
  def spawn_sub_agents(specs, timeout \\ :infinity) do
    parent_id = current_agent_id()

    unless parent_id do
      raise "spawn_sub_agents/2 must be called from within a scheduled agent"
    end

    GenServer.call(__MODULE__, {:spawn_sub_agents, parent_id, specs}, timeout)
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

  @doc """
  Reads the full agent record from ETS for the given agent_id.
  """
  def get_agent(agent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, agent}] -> {:ok, agent}
      [] -> :error
    end
  end

  @doc """
  Reads the full agent record from ETS for the calling process's agent.
  """
  def get_current_agent do
    case current_agent_id() do
      nil -> :error
      id -> get_agent(id)
    end
  end

  @doc """
  Updates the phylo_node for the given agent in ETS.
  Called by agents after they commit changes to keep the scheduler in sync.
  """
  def update_phylo_node(agent_id, %PhyloGraphNode{} = phylo_node) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, agent}] ->
        :ets.insert(@ets_table, {agent_id, %{agent | phylo_node: phylo_node}})
        :ok

      [] ->
        :error
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])

    max_concurrency =
      Keyword.get(opts, :max_concurrency) || Application.get_env(:evo_git, :max_concurrency, 3)

    max_retries =
      Keyword.get(opts, :max_retries) || Application.get_env(:evo_git, :max_retries, 3)

    max_depth =
      Keyword.get(opts, :max_depth) ||
        Application.get_env(:evo_git, :max_agent_depth, @default_max_depth)

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
       ref_to_agent: %{},
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:run_agent, spec}, from, state) do
    state = ensure_initialized(state)
    {agent_id, state} = register_agent(state, spec, from, _parent_id = nil, _depth = 0)
    state = try_dispatch(state, agent_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:spawn_sub_agents, parent_id, specs}, from, state) do
    state = ensure_initialized(state)
    {:ok, parent} = get_agent(parent_id)

    if parent.depth >= state.max_depth do
      Logger.warning(
        "AgentScheduler: Rejecting spawn_sub_agents from agent #{parent_id} " <>
          "(depth #{parent.depth} >= max #{state.max_depth})"
      )

      {:reply, {:error, :max_depth_exceeded}, state}
    else
      # Mark parent as :waiting
      put_agent(parent_id, %{parent | status: :waiting})

      # Register each sub-agent (depth = parent.depth + 1)
      {sub_ids, state} =
        Enum.map_reduce(specs, state, fn spec, acc ->
          {id, acc} = register_agent(acc, spec, _from = nil, parent_id, parent.depth + 1)
          {id, acc}
        end)

      # Track pending sub-agents on the parent
      {:ok, parent} = get_agent(parent_id)

      put_agent(parent_id, %{
        parent
        | sub_agent_from: from,
          pending_sub_agents: MapSet.new(sub_ids),
          sub_agent_results: %{}
      })

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
        {:ok, agent} = get_agent(agent_id)
        put_agent(agent_id, %{agent | result_sent: true})

        if agent.parent_id do
          store_sub_result(agent.parent_id, agent_id, result)
          state = maybe_resume_parent(state, agent.parent_id)
          {:noreply, state}
        else
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
        {:ok, agent} = get_agent(agent_id)

        if reason == :normal or agent.result_sent do
          state = recycle_agent(state, agent_id)
          state = process_queue(state)
          {:noreply, state}
        else
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

  # --- ETS Helpers ---

  defp put_agent(agent_id, agent) do
    :ets.insert(@ets_table, {agent_id, agent})
  end

  defp delete_agent(agent_id) do
    :ets.delete(@ets_table, agent_id)
  end

  defp find_waiting_agent_with_worktree do
    match_spec = [
      {{:"$1", %{status: :waiting, worktree: :"$2"}}, [{:"/=", :"$2", nil}], [{{:"$1", :"$2"}}]}
    ]

    case :ets.select(@ets_table, match_spec, 1) do
      {[{agent_id, worktree}], _cont} -> {agent_id, worktree}
      :"$end_of_table" -> nil
    end
  end

  # --- Agent Registry ---

  defp register_agent(state, spec, from, parent_id, depth) do
    id = state.next_agent_id

    agent = %{
      id: id,
      depth: depth,
      status: :pending,
      worktree: nil,
      task_ref: nil,
      from: from,
      parent_id: parent_id,
      spec: spec,
      retries: 0,
      result_sent: false,
      # Sub-agent tracking (used when this agent is a parent)
      sub_agent_from: nil,
      pending_sub_agents: MapSet.new(),
      sub_agent_results: %{},
      # Core state (populated on dispatch)
      context_node: spec.context_node,
      phylo_node: nil
    }

    put_agent(id, agent)
    state = %{state | next_agent_id: id + 1}
    {id, state}
  end

  # --- Dispatch ---

  defp try_dispatch(%{available_worktrees: [wt | rest]} = state, agent_id) do
    {:ok, agent} = get_agent(agent_id)
    retries = agent.retries
    spec = agent.spec

    # Prepare the worktree: clean and checkout to the agent's temporal state
    commit_sha = spec.phylo_node.current_commit
    Git.clean(wt)
    Git.checkout(wt, commit_sha)

    # Build the worktree-bound phylo_node (repo points to worktree, not original)
    wt_phylo_node = %PhyloGraphNode{
      repo: wt,
      base_commit: spec.phylo_node.base_commit,
      current_commit: spec.phylo_node.current_commit
    }

    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, agent.depth)

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        end

        caller_pid =
          case spec.opts do
            opts when is_list(opts) -> Keyword.get(opts, :caller_pid, self())
            opts when is_map(opts) -> Map.get(opts, :caller_pid, self())
            _ -> self()
          end

        spec.agent_module.run(spec.objective, caller_pid)
      end)

    # Update agent record in ETS with worktree assignment and core state
    put_agent(agent_id, %{
      agent
      | status: :running,
        worktree: wt,
        task_ref: task.ref,
        phylo_node: wt_phylo_node
    })

    %{
      state
      | available_worktrees: rest,
        ref_to_agent: Map.put(state.ref_to_agent, task.ref, agent_id)
    }
  end

  defp try_dispatch(%{available_worktrees: []} = state, agent_id) do
    case find_reclaimable_worktree(state) do
      {:ok, worktree, state} ->
        state = %{state | available_worktrees: [worktree]}
        try_dispatch(state, agent_id)

      :none ->
        %{state | queue: :queue.in(agent_id, state.queue)}
    end
  end

  defp find_reclaimable_worktree(state) do
    case find_waiting_agent_with_worktree() do
      {donor_id, worktree} ->
        Logger.info(
          "AgentScheduler: Reclaiming worktree #{worktree} from waiting agent #{donor_id}"
        )

        {:ok, donor} = get_agent(donor_id)
        put_agent(donor_id, %{donor | worktree: nil})
        {:ok, worktree, state}

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

  defp store_sub_result(parent_id, sub_id, result) do
    {:ok, parent} = get_agent(parent_id)
    results = Map.put(parent.sub_agent_results, sub_id, result)
    put_agent(parent_id, %{parent | sub_agent_results: results})
  end

  defp maybe_resume_parent(state, parent_id) do
    {:ok, parent} = get_agent(parent_id)
    pending = parent.pending_sub_agents

    all_done? =
      Enum.all?(pending, fn sub_id ->
        Map.has_key?(parent.sub_agent_results, sub_id)
      end)

    if all_done? do
      ordered_ids = pending |> MapSet.to_list() |> Enum.sort()
      results = Enum.map(ordered_ids, &parent.sub_agent_results[&1])

      GenServer.reply(parent.sub_agent_from, results)

      put_agent(parent_id, %{
        parent
        | status: :running,
          sub_agent_from: nil,
          pending_sub_agents: MapSet.new(),
          sub_agent_results: %{}
      })

      state
    else
      state
    end
  end

  # --- Agent Lifecycle ---

  defp recycle_agent(state, agent_id) do
    {:ok, agent} = get_agent(agent_id)

    state =
      if agent.worktree do
        reset_worktree(agent.worktree, state.repo_root, state.base_sha)
        %{state | available_worktrees: [agent.worktree | state.available_worktrees]}
      else
        state
      end

    delete_agent(agent_id)
    state
  end

  defp handle_agent_crash(state, agent_id, reason) do
    {:ok, agent} = get_agent(agent_id)

    Logger.error(
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{agent.retries}/#{state.max_retries}"
    )

    if agent.worktree do
      reset_worktree(agent.worktree, state.repo_root, state.base_sha)
    end

    if agent.retries < state.max_retries do
      state =
        if agent.worktree do
          %{state | available_worktrees: [agent.worktree | state.available_worktrees]}
        else
          state
        end

      put_agent(agent_id, %{
        agent
        | retries: agent.retries + 1,
          worktree: nil,
          task_ref: nil,
          phylo_node: nil
      })

      state = try_dispatch(state, agent_id)
      state = process_queue(state)
      {:noreply, state}
    else
      msg =
        "Agent #{agent_id} failed after #{state.max_retries} retries. Last: #{inspect(reason)}"

      Logger.error("AgentScheduler: #{msg}")

      state =
        if agent.worktree do
          %{state | available_worktrees: [agent.worktree | state.available_worktrees]}
        else
          state
        end

      delete_agent(agent_id)

      if agent.parent_id do
        store_sub_result(agent.parent_id, agent_id, {:error, :max_retries_exceeded})
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
