# Agent Runtime Refactor — One Session Process, Two Drivers

**Status:** design record + phased implementation plan. Nothing in this document is implemented yet.
**Scope:** the agent runtime (`apps/evo_git/lib/evo_git/agent/`, `agent_scheduler/`, `runtime/`, `task_registry/`) and the dashboard surfaces that read it (`apps/evo_dash`).
**Companion records:** [harness-alignment.md](harness-alignment.md) (tool/loop contracts), [genesis-assistant.md](genesis-assistant.md) (the `/help` product surface), [process-management.md](process-management.md) (tool execution), [virtual-tree.md](virtual-tree.md).

---

## 1. The ask, and the answer

| Goal | Design answer |
|---|---|
| Use both a user-facing **interactive** agent and today's **one-shot** agents | ONE engine, ONE process model; a `mode` field (`:oneshot` \| `:interactive`) decides only what happens on a tool-free reply: finish, or yield to idle and wait for the next message. |
| **More control / inspection** (stream thinking + response when wanted) | `Agent.Stream.watch/1` returns a snapshot + a monotonic `seq`; the exchange emits `:text` / `:thinking` / `:tool_call` / `:tool_result` / `:turn` deltas on a per-agent topic. History is a snapshot call, not a 3 Hz full-copy poll. |
| **Efficient by default** — streaming must not cost anything when nobody watches | Chunk callbacks are installed *only when a watcher is attached* (`Registry.count/1` at call time); zero watchers ⇒ the LLM call path is byte-identical to today. Deltas are coalesced (~60–80 ms). The ETS mirror no longer carries the context, so the dominant per-turn copy disappears. |
| **Scalable** — hundreds of agents, low resources | 1 idle session ≈ 1 process + its context, holding **no** LLM/tool slots; 1 extra short-lived worker process only per *in-flight* exchange; idle TTL for repo-backed sessions. |
| **Easy customization** | The `use EvoGit.Agent` macro keeps its zero-arity, data-only callbacks (they stay callable from any process). A new role is still "one module + `system_prompt/0`". Custom agents/tools keep their existing contracts. |
| **Two copies of the context (heap + ETS)** | Deleted. `%EvoGit.Agent.State{}` lives in exactly one place: the session process. `:evogit_agent_state` becomes `:evogit_agent_summary` — a bounded *read model* (no `context`, no pending input) with exactly one writer. |
| **GenServer / GenStatem per agent?** | **Yes** — a `gen_statem` per agent session, plus a plain `Task` per exchange. Rationale is in §3; rejected alternatives are in §6. |

---

## 2. What exists today (verified facts this plan is built on)

**Process model.** `AgentScheduler.run_agent/2` is a blocking `GenServer.call` (`agent_scheduler.ex:81`). The scheduler registers the agent in two public ETS tables and then spawns exactly ONE `%Task{}` via `Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, agent_module, :run, [objective, dispatch_ctx])` (`dispatch.ex:258`). The whole loop — LLM HTTP calls, serial tool calls, subagent waits — runs inside that Task. There is no process boundary between turns, and the Task's exit *is* the lifecycle signal.

**State.** `%Agent.LoopState{}` (25 fields, `agent/loop_state.ex:45`) is heap-authoritative; `%AgentState{}` (27 fields, `agent_scheduler/agent_state.ex:47`) is the same data mirrored into ETS. The context is written 4–8× per turn (`runner.ex:260,497,528,568`, `tool_dispatch.ex:397,567,570`) and is **never read back by the loop** — `do_run/2` always rebuilds a fresh context (`runner.ex:232`). It is a sink for the dashboard (`RemoteAPI.get_agent_history/1`), nothing more. Meanwhile `pending_user_messages` and `cancel_requested` are written by *other* processes with whole-struct read-modify-write (`agent_scheduler/store.ex:193,226,274,303,471`), racing the agent's own writes — a lost-update class that only stays benign because the window is short.

**Lifecycle is pid-death-driven.** Worktree reclaim (`worktree_manager.ex:511-527`), background-job ownership (`tool_dispatch.ex:852` → `Process.monitor`), `ProcessManager` execution ownership, slot release (`lifecycle.ex:272-305`), result delivery (`lifecycle.ex:246`), and crash-retry (`lifecycle.ex:128-183`) all key on "this pid died". An agent that outlives a turn breaks four monitor protocols at once.

