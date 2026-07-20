# TaskRegistry Support Modules

## Intent

Support modules extracted from `EvoGit.TaskRegistry` GenServer to keep the main module focused. These are pure-function or ETS-only modules — none maintain their own GenServer state. They were migrated from `evo_dash` (formerly `EvoDash.TaskRegistry.*`) to `evo_git` as part of the domain persistence layer migration.

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

## Routing Table

None — leaf directory (all modules at this level).
