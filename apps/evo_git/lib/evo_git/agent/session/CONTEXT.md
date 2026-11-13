# EvoGit Agent Session — `agent/session/`

## Intent

Holds the per-agent session process that owns `%EvoGit.Agent.State{}` for its whole life, plus the durable/per-process setup (worktree binding, process context, initial state).
The `:starting` phase runs the durable setup in ONE monitored task (the session pid stays the worktree owner), so a slow, queued or hung worktree create can never silence the session process itself.
`%EvoGit.Agent.State{}` is the ONE authoritative agent state; the process dictionary installed here is a DERIVED projection of it, never authoritative.
The exchange engine (`EvoGit.Agent.Exchange`) stays a pure function over the struct: the session spawns a short-lived WORKER task per exchange and never runs the turn loop inside its own process, so inspection/cancel/input stay answerable mid-run.
The session IS the one lifecycle for every agent: `EvoGit.AgentScheduler.Dispatch.do_try_dispatch/4` starts it under `EvoGit.Agent.Session.Supervisor` and `EvoGit.AgentScheduler` admits its ONE terminal `{:agent_session_result, …}`.
The session serves BOTH drivers: a `:oneshot` role ends at its first text reply, while an `:interactive` role YIELDS a text reply and parks in `:awaiting_input` until `start_input/3` resumes it on the SAME pid/worktree/context or `close/2` finalizes it.
The session also OWNS the push-only streaming contract — the watcher set, the monotonic `event_seq` and the coalescing batcher — so a live consumer is PUSHED deltas and never polls.

## API Surface