**Streaming.** `ReqLLM.stream_text` + `StreamResponse.process_stream/2` are already used (`llm_prompting.ex:286`), with **no callbacks**, so chunks are decoded and thrown away. `process_stream/2` supports `:on_chunk | :on_meta | :on_result | :on_thinking | :on_tool_call` (vendored `deps/req_llm/lib/req_llm/stream_response.ex:400-514`). Nothing text-shaped reaches observers; only counters do. `list_agents/0` is `:ets.tab2list/1` over full agent states (`remote_api.ex:84-91`), copying **every live agent's whole context** to render a roster.

**Customization.** `agent.ex` has no `@callback` at all — it is a macro injecting 8 zero-arity functions (`run/2`, `available_tools/0`, `agent_type/0`, `delegation_level/0`, `subagent_modules/0`, `subagent_tool_name/0`, `subagent_tool_description/0`, `system_prompt/0`), 7 of them `defoverridable`. Role modules are pure data; there is **no role-conditioned code in the loop**. Custom agents are one fixed module (`Agents.Custom`) whose definition is resolved per call from the process dictionary.

**Task model.** 7 statuses (`:pending | :running | :finalizing | :cancelling | :completed | :failed | :cancelled`), status is free `TEXT` (no migration needed for a new one), and the store's SQL whitelists are load-bearing: anything outside `@live_statuses` is classified *finished* (`store/operations/lightweight.ex:60,98`), so a wrongly-unlisted idle status would be deleted by cleanup. Every runtime phase is exactly `run_agent → notify_finalizing → merge_and_report` (`runtime/{genesis,evolution,self_reflective,skill_extraction}.ex`), and `merge_and_report` mints a fresh `genesis/agent_*` branch per invocation (`runtime/helpers.ex:50-57`) — so it must run exactly once, at final finish.

**Slots** are already per-attempt, not per-agent-lifetime (`with_llm_slot/2` = request → `try … after release`, `agent_scheduler.ex:416-427`; tool slots per call, `tool_runtime/executor.ex:189`). An idle agent holding nothing is the *native* model, not something to invent.

---

## 3. Decisions

**D1 — One supervised process per agent, in both modes.**
`EvoGit.Agent.Session`, a `gen_statem`, under a `DynamicSupervisor` (`EvoGit.Agent.SessionSupervisor`), registered by `agent_id` in a `Registry` (`keys: :unique`, the pattern already used for `EvoGit.RemoteConnection.Registry`).
One-shot agents get a session too, so there is exactly one lifecycle implementation. The public contract does not change: `AgentScheduler.run_agent/2` still blocks and still returns `{:ok, %Result{}}`; it now waits on the session instead of on a Task.

**D2 — Single owner of state.**
`%EvoGit.Agent.State{}` is the merge of `LoopState` and the authoritative half of `AgentState`. It exists only in the session process. `:evogit_agent_state` becomes `:evogit_agent_summary` — a *read model* with one writer (the session), no `context`, no `pending_user_messages`, no `cancel_requested`. Anything that needs the transcript asks the session.

**D3 — The loop is a library, not a process.**
`EvoGit.Agent.Exchange` runs one exchange (N turns until yield/finish) in a short-lived worker `Task` owned by the session. The session stays responsive for `inspect`, `input`, `cancel`, and `close` while the worker talks to the LLM. The worker checkpoints `%State{}` to the session after **each turn** — one copy per turn, replacing today's 4–8 full-struct ETS writes + diff.

**D4 — "Yield" and "finish" are different outcomes.**
A tool-free reply currently *is* completion: commit, git note, archive, `%Result{}`, process exit, ETS delete (`tool_dispatch.ex:705-751`, `completion.ex:44`). In the new model the engine returns one of:
- `{:continue, state}` — more turns;
- `{:yield, state, text}` — interactive only: commit, publish, status `:awaiting_input`, wait for the next input;
- `{:finish, state, result}` — run `Agent.Completion` exactly once and stop;
- `{:error, reason}`.
Only `:finish` ends the session; only the runtime phase runs `merge_and_report`, exactly once.

**D5 — Streaming is demand-gated.**
`Agent.Stream.watch(agent_id)` → `{:ok, snapshot, seq}` + subscription to topic `"agent:<id>"`. Deltas are batched (`{:agent_delta, id, seq, batch}`) at ~60–80 ms. The gate is `Registry.count/1` evaluated at each LLM call: zero watchers ⇒ no callbacks are installed at all. No full `%ReqLLM.Context{}` is ever broadcast. Watchers are monitored by `Registry` itself (no bookkeeping process, no leaked interest on watcher death).
Remote nodes (a dashboard on another node): **cursor pull** (`messages_since/2`) in v1, not cross-node token streaming — a remote watcher would otherwise need a proxy process on the agent's node.

