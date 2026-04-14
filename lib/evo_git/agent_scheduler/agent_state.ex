defmodule EvoGit.AgentScheduler.AgentState do
  @moduledoc """
  The live spatial/temporal state for a running agent, stored in the
  `:evogit_agent_state` ETS table.

  Owned by agent processes — the scheduler writes initial values on dispatch,
  then agents update `phylo_node` after each commit via
  `AgentScheduler.update_phylo_node/2`.

  ## Fields

  - `context_node` — the spatial state (ContextNode) the agent is targeting
  - `phylo_node` — the temporal state (PhyloGraphNode) with worktree-bound repo path;
    `nil` before the agent is dispatched to a worktree
  - `event_sink` — pid to receive `{:agent_event, ...}` streaming messages, or `nil`
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node]
  defstruct [:context_node, :phylo_node, :event_sink]

  @type t :: %__MODULE__{
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t() | nil,
          event_sink: pid() | nil
        }
end
