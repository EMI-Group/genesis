# EvoDash.TaskRegistry — Support Modules

## Intent

Support modules extracted from `EvoDash.TaskRegistry` (the main GenServer module) to keep each file focused and manageable. All public functions are called from the main module via aliases.

## Module Layout

| Module | File | Purpose |
|--------|------|---------|
| `EvoDash.TaskRegistry.Diagnostics` | `diagnostics.ex` | Failed-transition diagnostic logging — pure Logger/Process.info functions |
| `EvoDash.TaskRegistry.Lease` | `lease.ex` | SchedMeta ETS lookups and lease validity helpers — pure/ETS functions |
| `EvoDash.TaskRegistry.RuntimeOpts` | `runtime_opts.ex` | Builds `runtime_opts` keyword lists for genesis/evolve tasks |
| `EvoDash.TaskRegistry.TaskExecutor` | `task_executor.ex` | Task execution functions that run in spawned processes under `Task.Supervisor` |
| `EvoDash.TaskRegistry.ResumeContext` | `resume_context.ex` | Resume context builder for evolve tasks continuing from a previous task |
| `EvoDash.TaskRegistry.Cleanup` | `cleanup.ex` | Task history expiry — age/count-based cleanup of finished tasks. Has two arities: `cleanup_expired_tasks/1` (runtime — does its own store read) and `cleanup_expired_tasks/2` (init-time — accepts a pre-loaded task list to avoid a redundant full-table scan). |

The main GenServer module (`task_registry.ex` in the parent directory) retains:
- Client API (`start_link`, `start_task`, `get_task`, `list_tasks`, `cancel_task`, etc.)
- GenServer callbacks (`init`, `terminate`, `handle_call`, `handle_cast`, `handle_info`)
- Internal helpers (`handle_update_status`, store reads, `normalize_and_cleanup_tasks` (consolidated single-pass init normalize + cleanup), `reconcile_task_status`, `resolve_recheck_task`, `trim_recent_projects`)
