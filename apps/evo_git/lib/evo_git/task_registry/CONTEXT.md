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

## SQL-Lowering Opportunities (read-only analysis findings)

**Cleanup (`cleanup.ex`) — the primary opportunity:**
- `cleanup_expired_tasks/1` (cleanup.ex:31-62) reads `SELECT id, finished_at FROM tasks` for **ALL** rows (store.ex:588-601, no WHERE), then does ALL filtering/sorting in Elixir: age partition via `Enum.split_with` + `DateTime.compare(finished_at, cutoff) == :lt` (cleanup.ex:40-43), then `remaining |> Enum.filter(&(&1.finished_at != nil)) |> Enum.sort_by(& &1.finished_at, {:desc, DateTime}) |> Enum.drop(max_tasks)` (cleanup.ex:48-53). Could be pushed to SQL: `WHERE finished_at IS NOT NULL [AND finished_at < ?cutoff]` for age-expired; over-limit keys via `ORDER BY finished_at DESC LIMIT -1 OFFSET ?max_tasks`.
- ⚠️ **ISO-8601 lexicographic caveat**: `finished_at` is stored as `DateTime.to_iso8601/1` string (codec.ex:226). SQLite string comparison is only order-correct for consistently-UTC-Z values; a whole-second value (`"...00Z"`) sorts BEFORE a sub-second value (`"...00.5Z"`) because `'Z'` (0x5A) > `'.'` (0x2E). All writes use `DateTime.utc_now()`, but `to_iso8601` `:auto` precision emits microseconds only when non-zero, so both formats coexist today — boundary rows near the cutoff could be misclassified by a pure string comparison. A proper SQL lowering needs an epoch-seconds column or a normalized fixed-width timestamp.
- `cleanup_expired_tasks/2` (pre-loaded variant, cleanup.ex:72-101) is **DEAD CODE** — zero callers in `apps/evo_git/lib` and `apps/evo_dash/lib` (grep-verified). The "avoids double table scan at init" rationale never materialized; the only call sites (task_registry.ex:400, 942, 953) use the `/1` variant. Candidate for removal or wiring-up.
- `delete_tasks/2` (store.ex:434-439) issues N individual `DELETE FROM tasks WHERE id = ?1` statements in a loop — could be one batched `DELETE FROM tasks WHERE id IN (...)`.

**`select_running_lease_info` (store.ex:534-547)** reads ALL rows (`id, status, lease_expires_at`, no WHERE); both callers filter status in Elixir afterwards: init reconcile `status == :finalizing` (task_registry.ex:196) and lease_sweep `status == :running` (task_registry.ex:905-909). The status column is a plain string (codec.ex:192 — `Atom.to_string`), so SQL comparison is valid (`select_finished_task_ids` already uses `status NOT IN ('running','pending')` at store.ex:521). A `WHERE status IN ('running','finalizing')` (or a status param) would cut rows decoded. The `id not in owned_ids` (in-memory task_refs) and lease-expiry-vs-wall-clock parts must stay Elixir-side.

**ResumeContext (resume_context.ex:24)** → `TaskRegistry.get_task` → `Store.get_task/2` (store.ex:95,419) decodes the FULL 18-column row (including heavy JSON blobs logs/result/usage/archive_metadata) when only `base_sha` (resume_context.ex:44), `opts` (:84-85) and `result` (:89) are used. A lightweight variant (mirroring `select_tasks_summary`) would avoid the heavy decodes — low priority: single-row point lookup on an infrequent resume-from path.

**No Store access at all:** `lease.ex` (ETS-only; `sched_meta_has_active_agents?/1` at lease.ex:17-29 does a full `:ets.tab2list` scan — could be `:ets.select`, but that's ETS not SQL), `diagnostics.ex` (pure Logger/Process.info), `runtime_opts.ex` (pure builder; only `Application.ensure_all_started(:evo_git)`), `task_executor.ex` (no Store calls; reaches Store only transitively via ResumeContext).

**Full inventory of `EvoGit.Store.` (SQLite) callers in `apps/evo_git/lib`:** only `task_registry.ex` (main GenServer — ~28 call sites: 253, 275, 289, 331, 361, 377, 384, 390, 396, 398, 411, 434, 454, 465, 475, 489, 566, 586, 590, 638, 660, 713, 879, 882, 904, 932, 184, 195), `task_registry/cleanup.ex` (37, 58, 97), and `lib/mix/tasks/recover_quarantine.ex:32`. **No other module** in evo_git or evo_dash calls the SQLite Store directly — `agent_scheduler/*` `Store.` references are `EvoGit.AgentScheduler.Store` (the ETS store, a DIFFERENT module).

**Related Elixir-side sorting outside this node** (task_registry.ex, for completeness): `trim_recent_projects` (task_registry.ex:649-663) + `sort_projects_by_recency` (:668-675) fully decode all projects (`safe_select_all_projects`, :590) and sort in Elixir — SQL `ORDER BY last_opened_at DESC` + `LIMIT` would apply, with the same ISO-8601 ordering caveat.
