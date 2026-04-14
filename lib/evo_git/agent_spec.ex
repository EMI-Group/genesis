defmodule EvoGit.AgentSpec do
  @moduledoc """
  A structured specification for spawning an agent through the AgentScheduler.

  Contains all the information the scheduler needs to prepare a worktree,
  register the agent, and begin execution:

  - `context_node` — the spatial state (ContextNode)
  - `phylo_node` — the temporal state (PhyloGraphNode)
  - `agent_module` — the module implementing `use EvoGit.Agent`
  - `objective` — a natural language directive string
  - `opts` — keyword list of options (e.g., `caller_pid`)
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node, :phylo_node, :agent_module, :objective]
  defstruct [:context_node, :phylo_node, :agent_module, :objective, opts: []]

  @type t :: %__MODULE__{
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t(),
          agent_module: module(),
          objective: String.t(),
          opts: keyword()
        }

  @doc """
  Creates a new AgentSpec.
  """
  @spec new(ContextNode.t(), PhyloGraphNode.t(), module(), String.t(), keyword()) :: t()
  def new(context_node, phylo_node, agent_module, objective, opts \\ []) do
    %__MODULE__{
      context_node: context_node,
      phylo_node: phylo_node,
      agent_module: agent_module,
      objective: objective,
      opts: opts
    }
  end
end
