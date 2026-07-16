defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Runtime
  alias EvoGit.Agent.Result
  alias EvoGit.Runtime.Helpers
  require Logger

  def run(objective, opts \\ []) when is_list(opts) do
    node_path = Keyword.get(opts, :node_path, "./")
    starting_commit = Keyword.get(opts, :starting_commit)

    Logger.info(
      "Evolution: Starting for objective: #{objective} (node: #{node_path}, commit: #{starting_commit || "HEAD"})"
    )

    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, current_sha} <- Helpers.resolve_starting_commit(repo_path, starting_commit),
         :ok <- Helpers.validate_node_path(node_path, repo_path) do
      run_simple_mode(objective, repo_path, current_sha, node_path, opts)
    else
      {:error, {:invalid_node_path, message}} ->
        Logger.error("Evolution: Invalid node path: #{message}")
        {:error, {:invalid_node_path, message}}

      error ->
        Logger.error("Evolution failed to initialize: #{inspect(error)}")
        error
    end
  end

  # Mode A: Top-Down Evolution (Simple)
  defp run_simple_mode(objective, repo_path, current_sha, node_path, opts) do
    Logger.info("Evolution: Running Mode A (Top-Down)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(node_path, repo_path)
    # Load foreign repos: genesis.toml defaults merged with CLI-provided repos (CLI takes precedence)
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    foreign_repos = Helpers.merge_foreign_repos(toml_repos, cli_repos)

    case AgentSpec.new(context_node, phylo_node, EvoGit.Agents.Manager, objective,
           foreign_repos: foreign_repos,
           archive: Keyword.get(opts, :archive, false),
           task_id: Keyword.get(opts, :task_id),
           model_id: Keyword.get(opts, :model_id)
         )
         |> AgentScheduler.run_agent() do
      {:ok, %Result{} = agent_output} ->
        Helpers.notify_finalizing(Keyword.get(opts, :task_id))
        Helpers.merge_and_report(repo_path, agent_output, "evolve")

      error ->
        Logger.error("Evolution Mode A failed: #{inspect(error)}")
        error
    end
  end
end
