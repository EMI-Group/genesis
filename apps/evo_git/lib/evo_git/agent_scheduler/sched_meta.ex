defmodule EvoGit.AgentScheduler.SchedMeta do
  @moduledoc """
  Scheduling metadata for a registered agent, stored in the
  `:evogit_sched_meta` ETS table.

  Owned exclusively by the scheduler process — agents never read or write
  this table.

  ## Fields

  - `id` — scheduler-assigned integer agent ID
  - `depth` — recursion depth (0 for top-level agents)
  - `status` — `:pending | :running | :waiting | :ready | :blocked | :awaiting_input`
    - :pending — just registered, ready to run when a worktree is available
    - :running — currently executing in a worktree
    - :waiting — execution paused due to subagent calls
    - :ready — execution paused, all subagents completed, ready to resume
    - :blocked — waiting for an LLM or tool slot to become available
    - :awaiting_input — an INTERACTIVE session idle between exchanges: live,
      cancellable and closeable, but not busy (no worker, no slot, no timer)
  - `worktree` — path to the assigned worktree, or `nil` when unassigned
  - `session_pid` — the agent's `EvoGit.Agent.Session` owner pid, or `nil`
  - `mode` — `:oneshot | :interactive`. `:oneshot` is the default (one exchange,
    then the session ends); `:interactive` is ROOT-ONLY and lets one session
    process serve many exchanges until it is explicitly closed.
  - `phase` — a BEST-EFFORT mirror of the session's phase
  - `from` — the `GenServer.reply/2` destination for top-level agents
  - `parent_id` — the parent agent's ID, or `nil` for top-level agents
  - `task_id` — the string task ID for grouping agents belonging to the same top-level run_agent call
  - `task_number` — the short integer task number for worktree/branch naming
  - `spec` — the original `%AgentSpec{}` used to spawn this agent
  - `retries` — number of crash-retry attempts so far
  - `result_sent` — whether the agent's session has already delivered a result
  - `sub_agent_from` — `GenServer.reply/2` destination for `spawn_sub_agents` call
  - `total_sub_specs` — total number of subagent specs (for ordering results)
  - `pending_sub_agents` — `MapSet` of subagent IDs still running
  - `sub_agent_results` — `%{index => result}` accumulated subagent results by original spec index
  - `sub_agent_indices` — `%{agent_id => index}` mapping from subagent ID to original spec index
  - `foreign_repo_commits` — `%{repo_id => commit_sha}` latest known commit per foreign repo for this agent's subtree

  ## `session_pid`, `mode` and `phase` — the session-owned lifecycle

  `session_pid` is the agent's `EvoGit.Agent.Session` owner pid: the process that owns the
  authoritative agent state and whose death releases the worktree. It is never a `%Task{}`
  — the scheduler force-cancels through `EvoGit.Agent.Session.cancel/2` and re-monitors the
  session pid after a `WorktreeManager` restart.

  `mode` is `:oneshot | :interactive`. `:oneshot` is the default an agent registered by
  `run_agent/2` (and every subagent) carries: one exchange and the session ends.
  `:interactive` is set by `EvoGit.AgentScheduler.start_session/1` (root-only this version):
  one session process, many exchanges, until an explicit close/cancel.

  `phase` is a scheduler-side BEST-EFFORT MIRROR ONLY (`:starting | :running |
  :awaiting_input | :cancelling | :finalizing | :done | nil`): the scheduler sets
  `:starting` when it starts a session, `:awaiting_input` on a session yield,
  `:running` when a yielded session resumes, `:cancelling` when it drives a graceful
  cancel and `:done` when it recycles the agent.
  It is never the truth about a live run — the AUTHORITATIVE live phase is answered by
  `EvoGit.Agent.Session.inspect/2`.

  ## Status/phase enumerations

  The lists below are the single source of truth for this struct's enumerations
  (`statuses/0`, `phases/0`, …), so consumers — and one table-driven test — can
  assert totality instead of duplicating the unions. NOTE the semantic split:

  - every list containing `:running` whose meaning is "a live session" also
    contains `:awaiting_input`;
  - `:blocked` keeps its own meaning ("parked in an LLM/tool slot queue") and is
    NEVER overloaded to mean an idle session;
  - `:awaiting_input` is a live-but-not-busy status: it holds no worker, no slot
    and no timer, yet it must be cancellable, closeable and lease-renewable.
  """

  alias EvoGit.AgentSpec

  # Every status a REGISTERED agent can carry — including the idle-but-live
  # `:awaiting_input` of an interactive session.
  @statuses [:pending, :running, :waiting, :ready, :blocked, :awaiting_input]

  # Every phase the scheduler may mirror from a session (`nil` = not mirrored).
  @phases [:starting, :running, :awaiting_input, :cancelling, :finalizing, :done]

  # Statuses of an agent whose session process is alive (running an exchange,
  # idle between exchanges, or parked in a slot queue).
  @live_statuses @statuses

  # Statuses of a live session that is IDLE: no worker, no slot, no timer.
  @idle_statuses [:awaiting_input]

  # Statuses from which a graceful cancel or a force kill must still work.
  @cancel_reachable_statuses @statuses

  @type status :: :pending | :running | :waiting | :ready | :blocked | :awaiting_input
  @type mode :: :oneshot | :interactive

  @type phase ::
          :starting | :running | :awaiting_input | :cancelling | :finalizing | :done | nil

  @enforce_keys [:id, :depth, :spec]
  defstruct [
    :id,
    :depth,
    :from,
    :parent_id,
    :task_id,
    :task_number,
    :spec,
    status: :pending,
    worktree: nil,
    session_pid: nil,
    mode: :oneshot,
    phase: nil,
    retries: 0,
    result_sent: false,
    sub_agent_from: nil,
    total_sub_specs: 0,
    pending_sub_agents: MapSet.new(),
    sub_agent_results: %{},
    sub_agent_indices: %{},
    foreign_repo_commits: %{}
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          depth: non_neg_integer(),
          status: status(),
          worktree: String.t() | nil,
          session_pid: pid() | nil,
          mode: mode(),
          phase: phase(),
          from: GenServer.from() | nil,
          parent_id: pos_integer() | nil,
          task_id: String.t() | nil,
          task_number: pos_integer() | nil,
          spec: AgentSpec.t(),
          retries: non_neg_integer(),
          result_sent: boolean(),
          sub_agent_from: GenServer.from() | nil,
          total_sub_specs: non_neg_integer(),
          pending_sub_agents: MapSet.t(pos_integer()),
          sub_agent_results: %{optional(non_neg_integer()) => term()},
          sub_agent_indices: %{optional(pos_integer()) => non_neg_integer()},
          foreign_repo_commits: %{atom() => String.t()}
        }

  @doc false
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc false
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc false
  @spec live_statuses() :: [status()]
  def live_statuses, do: @live_statuses

  @doc false
  @spec idle_statuses() :: [status()]
  def idle_statuses, do: @idle_statuses

  @doc false
  @spec cancel_reachable_statuses() :: [status()]
  def cancel_reachable_statuses, do: @cancel_reachable_statuses
end
