defmodule EvoGit.AgentScheduler.SchedMeta do
  @moduledoc """
  Scheduling metadata for a registered agent, stored in the
  `:evogit_sched_meta` ETS table.

  Owned exclusively by the scheduler process — agents never read or write
  this table.

  ## Fields

  - `id` — scheduler-assigned integer agent ID
  - `depth` — recursion depth (0 for top-level agents)
  - `status` — `:pending | :running | :waiting | :ready | :blocked`
    - :pending — just registered, ready to run when a worktree is available
    - :running — currently executing in a worktree
    - :waiting — execution paused due to subagent calls
    - :ready — execution paused, all subagents completed, ready to resume
    - :blocked — waiting for an LLM or tool slot to become available
  - `worktree` — path to the assigned worktree, or `nil` when unassigned
  - `session_pid` — the agent's `EvoGit.Agent.Session` owner pid, or `nil`
  - `mode` — `:oneshot | :interactive` (always `:oneshot` today)
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

  `mode` is `:oneshot | :interactive` and is always `:oneshot` in this stage: an agent runs
  exactly one exchange and ends.

  `phase` is a scheduler-side BEST-EFFORT MIRROR ONLY (`:starting | :running | :cancelling |
  :finalizing | :done | nil`): the scheduler sets `:starting` when it starts a session,
  `:cancelling` when it drives a graceful cancel and `:done` when it recycles the agent.
  It is never the truth about a live run — the AUTHORITATIVE live phase is answered by
  `EvoGit.Agent.Session.inspect/2`.
  """

  alias EvoGit.AgentSpec

  @type mode :: :oneshot | :interactive
  @type phase :: :starting | :running | :cancelling | :finalizing | :done | nil

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
          status: :pending | :running | :waiting | :ready | :blocked,
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
end
