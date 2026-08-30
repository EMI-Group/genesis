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
  alias EvoGit.AgentScheduler.WorktreeRetry
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
    with {:ok, agent_state} <- Store.get_agent_state(agent_id),
         branch_name = branch_name(meta.task_number, agent_state.task_local_id),
         # Destroy leftovers from a previous run (crash-retry race — the old
         # worktree dir/branch may still exist). Failure to remove a leftover
         # dir ESCALATES: creating on top of a partially-removed dir is what
         # produces the plain-unregistered-dir state (see destroy_leftovers/3).
         :ok <- destroy_leftovers(worktree_path, repo_root, branch_name),
         # For subagents, use the parent's worktree as the CoW source; for
         # top-level agents, use the repo root.
         source_path = resolve_source_path(repo_root, meta),
         :ok <-
           create_worktree(agent_id, repo_root, worktree_path, spec, branch_name, source_path),
         {:ok, _commit_sha} <- assign_and_prepare_worktree(agent_id, worktree_path, repo_root) do
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

  # Destroys leftovers from a previous run at the same worktree path
  # (crash-retry race). Returns `:ok` when the path is clean, or
  # `{:error, {:worktree_create_failed, msg}}` when the leftover dir could NOT
  # be removed after retries — the create pipeline escalates instead of
  # creating on top of a partially-removed dir.
  #
  # Ordering is deliberate (main-HEAD-leak safety): `Git.prune_worktrees` must
  # run only AFTER the dir is actually gone. A dir that survives rm_rf WITH its
  # `.git` file + registration is a SAFE registered worktree; pruning it away
  # would turn it into a PLAIN unregistered dir — the foreign-repo main-HEAD
  # leak precondition. So on rm_rf failure we skip the prune, keep the
  # dir+registration pair consistent, and escalate. Transient failures are
  # retried via WorktreeRetry; never raises (runs inside the offloaded create
  # task).
  defp destroy_leftovers(worktree_path, repo_root, branch_name) do
    case WorktreeRetry.rm_rf_retry(worktree_path) do
      {:ok, _} ->
        # Dir is gone — safe to prune stale registrations and delete the
        # leftover branch. A genuine branch-delete failure (branch checked out
        # in a LIVE worktree elsewhere) warns and continues: the create step
        # below surfaces it loudly (it force-deletes/recreates the branch, or
        # fails with `:worktree_create_failed`).
        WorktreeRetry.retry_on_transient(fn -> Git.prune_worktrees(repo_root) end)

        case WorktreeRetry.retry_on_transient(fn ->
               delete_branch_tolerant(repo_root, branch_name)
             end) do
          :ok ->
            :ok

          {:error, output} ->
            Logger.warning(
              "AgentScheduler: Could not remove leftover branch #{branch_name}: #{inspect(output)}"
            )

            :ok
        end

      {:error, reason, path} ->
        Logger.error(
          "AgentScheduler: Could not remove leftover worktree #{worktree_path}: " <>
            "#{inspect(reason)} at #{path} — refusing to create at a path whose " <>
            "leftover could not be removed"
        )

        {:error,
         {:worktree_create_failed,
          "could not remove leftover worktree #{worktree_path}: #{inspect(reason)} at #{path}"}}
    end
  end

  @doc """
  Deletes a git branch, treating "branch not found" as a silent no-op.

  Destroy operations (leftover cleanup, worktree teardown) have "the branch is
  gone" as their goal, so a `git branch -D` failing with `error: branch
  '<name>' not found` means the goal is already met — not a failure. The same
  applies when the repository itself is gone ("Repository path does not exist"
  / "not a git repository" — see `WorktreeRetry.repo_gone_output?/1`): a
  vanished repo implies the branch is gone with it.

  A failure because the branch is checked out in a worktree ("cannot delete
  branch 'X' used by worktree at '<path>'", or the older "checked out at"
  wording) is treated as RECOVERABLE: the registration may be STALE (worktree
  dir already removed without a matching prune), so we prune stale
  registrations and retry the delete once. A branch genuinely checked out in a
  LIVE worktree survives the prune and the retry still fails — that remains
  `{:error, output}` (correct: a live checked-out branch is never force-deleted).

  Returns `:ok` for success-or-already-gone and `{:error, output}` for genuine
  failures so callers can keep their warning logs.
  """
  @spec delete_branch_tolerant(String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete_branch_tolerant(repo_root, branch_name) do
    case Git.delete_branch(repo_root, branch_name) do
      {:ok, _} ->
        :ok

      {:error, {_tag, output}} ->
        cond do
          branch_not_found?(output) or WorktreeRetry.repo_gone_output?(output) ->
            :ok

          branch_in_worktree?(output) ->
            # Drop STALE registrations (worktree dirs already gone), then
            # retry once. A live checkout's registration is not pruned, so the
            # retry fails — the branch stays (correctly) undeleted.
            WorktreeRetry.retry_on_transient(fn -> Git.prune_worktrees(repo_root) end)
            retry_tolerant_delete(repo_root, branch_name)

          true ->
            {:error, output}
        end
    end
  end

  defp retry_tolerant_delete(repo_root, branch_name) do
    case Git.delete_branch(repo_root, branch_name) do
      {:ok, _} ->
        :ok

      {:error, {_tag, output}} ->
        if branch_not_found?(output) or WorktreeRetry.repo_gone_output?(output) do
          :ok
        else
          {:error, output}
        end
    end
  end

  defp branch_not_found?(output) do
    String.contains?(output, "not found") and String.contains?(output, "branch")
  end

  # Matches git's refusal to delete a checked-out branch across version
  # wordings: "cannot delete branch 'X' used by worktree at '<path>'" (modern
  # git, verified 2.54.0) and the older "cannot delete branch 'X' checked out
  # at '<path>'" — both exit 1 (adapter: `{:error, {:conflict, output}}`).
  defp branch_in_worktree?(output) do
    String.contains?(output, "used by worktree") or
      String.contains?(output, "checked out at")
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

  Asserts `wt` is a REGISTERED linked worktree of the repo rooted at
  `repo_root` BEFORE running any git against it (see `ensure_linked_worktree/2`)
  — `Git.clean`/`Git.checkout` against a plain unregistered dir would act on
  the repo's MAIN working copy, moving its HEAD onto the agent branch (the
  foreign-repo main-HEAD leak). Then cleans the worktree, checks out the
  agent's branch, and updates the agent's phylo_node with the worktree-bound
  repo path.

  Returns `{:ok, commit_sha}` or `{:error, {:worktree_prepare_failed, ...}}`
  (the guard failure shape is `{:error, {:worktree_prepare_failed,
  :not_a_linked_worktree}}`).
  """
  @spec assign_and_prepare_worktree(pos_integer(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def assign_and_prepare_worktree(agent_id, wt, repo_root) do
    {:ok, meta} = Store.get_sched_meta(agent_id)
    {:ok, %AgentState{} = agent_state} = Store.get_agent_state(agent_id)
    spec = meta.spec

    commit_sha = spec.phylo_node.current_commit
    branch_name = branch_name(meta.task_number, agent_state.task_local_id)

    with :ok <- ensure_linked_worktree(wt, repo_root),
         {:ok, _} <- Git.clean(wt),
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
      # Guard failures arrive in the FINAL error shape already — log and pass
      # through unchanged (no double wrapping).
      {:error, {:worktree_prepare_failed, _} = error} ->
        Logger.error("AgentScheduler: Failed to prepare worktree #{wt}: #{inspect(error)}")
        error

      {:error, {_tag, _output} = error} ->
        Logger.error("AgentScheduler: Failed to prepare worktree #{wt}: #{inspect(error)}")

        {:error, {:worktree_prepare_failed, error}}
    end
  end

  # Verifies `wt` is a REGISTERED linked worktree of the repo rooted at
  # `repo_root` — the precondition for `Git.clean`/`Git.checkout` to act on
  # the worktree rather than the repo's MAIN working copy.
  #
  # A registered linked worktree ALWAYS has a `.git` FILE whose content is
  # "gitdir: <path>", where <path> (after `Path.expand/1` relative to the
  # worktree, per git's own rule) lies under `<repo_root>/.git/worktrees/`.
  #
  # Why the `.git`-file check and NOT `git -C wt rev-parse --git-common-dir`:
  # from a PLAIN dir inside the repo tree (the dangerous broken-registration
  # state) git walks UP and returns `<repo_root>/.git` — identical to a real
  # worktree's common dir — so a rev-parse check would PASS for exactly the
  # dangerous state. The repo ROOT itself has a `.git` DIRECTORY (not a file),
  # and a plain dir has no `.git` file at all — both fail this check.
  #
  # Never runs git — plain `File.read`/`Path` only, so a failure can never
  # touch the main copy.
  defp ensure_linked_worktree(wt, repo_root) do
    expected_prefix = Path.expand(Path.join(repo_root, ".git/worktrees"))

    case File.read(Path.join(wt, ".git")) do
      {:ok, content} ->
        case gitdir_from_content(content) do
          {:ok, gitdir} ->
            expanded = Path.expand(gitdir, wt)

            if String.starts_with?(expanded, expected_prefix <> "/") and File.dir?(expanded) do
              :ok
            else
              {:error, {:worktree_prepare_failed, :not_a_linked_worktree}}
            end

          :error ->
            {:error, {:worktree_prepare_failed, :not_a_linked_worktree}}
        end

      _ ->
        # No `.git` file (plain dir, or the repo ROOT with a `.git` directory)
        {:error, {:worktree_prepare_failed, :not_a_linked_worktree}}
    end
  end

  defp gitdir_from_content(content) do
    case content |> String.split("\n", parts: 2) |> List.first() do
      "gitdir: " <> path ->
        {:ok, String.trim(path)}

      _ ->
        :error
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
