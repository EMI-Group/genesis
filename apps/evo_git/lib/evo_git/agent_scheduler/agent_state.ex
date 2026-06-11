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
  - `llm_model` — the LLM model string for this agent to use
  - `llm_generation_params` — the LLM generation parameters (temperature, max_tokens, etc.) passed to ReqLLM calls
  - `max_retries` — maximum LLM call retries for this agent
  - `max_depth` — maximum agent recursion depth
  - `max_turns` — maximum turns per agent loop
  - `parent_id` — the parent agent ID (if this is a subagent), or `nil`
  - `objective` — the objective/task the agent was given
  - `repo_id` — atom identifying which repo this agent belongs to (`:primary` for main, or a foreign repo id)
  - `repo_root` — absolute filesystem path to the repo root (for display/grouping). Set from scheduler state at registration.
  - `task_local_id` — per-task agent number (starts at 1 for each task), used for display and workspace/branch naming
  - `foreign_repos` — list of foreign repos available to this agent (inherited from parent; root agents get this from CLI opts or evogit.toml)
  - `usage` — cumulative token and cost usage for this agent (`nil` until the first LLM call completes)
  """

  alias EvoGit.Agent.Usage
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node, :llm_model, :max_retries, :max_depth]
  defstruct [:context, :context_node, :phylo_node, :llm_model, :max_retries, :max_depth, :max_turns, :parent_id, :objective, :task_local_id, usage: nil, llm_generation_params: [], repo_id: :primary, repo_root: nil, foreign_repos: []]

  @type t :: %__MODULE__{
          context: ReqLLM.Context.t() | nil,
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t() | nil,
          llm_model: ReqLLM.model_input(),
          llm_generation_params: keyword(),
          max_retries: pos_integer(),
          max_depth: pos_integer(),
          max_turns: pos_integer(),
          parent_id: pos_integer() | nil,
          objective: String.t() | nil,
          repo_id: atom(),
          repo_root: String.t() | nil,
          task_local_id: pos_integer() | nil,
          usage: Usage.t() | nil,
          foreign_repos: [ForeignRepo.t()]
        }
end
