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
  - `llm_model` — the LLM model string for this agent to use
  - `max_retries` — maximum LLM call retries for this agent
  - `max_depth` — maximum agent recursion depth
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node, :llm_model, :max_retries, :max_depth]
  defstruct [:context_node, :phylo_node, :event_sink, :llm_model, :max_retries, :max_depth]

  @type t :: %__MODULE__{
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t() | nil,
          event_sink: pid() | nil,
          llm_model: String.t(),
          max_retries: pos_integer(),
          max_depth: pos_integer()
        }
end
