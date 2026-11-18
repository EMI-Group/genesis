defmodule EvoGit.AgentScheduler.SpawnFacts do
  @moduledoc """
  The spawn-side identity and context contract of `EvoGit.AgentScheduler.Dispatch`:
  explicit-id admission, the spawn FACTS a registration stores, and the dispatch
  context a session is started with.

  Extracted out of `dispatch.ex` because all three are pure functions over the
  state/meta/spec the scheduler already holds — no ETS mutation, no I/O beyond
  one registry lookup — and they are the contract the durable agent-state resume
  path consumes.

  ## Identity is stable, admission fails closed

  `agent_id` keys every durable read (`EvoGit.AgentState` rows are
  `(task_id, agent_id)`), so a resume re-registers with the id a previous run
  PERSISTED. Adopting an explicit id is only allowed when it is FREE: no live
  `EvoGit.Agent.Session` is registered under it (the AUTHORITY — the unique-name
  registry that makes "one session per agent id" structural) and no
  NON-terminal `:evogit_agent_summary` row claims it (belt and braces for a run
  whose session pid is already gone but whose row has not settled). Anything
  else answers `{:error, {:agent_id_taken, id}}` and nothing is written.

  ## Spawn facts

  `:spawn_turn` is the PARENT turn that issued the batch (the same turn the
  pre-batch `pending_tool_batch.turn` marker carries) and `:spawn_index` is the
  call's position in that batch. Both are stored on the registered spec, so the
  `%SchedMeta{}` row itself says where in the tree a child came from — no reader
  has to guess from ETS ordering. Only integers are stored: a `nil` (a ROOT)
  never becomes a `nil` entry.
  """

  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec

  # --- Explicit-id admission ---

  @doc """
  The id a registration should use: an explicit FREE id from
  `opts[:agent_id]`, else `state.next_agent_id` (today's allocation).

  A taken id fails closed. A non-positive or non-integer `:agent_id` is IGNORED
  (it falls back to allocation) rather than crashing the scheduler.
  """
  @spec resolve_agent_id(State.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def resolve_agent_id(%State{} = state, opts) do
    case Keyword.get(opts, :agent_id) do
      id when is_integer(id) and id > 0 ->
        if agent_id_free?(id), do: {:ok, id}, else: {:error, {:agent_id_taken, id}}

      _absent_or_invalid ->
        {:ok, state.next_agent_id}
    end
  end

  @doc """
  Whether an explicit id is still free — see the moduledoc for the two checks.
  """
  @spec agent_id_free?(term()) :: boolean()
  def agent_id_free?(id) do
    case EvoGit.Agent.Session.whereis(id) do
      {:ok, pid} when is_pid(pid) -> false
      _not_registered -> not live_summary_row?(id)
    end
  end

  @terminal_agent_statuses [:completed, :failed, :cancelled, :paused]

  defp live_summary_row?(id) do
    with tid when tid != :undefined <- :ets.whereis(:evogit_agent_summary),
         [{^id, row}] <- :ets.lookup(:evogit_agent_summary, id) do
      status = Map.get(row, :status)
      not is_nil(status) and status not in @terminal_agent_statuses
    else
      _absent -> false
    end
  end

  @spawn_fact_keys [:spawn_turn, :spawn_index]

  @doc """
  The spawn facts a registration ADOPTS from `opts` — integers only, so a `nil`
  fact never turns into a `nil` entry on the stored spec.
  """
  @spec spawn_facts(keyword()) :: keyword()
  def spawn_facts(opts) do
    opts
    |> Keyword.take(@spawn_fact_keys)
    |> Enum.filter(fn {_key, value} -> is_integer(value) end)
  end

  # --- Dispatch context ---

  @doc """
  The ONE dispatch context a session is started with.

  `plan` is the map `EvoGit.AgentScheduler.Dispatch.resume_plan/5` returned, i.e.
  the spec/meta the worktree is ACTUALLY created from, and every git fact is
  derived from it:

    * `:branch` — the branch `Worktrees.create_worktree/6` creates for this agent
      (`Worktrees.branch_name(task_number, task_local_id)`, the same formula
      `WorktreeManager` uses for its tracked rows);
    * `:base_commit` — the commit the created worktree really stands on.
      AUTHORITATIVE SOURCE: `plan.worktree_resume_from || spec.phylo_node.current_commit`.
      `apply_crash_base/3` REWRITES `phylo_node.current_commit` to the crash
      salvage / pause checkpoint sha (and reports it as `:worktree_resume_from`)
      and `Worktrees.create_worktree/6` reads exactly that field, so the two
      agree; the resume sha is preferred only because it states the intent
      explicitly. `nil` means "the spec carries no commit" (repo-less).

  `:spawn_turn` / `:spawn_index` are the child's spawn FACTS (`nil` for a ROOT),
  read from the stored spec opts — never guessed from ETS.
  """
  @spec build_dispatch_ctx(
          pos_integer(),
          SchedMeta.t(),
          EvoGit.AgentScheduler.AgentState.t() | map(),
          map(),
          String.t() | nil,
          String.t()
        ) :: keyword()
  def build_dispatch_ctx(
        agent_id,
        %SchedMeta{} = meta,
        agent_state,
        plan,
        repo_root,
        worktree_path
      ) do
    spec = plan.spec

    [
      agent_id: agent_id,
      depth: meta.depth,
      repo_root: repo_root,
      repo_id: spec.repo_id,
      worktree_path: worktree_path,
      retries: meta.retries,
      spec: spec,
      meta: meta,
      # The session's mode (`:oneshot | :interactive`), resolved at
      # registration and mirrored on SchedMeta. An interactive session yields
      # to `:awaiting_input` on a tool-free reply instead of finishing.
      session_mode: meta.mode,
      # `:persistent_state` is the TASK-WIDE durability flag (default `true`,
      # `false` opts the whole task — root plus descendants — out of durable
      # per-agent checkpoints). `:restore_agent_state` is set on a crash RETRY
      # of the SAME `agent_id` AND on a task-level PAUSE RESUME, so the rebuilt
      # session merges the persisted conversation onto its fresh dispatch
      # (fresh worktree/repo path, same identity); a first attempt always
      # starts clean.
      persistent_state: plan.persistent_state,
      restore_agent_state: plan.restore_agent_state,
      # Crash-resume-after-a-tool-call metadata (consumed by the agent-side
      # workstream; harmless when unused): the sha the retry worktree was
      # actually based on when it is NOT the task base (`nil` otherwise), and
      # the previous attempt's crash reason (`nil` on a first attempt).
      worktree_resume_from: plan.worktree_resume_from,
      retry_reason: meta.crash_reason,
      spawn_turn: Keyword.get(spec.opts, :spawn_turn),
      spawn_index: Keyword.get(spec.opts, :spawn_index),
      branch: Worktrees.branch_name(meta.task_number, agent_state.task_local_id),
      base_commit: dispatch_base_commit(plan),
      scheduler: self()
    ]
    |> put_resume_kind(plan.resume_kind)
    |> append_repo_less_ctx(spec, repo_root)
    |> append_notify_ctx(spec)
  end

  # See `build_dispatch_ctx/6`: the resume base wins when it was applied,
  # otherwise the spec's own commit IS the task base the worktree is created on.
  defp dispatch_base_commit(%{worktree_resume_from: sha}) when is_binary(sha) and sha != "",
    do: sha

  defp dispatch_base_commit(%{spec: %AgentSpec{phylo_node: %{current_commit: sha}}})
       when is_binary(sha) and sha != "",
       do: sha

  defp dispatch_base_commit(_plan), do: nil

  # Only a pause resume contributes a `:resume_kind` ctx key; every other run's
  # dispatch ctx stays exactly as it was.
  defp put_resume_kind(ctx, nil), do: ctx
  defp put_resume_kind(ctx, kind), do: Keyword.put(ctx, :resume_kind, kind)

  # For repo-less agents, carry the marker plus the resolved repo path in the
  # dispatch context: the session skips `create_worktree_for_agent` and uses
  # `repo_less_repo_path` as its `Process.get(:repo_path)`. No worktree is ever
  # created for a repo-less agent — the worktree path is synthetic (stored in
  # sched_meta for cancel lookup) and never materialized on disk.
  defp append_repo_less_ctx(ctx, spec, agent_repo_root) do
    if Keyword.get(spec.opts, :repo_less) do
      ctx ++ [repo_less: true, repo_less_repo_path: agent_repo_root]
    else
      ctx
    end
  end

  # An optional `:notify` sink for the session's non-terminal control messages
  # (`{:agent_session_closed, tag, result}`): carried ONLY when the spec opt is
  # a `{pid, tag}` tuple with a live pid shape, because the session
  # pattern-matches the key. The key is never present with a `nil` value.
  defp append_notify_ctx(ctx, spec) do
    case Keyword.get(spec.opts, :notify) do
      {pid, _tag} when is_pid(pid) -> ctx ++ [notify: Keyword.get(spec.opts, :notify)]
      _other -> ctx
    end
  end
end