**D6 — `:awaiting_input` is a task status, and `mode` is task metadata.**
Sessions stay tasks (they already own the repo path, model selection, usage, approvals, archives, branch, review status). A new non-terminal status is admitted everywhere `:running` is (checklist in §9), and `mode` (`"oneshot" | "interactive"`) is persisted so the UI can filter.

**D7 — Lifecycle invariants are re-keyed onto the session pid, not removed.**
The stable identity for worktree lease, background-job ownership, `ProcessManager` ownership and task-tmpdir is the **session** pid (it outlives exchanges). The exchange worker is an implementation detail that must never own anything durable.

**D8 — Idle sessions cost nothing but memory, and memory is bounded.**
Idle = 0 LLM slots, 0 tool slots, 0 worker process. Context size is already capped by compression. Repo-backed idle sessions keep their worktree for a configurable TTL (`[agent.session] idle_ttl_ms`, default 1 h) then suspend; repo-less sessions (Assistant) may idle indefinitely.

**D9 — The engine stays role-agnostic.**
No role name appears in the session or the exchange. New optional callbacks may be added (`session_mode/0` default `:oneshot`), but the existing 8 zero-arity callbacks keep their exact shape and their "callable from any process" property.

---

## 4. Target architecture

### 4.1 Process topology

```
TaskRegistry (wrapper Task, alive for the task's life)
  └─ Runtime.<Phase>
       ├─ AgentScheduler.start_session(spec) -> {:ok, session_pid}    (async)
       ├─ await session monitor close                                  (receive)
       └─ merge_and_report/4                                           (exactly once)

EvoGit.Agent.SessionSupervisor (DynamicSupervisor, :temporary)
  └─ EvoGit.Agent.Session (gen_statem) —— owns %Agent.State{}
       │  · registered in EvoGit.Agent.Registry (agent_id -> pid)
       │  · writes :evogit_agent_summary (read model, coalesced)
       │  · forwards/authorises input, cancel, close, inspect
       │
       └─ (per exchange) EvoGit.Agent.Exchange worker Task
            · installs the per-run process context (repo_path, repo_less, custom id…)
            · runs Turn -> LLM (streamed) -> ToolRuntime batch -> Turn …
            · emits deltas on "agent:<id>" only when watched
            · checkpoints %State{} to the session after each turn
            · commits at exchange end; runs Agent.Completion on :finish

EvoGit.Agent.Watchers (Registry, keys: :duplicate)   —— assistant_id -> watcher pids
EvoGit.AgentSummary (ETS, app-owned)                 —— the read model
```

Two processes per **active** agent (session + worker), one per **idle** agent. A `Task` and a `gen_statem` are both a few KB; the context dominates and is moved once per turn instead of 4–8 times.

### 4.2 `%EvoGit.Agent.State{}`

One struct, four groups, all owned by the session:

| Group | Fields | Notes |
|---|---|---|
| **identity** (immutable after start) | `agent_id`, `agent_module`, `task_id`, `depth`, `parent_id`, `node_path`, `context_node`, `repo_id`, `repo_root`, `repo_less`, `custom_agent_id`, `mode`, `archive` | replaces the `Process.put` block in `runner.ex:299-343`; installed into the worker's process dictionary at exchange start (it is *derived*, not authoritative there). |
| **conversation** | `context` (`%ReqLLM.Context{}`), `turn`, `total_tokens`, `usage`, `compression_count`, `llm_context_window`, `llm_model`, `llm_generation_params`, `model_spec`, `provider_profile_id`, `model_id_locked`, `prompt_cache_key` | the only copy in the system. |
| **control** (written only via commands) | `pending_inputs`, `cancel`, `phase` (`:starting \| :running \| :awaiting_input \| :cancelling \| :finalizing \| :done`), `exchange_ref`, `event_seq`, `last_checkpoint_at` | replaces the race-prone cross-process ETS writes. |
| **budget** | `max_turns`, `max_depth`, `max_retries`, `retries`, `grace_turns_remaining`, `delegation_hints`, `read_delegation_hints`, `delegation_level` | per-run terminal budgets, unchanged semantics. |

`%AgentState{}` keeps a *row shape* but only for the summary table: `agent_id, task_id, status, mode, depth, parent_id, node_path, objective_preview, model_spec, turn, message_count, usage, total_tokens, context_window, compression_count, current_commit, last_activity_at`.

### 4.3 The engine: `Agent.Exchange` (one exchange) and `Agent.Turn` (one LLM call + tools)

