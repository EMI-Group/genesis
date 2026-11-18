defmodule EvoGit.AgentScheduler.ResumePlan do
  @moduledoc """
  The ONE resume/retry decision a dispatch makes: which branch the run keeps,
  where its worktree is based, and whether the durable conversation is restored.

  Extracted out of `EvoGit.AgentScheduler.Dispatch` because it is a pure
  decision over `%AgentSpec{}` / `%SchedMeta{}` (plus the few git facts it
  VERIFIES) and it is the contract the whole-tree durable resume consumes:

    * a CRASH RETRY of the same `agent_id` bases the worktree on the salvaged
      commit the `WorktreeManager` preserved (`meta.crash_commit`);
    * a TASK-LEVEL PAUSE RESUME additionally re-establishes the PERSISTED
      identity — its `agent_id`, its branch and its worktree base — from the
      facts `EvoGit.TaskRegistry.Pause.resume/4` resolved before the wrapper was
      spawned;
    * a plain FIRST attempt makes no git call at all and returns its inputs
      unchanged.

  ## Identity across a restart

  `.genesis/workers/` is ephemeral: the first worktree create after a BEAM
  restart wipes the workers directory and every `evogit-agent-*` branch, so a
  resumed run cannot rely on its old branch surviving. The branch NAME is
  therefore persisted (`spec.opts[:resume_branch]` → `spec.opts[:worktree_branch]`
  so `EvoGit.AgentScheduler.WorktreeManager`/`Worktrees` recreate exactly that
  one), and when the branch is gone its sha is re-established from the durable
  anchor ref (`refs/genesis/agent-state/<task_id>/<agent_id>`).

  ## Base precedence (first USABLE candidate wins)

  1. `spec.opts[:pause_commit]` — the checkpoint the pause finalizer stored
     (`{:ok, nil}` means "resolved, nothing stored" and skips straight to 2);
  2. `spec.opts[:resume_current_commit]` — the persisted run's last commit;
  3. `meta.crash_commit` — the salvaged work of a crashed attempt;
  4. nothing usable → the task base stands untouched (`nil`).

  Every candidate is VERIFIED with `Salvage.commit_exists?/2`; an unusable sha
  degrades to the next one instead of guessing, and the durable store is only
  read through the BOUNDED `EvoGit.TaskRegistry.AgentStateRead` offload (never
  inline on the scheduler's heap).
  """

  alias EvoGit.AgentScheduler.Salvage
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec

  # The two task-level PAUSE resume kinds (see `docs/task-pause.md` §6). Any
  # other value — including an absent key — means "not a pause resume".
  @pause_resume_kinds [:clean_pause, :dirty_pause]

  # The `spec.opts` keys a resume carries from the registry/runtime. Their
  # PRESENCE (not their value: a resolved `nil` is a fact too) is what makes a
  # dispatch a resume and therefore worth verifying against the repo.
  @resume_input_keys [:pause_commit, :resume_current_commit, :resume_branch, :resume_agent_id]

  @doc """
  Plans ONE dispatch.

  Returns a map with EXACTLY these keys:

    * `:spec` / `:meta` — the (possibly branch- and base-rewritten) inputs to
      persist and dispatch;
    * `:branch` — the branch the run keeps: the resumed/persisted branch on a
      resume, else the freshly derived `Worktrees.branch_name/2`. `nil` only in
      the degenerate case where no agent-state row resolves the task-local id
      (a direct unit-level call outside a live scheduler);
    * `:worktree_resume_from` — the sha the worktree is actually based on when
      it is NOT the task base, else `nil`;
    * `:persistent_state` — the TASK-WIDE durability flag (`spec.opts`, default
      `true`, only an explicit `false` opts out);
    * `:restore_agent_state` — `true` for a crash RETRY (`retries > 0`), a pause
      resume, or an explicit `spec.opts[:restore_agent_state] == true`, and only
      while durability is on;
    * `:resume_kind` — `:clean_pause | :dirty_pause` for a pause resume, `nil`
      for every other run.
  """
  @spec plan(
          pos_integer(),
          AgentSpec.t(),
          SchedMeta.t(),
          String.t() | nil,
          non_neg_integer()
        ) :: map()
  def plan(agent_id, %AgentSpec{} = spec, %SchedMeta{} = meta, repo_root, retries) do
    resume_kind = resume_kind(spec)
    persistent_state = Keyword.get(spec.opts, :persistent_state, true) != false
    restore_requested? = Keyword.get(spec.opts, :restore_agent_state) == true

    fresh = fresh_branch(agent_id, meta)
    resume_branch = non_empty(Keyword.get(spec.opts, :resume_branch))

    branch =
      cond do
        resume_kind != nil and resume_branch != nil -> resume_branch
        restore_requested? and resume_branch != nil -> resume_branch
        true -> fresh
      end

    spec = normalize_branch(spec, branch, fresh, persistent_state)

    {spec, meta, worktree_resume_from} =
      if resume?(spec, meta, resume_kind, restore_requested?) do
        resolve_base(agent_id, spec, meta, repo_root)
      else
        {spec, meta, nil}
      end

    %{
      spec: spec,
      meta: meta,
      worktree_resume_from: worktree_resume_from,
      persistent_state: persistent_state,
      restore_agent_state:
        (retries > 0 or resume_kind != nil or restore_requested?) and persistent_state,
      resume_kind: resume_kind,
      branch: branch
    }
  end

  # --- Shape ---

  defp resume_kind(spec) do
    case Keyword.get(spec.opts, :resume_kind) do
      kind when kind in @pause_resume_kinds -> kind
      _other -> nil
    end
  end

  # The freshly derived name for THIS run. `nil` when no agent-state row
  # resolves the task-local id (a direct unit-level call outside a live
  # scheduler) — the plan stays total and simply has no branch to report.
  defp fresh_branch(agent_id, meta) do
    case task_local_id(agent_id) do
      id when is_integer(id) -> Worktrees.branch_name(task_number(meta), id)
      _absent -> nil
    end
  end

  # The task-local id lives on the agent's SUMMARY row; the read is a plain ETS
  # lookup and is TOTAL (a missing table — a unit-level call with no scheduler
  # booted — answers `:error` rather than raising).
  defp task_local_id(agent_id) when is_integer(agent_id) do
    if :ets.whereis(:evogit_agent_summary) == :undefined do
      nil
    else
      case Store.get_agent_state(agent_id) do
        {:ok, row} -> Map.get(row, :task_local_id)
        :error -> nil
      end
    end
  end

  defp task_local_id(_agent_id), do: nil

  defp task_number(meta) when is_map(meta), do: Map.get(meta, :task_number)
  defp task_number(_meta), do: nil

  # The persisted branch reaches the WorktreeManager through the SPEC only (the
  # manager has the spec and the meta row), so a resumed run records it as
  # `:worktree_branch` — and NOTHING is recorded when it equals the fresh name
  # or when the task opted out of durability.
  defp normalize_branch(spec, branch, fresh, true) do
    if is_binary(branch) and branch != "" and branch != fresh do
      %{spec | opts: Keyword.put(spec.opts, :worktree_branch, branch)}
    else
      delete_branch_opt(spec)
    end
  end

  defp normalize_branch(spec, _branch, _fresh, _persistent_state), do: delete_branch_opt(spec)

  defp delete_branch_opt(spec), do: %{spec | opts: Keyword.delete(spec.opts, :worktree_branch)}

  # --- Base resolution ---

  # A plain FIRST attempt (no pause resume, no resume fact, no salvage commit)
  # makes ZERO git calls: the spec/meta stand byte-identically.
  defp resume?(spec, meta, resume_kind, restore_requested?) do
    resume_kind != nil or restore_requested? or
      Enum.any?(@resume_input_keys, &Keyword.has_key?(spec.opts, &1)) or
      non_empty(Map.get(meta, :crash_commit)) != nil
  end

  defp resolve_base(agent_id, spec, meta, repo_root) do
    spec
    |> base_candidates(agent_id, meta)
    |> Enum.find(&usable?(repo_root, &1))
    |> apply_base(spec, meta)
  end

  defp base_candidates(spec, agent_id, meta) do
    [
      pause_commit_candidate(spec, agent_id, meta),
      non_empty(Keyword.get(spec.opts, :resume_current_commit)),
      non_empty(Map.get(meta, :crash_commit))
    ]
  end

  defp usable?(_repo_root, sha) when not is_binary(sha), do: false
  defp usable?(_repo_root, ""), do: false
  defp usable?(repo_root, sha), do: Salvage.commit_exists?(repo_root, sha)

  # The pause checkpoint is the PRE-RESOLVED `spec.opts[:pause_commit]`
  # (`EvoGit.TaskRegistry.Pause.resume/4` resolves it before the wrapper is
  # spawned): the scheduler never reads the durable agent-state store on the
  # resume path. The presence of the KEY decides — `nil` included, meaning
  # "resolved, nothing stored" — so only a DIRECT dispatch (no pause resume and
  # therefore no pre-resolution) falls back to a bounded read of its own.
  defp pause_commit_candidate(%AgentSpec{opts: opts}, agent_id, meta) do
    case Keyword.fetch(opts, :pause_commit) do
      {:ok, sha} -> non_empty(sha)
      :error -> stored_pause_commit(meta, agent_id)
    end
  end

  # The direct-dispatch fallback: a BOUNDED, offloaded read
  # (`EvoGit.TaskRegistry.AgentStateRead`) with a 2 s budget, so a locked, busy
  # or dead agent-state store can never block the scheduler — an expiry degrades
  # to `nil`, which is exactly the "unusable sha" path above.
  defp stored_pause_commit(meta, agent_id) when is_integer(agent_id) do
    case Map.get(meta, :task_id) do
      task_id when is_binary(task_id) ->
        EvoGit.TaskRegistry.AgentStateRead.pause_commit(task_id, agent_id,
          op: "dispatch pause_commit",
          timeout: 2_000
        )
        |> non_empty()

      _absent ->
        nil
    end
  end

  defp stored_pause_commit(_meta, _agent_id), do: nil

  # Base rewriting stays the ONE mechanism the worktree create reads:
  # `Worktrees.create_worktree/6` and `assign_and_prepare_worktree/3` both take
  # the base from `spec.phylo_node.current_commit`, so no new argument is
  # threaded through either of them. The rewritten spec is persisted by the
  # caller's single `Store.put_sched_meta/2` write.
  defp apply_base(nil, spec, meta), do: {spec, meta, nil}

  defp apply_base(sha, %AgentSpec{phylo_node: %EvoGit.Core.PhyloGraphNode{}} = spec, meta) do
    updated_spec = %{spec | phylo_node: %{spec.phylo_node | current_commit: sha}}
    {updated_spec, %{meta | spec: updated_spec}, sha}
  end

  defp apply_base(_sha, spec, meta), do: {spec, meta, nil}

  # --- Helpers ---

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_value), do: nil
end
