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
  alias EvoGit.AgentScheduler.State
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
  @spec ensure_initialized(State.t(), String.t() | nil) :: State.t()

  def ensure_initialized(%State{initialized: true} = state), do: state

  def ensure_initialized(%State{initialized: true} = state, new_repo_path)
      when is_binary(new_repo_path) do
    new_root = Path.expand(new_repo_path)

    if Map.has_key?(state.initialized_repos, new_root) do
      state
    else
      ensure_initialized_new_repo(state, new_root, new_repo_path)
    end
  end

  def ensure_initialized(%State{initialized: true} = state, nil), do: state

  def ensure_initialized(_state, nil) do
    raise ArgumentError, "repo_path is required for initial AgentScheduler initialization"
  end

  def ensure_initialized(state, repo_path) do
    repo_root = Path.expand(repo_path)
    do_initialize(state, repo_root)
  end

  defp ensure_initialized_new_repo(%State{initialized: true} = state, new_root, new_repo_path) do
    # If agents are still running, don't tear down worktrees — just register
    # the new repo path in initialized_repos and create the worker directory.
    # Per-agent repo_root resolution (via Dispatch.resolve_agent_repo_root/2)
    # derives the correct root from spec data, so we don't need a global
    # state.repo_root.
    if state.running_count > 0 do
      initialized_keys = Map.keys(state.initialized_repos)

      Logger.warning(
        "AgentScheduler: Concurrent task targets #{new_root} while " <>
          "#{state.running_count} agent(s) still running (initialized repos: #{inspect(initialized_keys)}) — " <>
          "creating worker directory for new repo"
      )

      worker_base = Path.join(new_root, ".evogit/workers")
      File.mkdir_p!(worker_base)

      %State{state | initialized_repos: Map.put(state.initialized_repos, new_root, true)}
    else
      Logger.info(
        "AgentScheduler: Repo path changed (initialized repos: #{inspect(Map.keys(state.initialized_repos))}), reinitializing for #{new_repo_path}..."
      )

      state = teardown_worktrees(state, new_root)
      do_initialize(state, new_root)
    end
  end

  defp do_initialize(%State{} = state, repo_root) do
    worker_base = Path.join(repo_root, ".evogit/workers")

    Logger.info("AgentScheduler: Initializing worktree directory at #{worker_base}")

    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)

    # Clean up orphaned evogit-agent branches from previous runs
    clean_orphaned_branches(repo_root)

    File.mkdir_p!(worker_base)

    %State{
      state
      | initialized: true,
        initialized_repos: Map.put(state.initialized_repos, repo_root, true)
    }
  end

  @doc """
  Tears down all worktrees, marking the scheduler as uninitialized.

  Removes the worker base directory, prunes worktrees, and resets
  the initialized flag.
  """
  @spec teardown_worktrees(State.t(), String.t()) :: State.t()

  def teardown_worktrees(%State{} = state, repo_root) when is_binary(repo_root) do
    worker_base = Path.join(repo_root, ".evogit/workers")
    File.rm_rf!(worker_base)
    Git.prune_worktrees(repo_root)
    %State{state | initialized: false}
  end

  @spec teardown_worktrees(State.t()) :: State.t()
  def teardown_worktrees(%State{} = state), do: %State{state | initialized: false}

  # --- Worktree Assignment and Preparation ---

  @doc """
  Assigns the given worktree to an agent and prepares its git state.

  Cleans the worktree, checks out the agent's branch, and updates
  the agent's phylo_node with the worktree-bound repo path.
  Returns the commit SHA.
  """
  @spec assign_and_prepare_worktree(pos_integer(), String.t()) :: String.t()

  def assign_and_prepare_worktree(agent_id, wt) do
    {:ok, meta} = get_sched_meta(agent_id)
    {:ok, agent_state} = get_agent_state(agent_id)
    spec = meta.spec

    commit_sha = spec.phylo_node.current_commit

    Git.clean(wt)
    task_id = meta.task_id
    task_local_id = agent_state.task_local_id
    branch_name = "evogit-agent-T#{task_id}-A#{task_local_id}"
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
  @spec run_init_script(String.t(), String.t()) :: :ok

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

  Extracts the branch name from the directory name by replacing the
  `worker_` prefix with `evogit-agent-` (e.g., `worker_T1_A42` → `evogit-agent-T1-A42`).
  """
  @spec delete(String.t(), String.t()) :: :ok

  def delete(path, repo_root) do
    Logger.info("AgentScheduler: Deleting worktree #{path}")
    # Derive branch name from directory name (e.g., worker_T1_A42 → evogit-agent-T1-A42)
    branch_name =
      path
      |> Path.basename()
      |> String.replace_prefix("worker_", "evogit-agent-")

    File.rm_rf!(path)
    Git.prune_worktrees(repo_root)
    Git.delete_branch(repo_root, branch_name)
  end

  # --- Orphaned Branch Cleanup ---

  @doc """
  Cleans up orphaned `evogit-agent-*` branches from previous runs.

  Matches all branches with the `evogit-agent-` prefix (e.g., `evogit-agent-T1-A1`,
  `evogit-agent-T2-A5`) and deletes each one. This is called during initialization
  to prevent stale branches from accumulating.
  """
  @spec clean_orphaned_branches(String.t()) :: :ok

  def clean_orphaned_branches(repo_root) do
    case System.cmd("git", ["branch", "--list", "evogit-agent-*"], cd: repo_root) do
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
  @spec sync_current_commit(pos_integer(), EvoGit.AgentScheduler.SchedMeta.t()) ::
          EvoGit.AgentScheduler.SchedMeta.t()

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
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end

  defp get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %AgentState{} = agent_state}] -> {:ok, agent_state}
      [] -> :error
    end
  end

  defp put_agent_state(agent_id, agent_state) do
    :ets.insert(@agent_table, {agent_id, agent_state})
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end
end