`Exchange.run(state, opts) -> {:continue,...} | {:yield,...} | {:finish,...} | {:error,...}` is a plain function over `%State{}`. It keeps `Runner.loop/1`'s logic verbatim (grace, drain, background notices, compression, warning cadence) but with three changes:
1. the loop's terminal case becomes the `:yield` / `:finish` split;
2. every `Process.get`/`Process.put` read of *identity* comes from `state` (the worker only installs the derived process context once per exchange);
3. tool results and turns call `opts.on_event` — which is `nil` when unwatched.

`Agent.Turn` is today's `ToolDispatch.do_turn/5` + `LLMPrompting`, unchanged in behaviour. `ToolRuntime.execute_batch/2` already takes a self-contained `%Request{}` and is reused as-is.

### 4.4 `EvoGit.Agent.Session` (gen_statem)

`handle_event_function` with these states:

| State | Enters on | Handles | Leaves on |
|---|---|---|---|
| `:starting` | `init/1` | bind worktree (skip if `repo_less`), snapshot skills, build the first user message | `{:run_exchange, …}` → `:running` |
| `:running` | worker started | `{:checkpoint, state}`, `{:event, …}`, `{:input, msg}` (queue), `{:cancel, :graceful \| :force}`, `inspect`, `{:DOWN, worker}` | checkpoint with `:yield` → `:awaiting_input`; `:finish` → `:finalizing` |
| `:awaiting_input` | a yield | `{:input, msg}` (starts a new exchange immediately), `inspect`, `{:cancel, …}`, idle-TTL timeout | `:running` or `:cancelling` |
| `:cancelling` | graceful cancel | input is rejected with a documented reason; the running exchange sees the flag at its next turn boundary and gets the 3-turn save-work grace | `:finalizing` |
| `:finalizing` | finish / cancel terminal | runs completion bookkeeping (or the worker did), replies to `meta.from`, publishes `:done` | `:done` (then `:stop, :normal`) |
| `:done` | terminal | nothing (transient) | — |

Why `gen_statem` and not `GenServer`: the lifecycle *is* a state machine, and the states have different legal commands (a `:yield` is illegal in `:oneshot`; `input` is illegal in `:finalizing`). `gen_statem` gives explicit `state_enter` hooks — the natural place for "commit + publish + set `:awaiting_input`" and for the idle timer — and turns illegal transitions into loud `{:error, {:bad_state, phase}}` instead of `if` ladders inside `handle_info`. The cost (one more OTP behaviour to know) is paid once, in one module, and the worker remains a plain `Task`.

Crash semantics: the session is supervised `:temporary`. A crash is handled by the scheduler exactly as today (`handle_agent_crash/3`): retry from scratch for `:oneshot`; for `:interactive`, mark the task failed with a clear message until P5 (§4.10) lands a durable checkpoint.

### 4.5 The two modes

| Aspect | `:oneshot` (Manager, Executor, Investigator, Architect, custom agents, all subagents) | `:interactive` (Assistant, future `genesis chat`) |
|---|---|---|
| Tool-free reply | `{:finish, …}` → completion → session stops | `{:yield, …}` → commit → `:awaiting_input` |
| Turn budget | `max_turns` terminal, as today | per-exchange burst budget; reset on yield, cumulative cap configurable |
| Context built | once from the tree + objective | once; later inputs are `append` only (no rebuild, no cache reset) |
| `prompt_cache_key` | per agent run | per **session** (stable across exchanges — the main latency/cost win) |
| Worktree | dies with the session | kept while idle, TTL/TTL-suspend |
| Subagents | as today | may spawn one-shot children; children are never interactive (v1) |
| Termination | always by finishing | explicit `close` / cancel / idle TTL / task force-kill |

Interactive mode is **root-only in v1**: the subagent barrier is an exact-count barrier (`maybe_resume_parent` waits for `map_size(results) == total_sub_specs`, `subagents.ex:484`) and a child that lives across exchanges never satisfies it. Making children interactive is a separate, later decision (and would need a "child yielded" result shape).

### 4.6 Inspection and streaming

Read paths after the refactor:

| Reader | Today | After |
|---|---|---|
| `/agents` roster | `:ets.tab2list` of full states, every ~300 ms while open | `:ets.select` over summary rows (no context) |
| agent detail counters | summary fields | same, from the summary |
| transcript | `get_agent_history/1` copies the whole context per `message_count` change | `Agent.Stream.watch/1` → snapshot once, then deltas; `messages_since(id, seq)` for cursors/remote |
| live text/thinking | nothing | `:text`, `:thinking`, `:tool_call`, `:tool_result`, `:turn` deltas, coalesced |
| live cost/timing | nothing (per-attempt duration discarded at `llm_prompting.ex:284-293`) | `:turn` delta carries usage + duration; optional `:telemetry` |

