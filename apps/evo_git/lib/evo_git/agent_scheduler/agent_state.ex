defmodule EvoGit.AgentScheduler.AgentState do
  @moduledoc """
  The live state for a running agent, stored in the `:evogit_agent_state` ETS table.

  Owned by agent processes — the scheduler writes initial values on dispatch,
  then agents update their fields as needed.

  ## Fields

  - `context` — the conversation context (ReqLLM.Context) - single source of truth
  - `context_node` — the spatial state (ContextNode) the agent is targeting
  - `phylo_node` — the temporal state (PhyloGraphNode) with worktree-bound repo path;
    `nil` before the agent is dispatched to a worktree
  - `event_sink` — pid to receive `{:agent_event, ...}` streaming messages, or `nil
  - `llm_model` — the LLM model string for this agent to use
  - `max_retries` — maximum LLM call retries for this agent
  - `max_depth` — maximum agent recursion depth
  - `parent_id` — the parent agent ID (if this is a subagent), or `nil`
  - `objective` — the objective/task the agent was given
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node, :llm_model, :max_retries, :max_depth]
  defstruct [:context, :context_node, :phylo_node, :event_sink, :llm_model, :max_retries, :max_depth, :parent_id, :objective]

  @type t :: %__MODULE__{
          context: ReqLLM.Context.t() | nil,
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t() | nil,
          event_sink: pid() | nil,
          llm_model: ReqLLM.model_input(),
          max_retries: pos_integer(),
          max_depth: pos_integer(),
          parent_id: pos_integer() | nil,
          objective: String.t() | nil
        }
end
