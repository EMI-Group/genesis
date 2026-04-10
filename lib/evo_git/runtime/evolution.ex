defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.WorkerPool
  alias EvoGit.Adapters.Git
  require Logger

  def run(objective, opts \\ []) do
    Logger.info("Evolution: Starting for objective: #{objective}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
         {:ok, current_sha} <- PhyloGraphNode.current_head(repo_path) do
      # 1. Diagnosis
      # Create a temporary node for diagnosis representing the main repo state
      current_node = PhyloGraphNode.new(repo_path, current_sha)
      target_path = EvoGit.Task.diagnose(current_node, objective, opts)

      Logger.info("Evolution: Diagnosed target path: #{target_path}")

      # 2. Dispatch (Single Agent)
      case WorkerPool.run(fn worktree_path ->
             # Ensure worktree is at the correct commit before ContextNode.load
             Git.clean(worktree_path)
             Git.checkout(worktree_path, current_sha)

             phylo_node = PhyloGraphNode.new(worktree_path, current_sha)

             # ContextNode.load expects a relative path
             context_node = ContextNode.load(target_path, worktree_path)

             state = %{context_node: context_node, phylo_node: phylo_node}

             EvoGit.Task.mutate(state, objective, opts)
           end) do
        {:ok, %{phylo_node: updated_node}, _agent_output} ->
          final_sha = updated_node.current_commit

          Logger.info(
            "Evolution: Evolution successful. Updating main repository to #{String.slice(final_sha, 0, 7)}"
          )

          Git.reset_hard(repo_path, final_sha)
          {:ok, final_sha}

        error ->
          Logger.error("Evolution: Agent failed: #{inspect(error)}")
          error
      end
    else
      error ->
        Logger.error("Evolution failed to initialize: #{inspect(error)}")
        error
    end
  end

  defp ensure_repo(repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) do
      :ok
    else
      Logger.info("Evolution: Initializing Git repository at #{repo_path}...")
      File.mkdir_p!(repo_path)
      Git.init(repo_path)
      # Create initial commit to allow branching
      File.write!(Path.join(repo_path, "README.md"), "")
      Git.add(repo_path, "README.md")

      case Git.commit(repo_path, "Initial commit") do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end
end
