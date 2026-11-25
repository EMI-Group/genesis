# Task-level Pause & Resume — design record

**Status:** design record of the SHIPPED implementation: a pause takes a SNAPSHOT of the whole task tree in place and a resume THAWS that snapshot. Implementation detail lives in the CONTEXT.md files it touches (`apps/evo_git/lib/evo_git/task_registry/CONTEXT.md`, `agent_scheduler/CONTEXT.md`, `agent/CONTEXT.md`, `agent_state/CONTEXT.md`, `apps/evo_dash/lib/evo_dash_web/CONTEXT.md`).

## 1. Why a task needs its own pause

The scheduler-wide pause (`EvoGit.AgentScheduler.pause/0`) stops NEW work — it grants no slots, dispatches no agents — but a running task keeps its agents blocked in-flight and holding their worktrees. It is a throttle, not a bookkeeping state.
A task-level pause is the opposite: one named task winds DOWN to a durable, resumable resting state, releases its worktree and its slots, and can be resumed later from exactly where it stopped.
Timer-driven agent state (`agent_state.sqlite`, `:persistent_state`) is already the durability substrate, so pause is a lifecycle on top of it, not a second persistence mechanism.

## 2. States

| Status | Meaning | Terminal | Lease |
|---|---|---|---|
| `:pausing` | a pause request is freezing the tree: a bounded quiesce, then a forced freeze of whatever is left | no | renewed (a wrapper is alive) |
| `:paused` | every agent's frozen position is durable — a turn boundary, or parked awaiting its subagent batch | no | none (no wrapper, no heartbeat) |

`:paused` is NOT `:cancelled` and NOT `:failed`: it keeps `finished_at` nil, keeps the transcript/result context, and is resumable.
`:cancelled` keeps meaning "gracefully cancelled by the user"; a pause never lands there.
A cancel that arrives while `:pausing` wins (the pause is abandoned, the cancel proceeds); a pause that arrives while `:cancelling` is ignored.

## 3. Clean vs dirty

`pause_kind` (`:clean` | `:dirty`) is a persisted task fact (`tasks.pause_kind`), nil whenever the task is not paused.

- **`:clean`** — the user paused the task, the whole tree was snapshotted in place (including parents parked on a subagent batch), and the kind is only recorded when every agent proved it froze inside the bounded quiesce. Nothing was interrupted, so the resume restores the transcript with NO repair and NO "files may be inconsistent" wording.
- **`:dirty`** — a restart/lease sweep, a quiesce that expired, or any agent that could not prove a clean freeze: the snapshot may hold interrupted work, so the resume runs the dangling-tool repair (honest per-class synthetic tool results) plus ONE `[RESUME]` notice.

Both kinds pause and resume through exactly one protocol; the kind decides ONLY (a) whether the bounded quiesce runs before snapshotting and (b) whether resume applies the repair plus narration — one snapshot builder and one thaw planner serve both.

## 4. Pause protocol (snapshot)

1. `EvoGit.TaskRegistry.pause_task/1` validates the status (`:running`, `:pending`, `:awaiting_input` accepted; `:pausing`/`:paused` idempotent; interactive-session tasks are refused — they have no resumable run).
2. The row becomes `:pausing` (`persist then broadcast`, dashboard shows the freeze).
3. `EvoGit.AgentScheduler.begin_task_pause/1` opens ONE `%EvoGit.AgentScheduler.TaskFreeze{}` over the task's LIVE roster: it flips the PAUSE flag in `EvoGit.AgentScheduler.ControlPlane` for every agent of the task, purges those agents' queued LLM/tool slot requests with `{:error, :paused}` so a pause cannot hang behind a slot wait, and parks every parent blocked in `spawn_sub_agents/2` (`Subagents.park_for_pause/2` replies `{:freeze, :task_pause}` and clears its batch bookkeeping; a later `spawn_sub_agents/2` for that task registers nothing).
4. Each agent reaches one of the TWO freeze points: a TURN BOUNDARY (right after a tool batch completes, at the top of the exchange loop) or its parked-awaiting-children position. In-flight tool calls are never interrupted — that is what makes the freeze clean — and a parent blocked on a subagent stays blocked instead of having its batch resolved.
5. Before the session stops it: reaps background jobs, creates a checkpoint commit of its worktree (anchored under `refs/genesis/salvage/<branch>` so reclaim/prune cannot lose it), records the sha durably per agent, PRESERVES the durable in-flight `pending_tool_batch` marker so the snapshot records the exact position (`:turn_boundary` | `{:awaiting_children, turn}` | `{:batch, class}`), flushes the durable checkpoint (`EvoGit.AgentState.flush/1`), and reports `{:paused, info}` to the freeze (never `{:ok, %Result{}}`, never `{:error, reason}`) with its own `clean_freeze`/`durable` facts.
6. The freeze is bounded: a quiesce of `:task_pause_quiesce_ms` (default 120 s) then a per-agent `{:task_freeze, :force}` with a 10 s grace, which kills a live exchange worker while leaving the pre-batch marker untouched — that checkpoint IS the snapshot, and the freeze degrades to `:dirty`. ONE task-level term `{:paused, %{pause_kind, clean_freeze, durable, frozen_agents}}` answers the ROOT's caller only after the LAST report, with the kind derived by `EvoGit.TaskRegistry.Pause.pause_kind/1`; the row becomes `:paused` (`pause_kind` derived, no lease, `finished_at` nil, `result`/`usage`/archive preserved) and the worktrees are reclaimed normally (the checkpoint commit is what survives).

