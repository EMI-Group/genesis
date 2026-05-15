defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Agent.CodebaseArchitect
  alias EvoGit.Agent.ContextExtractor
  alias EvoGit.Runtime
  require Logger

  def run(objective, opts \\ []) do
    Logger.info("Genesis: Starting with objective: #{objective}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, head_sha} <- PhyloGraphNode.current_head(repo_path) do
      if new_codebase?(repo_path) do
        run_new_codebase(objective, repo_path, head_sha, opts)
      else
        run_existing_codebase(objective, repo_path, head_sha, opts)
      end
    else
      error ->
        Logger.error("Genesis failed to initialize: #{inspect(error)}")
        error
    end
  end

  # Mode A: Existing Codebase
  # * Root Initialization: The system spawns an investigator agent at the repository root on the latest commit.
  # * Recursive Analysis: The agent spawns subagents for child directories/files to extract existing context and build the semantic tree structure.
  # * Fixed Point Convergence: The parent agent aggregates the context. If discrepancies exist, it spawns subagents to modify the child nodes.
  defp run_existing_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode A (Existing Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(".", repo_path)

    case AgentSpec.new(context_node, phylo_node, ContextExtractor, objective,
           event_sink: Keyword.get(opts, :event_sink, self())
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        merge_and_report(repo_path, agent_output)

      error ->
        Logger.error("Genesis Mode A failed: #{inspect(error)}")
        error
    end
  end

  # Mode B: New Codebase
  # * Architecture & Skeleton: An agent interprets the user's prompt at the root node and drafts the architectural plan in the root CONTEXT.md. It creates the directory tree, optionally empty code files, and recursively spawns subagents to do this for child directories.
  # * Implementation: After the entire skeleton is established, the agent orchestrates the implementation of the code by spawning generalist subagents.
  # * Fixed Point Convergence: Identical to Mode A, utilizing the same Convergence Circuit Breaker to ensure the generated structure and code finalize efficiently.
  defp run_new_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode B (New Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(".", repo_path)

    case AgentSpec.new(context_node, phylo_node, CodebaseArchitect, objective,
           event_sink: Keyword.get(opts, :event_sink, self())
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        merge_and_report(repo_path, agent_output)

      error ->
        Logger.error("Genesis Mode B failed: #{inspect(error)}")
        error
    end
  end

  defp merge_and_report(repo_path, agent_output) do
    final_sha = Map.get(agent_output, :commit_sha)
    result = Map.get(agent_output, :result)
    tag = Map.get(agent_output, :tag)

    if final_sha do
      Logger.info("Genesis: Merging agent changes back to main workspace...")

      case Git.merge_no_commit(repo_path, final_sha) do
        {:ok, output} ->
          Logger.info("Genesis: User handoff merge successful.\n#{output}")

        {:conflict, output} ->
          Logger.warning("Genesis: User handoff merge has conflicts.\n#{output}")

        {:error, code, output} ->
          Logger.warning("Genesis: User handoff merge finished (exit code #{code}).\n#{output}")
      end
    end

    {:ok, head_now} = Git.rev_parse(repo_path)
    Logger.info("Genesis: Evolution complete. Current HEAD: #{String.slice(head_now, 0, 7)}")

    {:ok, %{commit_sha: final_sha || head_now, result: result, tag: tag}}
  end

  defp new_codebase?(repo_path) do
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md", ".evogit", ".gitignore"]
        _ -> []
      end

    Enum.empty?(files)
  end
end
