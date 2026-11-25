# Agent Resume Tests — `test/evo_git/agent/resume/`

## Intent

Pins the DURABLE half of whole-tree resume: the worker-side rebuild plan built from a resumed parent's durable roster, and `EvoGit.Agent.Resume.Reattach.resolve/3`'s use of it when no in-memory batch survived.
Both suites are `async: true` and touch nothing BEAM-global: the roster, the rebuild call and the session seam are explicit options (`:roster_fun`, `:rebuild_fun`, `:reattach_fun`, `:spawn_fun`), never app env.

## Routing Table

- `roster_batch_test.exs` → `EvoGit.Agent.Resume.RosterBatchTest` (pure, injected `:roster_fun`): one slot per expected subagent call ordered by `spawn_index`, a `done` row contributing its stored result (text, commit, repo id, branch), a `running` row rebuilt into an `%AgentSpec{}` carrying the resume opts (persisted id, own base/branch/anchor, `restore_agent_state: true`) with the parent's resume KIND deciding its pause position (a `:clean_pause` child gets its OWN `pause_commit` plus that `:resume_kind`; a `:dirty_pause` child gets an explicit `nil` `pause_commit` suppressing a stale durable one; a crash retry writes neither key), a missing/unrebuildable slot as `:missing`, a row from an earlier turn never adopted, and total decline for `persistent_state: false`, a missing task id or an unknown turn.
- `reattach_test.exs` → `EvoGit.Agent.Resume.ReattachTest`: `Reattach.resolve/3` uses the surviving in-memory batch when there is one and otherwise REBUILDS from the durable roster through ONE `rebuild_subagent_batch/3` call; a finished child's stored result answers its call with no re-spawn, a still-running child arrives as a re-spawn plan, a row-less slot is upgraded to `:fresh` (a production-built spec with NO persisted id) on a `:clean_pause` and stays `:missing` on a `:dirty_pause`, a rebuilt same-repo commit is merged into the parent worktree, a lost slot answers the honest fallback text, and `persistent_state: false` never reads the roster.
- `../resume_test.exs` → the marker/transcript repair itself (synthetic per-class results, the ONE `[RESUME]` notice, and the batch-level fallback wording).
- `../../../lib/evo_git/agent/resume/CONTEXT.md` → production contracts for `Resume`, `Reattach`, `RosterBatch` and `ToolBatch`.
- `../agent_scheduler/CONTEXT.md` → `subagent_rebuild_test.exs`, the scheduler-side install half.

## Constraints

- `async: true` is load-bearing: no scheduler, session, worktree, ETS or app-env is required by either suite.
- Assertions pin HONESTY: a slot that cannot be rebuilt yields the fallback text or `{:error, :subagent_result_lost}`, never an invented result.
- A rebuilt child spec resumes ITS OWN run (persisted id + resume opts, inheriting the parent's resume KIND as its own pause position); a `:done` child must never be re-spawned or charged twice.
