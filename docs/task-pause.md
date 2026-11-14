# Task-level Pause & Resume — design record

**Status:** design record. The contract below is what the pause/resume implementation must satisfy; implementation detail lives in the CONTEXT.md files it touches (`apps/evo_git/lib/evo_git/task_registry/CONTEXT.md`, `agent_scheduler/CONTEXT.md`, `agent/CONTEXT.md`, `agent_state/CONTEXT.md`, `apps/evo_dash/lib/evo_dash_web/CONTEXT.md`).

## 1. Why a task needs its own pause

The scheduler-wide pause (`EvoGit.AgentScheduler.pause/0`) stops NEW work — it grants no slots, dispatches no agents — but a running task keeps its agents blocked in-flight and holding their worktrees. It is a throttle, not a bookkeeping state.
A task-level pause is the opposite: one named task winds DOWN to a durable, resumable resting state, releases its worktree and its slots, and can be resumed later from exactly where it stopped.
Timer-driven agent state (`agent_state.sqlite`, `:persistent_state`) is already the durability substrate, so pause is a lifecycle on top of it, not a second persistence mechanism.

## 2. States

| Status | Meaning | Terminal | Lease |
|---|---|---|---|
| `:pausing` | a pause request is draining the task's agents | no | renewed (a wrapper is alive) |
| `:paused` | every agent stopped at a turn boundary and its state is durable | no | none (no wrapper, no heartbeat) |

`:paused` is NOT `:cancelled` and NOT `:failed`: it keeps `finished_at` nil, keeps the transcript/result context, and is resumable.
`:cancelled` keeps meaning "gracefully cancelled by the user"; a pause never lands there.
A cancel that arrives while `:pausing` wins (the pause is abandoned, the cancel proceeds); a pause that arrives while `:cancelling` is ignored.

## 3. Clean vs dirty

`pause_kind` (`:clean` | `:dirty`) is a persisted task fact (`tasks.pause_kind`), nil whenever the task is not paused.

- **`:clean`** — the user paused the task. Every agent stopped AFTER its in-flight tool batch completed (no tool was interrupted), the conversation was checkpointed, and the worktree got a checkpoint commit. Resume restores the transcript with NO repair and NO "files may be inconsistent" wording: nothing was interrupted and the worktree is exactly what the agent left.
- **`:dirty`** — the task was brought back by a restart. The agents died mid-flight, so the last tool batch may be partially executed. Resume runs the existing crash-resume repair (honest per-class synthetic tool results) plus the `[RESUME]` notice.

Both kinds pause and resume through exactly one protocol; the kind only changes the resume narration and repair, never the durability mechanism.

## 4. Pause protocol (clean)

1. `EvoGit.TaskRegistry.pause_task/1` validates the status (`:running`, `:pending`, `:awaiting_input` accepted; `:pausing`/`:paused` idempotent; interactive-session tasks are refused — they have no resumable run).
2. The row becomes `:pausing` (`persist then broadcast`, dashboard shows the drain).
3. `EvoGit.AgentScheduler.begin_task_pause/1` sets a PAUSE flag in `EvoGit.AgentScheduler.ControlPlane` for every agent of the task, and purges those agents' queued LLM/tool slot requests so a pause cannot hang behind a slot wait.
4. Each agent honours the flag at a TURN BOUNDARY: right after a tool batch completes (results appended, `pending_tool_batch` cleared) and at the top of the exchange loop. In-flight tool calls are never interrupted — that is what makes the pause clean.
5. Before the session stops it: reaps background jobs, creates a checkpoint commit of its worktree (anchored under `refs/genesis/salvage/<branch>` so reclaim/prune cannot lose it), records the sha durably per agent, flushes the durable checkpoint (`EvoGit.AgentState.flush/1`), and delivers a paused outcome (never `{:ok, %Result{}}`, never `{:error, reason}`).
6. When every agent of the task reports paused, the row becomes `:paused` with `pause_kind: :clean`, no lease, `finished_at` nil, `result`/`usage`/archive preserved; the worktrees are reclaimed normally (the checkpoint commit is what survives).

An agent blocked on a subagent answers the batch after its children pause, merges their committed work exactly like a normal completion, and then stops at its own boundary.

## 5. Dirty pause (restart)

Boot reconciliation and the lease sweep map a `:running`/`:pausing` row to `:paused` with `pause_kind: :dirty` when the task is RESUMABLE — `persistent_state` is on AND a durable agent-state row exists for the task — instead of today's `:failed`.
Non-resumable rows keep today's `:lease_expired` → `:failed` behaviour.
Only the root agent is resumable after a restart: subagent processes are gone, their retained batch is scheduler memory, and a child's partial work survives only if it was already merged. This is stated in the UI and in the resume notice.

## 6. Resume protocol

`EvoGit.TaskRegistry.resume_task/1` accepts `:paused` only, re-enqueues the SAME task id (never mints a new one), and reuses the persisted opts.
The dispatch context carries `restore_agent_state: true`, a `resume_kind` (`:clean_pause` | `:dirty_pause` | `:crash`) and the per-agent checkpoint sha as the worktree base (verified with `git cat-file -e`, degrading to the task base).
Clean pause → restore the conversation, no repair, one neutral resume notice.
Dirty pause → restore the conversation, run the existing `EvoGit.Agent.Resume` repair and `[RESUME]` notice.
The prompt-cache prefix invariant holds: system message and first user message stay byte-identical; the resume notice is appended as a new trailing harness message.

## 7. Invariants

- Persist before broadcast; every broadcast carries `node()`.
- A pause outcome must be checkpointed explicitly (an error exit is never checkpointed).
- No `:finalizing` notification and no merge on a pause.
- `:paused` rows are never reported as "finished" by store/SQL filters (they must survive `clear_finished_tasks`).
- An LLM slot request that is purged by a pause must land as a pause, never as `:failed` or `:cancelled`.
- The status-bearing lists are a totality contract (`test/evo_git/status_admission_totality_test.exs`): every list that admits `:running` admits `:pausing`, every list that admits `:awaiting_input` admits `:paused`, unless an absence is pinned.

## 8. Limits

Interactive sessions are out of scope (no pause, no resume) — their lifecycle is user-driven and their durability is still deferred (P5).
A dirty resume cannot restore subagents.
A pause is only possible when durable agent state is enabled; with `persistent_state: false` the task is not resumable and pause is refused rather than pretending.
