# Agent Run Durability & Full-Tree Resume

Design record for `EvoGit.AgentState` (the `<data_dir>/agent_state.sqlite` durable run store) and the resume path built on it.
Read this before changing per-agent checkpoints, pause/resume, crash retry, agent identity allocation, worktree reclamation, or the agent-state supervision.
It supersedes the "root-only after a restart" limit that `task-pause.md` recorded.

## What durability must deliver

1. **A live-run snapshot.** For every RUNNING agent of every task, the store holds one row: identity, parent linkage, depth, repo/node context, objective, model selection, phase/turn/usage, the current conversation, the in-flight tool batch, the git branch and the commit the run is anchored to.
   Finished agents are NOT tracked: a completed run's row is deleted once nothing needs it, and retention pruning is the backstop.
2. **Exact resume.** A resumed agent restores its FULL conversation and scalar state (not a fresh prompt), on the same `agent_id`, on a worktree based on the work its crashed/live predecessor had actually produced, so it continues instead of restarting.
3. **Whole-tree resume.** A task resume restores the ROOT and every child that was running when the host died — each with its own transcript, worktree and branch — and resolves the parent's dangling subagent tool calls against the children's real results.
4. **Non-interference.** Durable state is best effort: no durable-state operation may crash, stall or corrupt a running task or agent, under concurrent tasks, a saturating disk, a locked database or a failed boot.

## Row model (`agent_states`, one row per running agent)

Identity and structure: `task_id`, `agent_id` (UNIQUE per task, stable across restarts), `parent_id` (NULL = root of the task), `depth`, `spawn_turn` + `spawn_index` (where in the parent's tool batch this child was started), `status` (`running` | `done`).

Conversation: append-only compressed message chunks (`agent_state_chunks`), `message_count`, `chunk_count`.

Run facts: `agent_module`, `mode`, `archive`, `custom_agent_id`, `objective`, `node_path`, `repo_id`, `repo_less`, `repo_root`, `model_spec`, `provider_profile_id`, `model_id`, `model_id_locked`, `prompt_cache_key`, `llm_model`, `llm_context_window`, `turn`, `usage`, `total_tokens`, `compression_count`, `current_commit`, `phase`, `pending_inputs`, `pending_tool_batch`, `pause_commit`.

Git: `branch` (the agent's own work branch), `base_commit` (the commit its worktree was created from), `current_commit` (the newest commit it produced), `anchor_ref` (the ref that keeps those commits reachable).

Re-dispatch: `redispatch` (JSON) — the normalized fields needed to build the agent's `%AgentSpec{}` again: `agent_type`, `delegation_level`, `tools`, `max_turns`, `custom_agent_id`, `model_spec`, `node_path`, `repo_id`, `objective`, `task_number`, `task_local_id`, `foreign_repos`, plus the parent linkage and batch position.
It never carries pids, funs, credentials or request options.

Completion: `status='done'` + `result` (JSON: text, commit, repo id) + `current_commit`.
A done child row stays readable until its parent's batch is resolved (the parent's checkpoint that CLEARS `pending_tool_batch` deletes the `done` children of that turn); a completed root deletes itself.
`prune/1` (retention, default 7 days) is the backstop for rows a crash left behind.

## Identity across restarts

`agent_id` must be stable, because every durable read is keyed `(task_id, agent_id)`.
The scheduler's in-memory counter restarts at 1 per BEAM, so:

* the scheduler seeds `next_agent_id` from the store's `max(agent_id) + 1` at boot;
* a resumed agent registers with its PERSISTED id (explicit-id registration), and an id already held by a live agent fails closed (the run degrades to a fresh agent instead of hijacking another run);
* a restore verifies the loaded row's `parent_id`/`depth` match the expected slot, so an id collision can never splice one agent's transcript into another.

## Git anchoring

A branch inside `.genesis/workers/` is NOT durability: the first worktree create after a BEAM restart wipes the workers directory and every `evogit-agent-*` branch, and an unanchored commit is then gc-eligible.

* At every turn-boundary checkpoint the session anchors `current_commit` at `refs/genesis/agent-state/<task_id>/<agent_id>` (one `git update-ref`, fire-and-forget, never blocking the turn).
* Anchored refs survive worktree reclamation and branch cleanup, so `git gc` cannot drop the run's commits.
* A resumed run's worktree base is `pause_commit || current_commit || crash_commit || task base`, and its branch is recreated from the anchor when the branch was wiped.
* Uncommitted worktree changes are NOT preserved by a hard kill; the resume narration says so instead of pretending otherwise.

## Resume protocol

1. `TaskRegistry.resume_task/1` refuses a task without a durable ROOT row, then re-enqueues the SAME task id with `resume_kind` (`:clean_pause` / `:dirty_pause`).
2. The root is dispatched with its persisted `agent_id`, `restore_agent_state: true`, and the worktree base from its anchor.
3. `EvoGit.Agent.Session.Setup` restores the transcript and scalars, then `EvoGit.Agent.Resume.apply/1` repairs only what the persisted in-flight marker proves was interrupted; a clean pause is not repaired and gets neutral wording.
4. A dangling subagent call is resolved by `reattach_sub_agents/3`: when no in-memory batch survives, the scheduler rebuilds the batch from the durable rows — `done` children contribute their stored result, `running` children are re-spawned with their persisted id, restored conversation, and their own anchored worktree — and waits for them exactly like a live batch.
5. Each re-spawned child repeats steps 3-4 for its own batch, so resume is recursive down the tree.
6. Child results merge into the parent worktree through the ordinary `SubagentProcessing` merge path.
7. A tool call with no durable child row is reported honestly as lost (`:subagent_result_lost`); nothing is invented.

## Isolation and containment

Durable state must never be able to hurt a run:

* **Boot is non-fatal.** A failed open/migration starts a DEGRADED store (no repo, every API total) and retries with bounded backoff; the subsystem lives under its own supervisor with generous restart intensity, so a failing disk cannot take down `EvoGit.Supervisor`, the application or the BEAM. A repo `:EXIT` is handled explicitly (log + restart/reboot), never swallowed into a permanently dead repo.
* **No synchronous barriers on life-critical processes.** Checkpoints and completion are casts. A finalizing session delivers its result BEFORE any durable bookkeeping. `EvoGit.TaskRegistry` and `EvoGit.AgentScheduler` never make synchronous durable calls: reads go through a bounded offloaded task, deletes are batched.
* **The writer is coalescing and bounded.** One writer serializes SQLite writes; superseded work for the same agent is replaced (only the newest `:rewrite` matters, appends after it are folded), payloads above a configured cap are skipped with ONE warning, and the writer's mailbox is bounded so a stalled disk cannot OOM the VM.
* **Honest barriers.** `flush/1` answers `:ok | {:error, :timeout}`; a pause only claims a durable checkpoint when it is `:ok`. The call timeout budget is never smaller than the DB busy timeout plus the statement budget.
* **Failures degrade, they do not raise.** Every public function is total; `database_busy`/`database_locked`/ENOSPC/`:noproc` answer documented error values, and a failed restore answers fresh state with a warning plus the restore-degradation sentence.

## What resume does NOT do

* Interactive sessions are never resumed (their lifecycle is user-driven).
* `persistent_state: false` tasks have no durable state at all: no pause, no restore.
* A child that finished and whose parent already consumed its result is gone, as intended.
* A hard kill may lose the turn that was in flight; only the last completed checkpoint is guaranteed.
