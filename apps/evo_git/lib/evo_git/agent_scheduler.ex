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
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State
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
    repo_id = Process.get(:evogit_repo_id, :primary)
    GenServer.call(__MODULE__, {:repo_root_for, repo_id})
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

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    :ets.new(@agent_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@sched_table, [:named_table, :public, :set, read_concurrency: true])

    config = EvoGit.Config.resolve()

    # Load API keys from credentials.toml into environment variables
    _credentials = EvoGit.Config.credentials()

    scheduler_config = Map.get(config, :scheduler, %{})

    max_concurrency = Map.get(scheduler_config, :max_concurrency, 3)
    max_tool_concurrency = Map.get(scheduler_config, :max_tool_concurrency, 2)
    agent_max_retries = Map.get(scheduler_config, :agent_max_retries, 3)
    max_depth = Map.get(scheduler_config, :max_agent_depth, 8)
    max_retries = Map.get(scheduler_config, :max_retries, 15)
    llm_model = Map.get(config, :llm, %{}) |> Map.get(:model)

    # Validate llm_model is configured
    unless llm_model do
      raise """
      LLM model not configured. Please set llm.model in your config file:

      ~/.config/evogit/config.toml:

          [llm]
          model = "provider:model_name"

      Example models:
      - "anthropic:claude-sonnet-4-20250514"
      - "google:gemini-2.0-flash-exp"
      - "zai_coding_plan:glm-5.1"

      See documentation for the full list of supported models.
      """
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
       repo_root: nil,
       repos: %{},
       base_sha: nil,
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
       next_task_id: 1
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

    # Merge with existing repos
    repos = Map.merge(state.repos, repos_map)

    Logger.info(
      "AgentScheduler: Registered #{map_size(repos_map)} foreign repo(s): #{inspect(Map.keys(repos_map))}"
    )

    {:reply, :ok, %{state | repos: repos}}
  end

  @impl true
  def handle_call(:get_foreign_repos, _from, state) do
    repos = Map.values(state.repos)
    {:reply, repos, state}
  end

  @impl true
  def handle_call({:register_foreign_repo, repo}, _from, state) do
    if Map.has_key?(state.repos, repo.id) do
      {:reply, {:error, {:already_exists, repo.id}}, state}
    else
      repos = Map.put(state.repos, repo.id, repo)
      Logger.info("AgentScheduler: Registered foreign repo #{repo.id} at #{repo.root}")
      {:reply, :ok, %{state | repos: repos}}
    end
  end

  @impl true
  def handle_call({:unregister_foreign_repo, repo_id}, _from, state) do
    cond do
      repo_id == :primary ->
        {:reply, {:error, :cannot_unregister_primary}, state}

      not Map.has_key?(state.repos, repo_id) ->
        {:reply, {:error, {:not_found, repo_id}}, state}

      true ->
        repos = Map.delete(state.repos, repo_id)
        Logger.info("AgentScheduler: Unregistered foreign repo #{repo_id}")
        {:reply, :ok, %{state | repos: repos}}
    end
  end

  @impl true
  def handle_call({:repo_root_for, repo_id}, _from, state) do
    case Map.get(state.repos, repo_id) do
      %ForeignRepo{root: root} ->
        {:reply, root, state}

      nil ->
        # Fallback: if repo_id is :primary and repos not yet populated, use repo_root
        if repo_id == :primary and state.repo_root do
          {:reply, state.repo_root, state}
        else
          {:reply, {:error, {:unknown_repo, repo_id}}, state}
        end
    end
  end

  @impl true
  def handle_call({:run_agent, spec}, from, state) do
    # Extract repo_path from the spec's phylo_node
    repo_path = spec.phylo_node.repo
    state = Worktrees.ensure_initialized(state, repo_path)
    task_id = state.next_task_id
    {agent_id, state} = register_agent(state, spec, from, _parent_id = nil, _depth = 0, task_id)
    state = %{state | next_task_id: task_id + 1}
    Logger.info("AgentScheduler: Spawning top-level agent #{agent_id} (task #{task_id})")

    if state.paused do
      # Queue the agent for dispatch when resumed
      state = %{state | queue: :queue.in(agent_id, state.queue)}
      {:noreply, state}
    else
      state = try_dispatch(state, agent_id)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:update_config, opts}, _from, state) do
    has_active_agents = state.ref_to_agent != %{} or not :queue.is_empty(state.queue)

    concurrency_changed =
      Keyword.has_key?(opts, :max_concurrency) and
        Keyword.get(opts, :max_concurrency) != state.max_concurrency

    # Validate llm_model if being updated
    if Keyword.has_key?(opts, :llm_model) do
      new_model = Keyword.get(opts, :llm_model)

      unless new_model do
        {:reply, {:error, "llm_model cannot be nil"}, state}
      else
        do_update_config(opts, state, concurrency_changed, has_active_agents)
      end
    else
      do_update_config(opts, state, concurrency_changed, has_active_agents)
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
      paused: state.paused
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
      state = dispatch_queued_agents(state)
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
    state = Worktrees.ensure_initialized(state)
    {:ok, parent} = get_sched_meta(parent_id)

    spawn_validated_subagents(parent_id, parent, specs, from, state)
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

  defp do_update_config(opts, state, concurrency_changed, has_active_agents) do
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
        |> maybe_update(:max_tool_concurrency, opts)

      # If concurrency changed, tear down the pool so it's lazily re-created
      state =
        if concurrency_changed and state.initialized do
          Worktrees.teardown_worktrees(state)
        else
          state
        end

      Logger.info(
        "AgentScheduler: Config updated — max_concurrency: #{state.max_concurrency}, " <>
          "max_tool_concurrency: #{state.max_tool_concurrency}, " <>
          "agent_max_retries: #{state.agent_max_retries}, max_depth: #{state.max_depth}"
      )

      {:reply, :ok, state}
    end
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
    Logger.info("AgentScheduler: Agent #{parent_id} yielding to spawn #{length(specs)} subagents")

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
        {sub_id, acc} =
          register_agent(acc, spec, _from = nil, parent_id, parent.depth + 1, parent.task_id)

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

  defp validate_spatial_contract_for_spec(
         _parent_id,
         %{context_node: parent_context, repo_id: parent_repo_id},
         spec
       ) do
    # Cross-repo delegation: foreign repos are independent trees, skip spatial check
    if spec.repo_id != parent_repo_id do
      :ok
    else
      parent_path = EvoGit.Agent.Tools.Shared.normalize_relpath(parent_context.path)
      child_type = spec.agent_module.agent_type()
      child_path = EvoGit.Agent.Tools.Shared.normalize_relpath(spec.context_node.path)
      validate_spawn_spatiality(:read_write, parent_path, child_type, child_path)
    end
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

  # --- Agent Registry ---

  defp register_agent(state, spec, from, parent_id, depth, task_id) do
    id = state.next_agent_id

    # Compute per-task local agent ID (display/branch naming only)
    task_local_id = Map.get(state.task_local_counters, task_id, 1)
    state = %{state | task_local_counters: Map.put(state.task_local_counters, task_id, task_local_id + 1)}

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
      max_depth: state.max_depth,
      parent_id: parent_id,
      objective: spec.objective,
      repo_id: spec.repo_id,
      task_local_id: task_local_id
    })

    # Scheduler metadata table: scheduling bookkeeping
    put_sched_meta(id, %SchedMeta{
      id: id,
      depth: depth,
      status: :pending,
      from: from,
      parent_id: parent_id,
      task_id: task_id,
      spec: spec
    })

    state = %{state | next_agent_id: id + 1}
    {id, state}
  end

  # --- Dispatch ---

  defp try_dispatch(state, agent_id) do
    {:ok, meta} = get_sched_meta(agent_id)
    {:ok, agent_state} = get_agent_state(agent_id)
    retries = meta.retries
    spec = meta.spec
    task_id = meta.task_id
    task_local_id = agent_state.task_local_id

    # Create a persistent worktree for this agent: worker_T<task_id>_A<task_local_id>
    # Determine repo root from the agent's spec data, with repos map as fallback
    agent_repo_root = resolve_agent_repo_root(spec, state)

    worktree_path = Path.join([agent_repo_root, ".evogit/workers", "worker_T#{task_id}_A#{task_local_id}"])

    # Create the worktree if it doesn't exist (e.g., on first dispatch)
    newly_created =
      unless File.exists?(worktree_path) do
        commit_sha = spec.phylo_node.current_commit
        branch_name = "evogit-agent-T#{task_id}-A#{task_local_id}"

        case Git.add_worktree(agent_repo_root, worktree_path, commit_sha, branch_name) do
          {:ok, _} ->
            Logger.info(
              "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} (T#{task_id}-A#{task_local_id}) on branch #{branch_name}"
            )

          {:error, _, msg} ->
            Logger.error("AgentScheduler: Failed to create worktree #{worktree_path}: #{msg}")
            raise "Failed to create worktree for agent #{agent_id}"
        end

        true
      else
        false
      end

    Worktrees.assign_and_prepare_worktree(agent_id, worktree_path)

    # Run worktree init script on first creation only, and only for the primary repo
    # (foreign repos are independent and should not inherit the primary repo's init script)
    if newly_created and spec.repo_id == :primary do
      Worktrees.run_init_script(agent_repo_root, worktree_path)
    end

    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, meta.depth)

        Process.put(:evogit_repo_root, agent_repo_root)
        Process.put(:evogit_repo_id, spec.repo_id)
        Process.put(:repo_path, worktree_path)

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        else
          Logger.info(
            "AgentScheduler: Agent #{agent_id} starting execution in worktree #{worktree_path}"
          )
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

  # Resolves the repo root for an agent from its spec data.
  # For primary repo agents, derives from phylo_node.repo (which is either
  # the repo root for top-level agents or a worktree path for subagents).
  # For foreign repo agents, falls back to the state.repos map.
  defp resolve_agent_repo_root(spec, state) do
    if spec.repo_id == :primary do
      # spec.phylo_node.repo is either:
      # - A repo root (e.g., "/home/bill/Source/evoclass") for top-level agents
      # - A worktree path (e.g., ".../.evogit/workers/worker_T1_A1") for subagents
      # Derive the repo root by stripping the worktree suffix if present.
      case String.split(spec.phylo_node.repo, "/.evogit/workers/", parts: 2) do
        [root, _rest] -> root
        [_] -> spec.phylo_node.repo
      end
    else
      # Foreign repo — resolve from the repos map
      case Map.get(state.repos, spec.repo_id) do
        %ForeignRepo{root: root} -> root
        nil -> state.repo_root
      end
    end
  end

  # --- Auto-Commit Fallback ---

  defp auto_commit_fallback(agent_id, %{status: :running, worktree: wt} = meta)
       when not is_nil(wt) do
    case Git.status(wt) do
      {:ok, ""} ->
        Worktrees.sync_current_commit(agent_id, meta)

      {:ok, _changes} ->
        Logger.info("AgentScheduler: Auto-committing pending changes for agent #{agent_id}")

        {:ok, prev_sha} = Git.rev_parse(wt)

        Git.run(["add", "--all"], wt)
        objective = meta.spec.objective || "task"
        Git.commit(wt, "Agent: #{objective} (auto-commit)")

        # Log diff stats for the auto-commit
        case Git.rev_parse(wt) do
          {:ok, ^prev_sha} ->
            Logger.debug(
              "AgentScheduler: Auto-commit for agent #{agent_id} resulted in no new commit"
            )

          {:ok, new_sha} ->
            case Git.diff_stat(wt, prev_sha, new_sha) do
              {:ok, stats} when stats != "" ->
                Logger.info("AgentScheduler: Auto-commit stats for agent #{agent_id}:\n#{stats}")

              _ ->
                :ok
            end
        end

        Worktrees.sync_current_commit(agent_id, meta)

      _ ->
        meta
    end
  end

  defp auto_commit_fallback(_agent_id, meta), do: meta

  # --- Queue Processing ---

  # Drains the agent queue after a resume, dispatching each queued agent.
  defp dispatch_queued_agents(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, agent_id}, rest_queue} ->
        state = %{state | queue: rest_queue}
        state = try_dispatch(state, agent_id)
        dispatch_queued_agents(state)

      {:empty, _} ->
        state
    end
  end

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
      Worktrees.delete(meta.worktree, state.repo_root)
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

      # Wrap dispatch in try/rescue to prevent GenServer crash on worktree creation failure
      state =
        try do
          try_dispatch(state, agent_id)
        rescue
          e ->
            Logger.error(
              "AgentScheduler: Failed to retry dispatch for agent #{agent_id}: #{inspect(e)}. " <>
                "Treating as permanent failure."
            )

            # Clean up and permanently fail the agent
            if meta.worktree do
              Worktrees.delete(meta.worktree, state.repo_root)
            end

            delete_agent_state(agent_id)
            delete_sched_meta(agent_id)
            updated_state = %{state | running_count: state.running_count - 1}

            updated_state =
              if meta.parent_id do
                store_sub_result(meta.parent_id, agent_id, {:error, :worktree_creation_failed})
                maybe_resume_parent(updated_state, meta.parent_id)
              else
                GenServer.reply(meta.from, {:error, :worktree_creation_failed})
                updated_state
              end

            updated_state
        end

      state = process_queue(state)
      {:noreply, state}
    else
      msg =
        "Agent #{agent_id} failed after #{state.agent_max_retries} retries. Last: #{inspect(reason)}"

      Logger.error("AgentScheduler: #{msg}")

      # Delete the agent's persistent worktree on permanent failure
      if meta.worktree do
        Worktrees.delete(meta.worktree, state.repo_root)
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

end