Delta contract: `{:agent_delta, agent_id, seq, batch}` where `batch` is `{:text, binary} | {:thinking, binary} | {:tool_call, id, name} | {:tool_result, id, status} | {:turn, %{usage, duration_ms}} | {:yield, text} | {:finished, status}`; `seq` is monotonic per session (carried in `State.event_seq`, checkpointed with the state). A watcher drops deltas with `seq <= snapshot.seq` — that is the whole reconciliation rule. There is deliberately **no replay ring buffer in v1**: a watcher attaching mid-message sees the message from the next batch on, and gets the complete text at the next snapshot. If a partial prefix is ever required, add a bounded per-agent ring as an additive change.

### 4.7 Input and cancellation

`send_user_message/2` and `cancel` stop being ETS flags and become commands:

- `{:input, %{text: text, attachments: attachments}, policy}` with `policy: :queue | :interrupt`.
  - `:queue` (default) — appended to `state.pending_inputs`, drained at the next turn boundary (today's semantics, but race-free and never "lost between reply and `:DOWN`": a message arriving after `:done` is answered `{:error, :finished}` rather than silently dropped).
  - `:interrupt` — the worker checks the mailbox between stream chunks (`receive … after 0`) and halts the enumerator; ReqLLM's `process_stream/2` stops on halt, so the in-flight turn ends early and the message is injected. This is the "stop generating and answer me" affordance.
- `{:cancel, :graceful}` → state `:cancelling`; the exchange reads the flag at the next turn boundary and gets the existing 3-turn save-work grace. `{:cancel, :force}` → kill the worker; terminal.
- Cancelling while `:awaiting_input` is immediate (nothing to save but the transcript, which is kept).
- Approvals keep working unchanged: `CommandApproval` already keys on task/agent ids.

### 4.8 Lifecycle re-keying (the mechanical part)

| Anchor | Today | After |
|---|---|---|
| Worktree lease | monitor on the agent Task pid (`worktree_manager.ex:511`) | monitor on the **session** pid (same code, new pid) |
| Background jobs | `Process.monitor` of `self()` inside the tool (`tool_dispatch.ex:852`) | explicit `owner_pid: session_pid` in `%ToolRuntime.Request{}` |
| `ProcessManager` executions | agent pid | `owner_pid: session_pid` |
| Task tmpdir | `Process.put` per run | derived per exchange, but reclaimed by terminal task status (unchanged) |
| Slot release | `:DOWN` of the agent Task | session per-turn release already exists; the session releases on every exchange end; `:DOWN` is the safety net |
| Completion | `try/after` in `run/3` + scheduler fallback (`dispatch.ex:313`) | worker commits at exchange end; `Agent.Completion` once on `:finish`; scheduler fallback kept |
| Force kill | `Task.shutdown(meta.task_ref, :brutal_kill)` | `GenServer.stop(session_pid, :shutdown)` + kill worker; `SchedMeta.task_ref` becomes `session_pid` |
| Result delivery | `GenServer.reply(meta.from, result)` from the `:DOWN` handler | session replies once in `:finalizing`; `run_agent/2` contract unchanged |

`SchedMeta` gains `session_pid`, `mode`, and `phase`; `ref_to_agent` is rebuilt from the session monitor. `:blocked` keeps its meaning ("parked in a slot queue") — an idle session is a *different* value, never overloaded.

### 4.9 Task status, and the policy that goes with it

New status `:awaiting_input` (non-terminal). It is admitted in the core enumerations listed in §9, and it carries policy:

- **`/server/status` must not count it as busy** — otherwise `genesis update`'s idle gate is permanently blocked by an idle chat. Idle sessions are safe to wind down: the update path asks them to close (graceful) rather than force-killing them.
- **`/tasks` hides sessions by default**, server-side (not the current client-side `visible_tasks/2` filter, which still counts them in pagination and `total_count`).
- **Sidebar**: sessions appear in their own group, not in "Other".
- **Review**: a session has no reviewable branch until it closes; `merge_and_report` runs at close only.
- **Lease**: `:awaiting_input` is lease-renewable (the wrapper is alive), but a session whose wrapper is gone reconciles to `:failed` on boot (P3; P5 may resume instead).
- **CLI**: `wait_for_terminal/1` must not block forever on it — it treats non-terminal-but-waiting as "still running" only when the caller asked for it.

### 4.10 Persistence (P5, deferred)

Nothing durable stores a transcript today (`task_agent_archives` has 23 columns and no messages). P3 keeps sessions in memory only, with an explicit, documented consequence: a BEAM restart loses open sessions (they reconcile to `:failed`). P5 adds:
- a `task_agent_transcripts` table (or a `session_state` JSON column) written at each exchange boundary by the session (the payload is already JSON-clean by construction: the archive path proves the shape),
- `suspend` (persist + stop, releasing the worktree) and `resume` (rehydrate the context, re-create/re-attach the worktree, reuse the stored `prompt_cache_key`),
- boot reconciliation for `:awaiting_input` rows.

### 4.11 Customization surface after the refactor

Unchanged, deliberately:
- one module + `use EvoGit.Agent` + optional zero-arity overrides; `system_prompt/0` is the only expectation;
- callbacks remain callable from *any* process (the scheduler reads `agent_type/0`, the parent reads `subagent_modules/0`) — they must never require session state;
- `available_tools/0` is still evaluated per turn (config gates, `agents.toml` edits, alias whitelists);
- custom agents stay one module (`Agents.Custom`) with per-call definition resolution — the fix is to move the bridge from an implicit process-dictionary read to an explicit install at exchange start (same data, one documented place);
- custom tools keep their behaviour, whitelist-only visibility and default-WRITE gating.

New, optional, and defaulted:
- `session_mode/0` → `:oneshot` (a role may opt into interactive semantics; custom agents can expose it via `agents.toml` in a later phase);
- `on_yield/1` (default: no-op) for roles that want to act when a session goes idle.

### 4.12 Efficiency budget (the numbers we will hold ourselves to)

| Cost | Today | Target |
|---|---|---|
| State copies per turn | 4–8 full-struct ETS read-modify-writes + field diff | 1 checkpoint copy (worker → session) |
| ETS bytes per agent | full context + 27 fields | summary only (~1 KB) |
| Roster render | copy every live context (`tab2list`) | `:ets.select` over summaries |
| Transcript read | full context per message-count change | snapshot once + coalesced deltas |
| LLM call when unwatched | no callbacks | no callbacks (identical) |
| Idle interactive agent | — | 1 process, 0 slots, 0 workers, 0 timers (one idle TTL timer) |
| Deltas | — | ≤ ~15 batches/s per watched agent, fan-out 1 message per watcher per batch |

---

## 5. Phases

Each phase is independently shippable and keeps `mix test` green. Sizes are relative (S < M < L).

### P0 — Control-plane split (S)
**Intent:** remove the cross-process read-modify-write races without changing the process model.
**Changes:** `agent_scheduler/store.ex` (`append_pending_user_message/2`, `drain_pending_user_messages/1`, `set_cancel_requested/2`, `clear_cancel_requested/1`, `increment_compression_count/1`) stop rewriting the whole `%AgentState{}`; they operate on a separate per-agent control row/table with atomic operations (a bag keyed `{agent_id, seq}` for messages; a counters row for flags). `put_agent_state/2` gains an invariant: the agent process is the only writer of the state row.
**Tests:** concurrent append+drain property test; cancel flag under concurrent context writes.
**Acceptance:** no lost updates under a stress test; behaviour identical.

### P1 — State unification + engine extraction (M)
**Intent:** one struct, one loop entry point, still Task-based.
**Changes:** add `agent/state.ex` (`%Agent.State{}`), add `agent/exchange.ex` (loop) and `agent/turn.ex` (thin wrapper over `ToolDispatch.do_turn/5`), delete `loop_state.ex`, make `AgentState` a projection struct, keep `Runner.run/3` as a shim (`run/3` → build state → `Exchange.run/2` → completion). No ETS change yet.
**Tests:** the loop's existing tests move onto the pure engine (no scheduler, no ETS); a golden test pins that an unwatched exchange makes the same LLM/tool calls as before.
**Acceptance:** `Runner` is a thin driver (<150 lines); the engine is testable without a process.

### P2 — Session process, one-shot mode (L)
**Intent:** delete the duplicated context and make the lifecycle explicit, with *no* new user-visible behaviour.
**Changes:** `agent/session/` (`session.ex` gen_statem, `supervisor.ex`, `registry.ex`, `summary.ex`), `EvoGit.Agent.Stream` (snapshot/seq only in this phase), scheduler wiring (`dispatch.ex`, `lifecycle.ex`, `sched_meta.ex`, `state.ex`), `:evogit_agent_summary`, `RemoteAPI`/`RemoteNode` (`get_agent_history` → session call with timeout + documented degraded reply; `list_agents` → summary select), worktree/background-job/ProcessManager owner re-keying, `Application` children.
**Tests:** state-machine transition tests; "no context in ETS" invariant; roster read does not touch sessions; history read while running; crash/retry; force-kill; cancel.
**Acceptance:** full suite green; `/agents` and `/help` unchanged; per-turn ETS writes gone; one copy of the context (grep-able invariant).
**Rollback:** `mode` stays `:oneshot`; the session is a drop-in for the Task.

### P3 — Interactive mode (L)
**Intent:** a session that yields and waits.
**Changes:** `:yield` path + `Agent.Completion` on `:finish` only; task status `:awaiting_input` + the §9 checklist; `AgentScheduler` API (`start_session/1`, `send_session_message/3`, `close_session/1`, `await_close/1`); `runtime/assistant.ex` (new phase: start → await → merge) and `self_reflective` reused as its engine; CLI/NodeContext/RemoteNode verbs; `prompt_cache_key` per session; idle TTL + config keys; `/server/status` + update wind-down policy; `/tasks` server-side filter.
**Tests:** multi-message session keeps one agent id, one cache key, one worktree, zero context-tree rebuilds; idle session holds no slots; cancel while idle; force-kill while idle; TTL suspend; `:awaiting_input` admitted by every enumeration (a table-driven test over the status lists).
**Acceptance:** `/help` runs on a single long-lived agent; opening/closing a session is clean; no reflect-task spam in `/tasks`.

### P4 — Demand-gated streaming + inspection (M)
**Intent:** live text/thinking/tool deltas that cost nothing when unwatched, and cheap reads.
**Changes:** `agent/stream/` (`watchers.ex` Registry, `delta.ex` batcher), `LLMPrompting` callback injection, `Exchange` event emission, `messages_since/2`, `RemoteAPI`/`RemoteNode` watch verbs, dashboard consumption (see P6).
**Tests:** zero broadcasts with no watcher (assert on `ReqLLM` callback installation); one watcher ⇒ coalesced rate; seq ordering and snapshot reconciliation; watcher death cleans up; N-agent broadcast budget.
**Acceptance:** measured per-turn overhead delta < ~2% on a 200-agent soak; a watched turn shows text within ~100 ms.

### P5 — Durability: suspend/resume + transcripts (M/L, optional)
**Intent:** survive a BEAM restart; bound idle memory for many sessions.
**Changes:** migration `20260815000008_*`, `Agent.Session.Persistence`, boot reconciliation, worktree re-attach, resume reuse of `prompt_cache_key`.
**Acceptance:** kill -9 a node with 3 idle sessions → restart restores them (or fails them with a clear message + preserved transcript); resume continues the conversation.

### P6 — Dashboard session UX (M, `apps/evo_dash`, parallel with P3/P4)
Ordered: session RPC passthroughs in `EvoDash.NodeContext` → session identity in the URL + list panel (`ChatHistory.current_chat_id` is a single BEAM-global pointer today) → send path switch to `send_session_message/3` with the existing `:reflect` fallback → delta rendering (reuse `Messages.to_entries/1`, `ContentText`, the thought-process component) → `:awaiting_input` badge/label in `Helpers` + sidebar/session group → composer-while-running + queue echo → "interrupt turn" → approval scoping to the session → reattach-after-navigate → chat attachments (port `AttachedFile`) → per-message reasoning retention + transcript cap.

---

## 6. Rejected alternatives

1. **Fork the Runner for interactive mode.** Duplicates compression, retries, tool gating, subagent merge — the single biggest maintenance hazard available.
2. **Keep task-per-message (today's `/help`).** Each message pays a cold prefix cache, a context-tree re-read, a fresh slot acquisition, an archive reset and a new agent id; transcript replay is truncated text. It is the reason the Assistant feels slow.
3. **One `GenServer` that runs the loop inline (no worker).** Cheaper by one process, but a running agent cannot answer `inspect`, cannot accept an interrupt, and cannot stream through its own process without blocking on the LLM call. The one extra `Task` per active agent is the price for a responsive owner.
4. **Keep the ETS context copy and just add a single-writer rule.** Still two copies of the same data, still an invitation to read the wrong one. The summary read model is strictly smaller and has no authority.
5. **`gen_statem` for the *exchange* as well.** The exchange is a sequential pipeline with no external events; a state machine there buys nothing.
6. **Per-token ETS writes / per-token PubSub to everyone.** Amplification at hundreds of agents, and it optimises the case nobody is watching.
7. **Interactive subagents in v1.** The parent barrier is an exact count; a child that never exits deadlocks the parent while holding a worktree and a tool slot.
8. **A separate "session" entity, disconnected from tasks.** Attractive naming, but it would re-implement model selection, approvals, usage/cost, archives, review status and cancellation. `mode` + `:awaiting_input` gets 90% of the benefit for a fraction of the surface.

---

## 7. Invariants to pin with tests

1. **One writer, one copy.** No ETS row (or any other process) holds the conversation; `get_agent_history` is the only full read. (Grep-able + a runtime assertion in tests.)
2. **No watcher ⇒ no callbacks.** A turn with zero watchers installs no `process_stream/2` callback.
3. **Idle holds nothing.** An `:awaiting_input` session holds no LLM slot, no tool slot, no worker task (assert on `Slots` holder sets and `Process.info(:links)`).
4. **One cache identity per session.** `prompt_cache_key`/`session_id` are identical across exchanges and differ across sessions.
5. **Completion once, merge once.** A session with 20 exchanges writes exactly one git note, one archive row, one `%Result{}`, one `genesis/agent_*` branch.
6. **Yield ≠ finish.** A yield never deletes the transcript, never tears down the worktree, never emits a terminal task status.
7. **Every status enumeration is total.** A table-driven test asserts each whitelist/list constant contains `:awaiting_input` where it contains `:running`.
8. **Signal always wins.** A message sent to a session is either queued, applied, or answered with an error — never silently dropped.
9. **Old suite unchanged.** The complete existing behavioural suite passes without weakening an assertion (the refactor is internal).

---

## 8. Open decisions

1. **Task-status vs separate entity** — recommended: keep sessions as tasks with `mode` + `:awaiting_input` (§3 D6, §4.9).
2. **Do one-shot agents also move onto the session process** — recommended yes (one lifecycle implementation). If you prefer minimum blast radius, P2 can be interactive-only, at the cost of two lifecycle implementations indefinitely.
3. **Idle policy for repo-backed sessions** — recommended: keep the worktree, TTL-suspend (default 1 h); repo-less sessions idle indefinitely.
4. **Remote-node token streaming in v1** — recommended: no (cursor pull only).
5. **Durability in scope now or later** — recommended later (P5), with "sessions do not survive a BEAM restart" documented in the meantime.
6. **`gen_statem` vs `GenServer`** — recommended `gen_statem` (§4.4); if the team prefers a smaller OTP surface, a `GenServer` with an explicit `phase` field and a guard function per command is an acceptable fallback, at the cost of less obvious illegal-transition errors.

---

## 9. Appendix — `:awaiting_input` admission checklist

Core (`apps/evo_git`):
- `store/types/atom_column.ex:89`, `store/codec.ex:234` (else a decode masks it to `:pending`), `store/schemas/task_info.ex:30-31`
- `store/operations/lightweight.ex:60` `@live_statuses` (else `clear_finished_tasks` deletes a waiting session) and `:66` `@lease_statuses`
- `task_registry/lease.ex:89,96-98,109-114` (`lease_renewable?/1`, `leaked?/3`)
- `task_registry.ex`: init reconcile `:397-424`, start guard `:465`, force-kill gate `:590`, `cancel_task` arms `:702,745,774,792`, `handle_update_status` `:1025,1029,1049,1054,1107,1132`, `:finalizing` ignore-list `:1559`, recheck terminal list `:1834`, heartbeat `:1652-1698`, sweep `:1706-1757`
- `command_approval.ex:88,318` `@denying_task_statuses`
- `cli.ex:8,198-217` (`wait_for_terminal` must not block forever)
- `SchedMeta.status` (`sched_meta.ex:39-58`) — a distinct idle value, never `:blocked`

Dashboard (`apps/evo_dash`): `server_status_controller.ex:33,73-80` (idle gate), `system_live/update_card.ex:29`, `live_hooks/node_aware.ex:124,312,317`, `layouts.ex:202,483,490`, `helpers.ex:118-171`, `task_card_components.ex:180,195-205,294,337,947-958`, `tasks_live.ex:67-88` (+ server-side session filter), `home_live.ex:63,1230-1276,1304-1347,1492`, `chat_state.ex:34,188`, `assistant_message.ex:71,86,310-318`, `notifications.ex:29`, `review_live.ex:1816-1818`.

The dashboard list should be owned by `apps/evo_dash/CONTEXT.md` once implemented; this appendix is the starting inventory.
