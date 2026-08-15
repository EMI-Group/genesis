defmodule EvoGit.Runtime.Helpers do
  @moduledoc "Shared helper functions for runtime phases."
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  require Logger

  @doc """
  Merges agent output and reports results. Creates a branch if changes were made.
  The `phase` argument should be "genesis" or "evolve" for logging and branch naming.
  """
  def merge_and_report(repo_path, %Result{} = agent_output, phase) when is_binary(phase) do
    final_sha = agent_output.commit_sha

    with {:ok, base_sha} <- Git.rev_parse(repo_path) do
      if final_sha && final_sha != base_sha do
        Logger.info(
          "#{String.capitalize(phase)}: Agent produced changes (#{binary_part(base_sha, 0, 7)} -> #{binary_part(final_sha, 0, 7)})"
        )

        branch_name = generate_branch_name(phase)

        case Git.create_branch(repo_path, branch_name, final_sha) do
          {:ok, _} ->
            Logger.info(
              "#{String.capitalize(phase)}: Created branch '#{branch_name}' at #{binary_part(final_sha, 0, 7)}"
            )

            {:ok, report_map(agent_output, final_sha, branch_name)}

          error ->
            Logger.error(
              "#{String.capitalize(phase)}: Failed to create branch '#{branch_name}': #{inspect(error)}"
            )

            # Still return success — the agent's work is committed, we just couldn't
            # create a named branch. The commit_sha is still valid.
            {:ok, report_map(agent_output, final_sha, nil)}
        end
      else
        Logger.info(
          "#{String.capitalize(phase)}: No changes detected (base and final commit are the same)"
        )

        {:ok, report_map(agent_output, final_sha || base_sha, nil, true)}
      end
    else
      error ->
        Logger.error("#{String.capitalize(phase)}: Failed to resolve base SHA: #{inspect(error)}")
        # Return the agent's result anyway — the work IS done, we just couldn't
        # do post-processing. Mark commit_sha as the agent's final_sha.
        {:ok, report_map(agent_output, final_sha, nil)}
    end
  end

  defp report_map(agent_output, commit_sha, branch_name, no_changes \\ false) do
    base = %{
      commit_sha: commit_sha,
      result: agent_output.result,
      tag: agent_output.tag,
      branch_name: branch_name,
      pr_url: nil,
      pr_title: nil,
      usage: agent_output.usage,
      agent_count: agent_output.agent_count,
      archive_records: agent_output.archive_records
    }

    if no_changes, do: Map.put(base, :no_changes, true), else: base
  end

  def notify_finalizing(nil), do: :ok

  def notify_finalizing(task_id) when is_binary(task_id) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})
  end

  def generate_branch_name(_prefix) do
    short_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "genesis/agent_#{short_id}"
  end

  def new_codebase?(repo_path) do
    files =
      case File.ls(repo_path) do
        {:ok, items} -> items -- [".git", "README.md", ".genesis", ".gitignore"]
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

  @doc """
  Loads foreign repos for a runtime phase: `genesis.toml` defaults merged with
  CLI-provided repos (CLI takes precedence).
  """
  def load_foreign_repos(repo_path, opts) do
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    merge_foreign_repos(toml_repos, cli_repos)
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

  @doc """
  Resolves the root-agent module and opts for a runtime phase.

  - `:agent` absent (nil) or an empty string → `{default_module, []}` — the
    phase's built-in root agent runs unchanged.
  - `:agent` set to a custom agent id → `{EvoGit.Agents.Custom, [custom_agent_id: id]}` —
    the generic `EvoGit.Agents.Custom` module runs as the root agent and resolves
    the definition from `agents.toml` at run time.
  - `:agent` set to an UNKNOWN id → raises `ArgumentError` with a descriptive
    message. Crashing loudly is intentional: this runs in the task process (not a
    GenServer), and a bad agent id is a spec error — a silent fallback to the
    default agent would run the task with the wrong agent.
  """
  @spec resolve_root_agent(keyword(), module()) :: {module(), keyword()}
  def resolve_root_agent(opts, default_module) do
    case Keyword.get(opts, :agent) do
      id when id in [nil, ""] ->
        {default_module, []}

      id ->
        case EvoGit.CustomAgents.get(id) do
          nil ->
            config_dir = EvoGit.Config.config_dir()

            raise ArgumentError,
                  "Unknown custom agent id '#{id}'. Define it in " <>
                    "#{config_dir}/agents.toml (config dir: #{config_dir})."

          _definition ->
            {EvoGit.Agents.Custom, [custom_agent_id: id]}
        end
    end
  end

  @doc """
  Determines whether the model-selection script must be skipped for this task.

  Returns true when either:
  - `:model_id` is a non-nil value — a non-nil `:model_id` in runtime opts means
    a user/dashboard explicitly chose a model, so the model-selection script must
    NOT override it; or
  - `:model_id_locked` is explicitly true — a pass-through for cases where the
    lock exists without an id (e.g. the CLI `-m` bare-model override).
  """
  @spec model_id_locked?(keyword()) :: boolean()
  def model_id_locked?(opts) do
    Keyword.get(opts, :model_id_locked, false) || not is_nil(Keyword.get(opts, :model_id))
  end
end
