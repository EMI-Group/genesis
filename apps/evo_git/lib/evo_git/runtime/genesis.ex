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
    # Load foreign repos: evogit.toml defaults merged with CLI-provided repos (CLI takes precedence)
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    foreign_repos = merge_foreign_repos(toml_repos, cli_repos)

    case AgentSpec.new(context_node, phylo_node, ContextExtractor, objective, foreign_repos: foreign_repos)
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
    # Load foreign repos: evogit.toml defaults merged with CLI-provided repos (CLI takes precedence)
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    foreign_repos = merge_foreign_repos(toml_repos, cli_repos)

    case AgentSpec.new(context_node, phylo_node, CodebaseArchitect, objective, foreign_repos: foreign_repos)
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        Helpers.notify_finalizing(opts)
        Helpers.merge_and_report(repo_path, agent_output, "genesis")

      error ->
        Logger.error("Genesis Mode B failed: #{inspect(error)}")
        error
    end
  end

  # Merge two foreign repo lists. CLI repos take precedence over TOML repos
  # when there's an id conflict.
  defp merge_foreign_repos(toml_repos, cli_repos) do
    toml_map = Map.new(toml_repos, &{&1.id, &1})
    cli_map = Map.new(cli_repos, &{&1.id, &1})
    Map.merge(toml_map, cli_map) |> Map.values()
  end
end
