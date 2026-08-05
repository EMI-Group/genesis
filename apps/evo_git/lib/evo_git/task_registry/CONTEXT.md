# TaskRegistry Support Modules

## Intent

Support modules extracted from `EvoGit.TaskRegistry` GenServer to keep the main module focused. These are pure-function or ETS-only modules — none maintain their own GenServer state. They were migrated from `evo_dash` (formerly `EvoDash.TaskRegistry.*`) to `evo_git` as part of the domain persistence layer migration.

## Routing Table

None — leaf directory (all modules at this level).

## API Surface

| Module | File | Purpose |
|--------|------|---------|
| `EvoGit.TaskRegistry.Cleanup` | `cleanup.ex` | Expires finished tasks by configurable age (14d default) and count (100 default). Two variants: store-read (fresh scan) and pre-loaded list (avoids double table scan at init). |
| `EvoGit.TaskRegistry.Diagnostics` | `diagnostics.ex` | Failed-transition diagnostic logging with greppable prefix (`"TaskRegistry: FAILED_TRANSITION"`) and captured stacktraces. Pure Logger/Process.info functions — no GenServer state dependency. |
| `EvoGit.TaskRegistry.Lease` | `lease.ex` | Lease validity checks and `:evogit_sched_meta` ETS helpers: `sched_meta_has_active_agents?/1` (cross-VM liveness detection), `lease_valid?/1` (expiry check), `best_effort_result/1` (result lookup). All ETS access guarded by `:ets.info/1` (non-crashing). |
| `EvoGit.TaskRegistry.RuntimeOpts` | `runtime_opts.ex` | Keyword-list builder for `EvoGit.Runtime.*` modules. Threads mode atoms, `model_id`, `build_system`, `archive`, `foreign_repos`, `starting_commit`, `node_path` into runtime opts. |
| `EvoGit.TaskRegistry.ResumeContext` | `resume_context.ex` | Assembles a "Previous Task Context" block (commits, objective, result summary) prepended to the objective when an evolve task resumes from a prior task. Sets `:starting_commit` from the prior task's `commit_sha`. |
| `EvoGit.TaskRegistry.TaskExecutor` | `task_executor.ex` | Execution entry points: `:genesis` → `Runtime.Genesis.run`, `:evolve` → `Runtime.Evolution.run`, `:extract_skills` → `Runtime.SkillExtraction.run`. Runs in spawned processes under `Task.Supervisor`, registers tasks in `ProcessRegistry`. |

## Constraints

- All modules are pure functions or ETS-only — no GenServer state, no I/O (aside from `Cleanup` which calls `EvoGit.Store` for deletion).
- `Lease` module: all ETS access uses `:ets.info/1` first (returns `:undefined` for missing tables), avoiding `try/rescue`.
- `Diagnostics`: logging only — never modifies state or raises.
- `TaskExecutor`: runs OUTSIDE the GenServer process (under `Task.Supervisor`).
- `RuntimeOpts` and `ResumeContext`: pure builders — no side effects.

## Restart Recovery & Status Transitions (findings)

**✅ FIXED — startup reconciliation for orphaned `:finalizing` tasks.** `TaskRegistry.init/1` (`task_registry.ex:159-220`) now reconciles orphaned `:finalizing` tasks directly: after `integrity_check`, it runs the lightweight query `EvoGit.Store.select_running_lease_info/1` (`task_registry.ex:195` — reads id+status+lease_expires_at for ALL rows, no SQL status filter), filters `status == :finalizing`, and for each such task synchronously calls the shared `handle_update_status/6` (`:506`) with `:failed`, result `"Runtime restarted during task finalization"`, empty opts, and `caller_info = {:startup_reconcile, :finalizing}`. This performs task_get, the stale-guard (`:finalizing`→`:failed` passes — `:finalizing` is non-terminal), `Diagnostics.log_failed_transition`, finished_at/lease_expires_at handling, the `{:tasks_updated}` broadcast, and task_refs cleanup. The writes are SYNCHRONOUS in init (NOT via the async `update_task_status/4` cast, which would race callers). This covers the crash window where slow git calls in `merge_and_report/3` hang while the task sits at `:finalizing` and the app dies before the terminal write. Still true afterwards:
- `state.task_refs` is in-memory only (`task_registry.ex:178,233`) — after restart it's empty, so the `{ref, result}` handler (`:730`) and `{:DOWN, ...}` handler (`:808`) can never fire for pre-restart tasks (hence the init reconciliation above).
- `:heartbeat` (`:872-888`) renews leases only for owned tasks with `status in [:running, :pending]` (`:858`→now `:881`) — never `:finalizing`.
- `:lease_sweep` (`:896-947`, one-shot, fires `@sweep_after` = 150s after init, `:217`) filters `status == :running and id not in owned_ids and not Lease.lease_valid?(lease)` (`:904-909`) — **`:finalizing` is excluded by design**: init already handled it, and `:running` stays the sweep's job (it respects lease validity for the legitimate multi-VM case).
- `:periodic_cleanup` (`:952-956`) → `Cleanup.cleanup_expired_tasks/1` only deletes tasks with `finished_at != nil` (`cleanup.ex:41-43,50,89`); `:finalizing` tasks have `finished_at == nil` (set only for terminal transitions, `task_registry.ex:534-537,701-704`) → never deleted.
- `{:recheck_task, task_id}` (`:971-990`) would resolve a `:finalizing` task (its guard only excludes terminal statuses), but **NOTHING schedules the first recheck** — only self-rescheduling. The handler remains unreachable dead code.

