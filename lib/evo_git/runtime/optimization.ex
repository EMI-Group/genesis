defmodule EvoGit.Runtime.Optimization do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Agent
  alias EvoGit.Core.PhyloGraphNode
  require Logger

  def run(objective) do
    Logger.info("Optimization: Starting for objective: #{objective}")

    {:ok, current_sha} = PhyloGraphNode.current_head()

    # 1. Diagnosis
    target_path = Agent.diagnose(current_sha, objective)

    Logger.info("Optimization: Diagnosed target path: #{target_path}")

    # 2. Dispatch (Single Agent)
    state = %{commit_sha: current_sha, node_path: target_path}

    case Agent.mutate(state, objective) do
      {:ok, new_state} ->
        Logger.info(
          "Optimization: Evolution successful. New commit: #{String.slice(new_state.commit_sha, 0, 7)}"
        )

        {:ok, new_state.commit_sha}

      error ->
        Logger.error("Optimization: Agent failed: #{inspect(error)}")
        error
    end
  end
end