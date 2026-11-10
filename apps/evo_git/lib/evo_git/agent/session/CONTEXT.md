# EvoGit Agent Session — `agent/session/`

## Intent

Holds the per-agent session process that owns `%EvoGit.Agent.State{}` for its whole life, plus the durable/per-process setup (worktree binding, process context, initial state).
`%EvoGit.Agent.State{}` is the ONE authoritative agent state; the process dictionary installed here is a DERIVED projection of it, never authoritative.
The exchange engine (`EvoGit.Agent.Exchange`) stays a pure function over the struct: the session spawns a short-lived WORKER task per exchange and never runs the turn loop inside its own process, so inspection/cancel/input stay answerable mid-run.
The session IS the one lifecycle for every agent: `EvoGit.AgentScheduler.Dispatch.do_try_dispatch/4` starts it under `EvoGit.Agent.Session.Supervisor` and `EvoGit.AgentScheduler` admits its ONE terminal `{:agent_session_result, …}`.
The session serves BOTH drivers: a `:oneshot` role ends at its first text reply, while an `:interactive` role YIELDS a text reply and parks in `:awaiting_input` until `start_input/3` resumes it on the SAME pid/worktree/context or `close/2` finalizes it.

## API Surface

| Module | Function | Role |
|---|---|---|
| `EvoGit.Agent.Session.Setup` | `bind_worktree(ctx, owner_pid \\ self())` | Durable: identity prefix (`:evogit_agent_id`, `:evogit_agent_depth`, `:evogit_started_at`, `:genesis_repo_root`, `:evogit_repo_id`), then provisions the fresh worktree via `WorktreeManager.create_worktree_for_agent/6` (raising on failure), or the repo-less branch that never touches WorktreeManager; applies the crash-retry sleep and the "starting execution in worktree" log. `owner_pid` is the pid WorktreeManager monitors. |
| `EvoGit.Agent.Session.Setup` | `ensure_tmpdir(ctx)` | Durable: returns the managed per-task scratch dir — `spec.opts[:task_tmpdir]` when binary, else `EvoGit.TaskTmpdir.ensure(meta.task_id, primary_repo_path)` with `nil` for repo-less agents. Does NOT install it. |
| `EvoGit.Agent.Session.Setup` | `install_process_context(source, task_tmpdir \\ nil, owner_pid \\ self())` | Per-process: puts the identity, role (`:foreign_repos`, `:custom_agent_id`, `:attachments`, `:quality_level`), path (`:repo_path`, `:repo_less`, `:genesis_repo_root`), owner (`:evogit_agent_pid`, `:evogit_task_id`) and per-dir delegation-counter keys, then `TaskTmpdir.put_current/1` when a tmpdir is given. Accepts the scheduler `dispatch_ctx` keyword list OR a `%State{}` (a worker starts with an empty dictionary); the FINALIZER passes the SESSION pid as owner. |
| `EvoGit.Agent.Session.Setup` | `build_initial_state(agent_module, objective, ctx)` | Builds the initial `%State{}` from `ctx` ALONE (`{:ok, state} | {:error, :path_not_exist}`): node-path existence check, the framed `<context>`/`<objective>` first user message, turn-0 tagging, hierarchical skill schemas, every struct field incl. `worktree: repo_path` and `phase: :running`. `mode` is resolved by `resolve_session_mode/3` (role `session_mode/0` → ctx `:session_mode` atom or `"interactive"`/`"oneshot"` string → `depth != 0` FORCES `:oneshot`). Performs no ETS writes and no process-dictionary writes. |
| `EvoGit.Agent.Session` | `start_link(dispatch_ctx)` / `child_spec(dispatch_ctx)` | Starts the `:gen_statem` under `EvoGit.Agent.Session.Supervisor`, registered `{:via, Registry, {EvoGit.Agent.Session.Registry, agent_id}}`; `restart: :temporary` and `id: {EvoGit.Agent.Session, agent_id}` so a crashed session is never auto-restarted behind the scheduler's back. |
| `EvoGit.Agent.Session` | `inspect(target, timeout \\ 5_000)` | TOTAL snapshot read → `{:ok, %{state: %State{}, phase: phase}} | :error`; `phase` is the gen_statem state name, so an idle interactive session reports `phase: :awaiting_input`; `:error` when the session is gone, unresponsive or the Registry is not started. |
| `EvoGit.Agent.Session` | `history(target, timeout \\ 5_000)` | TOTAL conversation read → `[%ReqLLM.Message{}]`, `[]` when gone/unresponsive. A YIELD does not clear it: an idle session still returns the full transcript. |
| `EvoGit.Agent.Session` | `cancel(target, :graceful \| :force)` | TOTAL → `:ok | {:error, :not_found}`; `:graceful` keeps a RUNNING worker alive (the engine's 3-turn save-work grace runs) but is immediately TERMINAL when idle (`:awaiting_input`), and `:force` kills the worker/finalizer with no result delivery. |
| `EvoGit.Agent.Session` | `start_input(target, message, mode \\ :queue)` | → `:ok | {:error, :not_found \| :finished \| {:bad_state, phase}}`; `:awaiting_input` RESUMES on the same pid, `:running` appends through the existing transport, everything else is refused per `Session.Input.policy/1`. |
| `EvoGit.Agent.Session` | `input(target, message)` | Compatibility wrapper: `start_input(target, message, :queue)` compressed to `:ok | {:error, :not_found \| :finished}`. |
| `EvoGit.Agent.Session` | `close(target, mode \\ :graceful)` | → `:ok | {:error, :not_found \| :finished \| {:bad_state, phase}}`; an idle session finalizes from its LAST YIELDED TEXT and replies IMMEDIATELY (the caller never waits for git/archive work). |
| `EvoGit.Agent.Session.Input` | `policy(phase)`, `resume_state(%State{})` | The pure input policy/phase table (`:resume | :queue | {:error, :finished} | {:error, {:bad_state, phase}}`) and the pure resume transformation (`exchange_turn_base: turn`, `phase: :running`, `cancel: nil`, `in_grace_period: false`, `grace_turns_remaining: 0`; every identity/routing/worktree field untouched). |
| `EvoGit.Agent.Session.Finalize` | `start(session_pid, %State{}, tmpdir, text)`, `current?(handle, pid, ref)`, `current?(handle, pid)`, `stop(handle)` | Spawns the short-lived MONITORED finalizer (`{pid, ref}`) that installs the process context with the SESSION as owner, runs `Completion.Builder.finalize/2` inside `try/rescue/catch`, and sends `{:session_finalized, pid, result}`; `stop/1` demonitors and kills it. |
| `EvoGit.Agent.Session.Outcome` | `classify(phase, mode, outcome)` | The PURE verdict table: `{:idle, state, text}` (interactive yield), `{:finalize_yield, state, text}` (cancel-grace yield), `{:finish, state, result}`, `{:error, reason}`, and `{:unexpected, outcome}` for everything else (a one-shot yield, a non-binary yield text, any outcome while idle/finalizing) — never a silent drop. |
| `EvoGit.Agent.Session.Worker` | `run(%State{}, session_pid, opts \\ [])` | The per-exchange worker body, executed inside `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, …)`: installs the process context with the SESSION as owner, runs `Exchange.run/2` in `try/after` (fallback commit then foreign-worktree sync), refreshes `current_commit` on a `{:yield, …}` and `Result.commit_sha` on a `{:finish, …}`, then sends ONE `{:exchange_finished, self(), outcome}`. |
| `EvoGit.Agent.Session.Summary` | `publish(agent_id, %State{}, extra \\ [])`, `read(agent_id)`, `select_all()` | The ONE writer/reader helper for the `:evogit_agent_summary` table: overwrites EVERY summary field (status, mode, turn, message_count, usage, total_tokens, compression_count, context_window, current_commit, last_activity_at, objective_preview — the objective truncated to at most 4 096 graphemes) on the EXISTING row through `Store.put_agent_state/2`, then applies any remaining `extra` keys; a publish whose merged row is unchanged (excluding `:last_activity_at`) is a NO-OP. Writes whatever `status` atom it is given, so `:running`, `:awaiting_input`, `:cancelling`, `:done` and `:failed` need no filter change here; it deliberately never writes `context`. |
| `EvoGit.Agent.Session.Registry` | `start_link/1`, `child_spec/1` | The named `Registry` (`keys: :unique`) for the per-agent id → pid lookup, mirroring `EvoGit.RemoteConnection.Registry`. |
| `EvoGit.Agent.Session.Supervisor` | `start_link/1`, `child_spec/1` | The named `DynamicSupervisor` (`strategy: :one_for_one`) hosting sessions. |

The session's start path composes them: `bind_worktree/2` (owner = the SESSION pid) → `ensure_tmpdir/1` → `install_process_context/3`, then reads the scheduler row, calls `build_initial_state/3` and publishes `status: :running`.
The only per-turn publication is the `:checkpoint` event → `Summary.publish/3` (summary fields only, never `context`); there is no per-turn ETS write-through.

## Phases, Events and Commands (yield/finish split)

The `:gen_statem` uses `callback_mode: :handle_event_function` and its state name IS the phase: `:starting | :running | :awaiting_input | :cancelling | :finalizing | :done` (`data.phase` is kept in sync on every transition because `inspect/2` surfaces it).
Internal data is a plain map `%{state:, worker:, finalizer:, last_yield_text:, notify_pid:, dispatch_ctx:, tmpdir:, result:, phase:, last_published_turn:}`; the worker ref is the ONLY identity that can deliver an outcome (`current_worker?/2`), and the finalizer handle the only one that can deliver a finalization.

Transition table (as implemented):

| From | Event | To |
|---|---|---|
| `:starting` | internal `:start` succeeded | `:running` (first worker started) |
| `:starting` | start failed (`:not_registered`, `:path_not_exist`, …) | `:finalizing` |
| `:running` | `{:exchange_finished, _worker, {:yield, state, text}}` (`mode == :interactive`) | `:awaiting_input` (no worker, no timer, no slot) |
| `:running` | `{:finish, …}` / `{:error, _}` / an unexpected outcome | `:finalizing` |
| `:running` | `{:cancel, :graceful}` | `:cancelling` (worker kept alive) |
| `:running` | `{:cancel, :force}` | stopped `:shutdown` (no result) |
| `:cancelling` | `{:yield, state, text}` (interactive cancel-grace) | `:finalizing` (finalizer, last yielded text) |
| `:cancelling` | `{:finish, …}` / `{:error, _}` | `:finalizing` |
| `:cancelling` | `{:cancel, :force}` | stopped `:shutdown` (no result) |
| `:awaiting_input` | `start_input/3` / `input/2` append ok | `:running` (NEW worker, same pid/context/worktree) |
| `:awaiting_input` | `close/2` or `{:cancel, :graceful}` | `:finalizing` (finalizer, `last_yield_text \|\| ""`), reply `:ok` immediately |
| `:awaiting_input` | `{:cancel, :force}` | stopped `:shutdown` (no result) |
| `:finalizing` | `{:session_finalized, pid, result}` (current finalizer) | `:done`, then `{:stop, :normal, …}` |
| `:finalizing` / `:done` | any command | `{:error, :finished}` |
| any of `:starting`/`:running`/`:cancelling`/`:awaiting_input` | `{:cancel, :force}` | stopped `:shutdown` |

`init/1` returns `[{:next_event, :internal, :start}]`; that event binds the worktree with the SESSION pid as owner, resolves the tmpdir, reads the scheduler row for the identity/model fields, builds the initial state (which resolves `mode`), publishes `status: :running` and starts the first worker.
A missing scheduler row (`Store.get_agent_state/1` → `:error`) goes to the finalizing path with `{:error, :not_registered}`; `{:error, :path_not_exist}` goes straight to finalizing with that error (the setup module already logs it).
`:running` and `:cancelling` also answer `{:checkpoint, %State{}}` (store it, publish a COALESCED summary — at most one write per turn, compared against `last_published_turn`), `{:DOWN, ref, :process, pid, reason}`, and the three commands `:inspect`, `:history`, `{:cancel, mode}`.
`:DOWN` semantics: a current FINALIZER down is logged and converted into `{:error, {:finalize_crashed, {:down, reason}}}` (never a crash); ignored once the session is finalizing; a non-`:normal`/`:shutdown` reason from the current worker is re-raised as `{:stop, reason, data}` so the scheduler's existing crash/retry path runs unchanged; a `:normal`/`:shutdown` DOWN without a prior `{:exchange_finished, …}` stops `:normal`; anything from a stale worker/finalizer is logged at `:debug` and ignored (as is the `async_nolink` `{ref, result}` reply).
`:cancelling` stays idempotent for `{:cancel, :graceful}` and a late `{:input, _}` is rejected with `{:error, :finished}` because a cancelling run accepts only the engine's own grace turns.
`:finalizing` is terminal-only: `finalize/1` publishes the final summary, delivers the result message ONCE, notifies the `:notify` pid, records `:done`, then stops `:normal`.

## Interactive Idle Contract (`:awaiting_input`)

A yield is NOT a completion: `ToolDispatch.process_llm_response/7` commits pending worktree work and returns `{:yield, record_current_commit(state), text}` for `mode: :interactive`, so the engine hands back the conversation instead of finalizing it.
On the interactive yield the session stores the yielded state with `phase: :awaiting_input`, records `last_yield_text`, clears the worker, calls `Store.clear_cancel_requested/1`, publishes summary `status: :awaiting_input`, sends `{:agent_session_yield, agent_id, self(), text}` to the scheduler, and calls the role callback `state.agent_module.on_yield(state)` as a PLAIN call (it must be cheap and side-effect-light; a raising callback is a role bug, deliberately not rescued).
The idle session holds NOTHING: no worker process, no timer (no idle TTL, no poll), and therefore no LLM/tool slot — slots are acquired and released INSIDE the worker, so an idle session cannot hold one.
It keeps the transcript and the worktree: `history/2` still returns the full conversation, and the worktree is reclaimed exactly ONCE, by the `WorktreeManager` monitor on the SESSION pid, only when the session process stops (never at a yield; there is no explicit release call anywhere).

Resume is APPEND-ONLY: `start_input/3` in `:awaiting_input` applies `Input.resume_state/1` (rebase `exchange_turn_base` to the current turn, `phase: :running`, clear `cancel`/grace fields), appends the message through `Store.append_pending_user_message/2` (the engine's next turn drains it into a user message), publishes `status: :running`, sends `{:agent_session_resumed, agent_id, self()}` and starts a NEW worker on the SAME session pid. The context tree is never rebuilt and `prompt_cache_key` is never reset, so the provider prefix cache stays valid across exchanges of one session.
A failed append (`{:error, :not_found}` — the scheduler row is gone) answers `{:error, :finished}` and starts no worker.
`:interrupt` is ACCEPTED in P3 but applied at the NEXT TURN BOUNDARY: there is no chunk-level stream callback until P4, so it is not a mid-generation abort today.

## Terminal Paths: close, idle cancel, completion ONCE

Every terminal transition ends in `finalize/1`: publish the final summary, deliver the result ONCE, notify `:notify`, stop `:normal`. The completion side effects (`Completion.complete/4`: git note, archive refs, streaming `task_agent_archives` row, `%Result{}`) run EXACTLY ONCE, inside whichever finalizer the FIRST terminal path started — a `:oneshot` finish runs inside the worker (the engine's `Completion.Builder.finalize/2`), and an interactive session runs it in `Finalize.start/4` from `close/2`, an idle `:graceful` cancel, or a cancel-grace yield.
`Completion.Builder.finalize/2` REQUIRES the installed process context (it reads `:repo_path`/`:repo_less` from the pd) and RAISES on a vanished worktree; the finalizer's `try/rescue/catch` converts any raise/exit into `{:error, {:finalize_crashed, reason}}`, which becomes a delivered `{:error, …}` result — the session never crashes from a finalization failure.
A second `close/2` (or a `close/2` on a still-finalizing session) answers `{:error, :finished}` (or `{:error, :not_found}` once the pid is gone); nothing is finalized twice.
Graceful cancel while idle is immediate: nothing needs saving but the transcript (which is KEPT), so the summary moves to `:cancelling` and the finalizer runs with the last yielded text — the task registry maps that to `:cancelled` with the result preserved.

## Terminal Delivery Contract

`finalize/1` sends exactly ONE `{:agent_session_result, agent_id, self(), result}` to the dispatch context's `:scheduler` pid (`Dispatch.do_try_dispatch/4` sets it to the scheduler that started the session), falling back to `Process.whereis(EvoGit.AgentScheduler)` and skipped silently when neither exists, then notifies the dispatch context's `:notify` pid (when present and alive) with `{:agent_session_closed, agent_id, result}`, and THEN returns `{:stop, :normal, data}`.
The notify message exists so a caller can await the close race-free: the terminal result goes to the scheduler FIRST, and `{:agent_session_closed, …}` is the caller-facing completion signal that arrives before the session's monitor `:DOWN`.
Sending BEFORE stopping exploits Erlang signal ordering: both messages always arrive before the monitor `:DOWN`, so no consumer observes a death without an outcome.
The session NEVER calls `GenServer.reply` on the dispatch-caller's `from` — the scheduler owns that reply (it also injects `agent_count`/`foreign_repo_commits` and routes subagent results).
Outcome mapping comes from `Session.Outcome.classify/3`: `{:finish, state, result}` → terminal `{:ok, result}` (the worker already refreshed the sha), `{:error, reason}` → terminal `{:error, reason}` (delivered verbatim, never converted into a raise or a success), an interactive yield → `:awaiting_input`, and any unexpected shape → `{:error, {:unexpected_exchange_outcome, other}}` delivered LOUDLY (a one-shot yield, or a `{:finish, …}` arriving while idle, is a contract violation, never silently dropped).
The final summary publishes `status: :done` for `{:ok, result}`, `:failed` for `{:error, _}`, plus `current_commit` taken from the built result when it carries one.
`EvoGit.AgentScheduler.handle_info({:agent_session_result, agent_id, session_pid, result}, state)` admits that message only for an existing `SchedMeta` whose `session_pid` is `nil` (already recycled) or the sending pid, and delegates to `EvoGit.AgentScheduler.Lifecycle.handle_session_result/3`; a message from a stale session or for a missing agent is logged at `:debug` and ignored.
`{:agent_session_yield, agent_id, session_pid, text}` and `{:agent_session_resumed, agent_id, session_pid}` are EMITTED here and consumed by the scheduler side; they carry no result and must never be treated as terminal.

## Snapshot-Only Inspection (no streaming)

Inspection is snapshot-only: `inspect/2` returns the current `%State{}` + phase (so `:awaiting_input` is observable for free), `history/2` the current message list, and there is NO delta contract, NO watcher registration, NO `EvoGit.Agent.Stream`, no PubSub topic and no `seq`/resync — the `State.watchers`/`event_seq` fields are carried but unused.
Consumers that want changes re-poll or re-read; the summary table row (published at most once per turn, plus once per yield/resume close) is the only pushed artifact, and it excludes `context`.
Public API totality is enforced at the boundary: `:gen_statem.call/3,4` is wrapped in `try/catch :exit` (covering `:timeout`, `:noproc` and `:normal`) and the `Registry.lookup/2` is guarded by `Process.whereis(EvoGit.Agent.Session.Registry)`, so an unstarted registry or a dead session degrades to the documented fallback instead of leaking an exit.

## Seams

`dispatch_ctx[:exchange_opts]` is a documented, DEFAULT-INERT seam: its keyword list is forwarded to every exchange worker (`[tmpdir: tmpdir] ++ exchange_opts`), so tests can inject engine seams.
Production passes none, and `:exchange_opts` never appears in a shipped configuration.
The `checkpoint:` opt handed to `Exchange.run/2` is LIVE: the engine calls it once per turn after the state advances, and the worker forwards each call to the session as a `{:checkpoint, %State{}}` message.
`dispatch_ctx[:scheduler]` and `dispatch_ctx[:notify]` are the two delivery addresses (see Terminal Delivery Contract); `dispatch_ctx[:session_mode]` is the per-task mode override consumed once by `Setup.build_initial_state/3`.

## Constraints

- Setup modules must not call `AgentScheduler` state/log APIs except the durable ones the dispatch path already used (`WorktreeManager`, `TaskTmpdir`); `build_initial_state/3` never reads the scheduler row or the process dictionary.
- `build_initial_state/3` must not write ETS or the process dictionary; those side effects belong to the session (`install_process_context/3`) or to the worker.
- The installed process context must stay behaviour-identical: same keys, same values, same logs, same retry sleep and the same repo-less cardinal rule (git is never touched, no worktree, no `.genesis/tmp` in the source root).
- Per-process keys are a projection only — never a source of truth for the exchange engine, which reads the struct.
- `Summary.publish/3` never raises, never treats a missing row as an error (it no-ops), never builds a fresh `%AgentState{}` and never writes `context`; it guards `:ets.whereis(:evogit_agent_summary)`, skips a write when nothing but `last_activity_at` would change, and delegates persistence/broadcast to `EvoGit.AgentScheduler.Store.put_agent_state/2`.
- `Summary.select_all/0` uses `:ets.select/2` (never `:tab2list`), returning `[]` when the table is absent.
- `:awaiting_input` is a live agent status this module WRITES but does not own: `store/operations/lightweight.ex`'s `@live_statuses` and the task lease/heartbeat sets live outside this node, so anything that must treat an idle session as in-flight is their concern, not a session change.
- A consumer that needs the TRANSCRIPT (`dashboard /help` chat, `/agents` history) goes through `Session.history/1` / `RemoteAPI.get_agent_history/1`; seeding the ETS row can only produce a SUMMARY, so any test or fixture that needs real messages must start a live session (with `dispatch_ctx[:exchange_opts]` seams), never an `:evogit_agent_summary` row. A yield does NOT delete it.
- The session owns the worktree and the tmpdir; the worker owns nothing durable and installs the SESSION pid as `:evogit_agent_pid` (D7), so a worker death never orphans owner-bound state. The finalizer follows the same rule.
- An exception inside the worker is deliberately NOT caught: it becomes an abnormal `:DOWN`, which the session maps onto its existing crash path. The FINALIZER is the exception — it is monitored and its failure is converted into an error result instead of a crash.
- `EvoGit.Agent.Session.Registry` and `EvoGit.Agent.Session.Supervisor` are started by `EvoGit.Application` before `EvoGit.AgentScheduler`; every agent session is started by `Dispatch.do_try_dispatch/4`, a start failure is routed through the scheduler's existing crash/retry path, and `SchedMeta.session_pid`/`mode`/`phase` are only a best-effort mirror (`EvoGit.Agent.Session.inspect/2` is the live phase truth).
- No idle timer, ever: an interactive session stays parked until `start_input/3` or `close/2` arrives (or the owner dies with it).
- `prompt_cache_key` is PROJECTED once by `EvoGit.Agent.Session` while assembling the state context: `%AgentState{}` carries no dedicated field for it, so a row field wins when present, else the registered identity is read from `llm_generation_params[:provider_options][:prompt_cache_key]` with `:session_id` as the fallback (`Config.Schema.LLM.with_cache_identity/3` appends both at registration), and an agent whose provider has no cache identity keeps `nil`.
- That one projected value lives on the owned `%State{}` for the whole session, so every exchange of one session sends the same provider cache/routing identity and resume never rotates it.

## Routing Table

- `./setup.ex` → `EvoGit.Agent.Session.Setup` (the four functions above, incl. `resolve_session_mode/3`).
- `./input.ex` → `EvoGit.Agent.Session.Input` (the pure input policy + resume transformation).
- `./finalize.ex` → `EvoGit.Agent.Session.Finalize` (the monitored finalizer: process context, `Completion.Builder.finalize/2` containment, `{:session_finalized, …}`).
- `./outcome.ex` → `EvoGit.Agent.Session.Outcome` (the pure phase/mode/outcome verdict table).
- `./session.ex` (parent `../session.ex`) → `EvoGit.Agent.Session`, the `:gen_statem` owning the phase machine, the public API and the terminal delivery.
- `./worker.ex` → `EvoGit.Agent.Session.Worker`, the per-exchange task body.
- `./summary.ex` → `EvoGit.Agent.Session.Summary`, the one `:evogit_agent_summary` merge/read helper.
- `./registry.ex` → `EvoGit.Agent.Session.Registry`; `./supervisor.ex` → `EvoGit.Agent.Session.Supervisor`.
- `../state.ex` → `%EvoGit.Agent.State{}`, the authoritative struct these functions build and project from (`mode`, `phase`, `prompt_cache_key`, `exchange_turn_base`).
- `../exchange.ex` → the engine the worker runs (`{:yield, state, text} | {:finish, state, result} | {:error, reason}`); `../completion/builder.ex` → `Completion.Builder.finalize/2`, the ONE completion writer the finalizer calls; `../runner.ex` → the thin HELPER module (`refresh_commit_sha/1` + `@doc false` engine delegates), whose `try/after` + `refresh_commit_sha/1` shape the worker follows.
