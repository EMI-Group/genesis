defmodule EvoGit.AgentSpec do
  @moduledoc """
  A structured specification for spawning an agent through the AgentScheduler.

  Contains all the information the scheduler needs to prepare a worktree,
  register the agent, and begin execution:

  - `context_node` — the spatial state (ContextNode)
  - `phylo_node` — the temporal state (PhyloGraphNode)
  - `agent_module` — the module implementing `use EvoGit.Agent`
  - `objective` — a natural language directive string
  - `repo_id` — string identifying which repo this agent belongs to (`"primary"` for the main project, or a foreign repo id). Determines where worktrees are created and which git database is used.
  - `opts` — keyword list of options
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node, :phylo_node, :agent_module, :objective]
  defstruct [
    :context_node,
    :phylo_node,
    :agent_module,
    :objective,
    :model_id,
    repo_id: "primary",
    opts: [],
    foreign_repos: []
  ]

  @type t :: %__MODULE__{
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t(),
          agent_module: module(),
          objective: String.t(),
          model_id: String.t() | nil,
          repo_id: String.t(),
          opts: keyword(),
          foreign_repos: [ForeignRepo.t()]
        }

  @doc """
  Creates a new AgentSpec.

  ## Options

  - `:repo_id` — string identifying which repo this agent belongs to (`"primary"` for main, or a foreign repo id)
  - `:model_id` — the model profile id to bind this agent to (`nil` → scheduler resolves the default profile)
  - `:foreign_repos` — list of foreign repos available to this agent
  - `:archive` — whether task archiving is enabled
  - `:task_id` — optional explicit task ID override
  """
  @spec new(ContextNode.t(), PhyloGraphNode.t(), module(), String.t(), keyword()) :: t()
  def new(context_node, phylo_node, agent_module, objective, opts \\ []) do
    %__MODULE__{
      context_node: context_node,
      phylo_node: phylo_node,
      agent_module: agent_module,
      objective: objective,
      model_id: Keyword.get(opts, :model_id),
      repo_id: Keyword.get(opts, :repo_id, "primary"),
      opts: opts,
      foreign_repos: Keyword.get(opts, :foreign_repos, [])
    }
  end
end
