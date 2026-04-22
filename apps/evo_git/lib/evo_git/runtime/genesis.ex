defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Agent.CodebaseArchitect
  alias EvoGit.Agent.ContextExtractor
  require Logger

  def run(objective, opts \\ []) do
    Logger.info("Genesis: Starting with objective: #{objective}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
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
  # * Recursive Analysis: The agent spawns sub-agents for child directories/files to extract existing context and build the semantic tree structure.
  # * Fixed Point Convergence: The parent agent aggregates the context. If discrepancies exist, it spawns sub-agents to modify the child nodes.
  defp run_existing_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode A (Existing Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    {:ok, context_node} = ContextNode.load(".", repo_path)

    case AgentSpec.new(context_node, phylo_node, ContextExtractor, objective,
           event_sink: Keyword.get(opts, :event_sink, self())
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        final_sha = Map.get(agent_output, :commit_sha)
        merge_and_report(repo_path, final_sha)

      error ->
        Logger.error("Genesis Mode A failed: #{inspect(error)}")
        error
    end
  end

  # Mode B: New Codebase
  # * Planning: An agent interprets the user's prompt at the root node and drafts the initial architectural plan in the root CONTEXT.md.
  # * Recursive Realization: For each planned submodule, spawn sub-agents to initialize the corresponding child nodes and populate their CONTEXT.md files.
  # * Fixed Point Convergence: Identical to Mode A, utilizing the same Convergence Circuit Breaker to ensure the generated structure finalizes efficiently.
  defp run_new_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode B (New Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    {:ok, context_node} = ContextNode.load(".", repo_path)

    # Mode B is a two-step process in the runtime: Planning then Realization.
    # The design states:
    # 1. Planning: Draft the initial architectural plan in the root CONTEXT.md.
    # 2. Recursive Realization: Spawn sub-agents to initialize corresponding child nodes.

    planning_objective =
      "Draft the initial architectural plan in the root CONTEXT.md based on the objective: #{objective}"

    Logger.info("Genesis Mode B: Phase 1 - Planning")

    with {:ok, planning_output} <-
           AgentSpec.new(context_node, phylo_node, CodebaseArchitect, planning_objective,
             event_sink: Keyword.get(opts, :event_sink, self())
           )
           |> AgentScheduler.run_agent(),
         planning_sha = Map.get(planning_output, :commit_sha) || current_sha,
         phylo_node_realize = PhyloGraphNode.new(repo_path, planning_sha),
         realization_objective =
           "Implement and realize the initial architectural plan defined in CONTEXT.md. Initialize the corresponding child nodes and delegate focused sub-tasks to sub-agents.",
         Logger.info("Genesis Mode B: Phase 2 - Recursive Realization"),
         {:ok, realization_output} <-
           AgentSpec.new(
             context_node,
             phylo_node_realize,
             CodebaseArchitect,
             realization_objective, event_sink: Keyword.get(opts, :event_sink, self()))
           |> AgentScheduler.run_agent() do
      final_sha = Map.get(realization_output, :commit_sha)
      merge_and_report(repo_path, final_sha)
    else
      error ->
        Logger.error("Genesis Mode B failed: #{inspect(error)}")
        error
    end
  end

  defp merge_and_report(repo_path, final_sha) do
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

    {:ok, final_sha || head_now}
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
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md"]
        _ -> []
      end

    Enum.empty?(files)
  end
end
