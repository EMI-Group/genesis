defmodule EvoGit.AgentScheduler do
  @moduledoc """
  Global agent scheduler managing agent lifecycles and worktree assignments.

  The scheduler is the single owner of worktree lifecycle. Callers provide a
  structured agent specification — spatial state (ContextNode), temporal state
  (PhyloGraphNode), agent module, and objective — and the scheduler handles:

  - Managing the worktree pool (creation, assignment, reclamation)
  - Preparing worktrees (Git clean/checkout) before agent execution
  - Spawning and tracking agents (both top-level and subagents)
  - Transitioning agents between :pending, :running, :waiting, and :ready states
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
  alias EvoGit.Defaults

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta

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
  Called from within a running agent to spawn subagents concurrently.
  Marks the calling agent as :waiting (worktree becomes reclaimable).
  Blocks until all subagents complete. Returns a list of results in the
  same order as the input specs.

  Returns `{:error, :max_depth_exceeded}` if the calling agent has reached
  the maximum recursion depth and cannot spawn further subagents.

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
    GenServer.call(__MODULE__, :get_max_depth)
  end

  @doc """
  Updates scheduler configuration at runtime without restarting the process.

  Accepts a keyword list with any of: `:max_concurrency`, `:agent_max_retries`,
  `:max_depth`. Only provided keys are updated; others remain unchanged.

  If `:max_concurrency` changes and the worktree pool is already initialized,
  the pool is torn down and will be lazily re-created on the next `run_agent/2`
  call. This is only safe when no agents are running — returns
  `{:error, :agents_running}` if active agents exist.

  Returns `:ok` on success.
  """
  @spec update_config(keyword()) :: :ok | {:error, :agents_running}
  def update_config(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:update_config, opts})
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

    max_concurrency =
      Keyword.get(opts, :max_concurrency, Defaults.max_concurrency())

    agent_max_retries =
      Keyword.get(opts, :agent_max_retries, Defaults.agent_max_retries())

    max_depth =
      Keyword.get(opts, :max_depth, Defaults.max_agent_depth())

    llm_model =
      Keyword.get(opts, :llm_model, Defaults.llm_model())

    max_retries =
      Keyword.get(opts, :max_retries, Defaults.max_retries())

    {:ok,
     %{
       initialized: false,
       repo_root: nil,
       base_sha: nil,
       max_concurrency: max_concurrency,
       agent_max_retries: agent_max_retries,
       max_depth: max_depth,
       llm_model: llm_model,
       max_retries: max_retries,
       next_agent_id: 1,
       running_count: 0,
       ref_to_agent: %{},
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call(:get_max_depth, _from, state) do
    {:reply, state.max_depth, state}
  end

  @impl true
  def handle_call({:run_agent, spec}, from, state) do
    # Extract repo_path from the spec's phylo_node
    repo_path = spec.phylo_node.repo
    state = ensure_initialized(state, repo_path)
    {agent_id, state} = register_agent(state, spec, from, _parent_id = nil, _depth = 0)
    Logger.info("AgentScheduler: Spawning top-level agent #{agent_id}")
    state = try_dispatch(state, agent_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:update_config, opts}, _from, state) do
    has_active_agents = state.ref_to_agent != %{} or not :queue.is_empty(state.queue)

    concurrency_changed =
      Keyword.has_key?(opts, :max_concurrency) and
        Keyword.get(opts, :max_concurrency) != state.max_concurrency

    if concurrency_changed and has_active_agents do
      {:reply, {:error, :agents_running}, state}
    else
      state =
        state
        |> maybe_update(:max_concurrency, opts)
        |> maybe_update(:agent_max_retries, opts)
        |> maybe_update(:max_depth, opts)
        |> maybe_update(:llm_model, opts)
        |> maybe_update(:max_retries, opts)

      # If concurrency changed, tear down the pool so it's lazily re-created
      state =
        if concurrency_changed and state.initialized do
          teardown_worktrees(state)
        else
          state
        end

      Logger.info(
        "AgentScheduler: Config updated — max_concurrency: #{state.max_concurrency}, " <>
          "agent_max_retries: #{state.agent_max_retries}, max_depth: #{state.max_depth}"
      )

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:spawn_sub_agents, parent_id, specs}, from, state) do
    state = ensure_initialized(state)
    {:ok, parent} = get_sched_meta(parent_id)

    spawn_validated_subagents(parent_id, parent, specs, from, state)
  end

  # --- Subagent-Level Validation and Spawning ---

  # Validates and spawns subagents. Each spec is validated independently;
  # failed specs get an error result, valid specs are spawned.
  defp spawn_validated_subagents(parent_id, parent, specs, from, state) do
    # Get parent agent state for validation context
    {:ok, parent_agent_state} = get_agent_state(parent_id)

    # Pre-Delegation Cleanliness
    parent = auto_commit_fallback(parent_id, parent)

    # Mark parent as :waiting
    Logger.info(
      "AgentScheduler: Agent #{parent_id} yielding to spawn #{length(specs)} subagents"
    )

    parent = %{parent | status: :waiting}
    put_sched_meta(parent_id, parent)

    # Validate each spec and partition into valid/invalid
    {valid_specs_with_idx, invalid_results} =
      specs
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {spec, idx}, {valid, invalid} ->
        case validate_single_subagent(parent_id, parent, spec, parent_agent_state, state) do
          :ok ->
            {[{spec, idx} | valid], invalid}

          {:error, reason} ->
            Logger.warning(
              "AgentScheduler: Subagent #{idx} failed validation: #{inspect(reason)}"
            )

            {valid, Map.put(invalid, idx, {:error, reason})}
        end
      end)

    # Reverse to maintain original order
    valid_specs_with_idx = Enum.reverse(valid_specs_with_idx)

    # Register and spawn valid subagents
    {idx_to_sub_id, state} =
      Enum.map_reduce(valid_specs_with_idx, state, fn {spec, idx}, acc ->
        {sub_id, acc} = register_agent(acc, spec, _from = nil, parent_id, parent.depth + 1)
        {{idx, sub_id}, acc}
      end)

    sub_ids = Enum.map(idx_to_sub_id, fn {_idx, sub_id} -> sub_id end)

    # Build the sub_id -> index mapping
    sub_agent_indices = Map.new(idx_to_sub_id, fn {idx, sub_id} -> {sub_id, idx} end)

    # Track pending subagents, pre-failed results, and index mapping on the parent
    put_sched_meta(parent_id, %{
      parent
      | sub_agent_from: from,
        total_sub_specs: length(specs),
        pending_sub_agents: MapSet.new(sub_ids),
        sub_agent_results: invalid_results,
        sub_agent_indices: sub_agent_indices
    })

    # Dispatch all valid subagents
    state = Enum.reduce(sub_ids, state, &try_dispatch(&2, &1))

    # If no valid subagents, immediately reply with all errors
    if sub_ids == [] do
      results = build_ordered_results(invalid_results, length(specs))
      GenServer.reply(from, results)
      put_sched_meta(parent_id, %{parent | status: :running})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Validates a single subagent spec. All checks are per-subagent.
  defp validate_single_subagent(parent_id, parent, spec, parent_agent_state, state) do
    subagent_depth = parent.depth + 1

    with :ok <- validate_subagent_depth(parent_id, subagent_depth, state),
         :ok <- validate_subagent_not_ignored(spec),
         :ok <- validate_spatial_contract_for_spec(parent_id, parent_agent_state, spec) do
      :ok
    end
  end

  # Checks if the subagent's depth exceeds the maximum allowed depth
  defp validate_subagent_depth(_parent_id, subagent_depth, state) do
    if subagent_depth > state.max_depth do
      Logger.warning(
        "AgentScheduler: Subagent depth #{subagent_depth} exceeds max #{state.max_depth}"
      )

      {:error, :max_depth_exceeded}
    else
      :ok
    end
  end

  # Checks if the subagent's path is ignored by git
  defp validate_subagent_not_ignored(spec) do
    if EvoGit.Core.ContextNode.is_ignored?(spec.context_node) do
      {:error, :path_ignored}
    else
      :ok
    end
  end

  # Builds the final results list in the same order as input specs
  defp build_ordered_results(sub_results, spec_count) do
    0..(spec_count - 1)
    |> Enum.map(fn idx ->
      Map.get(sub_results, idx, {:error, :unknown_error})
    end)
  end

  # --- Spatial Contract Validation (Per-Subagent) ---

  defp validate_spatial_contract_for_spec(_parent_id, %{context_node: parent_context}, spec) do
    parent_type = :read_write
    parent_path = EvoGit.Agent.Tools.Shared.normalize_path(parent_context.path)
    child_type = spec.agent_module.agent_type()
    child_path = EvoGit.Agent.Tools.Shared.normalize_path(spec.context_node.path)

    validate_spawn_spatiality(parent_type, parent_path, child_type, child_path)
  end

  defp validate_spawn_spatiality(
         :read_write,
         parent_path,
         :read_write,
         child_path
       ) do
    if EvoGit.Agent.Tools.Shared.is_child_or_same_node?(parent_path, child_path) do
      :ok
    else
      {:error,
       {:spatial_contract_violation,
        """
        Subagent that requires editing permissions can only be spawned on the same node or child nodes of your assigned node.
        You attempted to spawn a read-write subagent at '#{child_path}' from your assigned node '#{parent_path}'.

        This violates the contract - you do NOT have write permission on sibling or parent nodes.
        If you need to make changes to '#{child_path}', do the following:
        1. Complete your work within your assigned node '#{parent_path}'
        2. Return and report to the user about your progress and the changes needed on '#{child_path}'
        """}}
    end
  end

  defp validate_spawn_spatiality(_parent_type, _parent_path, _child_type, _child_path), do: :ok

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

  defp ensure_initialized(state, repo_path \\ nil)

  defp ensure_initialized(%{initialized: true} = state, nil), do: state

  defp ensure_initialized(%{initialized: true, repo_root: repo_root} = state, new_repo_path)
       when repo_root == new_repo_path do
    state
  end

  defp ensure_initialized(%{initialized: true} = state, new_repo_path) do
    Logger.info(
      "AgentScheduler: Repo path changed from #{state.repo_root} to #{new_repo_path}, reinitializing..."
    )

    state = teardown_worktrees(state)
    do_initialize(state, new_repo_path)
  end

  defp ensure_initialized(_state, nil) do
    raise ArgumentError, "repo_path is required for initial AgentScheduler initialization"
  end

  defp ensure_initialized(state, repo_path) do
    repo_root = Path.expand(repo_path)
    do_initialize(state, repo_root)
  end

  defp do_initialize(state, repo_root) do
    worker_base = Path.join(repo_root, ".evogit/workers")

    Logger.info(
      "AgentScheduler: Initializing worktree directory at #{worker_base}"
    )

    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)
    File.mkdir_p!(worker_base)

    {:ok, current_sha} = Git.rev_parse(repo_root)

    %{
      state
      | initialized: true,
        repo_root: repo_root,
        base_sha: current_sha
    }
  end

  defp teardown_worktrees(%{repo_root: repo_root} = state) when is_binary(repo_root) do
    worker_base = Path.join(repo_root, ".evogit/workers")
    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)
    %{state | initialized: false}
  end

  defp teardown_worktrees(state), do: %{state | initialized: false}

  defp maybe_update(state, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(state, key, value)
      :error -> state
    end
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
  Gets the conversation context for an agent from the agent state table.
  Returns the context or nil if not set.
  """
  @spec get_agent_context(pos_integer()) :: ReqLLM.Context.t() | nil
  def get_agent_context(agent_id) do
    case get_agent_state(agent_id) do
      {:ok, %{context: context}} -> context
      _ -> nil
    end
  end

  @doc """
  Updates the conversation context for an agent in the agent state table.
  Also streams the update to the event sink for real-time dashboard updates.
  """
  @spec update_agent_context(pos_integer(), ReqLLM.Context.t()) :: :ok
  def update_agent_context(agent_id, %ReqLLM.Context{} = context) do
    case get_agent_state(agent_id) do
      {:ok, agent_state} ->
        updated_state = %{agent_state | context: context}
        put_agent_state(agent_id, updated_state)

        # Stream context update to event sink for dashboard
        stream_context_update(agent_id, context)

        :ok

      :error ->
        :error
    end
  end

  # Streams context update to event sink for dashboard visualization
  defp stream_context_update(agent_id, context) do
    case get_agent_state(agent_id) do
      {:ok, %{event_sink: pid}} when is_pid(pid) ->
        messages = ReqLLM.Context.to_list(context)
        send(pid, {:agent_context, %{agent_id: agent_id, messages: messages}})

      _ ->
        :ok
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
      event_sink: event_sink,
      llm_model: state.llm_model,
      max_retries: state.max_retries,
      max_depth: state.max_depth
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

  # --- Dispatch Helpers ---

  defp assign_and_prepare_worktree(agent_id, wt) do
    {:ok, meta} = get_sched_meta(agent_id)
    {:ok, agent_state} = get_agent_state(agent_id)
    spec = meta.spec

    commit_sha = spec.phylo_node.current_commit

    Git.clean(wt)
    Git.checkout(wt, commit_sha)

    # Build the worktree-bound phylo_node (repo points to worktree)
    wt_phylo_node = %PhyloGraphNode{
      repo: wt,
      base_commit: spec.phylo_node.base_commit,
      current_commit: commit_sha
    }

    put_agent_state(agent_id, %AgentState{agent_state | phylo_node: wt_phylo_node})

    commit_sha
  end

  # --- Dispatch ---

  defp try_dispatch(state, agent_id) do
    {:ok, meta} = get_sched_meta(agent_id)
    retries = meta.retries
    spec = meta.spec

    # Create a persistent worktree for this agent: worker_<agent_id>
    worktree_path = Path.join([state.repo_root, ".evogit/workers", "worker_#{agent_id}"])

    # Create the worktree if it doesn't exist (e.g., on first dispatch)
    unless File.exists?(worktree_path) do
      commit_sha = spec.phylo_node.current_commit

      case Git.add_worktree(state.repo_root, worktree_path, commit_sha) do
        {:ok, _} ->
          Logger.info("AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id}")

        {:error, _, msg} ->
          Logger.error("AgentScheduler: Failed to create worktree #{worktree_path}: #{msg}")
          raise "Failed to create worktree for agent #{agent_id}"
      end
    end

    assign_and_prepare_worktree(agent_id, worktree_path)

    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, meta.depth)
        Process.put(:evogit_repo_root, state.repo_root)
        Process.put(:repo_path, worktree_path)

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        else
          Logger.info("AgentScheduler: Agent #{agent_id} starting execution in worktree #{worktree_path}")
        end

        spec.agent_module.run(spec.objective)
      end)

    # Update scheduler metadata with worktree assignment and running status
    put_sched_meta(agent_id, %{
      meta
      | status: :running,
        worktree: worktree_path,
        task_ref: task.ref
    })

    %{
      state
      | running_count: state.running_count + 1,
        ref_to_agent: Map.put(state.ref_to_agent, task.ref, agent_id)
    }
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
    {:ok, current_sha} = Git.rev_parse(wt)
    {:ok, agent_state} = get_agent_state(agent_id)

    agent_needs_update? = agent_state.phylo_node.current_commit != current_sha
    meta_needs_update? = meta.spec.phylo_node.current_commit != current_sha

    if agent_needs_update? do
      updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
      put_agent_state(agent_id, %{agent_state | phylo_node: updated_phylo})
    end

    if meta_needs_update? do
      updated_spec_phylo = %{
        meta.spec.phylo_node
        | current_commit: current_sha
      }

      updated_spec = %{meta.spec | phylo_node: updated_spec_phylo}
      updated_meta = %{meta | spec: updated_spec}
      put_sched_meta(agent_id, updated_meta)

      updated_meta
    else
      meta
    end
  end

  # --- Queue Processing ---

  defp process_queue(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, agent_id}, new_queue} ->
        state = %{state | queue: new_queue}

        case get_sched_meta(agent_id) do
          {:ok, %{status: :ready} = meta} ->
            # Ready parent agent - resume with its persistent worktree
            state = dispatch_ready_parent(state, agent_id, meta)
            process_queue(state)

          {:ok, _meta} ->
            # Regular agent - dispatch with its persistent worktree
            state = try_dispatch(state, agent_id)
            process_queue(state)

          :error ->
            # Agent was already recycled; skip stale queue entry
            Logger.debug("AgentScheduler: Skipping stale queue entry for agent #{agent_id}")
            process_queue(state)
        end

      {:empty, _} ->
        state
    end
  end

  # Resumes a waiting parent agent. The parent keeps its persistent worktree
  # while waiting, so no worktree assignment is needed.
  defp dispatch_ready_parent(state, agent_id, %{worktree: wt} = meta) do
    results = build_ordered_results(meta.sub_agent_results, meta.total_sub_specs)

    GenServer.reply(meta.sub_agent_from, results)

    put_sched_meta(agent_id, %{
      meta
      | status: :running,
        sub_agent_from: nil,
        pending_sub_agents: MapSet.new(),
        sub_agent_results: %{},
        sub_agent_indices: %{},
        total_sub_specs: 0
    })

    {:ok, agent_state} = get_agent_state(agent_id)
    commit_sha = agent_state.phylo_node.current_commit

    Logger.info(
      "AgentScheduler: Waiting agent #{agent_id} resumed with persistent worktree #{wt} at commit #{commit_sha}"
    )

    state
  end

  # --- SubAgent Result Tracking ---

  defp store_sub_result(parent_id, sub_id, result) do
    {:ok, parent} = get_sched_meta(parent_id)
    idx = Map.get(parent.sub_agent_indices, sub_id)
    results = Map.put(parent.sub_agent_results, idx, result)
    put_sched_meta(parent_id, %{parent | sub_agent_results: results})
  end

  defp maybe_resume_parent(state, parent_id) do
    {:ok, parent} = get_sched_meta(parent_id)

    all_done? = map_size(parent.sub_agent_results) == parent.total_sub_specs

    if all_done? do
      Logger.info("AgentScheduler: Agent #{parent_id} ready to resume, all subagents completed")

      # Parent always has its persistent worktree - resume immediately
      parent = %{parent | status: :ready}
      put_sched_meta(parent_id, parent)
      dispatch_ready_parent(state, parent_id, parent)
    else
      state
    end
  end

  # --- Agent Lifecycle ---

  defp recycle_agent(state, agent_id) do
    {:ok, meta} = get_sched_meta(agent_id)

    # Delete the agent's persistent worktree
    if meta.worktree do
      delete_worktree(meta.worktree, state.repo_root)
    end

    delete_agent_state(agent_id)
    delete_sched_meta(agent_id)
    %{state | running_count: state.running_count - 1}
  end

  defp handle_agent_crash(state, agent_id, reason) do
    {:ok, meta} = get_sched_meta(agent_id)

    Logger.error(
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{meta.retries}/#{state.agent_max_retries}"
    )

    if meta.retries < state.agent_max_retries do
      # On retry, keep the persistent worktree - just update retry count and status
      # The worktree will be reused on next dispatch (assign_and_prepare_worktree will clean/checkout)
      put_sched_meta(agent_id, %{
        meta
        | retries: meta.retries + 1,
          status: :pending,
          task_ref: nil
      })

      # Reset agent state phylo_node (will be re-set on dispatch)
      {:ok, agent_state} = get_agent_state(agent_id)
      put_agent_state(agent_id, %AgentState{agent_state | phylo_node: nil, context: nil})

      state = try_dispatch(state, agent_id)
      state = process_queue(state)
      {:noreply, state}
    else
      msg =
        "Agent #{agent_id} failed after #{state.agent_max_retries} retries. Last: #{inspect(reason)}"

      Logger.error("AgentScheduler: #{msg}")

      # Delete the agent's persistent worktree on permanent failure
      if meta.worktree do
        delete_worktree(meta.worktree, state.repo_root)
      end

      delete_agent_state(agent_id)
      delete_sched_meta(agent_id)
      state = %{state | running_count: state.running_count - 1}

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

  defp delete_worktree(path, repo_root) do
    Logger.info("AgentScheduler: Deleting worktree #{path}")
    File.rm_rf!(path)
    Git.prune_worktrees(repo_root)
  end
end
