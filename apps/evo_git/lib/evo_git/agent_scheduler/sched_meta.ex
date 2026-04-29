defmodule EvoGit.AgentScheduler.SchedMeta do
  @moduledoc """
  Scheduling metadata for a registered agent, stored in the
  `:evogit_sched_meta` ETS table.

  Owned exclusively by the scheduler process — agents never read or write
  this table.

  ## Fields

  - `id` — scheduler-assigned integer agent ID
  - `depth` — recursion depth (0 for top-level agents)
  - `status` — `:pending | :running | :waiting | :ready`
    - :pending — just registered, ready to run when a worktree is available
    - :running — currently executing in a worktree
    - :waiting — execution paused due to subagent calls
    - :ready — execution paused, all subagents completed, ready to resume
  - `worktree` — path to the assigned worktree, or `nil` when unassigned
  - `task_ref` — the `Task` monitor reference, or `nil`
  - `from` — the `GenServer.reply/2` destination for top-level agents
  - `parent_id` — the parent agent's ID, or `nil` for top-level agents
  - `spec` — the original `%AgentSpec{}` used to spawn this agent
  - `retries` — number of crash-retry attempts so far
  - `result_sent` — whether the Task has already delivered a result
  - `sub_agent_from` — `GenServer.reply/2` destination for `spawn_sub_agents` call
  - `total_sub_specs` — total number of subagent specs (for ordering results)
  - `pending_sub_agents` — `MapSet` of subagent IDs still running
  - `sub_agent_results` — `%{index => result}` accumulated subagent results by original spec index
  - `sub_agent_indices` — `%{agent_id => index}` mapping from subagent ID to original spec index
  """

  alias EvoGit.AgentSpec

  @enforce_keys [:id, :depth, :spec]
  defstruct [
    :id,
    :depth,
    :from,
    :parent_id,
    :spec,
    status: :pending,
    worktree: nil,
    task_ref: nil,
    retries: 0,
    result_sent: false,
    sub_agent_from: nil,
    total_sub_specs: 0,
    pending_sub_agents: MapSet.new(),
    sub_agent_results: %{},
    sub_agent_indices: %{}
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          depth: non_neg_integer(),
          status: :pending | :running | :waiting | :ready,
          worktree: String.t() | nil,
          task_ref: reference() | nil,
          from: GenServer.from() | nil,
          parent_id: pos_integer() | nil,
          spec: AgentSpec.t(),
          retries: non_neg_integer(),
          result_sent: boolean(),
          sub_agent_from: GenServer.from() | nil,
          total_sub_specs: non_neg_integer(),
          pending_sub_agents: MapSet.t(pos_integer()),
          sub_agent_results: %{optional(non_neg_integer()) => term()},
          sub_agent_indices: %{optional(pos_integer()) => non_neg_integer()}
        }
end
