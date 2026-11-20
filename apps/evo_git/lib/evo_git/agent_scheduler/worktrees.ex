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
  alias EvoGit.AgentScheduler.Salvage
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
  Derives the repo root from a worktree path (primary-repo layout): strips the
  `.genesis/workers/` suffix when present, otherwise returns the path unchanged.
  """
  @spec repo_root_from_worktree(String.t()) :: String.t()
  def repo_root_from_worktree(worktree_path) do
    case String.split(worktree_path, "/.genesis/workers/", parts: 2) do
      [root, _rest] -> root
      [_] -> worktree_path
    end
  end

  @doc """
  Single source of truth for the agent branch-name derivation.
  """
  @spec branch_name(pos_integer(), pos_integer()) :: String.t()
  def branch_name(task_number, task_local_id),
    do: "evogit-agent-T#{task_number}-A#{task_local_id}"

  @doc """
  The PERSISTED branch this dispatch must reuse, from
  `spec.opts[:worktree_branch]`.

  A resumed run keeps the branch it was paused/crashed on, so its commits stay
  reachable through the same name after the workers directory was wiped. Total:
  an absent, blank or non-binary value (and a non-spec input) answers `nil`, and
  the caller falls back to the freshly derived `branch_name/2`.
  """
  @spec resume_branch(EvoGit.AgentSpec.t() | map()) :: String.t() | nil
  def resume_branch(%{opts: opts}) when is_list(opts) do
    case Keyword.get(opts, :worktree_branch) do
      branch when is_binary(branch) and branch != "" -> branch
      _absent -> nil
    end
  end

  def resume_branch(_spec), do: nil

  @doc """
  The ONE branch resolution of a dispatch: the resumed/persisted branch when the
  spec carries one, else the freshly derived `branch_name/2`.

  `WorktreeManager`'s tracked row, `create_worktree/6`, `assign_and_prepare_worktree/3`
  and the session's dispatch ctx all resolve their branch HERE, so the reclaim
  delete can never target a different branch than the one that was created.
  """
  @spec branch_for(map(), term(), EvoGit.AgentSpec.t() | map()) :: String.t()
  def branch_for(meta, task_local_id, spec),
    do: resume_branch(spec) || branch_name(task_number(meta), task_local_id)

  defp task_number(meta) when is_map(meta), do: Map.get(meta, :task_number)
  defp task_number(_meta), do: nil

  # --- Worktree Creation Pipeline ---

  @doc """
  Creates a FRESH worktree for an agent and prepares it for execution.

  Called by `EvoGit.AgentScheduler.WorktreeManager`'s offloaded create task.
  Every call creates fresh — there is no fast/reuse path, no `File.exists?`
  check, no `newly_created` flag. Leftovers from a previous run (crash-retry
  race) are destroyed first.

  Returns `{:ok, worktree_path}` on success or `{:error, reason}` — ALWAYS the
  outer `:error` tag, with one reason per failure class:
  `{:error, {:worktree_create_failed, msg}}`, `{:error,
  {:worktree_prepare_failed, detail}}` (the prepare step's own error shape,
  carried through unchanged) or `{:error, {:agent_state_missing, agent_id}}`.
  Git error tuples are handled explicitly — this function never raises.
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
         branch_name = branch_for(meta, agent_state.task_local_id, spec),
         # A RESUMED run re-establishes its base from the durable anchor when the
         # branch/commits were wiped by the workers-directory cleanup. A
         # non-resume run makes no extra git call at all (no `:worktree_branch`).
         spec = maybe_resume_base(repo_root, branch_name, spec, meta),
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

      # The prepare step answers the FINAL error shape already
      # (`{:error, {:worktree_prepare_failed, detail}}`), so it is re-tagged
      # nowhere: bind the reason and keep the outer `:error` tag.
      {:error, {:worktree_prepare_failed, _} = reason} ->
        Logger.error(
          "AgentScheduler: Failed to prepare worktree #{worktree_path}: #{inspect(reason)}"
        )

        {:error, reason}

      :error ->
        {:error, {:agent_state_missing, agent_id}}
    end
  end

  # A RESUMED run (the spec carries `:worktree_branch`) may have lost its
  # commits to a workers-directory wipe and a `git gc`: re-establish the base
  # from the durable anchor BEFORE the leftovers are destroyed and the worktree
  # is created, so `create_worktree/6` (which reads
  # `spec.phylo_node.current_commit`) starts where the run actually stopped.
  #
  # A NON-resume run makes ZERO extra git calls — the guards short-circuit on the
  # absent `:worktree_branch` opt.
  defp maybe_resume_base(repo_root, branch_name, spec, meta) do
    if resume_branch(spec) == nil do
      spec
    else
      case ensure_resume_base(repo_root, branch_name, spec, meta) do
        nil ->
          spec

        sha ->
          if match?(%EvoGit.Core.PhyloGraphNode{}, spec.phylo_node) and
               spec.phylo_node.current_commit != sha do
            %{spec | phylo_node: %{spec.phylo_node | current_commit: sha}}
          else
            spec
          end
      end
    end
  end

  @doc false
  # The sha a RESUMED worktree must be created at, or `nil` when the spec's own
  # base stands.
  #
  # Chain (first USABLE answer wins, every step total):
  #
  #   1. the spec's own `phylo_node.current_commit` when the repo verifies it —
  #      the dispatch already resolved it, so nothing is changed;
  #   2. the sha the durable ANCHOR ref points at
  #      (`spec.opts[:resume_anchor_ref]`, else
  #      `EvoGit.AgentState.Anchor.ref/2` for `(task_id, agent_id)`);
  #   3. the EXISTING branch's own sha (`git show-ref` then `git rev-parse`) —
  #      a branch that survived the cleanup;
  #   4. nothing usable: ONE warning, and `nil` leaves the spec's base alone.
  #
  # Only `EvoGit.Adapters.Git` is used (no shell), and a `nil`/non-binary
  # `repo_root` degrades immediately.
  @spec ensure_resume_base(String.t() | nil, String.t() | nil, map(), map()) :: String.t() | nil
  def ensure_resume_base(repo_root, branch_name, spec, meta)
      when is_binary(repo_root) and repo_root != "" do
    cond do
      spec_base_usable?(repo_root, spec) -> nil
      sha = anchored_sha(repo_root, spec, meta) -> sha
      sha = existing_branch_sha(repo_root, branch_name) -> sha
      true -> warn_unresolved_resume_base(repo_root, spec, meta)
    end
  end

  def ensure_resume_base(_repo_root, _branch_name, _spec, _meta), do: nil

  # The spec's own base, when this repository can still resolve it.
  defp spec_base_usable?(repo_root, spec) do
    case commit_sha(spec) do
      sha when is_binary(sha) -> Salvage.commit_exists?(repo_root, sha)
      _absent -> false
    end
  end

  defp commit_sha(%{phylo_node: %EvoGit.Core.PhyloGraphNode{current_commit: sha}}) do
    if is_binary(sha) and sha != "" do
      sha
    end
  end

  defp commit_sha(_spec), do: nil

  defp anchored_sha(repo_root, spec, meta) do
    ref =
      case Keyword.get(spec_opts(spec), :resume_anchor_ref) do
        custom when is_binary(custom) and custom != "" -> custom
        _absent -> EvoGit.AgentState.Anchor.ref(Map.get(meta, :task_id), Map.get(meta, :id))
      end

    rev_parse_sha(repo_root, ref <> "^{commit}")
  end

  defp existing_branch_sha(repo_root, branch_name)
       when is_binary(branch_name) and branch_name != "" do
    if Git.branch_exists?(repo_root, branch_name) do
      rev_parse_sha(repo_root, branch_name)
    end
  end

  defp existing_branch_sha(_repo_root, _branch_name), do: nil

  defp rev_parse_sha(repo_root, rev) do
    case Git.rev_parse(repo_root, rev) do
      {:ok, output} when is_binary(output) ->
        case String.trim(output) do
          "" -> nil
          sha -> sha
        end

      _error ->
        nil
    end
  end

  defp warn_unresolved_resume_base(repo_root, spec, meta) do
    Logger.warning(
      "AgentScheduler: could not re-establish the resume base for agent " <>
        "#{inspect(Map.get(meta, :id))} in #{repo_root} " <>
        "(branch #{inspect(resume_branch(spec))}); keeping the spec's base"
    )

    nil
  end

  defp spec_opts(%{opts: opts}) when is_list(opts), do: opts
  defp spec_opts(_spec), do: []

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
  agent's branch, and records the worktree-bound commit on the agent's summary
  row.

  Returns `{:ok, commit_sha}` or `{:error, {:worktree_prepare_failed, ...}}`
  (the guard failure shape is `{:error, {:worktree_prepare_failed,
  :not_a_linked_worktree}}`). Neither the scheduler metadata row nor the agent
  state row is guaranteed to exist at this point (both are written/deleted by
  other processes), so a missing row answers the final error shape
  `{:error, {:worktree_prepare_failed, {:rows_missing, agent_id}}}` instead of
  raising.
  """
  @spec assign_and_prepare_worktree(pos_integer(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def assign_and_prepare_worktree(agent_id, wt, repo_root) do
    # Both rows are written/deleted by other processes, so a missing row is a
    # normal race rather than a crash: report it in the final error shape.
    with {:ok, meta} <- Store.get_sched_meta(agent_id),
         {:ok, %AgentState{} = agent_state} <- Store.get_agent_state(agent_id) do
      spec = meta.spec

      commit_sha = spec.phylo_node.current_commit
      branch_name = branch_for(meta, agent_state.task_local_id, spec)

      with :ok <- ensure_linked_worktree(wt, repo_root),
           {:ok, _} <- Git.clean(wt),
           {:ok, _} <- Git.checkout(wt, branch_name) do
        # The worktree is prepared at `commit_sha`: record it as the agent's
        # current commit (registration write — the session publishes it onwards).
        Store.put_agent_state(agent_id, %AgentState{agent_state | current_commit: commit_sha})

        {:ok, commit_sha}
      else
        # Guard failures arrive in the FINAL error shape already — log and
        # re-emit it with its outer `:error` tag (no double wrapping; the bare
        # inner pair never escapes this function).
        {:error, {:worktree_prepare_failed, _} = reason} ->
          Logger.error("AgentScheduler: Failed to prepare worktree #{wt}: #{inspect(reason)}")
          {:error, reason}

        {:error, {_tag, _output} = error} ->
          Logger.error("AgentScheduler: Failed to prepare worktree #{wt}: #{inspect(error)}")

          {:error, {:worktree_prepare_failed, error}}
      end
    else
      :error ->
        error = {:worktree_prepare_failed, {:rows_missing, agent_id}}
        Logger.error("AgentScheduler: Failed to prepare worktree #{wt}: #{inspect(error)}")
        {:error, error}
    end
  end

  # Verifies `wt` is a REGISTERED linked worktree of the repo rooted at
  # `repo_root` — the precondition for `Git.clean`/`Git.checkout` to act on
  # the worktree rather than the repo's MAIN working copy.
  #
  # A registered linked worktree ALWAYS has a `.git` FILE whose content is
  # "gitdir: <path>", where <path> (after `EvoGit.Platform.safe_expand/2` — a
  # UNC-preserving `Path.expand` — relative to the worktree, per git's own
  # rule) lies under `<repo_root>/.git/worktrees/`.
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
    expected_prefix = Platform.safe_expand(Path.join(repo_root, ".git/worktrees"))

    case File.read(Path.join(wt, ".git")) do
      {:ok, content} ->
        case gitdir_from_content(content) do
          {:ok, gitdir} ->
            expanded = Platform.safe_expand(gitdir, wt)

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