| Module | Function | Role |
|---|---|---|
| `EvoGit.Agent.Session.Setup` | `install_identity(ctx)` | Durable, NO I/O: puts the identity prefix (`:evogit_agent_id`, `:evogit_agent_depth`, `:evogit_started_at`, `:genesis_repo_root`, `:evogit_repo_id`). |
| `EvoGit.Agent.Session.Setup` | `request_worktree(ctx, owner_pid)` | Durable: provisions the fresh worktree via `WorktreeManager.create_worktree_for_agent/6` (raising on `{:error, reason}`), or the repo-less branch that never touches WorktreeManager; applies the crash-retry sleep and the "starting execution in worktree" log. `owner_pid` is the pid WorktreeManager monitors. |
| `EvoGit.Agent.Session.Setup` | `bind_worktree(ctx, owner_pid \\ self())` | `install_identity/1` then `request_worktree/2` — unchanged contract for its only caller (the session's start task). |
| `EvoGit.Agent.Session.Setup` | `ensure_tmpdir(ctx)` | Durable: returns the managed per-task scratch dir — `spec.opts[:task_tmpdir]` when binary, else `EvoGit.TaskTmpdir.ensure(meta.task_id, primary_repo_path)` with `nil` for repo-less agents. Does NOT install it, and MUST run in the same process as `install_identity/1` (the start task) because `:per_repo` roots it at that process's `:genesis_repo_root`. |
| `EvoGit.Agent.Session.Setup` | `install_process_context(source, task_tmpdir \\ nil, owner_pid \\ self())` | Per-process: puts the identity, role (`:foreign_repos`, `:custom_agent_id`, `:attachments`, `:quality_level`), path (`:repo_path`, `:repo_less`, `:genesis_repo_root`), owner (`:evogit_agent_pid`, `:evogit_task_id`) and per-dir delegation-counter keys, then `TaskTmpdir.put_current/1` when a tmpdir is given. Accepts the scheduler `dispatch_ctx` keyword list OR a `%State{}` (a worker starts with an empty dictionary); the FINALIZER passes the SESSION pid as owner. |
| `EvoGit.Agent.Session.Setup` | `build_initial_state(agent_module, objective, ctx)` | Builds the initial `%State{}` from `ctx` ALONE (`{:ok, state} | {:error, :path_not_exist}`): node-path existence check, the framed `<context>`/`<objective>` first user message, turn-0 tagging, hierarchical skill schemas, every struct field incl. `worktree: repo_path` and `phase: :running`. `mode` is resolved by `resolve_session_mode/3`: a ctx `:session_mode` atom `:oneshot`/`:interactive` (or the string `"oneshot"`/`"interactive"`) OVERRIDES the role's `session_mode/0` callback (the default), any other value falls back to that callback, and `depth != 0` FORCES `:oneshot` over both. Performs no ETS writes and no process-dictionary writes. |
| `EvoGit.Agent.Session` | `start_link(dispatch_ctx)` / `child_spec(dispatch_ctx)` | Starts the `:gen_statem` under `EvoGit.Agent.Session.Supervisor`, registered `{:via, Registry, {EvoGit.Agent.Session.Registry, agent_id}}`; `restart: :temporary` and `id: {EvoGit.Agent.Session, agent_id}` so a crashed session is never auto-restarted behind the scheduler's back. |
| `EvoGit.Agent.Session` | `inspect(target, timeout \\ 5_000)` | TOTAL snapshot read → `{:ok, %{state: %State{}, phase: phase}} | :error`; `phase` is the gen_statem state name, so an idle interactive session reports `phase: :awaiting_input`; `:error` when the session is gone, unresponsive or the Registry is not started. |
| `EvoGit.Agent.Session` | `history(target, timeout \\ 5_000)` | TOTAL conversation read → `[%ReqLLM.Message{}]`, `[]` when gone/unresponsive. A YIELD does not clear it: an idle session still returns the full transcript. |
| `EvoGit.Agent.Session` | `whereis(agent_id)` | THE id → pid lookup: `{:ok, pid} | :error`, guarded by `Process.whereis(EvoGit.Agent.Session.Registry)`, so an unstarted registry degrades exactly like a missing key instead of raising. |
| `EvoGit.Agent.Session` | `identity(pid, timeout \\ 5_000)` | TOTAL → `{:ok, agent_id} | :error`: asks the SESSION which id it is registered under (a bare pid cannot supply the `"agent:<id>"` topic); `:error` for a non-pid, a dead/unresponsive session or a timeout. |
| `EvoGit.Agent.Session` | `watching?(target, timeout \\ 5_000)` | The streaming CONSUMER GATE, FAIL-CLOSED: `true` only when the session answered `true` (`map_size(state.watchers) > 0`), so a gone session, a timeout or any other reply is `false` — never a guess, and never Registry/PubSub introspection. Answered in EVERY phase. |
| `EvoGit.Agent.Session` | `cancel(target, :graceful \| :force)` | TOTAL → `:ok | {:error, :not_found}`; `:graceful` keeps a RUNNING worker alive (the engine's 3-turn save-work grace runs) but is immediately TERMINAL when idle (`:awaiting_input`), and `:force` kills the worker/finalizer/start task with no result delivery. Answered in EVERY phase, `:starting` included, so a stalled worktree create is force-cancellable. |
| `EvoGit.Agent.Session` | `start_input(target, message, mode \\ :queue)` | → `:ok | {:error, :not_found \| :finished \| {:bad_state, phase}}`; `:awaiting_input` RESUMES on the same pid for BOTH modes, `:running` appends through the existing transport (and `:interrupt` additionally halts the stream in flight), everything else is refused per `Session.Input.policy/1`. |
| `EvoGit.Agent.Session` | `input(target, message)` | Compatibility wrapper: `start_input(target, message, :queue)` compressed to `:ok | {:error, :not_found \| :finished}`. |
| `EvoGit.Agent.Session` | `close(target, mode \\ :graceful)` | → `:ok | {:error, :not_found \| :finished \| {:bad_state, phase}}`; an idle session finalizes from its LAST YIELDED TEXT and replies IMMEDIATELY (the caller never waits for git/archive work). |
| `EvoGit.Agent.Session.Input` | `policy(phase)`, `resume_state(%State{})` | The pure input policy/phase table (`:resume | :queue | {:error, :finished} | {:error, {:bad_state, phase}}`) and the pure resume transformation (`exchange_turn_base: turn`, `phase: :running`, `cancel: nil`, `in_grace_period: false`, `grace_turns_remaining: 0`; every identity/routing/worktree field untouched). |
| `EvoGit.Agent.Session.Finalize` | `start(session_pid, %State{}, tmpdir, text)`, `current?(handle, pid, ref)`, `current?(handle, pid)`, `stop(handle)` | Spawns the short-lived MONITORED finalizer (`{pid, ref}`) that installs the process context with the SESSION as owner, runs `Completion.Builder.finalize/2` inside `try/rescue/catch`, and sends `{:session_finalized, pid, result}`; `stop/1` demonitors and kills it. |
| `EvoGit.Agent.Session.Outcome` | `classify(phase, mode, outcome)` | The PURE verdict table: `{:idle, state, text}` (interactive yield), `{:finalize_yield, state, text}` (cancel-grace yield), `{:finish, state, result}`, `{:error, reason}`, and `{:unexpected, outcome}` for everything else (a one-shot yield, a non-binary yield text, any outcome while idle/finalizing) — never a silent drop. |
| `EvoGit.Agent.Session.Worker` | `run(%State{}, session_pid, opts \\ [])` | The per-exchange worker body, executed inside `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, …)`: installs the process context with the SESSION as owner, installs the process-local `Stream.Sink` (`Sink.install/2`), runs `Exchange.run/2` in `try/after` (uninstall the sink FIRST, then fallback commit, then foreign-worktree sync), refreshes `current_commit` on a `{:yield, …}` and `Result.commit_sha` on a `{:finish, …}`, then sends ONE `{:exchange_finished, self(), outcome}`. |
| `EvoGit.Agent.Session.Summary` | `publish(agent_id, %State{}, extra \\ [])`, `read(agent_id)`, `select_all()` | The ONE writer/reader helper for the `:evogit_agent_summary` table: overwrites EVERY summary field (status, mode, turn, message_count, usage, total_tokens, compression_count, context_window, current_commit, last_activity_at, objective_preview — the objective truncated to at most 4 096 graphemes) on the EXISTING row through `Store.put_agent_state/2`, then applies any remaining `extra` keys; a publish whose merged row is unchanged (excluding `:last_activity_at`) is a NO-OP. Writes whatever `status` atom it is given, so `:running`, `:awaiting_input`, `:cancelling`, `:done` and `:failed` need no filter change here; it deliberately never writes `context`. |
| `EvoGit.Agent.Session.Registry` | `start_link/1`, `child_spec/1` | The named `Registry` (`keys: :unique`) for the per-agent id → pid lookup, mirroring `EvoGit.RemoteConnection.Registry`. |
| `EvoGit.Agent.Session.Supervisor` | `start_link/1`, `child_spec/1` | The named `DynamicSupervisor` (`strategy: :one_for_one`) hosting sessions. |

**Seeded message order — exactly `[system, user]`, and this list IS what `history/2` returns**: message #1 is a `:system` message carrying `agent_module.system_prompt()` alone, and message #2 is a `:user` message; the system prompt is never prepended to, joined with, or repeated inside the user message (`ContextBuilder.build_initial_messages/4`, `context_builder.ex:401-406`).
Message #2's text is the `<context>` block joined to the `<objective>` block by `"\n\n---\n\n"` (`setup.ex:338-344`); blank sections are dropped, and the raw objective (a plain `String.t()`) becomes exactly `<objective>\n<objective>\n</objective>`, so `objective: "foo bar"` reaches the model as `<objective>\nfoo bar\n</objective>`.
Message #2 is also the session's ONE user-authored turn at start: `build_initial_state/3` calls `EvoGit.Agent.MessageMarker.mark_first_user_authored/1` AFTER turn-0 tagging, so it carries `metadata[:user_authored] => true` alongside `:turn` + `:timestamp` and `history/2` hands that marker to the caller; the `:system` message #1 never carries it (`../CONTEXT.md` § User-Authored Message Marker).
The `<context>` block is `<context>\n` + `ContextNode.build_context(node_path, repo_path)` + `\n\n` + the `Current local time: <date> <HH:MM>[ (<IANA zone>)]` line + `\n</context>` (`context_builder.ex:310-343`, `365-367`), and `ContextNode.build_context/2` renders `# Context Tree` + one `File: <path>` stage per directory holding a CONTEXT.md + the location block (`core/context_node.ex:181-204, 267`).
For a REPO-LESS session (`node_path: "./"`, `state.repo_path` = the resolved source root, `session.ex:951-954`) that means message #2 embeds the SOURCE ROOT's `./CONTEXT.md` verbatim — truncated at `[:truncation, :context_max_bytes]` (64 KB) with a `... [Content Truncated] ...` marker — and the location block still reads `Current Repository (worktree): '<source root>'` even though no worktree exists; the authority, foreign-repos, repo-notes, quality-guidance and background-jobs sections are all `""` for a repo-less agent.
The session's start path composes them INSIDE its ONE start task: `bind_worktree/2` (owner = the SESSION pid) → `ensure_tmpdir/1`; when that task replies the session reads the scheduler row, calls `build_initial_state/3` (whose worker later installs the process context) and publishes `status: :running`.
The only per-turn publication is the `:checkpoint` event → `Summary.publish/3` (summary fields only, never `context`); there is no per-turn ETS write-through, and the turn's live deltas travel on the separate push contract ("Live Streaming" below).

## Phases, Events and Commands (yield/finish split)

The `:gen_statem` uses `callback_mode: :handle_event_function` and its state name IS the lifecycle phase: `:starting | :running | :awaiting_input | :cancelling | :finalizing | :done`.
`inspect/2` exposes that live phase separately from the last checkpointed `%State{}`; `state.phase` is not re-stamped on cancellation or finalization and must not be treated as live phase truth.
Internal data is a plain map `%{state:, worker:, finalizer:, start_task:, start_timers:, last_yield_text:, notify_pid:, dispatch_ctx:, tmpdir:, result:, phase:, last_published_turn:, watchers:, event_seq:, batcher:}`, where `notify_pid` is the normalized `{pid, tag} | nil` close sink (`init/1` maps `{pid, tag}` as-is, a bare `pid` to `{pid, nil}`, anything else to `nil`); `start_task` is the `:starting` phase's ONE durable-setup `%Task{}` and `start_timers` its `{slow_warn_ref, stall_ref}` pair (cleared as soon as the task replies, so a later `:DOWN`/timer for it is stale by construction); `watchers` (`%{consumer_pid => monitor_ref}`), `event_seq` and `batcher` are SESSION-authoritative streaming state that no worker state copy may override; the worker ref is the ONLY identity that can deliver an outcome (`current_worker?/2`), the start task ref the only one that can finish `:starting` (`current_start_ref?/2`), and the finalizer handle the only one that can deliver a finalization.

Transition table (as implemented):

| From | Event | To |
|---|---|---|
| `:starting` | internal `:start` | `:starting` (ONE monitored start task + its two timers; the handler never blocks) |
| `:starting` | the start task replies `{:ok, tmpdir}` and the state builds | `:running` (first worker started) |
| `:starting` | start failed (`:not_registered`, `:path_not_exist`, …) | `:finalizing` |
| `:starting` | the create exceeded `:worktree_create_stall_timeout_ms` | `:finalizing` → `:done` with `{:error, {:worktree_create_stalled, ms}}` |
| `:starting` | start task `:DOWN`, `:normal`/`:shutdown` without a reply | `:finalizing` with `{:error, {:worktree_create_failed, {:down, reason}}}` |
| `:starting` | start task `:DOWN`, any other reason | stopped with that reason (scheduler crash/retry, unchanged) |
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

Every read/streaming command (`:inspect`, `:history`, `:identity`, `:watching?`, `{:snapshot}`, `{:watch, _}`, `{:unwatch, _}`) replies WITHOUT changing the phase, so a watch can never perturb a run.

`init/1` returns `[{:next_event, :internal, :start}]`; that event starts ONE monitored `EvoGit.TaskSupervisor` task running `Setup.bind_worktree(ctx, session_pid)` + `Setup.ensure_tmpdir(ctx)` — the session pid is the create owner (worktree reclamation is driven by the SESSION's `:DOWN`), and nothing in the task is rescued — plus two `Process.send_after` timers read at CALL time from `:worktree_create_slow_warn_ms` (default 120_000, ONE warning while the session keeps waiting) and `:worktree_create_stall_timeout_ms` (default 1_800_000, the terminal `{:error, {:worktree_create_stalled, ms}}`).
When the task replies, the session reads the scheduler row for the identity/model fields, forwards the mode (`dispatch_ctx[:session_mode]`, else an `:interactive` scheduler-row `mode`), builds the initial state (which resolves `mode`), publishes `status: :running` and starts the first worker.
`:starting` is therefore RESPONSIVE: `:identity`, `:inspect`/`:history` (no state yet → `:error`/`[]`), `close/2` (`{:error, {:bad_state, :starting}}`), a graceful cancel (same refusal) and `{:cancel, :force}` (stops `:shutdown` at once) all answer while a create is slow, queued or hung.
A missing scheduler row (`Store.get_agent_state/1` → `:error`) goes to the finalizing path with `{:error, :not_registered}`; `{:error, :path_not_exist}` goes straight to finalizing with that error (the setup module already logs it).
`:running` and `:cancelling` also answer `{:checkpoint, %State{}}` (store it, publish a COALESCED summary — at most one write per turn, compared against `last_published_turn`), `{:delta, events}`, `:flush_deltas`, `{:DOWN, ref, :process, pid, reason}`, and the commands `:inspect`, `:history`, `:identity`, `:watching?`, `{:cancel, mode}`, `{:watch, pid}`, `{:unwatch, pid}` and `{:snapshot}`; `:awaiting_input` serves the same read/streaming command set, because an idle session can still be watched and snapshotted.
Streaming commands and messages (full rules in "Live Streaming" below): `{:watch, consumer_pid}` monitors the consumer, stores `watchers[consumer_pid] = ref` and replies `{:ok, %Snapshot{}, seq}` — accepted in `:running | :cancelling | :awaiting_input` and refused with `{:error, {:bad_state, phase}}` otherwise (or for a non-pid); `{:unwatch, consumer_pid}` replies `:ok` in EVERY phase (demonitor + remove, idempotent because the `:DOWN` path usually removed it already); `{:snapshot}` replies `{:ok, %Snapshot{}, seq}` in `:running | :cancelling | :awaiting_input`, else `{:error, {:bad_state, phase}}`; `{:delta, events}` is buffered only in `:running | :cancelling` and only while a watcher exists (zero watchers ⇒ dropped on arrival, no buffer, no timer, no broadcast; any other phase ⇒ logged at `:debug` and ignored); `:flush_deltas` is the batcher's own timer and is TOTAL in every phase (an empty batch is a no-op).
`:DOWN` semantics, checked in this order: a dead WATCHER (`Watchers.watcher_ref?/3` for the ref that actually went down) removes only its watcher entry and stays in phase, so a consumer exit can never be mistaken for a dead worker, start task or finalizer; a current FINALIZER down is logged and converted into `{:error, {:finalize_crashed, {:down, reason}}}` (never a crash); a current START task down with `:normal`/`:shutdown` (it died without a reply) finalizes `{:error, {:worktree_create_failed, {:down, reason}}}`, while any other start-task reason stops the session with that reason — an exception in the start task is NEVER rescued, so the scheduler's crash/retry path runs unchanged; once the session is finalizing a `:DOWN` is ignored; a non-`:normal`/`:shutdown` reason from the current worker is re-raised as `{:stop, reason, data}` so the scheduler's existing crash/retry path runs unchanged; a `:normal`/`:shutdown` DOWN without a prior `{:exchange_finished, …}` stops `:normal`; anything from a stale worker/start task/finalizer is logged at `:debug` and ignored (as is the `async_nolink` `{ref, result}` reply).
The stall deadline calls `shutdown_start/1` (kill the start task, cancel both timers) and finalizes; a force cancel and `terminate/3` do the same, so a start task can never outlive the session.
`:cancelling` stays idempotent for `{:cancel, :graceful}` and a late `{:start_input, …}` is rejected with `{:error, :finished}` because a cancelling run accepts only the engine's own grace turns.
`:finalizing` is terminal-only: `finalize/1` publishes the final summary, delivers the result message ONCE, notifies the `:notify` pid, records `:done`, then stops `:normal`.

## Interactive Idle Contract (`:awaiting_input`)

A yield is NOT a completion: `ToolDispatch.process_llm_response/7` commits pending worktree work and returns `{:yield, record_current_commit(state), text}` for `mode: :interactive`, so the engine hands back the conversation instead of finalizing it.
On the interactive yield the session stores the yielded state with `phase: :awaiting_input`, records `last_yield_text`, clears the worker, calls `Store.clear_cancel_requested/1`, publishes summary `status: :awaiting_input`, sends `{:agent_session_yield, agent_id, self(), text}` to the scheduler, and calls the role callback `state.agent_module.on_yield(state)` as a PLAIN call (it must be cheap and side-effect-light; a raising callback is a role bug, deliberately not rescued).
The idle session holds NOTHING: no worker process, no timer (no idle TTL, no poll, no flush timer), and therefore no LLM/tool slot — slots are acquired and released INSIDE the worker, so an idle session cannot hold one.
It still serves reads and streaming: `history/2`/`inspect/2` answer, `{:watch, pid}`/`{:snapshot}` are accepted in `:awaiting_input`, and `watching?/2` reports the idle watcher count.
It keeps the transcript and the worktree: `history/2` still returns the full conversation, and the worktree is reclaimed exactly ONCE, by the `WorktreeManager` monitor on the SESSION pid, only when the session process stops (never at a yield; there is no explicit release call anywhere).

Resume is APPEND-ONLY: `start_input/3` in `:awaiting_input` applies `Input.resume_state/1` (rebase `exchange_turn_base` to the current turn, `phase: :running`, clear `cancel`/grace fields), appends the message through `Store.append_pending_user_message/2` (the engine's next turn drains it into a user message), publishes `status: :running`, sends `{:agent_session_resumed, agent_id, self()}` and starts a NEW worker on the SAME session pid. The context tree is never rebuilt and `prompt_cache_key` is never reset, so the provider prefix cache stays valid across exchanges of one session.
A failed append (`{:error, :not_found}` — the scheduler row is gone) answers `{:error, :finished}` and starts no worker.
`:interrupt` in `:awaiting_input` is not a pre-emption: there is nothing in flight, so it RESUMES the session exactly like `:queue` (the append-and-start path ignores the mode).

## Terminal Paths: close, idle cancel, completion ONCE

Every terminal transition ends in `finalize/1`: publish the final summary, deliver the result ONCE, notify `:notify`, stop `:normal`. The completion side effects (`Completion.complete/4`: git note, archive refs, streaming `task_agent_archives` row, `%Result{}`) run EXACTLY ONCE, inside whichever finalizer the FIRST terminal path started — a `:oneshot` finish runs inside the worker (the engine's `Completion.Builder.finalize/2`), and an interactive session runs it in `Finalize.start/4` from `close/2`, an idle `:graceful` cancel, or a cancel-grace yield.
`Completion.Builder.finalize/2` REQUIRES the installed process context (it reads `:repo_path`/`:repo_less` from the pd) and RAISES on a vanished worktree; the finalizer's `try/rescue/catch` converts any raise/exit into `{:error, {:finalize_crashed, reason}}`, which becomes a delivered `{:error, …}` result — the session never crashes from a finalization failure.
A second `close/2` (or a `close/2` on a still-finalizing session) answers `{:error, :finished}` (or `{:error, :not_found}` once the pid is gone); nothing is finalized twice.
Graceful cancel while idle is immediate: nothing needs saving but the transcript (which is KEPT), so the summary moves to `:cancelling` and the finalizer runs with the last yielded text — the task registry maps that to `:cancelled` with the result preserved.

## Terminal Delivery Contract

`finalize/1` sends exactly ONE `{:agent_session_result, agent_id, self(), result}` to the dispatch context's `:scheduler` pid (`Dispatch.do_try_dispatch/4` sets it to the scheduler that started the session), falling back to `Process.whereis(EvoGit.AgentScheduler)` and skipped silently when neither exists, then notifies the dispatch context's normalized `:notify` `{pid, tag}` sink (when present and alive) with `{:agent_session_closed, tag || agent_id, result}` — a bare notify pid normalizes to `{pid, nil}` so the payload is the agent id — and THEN returns `{:stop, :normal, data}`.
The notify message exists so a caller can await the close race-free: the terminal result goes to the scheduler FIRST, and `{:agent_session_closed, …}` is the caller-facing completion signal that arrives before the session's monitor `:DOWN`.
Sending BEFORE stopping exploits Erlang signal ordering: both messages always arrive before the monitor `:DOWN`, so no consumer observes a death without an outcome.
The session NEVER calls `GenServer.reply` on the dispatch-caller's `from` — the scheduler owns that reply (it also injects `agent_count`/`foreign_repo_commits` and routes subagent results).
Outcome mapping comes from `Session.Outcome.classify/3`: `{:finish, state, result}` → terminal `{:ok, result}` (the worker already refreshed the sha), `{:error, reason}` → terminal `{:error, reason}` (delivered verbatim, never converted into a raise or a success), an interactive yield → `:awaiting_input`, and any unexpected shape → `{:error, {:unexpected_exchange_outcome, other}}` delivered LOUDLY (a one-shot yield, or a `{:finish, …}` arriving while idle, is a contract violation, never silently dropped).
The final summary publishes `status: :done` for `{:ok, result}`, `:failed` for `{:error, _}`, plus `current_commit` taken from the built result when it carries one.
`EvoGit.AgentScheduler.handle_info({:agent_session_result, agent_id, session_pid, result}, state)` admits that message only for an existing `SchedMeta` whose `session_pid` is `nil` (already recycled) or the sending pid, and delegates to `EvoGit.AgentScheduler.Lifecycle.handle_session_result/3`; a message from a stale session or for a missing agent is logged at `:debug` and ignored.
`{:agent_session_yield, agent_id, session_pid, text}` and `{:agent_session_resumed, agent_id, session_pid}` are EMITTED here and consumed by the scheduler side; they carry no result and must never be treated as terminal.

## Live Streaming (watchers, `event_seq`, coalesced deltas)

The session OWNS the push-only delta contract: the watcher set (`watchers`, `%{consumer_pid => monitor_ref}`), the monotonic `event_seq` and the coalescing `EvoGit.Agent.Stream.Batcher`.
`{:watch, consumer_pid}` REGISTERS the consumer with `Process.monitor/1` (a monitor works for a local or a remote pid) and answers `{:ok, %EvoGit.Agent.Stream.Snapshot{}, seq}`, so a consumer starts from a coherent point and is then PUSHED `{:agent_delta, agent_id, seq, events}` — it never polls.
`{:snapshot}` is the ONLY resync: one bounded one-shot read answering `{:ok, %Snapshot{}, seq}`, and a delta whose `seq` is `<=` the snapshot's `seq` is dropped (`EvoGit.Agent.Stream.stale?/2`); there is no replay ring buffer and no cursor.
The snapshot's `seq` and `phase` are SESSION-authoritative, never the state's boundary copies (`snapshot_reply/2` stamps `data.event_seq` and the LIVE gen_statem phase).
Snapshot consistency caveat: `snapshot_reply/2` combines the last checkpointed transcript with the last FLUSHED delta sequence, without flushing or reconciling `data.batcher`, and `publish_checkpoint/2` adopts the transcript without advancing or draining that batch.
Consequently a snapshot can contain a completed turn whose buffered deltas will later arrive with a larger sequence (duplicate replay), or carry a flushed sequence for in-flight content absent from its checkpointed transcript (missing content when deltas at or below that sequence are discarded).
Watch registration uses that same snapshot path, so a sequence comparison alone is not a transcript coverage watermark.
The session emits no stream delta for phase/status transitions or terminal closure: yield/resume go to the scheduler plus Summary, cancellation publishes Summary, and terminal delivery uses scheduler/notify messages plus Summary rather than a guaranteed final stream snapshot.
Starting and finalizing reject watch/snapshot, so consumers need lifecycle-driven retry or reconciliation outside the delta topic; a finalizing session may still serve `history/2` until it stops.
`EvoGit.Agent.Stream.Sink.emit/1` sends `{:delta, events}` from the exchange worker; the session buffers them for `Stream.Batcher.flush_interval_ms/0` (75 ms), and `EvoGit.Agent.Stream.Watchers.flush/4` is the ONE broadcast site — exactly ONE `{:agent_delta, agent_id, seq, events}` on the `"agent:<agent_id>"` `EvoGit.PubSub` topic per flush, with `event_seq` incremented by exactly one.
`event_seq` and `watchers` live in the session's data and stay authoritative: `publish_checkpoint/2` RE-STAMPS them onto every adopted worker state copy (`adopt_state/2`), so a checkpoint can never roll streaming state back.
Flush points: a `{:exchange_finished, …}` outcome (i.e. before ANY transition out of `:running`/`:cancelling`), `finalize/1` before the terminal delivery, before a force-cancel stop, and best-effort in `terminate/3` (which never raises).
At most ONE flush timer exists at a time (`schedule_flush/1` runs on the batcher's clock and schedules none for an empty buffer), and `:awaiting_input`, `:finalizing` and `:done` hold NO flush timer at all.
ZERO WATCHERS is the zero-cost path: `{:delta, …}` is dropped on arrival (no buffer, no timer, no broadcast), `Watchers.flush/4` consumes no `seq` for an unwatched batch, and `Sink.stream_opts/0` installs no `ReqLLM.StreamResponse.process_stream/2` callback at all.
A broadcast can never take the session down: an unavailable PubSub degrades to a dropped batch that a fresh snapshot repairs.
The delta vocabulary, `Stream.watch/1`/`register_watcher/2`/`snapshot/1`/`stale?/2` and `Sink` are specified in `../stream/CONTEXT.md`.

## `:interrupt` — a real chunk-level halt

`start_input(target, message, :interrupt)` on a `:running` session APPENDS the message through the settled transport (`EvoGit.AgentScheduler.Store.append_pending_user_message/2`) FIRST and THEN sends the current exchange worker `{:evogit_interrupt, ref}`, replying `:ok` — append-first is load-bearing, because the halt can end the turn before the caller gets the reply.
The worker's per-chunk `Sink` callback consumes that message exactly once (`Sink.interrupt_requested?/0`) and raises `%EvoGit.Agent.Stream.Interrupted{}`, which `ReqLLM.StreamResponse.process_stream/2` converts into `{:error, %Interrupted{}}` and `EvoGit.Agent.LLMPrompting.run_llm_attempt/4` turns into `{:interrupted, reason}` — never a failure warning, never a pool bump, never a retry.
`EvoGit.Agent.ToolDispatch.do_turn/6` maps `{:interrupted, reason}` to an EARLY turn end: no assistant message is appended, no protocol violation is recorded and NO grace turn is consumed; the loop re-enters at its top, which drains the already-appended message for the next turn.
DEGRADATION (documented, never a silent loss): the chunk-level halt needs an installed stream callback, and `Sink.stream_opts/0` is `[]` while no watcher is registered, so with ZERO watchers `:interrupt` cannot pre-empt the in-flight turn and is applied at the NEXT turn boundary instead.
That fallback stays race-free, because the message travels exactly once through the pending-message transport — it is therefore never lost and never delivered twice.
A `{:evogit_interrupt, _ref}` that arrives after the last chunk of a turn (or while no watcher exists) stays unread in that SHORT-LIVED worker's mailbox and dies with the process; the next exchange runs in a NEW worker (and `Sink.install/2` sweeps the mailbox anyway), so one request can never abort two turns.

## Inspector Snapshot Limitations

`Stream.Snapshot` currently contains exactly `agent_id`, lifecycle `phase`, `seq`, `turn`, `total_tokens`, `usage`, `messages`, `mode`, `model_spec` and `compression_count`, with no in-flight response, active-tool list or runtime-activity phase.
`history/2` and snapshot `messages` expose the last checkpointed conversation, not the currently streaming assistant response or in-progress tool batch.
The delta handler only buffers events for broadcast and never folds text, thinking or tool events into snapshot state, so a mid-turn attachment or resnapshot cannot recover already-flushed fragments even though its `seq` includes those flushes.
Watch and snapshot calls neither flush the batcher nor reconcile its events with checkpointed history, so a pending batch can also overlap a newer checkpoint's messages.
The session's lifecycle phase does not distinguish thinking, generating, executing tools, waiting for slots or waiting for subagents, and the session emits no lifecycle delta on yield/resume/cancel/finalization itself.
An interactive close finalizes through `Session.Finalize` rather than the exchange engine, so session shutdown cannot be inferred solely from the exchange's `{:finished, status}` delta.
Adding an explicit inspector runtime-activity contract requires session-owned snapshot state distinct from lifecycle phase and restamped independently of worker checkpoints, plus ordered runtime transition events from the worker and terminal session paths.

## Snapshot-Only Reads (no polling)

`inspect/2` and `history/2` remain TOTAL one-shot reads: `inspect/2` returns the current `%State{}` + phase (so `:awaiting_input` is observable for free) and `history/2` the current message list, which is the one-answer fallback for a consumer that does not subscribe.
Everything a consumer needs to FOLLOW a live run arrives by push (`{:agent_delta, agent_id, seq, events}`, with `{:watch, …}`/`{:snapshot}` for resync), while the summary table row (published at most once per turn, plus once per yield/resume close) remains the only pushed artifact that excludes `context`.
Public API totality is enforced at the boundary: `:gen_statem.call/3,4` is wrapped in `try/catch :exit` (covering `:timeout`, `:noproc` and `:normal`) and the `Registry.lookup/2` is guarded by `Process.whereis(EvoGit.Agent.Session.Registry)`, so an unstarted registry or a dead session degrades to the documented fallback instead of leaking an exit.

## Seams

`dispatch_ctx[:exchange_opts]` is a documented, DEFAULT-INERT seam: its keyword list is forwarded to every exchange worker (`[tmpdir: tmpdir] ++ exchange_opts`), so tests can inject engine seams.
Production passes none, and `:exchange_opts` never appears in a shipped configuration.
The `checkpoint:` opt handed to `Exchange.run/2` is LIVE: the engine calls it once per turn after the state advances, and the worker forwards each call to the session as a `{:checkpoint, %State{}}` message.
`EvoGit.Agent.Stream.Sink` is installed by the WORKER (two `Process.put/2` keys in that process, uninstalled in the `after` block before the outcome is sent) and is DEFAULT-INERT: `stream_opts/0` returns `[]` while `Session.watching?/2` is `false`, so an unwatched run performs no extra LLM work and reaches the engine byte-identically.
`dispatch_ctx[:scheduler]` and `dispatch_ctx[:notify]` are the two delivery addresses (see Terminal Delivery Contract); `dispatch_ctx[:session_mode]` is forwarded by `build_state/2` into the state-construction context and consumed once by `Setup.build_initial_state/3` — the REAL dispatch context always carries the registration-resolved mode (`Dispatch.do_try_dispatch/4` puts `meta.mode` there, `:interactive` for `start_session/1`), the scheduler row's mirrored `mode` is only a fallback for a hand-built context and only when it is `:interactive` (`%AgentState{}` defaults it to `:oneshot`, which must never outrank a role `session_mode/0` callback), and an absent/`nil` value leaves the role callback in charge.

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
- An exception inside the worker or the START task is deliberately NOT caught: it becomes an abnormal `:DOWN`, which the session maps onto its existing crash path. The FINALIZER is the exception — it is monitored and its failure is converted into an error result instead of a crash.
- `:starting` performs NO I/O in the session process: the worktree request and the scratch dir run in ONE monitored `EvoGit.TaskSupervisor` task whose create owner is the SESSION pid, and both diagnostic timers (`:worktree_create_slow_warn_ms`, `:worktree_create_stall_timeout_ms`) are read and validated (`> 0` integer, else the default) at call time.
- A start task must never outlive its session: the stall deadline, `{:cancel, :force}` and `terminate/3` all run `shutdown_start/1` (kill the task, cancel both timers), and only the CURRENT start ref may finish `:starting`.
- `EvoGit.Agent.Session.Registry` and `EvoGit.Agent.Session.Supervisor` are started by `EvoGit.Application` before `EvoGit.AgentScheduler`; every agent session is started by `Dispatch.do_try_dispatch/4`, a start failure is routed through the scheduler's existing crash/retry path, and `SchedMeta.session_pid`/`mode`/`phase` are only a best-effort mirror (`EvoGit.Agent.Session.inspect/2` is the live phase truth).
- No idle timer, ever: an interactive session stays parked until `start_input/3` or `close/2` arrives (or the owner dies with it).
- `prompt_cache_key` is PROJECTED once by `EvoGit.Agent.Session` while assembling the state context: `%AgentState{}` carries no dedicated field for it, so a row field wins when present, else the registered identity is read from `llm_generation_params[:provider_options][:prompt_cache_key]` with `:session_id` as the fallback (`Config.Schema.LLM.with_cache_identity/3` appends both at registration), and an agent whose provider has no cache identity keeps `nil`.
- That one projected value lives on the owned `%State{}` for the whole session, so every exchange of one session sends the same provider cache/routing identity and resume never rotates it.
- Streaming state is SESSION-authoritative: `watchers`/`event_seq` live in the session's data and are re-stamped onto every adopted `%State{}` (`adopt_state/2`), so a worker's checkpoint copy can never roll them back and the worker never owns them.
- `Watchers.flush/4` is the ONLY delta broadcast site and `EvoGit.Agent.Stream.Batcher` is the ONLY coalescing buffer — no other module may batch, time or publish a delta, and the session reads `flush_interval_ms/0` rather than a local literal.
- A watcher `:DOWN` is handled BEFORE the worker/finalizer arms (`Watchers.watcher_ref?/3`), and `unregister_ref/3` only removes the ref that actually went down, so a consumer exit can never be mistaken for a worker/finalizer death and a stale `:DOWN` never evicts a live re-registration.
- A zero-watcher session must stay byte-identical to the pre-streaming runtime: no buffer, no timer, no broadcast, no `seq` consumed and no `process_stream/2` callback installed.
- Interrupt delivery order is load-bearing: the message is appended to the pending-message transport BEFORE the worker is signalled, so a halt can never lose the message it was asked to carry.

## Routing Table

- `./setup.ex` → `EvoGit.Agent.Session.Setup` (the four functions above, incl. `resolve_session_mode/3`).
- `./input.ex` → `EvoGit.Agent.Session.Input` (the pure input policy + resume transformation).
- `./finalize.ex` → `EvoGit.Agent.Session.Finalize` (the monitored finalizer: process context, `Completion.Builder.finalize/2` containment, `{:session_finalized, …}`).
- `./outcome.ex` → `EvoGit.Agent.Session.Outcome` (the pure phase/mode/outcome verdict table).
- `../session.ex` (parent of this node) → `EvoGit.Agent.Session`, the `:gen_statem` owning the phase machine, the watcher set/`event_seq` authority, the public API and the terminal delivery.
- `../stream.ex` + `../stream/` → `EvoGit.Agent.Stream` (consumer API: `watch/1`, `register_watcher/2`, `unwatch/1`, `unregister_watcher/2`, `snapshot/1`, `stale?/2`, `topic/1`), `Stream.Watchers` (the session watcher set + the ONE `flush/4` broadcast), `Stream.Batcher` (the ONE coalescing buffer, `flush_interval_ms/0`), `Stream.Sink` (the worker-process-local, default-inert emitter + `{:evogit_interrupt, _ref}` consumption), `Stream.Snapshot` (the plain-data point-in-time view) and `Stream.Interrupted` (the halt exception) — wire contract: `../stream/CONTEXT.md`.
- `./worker.ex` → `EvoGit.Agent.Session.Worker`, the per-exchange task body.
- `./summary.ex` → `EvoGit.Agent.Session.Summary`, the one `:evogit_agent_summary` merge/read helper.
- `./registry.ex` → `EvoGit.Agent.Session.Registry`; `./supervisor.ex` → `EvoGit.Agent.Session.Supervisor`.
- `../state.ex` → `%EvoGit.Agent.State{}`, the authoritative struct these functions build and project from (`mode`, `phase`, `prompt_cache_key`, `exchange_turn_base`), whose `watchers`/`event_seq` fields are only the session's re-stamped projection (`adopt_state/2`).
- `../exchange.ex` → the engine the worker runs (`{:yield, state, text} | {:finish, state, result} | {:error, reason}`); `../completion/builder.ex` → `Completion.Builder.finalize/2`, the ONE completion writer the finalizer calls; `../runner.ex` → the thin HELPER module (`refresh_commit_sha/1` + `@doc false` engine delegates), whose `try/after` + `refresh_commit_sha/1` shape the worker follows.

## Process-dictionary keys installed by `setup.ex` (agent-side contract)

`Session.Setup.bind_worktree/2` + `install_process_context/3` install these keys and seed the per-dir delegation counters; the table states who writes each key and who reads it.
| pd key | written | read / meaning |
|---|---|---|
| `:evogit_agent_id` | agent proc; EVERY tool task | `current_agent_id/0`, `CommandShell`, approval gate |
| `:evogit_task_id` | EVERY tool task | `CommandShell`, approval gate |
| `:evogit_agent_pid` | EVERY tool task (durable AGENT/session pid) | `BackgroundJobs.current_owner_pid/0` |
| `:evogit_agent_depth` | `session/setup.ex` | `AgentScheduler.current_depth/0` |
| `:evogit_started_at` | `session/setup.ex` | `Completion` — ISO-8601 |
| `:genesis_repo_root` | `session/setup.ex` (incl. repo-less override) | `ToolDispatch` — REAL repo root |
| `:evogit_repo_id` | `session/setup.ex` | `Tools.execute/5`, `Completion` — `"primary"` or a foreign id |
| `:foreign_repos` | `session/setup.ex` | `Tools`/`Tools.Shared` — `%ForeignRepo{}` list (write-role gate) |
| `:custom_agent_id` | `session/setup.ex` | `EvoGit.Agents.Custom` (root only) |
| `:attachments`, `:quality_level` | `session/setup.ex` | root media parts / quality level |
| `:repo_path`, `:repo_less` | `session/setup.ex` | agent worktree path / repo-less marker |
| `:evogit_task_tmpdir` | agent proc + tool task | `TaskTmpdir.current/0` |
| `:delegation_hints`, `:read_delegation_hints`, `:redundant_cd_warned` | exchange worker / tool_output_tracking | per-dir counters, once-per-run flag |
| `:conflict_files` | `ConflictState.refresh/1` (turn END) | `ConflictState.files/0`/`in_conflict?/0` — the ONE per-turn snapshot |

There are NO `:parent_id`, `:model_id` or `:depth` pd keys (they live on `%State{}` and the summary row), and the durable owner is `:evogit_agent_pid` (or `:ets.lookup(:evogit_sched_meta, agent_id)` → `%SchedMeta{session_pid: pid}`), never `$callers`.
Tool tasks inherit NO pd — the batch re-installs these keys per call (`../../tool_runtime/CONTEXT.md`).
