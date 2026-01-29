defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase"
  alias EvoGit.Agent
  alias EvoGit.Adapters.Git
  require Logger

  def run(root_prompt) do
    Logger.info("Genesis: Starting with root prompt: #{root_prompt}")

    # 1. Initialize Root
    {:ok, head_sha} = Git.rev_parse(File.cwd!())

    # Create Root Context
    initial_state = %{commit_sha: head_sha, node_path: "."}

    objective =
      "Create the top-level CONTEXT.md defining the architecture based on: #{root_prompt}. Create only the CONTEXT.md file and directory structure (empty dirs are fine)."

    case Agent.mutate(initial_state, objective) do
      {:ok, root_state} ->
        Logger.info(
          "Genesis: Root context created at #{String.slice(root_state.commit_sha, 0, 7)}"
        )

        # 2. Recursive Expansion
        expand(root_state.commit_sha, [])

      {:error, reason} ->
        Logger.error("Genesis: Root agent failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp expand(current_sha, visited) do
    # Find all directories in current SHA
    case Git.run(["ls-tree", "-r", "-d", "--name-only", current_sha], File.cwd!()) do
      {:ok, output} ->
        all_dirs = String.split(output, "\n", trim: true)

        # Candidates are directories not yet visited
        candidates = all_dirs -- visited

        if candidates == [] do
          Logger.info("Genesis: Expansion complete.")
          {:ok, current_sha}
        else
          # BFS: Pick shallowest
          next_dir = Enum.min_by(candidates, fn p -> length(Path.split(p)) end)

          Logger.info("Genesis: Expanding #{next_dir}")

          state = %{commit_sha: current_sha, node_path: next_dir}

          objective =
            "Implement the context and structure for this directory based on the parent context. Create CONTEXT.md if it is a structural directory, or source files if it is a leaf."

          case Agent.mutate(state, objective) do
            {:ok, new_state} ->
              expand(new_state.commit_sha, [next_dir | visited])

            {:error, reason} ->
              Logger.error("Genesis: Failed to expand #{next_dir}: #{inspect(reason)}")
              # If expansion fails, do we abort or skip?
              # Let's abort for now to avoid broken state.
              {:error, reason}
          end
        end

      error ->
        Logger.error("Genesis: Failed to list directories: #{inspect(error)}")
        error
    end
  end
end
