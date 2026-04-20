defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Adapters.Git
  require Logger

  def run(objective, opts \\ []) do
    Logger.info("Evolution: Starting for objective: #{objective}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
         {:ok, current_sha} <- PhyloGraphNode.current_head(repo_path) do
      # 1. Diagnosis
      current_node = PhyloGraphNode.new(repo_path, current_sha)
      target_path = EvoGit.Task.diagnose(current_node, objective, opts)

      Logger.info("Evolution: Diagnosed target path: #{target_path}")

      # 2. Dispatch via structured AgentScheduler API
      phylo_node = PhyloGraphNode.new(repo_path, current_sha)
      {:ok, context_node} = ContextNode.load(target_path, repo_path)

      agent_module = Keyword.get(opts, :agent_module, EvoGit.Agent.Generalist)

      case AgentSpec.new(context_node, phylo_node, agent_module, objective,
             event_sink: Keyword.get(opts, :event_sink, self())
           )
           |> AgentScheduler.run_agent() do
        {:ok, agent_output} ->
          final_sha = Map.get(agent_output, :commit_sha)

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
      File.write!(Path.join(repo_path, "README.md"), "")
      Git.add(repo_path, "README.md")

      case Git.commit(repo_path, "Initial commit") do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end
end
