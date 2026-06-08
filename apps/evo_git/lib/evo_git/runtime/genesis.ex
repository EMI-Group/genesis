defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Agents.CodebaseArchitect
  alias EvoGit.Agents.ContextExtractor
  alias EvoGit.Runtime
  alias EvoGit.Runtime.Helpers
  require Logger

  def run(objective, opts \\ []) do
    Logger.info("Genesis: Starting with objective: #{objective}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    foreign_repos = Keyword.get(opts, :foreign_repos, [])

    if foreign_repos != [] do
      EvoGit.AgentScheduler.register_foreign_repos(foreign_repos)
    end

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, head_sha} <- PhyloGraphNode.current_head(repo_path) do
      if Helpers.new_codebase?(repo_path) do
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
  defp run_existing_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode A (Existing Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load("./", repo_path)

    case AgentSpec.new(context_node, phylo_node, ContextExtractor, objective)
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        Helpers.notify_finalizing(opts)
        Helpers.merge_and_report(repo_path, agent_output, "genesis")

      error ->
        Logger.error("Genesis Mode A failed: #{inspect(error)}")
        error
    end
  end

  # Mode B: New Codebase
  defp run_new_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode B (New Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load("./", repo_path)

    case AgentSpec.new(context_node, phylo_node, CodebaseArchitect, objective)
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        Helpers.notify_finalizing(opts)
        Helpers.merge_and_report(repo_path, agent_output, "genesis")

      error ->
        Logger.error("Genesis Mode B failed: #{inspect(error)}")
        error
    end
  end
end
