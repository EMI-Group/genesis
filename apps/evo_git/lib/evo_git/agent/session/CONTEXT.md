# EvoGit Agent Session — `agent/session/`

## Intent

Holds the per-agent session process that owns `%EvoGit.Agent.State{}` for its whole life, plus the durable/per-process setup (the retired one-shot `Runner` driver's setup lives here now).
`%EvoGit.Agent.State{}` is the ONE authoritative agent state; the process dictionary installed here is a DERIVED projection of it, never authoritative.
The exchange engine (`EvoGit.Agent.Exchange`) stays a pure function over the struct: the session spawns a short-lived WORKER task per exchange and never runs the turn loop inside its own process, so inspection/cancel/input stay answerable mid-run.
The session IS the one lifecycle for every agent: `EvoGit.AgentScheduler.Dispatch.do_try_dispatch/4` starts it under `EvoGit.Agent.Session.Supervisor` and `EvoGit.AgentScheduler` admits its ONE terminal `{:agent_session_result, …}`.
This is still the ONE-SHOT subset only (no `:awaiting_input`, no yield, no close).

## API Surface

| Module | Function | Role |
|---|---|---|
| `EvoGit.Agent.Session.Setup` | `bind_worktree(ctx, owner_pid \\ self())` | Durable: identity prefix (`:evogit_agent_id`, `:evogit_agent_depth`, `:evogit_started_at`, `:genesis_repo_root`, `:evogit_repo_id`), then provisions the fresh worktree via `WorktreeManager.create_worktree_for_agent/6` (raising on failure), or the repo-less branch that never touches WorktreeManager; applies the crash-retry sleep and the "starting execution in worktree" log. `owner_pid` is the pid WorktreeManager monitors. |
| `EvoGit.Agent.Session.Setup` | `ensure_tmpdir(ctx)` | Durable: returns the managed per-task scratch dir — `spec.opts[:task_tmpdir]` when binary, else `EvoGit.TaskTmpdir.ensure(meta.task_id, primary_repo_path)` with `nil` for repo-less agents. Does NOT install it. |
| `EvoGit.Agent.Session.Setup` | `install_process_context(source, task_tmpdir \\ nil, owner_pid \\ self())` | Per-process: puts the identity, role (`:foreign_repos`, `:custom_agent_id`, `:attachments`, `:quality_level`), path (`:repo_path`, `:repo_less`, `:genesis_repo_root`), owner (`:evogit_agent_pid`, `:evogit_task_id`) and per-dir delegation-counter keys, then `TaskTmpdir.put_current/1` when a tmpdir is given. Accepts the scheduler `dispatch_ctx` keyword list OR a `%State{}` (a worker starts with an empty dictionary). |
| `EvoGit.Agent.Session.Setup` | `build_initial_state(agent_module, objective, ctx)` | Builds the initial `%State{}` from `ctx` ALONE (`{:ok, state} | {:error, :path_not_exist}`): node-path existence check, the framed `<context>`/`<objective>` first user message, turn-0 tagging, hierarchical skill schemas, every struct field incl. `mode: :oneshot`, `worktree: repo_path` and `phase: :running`. Performs no ETS writes and no process-dictionary writes. |
| `EvoGit.Agent.Session` | `start_link(dispatch_ctx)` / `child_spec(dispatch_ctx)` | Starts the `:gen_statem` under `EvoGit.Agent.Session.Supervisor`, registered `{:via, Registry, {EvoGit.Agent.Session.Registry, agent_id}}`; `restart: :temporary` and `id: {EvoGit.Agent.Session, agent_id}` so a crashed session is never auto-restarted behind the scheduler's back. |
| `EvoGit.Agent.Session` | `inspect(target, timeout \\ 5_000)` | TOTAL snapshot read → `{:ok, %{state: %State{}, phase: phase}} | :error`; `:error` when the session is gone, unresponsive or the Registry is not started. |
| `EvoGit.Agent.Session` | `history(target, timeout \\ 5_000)` | TOTAL conversation read → `[%ReqLLM.Message{}]`, `[]` when gone/unresponsive. |
| `EvoGit.Agent.Session` | `cancel(target, :graceful \| :force)` | TOTAL → `:ok | {:error, :not_found}`; `:graceful` keeps the worker alive (the engine's 3-turn save-work grace runs), `:force` kills it with no result delivery. |
| `EvoGit.Agent.Session` | `input(target, message)` | TOTAL → `:ok | {:error, :not_found \| :finished}`; a binary or the canonical multimodal map, appended through `Store.append_pending_user_message/2` (the settled P2 transport). |
| `EvoGit.Agent.Session.Worker` | `run(%State{}, session_pid, opts \\ [])` | The per-exchange worker body, executed inside `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, …)`: installs the process context with the SESSION as owner, runs `Exchange.run/2` in `try/after` (fallback commit then foreign-worktree sync), refreshes `Result.commit_sha` through `EvoGit.Agent.Runner.refresh_commit_sha/1`, then sends ONE `{:exchange_finished, self(), outcome}`. |
| `EvoGit.Agent.Session.Summary` | `publish(agent_id, %State{}, extra \\ [])`, `read(agent_id)`, `select_all()` | The ONE writer/reader helper for the `:evogit_agent_summary` table: merges turn/message_count/usage/total_tokens/compression_count/last_activity_at/status/current_commit (plus any remaining `extra` keys) onto the EXISTING row through `Store.put_agent_state/2`; total, and it deliberately never touches `context` (a later checkpoint deletes that field). |
| `EvoGit.Agent.Session.Registry` | `start_link/1`, `child_spec/1` | The named `Registry` (`keys: :unique`) for the per-agent id → pid lookup, mirroring `EvoGit.RemoteConnection.Registry`. |
| `EvoGit.Agent.Session.Supervisor` | `start_link/1`, `child_spec/1` | The named `DynamicSupervisor` (`strategy: :one_for_one`) hosting sessions. |

The session's start path composes them: `bind_worktree/2` (owner = the SESSION pid) → `ensure_tmpdir/1` → `install_process_context/3`, then reads the scheduler row, calls `build_initial_state/3` and publishes `status: :running`.
There is no `Runner.Setup` / `Runner.InitialState` module any more, and no per-turn ETS write-through: the only per-turn publication is the `:checkpoint` event → `Summary.publish/3` (summary fields only, never `context`).

## Phases, Events and Commands (ONE-SHOT subset)

The `:gen_statem` uses `callback_mode: :handle_event_function` and its state name IS the phase: `:starting | :running | :cancelling | :finalizing | :done`.
`:awaiting_input`, `{:yield}` and `:close` deliberately DO NOT exist yet: the one-shot engine has no non-terminal pause, so there is nothing to wait for and nothing to close explicitly.
Internal data is a plain map `%{state:, worker:, dispatch_ctx:, tmpdir:, result:, phase:, last_published_turn:}`; the worker ref is the ONLY identity that can deliver an outcome.
`:starting` → `init/1` returns immediately with `[{:next_event, :internal, :start}]`; that event binds the worktree with the SESSION pid as owner, resolves the tmpdir, reads the scheduler row for the identity/model fields, builds the initial state, publishes `status: :running` and starts the first worker.
A missing scheduler row (`Store.get_agent_state/1` → `:error`) goes to the finalizing path with `{:error, :not_registered}`; `{:error, :path_not_exist}` goes straight to finalizing with that error (the setup module already logs it).
`:running` handles `{:checkpoint, %State{}}` (store it, publish a COALESCED summary — at most one write per turn, compared against `last_published_turn`), `{:exchange_finished, worker_pid, outcome}` (accepted ONLY from the current worker), `{:DOWN, ref, :process, pid, reason}`, and the four commands `:inspect`, `:history`, `{:input, message}`, `{:cancel, mode}`.
`:DOWN` semantics: ignored once the session is finalizing; a non-`:normal`/`:shutdown` reason from the current worker is re-raised as `{:stop, reason, data}` so the scheduler's existing crash/retry path runs unchanged; a `:normal`/`:shutdown` DOWN without a prior `{:exchange_finished, …}` stops `:normal`; anything from a stale worker is logged at `:debug` and ignored (as is the `async_nolink` `{ref, result}` reply).
`:cancelling` (entered by `{:cancel, :graceful}` in `:running`) answers `{:checkpoint, _}`, `{:exchange_finished, …}`, `:DOWN`, `:inspect` and `:history` exactly like `:running`; `{:cancel, :graceful}` stays idempotent, `{:cancel, :force}` behaves as everywhere else, and a late `{:input, _}` is rejected with `{:error, :finished}` because a cancelling run accepts only the engine's own grace turns — injecting new work would contradict the save-work contract.
`:finalizing` is terminal-only: `finalize/1` publishes the final summary, delivers the result message ONCE, records `:done`, then stops `:normal`.
Graceful cancel publishes `status: :cancelling` and KEEPS the worker alive; force cancel runs `Task.shutdown(worker, :brutal_kill)` and stops `:shutdown` with NO result delivery.

## Terminal Delivery Contract

`finalize/1` sends exactly ONE `{:agent_session_result, agent_id, self(), result}` to the dispatch context's `:scheduler` pid (`Dispatch.do_try_dispatch/4` sets it to the scheduler that started the session), falling back to `Process.whereis(EvoGit.AgentScheduler)` and skipped silently when neither exists, and THEN returns `{:stop, :normal, data}`.
Sending BEFORE stopping exploits Erlang signal ordering: the result message always arrives before the monitor `:DOWN`, so the scheduler never observes a death without an outcome.
The session NEVER calls `GenServer.reply` on the dispatch-caller's `from` — the scheduler owns that reply (it also injects `agent_count`/`foreign_repo_commits` and routes subagent results).
Outcome mapping: `{:finish, state, result}` → terminal `{:ok, result}` (the worker already refreshed the sha), `{:error, reason}` → terminal `{:error, reason}` (delivered verbatim, never converted into a raise or a success); an unexpected shape logs a warning and becomes `{:error, {:unexpected_exchange_outcome, other}}`.
The final summary publishes `status: :done` for `{:ok, result}`, `:failed` for `{:error, _}`, plus `current_commit` when the result is a `%EvoGit.Agent.Result{}` carrying a binary `commit_sha`.
`EvoGit.AgentScheduler.handle_info({:agent_session_result, agent_id, session_pid, result}, state)` admits that message only for an existing `SchedMeta` whose `session_pid` is `nil` (already recycled) or the sending pid, and delegates to `EvoGit.AgentScheduler.Lifecycle.handle_session_result/3`; a message from a stale session or for a missing agent is logged at `:debug` and ignored.

## Snapshot-Only Inspection (no streaming)

Inspection is snapshot-only: `inspect/2` returns the current `%State{}` + phase, `history/2` the current message list, and there is NO delta contract, NO watcher registration, NO `EvoGit.Agent.Stream`, no PubSub topic and no `seq`/resync — the `State.watchers`/`event_seq` fields are carried but unused.
Consumers that want changes re-poll or re-read; the summary table row (published at most once per turn) is the only pushed artifact, and it excludes `context`.
Public API totality is enforced at the boundary: `:gen_statem.call/3,4` is wrapped in `try/catch :exit` (covering `:timeout`, `:noproc` and `:normal`) and the `Registry.lookup/2` is guarded by `Process.whereis(EvoGit.Agent.Session.Registry)`, so an unstarted registry or a dead session degrades to the documented fallback instead of leaking an exit.

## Seams

`dispatch_ctx[:exchange_opts]` is a documented, DEFAULT-INERT seam: its keyword list is forwarded to every exchange worker (`[tmpdir: tmpdir] ++ exchange_opts`), so tests can inject engine seams.
Production passes none, and `:exchange_opts` never appears in a shipped configuration.
The `checkpoint:` opt handed to `Exchange.run/2` is LIVE: the engine calls it once per turn after the state advances, and the worker forwards each call to the session as a `{:checkpoint, %State{}}` message.

## Constraints

- Setup modules must not call `AgentScheduler` state/log APIs except the durable ones the Runner path already used (`WorktreeManager`, `TaskTmpdir`); `build_initial_state/3` never reads the scheduler row or the process dictionary.
- `build_initial_state/3` must not write ETS or the process dictionary; those side effects belong to the caller (Runner or the session) or to `install_process_context/3`.
- The Runner install must stay behaviour-identical: same keys, same values, same logs, same retry sleep and the same repo-less cardinal rule (git is never touched, no worktree, no `.genesis/tmp` in the source root).
- Per-process keys are a projection only — never a source of truth for the exchange engine, which reads the struct.
- `Summary.publish/3` never raises, never treats a missing row as an error (it no-ops), never builds a fresh `%AgentState{}` and never writes `context`; it guards `:ets.whereis(:evogit_agent_summary)` and delegates persistence/broadcast to `EvoGit.AgentScheduler.Store.put_agent_state/2`.
- `Summary.select_all/0` uses `:ets.select/2` (never `:tab2list`), returning `[]` when the table is absent.
- The session owns the worktree and the tmpdir; the worker owns nothing durable and installs the SESSION pid as `:evogit_agent_pid` (D7), so a worker death never orphans owner-bound state.
- An exception inside the worker is deliberately NOT caught: it becomes an abnormal `:DOWN`, which the session maps onto its existing crash path.
- `EvoGit.Agent.Session.Registry` and `EvoGit.Agent.Session.Supervisor` are started by `EvoGit.Application` before `EvoGit.AgentScheduler`; every agent session is started by `Dispatch.do_try_dispatch/4`, a start failure is routed through the scheduler's existing crash/retry path, and `SchedMeta.session_pid`/`mode`/`phase` are only a best-effort mirror (`EvoGit.Agent.Session.inspect/2` is the live phase truth).

## Routing Table

- `./setup.ex` → `EvoGit.Agent.Session.Setup` (the four functions above).
- `./session.ex` (parent `../session.ex`) → `EvoGit.Agent.Session`, the `:gen_statem` owning the phase machine, the public API and the terminal delivery.
- `./worker.ex` → `EvoGit.Agent.Session.Worker`, the per-exchange task body.
- `./summary.ex` → `EvoGit.Agent.Session.Summary`, the one `:evogit_agent_summary` merge/read helper.
- `./registry.ex` → `EvoGit.Agent.Session.Registry`; `./supervisor.ex` → `EvoGit.Agent.Session.Supervisor`.
- `../state.ex` → `%EvoGit.Agent.State{}`, the authoritative struct these functions build and project from.
- `../exchange.ex` → the engine the worker runs; `../runner.ex` → the surviving thin HELPER module (`refresh_commit_sha/1` + engine delegates) whose `try/after` + `refresh_commit_sha/1` shape the worker copies.
