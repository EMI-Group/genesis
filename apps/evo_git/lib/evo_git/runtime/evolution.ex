defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Adapters.Git
  alias EvoGit.Runtime
  require Logger

  def run(objective, opts \\ []) do
    mode = Keyword.get(opts, :mode, :simple)

    Logger.info("Evolution: Starting for objective: #{objective} (mode: #{mode})")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- Runtime.ensure_repo(repo_path),
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
  # The Manager agent plans and delegates the task to appropriate subagents.
  defp run_simple_mode(objective, repo_path, current_sha, opts) do
    Logger.info("Evolution: Running Mode A (Top-Down)")

    # Use Manager agent for Mode A
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(".", repo_path)

    # Manager plans and delegates the task to appropriate subagents
    case AgentSpec.new(context_node, phylo_node, EvoGit.Agent.Manager, objective,
           event_sink: Keyword.get(opts, :event_sink, self())
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        merge_and_report(repo_path, agent_output)

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

  defp merge_and_report(repo_path, agent_output) do
    final_sha = Map.get(agent_output, :commit_sha)
    result = Map.get(agent_output, :result)
    tag = Map.get(agent_output, :tag)

    # Get the base commit (HEAD before any agent work)
    {:ok, base_sha} = Git.rev_parse(repo_path)

    # Check if the agent made any changes
    if final_sha && final_sha != base_sha do
      Logger.info("Evolution: Agent produced changes (#{String.slice(base_sha, 0, 7)} -> #{String.slice(final_sha, 0, 7)})")

      # Create a branch for the agent's final commit
      branch_name = generate_branch_name("evolve")
      {:ok, _} = Git.create_branch(repo_path, branch_name, final_sha)
      Logger.info("Evolution: Created branch '#{branch_name}' at #{String.slice(final_sha, 0, 7)}")

      # Try to create a PR if gh is available
      pr_url = try_create_pull_request(repo_path, branch_name, result)

      {:ok, %{
        commit_sha: final_sha,
        result: result,
        tag: tag,
        branch_name: branch_name,
        pr_url: pr_url
      }}
    else
      Logger.info("Evolution: No changes detected (base and final commit are the same)")
      {:ok, %{
        commit_sha: final_sha || base_sha,
        result: result,
        tag: tag,
        branch_name: nil,
        pr_url: nil,
        no_changes: true
      }}
    end
  end

  defp generate_branch_name(prefix) do
    short_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "evogit/#{prefix}_#{short_id}"
  end

  defp try_create_pull_request(repo_path, head_branch, agent_result) do
    if Git.gh_available?() do
      # Check if origin remote exists, create if not
      with true <-
             Git.has_origin_remote?(repo_path) or
               create_remote_repo_and_continue(repo_path),
           {:ok, current_branch} <- Git.current_branch(repo_path) do
        base_branch = if current_branch == "HEAD", do: "main", else: current_branch

        # Try to get origin's default branch
        base_branch =
          case Git.origin_default_branch(repo_path) do
            {:ok, origin_default} -> origin_default
            _ -> base_branch
          end

        # Get the configured GitHub username
        github_username = EvoGit.Defaults.github_username()

        # Format PR body with header and agent result
        pr_title = "EvoGit: #{head_branch}"
        pr_body = format_pr_body(github_username, agent_result)

        # Push the branch to remote first
        case Git.push_branch(repo_path, head_branch) do
          {:ok, _} ->
            Logger.info("Evolution: Pushed branch '#{head_branch}' to remote")

            case Git.create_pull_request(repo_path, head_branch, base_branch, pr_title, pr_body) do
              {:ok, pr_url} ->
                Logger.info("Evolution: Created pull request: #{pr_url}")
                pr_url

              {:error, _code, output} ->
                Logger.warning("Evolution: Failed to create pull request: #{output}")
                nil
            end

          {:error, _code, output} ->
            Logger.warning("Evolution: Failed to push branch '#{head_branch}': #{output}")
            nil

          {:conflict, output} ->
            Logger.warning("Evolution: Conflict pushing branch '#{head_branch}': #{output}")
            nil
        end
      else
        {:error, _code, output} ->
          Logger.warning("Evolution: Failed to create remote repository: #{output}")
          nil
      end
    else
      Logger.info("Evolution: 'gh' CLI not available, skipping PR creation")
      nil
    end
  end

  defp create_remote_repo_and_continue(repo_path) do
    Logger.info("Evolution: No origin remote found, creating remote repository...")

    case Git.create_origin_remote(repo_path) do
      {:ok, repo_url} ->
        Logger.info("Evolution: Created remote repository: #{repo_url}")
        true

      {:error, _code, output} ->
        Logger.warning("Evolution: Failed to create remote repository: #{output}")
        false
    end
  end

  defp format_pr_body(github_username, agent_result) do
    """
    ## 🤖 Auto-generated by EvoGit

    This pull request was automatically created by **EvoGit** for @#{github_username}.

    ---

    ## Agent Result

    #{agent_result}
    """
  end
end