No subagent call is ever completed by a pause: nothing is merged, no parent batch result slot is filled, and no "child finished" narration is produced — a parent that was waiting stays waiting, and its durable in-flight batch marker is the snapshot of that position. A paused child's durable row keeps `status = "running"` plus its own `pause_commit`, because nothing consumed it.

## 5. Dirty pause (restart)

Boot reconciliation and the lease sweep map a `:running`/`:pausing` row to `:paused` with `pause_kind: :dirty` when the task is RESUMABLE — `persistent_state` is on AND the task's durable ROOT row exists — instead of today's `:failed`.
Non-resumable rows keep today's `:lease_expired` → `:failed` behaviour.
The dirty snapshot is simply whatever `<data_dir>/agent_state.sqlite` still holds: one row per running agent, written by the deadline-crashed runs' own last checkpoints, and the read is the one `EvoGit.AgentState.Snapshot`.

## 6. Resume protocol (thaw)

`EvoGit.TaskRegistry.resume_task/1` accepts `:paused` only, re-enqueues the SAME task id (never mints a new one), and reuses the persisted opts.
The resumability gate is the durable ROOT row (`EvoGit.AgentState.Snapshot.root?/1`): the rest of the tree rides along with it, a child-only roster is `:not_resumable`, and an unreadable store answers `{:error, :store_unavailable}` rather than pretending.
The dispatch context carries `restore_agent_state: true`, a `resume_kind` (`:clean_pause` | `:dirty_pause` | nil — there is no `:crash` value; absent means an ordinary crash retry), the persisted `agent_id`, and the per-agent worktree base (`pause_commit` → `current_commit` → `crash_commit` → the task base, each verified with `git cat-file -e`), with the branch recreated from its anchor when a restart had reclaimed it.
The one thaw planner (`ResumePlan` / `Reattach` / `RosterBatch` / `SubagentRebuild`) restores the whole tree with the same ids, topology and positions; which of the three positions a run thawed from decides its repair:

- **turn boundary** ⇒ restore the conversation, no repair, one neutral resume notice.
- **awaiting children** ⇒ the parent's batch is REBUILT from the durable rows, never re-issued: a `done` child contributes its stored result, a `running` child is re-spawned under its own id with its own `pause_commit`/conversation/worktree, and a child frozen before it registered becomes a `:fresh` spawn from the original call's spec. The parent keeps waiting and merges only when a child genuinely returns a result; a call with no durable row is reported honestly as lost.
- **dirty** ⇒ restore the conversation, run the existing `EvoGit.Agent.Resume` repair (dangling-tool `[RESUME]` handling) and ONE `[RESUME]` notice.

A clean-frozen child resumes with `:clean_pause` and its own `pause_commit`; a dirty child resumes with an explicit `pause_commit: nil`, so it never adopts a checkpoint the freeze could not prove.
The prompt-cache prefix invariant holds: system message and first user message stay byte-identical; the resume notice is appended as a new trailing harness message.

## 7. Invariants

- Persist before broadcast; every broadcast carries `node()`.
- A pause outcome must be checkpointed explicitly (an error exit is never checkpointed).
- No `:finalizing` notification, and a pause never completes or merges a subagent batch — it preserves the in-flight marker instead.
- `:paused` rows are never reported as "finished" by store/SQL filters (they must survive `clear_finished_tasks`).
- An LLM slot request that is purged by a pause must land as a pause, never as `:failed` or `:cancelled`.
- The status-bearing lists are a totality contract (`test/evo_git/status_admission_totality_test.exs`): every list that admits `:running` admits `:pausing`, every list that admits `:awaiting_input` admits `:paused`, unless an absence is pinned.

## 8. Limits

Interactive sessions are out of scope (no pause, no resume) — their lifecycle is user-driven and their durability is still deferred (P5).
A pause is only possible when durable agent state is enabled; with `persistent_state: false` the task is not resumable and pause is refused rather than pretending.
The freeze budget is bounded (a 120 s quiesce plus a 10 s force grace); a tree that cannot quiesce inside it is force-frozen and snapshotted as `:dirty`, never left `:pausing` forever.
