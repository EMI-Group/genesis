defmodule EvoGit.Runtime.Optimization do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Agent
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.WorkerPool
  require Logger

  def run(objective, _opts \\ []) do
    Logger.info("Optimization: Starting for objective: #{objective}")

    {:ok, current_sha} = PhyloGraphNode.current_head()

    # 1. Diagnosis
    # Create a temporary node for diagnosis representing the main repo state
    current_node = PhyloGraphNode.new(File.cwd!(), current_sha)
    target_path = Agent.diagnose(current_node, objective)

    Logger.info("Optimization: Diagnosed target path: #{target_path}")

    # 2. Dispatch (Single Agent)

    case WorkerPool.run(fn worktree_path ->
           phylo_node = PhyloGraphNode.new(worktree_path, current_sha)
           abs_target_path = Path.join(worktree_path, target_path)
           context_node = ContextNode.load(abs_target_path, worktree_path)

           state = %{context_node: context_node, phylo_node: phylo_node}

           Agent.mutate(state, objective)
         end) do
      {:ok, %{phylo_node: updated_node}} ->
        Logger.info(
          "Optimization: Evolution successful. New commit: #{String.slice(updated_node.current_commit, 0, 7)}"
        )

        {:ok, updated_node.current_commit}

      error ->
        Logger.error("Optimization: Agent failed: #{inspect(error)}")
        error
    end
  end
end
