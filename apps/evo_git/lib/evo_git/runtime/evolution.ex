defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Adapters.Git
  alias EvoGit.Runtime
  alias EvoGit.Runtime.PullRequest
  require Logger

  def run(objective, opts \\ []) do
    mode = Keyword.get(opts, :mode, :simple)
    node_path = Keyword.get(opts, :node_path, "./")

    Logger.info("Evolution: Starting for objective: #{objective} (mode: #{mode}, node: #{node_path})")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    foreign_repos = Keyword.get(opts, :foreign_repos, [])
    if foreign_repos != [] do
      EvoGit.AgentScheduler.register_foreign_repos(foreign_repos)
    end

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, current_sha} <- PhyloGraphNode.current_head(repo_path),
         :ok <- validate_node_path(node_path, repo_path) do
      case mode do
        :simple -> run_simple_mode(objective, repo_path, current_sha, node_path, opts)
        :complex -> run_complex_mode(objective, repo_path, current_sha, node_path, opts)
      end
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
  # Used for clear tasks with well-defined objectives.
  # The Manager agent plans and delegates the task to appropriate subagents.
  defp run_simple_mode(objective, repo_path, current_sha, node_path, opts) do
    Logger.info("Evolution: Running Mode A (Top-Down)")

    # Use Manager agent for Mode A
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(node_path, repo_path)

    # Manager plans and delegates the task to appropriate subagents
    case AgentSpec.new(context_node, phylo_node, EvoGit.Agents.Manager, objective,
           event_sink: Keyword.get(opts, :event_sink, self())
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        notify_finalizing(opts)
        merge_and_report(repo_path, agent_output, objective)

      error ->
        Logger.error("Evolution Mode A failed: #{inspect(error)}")
        error
    end
  end

  defp run_complex_mode(objective, repo_path, current_sha, node_path, opts) do
    Logger.info("Evolution: Running Mode B (Open-Ended/Bottom-Up)")

    case EvoGit.Runtime.Evolution.Engine.run(objective, repo_path, current_sha, node_path, opts) do
      {:ok, agent_output} ->
        notify_finalizing(opts)
        merge_and_report(repo_path, agent_output, objective)

      error ->
        Logger.error("Evolution Mode B failed: #{inspect(error)}")
        error
    end
  end

  defp merge_and_report(repo_path, agent_output, objective) do
    final_sha = agent_output.commit_sha
    result = agent_output.result
    tag = agent_output.tag

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
      {pr_url, pr_title} = PullRequest.try_create(repo_path, branch_name, objective, result)

      {:ok, %{
        commit_sha: final_sha,
        result: result,
        tag: tag,
        branch_name: branch_name,
        pr_url: pr_url,
        pr_title: pr_title
      }}
    else
      Logger.info("Evolution: No changes detected (base and final commit are the same)")
      {:ok, %{
        commit_sha: final_sha || base_sha,
        result: result,
        tag: tag,
        branch_name: nil,
        pr_url: nil,
        pr_title: nil,
        no_changes: true
      }}
    end
  end

  defp notify_finalizing(opts) do
    if task_id = Keyword.get(opts, :task_id) do
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})
    end
  end

  defp generate_branch_name(prefix) do
    short_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "evogit/#{prefix}_#{short_id}"
  end

  defp validate_node_path("./", _repo_path), do: :ok

  defp validate_node_path(node_path, repo_path) do
    if Path.type(node_path) == :absolute do
      {:error, {:invalid_node_path, "Node path must be relative to the repository root, got absolute path: #{node_path}"}}
    else
      normalized = ContextNode.normalize_relpath(node_path)
      abs_path = Path.join(repo_path, String.trim_leading(normalized, "./"))

      cond do
        not File.dir?(abs_path) ->
          {:error, {:invalid_node_path, "Directory does not exist: #{node_path}"}}

        not File.exists?(Path.join(abs_path, "CONTEXT.md")) ->
          {:error, {:invalid_node_path, "No CONTEXT.md found at: #{node_path}"}}

        true ->
          :ok
      end
    end
  end
end
