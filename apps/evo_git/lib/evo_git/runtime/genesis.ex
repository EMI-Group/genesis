defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Agents.CodebaseArchitect
  alias EvoGit.Agents.ContextExtractor
  alias EvoGit.Runtime
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
    context_node = ContextNode.load("./", repo_path)

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
    context_node = ContextNode.load("./", repo_path)

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

    # Get the base commit (HEAD before any agent work)
    {:ok, base_sha} = Git.rev_parse(repo_path)

    # Check if the agent made any changes
    if final_sha && final_sha != base_sha do
      Logger.info(
        "Genesis: Agent produced changes (#{String.slice(base_sha, 0, 7)} -> #{String.slice(final_sha, 0, 7)})"
      )

      # Create a branch for the agent's final commit
      branch_name = generate_branch_name("genesis")
      {:ok, _} = Git.create_branch(repo_path, branch_name, final_sha)
      Logger.info("Genesis: Created branch '#{branch_name}' at #{String.slice(final_sha, 0, 7)}")

      # Try to create a PR if gh is available
      pr_url = try_create_pull_request(repo_path, branch_name, result)

      {:ok,
       %{
         commit_sha: final_sha,
         result: result,
         tag: tag,
         branch_name: branch_name,
         pr_url: pr_url
       }}
    else
      Logger.info("Genesis: No changes detected (base and final commit are the same)")

      {:ok,
       %{
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
           {:ok, _current_branch} <- Git.current_branch(repo_path) do
        base_branch = case Git.origin_default_branch(repo_path) do
          {:ok, origin_default} -> origin_default
        end

        # Get the configured GitHub username
        github_username = EvoGit.Defaults.github_username()

        # Format PR body with header and agent result
        pr_title = "EvoGit: #{head_branch}"
        pr_body = format_pr_body(github_username, agent_result)

        # Push the branch to remote first
        case Git.push_branch(repo_path, head_branch) do
          {:ok, _} ->
            Logger.info("Genesis: Pushed branch '#{head_branch}' to remote")

            case Git.create_pull_request(repo_path, head_branch, base_branch, pr_title, pr_body) do
              {:ok, pr_url} ->
                Logger.info("Genesis: Created pull request: #{pr_url}")
                pr_url

              {:error, _code, output} ->
                Logger.warning("Genesis: Failed to create pull request: #{output}")
                nil
            end

          {:error, _code, output} ->
            Logger.warning("Genesis: Failed to push branch '#{head_branch}': #{output}")
            nil

          {:conflict, output} ->
            Logger.warning("Genesis: Conflict pushing branch '#{head_branch}': #{output}")
            nil
        end
      else
        {:error, _code, output} ->
          Logger.warning("Genesis: Failed to create remote repository: #{output}")
          nil

        _ ->
          Logger.warning("Genesis: Failed to set up remote repository")
          nil
      end
    else
      Logger.info("Genesis: 'gh' CLI not available, skipping PR creation")
      nil
    end
  end

  defp create_remote_repo_and_continue(repo_path) do
    Logger.info("Genesis: No origin remote found, creating remote repository...")

    case Git.create_origin_remote(repo_path) do
      {:ok, repo_url} ->
        Logger.info("Genesis: Created remote repository: #{repo_url}")
        true

      {:error, _code, output} ->
        Logger.warning("Genesis: Failed to create remote repository: #{output}")
        false
    end
  end

  defp format_pr_body(github_username, agent_result) do
    """
    ## 🤖 Auto-generated by EvoGit

    This pull request was automatically created by **EvoGit** for @#{github_username}.

    ---

    #{agent_result}
    """
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
