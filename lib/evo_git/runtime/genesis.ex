defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.Agent.CodebaseArchitect
  alias EvoGit.Agent.CodebaseInvestigator
  alias EvoGit.Runtime.Prompts
  require Logger

  def run(root_prompt, opts \\ []) do
    Logger.info("Genesis: Starting with root prompt: #{root_prompt}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
         {:ok, head_sha} <- PhyloGraphNode.current_head(repo_path) do
      is_new = new_codebase?(repo_path)

      mode = if is_new, do: "Mode B (New Codebase)", else: "Mode A (Existing Codebase)"
      Logger.info("Genesis: Detected #{mode}")

      agent_module = if is_new, do: CodebaseArchitect, else: CodebaseInvestigator

      objective =
        if is_new do
          Prompts.genesis_new_codebase(root_prompt)
        else
          Prompts.genesis_existing_codebase(root_prompt)
        end

      result =
        AgentScheduler.run_agent(fn worktree_path ->
          Git.clean(worktree_path)
          Git.checkout(worktree_path, head_sha)

          phylo_node = PhyloGraphNode.new(worktree_path, head_sha)
          {:ok, context_node} = ContextNode.load(".", worktree_path)

          state = %{context_node: context_node, phylo_node: phylo_node}

          EvoGit.Task.mutate(state, objective, Keyword.put(opts, :agent_module, agent_module))
        end)

      case result do
        {:ok, %{phylo_node: updated_node}, _agent_output} ->
          final_sha = updated_node.current_commit

          Logger.info(
            "Genesis: Evolution complete. Updating main repository to #{String.slice(final_sha, 0, 7)}"
          )

          Git.reset_hard(repo_path, final_sha)
          {:ok, final_sha}

        error ->
          Logger.error("Genesis failed: #{inspect(error)}")
          error
      end
    else
      error ->
        Logger.error("Genesis failed to initialize: #{inspect(error)}")
        error
    end
  end

  defp ensure_repo(repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) do
      :ok
    else
      Logger.info("Genesis: Initializing Git repository at #{repo_path}...")
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

  defp new_codebase?(repo_path) do
    # A codebase is considered new if it has almost no files tracked/present
    # Ignore .git and README.md
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md"]
        _ -> []
      end

    Enum.empty?(files)
  end
end
