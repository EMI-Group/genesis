defmodule EvoGit.AgentScheduler do
  @moduledoc """
  Global agent scheduler managing agent lifecycles and scheduling.

  The scheduler is ONLY responsible for scheduling. Callers provide a
  structured agent specification — spatial state (ContextNode), temporal state
  (PhyloGraphNode), agent module, and objective — and the scheduler handles:

  - Spawning and tracking agents (both top-level and subagents)
  - Transitioning agents between :pending, :running, :waiting, and :ready states
  - LLM and tool execution slot management with concurrency control and backoff

  The scheduler NEVER touches worktree I/O. Worktree lifecycle is owned by
  `EvoGit.AgentScheduler.WorktreeManager`: the agent Runner requests a fresh
  worktree (1-hour call timeout; WorktreeManager offloads the I/O to a spawned
  task), WorktreeManager monitors the agent process and destroys the worktree
  on exit.

  ## ETS Tables

  Agent data is split across two ETS tables with clear ownership:

  - **`:evogit_agent_state`** — Owned by agent processes. Contains the agent's
    live spatial/temporal state (`context_node`, `phylo_node`).
    The scheduler writes initial values on dispatch; agents update `phylo_node`
    after each commit via `update_phylo_node/2`.

  - **`:evogit_sched_meta`** — Owned by the scheduler process. Contains all
    scheduling bookkeeping: status, worktree assignment, task refs, parent/child
    tracking, retry counts, etc. Agents do not write to this table.

  ## Slot Management

  The scheduler manages two independent slot pools:

  - **LLM slots** (`default_llm_max_concurrency`) — Default per-LLM concurrency:
    controls how many agents can make concurrent LLM calls (the fallback when a
    model profile doesn't specify its own). Includes a global backoff mechanism
    for rate limit errors (60-second cooldown).

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
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.AgentSpec
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
  Returns the repo root path stored in the current agent's process dictionary.
  Returns nil if not in a scheduled agent.
  """
  def current_repo_root do
    Process.get(:genesis_repo_root)
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
  with any of: `:default_llm_max_concurrency`, `:max_tool_concurrency`,
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

      AgentScheduler.get_config(:default_llm_max_concurrency)
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
  def get_agent_state(agent_id), do: Store.get_agent_state(agent_id)

  @doc """
  Updates the phylo_node for the given agent in the agent state table.
  Called by agents after they commit changes to keep state in sync.
  """
  @spec update_phylo_node(pos_integer(), PhyloGraphNode.t()) :: :ok | :error
  def update_phylo_node(agent_id, %PhyloGraphNode{} = phylo_node) do
    {:ok, agent_state} = Store.get_agent_state(agent_id)
    updated = %{agent_state | phylo_node: phylo_node}
    Store.put_agent_state(agent_id, updated)
  end

  @doc """
  Sends a user message to a running agent.

  The message is appended to the agent's `pending_user_messages` queue and will
  be injected into the agent's LLM context at the top of its next turn (as a
  user-role message). This serializes the append through the GenServer to avoid
  concurrent-write races.

  Returns `:ok` on success, or `{:error, :not_found}` if the agent doesn't exist.
  """
  @spec send_user_message(pos_integer(), String.t()) :: :ok | {:error, :not_found}
  def send_user_message(agent_id, message) when is_binary(message) do
    GenServer.call(__MODULE__, {:send_user_message, agent_id, message})
  end

  @doc """
  Returns the foreign repo commits map for the given agent's SchedMeta.
  Used by agents to track the latest known commit per foreign repo from
  previous subagent completions.
  """
  @spec get_foreign_repo_commits(pos_integer()) :: %{atom() => String.t()}
  def get_foreign_repo_commits(agent_id) do
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} -> meta.foreign_repo_commits
      :error -> %{}
    end
  end

  @doc """
  Requests an LLM execution slot from the scheduler. Blocks the caller until a slot
  is granted (respects default_llm_max_concurrency and per-model concurrency).
  Returns :ok when granted. A 0-capacity model (peak hard-pause) does NOT fail
  fast — the request enqueues and blocks exactly like the paused-scheduler case
  and is granted when capacity returns. Returns `{:error, :cancelled}` when the
  agent is purged from the waiting queue (force-kill / graceful cancel).
  """
  @spec request_llm_slot(pos_integer(), timeout()) :: :ok | {:error, :cancelled}
  def request_llm_slot(agent_id, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:request_llm_slot, agent_id}, timeout)
  end

  @doc """
  Releases an LLM execution slot back to the scheduler. Call this after the LLM
  call completes (success or failure).

  Uses `GenServer.cast` (fire-and-forget) rather than `GenServer.call` to avoid
  blocking the agent on slot release. A synchronous call here can time out when
  the scheduler GenServer is busy processing another synchronous call (e.g.,
  worktree initialization in `handle_call({:run_agent, ...})`), causing agent
  crashes with 5-second `:timeout` exits.
  """
  @spec release_llm_slot(pos_integer()) :: :ok
  def release_llm_slot(agent_id) do
    GenServer.cast(__MODULE__, {:release_llm_slot, agent_id})
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

  Uses `GenServer.cast` (fire-and-forget) rather than `GenServer.call` to avoid
  blocking the agent on slot release. See `release_llm_slot/1` for rationale.
  """
  @spec release_tool_slot(pos_integer()) :: :ok
  def release_tool_slot(agent_id) do
    GenServer.cast(__MODULE__, {:release_tool_slot, agent_id})
  end

  @doc """
  Acquires an LLM slot, executes the given function, and releases the slot afterward.

  The slot is always released via an `after` block, even if the function raises.
  Rate-limit error reporting should be handled by the caller inside the callback,
  before raising — the `after` block runs after any exception.

  The slot request BLOCKS until the slot is granted (`GenServer.call` with an
  `:infinity` timeout): if all slots are busy, the model is in backoff, the
  scheduler is paused, or the model has 0 capacity (peak hard-pause), the
  request is enqueued and the caller waits. A queued request is granted when
  capacity returns — including a 0-capacity model on peak exit, which flows
  through `update_config` → the end-of-update `grant_pending_on_resume` sweep.

  A non-`:ok` result from the slot request (`{:error, :cancelled}` when the
  agent is purged from the waiting queue during a force-kill or graceful
  cancel) raises instead of proceeding without a slot.

  The raise is deliberate: callers (`ToolDispatch.call_llm_with_retry/5`, context
  compression) already depend on a non-`:ok` slot result being an exception, and
  the retry loop is configured with `rescue_only: []` so the raise propagates on
  the first attempt with zero retries (a retried cancelled agent would be
  pointless — the crash hands it to the scheduler's crash-retry/cancel machinery).
  """
  @spec with_llm_slot(pos_integer(), (-> result)) :: result when result: var
  def with_llm_slot(agent_id, fun) when is_function(fun, 0) do
    case request_llm_slot(agent_id) do
      :ok ->
        # try/after (not rescue) — guarantees slot release even if fun raises.
        # The exception is NOT swallowed; it's re-raised after cleanup.
        try do
          fun.()
        after
          release_llm_slot(agent_id)
        end

      other ->
        raise "LLM slot request failed for agent #{agent_id}: #{inspect(other)}"
    end
  end

  @doc """
  Acquires a tool execution slot, executes the given function, and releases the slot afterward.
  Ensures the slot is released even if the function raises.

  A non-`:ok` result from the slot request (e.g. `{:error, :cancelled}` when the
  agent is purged from the waiting queue during a force-kill) raises instead of
  proceeding without a slot.

  Returns the result of `fun.()`.
  """
  @spec with_tool_slot(pos_integer(), (-> result)) :: result when result: var
  def with_tool_slot(agent_id, fun) when is_function(fun, 0) do
    case request_tool_slot(agent_id) do
      :ok ->
        # try/after (not rescue) — guarantees slot release even if fun raises.
        # The exception is NOT swallowed; it's re-raised after cleanup.
        try do
          fun.()
        after
          release_tool_slot(agent_id)
        end

      other ->
        raise "Tool slot request failed for agent #{agent_id}: #{inspect(other)}"
    end
  end

  @doc """
  Force-kills all agents belonging to a task identified by the caller PID.

  When the EvoDash Task process (which called `run_agent/2`) is killed,
  its PID is used to find the matching top-level agent. All agents sharing
  the same scheduler `task_id` (including subagents) are then cancelled:
  their Task processes are killed, worktrees deleted, ETS entries removed,
  and any blocked callers are replied to with `{:error, :cancelled}`.

  This is the BRUTAL cancellation path (no grace period) — used by
  `TaskRegistry.force_kill_task/1`. Graceful cancellation is
  `begin_graceful_cancel/1`.

  Returns `:ok` if agents were found and cancelled, or `{:error, :not_found}`.
  """
  @spec force_kill_task_agents(pid()) :: :ok | {:error, :not_found}
  def force_kill_task_agents(caller_pid) when is_pid(caller_pid) do
    GenServer.call(__MODULE__, {:force_kill_task_agents, caller_pid})
  end

  # The cancel notification message injected into every agent of a task that
  # is being gracefully cancelled. The runner drains pending user messages at
  # the top of each turn, so the agent sees this before its next LLM call.
  @cancel_message "The task is being cancelled by the user. Please immediately save your work: commit any uncommitted changes, then call complete_task with a summary of what was accomplished. You are in a grace period and must call complete_task now."

  @doc """
  Returns the cancel notification message text injected into agents of a task
  that is being gracefully cancelled.
  """
  @spec cancel_message() :: String.t()
  def cancel_message, do: @cancel_message

  @doc """
  Begins a graceful cancel for the given task.

  Called by `EvoGit.TaskRegistry.cancel_task/1` once the task's status has
  been set to `:cancelling`. The handler:

  1. Registers the task_id in the `:evogit_cancelling_tasks` marker (so
     `run_agent` refuses new root agents for the task and newly registered
     agents are immediately put into cancel-grace).
  2. Finds every agent of the task (SchedMeta.task_id scan) and, for each
     agent with a live ETS state, appends the cancel notification message to
     its pending-user-messages queue and sets `cancel_requested = true` — the
     runner enters the grace period at the top of its next turn.

  Returns `:ok`.
  """
  @spec begin_graceful_cancel(String.t()) :: :ok
  def begin_graceful_cancel(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:begin_graceful_cancel, task_id})
  end

  @doc """
  Removes a task from the `:evogit_cancelling_tasks` marker.

  Called by `EvoGit.TaskRegistry` when a cancelling task reaches a terminal
  state (`:completed`/`:failed`/`:cancelled`) so the marker doesn't leak.
  Idempotent — deleting a non-member is a no-op. Returns `:ok`.
  """
  @spec clear_cancelling_task(String.t()) :: :ok
  def clear_cancelling_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:clear_cancelling_task, task_id})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    # ETS tables (:evogit_agent_state, :evogit_sched_meta, :evogit_archive_records)
    # are created by EvoGit.Application before the scheduler starts so they survive
    # scheduler crashes. Defensive check: warn if any table is unexpectedly missing.
    for table <- [@agent_table, @sched_table, :evogit_archive_records] do
      if :ets.whereis(table) == :undefined do
        Logger.warning(
          "AgentScheduler: ETS table #{inspect(table)} is missing — agents may not function correctly"
        )
      end
    end

    config = EvoGit.Config.resolve()

    # Load API keys from credentials.toml into environment variables
    _credentials = EvoGit.Config.credentials()

    %{
      scheduler: scheduler_config,
      sandbox: sandbox_config
    } = config

    %{
      max_tool_concurrency: max_tool_concurrency,
      agent_max_retries: agent_max_retries,
      max_agent_depth: max_depth,
      max_retries: max_retries,
      max_turns: max_turns,
      max_turns_root: max_turns_root
    } = scheduler_config

    # Load model profiles from config (Step 2: per-model slot pools).
    # Each profile becomes its own slot pool. Falls back to a single
    # legacy profile derived from the flat llm.model / scheduler.default_llm_max_concurrency
    # config keys when no [[llm.models]] profiles are configured.
    raw_model_profiles = EvoGit.Config.Schema.model_profiles(config)

    model_profiles =
      case raw_model_profiles do
        [] ->
          # Legacy path: build a single "default" profile from flat config
          [EvoGit.Config.Schema.LLM.build_legacy_default_profile(config)]

        profiles ->
          profiles
      end

    # Build per-model pool state from profiles
    pool_state = State.from_model_profiles(model_profiles)

    # Override default model/params from flat config if profiles don't specify them.
    # The flat llm.model still serves as the default model string.
    default_model =
      case List.first(model_profiles) do
        %{model: model} when model != nil -> model
        _ -> config[:llm] |> Map.get(:model)
      end

    default_params =
      case List.first(model_profiles) do
        nil -> EvoGit.Config.Schema.llm_generation_params(config)
        profile -> EvoGit.Config.Schema.llm_generation_params(profile)
      end

    sandbox_mode = Map.get(sandbox_config, :mode)
    sandbox_resources = Map.get(sandbox_config, :resources)
    sandbox_process_resources = Map.get(sandbox_config, :process)

    # Warn (but don't crash) if no model is configured at all
    unless default_model do
      Logger.warning("""
      AgentScheduler: LLM model not configured. Agent execution will be unavailable until configured.
      Please set llm.model in your config file:

      ~/.config/genesis/config.toml:

          [llm]
          model = "provider:model_name"

      Example models:
      - "anthropic:claude-sonnet-4-20250514"
      - "google:gemini-2.0-flash-exp"
      - "zai:glm-5.1"

      You can also configure this via the Settings page in the dashboard.
      """)
    end

    # Allow opts to override (for backward compat with CLI --flags)
    max_tool_concurrency = Keyword.get(opts, :max_tool_concurrency, max_tool_concurrency)
    agent_max_retries = Keyword.get(opts, :agent_max_retries, agent_max_retries)
    max_depth = Keyword.get(opts, :max_depth, max_depth)
    max_retries = Keyword.get(opts, :max_retries, max_retries)
    max_turns = Keyword.get(opts, :max_turns, max_turns)
    max_turns_root = Keyword.get(opts, :max_turns_root, max_turns_root)

    # Apply flat-config overrides on top of profile-derived state
    default_model = Keyword.get(opts, :llm_model, default_model)
    default_params = Keyword.get(opts, :llm_generation_params, default_params)

    default_llm_max_concurrency =
      Keyword.get(opts, :default_llm_max_concurrency, pool_state.default_llm_max_concurrency)

    state = %State{
      pool_state
      | default_llm_max_concurrency: default_llm_max_concurrency,
        agent_max_retries: agent_max_retries,
        max_depth: max_depth,
        llm_model: default_model,
        llm_generation_params: default_params,
        max_retries: max_retries,
        max_turns: max_turns,
        max_turns_root: max_turns_root,
        next_agent_id: 1,
        ref_to_agent: %{},
        queue: :queue.new(),
        tool_waiting: :queue.new(),
        max_tool_concurrency: max_tool_concurrency,
        sandbox_mode: sandbox_mode,
        sandbox_resources: sandbox_resources,
        sandbox_process_resources: sandbox_process_resources
    }

    # Best-effort Finch pool reconciliation at boot (pools are lazy — normally a no-op).
    total =
      EvoGit.ReqLLMPool.effective_concurrency(
        state.model_concurrency,
        state.default_llm_max_concurrency
      )

    EvoGit.ReqLLMPool.reconcile(total)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_max_depth, _from, %State{} = state) do
    {:reply, state.max_depth, state}
  end

  @impl true
  def handle_call({:run_agent, _spec}, _from, %State{model_profiles: []} = state) do
    Logger.warning("AgentScheduler: Rejecting agent spawn — no model profiles configured")
    {:reply, {:error, :llm_not_configured}, state}
  end

  def handle_call(
        {:run_agent, _spec},
        _from,
        %State{llm_model: nil, model_profiles: profiles} = state
      )
      when profiles == [] or profiles == nil do
    Logger.warning("AgentScheduler: Rejecting agent spawn — LLM model not configured")
    {:reply, {:error, :llm_not_configured}, state}
  end

  def handle_call({:run_agent, spec}, from, %State{} = state) do
    task_id =
      spec.opts[:task_id] || :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    # Graceful-cancel guard: if the task is in the cancelling marker, refuse to
    # spawn the root agent immediately — BEFORE Dispatch.register_agent/dispatch.
    # This blocks Genesis Mode B's second sequential root agent (which shares
    # the first root's task_id) from spawning after the first root completes
    # during a cancel.
    if cancelling_task?(task_id) do
      Logger.info(
        "AgentScheduler: Refusing to spawn root agent for task #{task_id} — task is being cancelled"
      )

      {:reply, {:error, :cancelled}, state}
    else
      # Defensive per-task archive reset: any leftover records from a previous run
      # sharing this task_id (e.g., a crash before the task completed) must not leak
      # into this run's collected archive.
      Lifecycle.clear_archive_records(task_id)

      repo_root = Dispatch.resolve_agent_repo_root(spec, state)
      task_number = Dispatch.next_task_number(repo_root)

      {agent_id, state} =
        Dispatch.register_agent(
          state,
          spec,
          from,
          _parent_id = nil,
          _depth = 0,
          task_id,
          task_number
        )

      Logger.info(
        "AgentScheduler: Spawning top-level agent #{agent_id} (task #{task_id}, number #{task_number})"
      )

      if state.paused do
        # Queue the agent for dispatch when resumed
        state = %{state | queue: :queue.in(agent_id, state.queue)}
        {:noreply, state}
      else
        state = Dispatch.try_dispatch(state, agent_id)
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_call({:force_kill_task_agents, caller_pid}, _from, %State{} = state) do
    # 1. Scan :evogit_sched_meta ETS to find top-level agent whose meta.from contains caller_pid
    #    The meta.from is a GenServer.from() tuple: {pid, ref} where pid is the calling process
    top_level_agent =
      Store.list_sched_meta()
      |> Enum.find(fn
        {_id, %SchedMeta{depth: 0, from: {pid, _}}} -> pid == caller_pid
        _ -> false
      end)

    case top_level_agent do
      nil ->
        {:reply, {:error, :not_found}, state}

      {_id, %SchedMeta{task_id: task_id}} ->
        Logger.info(
          "AgentScheduler: Cancelling all agents for task #{task_id} (caller PID #{inspect(caller_pid)})"
        )

        # 2. Find ALL agents with this task_id
        agent_ids =
          Store.list_sched_meta()
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
          :queue.filter(
            fn aid ->
              not MapSet.member?(cancel_set, aid)
            end,
            state.queue
          )

        state = %{state | queue: queue}

        # 5. Purge from slot waiting queues (replies {:error, :cancelled} to blocked callers)
        {state, _status_updates} = Slots.purge_agents_from_queues(state, cancel_set)

        # 5.5 Release LLM/tool slots held by cancelled agents.
        #     Step 3 made the :DOWN handler a no-op for these agents, so the normal
        #     slot release path (Slots.release_agent_slots in handle_info :DOWN) is
        #     bypassed. We must release held slots here to avoid permanent leaks.
        #     Waiting queues were already purged in step 5, so grant_pending only
        #     affects non-cancelled agents.
        state =
          Enum.reduce(cancel_set, state, fn agent_id, acc_state ->
            {acc_state, slot_status} = Slots.release_agent_slots(acc_state, agent_id)
            Lifecycle.apply_status_updates(slot_status)
            acc_state
          end)

        # 6. Cancel agents in reverse depth order (leaf subagents first, then parents)
        #    Sort by depth descending so deepest agents are cancelled first
        sorted_agents =
          Store.list_sched_meta()
          |> Enum.filter(fn {_id, %SchedMeta{task_id: tid}} -> tid == task_id end)
          |> Enum.sort_by(fn {_id, %SchedMeta{depth: d}} -> d end, :desc)
          |> Enum.map(fn {id, _meta} -> id end)

        state =
          Enum.reduce(sorted_agents, state, fn agent_id, acc_state ->
            Lifecycle.cancel_agent(acc_state, agent_id)
          end)

        # 7. Process queue to dispatch any newly-eligible agents
        state = Dispatch.process_queue(state)

        Logger.info("AgentScheduler: Cancelled #{length(agent_ids)} agent(s) for task #{task_id}")

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:begin_graceful_cancel, task_id}, _from, %State{} = state) do
    # 1. Register the task in the cancelling marker so run_agent refuses new
    #    root agents for it and Dispatch.register_agent immediately puts any
    #    newly registered agent (subagent spawns, crash-retries, queued agents
    #    starting late) into cancel-grace.
    register_cancelling_task(task_id)

    # 2. Find all agents of this task (SchedMeta.task_id scan — same pattern
    #    as force_kill_task_agents) and put each live agent into cancel-grace:
    #    append the cancel notification message and set cancel_requested=true.
    agent_ids =
      Store.list_sched_meta()
      |> Enum.filter(fn {_id, %SchedMeta{task_id: tid}} -> tid == task_id end)
      |> Enum.map(fn {id, _meta} -> id end)

    Enum.each(agent_ids, fn agent_id ->
      case Store.get_agent_state(agent_id) do
        {:ok, _agent_state} ->
          Store.append_pending_user_message(agent_id, cancel_message())
          Store.set_cancel_requested(agent_id)

        :error ->
          :ok
      end
    end)

    # 3. Purge the task's agents from the LLM/tool waiting queues. A queued
    #    agent (e.g. blocked on a 0-capacity model's LLM slot, which now
    #    blocks instead of failing fast) would never see the cancel message
    #    while waiting — the purge replies {:error, :cancelled} to each
    #    blocked caller, whose with_llm_slot/with_tool_slot raise via the
    #    catch-all → agent crash → the crash-retry re-registration (gated on
    #    register_cancelling_task from step 1) lands the retried agent in
    #    cancel-grace, where it saves work and completes. Slot HOLDERS are
    #    untouched — a running agent finishes its current call and reads the
    #    cancel message at its next loop top. Purge is a no-op for agents not
    #    in any queue, so ALL task agents are purged unconditionally.
    {state, _status_updates} = Slots.purge_agents_from_queues(state, MapSet.new(agent_ids))

    Logger.info(
      "AgentScheduler: Began graceful cancel for task #{task_id} — #{length(agent_ids)} agent(s) notified"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_cancelling_task, task_id}, _from, %State{} = state) do
    case :ets.whereis(:evogit_cancelling_tasks) do
      :undefined -> :ok
      _tid -> :ets.delete(:evogit_cancelling_tasks, task_id)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_config, opts}, _from, %State{} = state) do
    # Validate llm_model if being updated: setting it to nil is rejected.
    if Keyword.has_key?(opts, :llm_model) and Keyword.get(opts, :llm_model) == nil do
      {:reply, {:error, "llm_model cannot be nil"}, state}
    else
      reply = State.do_update_config(opts, state)
      log_model_concurrency_update(opts, state, reply)
      reconcile_pool_after_update(reply)
    end
  end

  @impl true
  def handle_call(:get_config, _from, %State{} = state) do
    config = %{
      default_llm_max_concurrency: state.default_llm_max_concurrency,
      max_tool_concurrency: state.max_tool_concurrency,
      agent_max_retries: state.agent_max_retries,
      max_agent_depth: state.max_depth,
      max_retries: state.max_retries,
      max_turns: state.max_turns,
      max_turns_root: state.max_turns_root,
      llm_model: state.llm_model,
      llm_generation_params: state.llm_generation_params,
      model_profiles: state.model_profiles,
      paused: state.paused,
      sandbox_mode: state.sandbox_mode,
      sandbox_resources: state.sandbox_resources,
      sandbox_process_resources: state.sandbox_process_resources,
      sandbox_backend: EvoGit.Platform.sandbox_backend(),
      sandbox_capabilities: EvoGit.Sandbox.capabilities()
    }

    {:reply, config, state}
  end

  @impl true
  def handle_call({:get_config, key}, _from, %State{} = state) do
    value =
      case key do
        :default_llm_max_concurrency -> state.default_llm_max_concurrency
        :max_tool_concurrency -> state.max_tool_concurrency
        :agent_max_retries -> state.agent_max_retries
        :max_agent_depth -> state.max_depth
        :max_retries -> state.max_retries
        :max_turns -> state.max_turns
        :max_turns_root -> state.max_turns_root
        :llm_model -> state.llm_model
        :llm_generation_params -> state.llm_generation_params
        :model_profiles -> state.model_profiles
        :model_concurrency -> state.model_concurrency
        :paused -> state.paused
        :sandbox_mode -> state.sandbox_mode
        :sandbox_resources -> state.sandbox_resources
        :sandbox_process_resources -> state.sandbox_process_resources
        :sandbox_backend -> EvoGit.Platform.sandbox_backend()
        :sandbox_capabilities -> EvoGit.Sandbox.capabilities()
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
      Logger.info(
        "AgentScheduler: Resuming scheduler — granting pending slots and dispatching queued agents"
      )

      state = struct(state, paused: false)
      {state, status_updates} = Slots.grant_pending_on_resume(state)
      Lifecycle.apply_status_updates(status_updates)
      state = Dispatch.dispatch_queued_agents(state)
      EvoGit.AgentScheduler.PubSub.broadcast_config_updated()
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:paused?, _from, %State{} = state) do
    {:reply, state.paused, state}
  end

  @impl true
  def handle_call({:send_user_message, agent_id, message}, _from, %State{} = state) do
    result = Store.append_pending_user_message(agent_id, message)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:spawn_sub_agents, parent_id, specs}, from, %State{} = state) do
    if state.paused do
      {:reply, {:error, :scheduler_paused}, state}
    else
      {:ok, parent} = Store.get_sched_meta(parent_id)

      Subagents.spawn_validated_subagents(parent_id, parent, specs, from, state)
    end
  end

  # --- LLM and Tool Slot Management (delegated to Slots module) ---

  @impl true
  def handle_call({:request_llm_slot, agent_id}, from, %State{} = state) do
    case Slots.handle_request_llm_slot(agent_id, from, state) do
      {:reply, :ok, new_state, status_updates} ->
        Lifecycle.apply_status_updates(status_updates)
        {:reply, :ok, new_state}

      {:noreply, new_state, status_updates} ->
        Lifecycle.apply_status_updates(status_updates)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:report_llm_error, agent_id, error_type}, _from, %State{} = state) do
    {:reply, :ok, new_state, status_updates} =
      Slots.handle_report_llm_error(agent_id, error_type, state)

    Lifecycle.apply_status_updates(status_updates)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:request_tool_slot, agent_id}, from, %State{} = state) do
    case Slots.handle_request_tool_slot(agent_id, from, state) do
      {:reply, :ok, new_state, status_updates} ->
        Lifecycle.apply_status_updates(status_updates)
        {:reply, :ok, new_state}

      {:noreply, new_state, status_updates} ->
        Lifecycle.apply_status_updates(status_updates)
        {:noreply, new_state}
    end
  end

  # Best-effort ReqLLM Finch pool reconciliation after a successful config
  # update. `State.do_update_config/2` always returns `{:reply, :ok, new_state}`
  # (the llm_model-nil error path never reaches it), so reconcile never raises.
  # Covers ALL config-change routes (RemoteAPI.reload_config, save_user_config,
  # evo_dash ConfigIO) — they all funnel through update_config.
  defp reconcile_pool_after_update({:reply, :ok, new_state} = reply) do
    total =
      EvoGit.ReqLLMPool.effective_concurrency(
        new_state.model_concurrency,
        new_state.default_llm_max_concurrency
      )

    EvoGit.ReqLLMPool.reconcile(total)
    reply
  end

  # Diagnostic log for `:model_concurrency` updates (PeakHourEngine applies,
  # CLI -c floor, dashboard saves): old vs POST-APPLICATION map (post-floor,
  # verbatim for skip_floor) + the skip-floor flag. A "0 capacity stayed 0
  # after peak exit" case shows up here as an old==new no-op, and the full map
  # (model ids are the map keys) makes per-model capacity transitions visible.
  defp log_model_concurrency_update(opts, state, {:reply, :ok, new_state}) do
    if Keyword.has_key?(opts, :model_concurrency) do
      Logger.info(
        "AgentScheduler: model_concurrency updated — old=#{inspect(state.model_concurrency)} " <>
          "new=#{inspect(new_state.model_concurrency)} " <>
          "skip_floor=#{Keyword.get(opts, :model_concurrency_skip_floor, false)} " <>
          "default_llm_max_concurrency=#{new_state.default_llm_max_concurrency}"
      )
    end
  end

  @impl true
  def handle_cast({:release_llm_slot, agent_id}, %State{} = state) do
    {new_state, status_updates} = Slots.handle_release_llm_slot(agent_id, state)
    Lifecycle.apply_status_updates(status_updates)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:release_tool_slot, agent_id}, %State{} = state) do
    {new_state, status_updates} = Slots.handle_release_tool_slot(agent_id, state)
    Lifecycle.apply_status_updates(status_updates)
    {:noreply, new_state}
  end

  # Retry LLM waiting queue after backoff expiry (delegated to Slots module)
  @impl true
  def handle_info(:retry_llm_waiting, %State{} = state) do
    {:noreply, state, status_updates} = Slots.handle_retry_llm_waiting(state)
    Lifecycle.apply_status_updates(status_updates)
    {:noreply, state}
  end

  # Task returned a result
  @impl true
  def handle_info({ref, result}, %State{} = state) when is_reference(ref) do
    Lifecycle.handle_task_result(ref, result, state)
  end

  # Task process exited (monitor :DOWN).
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{} = state) do
    Lifecycle.handle_agent_down(ref, pid, reason, state)
  end

  # --- ETS Helpers (Agent History Table) ---

  @doc """
  Gets the conversation context for an agent from the agent state table.
  Returns the context or nil if not set.
  """
  @spec get_agent_context(pos_integer()) :: ReqLLM.Context.t() | nil
  def get_agent_context(agent_id), do: Store.get_agent_context(agent_id)

  @doc """
  Updates multiple fields for an agent in a single ETS get+put cycle.
  Accepts a keyword list of field-value pairs (e.g., `[context: ctx, turn: 5, usage: usage, total_tokens: 100]`).
  This avoids redundant `:ets.lookup` + `:ets.insert` round-trips when syncing
  multiple fields per agent turn.
  """
  @spec batch_update_agent(pos_integer(), keyword()) :: :ok
  def batch_update_agent(agent_id, fields), do: Store.batch_update_agent(agent_id, fields)

  @doc """
  Updates the conversation context for an agent in the agent state table.
  """
  @spec update_agent_context(pos_integer(), ReqLLM.Context.t()) :: :ok
  def update_agent_context(agent_id, context), do: Store.update_agent_context(agent_id, context)

  @doc """
  Updates the cumulative usage for an agent in the agent state table.
  """
  @spec update_agent_usage(pos_integer(), EvoGit.Agent.Usage.t()) :: :ok
  def update_agent_usage(agent_id, usage), do: Store.update_agent_usage(agent_id, usage)

  @doc """
  Updates the current turn for an agent in the agent state table.
  """
  @spec update_agent_turn(pos_integer(), non_neg_integer()) :: :ok
  def update_agent_turn(agent_id, turn), do: Store.update_agent_turn(agent_id, turn)

  @doc """
  Updates the cumulative token count for an agent in the agent state table.

  This mirrors `LoopState.total_tokens` so the dashboard can display context
  progress. Reset to 0 on each context compression.
  """
  @spec update_total_tokens(pos_integer(), non_neg_integer()) :: :ok
  def update_total_tokens(agent_id, total_tokens),
    do: Store.update_total_tokens(agent_id, total_tokens)

  @doc """
  Increments the compression count for an agent in the agent state table.

  Called once per successful context-compression event to track how many times
  an agent's context has been compressed.
  """
  @spec increment_compression_count(pos_integer()) :: :ok
  def increment_compression_count(agent_id), do: Store.increment_compression_count(agent_id)

  # --- Graceful-cancel marker helpers ---

  # Returns true when the task_id is registered in the :evogit_cancelling_tasks
  # marker (a graceful cancel is in flight). Defensive against a missing table
  # (should not happen — Application.start/2 creates it before the scheduler).
  defp cancelling_task?(task_id) do
    case :ets.whereis(:evogit_cancelling_tasks) do
      :undefined -> false
      _tid -> :ets.member(:evogit_cancelling_tasks, task_id)
    end
  end

  # Registers a task_id in the :evogit_cancelling_tasks marker. The table is a
  # public :set so the marker is readable from Dispatch.register_agent (which
  # runs inside scheduler handlers) and from TaskRegistry's guarded cleanup.
  defp register_cancelling_task(task_id) do
    case :ets.whereis(:evogit_cancelling_tasks) do
      :undefined -> :ok
      _tid -> :ets.insert(:evogit_cancelling_tasks, {task_id})
    end

    :ok
  end
end
