defmodule EvoGit.AgentScheduler.Worktrees do
  @moduledoc """
  Worktree creation pipeline and preparation helpers.

  The I/O pipeline lives here so `EvoGit.AgentScheduler.WorktreeManager` can
  offload worktree creation to a spawned task (keeping its message loop
  responsive for `:DOWN`/cleanup messages). Functions are pure helpers that
  take explicit parameters — no scheduler state is involved.
  """

  require Logger
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Platform
  alias EvoGit.Powershell
  alias EvoGit.ProjectConfig

  # --- Paths and Naming ---

  @doc """
  Returns the path to the workers directory for a given repo root.
  """
  @spec workers_dir(String.t()) :: String.t()
  def workers_dir(repo_root), do: Path.join(repo_root, ".genesis/workers")

  @doc """
  Single source of truth for the agent branch-name derivation.
  """
  @spec branch_name(pos_integer(), pos_integer()) :: String.t()
  def branch_name(task_number, task_local_id),
    do: "evogit-agent-T#{task_number}-A#{task_local_id}"

  # --- Worktree Creation Pipeline ---

  @doc """
  Creates a FRESH worktree for an agent and prepares it for execution.

  Called by `EvoGit.AgentScheduler.WorktreeManager`'s offloaded create task.
  Every call creates fresh — there is no fast/reuse path, no `File.exists?`
  check, no `newly_created` flag. Leftovers from a previous run (crash-retry
  race) are destroyed first.

  Returns `{:ok, worktree_path}` on success or `{:error, reason}`. Git error
  tuples are handled explicitly — this function never raises.
  """
  @spec prepare_new_worktree(
          pos_integer(),
          String.t(),
          String.t(),
          EvoGit.AgentSpec.t(),
          EvoGit.AgentScheduler.SchedMeta.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def prepare_new_worktree(agent_id, repo_root, worktree_path, spec, meta) do
    with {:ok, agent_state} <- Store.get_agent_state(agent_id) do
      branch_name = branch_name(meta.task_number, agent_state.task_local_id)

      # Destroy leftovers from a previous run (crash-retry race — the old
      # worktree dir/branch may still exist).
      destroy_leftovers(worktree_path, repo_root, branch_name)

      # For subagents, use the parent's worktree as the CoW source; for
      # top-level agents, use the repo root.
      source_path = resolve_source_path(repo_root, meta)

      with :ok <-
             create_worktree(agent_id, repo_root, worktree_path, spec, branch_name, source_path),
           {:ok, _commit_sha} <- assign_and_prepare_worktree(agent_id, worktree_path) do
        # Run the worktree init script only for the primary repo (foreign
        # repos are independent and should not inherit the primary repo's
        # init script).
        if spec.repo_id == "primary" do
          run_init_script(repo_root, worktree_path, source_worktree_path: source_path)
        end

        {:ok, worktree_path}
      else
        {:error, {:worktree_create_failed, msg}} ->
          Logger.error("AgentScheduler: Failed to create worktree #{worktree_path}: #{msg}")
          {:error, {:worktree_create_failed, msg}}

        {:error, {:worktree_prepare_failed, _} = error} ->
          Logger.error(
            "AgentScheduler: Failed to prepare worktree #{worktree_path}: #{inspect(error)}"
          )

          error
      end
    else
      :error ->
        {:error, {:agent_state_missing, agent_id}}
    end
  end

  defp create_worktree(agent_id, repo_root, worktree_path, spec, branch_name, source_path) do
    commit_sha = spec.phylo_node.current_commit

    cow_result =
      if EvoGit.Adapters.CowWorktree.enabled?() do
        EvoGit.Adapters.CowWorktree.create_worktree(
          repo_root,
          worktree_path,
          commit_sha,
          branch_name,
          source_path
        )
      else
        {:fallback, :disabled}
      end

    case cow_result do
      :ok ->
        Logger.info(
          "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} " <>
            "on branch #{branch_name} via CoW"
        )

        :ok

      {:fallback, reason} ->
        Logger.debug("AgentScheduler: Falling back to standard worktree creation (#{reason})")

        case Git.add_worktree(repo_root, worktree_path, commit_sha, branch_name) do
          {:ok, _} ->
            Logger.info(
              "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} " <>
                "on branch #{branch_name}"
            )

            :ok

          {:error, {_tag, msg}} ->
            {:error, {:worktree_create_failed, msg}}
        end
    end
  end

  defp destroy_leftovers(worktree_path, repo_root, branch_name) do
    case File.rm_rf(worktree_path) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "AgentScheduler: Could not remove leftover worktree #{worktree_path}: " <>
            "#{inspect(reason)} at #{path}"
        )
    end

    Git.prune_worktrees(repo_root)

    case delete_branch_tolerant(repo_root, branch_name) do
      :ok ->
        :ok

      {:error, output} ->
        Logger.warning(
          "AgentScheduler: Could not remove leftover branch #{branch_name}: #{inspect(output)}"
        )
    end

    :ok
  end

  @doc """
  Deletes a git branch, treating "branch not found" as a silent no-op.

  Destroy operations (leftover cleanup, worktree teardown) have "the branch is
  gone" as their goal, so a `git branch -D` failing with `error: branch
  '<name>' not found` means the goal is already met — not a failure. Returns
  `:ok` for success-or-already-gone and `{:error, output}` for genuine
  failures so callers can keep their warning logs.
  """
  @spec delete_branch_tolerant(String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete_branch_tolerant(repo_root, branch_name) do
    case Git.delete_branch(repo_root, branch_name) do
      {:ok, _} ->
        :ok

      {:error, {_tag, output}} ->
        if branch_not_found?(output) do
          :ok
        else
          {:error, output}
        end
    end
  end

  defp branch_not_found?(output) do
    String.contains?(output, "not found") and String.contains?(output, "branch")
  end

  defp resolve_source_path(agent_repo_root, meta) do
    # For subagents: use the parent's worktree path (already has most files
    # at same content). For top-level agents: use the main repo root.
    if meta.parent_id do
      case Store.get_sched_meta(meta.parent_id) do
        {:ok, parent_meta} when parent_meta.worktree != nil ->
          parent_meta.worktree

        _ ->
          agent_repo_root
      end
    else
      agent_repo_root
    end
  end

  # --- Worktree Assignment and Preparation ---

  @doc """
  Assigns the given worktree to an agent and prepares its git state.

  Cleans the worktree, checks out the agent's branch, and updates
  the agent's phylo_node with the worktree-bound repo path.

  Returns `{:ok, commit_sha}` or `{:error, {:worktree_prepare_failed, ...}}`
  on git failure.
  """
  @spec assign_and_prepare_worktree(pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}

  def assign_and_prepare_worktree(agent_id, wt) do
    {:ok, meta} = Store.get_sched_meta(agent_id)
    {:ok, %AgentState{} = agent_state} = Store.get_agent_state(agent_id)
    spec = meta.spec

    commit_sha = spec.phylo_node.current_commit
    branch_name = branch_name(meta.task_number, agent_state.task_local_id)

    with {:ok, _} <- Git.clean(wt),
         {:ok, _} <- Git.checkout(wt, branch_name) do
      # Build the worktree-bound phylo_node (repo points to worktree)
      wt_phylo_node = %EvoGit.Core.PhyloGraphNode{
        repo: wt,
        base_commit: spec.phylo_node.base_commit,
        current_commit: commit_sha
      }

      Store.put_agent_state(agent_id, %AgentState{agent_state | phylo_node: wt_phylo_node})

      {:ok, commit_sha}
    else
      {:error, {_tag, _output} = error} ->
        Logger.error("AgentScheduler: Failed to prepare worktree #{wt}: #{inspect(error)}")

        {:error, {:worktree_prepare_failed, error}}
    end
  end

  @doc """
  Runs the worktree initialization script if one is configured.

  The script is read from `genesis.toml` under the `[worktree]` section.
  Shell detection is done via shebang line, defaulting to the platform shell.
  Environment variables `SOURCE_REPO_PATH`, `SOURCE_WORKTREE_PATH`, and
  `TARGET_WORKTREE_PATH` are set.

  ## Options

    - `:source_worktree_path` — the parent agent's worktree path. Defaults to
      `repo_root` (same as `SOURCE_REPO_PATH`) for top-level agents.
  """
  @spec run_init_script(String.t(), String.t(), keyword()) :: :ok

  def run_init_script(repo_root, worktree_path, opts \\ []) do
    source_worktree_path = Keyword.get(opts, :source_worktree_path, repo_root)

    case ProjectConfig.worktree_script(repo_root, Platform.os()) do
      nil ->
        :ok

      script_content ->
        Logger.info("AgentScheduler: Running worktree init script")

        # Detect shell from shebang, defaulting to platform shell.
        # Split into executable + extra args so that shebangs like
        # "#!/usr/bin/env bash" work correctly (executable=/usr/bin/env,
        # extra_args=["bash"]) rather than treating the whole line as one
        # binary path.
        {shell, extra_args} =
          case String.split(script_content, "\n", parts: 2) |> List.first() do
            "#!" <> rest ->
              parts = String.trim(rest) |> String.split(~r/\s+/, trim: true)
              {List.first(parts), tl(parts)}

            _ ->
              {Platform.shell(), []}
          end

        cmd =
          if Platform.windows?() do
            """
            $env:SOURCE_REPO_PATH = "#{repo_root}"
            $env:SOURCE_WORKTREE_PATH = "#{source_worktree_path}"
            $env:TARGET_WORKTREE_PATH = "#{worktree_path}"
            Set-Location "#{repo_root}"
            #{script_content}
            """
          else
            """
            export SOURCE_REPO_PATH="#{repo_root}"
            export SOURCE_WORKTREE_PATH="#{source_worktree_path}"
            export TARGET_WORKTREE_PATH="#{worktree_path}"
            cd "#{repo_root}"
            #{script_content}
            """
          end

        {raw_output, exit_code} =
          System.cmd(shell, extra_args ++ Platform.shell_args(cmd),
            cd: repo_root,
            stderr_to_stdout: true
          )

        # Host PowerShell may emit UTF-16LE-with-BOM output; decode once so
        # both log branches show readable text (idempotent, passthrough on
        # Unix).
        output = Powershell.decode_output(raw_output)

        case {output, exit_code} do
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
end
