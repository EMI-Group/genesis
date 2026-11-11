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
  `EvoGit.AgentScheduler.WorktreeManager`: the agent's session requests a fresh
  worktree (the call waits indefinitely — no call timeout, so a slow create is
  never aborted, while a genuine failure inside the create pipeline still
  errors promptly; WorktreeManager offloads the I/O to a spawned task),
  WorktreeManager monitors the session process and destroys the worktree on exit.

  ## Agent lifecycle

  Every agent is ONE `EvoGit.Agent.Session` process, started here by
  `EvoGit.AgentScheduler.Dispatch.do_try_dispatch/4` under
  `EvoGit.Agent.Session.Supervisor`. The session owns the authoritative agent
  state and sends exactly ONE terminal
  `{:agent_session_result, agent_id, session_pid, result}` before it stops; the
  scheduler admits it (`Lifecycle.handle_session_result/3`) and keeps only a
  best-effort `SchedMeta` mirror (`session_pid`, `mode`, `phase`).

  ## Interactive sessions

  `start_session/1` starts the SAME per-agent session in INTERACTIVE mode
  (root-only this version): one session process serves MANY exchanges, so the
  agent keeps its worktree, its context and its provider `prompt_cache_key`
  across messages instead of paying a cold start per message.

  A session YIELDS when it has nothing more to do for the current message: it
  sends `{:agent_session_yield, agent_id, session_pid, text}` and goes idle. The
  scheduler mirrors that as `SchedMeta.status: :awaiting_input` (+ `phase`), plus
  a best-effort task-row flip and a roster re-broadcast; the transcript and its
  text stay owned by the session. An idle session is LIVE but NOT BUSY — no
  worker, no LLM/tool slot, no timer — and `list_awaiting_input/0` is the fact an
  idle gate needs. A new input on the same pid sends
  `{:agent_session_resumed, agent_id, session_pid}`, flipping the mirror and the
  task row back to `:running`.

  A yield is NEVER a finish: no caller reply, no row deletion, no worktree
  release, no slot change, no terminal task status. A session ends only by
  finishing, by `close_session/1`, by a graceful cancel or by a force kill —
  there is deliberately NO idle timeout. Messages arrive through
  `send_session_message/3`: both `:queue` (the default) and `:interrupt` are
  accepted and validated, but they are applied IDENTICALLY — the message is
  appended and delivered at the next turn boundary, because chunk-level
  interruption of the in-flight generation is later work
  (`docs/agent-runtime-refactor.md` §5, P4). A mid-exchange message is therefore
  never dropped, and a message sent while `:awaiting_input` starts a new
  exchange immediately on the SAME session, worktree, context and cache
  identity.

  `await_close/2` is the interactive counterpart of `run_agent/2`: `run_agent/2`
  blocks one caller until the one-shot agent terminates (the scheduler owns the
  `from` reply), while `start_session/1` + `await_close/2` start a session and
  await its explicit close, after any number of exchanges. `:blocked` keeps its
  own meaning (parked in a slot queue) — an idle session is `:awaiting_input`.

  ## ETS Tables

  Agent data is split across two ETS tables with clear ownership:

  - **`:evogit_agent_summary`** — Owned by agent processes. The agent SUMMARY row
    (the read model of the agent's state): identity, model selection, counters
    and the session-published status/commit fields.
    The scheduler writes the registration values on dispatch; from then on the
    owning `EvoGit.Agent.Session` is the only runtime writer (at most one
    summary publish per turn).

  - **`:evogit_sched_meta`** — Owned by the scheduler process. Contains all
    scheduling bookkeeping: status, worktree assignment, session refs,
    parent/child tracking, retry counts, etc. Agents do not write to this table.

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
  alias EvoGit.AgentScheduler.SessionOpts
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.AgentSpec

  @agent_table :evogit_agent_summary
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
  Starts an agent SESSION and returns its agent id WITHOUT waiting for it.

  The INTERACTIVE entry point (root-only this version): the session serves many
  exchanges — later messages go through `send_session_message/3` on the same
  agent — until it finishes or is closed with `close_session/1`. One session means
  one worktree, one context and one provider `prompt_cache_key` across messages.

  Same bookkeeping as `run_agent/2` (task id, graceful-cancel guard, archive
  reset, repo-root/task-number resolution, `Dispatch.register_agent/7`) but NO
  blocking and no caller `from`: the answer is the new agent id and the terminal
  outcome is collected with `await_close/2`. `session_mode` is always forced to
  `:interactive` and mirrored onto `SchedMeta.mode`.

  Accepts a ready `%AgentSpec{}` or a keyword list built by
  `EvoGit.AgentScheduler.SessionOpts.build/1` (`:agent_module` and `:objective`
  required). Returns `{:ok, agent_id}` or `{:error, reason}` —
  `:llm_not_configured`, `:cancelled`, a dispatch error,
  `{:invalid_session_opts, detail}`, `{:interactive_root_only, message}` or
  `{:unsupported_session_mode, value}`.
  """
  @spec start_session(AgentSpec.t() | keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def start_session(%AgentSpec{} = spec) do
    with {:ok, spec} <- SessionOpts.force_interactive(spec) do
      GenServer.call(__MODULE__, {:start_session, spec})
    end
  end

  def start_session(opts) when is_list(opts) do
    with {:ok, spec} <- SessionOpts.build(opts) do
      start_session(spec)
    end
  end

  def start_session(other), do: {:error, {:invalid_session_opts, {:not_a_session_spec, other}}}

  @doc """
  Delivers one message to a session (by session pid or agent id).

  Both `:queue` (default) and `:interrupt` are accepted and validated but applied
  IDENTICALLY: the message is appended and delivered at the next turn boundary,
  because chunk-level interruption of the in-flight generation is later work
  (`docs/agent-runtime-refactor.md` §5, P4). A mid-exchange message is never
  dropped, and one sent while `:awaiting_input` starts a new exchange
  immediately on the same session, worktree, context and cache identity.
  The session owns the queue and the transcript.
  Total: `:ok`, or `{:error, {:session, reason}}` — the session's own
  `:not_found`/`:finished`/`{:bad_state, phase}`, or a caller error
  (`{:bad_policy, _}`/`{:bad_target, _}`/`{:bad_message, _}`).
  """
  @spec send_session_message(pid() | pos_integer(), String.t() | map(), :queue | :interrupt) ::
          :ok | {:error, {:session, term()}}
  def send_session_message(target, message, policy \\ :queue) do
    cond do
      policy not in [:queue, :interrupt] ->
        {:error, {:session, {:bad_policy, policy}}}

      not (is_pid(target) or is_integer(target)) ->
        {:error, {:session, {:bad_target, target}}}

      not (is_binary(message) or is_map(message)) ->
        {:error, {:session, {:bad_message, message}}}

      true ->
        session_call(fn -> EvoGit.Agent.Session.start_input(target, message, policy) end)
    end
  end

  @doc """
  Closes a session — the ONLY non-cancellation way out of `:awaiting_input`.

  Completion bookkeeping runs once at that terminal outcome and the worktree is
  released when the session stops; no timer ever does this.
  """
  @spec close_session(pid() | pos_integer()) :: :ok | {:error, {:session, term()}}
  def close_session(target) when is_pid(target) or is_integer(target) do
    session_call(fn -> EvoGit.Agent.Session.close(target) end)
  end

  def close_session(other), do: {:error, {:session, {:bad_target, other}}}

  @doc """
  Waits until the session of `agent_id` is CLOSED (or terminated) and returns
  its terminal outcome.

  The interactive counterpart of `run_agent/2` (which blocks the one-shot caller
  until the agent finishes): `start_session/1` + `await_close/2` await an
  explicit close, after any number of exchanges. An `:awaiting_input` session is
  AWAITED, not busy — no worker, no slot, no timer while it idles.

  Returns `{:ok, %EvoGit.Agent.Result{}}` or `{:error, :not_found | :timeout |
  term()}`.

  `timeout` (milliseconds) defaults to `30_000` — a bounded wait suitable for an
  RPC caller. Awaiting a HUMAN-driven session (one that may legitimately stay
  `:awaiting_input` for minutes) passes `:infinity` EXPLICITLY; a caller that
  wants to wait forever must say so.
  """
  @spec await_close(pos_integer(), timeout()) ::
          {:ok, %EvoGit.Agent.Result{}} | {:error, :not_found | :timeout | term()}
  def await_close(agent_id, timeout \\ 30_000)

  def await_close(agent_id, timeout) when is_integer(agent_id) do
    GenServer.call(__MODULE__, {:await_close, agent_id}, timeout)
  catch
    # A `GenServer.call` to a dead/restarting scheduler or an expired timeout
    # EXITS the caller; the public waiter answers its documented error instead.
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end

  def await_close(_agent_id, _timeout), do: {:error, :not_found}

  @doc """
  Lists every `:awaiting_input` agent — the core "idle session" fact.

  Each entry is `%{agent_id, task_id, session_pid, task_number, mode}`. Idle
  sessions are LIVE but NOT BUSY, so an idle gate (e.g. `/server/status` before an
  update) can wind them down gracefully instead of force-killing them. `[]` when
  nothing is idle or the table is absent (a cheap ETS read, no scheduler call).
  """
  @spec list_awaiting_input() :: [
          %{
            agent_id: pos_integer(),
            task_id: String.t() | nil,
            session_pid: pid() | nil,
            task_number: pos_integer() | nil,
            mode: SchedMeta.mode()
          }
        ]
  def list_awaiting_input, do: SessionOpts.idle_sessions()

  # Every session command crosses a process boundary: an exit (target or
  # registry gone, call timeout) must become the documented error tuple instead
  # of crashing the caller, and a session's `{:error, reason}` is wrapped so a
  # caller can tell session refusals from scheduler refusals.
  defp session_call(fun) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, {:session, reason}}
      other -> {:error, {:session, other}}
    end
  catch
    :exit, reason -> {:error, {:session, {:exit, reason}}}
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
  Returns the scheduler task_id owning the given agent, or `nil` when the
  agent is unknown or the scheduler tables are not up.

  A cheap public ETS read of the `:evogit_sched_meta` table (keyed by agent
  id) — safe to call from any process, including spawned tool tasks. Used by
  the tool-dispatch layer to attribute `run_command` approval requests to the
  owning task (so a graceful task cancel auto-denies its pending approvals).
  """
  @spec task_id_for_agent(pos_integer()) :: String.t() | nil
  def task_id_for_agent(agent_id) when is_integer(agent_id) do
    case :ets.lookup(:evogit_sched_meta, agent_id) do
      [{^agent_id, %SchedMeta{task_id: task_id}}] -> task_id
      _ -> nil
    end
  end

  def task_id_for_agent(_other), do: nil

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
  Returns the current per-model LLM slot status from the scheduler's live
  state: for every model id in `State.all_model_ids/1` (configured model
  profiles plus any live/stale pools still holding or waiting agents) the map
  reports

      %{
        "model_id" => %{used: non_neg_integer, waiting: non_neg_integer, capacity: non_neg_integer}
      }

  * `used` — agents CURRENTLY HOLDING an LLM slot of that model (the real
    `MapSet.size` of the holder pool, not a status proxy).
  * `waiting` — agents queued for a slot of that model (the real `:queue.len`).
  * `capacity` — the model's effective slot capacity exactly as the scheduler
    grants it (`State.concurrency_for/2`); a peak-paused model reports `0`,
    and the value can change across peak/off-peak transitions.

  Cheap pure in-state reads only — no locking, no side effects. The scheduler
  must be running: callers guard with `Process.whereis(__MODULE__) != nil`
  (no try/rescue; a call to a dead process exits the caller). This read lives
  on the scheduler GenServer itself — `AgentScheduler.RemoteAPI` is
  intentionally ETS-pure and does not expose it.
  """
  @spec get_llm_slot_status() ::
          %{
            String.t() => %{
              used: non_neg_integer(),
              waiting: non_neg_integer(),
              capacity: non_neg_integer()
            }
          }
  def get_llm_slot_status do
    GenServer.call(__MODULE__, :get_llm_slot_status)
  end

  @doc """
  Reads the agent summary row from the agent summary table.

  The row is a SUMMARY snapshot published by the agent's session; a reader must
  never treat it as the authoritative agent state.
  """
  @spec get_agent_state(pos_integer()) :: {:ok, AgentState.t()} | :error
  def get_agent_state(agent_id), do: Store.get_agent_state(agent_id)

  @doc """
  Sends a user message to a running agent.

  `message` is either a legacy plain `String.t()` or a
  `%{text:, attachments:}` map (see `EvoGit.Attachments.message/1` — the map
  may carry images/audio, atom- or string-keyed). The message is appended to
  the agent's `pending_user_messages` queue and will be injected into the
  agent's LLM context at the top of its next turn (as a user-role message),
  materialized by `EvoGit.Agent.ContextBuilder.build_injected_message/2`. There
  is NO root gate on injected messages — any agent at any depth may receive
  media this way (the root-only gate covers the `:attachments` task opt only).
  This serializes the append through the GenServer to avoid concurrent-write
  races.

  Returns `:ok` on success, or `{:error, :not_found}` if the agent doesn't exist.
  """
  @spec send_user_message(pos_integer(), String.t() | map()) :: :ok | {:error, :not_found}
  def send_user_message(agent_id, message) when is_binary(message) or is_map(message) do
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

  For the model-exhaustion classes (`:rate_limit`, `:insufficient_balance`) this
  applies a model-wide per-model backoff for the given duration (`backoff_ms`;
  `nil` falls back to the Slots default).
  """
  @spec report_llm_error(pos_integer(), atom(), pos_integer() | nil) :: :ok
  def report_llm_error(agent_id, error_type, backoff_ms) do
    GenServer.call(__MODULE__, {:report_llm_error, agent_id, error_type, backoff_ms})
  end

  @doc """
  Back-compat delegate for `report_llm_error/3` with no explicit backoff duration
  (`nil` -> the Slots default).
  """
  @spec report_llm_error(pos_integer(), atom()) :: :ok
  def report_llm_error(agent_id, error_type), do: report_llm_error(agent_id, error_type, nil)

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

  The raise is deliberate: callers (`EvoGit.Agent.LLMPrompting.call_llm_with_retry/5`,
  context compression) already depend on a non-`:ok` slot result being an
  exception, and the retry loop is configured with `rescue_only: []` so the
  raise propagates on the first attempt with zero retries (a retried cancelled
  agent would be pointless — the crash hands it to the scheduler's
  crash-retry/cancel machinery).
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

  @doc """
  Force-kills all agents belonging to a task identified by its TASK ID.

  The task-id-addressed sibling of `force_kill_task_agents/1`: an INTERACTIVE
  session started by `start_session/1` is registered with `from: nil`, so the
  caller-pid lookup cannot see it. This entry point finds a depth-0 agent whose
  `SchedMeta.task_id` matches and then cancels every agent of that task
  (subagents included) exactly like the caller-pid path.

  Same BRUTAL cancellation path (no grace period): Task processes are killed,
  worktrees deleted, ETS entries removed, blocked callers replied with
  `{:error, :cancelled}` and `await_close/2` waiters flushed.

  Returns `:ok` if agents were found and cancelled, or `{:error, :not_found}`.
  """
  @spec force_kill_task_agents_for_task(String.t()) :: :ok | {:error, :not_found}
  def force_kill_task_agents_for_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:force_kill_task_agents_for_task, task_id})
  end

  # The cancel notification message injected into every agent of a task that
  # is being gracefully cancelled. The runner drains pending user messages at
  # the top of each turn, so the agent sees this before its next LLM call.
  @cancel_message "The task is being cancelled by the user. Please immediately save your work: commit any uncommitted changes, then reply with a summary of what was accomplished as plain text — a reply with no tool calls ends the run and its text IS the report, so no tool call is required. You are in a grace period: finish now."

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
    # ETS tables (:evogit_agent_summary, :evogit_sched_meta)
    # are created by EvoGit.Application before the scheduler starts so they survive
    # scheduler crashes. Defensive check: warn if any table is unexpectedly missing.
    for table <- [@agent_table, @sched_table] do
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

    # Boot and reload share one selection snapshot and provider/account pool
    # identities. Multiple models on an account must never create extra capacity.
    # CatalogWarmup resolves these selections in a throwaway process first.
    pool_state = State.from_config(config, opts)
    default_model = pool_state.llm_model
    default_params = pool_state.llm_generation_params

    sandbox_mode = Map.get(sandbox_config, :mode)
    sandbox_resources = Map.get(sandbox_config, :resources)
    sandbox_process_resources = Map.get(sandbox_config, :process)

    # Warn (but don't crash) if no model is configured at all
    unless default_model do
      Logger.warning("""
      AgentScheduler: LLM model not configured. Agent execution will be unavailable until configured.
      Please configure a provider account and its models in your config file:

      ~/.config/genesis/config.toml:

          [[llm.providers]]
          id = "my-provider"
          provider = "provider"
          models = ["model_name"]

      Use your provider's identifier and supported model names.

      You can also configure this via the Settings page in the dashboard.
      """)
    end

    # Allow opts to override (for backward compat with legacy flag-style opts)
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
      when profiles == nil do
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
      # Defensive per-task archive reset: the relational `task_agent_archives`
      # table is the single canonical archive for a task run, so any leftover
      # rows from a previous run sharing this task_id (e.g. a crash before the
      # task completed) must not leak into this run. Best-effort: a store
      # failure must never kill the scheduler.
      reset_task_archives(task_id)

      repo_root = Dispatch.resolve_agent_repo_root(spec, state)
      task_number = Dispatch.next_task_number(repo_root)

      case Dispatch.register_agent(state, spec, from, nil, 0, task_id, task_number) do
        {:error, reason} ->
          {:reply, {:error, reason}, state}

        {agent_id, state} ->
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
  end

  @impl true
  def handle_call({:start_session, spec}, _from, %State{} = state) do
    if llm_configured?(state) do
      do_start_session(spec, state)
    else
      Logger.warning("AgentScheduler: Rejecting interactive session — LLM not configured")
      {:reply, {:error, :llm_not_configured}, state}
    end
  end

  @impl true
  def handle_call({:await_close, agent_id}, from, %State{} = state) do
    # The waiter is answered with the session's terminal term (or a cancel /
    # crash terminal) by Lifecycle's close-waiter flush. An unknown agent is
    # answered immediately — there is nothing to wait for.
    case Store.get_sched_meta(agent_id) do
      {:ok, _meta} -> {:noreply, Lifecycle.register_close_waiter(state, agent_id, from)}
      :error -> {:reply, {:error, :not_found}, state}
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

        {:reply, :ok, cancel_task_agents(state, task_id)}
    end
  end

  @impl true
  def handle_call({:force_kill_task_agents_for_task, task_id}, _from, %State{} = state) do
    # A TASK-ID-addressed lookup: an interactive `start_session/1` agent has no
    # caller `from` (it is registered with `from: nil`), so the pid-addressed
    # path above can never find it. Match the task id on a depth-0 row, exactly
    # like the root lookup there.
    top_level_agent =
      Store.list_sched_meta()
      |> Enum.find(fn
        {_id, %SchedMeta{depth: 0, task_id: tid}} -> tid == task_id
        _ -> false
      end)

    case top_level_agent do
      nil ->
        {:reply, {:error, :not_found}, state}

      {_id, %SchedMeta{}} ->
        Logger.info("AgentScheduler: Cancelling all agents for task #{task_id} (by task id)")

        {:reply, :ok, cancel_task_agents(state, task_id)}
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
    #    Then drive the agent's SESSION into `:cancelling` as well, so the
    #    session's own summary row follows and its phase mirror is accurate.
    agent_ids = agent_ids_for_task(task_id)

    Enum.each(agent_ids, fn agent_id ->
      case Store.get_agent_state(agent_id) do
        {:ok, _agent_state} ->
          Store.append_pending_user_message(agent_id, cancel_message())
          Store.set_cancel_requested(agent_id)
          drive_session_graceful_cancel(agent_id)

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
    {:reply, config_map(state), state}
  end

  @impl true
  def handle_call({:get_config, key}, _from, %State{} = state) do
    {:reply, config_value(state, key), state}
  end

  @impl true
  def handle_call(:get_llm_slot_status, _from, %State{} = state) do
    status =
      Map.new(State.all_model_ids(state), fn model_id ->
        {model_id,
         %{
           used: MapSet.size(State.holders_for(state, model_id)),
           waiting: :queue.len(State.waiting_for(state, model_id)),
           capacity: State.concurrency_for(state, model_id)
         }}
      end)

    {:reply, status, state}
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
  def handle_call({:report_llm_error, agent_id, error_type, backoff_ms}, _from, %State{} = state) do
    {:reply, :ok, new_state, status_updates} =
      Slots.handle_report_llm_error(agent_id, error_type, backoff_ms, state)

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
  # runtime-override floor, dashboard saves): old vs POST-APPLICATION map (post-floor,
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

  # Every key served by the map-form :get_config reply. Deliberately omits
  # :model_concurrency — the map-form reply has never included it; the
  # single-key accessor serves it from live state via config_value/2.
  @config_keys [
    :default_llm_max_concurrency,
    :max_tool_concurrency,
    :agent_max_retries,
    :max_agent_depth,
    :max_retries,
    :max_turns,
    :max_turns_root,
    :llm_model,
    :llm_generation_params,
    :model_profiles,
    :provider_profiles,
    :paused,
    :sandbox_mode,
    :sandbox_resources,
    :sandbox_process_resources,
    :sandbox_backend,
    :sandbox_capabilities
  ]

  # Builds the full resolved config map for the map-form :get_config reply.
  defp config_map(%State{} = state) do
    Map.new(@config_keys, fn key -> {key, config_value(state, key)} end)
  end

  # Lazy per-key accessor shared by the map-form builder and the single-key
  # :get_config handler. Each call evaluates ONLY the requested key (a direct
  # %State{} field read for field-backed keys, or the platform/sandbox probe
  # for the two computed keys) — never the whole map, so single-key hot paths
  # (e.g. PeakHourEngine's per-broadcast reads) do not pay for unrelated
  # values. Unknown keys resolve to nil.
  defp config_value(%State{} = _state, :sandbox_backend), do: EvoGit.Platform.sandbox_backend()
  defp config_value(%State{} = _state, :sandbox_capabilities), do: EvoGit.Sandbox.capabilities()
  defp config_value(%State{} = state, :max_agent_depth), do: state.max_depth

  defp config_value(%State{} = state, key)
       when key in @config_keys or key == :model_concurrency do
    # For every other config key the config key IS the %State{} field name.
    Map.get(state, key)
  end

  defp config_value(_state, _key), do: nil

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

  # Session process exited (monitor :DOWN).
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{} = state) do
    Lifecycle.handle_agent_down(ref, pid, reason, state)
  end

  # A session's ONE terminal result, delivered BEFORE it stops (signal ordering
  # guarantees it arrives before that session's :DOWN). Admitted only from the
  # CURRENT session of a live agent: a `session_pid` of `nil` means the run is
  # already recycled/being retried, so a late result for it is still the run's
  # outcome; any OTHER pid is a stale session and is ignored.
  @impl true
  def handle_info({:agent_session_result, agent_id, session_pid, result}, %State{} = state) do
    case Store.get_sched_meta(agent_id) do
      {:ok, %SchedMeta{session_pid: nil}} ->
        Lifecycle.handle_session_result(agent_id, result, state)

      {:ok, %SchedMeta{session_pid: ^session_pid}} ->
        Lifecycle.handle_session_result(agent_id, result, state)

      {:ok, %SchedMeta{session_pid: other}} ->
        Logger.debug(
          "AgentScheduler: ignoring result from stale session #{inspect(session_pid)} " <>
            "for agent #{agent_id} (current: #{inspect(other)})"
        )

        {:noreply, state}

      :error ->
        Logger.debug(
          "AgentScheduler: ignoring session result for unknown agent " <>
            "#{inspect(agent_id)} from #{inspect(session_pid)}"
        )

        {:noreply, state}
    end
  end

  # A session went IDLE (`:awaiting_input`, a yield) or started a NEW exchange on
  # the same pid (`:running`, a resume): mirror status/phase, best-effort flip the
  # TASK row, re-broadcast the roster. Neither signal replies to `meta.from`,
  # deletes rows, releases the worktree, touches slots or emits a TERMINAL task
  # status — a yield is idle, not finished — and the text stays owned by the
  # session (the scheduler stores no transcript).
  @impl true
  def handle_info({:agent_session_yield, agent_id, session_pid, _text}, %State{} = state) do
    handle_session_status_signal(state, agent_id, session_pid, :awaiting_input)
  end

  @impl true
  def handle_info({:agent_session_resumed, agent_id, session_pid}, %State{} = state) do
    handle_session_status_signal(state, agent_id, session_pid, :running)
  end

  defp handle_session_status_signal(%State{} = state, agent_id, session_pid, status) do
    case SessionOpts.admit_signal(agent_id, session_pid) do
      {:ok, meta} ->
        Store.put_sched_meta(agent_id, %{meta | status: status, phase: status})
        SessionOpts.update_task_status(meta.task_id, status)
        EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
        {:noreply, state}

      {:stale, other} ->
        SessionOpts.log_stale_signal(status, agent_id, session_pid, other)
        {:noreply, state}

      :unknown ->
        SessionOpts.log_unknown_signal(status, agent_id, session_pid)
        {:noreply, state}
    end
  end

  # --- ETS Helpers (Agent History Table) ---

  # --- Task archive reset ---

  # Best-effort archive reset for one task id: the relational
  # `task_agent_archives` table is the single canonical archive for a task run,
  # so a task start clears any leftover rows for that id. A store failure
  # (crash/timeout/exit) is logged and swallowed — it must never kill the
  # scheduler.
  # The same admission `run_agent/2` applies: a legacy configuration with no
  # profiles (or no profiles AND no model) cannot run an agent at all.
  defp llm_configured?(%State{model_profiles: []}), do: false
  defp llm_configured?(%State{model_profiles: nil, llm_model: nil}), do: false
  defp llm_configured?(%State{}), do: true

  defp do_start_session(spec, %State{} = state) do
    task_id =
      Keyword.get(spec.opts || [], :task_id) ||
        Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # Same graceful-cancel guard as `run_agent/2`: never start a session for a
    # task that is already being cancelled.
    if cancelling_task?(task_id) do
      Logger.info(
        "AgentScheduler: Refusing to start an interactive session for task #{task_id} — " <>
          "task is being cancelled"
      )

      {:reply, {:error, :cancelled}, state}
    else
      reset_task_archives(task_id)

      repo_root = Dispatch.resolve_agent_repo_root(spec, state)
      task_number = Dispatch.next_task_number(repo_root)

      # `from = nil`: nothing blocks on this session's terminal outcome — it is
      # collected through `await_close/2`'s registered close waiter instead.
      case Dispatch.register_agent(state, spec, nil, nil, 0, task_id, task_number) do
        {:error, reason} ->
          {:reply, {:error, reason}, state}

        {agent_id, state} ->
          state = SessionOpts.mark_mode(state, agent_id, spec)

          Logger.info(
            "AgentScheduler: Starting interactive session #{agent_id} " <>
              "(task #{task_id}, number #{task_number})"
          )

          state =
            if state.paused do
              %{state | queue: :queue.in(agent_id, state.queue)}
            else
              Dispatch.try_dispatch(state, agent_id)
            end

          {:reply, {:ok, agent_id}, state}
      end
    end
  end

  defp reset_task_archives(task_id) do
    EvoGit.Store.delete_task_archives(task_id)
    :ok
  rescue
    error ->
      Logger.debug(
        "AgentScheduler: archive reset for task #{inspect(task_id)} failed: #{inspect(error)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "AgentScheduler: archive reset for task #{inspect(task_id)} exited: #{inspect(reason)}"
      )

      :ok
  end

  # --- Graceful-cancel marker helpers ---

  # Collects the ids of every agent registered under the given task by scanning
  # the scheduler metadata table. Each call takes its own fresh
  # `Store.list_sched_meta()` snapshot — never share one read across call sites.
  defp agent_ids_for_task(task_id) do
    Store.list_sched_meta()
    |> Enum.filter(fn {_id, %SchedMeta{task_id: tid}} -> tid == task_id end)
    |> Enum.map(fn {id, _meta} -> id end)
  end

  # The BRUTAL cancellation body shared by the two force-kill entry points
  # (caller-pid-addressed and task-id-addressed). Both resolve a task id first,
  # so the cascade is IDENTICAL for a blocking `run_agent/2` task and for a
  # `from = nil` interactive session.
  defp cancel_task_agents(%State{} = state, task_id) do
    # 1. Find ALL agents with this task_id
    agent_ids = agent_ids_for_task(task_id)

    cancel_set = MapSet.new(agent_ids)

    # 2. Remove refs from ref_to_agent BEFORE killing sessions (so DOWN handler is a no-op)
    ref_to_agent =
      state.ref_to_agent
      |> Enum.reject(fn {_ref, aid} -> MapSet.member?(cancel_set, aid) end)
      |> Map.new()

    state = %{state | ref_to_agent: ref_to_agent}

    # 3. Remove from dispatch queue
    queue =
      :queue.filter(
        fn aid ->
          not MapSet.member?(cancel_set, aid)
        end,
        state.queue
      )

    state = %{state | queue: queue}

    # 4. Purge from slot waiting queues (replies {:error, :cancelled} to blocked callers)
    {state, _status_updates} = Slots.purge_agents_from_queues(state, cancel_set)

    # 5. Release LLM/tool slots held by cancelled agents.
    #    Step 2 made the :DOWN handler a no-op for these agents, so the normal
    #    slot release path (Slots.release_agent_slots in handle_info :DOWN) is
    #    bypassed. We must release held slots here to avoid permanent leaks.
    #    Waiting queues were already purged in step 4, so grant_pending only
    #    affects non-cancelled agents.
    state =
      Enum.reduce(cancel_set, state, fn agent_id, acc_state ->
        {acc_state, slot_status} = Slots.release_agent_slots(acc_state, agent_id)
        Lifecycle.apply_status_updates(slot_status)
        acc_state
      end)

    # 6. Cancel agents in reverse depth order (leaf subagents first, then parents)
    #    Sort by depth descending so deepest agents are cancelled first
    sorted_agents =
      agent_ids_for_task(task_id)
      |> Enum.sort_by(&Store.depth_of/1, :desc)

    state =
      Enum.reduce(sorted_agents, state, fn agent_id, acc_state ->
        Lifecycle.cancel_agent(acc_state, agent_id)
      end)

    # 7. Process queue to dispatch any newly-eligible agents
    state = Dispatch.process_queue(state)

    Logger.info("AgentScheduler: Cancelled #{length(agent_ids)} agent(s) for task #{task_id}")

    state
  end

  # Drives one agent's SESSION into cancel-grace.
  # (pending message + cancel_requested flag) is what makes the RUNNING exchange
  # save work; this call makes the session itself enter `:cancelling` (so its
  # summary row follows) and mirrors the phase onto sched_meta. Best-effort: a
  # session that cannot serve the call (still `:starting`, already finished, or
  # gone) is left to the pending-message drain, and a `nil` pid (registered but
  # never dispatched) is a no-op.
  defp drive_session_graceful_cancel(agent_id) do
    case Store.get_sched_meta(agent_id) do
      {:ok, %SchedMeta{session_pid: pid} = meta} when is_pid(pid) ->
        EvoGit.Agent.Session.cancel(pid, :graceful)
        Store.put_sched_meta(agent_id, %{meta | phase: :cancelling})

      _other ->
        :ok
    end
  end

  @doc false
  # Returns true when the task_id is registered in the :evogit_cancelling_tasks
  # marker (a graceful cancel is in flight). Defensive against a missing table
  # (should not happen — Application.start/2 creates it before the scheduler).
  # Public (hidden from docs) so Dispatch.register_agent shares the single
  # implementation instead of duplicating it.
  def cancelling_task?(task_id) do
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