**Resolution paths for a `:finalizing` task now:** (a) **at startup** — init reconciliation marks it `:failed` with `"Runtime restarted during task finalization"` (the fix above); (b) explicit user action — `clear_finished_tasks` (`task_registry.ex:372-380`) uses `select_finished_task_ids` (`store.ex:521`, SQL `status NOT IN ('running','pending')` — **`SELECT` includes `:finalizing`**) and DELETEs them, or `delete_task` (`:441`); (c) in-process only: wrapper completion → `{ref, result}` (`:730-805`, `{:ok,_}`→`:completed`, error/exit→`:failed`), wrapper crash → `:DOWN` (`:808-866`, `:normal`→`:completed`, abnormal→`:failed` only if `Lease.sched_meta_has_active_agents?` is false), or the public `update_task_status/4` cast (`:78`; stale-guard blocks terminal→terminal changes except to `:completed`). `cancel_task` only works from `status: :running` (`:277`). **Lease expiry plays NO role in resolving `:finalizing`** — a stuck-but-alive `:finalizing` wrapper just stops getting lease renewals (heartbeat skips it) and stays `:finalizing` until the wrapper process finishes/dies or the runtime restarts.

**Dead code:** `Lease.set_crash_details/1` (`lease.ex:76-80`) has zero callers; `Lease.lookup_sched_meta_result/1` (`lease.ex:42-60`) is only used by the unreachable `resolve_recheck_task/3` (`task_registry.ex:576-622`).

**Cleanup semantics:** `Cleanup.cleanup_expired_tasks/1,2` (`cleanup.ex:31,72`) never change status — they only DELETE, keyed on `finished_at != nil` (age `:lt` cutoff, `cleanup.ex:41-43,81-82`; count `max_tasks` newest-kept `cleanup.ex:48-53,87-92`). `select_cleanup_info` (`store.ex:588-601`) reads ALL tasks with no SQL status filter — the `finished_at != nil` guard is the only filter, so in practice only terminal tasks are cleaned. `config` defaults `max_tasks: 100, max_age_days: 14` (`cleanup.ex:13`).

**Lease mechanics:** `@lease_duration 120` s, `@heartbeat_interval 60_000` ms, `@sweep_after (@lease_duration + 30) * 1000` ms (`task_registry.ex:37-42`). Lease set at start (`:225`), renewed by heartbeat via `Store.update_lease_expires_at` (`:859`). The one-shot `:lease_sweep` marks expired `:running` foreign tasks `:failed` only when `sched_meta_has_active_agents?` is false (`:888-909`), then runs cleanup + broadcasts (`:918-921`).

**TaskExecutor structure:** `start_task` (`:206-237`) does `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, TaskExecutor, :execute_task, [task_type, opts, task_id])` (`:208-213`). The wrapper process IS the executor — `TaskExecutor.execute_task/3` (`task_executor.ex:20-71`) registers itself in `EvoGit.TaskRegistry.ProcessRegistry` (`:21,79-81`) and calls the runtime phase directly (Genesis.run `:24`, Evolution.run `:40`, SkillExtraction.run `:70`). **The wrapper never writes statuses** — TaskRegistry's GenServer performs all writes from `{ref, result}` / `:DOWN` / PubSub `{:task_status, ...}` / `update_status` casts; `handle_update_status` (`:483-558`) writes via `EvoGit.Store.update_task_columns` (`:543`) and deletes terminal tasks from `task_refs` (`:545-549`).
