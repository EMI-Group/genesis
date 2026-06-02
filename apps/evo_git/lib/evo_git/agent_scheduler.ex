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
  - LLM and tool execution slot management with concurrency control and backoff

  ## ETS Tables

  Agent data is split across two ETS tables with clear ownership:

  - **`:evogit_agent_state`** — Owned by agent processes. Contains the agent's
    live spatial/temporal state (`context_node`, `phylo_node`) and `event_sink`.
    The scheduler writes initial values on dispatch; agents update `phylo_node`
    after each commit via `update_phylo_node/2`.

  - **`:evogit_sched_meta`** — Owned by the scheduler process. Contains all
    scheduling bookkeeping: status, worktree assignment, task refs, parent/child
    tracking, retry counts, etc. Agents do not write to this table.

  ## Slot Management

  The scheduler manages two independent slot pools:

  - **LLM slots** (`max_concurrency`) — Controls how many agents can make
    concurrent LLM calls. Includes a global backoff mechanism for rate limit
    errors (60-second cooldown).

  - **Tool slots** (`max_tool_concurrency`) — Controls how many agents can
    execute tools concurrently. Simple semaphore without backoff.

  Both slot types use blocking calls — agents wait in queues when no slots
  are available and are granted slots via `GenServer.reply/2` when freed.
  """

  use GenServer
  require Logger
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

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
  Returns the repo root path for the current agent's repo_id.
  Returns nil if not in a scheduled agent.
  """
  def current_repo_root do
    # Prefer the process dictionary value (set at dispatch time) — this is
    # always correct for the current agent and avoids a GenServer call that
    # could return a stale value when multiple tasks target different repos.
    case Process.get(:evogit_repo_root) do
      nil ->
        repo_id = Process.get(:evogit_repo_id, :primary)
        GenServer.call(__MODULE__, {:repo_root_for, repo_id})

      repo_root ->
        repo_root
    end
  end

  @doc """
  Returns the configured maximum agent recursion depth.
  """
  def max_depth do
    GenServer.call(__MODULE__, :get_max_depth)
  end

  @doc """
  Updates scheduler configuration at runtime (session-level override).

  This is the highest-priority configuration layer. Accepts a keyword list
  with any of: `:max_concurrency`, `:max_tool_concurrency`,
  `:agent_max_retries`, `:max_depth`, `:max_retries`, `:llm_model`.
  Only provided keys are updated; others remain unchanged.

  Concurrency changes take effect on the next scheduling action — currently
  running agents are unaffected. If concurrency is increased, pending agents
  waiting for slots will be granted immediately.

  Returns `:ok` on success, or `{:error, message}` if validation fails
  (e.g., setting `llm_model` to `nil`).
  """
  @spec update_config(keyword()) :: :ok | {:error, String.t()}
  def update_config(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:update_config, opts})
  end

  @doc """
  Returns the current scheduler configuration as a map.

  Includes all runtime settings (some may have been overridden via `update_config/1`).
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Pauses the scheduler. Currently running agents continue to completion,
  but no new LLM slots, tool slots, agent dispatches, or subagent spawns
  will be granted until `resume/0` is called.

  Returns `:ok` if already paused or successfully paused.
  """
  @spec pause() :: :ok
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resumes the scheduler after a pause. Grants any pending slots and
  dispatches any queued agents that were blocked while paused.

  Returns `:ok`.
  """
  @spec resume() :: :ok
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc """
  Returns whether the scheduler is currently paused.
  """
  @spec paused?() :: boolean()
  def paused? do
    GenServer.call(__MODULE__, :paused?)
  end

  @doc """
  Returns the value of a specific scheduler config key.

  ## Example

      AgentScheduler.get_config(:max_concurrency)
      #=> 3
  """
  @spec get_config(atom()) :: term()
  def get_config(key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get_config, key})
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

  @doc """
  Registers foreign repos for multi-repo support.
  Called during runtime initialization before any agents are spawned.
  """
  @spec register_foreign_repos([ForeignRepo.t()]) :: :ok
  def register_foreign_repos(foreign_repos) when is_list(foreign_repos) do
    GenServer.call(__MODULE__, {:register_foreign_repos, foreign_repos})
  end

  @doc """
  Returns the list of all registered ForeignRepo structs (including primary).
  """
  @spec get_foreign_repos() :: [ForeignRepo.t()]
  def get_foreign_repos do
    GenServer.call(__MODULE__, :get_foreign_repos)
  end

  @doc """
  Returns the foreign repo commits map for the given agent's SchedMeta.
  Used by agents to track the latest known commit per foreign repo from
  previous subagent completions.
  """
  @spec get_foreign_repo_commits(pos_integer()) :: %{atom() => String.t()}
  def get_foreign_repo_commits(agent_id) do
    case :ets.lookup(@sched_table, agent_id) do
      [{^agent_id, %{foreign_repo_commits: frc}}] when is_map(frc) -> frc
      _ -> %{}
    end
  end

  @doc """
  Registers a single foreign repo at runtime.
  Can be used to add repos dynamically (e.g., from the dashboard).
  Returns `:ok` on success, `{:error, {:already_exists, id}}` if a repo with the same id already exists (except :primary).
  """
  @spec register_foreign_repo(ForeignRepo.t()) :: :ok | {:error, {:already_exists, atom()}}
  def register_foreign_repo(%ForeignRepo{} = repo) do
    GenServer.call(__MODULE__, {:register_foreign_repo, repo})
  end

  @doc """
  Unregisters a foreign repo by its id.
  Cannot unregister the :primary repo.
  Returns `:ok` on success, `{:error, :cannot_unregister_primary}` if id is :primary,
  `{:error, {:not_found, id}}` if the repo id doesn't exist.
  """
  @spec unregister_foreign_repo(atom()) :: :ok | {:error, term()}
  def unregister_foreign_repo(repo_id) when is_atom(repo_id) do
    GenServer.call(__MODULE__, {:unregister_foreign_repo, repo_id})
  end

  @doc """
  Returns the repo root path for the given repo_id.
  Raises if the repo_id is not registered.
  """
  @spec repo_root_for(atom()) :: String.t() | {:error, {:unknown_repo, atom()}}
  def repo_root_for(repo_id) when is_atom(repo_id) do
    GenServer.call(__MODULE__, {:repo_root_for, repo_id})
  end

  @doc """
  Requests an LLM execution slot from the scheduler. Blocks the caller until a slot
  is available (respects max_concurrency). Returns :ok when granted.
  """
  @spec request_llm_slot(pos_integer(), timeout()) :: :ok
  def request_llm_slot(agent_id, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:request_llm_slot, agent_id}, timeout)
  end

  @doc """
  Releases an LLM execution slot back to the scheduler. Call this after the LLM
  call completes (success or failure).
  """
  @spec release_llm_slot(pos_integer()) :: :ok
  def release_llm_slot(agent_id) do
    GenServer.call(__MODULE__, {:release_llm_slot, agent_id})
  end

  @doc """
  Reports an LLM error that should trigger a global backoff period.
  All agents waiting for LLM slots will be delayed until the backoff expires.
  """
  @spec report_llm_error(pos_integer(), atom()) :: :ok
  def report_llm_error(agent_id, error_type) do
    GenServer.call(__MODULE__, {:report_llm_error, agent_id, error_type})
  end

  @doc """
  Requests a tool execution slot from the scheduler. Blocks the caller until a slot
  is available (respects max_tool_concurrency). Returns :ok when granted.
  """
  @spec request_tool_slot(pos_integer(), timeout()) :: :ok
  def request_tool_slot(agent_id, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:request_tool_slot, agent_id}, timeout)
  end

  @doc """
  Releases a tool execution slot back to the scheduler. Call this after tool
  execution completes.
  """
  @spec release_tool_slot(pos_integer()) :: :ok
  def release_tool_slot(agent_id) do
    GenServer.call(__MODULE__, {:release_tool_slot, agent_id})
  end

  @doc """
  Acquires an LLM slot, executes the given function, and releases the slot afterward.

  The slot is always released via an `after` block, even if the function raises.
  Rate-limit error reporting should be handled by the caller inside the callback,
  before raising — the `after` block runs after any exception.

  Returns the result of `fun.()`.
  """
  @spec with_llm_slot(pos_integer(), (-> result)) :: result when result: var
  def with_llm_slot(agent_id, fun) when is_function(fun, 0) do
    request_llm_slot(agent_id)

    try do
      fun.()
    after
      release_llm_slot(agent_id)
    end
  end

  @doc """
  Acquires a tool execution slot, executes the given function, and releases the slot afterward.
  Ensures the slot is released even if the function raises.

  Returns the result of `fun.()`.
  """
  @spec with_tool_slot(pos_integer(), (-> result)) :: result when result: var
  def with_tool_slot(agent_id, fun) when is_function(fun, 0) do
    request_tool_slot(agent_id)

    try do
      fun.()
    after
      release_tool_slot(agent_id)
    end
  end

  @doc """
  Cancels all agents belonging to a task identified by the caller PID.

  When the EvoDash Task process (which called `run_agent/2`) is killed,
  its PID is used to find the matching top-level agent. All agents sharing
  the same scheduler `task_id` (including subagents) are then cancelled:
  their Task processes are killed, worktrees deleted, ETS entries removed,
  and any blocked callers are replied to with `{:error, :cancelled}`.

  Returns `:ok` if agents were found and cancelled, or `{:error, :not_found}`.
  """
  @spec cancel_task_agents(pid()) :: :ok | {:error, :not_found}
  def cancel_task_agents(caller_pid) when is_pid(caller_pid) do
    GenServer.call(__MODULE__, {:cancel_task_agents, caller_pid})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    :ets.new(@agent_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@sched_table, [:named_table, :public, :set, read_concurrency: true])

    config = EvoGit.Config.resolve()

    # Load API keys from credentials.toml into environment variables
    _credentials = EvoGit.Config.credentials()

    scheduler_config = Map.get(config, :scheduler, %{})
    sandbox_config = Map.get(config, :sandbox, %{})

    max_concurrency = Map.get(scheduler_config, :max_concurrency, 3)
    max_tool_concurrency = Map.get(scheduler_config, :max_tool_concurrency, 2)
    agent_max_retries = Map.get(scheduler_config, :agent_max_retries, 3)
    max_depth = Map.get(scheduler_config, :max_agent_depth, 8)
    max_retries = Map.get(scheduler_config, :max_retries, 15)
    llm_model = Map.get(config, :llm, %{}) |> Map.get(:model)
    sandbox_mode = Map.get(sandbox_config, :mode)
    sandbox_resources = Map.get(sandbox_config, :resources)

    # Warn (but don't crash) if llm_model is not configured
    unless llm_model do
      Logger.warning("""
      AgentScheduler: LLM model not configured. Agent execution will be unavailable until configured.
      Please set llm.model in your config file:

      ~/.config/evogit/config.toml:

          [llm]
          model = "provider:model_name"

      Example models:
      - "anthropic:claude-sonnet-4-20250514"
      - "google:gemini-2.0-flash-exp"
      - "zai_coding_plan:glm-5.1"

      You can also configure this via the Settings page in the dashboard.
      """)
    end

    # Allow opts to override (for backward compat with CLI --flags)
    max_concurrency = Keyword.get(opts, :max_concurrency, max_concurrency)
    max_tool_concurrency = Keyword.get(opts, :max_tool_concurrency, max_tool_concurrency)
    agent_max_retries = Keyword.get(opts, :agent_max_retries, agent_max_retries)
    max_depth = Keyword.get(opts, :max_depth, max_depth)
    max_retries = Keyword.get(opts, :max_retries, max_retries)
    llm_model = Keyword.get(opts, :llm_model, llm_model)

    {:ok,
     %State{
       initialized: false,
       foreign_repos: %{},
       initialized_repos: %{},
       max_concurrency: max_concurrency,
       agent_max_retries: agent_max_retries,
       max_depth: max_depth,
       llm_model: llm_model,
       max_retries: max_retries,
       next_agent_id: 1,
       running_count: 0,
       ref_to_agent: %{},
       queue: :queue.new(),
       llm_slots_available: max_concurrency,
       llm_waiting: :queue.new(),
       llm_backoff_until: nil,
       tool_slots_available: max_tool_concurrency,
       tool_waiting: :queue.new(),
       max_tool_concurrency: max_tool_concurrency,
       next_task_id: 1,
       sandbox_mode: sandbox_mode,
       sandbox_resources: sandbox_resources
     }}
  end

  @impl true
  def handle_call(:get_max_depth, _from, state) do
    {:reply, state.max_depth, state}
  end

  @impl true
  def handle_call({:register_foreign_repos, foreign_repos}, _from, state) do
    repos_map =
      foreign_repos
      |> Enum.map(fn repo -> {repo.id, repo} end)
      |> Map.new()

    # Merge with existing foreign repos
    foreign_repos = Map.merge(state.foreign_repos, repos_map)

    Logger.info(
      "AgentScheduler: Registered #{map_size(repos_map)} foreign repo(s): #{inspect(Map.keys(repos_map))}"
    )

    {:reply, :ok, %{state | foreign_repos: foreign_repos}}
  end

  @impl true
  def handle_call(:get_foreign_repos, _from, state) do
    repos = Map.values(state.foreign_repos)
    {:reply, repos, state}
  end

  @impl true
  def handle_call({:register_foreign_repo, repo}, _from, state) do
    if Map.has_key?(state.foreign_repos, repo.id) do
      {:reply, {:error, {:already_exists, repo.id}}, state}
    else
      foreign_repos = Map.put(state.foreign_repos, repo.id, repo)
      Logger.info("AgentScheduler: Registered foreign repo #{repo.id} at #{repo.root}")
      {:reply, :ok, %{state | foreign_repos: foreign_repos}}
    end
  end

  @impl true
  def handle_call({:unregister_foreign_repo, repo_id}, _from, state) do
    cond do
      repo_id == :primary ->
        {:reply, {:error, :cannot_unregister_primary}, state}

      not Map.has_key?(state.foreign_repos, repo_id) ->
        {:reply, {:error, {:not_found, repo_id}}, state}

      true ->
        foreign_repos = Map.delete(state.foreign_repos, repo_id)
        Logger.info("AgentScheduler: Unregistered foreign repo #{repo_id}")
        {:reply, :ok, %{state | foreign_repos: foreign_repos}}
    end
  end

  @impl true
  def handle_call({:repo_root_for, repo_id}, _from, state) do
    case Map.get(state.foreign_repos, repo_id) do
      %ForeignRepo{root: root} ->
        {:reply, root, state}

      nil ->
        {:reply, {:error, {:unknown_repo, repo_id}}, state}
    end
  end

  @impl true
  def handle_call({:run_agent, _spec}, _from, %{llm_model: nil} = state) do
    Logger.warning("AgentScheduler: Rejecting agent spawn — LLM model not configured")
    {:reply, {:error, :llm_not_configured}, state}
  end

  def handle_call({:run_agent, spec}, from, state) do
    # Extract repo_path from the spec's phylo_node
    repo_path = spec.phylo_node.repo
    state = Worktrees.ensure_initialized(state, repo_path)
    task_id = state.next_task_id
    {agent_id, state} = Dispatch.register_agent(state, spec, from, _parent_id = nil, _depth = 0, task_id)
    state = %{state | next_task_id: task_id + 1}
    Logger.info("AgentScheduler: Spawning top-level agent #{agent_id} (task #{task_id})")

    if state.paused do
      # Queue the agent for dispatch when resumed
      state = %{state | queue: :queue.in(agent_id, state.queue)}
      {:noreply, state}
    else
      state = Dispatch.try_dispatch(state, agent_id)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:cancel_task_agents, caller_pid}, _from, state) do
    # 1. Scan :evogit_sched_meta ETS to find top-level agent whose meta.from contains caller_pid
    #    The meta.from is a GenServer.from() tuple: {ref, pid} where pid is the calling process
    top_level_agent =
      :ets.tab2list(@sched_table)
      |> Enum.find(fn {_id, %SchedMeta{depth: 0, from: {_, pid}}} ->
        pid == caller_pid
      end)

    case top_level_agent do
      nil ->
        {:reply, {:error, :not_found}, state}

      {_id, %SchedMeta{task_id: task_id}} ->
        Logger.info("AgentScheduler: Cancelling all agents for task #{task_id} (caller PID #{inspect(caller_pid)})")

        # 2. Find ALL agents with this task_id
        agent_ids =
          :ets.tab2list(@sched_table)
          |> Enum.filter(fn {_id, %SchedMeta{task_id: tid}} -> tid == task_id end)
          |> Enum.map(fn {id, _meta} -> id end)

        cancel_set = MapSet.new(agent_ids)

        # 3. Remove refs from ref_to_agent BEFORE killing Tasks (so DOWN handler is a no-op)
        ref_to_agent =
          state.ref_to_agent
          |> Enum.reject(fn {_ref, aid} -> MapSet.member?(cancel_set, aid) end)
          |> Map.new()

        state = %{state | ref_to_agent: ref_to_agent}

        # 4. Remove from dispatch queue
        queue =
          :queue.filter(state.queue, fn aid ->
            not MapSet.member?(cancel_set, aid)
          end)

        state = %{state | queue: queue}

        # 5. Purge from slot waiting queues (replies {:error, :cancelled} to blocked callers)
        {state, _status_updates} = Slots.purge_agents_from_queues(state, cancel_set)

        # 6. Cancel agents in reverse depth order (leaf subagents first, then parents)
        #    Sort by depth descending so deepest agents are cancelled first
        sorted_agents =
          :ets.tab2list(@sched_table)
          |> Enum.filter(fn {_id, %SchedMeta{task_id: tid}} -> tid == task_id end)
          |> Enum.sort_by(fn {_id, %SchedMeta{depth: d}} -> d end, :desc)
          |> Enum.map(fn {id, _meta} -> id end)

        state = Enum.reduce(sorted_agents, state, fn agent_id, acc_state ->
          Lifecycle.cancel_agent(acc_state, agent_id)
        end)

        # 7. Process queue to dispatch any newly-eligible agents
        state = Dispatch.process_queue(state)

        Logger.info("AgentScheduler: Cancelled #{length(agent_ids)} agent(s) for task #{task_id}")

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:update_config, opts}, _from, state) do
    # Validate llm_model if being updated
    if Keyword.has_key?(opts, :llm_model) do
      new_model = Keyword.get(opts, :llm_model)

      unless new_model do
        {:reply, {:error, "llm_model cannot be nil"}, state}
      else
        do_update_config(opts, state)
      end
    else
      do_update_config(opts, state)
    end
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    config = %{
      max_concurrency: state.max_concurrency,
      max_tool_concurrency: state.max_tool_concurrency,
      agent_max_retries: state.agent_max_retries,
      max_agent_depth: state.max_depth,
      max_retries: state.max_retries,
      llm_model: state.llm_model,
      paused: state.paused,
      sandbox_mode: state.sandbox_mode,
      sandbox_resources: state.sandbox_resources
    }

    {:reply, config, state}
  end

  @impl true
  def handle_call({:get_config, key}, _from, state) do
    value =
      case key do
        :max_concurrency -> state.max_concurrency
        :max_tool_concurrency -> state.max_tool_concurrency
        :agent_max_retries -> state.agent_max_retries
        :max_agent_depth -> state.max_depth
        :max_retries -> state.max_retries
        :llm_model -> state.llm_model
        :paused -> state.paused
        :sandbox_mode -> state.sandbox_mode
        :sandbox_resources -> state.sandbox_resources
        _ -> nil
      end

    {:reply, value, state}
  end

  @impl true
  def handle_call(:pause, _from, %State{} = state) do
    if state.paused do
      {:reply, :ok, state}
    else
      Logger.info("AgentScheduler: Pausing scheduler — no new slots or agents will be granted")
      state = struct(state, paused: true)
      EvoGit.AgentScheduler.PubSub.broadcast_config_updated()
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:resume, _from, %State{} = state) do
    if state.paused do
      Logger.info("AgentScheduler: Resuming scheduler — granting pending slots and dispatching queued agents")
      state = struct(state, paused: false)
      {state, status_updates} = Slots.grant_pending_on_resume(state)
      apply_status_updates(status_updates)
      state = Dispatch.dispatch_queued_agents(state)
      EvoGit.AgentScheduler.PubSub.broadcast_config_updated()
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:paused?, _from, state) do
    {:reply, state.paused, state}
  end

  @impl true
  def handle_call({:spawn_sub_agents, parent_id, specs}, from, state) do
    if state.paused do
      {:reply, {:error, :scheduler_paused}, state}
    else
      state = Worktrees.ensure_initialized(state)
      {:ok, parent} = get_sched_meta(parent_id)

      Subagents.spawn_validated_subagents(parent_id, parent, specs, from, state)
    end
  end

  # --- LLM and Tool Slot Management (delegated to Slots module) ---

  @impl true
  def handle_call({:request_llm_slot, agent_id}, from, state) do
    case Slots.handle_request_llm_slot(agent_id, from, state) do
      {:reply, :ok, new_state, status_updates} ->
        apply_status_updates(status_updates)
        {:reply, :ok, new_state}

      {:noreply, new_state, status_updates} ->
        apply_status_updates(status_updates)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:release_llm_slot, agent_id}, _from, state) do
    {:reply, :ok, new_state, status_updates} = Slots.handle_release_llm_slot(agent_id, state)
    apply_status_updates(status_updates)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:report_llm_error, agent_id, error_type}, _from, state) do
    {:reply, :ok, new_state, status_updates} = Slots.handle_report_llm_error(agent_id, error_type, state)
    apply_status_updates(status_updates)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:request_tool_slot, agent_id}, from, state) do
    case Slots.handle_request_tool_slot(agent_id, from, state) do
      {:reply, :ok, new_state, status_updates} ->
        apply_status_updates(status_updates)
        {:reply, :ok, new_state}

      {:noreply, new_state, status_updates} ->
        apply_status_updates(status_updates)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:release_tool_slot, agent_id}, _from, state) do
    {:reply, :ok, new_state, status_updates} = Slots.handle_release_tool_slot(agent_id, state)
    apply_status_updates(status_updates)
    {:reply, :ok, new_state}
  end

  # --- Private Helpers ---

  defp do_update_config(opts, %State{} = state) do
    # Capture old values for slot adjustment
    old_max_concurrency = state.max_concurrency
    old_max_tool_concurrency = state.max_tool_concurrency

    # Apply all field updates
    state =
      state
      |> maybe_update(:max_concurrency, opts)
      |> maybe_update(:agent_max_retries, opts)
      |> maybe_update(:max_depth, opts)
      |> maybe_update(:llm_model, opts)
      |> maybe_update(:max_retries, opts)
      |> maybe_update(:max_tool_concurrency, opts)
      |> maybe_update(:sandbox_mode, opts)
      |> maybe_update(:sandbox_resources, opts)

    # Adjust LLM slot counter if max_concurrency changed
    state =
      if state.max_concurrency != old_max_concurrency do
        delta = state.max_concurrency - old_max_concurrency
        new_available = max(state.llm_slots_available + delta, 0)
        struct(state, llm_slots_available: new_available)
      else
        state
      end

    # Adjust tool slot counter if max_tool_concurrency changed
    state =
      if state.max_tool_concurrency != old_max_tool_concurrency do
        delta = state.max_tool_concurrency - old_max_tool_concurrency
        new_available = max(state.tool_slots_available + delta, 0)
        struct(state, tool_slots_available: new_available)
      else
        state
      end

    # Propagate sandbox resource changes to the live slice
    state =
      if Keyword.has_key?(opts, :sandbox_resources) do
        resources = Keyword.get(opts, :sandbox_resources)
        case EvoGit.SandboxSlice.update_resources(resources) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("Failed to update sandbox slice resources: #{inspect(reason)}")
        end
        state
      else
        state
      end

    # Grant any newly-available slots to waiting agents
    {state, status_updates} = Slots.grant_pending_on_resume(state)
    apply_status_updates(status_updates)

    Logger.info(
      "AgentScheduler: Config updated — max_concurrency: #{state.max_concurrency}, " <>
        "max_tool_concurrency: #{state.max_tool_concurrency}, " <>
        "agent_max_retries: #{state.agent_max_retries}, max_depth: #{state.max_depth}"
    )

    EvoGit.AgentScheduler.PubSub.broadcast_config_updated()

    {:reply, :ok, state}
  end

  # Retry LLM waiting queue after backoff expiry (delegated to Slots module)
  @impl true
  def handle_info(:retry_llm_waiting, state) do
    {:noreply, state, status_updates} = Slots.handle_retry_llm_waiting(state)
    apply_status_updates(status_updates)
    {:noreply, state}
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
        meta = Dispatch.auto_commit_fallback(agent_id, meta)

        put_sched_meta(agent_id, %{meta | result_sent: true})

        if meta.parent_id do
          Subagents.store_sub_result(meta.parent_id, agent_id, result)
          state = Subagents.maybe_resume_parent(state, meta.parent_id)
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
          state = Lifecycle.recycle_agent(state, agent_id)
          state = Dispatch.process_queue(state)
          {:noreply, state}
        else
          Lifecycle.handle_agent_crash(state, agent_id, reason)
        end
    end
  end

  # --- Config Helpers ---

  defp maybe_update(state, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> struct(state, [{key, value}])
      :error -> state
    end
  end

  # --- ETS Helpers (Agent State Table) ---

  defp put_agent_state(agent_id, agent_state) do
    :ets.insert(@agent_table, {agent_id, agent_state})
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
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
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end

  # Applies a list of {agent_id, status} updates to the ETS SchedMeta table.
  # Used by slot management to reflect blocked/running status in the dashboard.
  defp apply_status_updates(status_updates) do
    Enum.each(status_updates, fn {agent_id, new_status} ->
      case get_sched_meta(agent_id) do
        {:ok, meta} ->
          # Only update running agents to blocked (don't overwrite :waiting or :ready)
          # and only restore to :running from :blocked
          if (new_status == :blocked and meta.status == :running) or
               (new_status == :running and meta.status == :blocked) do
            put_sched_meta(agent_id, %{meta | status: new_status})
          end

        :error ->
          :ok
      end
    end)
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

end
