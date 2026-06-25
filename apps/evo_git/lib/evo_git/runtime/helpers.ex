defmodule EvoGit.Runtime.Helpers do
  @moduledoc "Shared helper functions for runtime phases."
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  require Logger

  @doc """
  Merges agent output and reports results. Creates a branch if changes were made.
  The `phase` argument should be "genesis" or "evolve" for logging and branch naming.
  """
  def merge_and_report(repo_path, %Result{} = agent_output, phase) do
    final_sha = agent_output.commit_sha
    result = agent_output.result
    tag = agent_output.tag

    {:ok, base_sha} = Git.rev_parse(repo_path)

    if final_sha && final_sha != base_sha do
      Logger.info(
        "#{String.capitalize(phase)}: Agent produced changes (#{String.slice(base_sha, 0, 7)} -> #{String.slice(final_sha, 0, 7)})"
      )

      branch_name = generate_branch_name(phase)
      {:ok, _} = Git.create_branch(repo_path, branch_name, final_sha)

      Logger.info(
        "#{String.capitalize(phase)}: Created branch '#{branch_name}' at #{String.slice(final_sha, 0, 7)}"
      )

      # PR creation is now manual via the Review page — no automatic PR
      {pr_url, pr_title} = {nil, nil}

      {:ok,
       %{
         commit_sha: final_sha,
         result: result,
         tag: tag,
         branch_name: branch_name,
         pr_url: pr_url,
         pr_title: pr_title,
         usage: agent_output.usage,
         agent_count: agent_output.agent_count
       }}
    else
      Logger.info(
        "#{String.capitalize(phase)}: No changes detected (base and final commit are the same)"
      )

      {:ok,
       %{
         commit_sha: final_sha || base_sha,
         result: result,
         tag: tag,
         branch_name: nil,
         pr_url: nil,
         pr_title: nil,
         no_changes: true,
         usage: agent_output.usage,
         agent_count: agent_output.agent_count
       }}
    end
  end

  def notify_finalizing(opts) do
    if task_id = Keyword.get(opts, :task_id) do
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})
    end
  end

  def generate_branch_name(prefix) do
    short_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "evogit/#{prefix}_#{short_id}"
  end

  def new_codebase?(repo_path) do
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md", ".evogit", ".gitignore"]
        _ -> []
      end

    Enum.empty?(files)
  end

  def validate_node_path("./", _repo_path), do: :ok

  def validate_node_path(node_path, repo_path) do
    if Path.type(node_path) == :absolute do
      {:error,
       {:invalid_node_path,
        "Node path must be relative to the repository root, got absolute path: #{node_path}"}}
    else
      normalized = EvoGit.Core.ContextNode.normalize_relpath(node_path)
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

  @doc """
  Merges two foreign repo lists. CLI repos take precedence over TOML repos
  when there's an id conflict.
  """
  def merge_foreign_repos(toml_repos, cli_repos) do
    toml_map = Map.new(toml_repos, &{&1.id, &1})
    cli_map = Map.new(cli_repos, &{&1.id, &1})
    Map.merge(toml_map, cli_map) |> Map.values()
  end

  def resolve_starting_commit(repo_path, nil) do
    EvoGit.Core.PhyloGraphNode.current_head(repo_path)
  end

  def resolve_starting_commit(repo_path, ref) do
    case Git.rev_parse(repo_path, ref) do
      {:ok, sha} ->
        {:ok, sha}

      error ->
        Logger.error("Invalid starting commit '#{ref}': #{inspect(error)}")
        error
    end
  end
end
