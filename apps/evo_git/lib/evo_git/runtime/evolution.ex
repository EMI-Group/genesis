defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Adapters.Git
  require Logger

  def run(objective, opts \\ []) do
    mode = Keyword.get(opts, :mode, :simple)

    Logger.info("Evolution: Starting for objective: #{objective} (mode: #{mode})")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
         {:ok, current_sha} <- PhyloGraphNode.current_head(repo_path) do
      case mode do
        :simple -> run_simple_mode(objective, repo_path, current_sha, opts)
        :complex -> run_complex_mode(objective, repo_path, current_sha, opts)
      end
    else
      error ->
        Logger.error("Evolution failed to initialize: #{inspect(error)}")
        error
    end
  end

  # Mode A: Top-Down Evolution (Simple)
  # Used for clear tasks with well-defined objectives.
  # The Planner agent orchestrates the entire process.
  defp run_simple_mode(objective, repo_path, current_sha, opts) do
    Logger.info("Evolution: Running Mode A (Top-Down)")

    # Use Planner agent as the orchestrator for Mode A
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    {:ok, context_node} = ContextNode.load(".", repo_path)

    # Planner spawns executors and evaluator via sub-agent delegation
    case AgentSpec.new(context_node, phylo_node, EvoGit.Agent.Planner, objective,
           event_sink: Keyword.get(opts, :event_sink, self())
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        final_sha = Map.get(agent_output, :commit_sha)
        merge_and_report(repo_path, final_sha)

      error ->
        Logger.error("Evolution Mode A failed: #{inspect(error)}")
        error
    end
  end

  # Mode B: Bottom-Up Evolution (Complex)
  # Used for open-ended tasks requiring exploration.
  # NOT YET IMPLEMENTED - falls back to simple mode with warning.
  defp run_complex_mode(objective, repo_path, current_sha, opts) do
    Logger.warning("Evolution: Mode B (Complex/Bottom-Up) is not yet implemented, falling back to Mode A")

    # Fallback to Mode A for now
    run_simple_mode(objective, repo_path, current_sha, opts)
  end

  defp merge_and_report(repo_path, final_sha) do
    if final_sha do
      Logger.info("Evolution: Merging agent changes back to main workspace...")
      case Git.merge_no_commit(repo_path, final_sha) do
        {:ok, output} ->
          Logger.info("Evolution: User handoff merge successful.\n#{output}")

        {:conflict, output} ->
          Logger.warning("Evolution: User handoff merge has conflicts.\n#{output}")

        {:error, code, output} ->
          Logger.warning("Evolution: User handoff merge finished (exit code #{code}).\n#{output}")
      end
    end

    {:ok, head_now} = Git.rev_parse(repo_path)
    Logger.info(
      "Evolution: Evolution successful. Current HEAD: #{String.slice(head_now, 0, 7)}"
    )

    {:ok, final_sha || head_now}
  end

  defp ensure_repo(repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) do
      :ok
    else
      Logger.info("Evolution: Initializing Git repository at #{repo_path}...")
      File.mkdir_p!(repo_path)
      Git.init(repo_path)
      File.write!(Path.join(repo_path, "README.md"), "")
      Git.add(repo_path, "README.md")

      case Git.commit(repo_path, "Initial commit") do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end
end
