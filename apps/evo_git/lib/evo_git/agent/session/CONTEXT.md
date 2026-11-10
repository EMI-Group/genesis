# EvoGit Agent Session — `agent/session/`

## Intent

Holds the durable/per-process setup shared by the current `EvoGit.Agent.Runner` driver and the future `EvoGit.Agent.Session` process.
`%EvoGit.Agent.State{}` is the ONE authoritative agent state; the process dictionary installed here is a DERIVED projection of it, never authoritative.
The exchange engine (`EvoGit.Agent.Exchange`) stays a pure function over the struct, so neither the setup nor the session process owns conversation logic.

## API Surface

| Module | Function | Role |
|---|---|---|
| `EvoGit.Agent.Session.Setup` | `bind_worktree(ctx, owner_pid \\ self())` | Durable: identity prefix (`:evogit_agent_id`, `:evogit_agent_depth`, `:evogit_started_at`, `:genesis_repo_root`, `:evogit_repo_id`), then provisions the fresh worktree via `WorktreeManager.create_worktree_for_agent/6` (raising on failure), or the repo-less branch that never touches WorktreeManager; applies the crash-retry sleep and the "starting execution in worktree" log. `owner_pid` is the pid WorktreeManager monitors. |
| `EvoGit.Agent.Session.Setup` | `ensure_tmpdir(ctx)` | Durable: returns the managed per-task scratch dir — `spec.opts[:task_tmpdir]` when binary, else `EvoGit.TaskTmpdir.ensure(meta.task_id, primary_repo_path)` with `nil` for repo-less agents. Does NOT install it. |
| `EvoGit.Agent.Session.Setup` | `install_process_context(source, task_tmpdir \\ nil, owner_pid \\ self())` | Per-process: puts the identity, role (`:foreign_repos`, `:custom_agent_id`, `:attachments`, `:quality_level`), path (`:repo_path`, `:repo_less`, `:genesis_repo_root`), owner (`:evogit_agent_pid`, `:evogit_task_id`) and per-dir delegation-counter keys, then `TaskTmpdir.put_current/1` when a tmpdir is given. Accepts the scheduler `dispatch_ctx` keyword list OR a `%State{}` (a worker starts with an empty dictionary). |
| `EvoGit.Agent.Session.Setup` | `build_initial_state(agent_module, objective, ctx)` | Builds the initial `%State{}` from `ctx` ALONE (`{:ok, state} | {:error, :path_not_exist}`): node-path existence check, the framed `<context>`/`<objective>` first user message, turn-0 tagging, hierarchical skill schemas, every struct field incl. `mode: :oneshot`, `worktree: repo_path` and `phase: :running`. Performs no ETS writes and no process-dictionary writes. |

`EvoGit.Agent.Runner.Setup.setup/1` and `EvoGit.Agent.Runner.InitialState.build/2` are THIN delegations.
`Runner.Setup.setup/1` = `bind_worktree/2` → `ensure_tmpdir/1` → `install_process_context/3` for `self()`.
`Runner.InitialState.build/2` gathers the inputs from the scheduler row and the process dictionary, calls `build_initial_state/3`, then keeps its Runner-only ETS writes (`AgentScheduler.update_agent_context/2`, `ContextBuilder.sync_turn_to_ets/2`).

## Constraints

- Setup modules must not call `AgentScheduler` state/log APIs except the durable ones the Runner path already used (`WorktreeManager`, `TaskTmpdir`); `build_initial_state/3` never reads the scheduler row or the process dictionary.
- `build_initial_state/3` must not write ETS or the process dictionary; those side effects belong to the caller (Runner) or to `install_process_context/3`.
- The Runner install must stay behaviour-identical: same keys, same values, same logs, same retry sleep and the same repo-less cardinal rule (git is never touched, no worktree, no `.genesis/tmp` in the source root).
- Per-process keys are a projection only — never a source of truth for the exchange engine, which reads the struct.
- `session.ex`, `session/worker.ex`, `session/summary.ex`, `session/registry.ex` and `session/supervisor.ex` land in the next step of the same phase (phase B); nothing here references them yet.

## Routing Table

- `./setup.ex` → `EvoGit.Agent.Session.Setup` (the four functions above).
- `../runner/setup.ex` + `../runner/initial_state.ex` → the thin Runner delegations that preserve today's behaviour and ETS writes.
- `../state.ex` → `%EvoGit.Agent.State{}`, the authoritative struct these functions build and project from.
