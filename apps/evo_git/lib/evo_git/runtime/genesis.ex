defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Agent.CodebaseArchitect
  alias EvoGit.Agent.ContextExtractor
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

      agent_module = if is_new, do: CodebaseArchitect, else: ContextExtractor

      objective =
        if is_new do
          Prompts.genesis_new_codebase(root_prompt)
        else
          Prompts.genesis_existing_codebase(root_prompt)
        end

      phylo_node = PhyloGraphNode.new(repo_path, head_sha)
      {:ok, context_node} = ContextNode.load(".", repo_path)

      result =
        AgentSpec.new(context_node, phylo_node, agent_module, objective,
          event_sink: Keyword.get(opts, :event_sink, self())
        )
        |> AgentScheduler.run_agent()

      case result do
        {:ok, agent_output} ->
          final_sha = Map.get(agent_output, :commit_sha)

          if final_sha do
            Logger.info("Genesis: Merging agent changes back to main workspace...")
            case System.cmd("git", ["merge", "--no-commit", final_sha], cd: repo_path, stderr_to_stdout: true) do
              {output, 0} ->
                Logger.info("Genesis: User handoff merge successful.\n#{output}")
              {output, code} ->
                Logger.warning("Genesis: User handoff merge finished (exit code #{code}).\n#{output}")
            end
          end

          {:ok, head_now} = Git.rev_parse(repo_path)
          Logger.info("Genesis: Evolution complete. Current HEAD: #{String.slice(head_now, 0, 7)}")

          {:ok, final_sha || head_now}

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
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md"]
        _ -> []
      end

    Enum.empty?(files)
  end
end
