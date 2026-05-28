defmodule EvoGit.AgentScheduler.Worktrees do
  @moduledoc """
  Worktree lifecycle management for the AgentScheduler.

  Handles worktree creation, preparation, initialization scripts,
  cleanup, and orphaned branch management. All functions operate
  on the scheduler state or are pure helpers that take explicit
  parameters.
  """

  require Logger
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Platform
  alias EvoGit.ProjectConfig

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta

  # --- Initialization ---

  @doc """
  Ensures the worktree pool is initialized for the given repo path.

  Handles the following cases:
  - Already initialized with same repo → no-op
  - Already initialized with different repo → teardown and reinitialize
  - Not initialized with no path → raises
  - Not initialized with path → initialize
  """
  def ensure_initialized(state, repo_path \\ nil)

  def ensure_initialized(%{initialized: true} = state, nil), do: state

  def ensure_initialized(%{initialized: true, repo_root: repo_root} = state, new_repo_path)
      when repo_root == new_repo_path do
    state
  end

  def ensure_initialized(%{initialized: true} = state, new_repo_path) do
    Logger.info(
      "AgentScheduler: Repo path changed from #{state.repo_root} to #{new_repo_path}, reinitializing..."
    )

    state = teardown_worktrees(state)
    do_initialize(state, new_repo_path)
  end

  def ensure_initialized(_state, nil) do
    raise ArgumentError, "repo_path is required for initial AgentScheduler initialization"
  end

  def ensure_initialized(state, repo_path) do
    repo_root = Path.expand(repo_path)
    do_initialize(state, repo_root)
  end

  defp do_initialize(state, repo_root) do
    worker_base = Path.join(repo_root, ".evogit/workers")

    Logger.info("AgentScheduler: Initializing worktree directory at #{worker_base}")

    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)

    # Clean up orphaned evogit-agent branches from previous runs
    clean_orphaned_branches(repo_root)

    File.mkdir_p!(worker_base)

    {:ok, current_sha} = Git.rev_parse(repo_root)

    # Register primary repo
    primary_repo = ForeignRepo.new(:primary, repo_root)
    repos = Map.put(state.repos, :primary, primary_repo)

    %{
      state
      | initialized: true,
        repo_root: repo_root,
        repos: repos,
        base_sha: current_sha
    }
  end

  @doc """
  Tears down all worktrees, marking the scheduler as uninitialized.

  Removes the worker base directory, prunes worktrees, and resets
  the initialized flag.
  """
  def teardown_worktrees(%{repo_root: repo_root} = state) when is_binary(repo_root) do
    worker_base = Path.join(repo_root, ".evogit/workers")
    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)
    %{state | initialized: false}
  end

  def teardown_worktrees(state), do: %{state | initialized: false}

  # --- Worktree Assignment and Preparation ---

  @doc """
  Assigns the given worktree to an agent and prepares its git state.

  Cleans the worktree, checks out the agent's branch, and updates
  the agent's phylo_node with the worktree-bound repo path.
  Returns the commit SHA.
  """
  def assign_and_prepare_worktree(agent_id, wt) do
    {:ok, meta} = get_sched_meta(agent_id)
    {:ok, agent_state} = get_agent_state(agent_id)
    spec = meta.spec

    commit_sha = spec.phylo_node.current_commit

    Git.clean(wt)
    branch_name = "evogit-agent#{agent_id}"
    Git.checkout(wt, branch_name)

    # Build the worktree-bound phylo_node (repo points to worktree)
    wt_phylo_node = %EvoGit.Core.PhyloGraphNode{
      repo: wt,
      base_commit: spec.phylo_node.base_commit,
      current_commit: commit_sha
    }

    put_agent_state(agent_id, %AgentState{agent_state | phylo_node: wt_phylo_node})

    commit_sha
  end

  @doc """
  Runs the worktree initialization script if one is configured.

  The script is read from `evogit.toml` under the `[worktree]` section.
  Shell detection is done via shebang line, defaulting to the platform shell.
  Environment variables `SOURCE_REPO_PATH` and `TARGET_WORKTREE_PATH` are set.
  """
  def run_init_script(repo_root, worktree_path) do
    case ProjectConfig.worktree_script(repo_root) do
      nil ->
        :ok

      script_content ->
        Logger.info("AgentScheduler: Running worktree init script")

        # Detect shell from shebang, default to /bin/sh
        shell =
          case String.split(script_content, "\n") |> List.first() do
            "#!" <> rest -> String.trim(rest)
            _ -> Platform.shell()
          end

        cmd =
          if Platform.windows?() do
            """
            $env:SOURCE_REPO_PATH = "#{repo_root}"
            $env:TARGET_WORKTREE_PATH = "#{worktree_path}"
            Set-Location "#{repo_root}"
            #{script_content}
            """
          else
            """
            export SOURCE_REPO_PATH="#{repo_root}"
            export TARGET_WORKTREE_PATH="#{worktree_path}"
            cd "#{repo_root}"
            #{script_content}
            """
          end

        case System.cmd(shell, Platform.shell_args(cmd),
               cd: repo_root,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            if output != "" do
              Logger.info("AgentScheduler: Worktree init script output:\n#{output}")
            end

            Logger.info("AgentScheduler: Worktree init script completed successfully")

          {output, exit_code} ->
            Logger.warning(
              "AgentScheduler: Worktree init script failed with exit code #{exit_code}:\n#{output}"
            )
        end

        :ok
    end
  end

  # --- Worktree Deletion ---

  @doc """
  Deletes a worktree directory and its associated git branch.

  Extracts the agent ID from the path to derive the branch name
  (e.g., `worker_42` → `evogit-agent42`).
  """
  def delete(path, repo_root) do
    Logger.info("AgentScheduler: Deleting worktree #{path}")
    # Extract agent ID from path to derive branch name (e.g., worker_42 -> evogit-agent42)
    branch_name =
      path
      |> Path.basename()
      |> String.replace_prefix("worker_", "evogit-agent")

    File.rm_rf!(path)
    Git.prune_worktrees(repo_root)
    Git.delete_branch(repo_root, branch_name)
  end

  # --- Orphaned Branch Cleanup ---

  @doc """
  Cleans up orphaned `evogit-agent*` branches from previous runs.

  Lists all matching branches and deletes each one. This is called
  during initialization to prevent stale branches from accumulating.
  """
  def clean_orphaned_branches(repo_root) do
    case System.cmd("git", ["branch", "--list", "evogit-agent*"], cd: repo_root) do
      {output, 0} when is_binary(output) and byte_size(output) > 0 ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.each(fn branch ->
          Logger.info("AgentScheduler: Cleaning up orphaned branch #{branch}")
          Git.delete_branch(repo_root, branch)
        end)

      _ ->
        :ok
    end
  end

  # --- Commit Sync ---

  @doc """
  Syncs the current commit SHA in both agent state and sched meta.

  Reads the current HEAD SHA from the worktree and updates the
  `phylo_node.current_commit` in both ETS tables if it has changed.
  Returns the updated meta.
  """
  def sync_current_commit(agent_id, %{worktree: wt} = meta) do
    {:ok, current_sha} = Git.rev_parse(wt)
    {:ok, agent_state} = get_agent_state(agent_id)

    agent_needs_update? = agent_state.phylo_node.current_commit != current_sha
    meta_needs_update? = meta.spec.phylo_node.current_commit != current_sha

    if agent_needs_update? do
      updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
      put_agent_state(agent_id, %{agent_state | phylo_node: updated_phylo})
    end

    if meta_needs_update? do
      updated_spec_phylo = %{
        meta.spec.phylo_node
        | current_commit: current_sha
      }

      updated_spec = %{meta.spec | phylo_node: updated_spec_phylo}
      updated_meta = %{meta | spec: updated_spec}
      put_sched_meta(agent_id, updated_meta)

      updated_meta
    else
      meta
    end
  end

  # --- Private ETS Helpers ---

  # These are needed because the Worktrees module operates on ETS tables
  # that are shared with the AgentScheduler.

  defp get_sched_meta(agent_id) do
    case :ets.lookup(@sched_table, agent_id) do
      [{^agent_id, %SchedMeta{} = meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  defp put_sched_meta(agent_id, meta) do
    :ets.insert(@sched_table, {agent_id, meta})
  end

  defp get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %AgentState{} = agent_state}] -> {:ok, agent_state}
      [] -> :error
    end
  end

  defp put_agent_state(agent_id, agent_state) do
    :ets.insert(@agent_table, {agent_id, agent_state})
  end
end
