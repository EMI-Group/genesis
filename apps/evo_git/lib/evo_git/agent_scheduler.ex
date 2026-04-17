defmodule EvoGit.AgentScheduler do
  @moduledoc """
  Global agent scheduler managing agent lifecycles and worktree assignments.

  The scheduler is the single owner of worktree lifecycle. Callers provide a
  structured agent specification — spatial state (ContextNode), temporal state
  (PhyloGraphNode), agent module, and objective — and the scheduler handles:

  - Managing the worktree pool (creation, assignment, reclamation)
  - Preparing worktrees (Git clean/checkout) before agent execution
  - Spawning and tracking agents (both top-level and sub-agents)
  - Transitioning agents between :running and :waiting states
  - Lazy reclamation of worktrees from waiting agents when the pool is exhausted

  ## ETS Tables

  Agent data is split across two ETS tables with clear ownership:

  - **`:evogit_agent_state`** — Owned by agent processes. Contains the agent's
    live spatial/temporal state (`context_node`, `phylo_node`) and `event_sink`.
    The scheduler writes initial values on dispatch; agents update `phylo_node`
    after each commit via `update_phylo_node/2`.

  - **`:evogit_sched_meta`** — Owned by the scheduler process. Contains all
    scheduling bookkeeping: status, worktree assignment, task refs, parent/child
    tracking, retry counts, etc. Agents do not write to this table.
  """

  use GenServer
  require Logger
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentSpec
  alias EvoGit.Core.PhyloGraphNode

  @default_max_depth 5
  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta
  @history_table :evogit_agent_history

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Spawns a top-level agent. Blocks the caller until the agent completes.

  Accepts an `%AgentSpec{}` struct containing the spatial state (ContextNode),
  temporal state (PhyloGraphNode), agent module, objective, and options.

  The scheduler handles worktree preparation (clean + checkout) and stores
  the agent's state in ETS for the agent process to read.
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

  Returns `{:error, :path_ignored}` if the calling agent is in a directory
  that is ignored by git (e.g., .venv, node_modules). This prevents infinite
  recursion in large ignored folders.

  Each spec must be an `%AgentSpec{}` struct.
  """
  @spec spawn_sub_agents([AgentSpec.t()], timeout()) ::
          [term()] | {:error, :max_depth_exceeded | :path_ignored}
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
  Reads the agent's live state from the agent state table.
  Called by agent processes every turn.
  """
  @spec get_agent_state(pos_integer()) :: {:ok, AgentState.t()} | :error
  def get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %AgentState{} = agent_state}] -> {:ok, agent_state}
      [] -> :error
    end
  end

  @doc """
  Returns the event_sink pid for the given agent, or nil if not set.
  Agents use this to stream UI events (thoughts, tool calls, etc.).
  """
  def get_event_sink(agent_id) do
    case get_agent_state(agent_id) do
      {:ok, %{event_sink: sink}} -> sink
      _ -> nil
    end
  end

  @doc """
  Updates the phylo_node for the given agent in the agent state table.
  Called by agents after they commit changes to keep state in sync.
  """
  @spec update_phylo_node(pos_integer(), PhyloGraphNode.t()) :: :ok | :error
  def update_phylo_node(agent_id, %PhyloGraphNode{} = phylo_node) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %AgentState{} = agent_state}] ->
        :ets.insert(@agent_table, {agent_id, %AgentState{agent_state | phylo_node: phylo_node}})
        :ok

      [] ->
        :error
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    :ets.new(@agent_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@sched_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@history_table, [:named_table, :public, :bag, read_concurrency: true])

    max_concurrency =
      Keyword.get(opts, :max_concurrency) || Application.get_env(:evo_git, :max_concurrency, 3)

    agent_max_retries =
      Keyword.get(opts, :agent_max_retries) ||
        Application.get_env(:evo_git, :agent_max_retries, 3)

    max_depth =
      Keyword.get(opts, :max_depth) ||
        Application.get_env(:evo_git, :max_agent_depth, @default_max_depth)

    {:ok,
     %{
       initialized: false,
       repo_root: nil,
       base_sha: nil,
       max_concurrency: max_concurrency,
       agent_max_retries: agent_max_retries,
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
    Logger.info("AgentScheduler: Spawning top-level agent #{agent_id}")
    state = try_dispatch(state, agent_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:spawn_sub_agents, parent_id, specs}, from, state) do
    state = ensure_initialized(state)
    {:ok, parent} = get_sched_meta(parent_id)

    # Check if parent is in an ignored folder
    case get_agent_state(parent_id) do
      {:ok, agent_state} when is_struct(agent_state) ->
        if EvoGit.Core.ContextNode.is_ignored?(agent_state.context_node) do
          Logger.warning(
            "AgentScheduler: Rejecting spawn_sub_agents from agent #{parent_id} " <>
              "in ignored path '#{agent_state.context_node.path}'"
          )

          {:reply, {:error, :path_ignored}, state}
        end

      _ ->
        # If we can't get agent state, proceed with spawn (backward compatibility)
        :ok
    end

    if parent.depth >= state.max_depth do
      Logger.warning(
        "AgentScheduler: Rejecting spawn_sub_agents from agent #{parent_id} " <>
          "(depth #{parent.depth} >= max #{state.max_depth})"
      )

      {:reply, {:error, :max_depth_exceeded}, state}
    else
      # Pre-Delegation Cleanliness
      parent = auto_commit_fallback(parent_id, parent)

      # Mark parent as :waiting
      Logger.info(
        "AgentScheduler: Agent #{parent_id} yielding to spawn #{length(specs)} sub-agents"
      )

      put_sched_meta(parent_id, %{parent | status: :waiting})

      # Register each sub-agent (depth = parent.depth + 1)
      {sub_ids, state} =
        Enum.map_reduce(specs, state, fn spec, acc ->
          {id, acc} = register_agent(acc, spec, _from = nil, parent_id, parent.depth + 1)
          {id, acc}
        end)

      # Track pending sub-agents on the parent
      {:ok, parent} = get_sched_meta(parent_id)

      put_sched_meta(parent_id, %{
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
        {:ok, meta} = get_sched_meta(agent_id)

        # Completion Cleanliness
        meta = auto_commit_fallback(agent_id, meta)

        put_sched_meta(agent_id, %{meta | result_sent: true})

        if meta.parent_id do
          store_sub_result(meta.parent_id, agent_id, result)
          state = maybe_resume_parent(state, meta.parent_id)
          {:noreply, state}
        else
          GenServer.reply(meta.from, result)
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
        {:ok, meta} = get_sched_meta(agent_id)

        if reason == :normal or meta.result_sent do
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

  # --- ETS Helpers (Agent State Table) ---

  defp put_agent_state(agent_id, agent_state) do
    :ets.insert(@agent_table, {agent_id, agent_state})
  end

  defp delete_agent_state(agent_id) do
    :ets.delete(@agent_table, agent_id)
  end

  # --- ETS Helpers (Scheduler Metadata Table) ---

  defp get_sched_meta(agent_id) do
    case :ets.lookup(@sched_table, agent_id) do
      [{^agent_id, %SchedMeta{} = meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  defp put_sched_meta(agent_id, meta) do
    :ets.insert(@sched_table, {agent_id, meta})
  end

  defp delete_sched_meta(agent_id) do
    :ets.delete(@sched_table, agent_id)
  end

  # --- ETS Helpers (Agent History Table) ---

  @doc """
  Appends a history entry to the agent's history.
  The history table is a bag to allow multiple entries per agent.
  """
  @spec append_history(pos_integer(), String.t(), map()) :: :ok
  def append_history(agent_id, type, data) do
    entry = %{
      timestamp: System.monotonic_time(:millisecond),
      type: type,
      data: data
    }
    :ets.insert(@history_table, {agent_id, entry})
    :ok
  end

  @doc """
  Retrieves all history entries for a given agent, sorted by timestamp.
  Returns an empty list if no history exists.
  """
  @spec get_history(pos_integer()) :: [map()]
  def get_history(agent_id) do
    case :ets.lookup(@history_table, agent_id) do
      [] -> []
      entries ->
        entries
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.sort_by(& &1.timestamp)
    end
  end

  @doc """
  Clears all history entries for a given agent.
  """
  @spec clear_history(pos_integer()) :: :ok
  def clear_history(agent_id) do
    :ets.delete(@history_table, agent_id)
    :ok
  end

  defp find_waiting_agent_with_worktree do
    # Use a plain map with __struct__ for the ETS match spec — struct literals
    # require all @enforce_keys which doesn't work in match patterns.
    match_spec = [
      {
        {:"$1", %{__struct__: SchedMeta, status: :waiting, worktree: :"$2"}},
        [{:"/=", :"$2", nil}],
        [{{:"$1", :"$2"}}]
      }
    ]

    case :ets.select(@sched_table, match_spec, 1) do
      {[{agent_id, worktree}], _cont} -> {agent_id, worktree}
      :"$end_of_table" -> nil
    end
  end

  # --- Agent Registry ---

  defp register_agent(state, spec, from, parent_id, depth) do
    id = state.next_agent_id

    # Resolve event_sink: explicit in opts, inherited from parent, or nil
    event_sink =
      case spec.opts do
        opts when is_list(opts) -> Keyword.get(opts, :event_sink)
        opts when is_map(opts) -> Map.get(opts, :event_sink)
        _ -> nil
      end

    event_sink =
      if is_nil(event_sink) and parent_id do
        case get_agent_state(parent_id) do
          {:ok, %{event_sink: sink}} -> sink
          _ -> nil
        end
      else
        event_sink
      end

    # Agent state table: live spatial/temporal state for the agent process
    put_agent_state(id, %AgentState{
      context_node: spec.context_node,
      phylo_node: nil,
      event_sink: event_sink
    })

    # Scheduler metadata table: scheduling bookkeeping
    put_sched_meta(id, %SchedMeta{
      id: id,
      depth: depth,
      status: :pending,
      from: from,
      parent_id: parent_id,
      spec: spec
    })

    state = %{state | next_agent_id: id + 1}
    {id, state}
  end

  # --- Dispatch ---

  defp try_dispatch(%{available_worktrees: [wt | rest]} = state, agent_id) do
    {:ok, meta} = get_sched_meta(agent_id)
    retries = meta.retries
    spec = meta.spec

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

    # Log dispatch event for dashboard visibility
    if retries > 0 do
      append_history(agent_id, "RETRY_DISPATCH", %{
        attempt: retries,
        backoff_seconds: 30 * retries,
        worktree: wt
      })
    end

    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, meta.depth)

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        else
          Logger.info("AgentScheduler: Agent #{agent_id} starting execution in worktree #{wt}")
        end

        spec.agent_module.run(spec.objective)
      end)

    # Update agent state with worktree-bound phylo_node
    {:ok, agent_state} = get_agent_state(agent_id)
    put_agent_state(agent_id, %AgentState{agent_state | phylo_node: wt_phylo_node})

    # Update scheduler metadata with worktree assignment and running status
    put_sched_meta(agent_id, %{
      meta
      | status: :running,
        worktree: wt,
        task_ref: task.ref
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
        Logger.info("AgentScheduler: Queueing agent #{agent_id} (no available worktrees)")
        append_history(agent_id, "QUEUED", %{
          message: "Waiting for available worktree"
        })
        %{state | queue: :queue.in(agent_id, state.queue)}
    end
  end

  defp find_reclaimable_worktree(state) do
    case find_waiting_agent_with_worktree() do
      {donor_id, worktree} ->
        Logger.info(
          "AgentScheduler: Reclaiming worktree #{worktree} from waiting agent #{donor_id}"
        )

        {:ok, donor} = get_sched_meta(donor_id)
        put_sched_meta(donor_id, %{donor | worktree: nil})
        {:ok, worktree, state}

      nil ->
        :none
    end
  end

  # --- Auto-Commit Fallback ---

  defp auto_commit_fallback(agent_id, %{status: :running, worktree: wt} = meta)
       when not is_nil(wt) do
    case Git.status(wt) do
      {:ok, ""} ->
        sync_current_commit(agent_id, meta)

      {:ok, _changes} ->
        Logger.info("AgentScheduler: Auto-committing pending changes for agent #{agent_id}")

        # "discarding .gitignore files"
        Path.join(wt, "**/.gitignore")
        |> Path.wildcard(match_dot: true)
        |> Enum.each(&File.rm/1)

        Git.run(["add", "--all"], wt)
        objective = meta.spec.objective || "task"
        Git.commit(wt, "Agent: #{objective} (auto-commit)")

        sync_current_commit(agent_id, meta)

      _ ->
        meta
    end
  end

  defp auto_commit_fallback(_agent_id, meta), do: meta

  defp sync_current_commit(agent_id, %{worktree: wt} = meta) do
    case Git.rev_parse(wt) do
      {:ok, current_sha} ->
        {:ok, agent_state} = get_agent_state(agent_id)

        if agent_state.phylo_node.current_commit != current_sha do
          updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
          put_agent_state(agent_id, %{agent_state | phylo_node: updated_phylo})

          updated_spec = %{meta.spec | phylo_node: updated_phylo}
          updated_meta = %{meta | spec: updated_spec}
          put_sched_meta(agent_id, updated_meta)

          updated_meta
        else
          meta
        end

      _ ->
        meta
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
    {:ok, parent} = get_sched_meta(parent_id)
    results = Map.put(parent.sub_agent_results, sub_id, result)
    put_sched_meta(parent_id, %{parent | sub_agent_results: results})
  end

  defp maybe_resume_parent(state, parent_id) do
    {:ok, parent} = get_sched_meta(parent_id)
    pending = parent.pending_sub_agents

    all_done? =
      Enum.all?(pending, fn sub_id ->
        Map.has_key?(parent.sub_agent_results, sub_id)
      end)

    if all_done? do
      Logger.info("AgentScheduler: Agent #{parent_id} resuming, all sub-agents completed")
      ordered_ids = pending |> MapSet.to_list() |> Enum.sort()
      results = Enum.map(ordered_ids, &parent.sub_agent_results[&1])

      GenServer.reply(parent.sub_agent_from, results)

      put_sched_meta(parent_id, %{
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
    {:ok, meta} = get_sched_meta(agent_id)

    state =
      if meta.worktree do
        reset_worktree(meta.worktree, state.repo_root, state.base_sha)
        %{state | available_worktrees: [meta.worktree | state.available_worktrees]}
      else
        state
      end

    delete_agent_state(agent_id)
    delete_sched_meta(agent_id)
    clear_history(agent_id)
    state
  end

  defp handle_agent_crash(state, agent_id, reason) do
    {:ok, meta} = get_sched_meta(agent_id)

    Logger.error(
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{meta.retries}/#{state.agent_max_retries}"
    )

    if meta.worktree do
      reset_worktree(meta.worktree, state.repo_root, state.base_sha)
    end

    if meta.retries < state.agent_max_retries do
      state =
        if meta.worktree do
          %{state | available_worktrees: [meta.worktree | state.available_worktrees]}
        else
          state
        end

      # Log retry event to history for dashboard visibility
      append_history(agent_id, "RETRY", %{
        attempt: meta.retries + 1,
        reason: inspect(reason)
      })

      # Reset scheduler metadata for retry - status set to :pending to indicate waiting for worktree
      put_sched_meta(agent_id, %{
        meta
        | retries: meta.retries + 1,
          status: :pending,
          worktree: nil,
          task_ref: nil
      })

      # Reset agent state phylo_node (will be re-set on dispatch)
      {:ok, agent_state} = get_agent_state(agent_id)
      put_agent_state(agent_id, %AgentState{agent_state | phylo_node: nil})

      state = try_dispatch(state, agent_id)
      state = process_queue(state)
      {:noreply, state}
    else
      msg =
        "Agent #{agent_id} failed after #{state.agent_max_retries} retries. Last: #{inspect(reason)}"

      Logger.error("AgentScheduler: #{msg}")

      state =
        if meta.worktree do
          %{state | available_worktrees: [meta.worktree | state.available_worktrees]}
        else
          state
        end

      delete_agent_state(agent_id)
      delete_sched_meta(agent_id)
      clear_history(agent_id)

      if meta.parent_id do
        store_sub_result(meta.parent_id, agent_id, {:error, :agent_max_retries_exceeded})
        state = maybe_resume_parent(state, meta.parent_id)
        state = process_queue(state)
        {:noreply, state}
      else
        GenServer.reply(meta.from, {:error, :agent_max_retries_exceeded})
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
