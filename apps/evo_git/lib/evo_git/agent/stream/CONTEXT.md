# EvoGit Agent Streaming

## Intent
Push-only delta streaming for a live agent, plus bounded one-shot inspection: no replay buffer, no cursor, no polling loop.
`EvoGit.PubSub` topic `"agent:<agent_id>"` (`EvoGit.Agent.Stream.topic/1`) carries `{:agent_delta, agent_id, seq, events}`, and `events` is ALWAYS a list.
The gate lives in the session: `EvoGit.Agent.Session.watching?/2` is `EvoGit.Agent.Stream.Watchers.watching?(watchers)` (`map_size(watchers) > 0`), consulted by `EvoGit.Agent.Stream.Sink.stream_opts/0` at EACH LLM attempt start — so a watcher attaching mid-attempt gets no `process_stream/2` callbacks (no `:text`/`:thinking` chunks) until the NEXT attempt.
The same boolean is re-checked per arriving `{:delta, events}` and again in `Watchers.flush/4`, so the non-stream emitters (`Sink.emit/1`: id-bearing `{:tool_call, …}`, `{:tool_result, …}`, `{:turn, …}`, `{:yield, …}`, `{:finished, …}`) DO reach a watcher that attached earlier in the same turn.
Zero watchers ⇒ no stream callbacks (`process_stream/2` gets `[]`, byte-identical to the one-argument call) and no broadcast.
A consumer that fell behind, reconnected or lost a delta resyncs with a fresh `snapshot/1` and drops stale deltas via `stale?/2`; nothing is ever replayed.

## API Surface

| Function | Contract |
|---|---|
| `topic/1` | `"agent:<agent_id>"`. |
| `subscribe(agent_id)` | Subscribes the CALLING process at most once per agent: a CONSUMER-LOCAL `Process` memo of subscribed topics (`:evogit_stream_subscriptions`, a `MapSet`) makes a repeat subscribe a no-op, because `Phoenix.PubSub`'s registry is `keys: :duplicate` and a duplicate subscribe would deliver every batch TWICE. PubSub unavailable → `{:error, {:not_found, :pubsub_unavailable}}`, never an exit. |
| `unsubscribe(agent_id)` | `Phoenix.PubSub.unsubscribe/2` + clears the memo entry; idempotent `:ok` (also when PubSub is gone), so a later `subscribe/1` subscribes for real again. |
| `watch(agent_id_or_pid)` | Subscribes the CALLING process FIRST (through `subscribe/1`, so a re-watch is idempotent), then registers it as a watcher and returns `{:ok, %Snapshot{}, seq}`; unsubscribes again and returns the error if registration fails. The ordering is load-bearing: a delta in the gap is either covered by the snapshot (`seq <= snapshot.seq`) or newer and delivered normally. |
| `register_watcher(target, consumer_pid)` | RPC-facing: registers an ARBITRARY pid (a local pid or a remote external pid, since `Process.monitor/1` delivers the `:DOWN` locally) with NO subscription. |
| `unregister_watcher/2` | Removes a watcher; idempotent `:ok`. |
| `unwatch/1` | Unregisters the calling pid and `Phoenix.PubSub.unsubscribe/2`s it; idempotent and total (`:ok` even when the session or the watcher entry is already gone). |
| `snapshot/1` | `{:ok, %Stream.Snapshot{}, seq}` — the ONLY resync path, a bounded one-shot read, never a poll loop. |
| `stale?/2` | `seq <= snapshot_seq` ⇒ drop; a non-integer pair is stale as well (fails closed). |
| `normalize_batch/1` | `nil` → `[]`, a list → itself, a single event → `[it]`. |
| errors | Only `{:error, {:not_found, reason}}` and `{:error, {:bad_state, phase}}`; every function is TOTAL (never raises or exits); `@call_timeout` 5_000 ms. |

`{:watch, consumer_pid}` and `{:snapshot}` are served ONLY in `:running | :cancelling | :awaiting_input` (any other phase, e.g. `:starting`/`:finalizing`/`:done`, answers `{:error, {:bad_state, phase}}`), and a `{:delta, events}` arriving outside `:running`/`:cancelling` is logged and dropped.

`EvoGit.AgentScheduler.RemoteAPI.register_watcher/2`, `unregister_watcher/2` and `watch_snapshot/1` are thin passthroughs to `register_watcher/2`, `unregister_watcher/2` and `snapshot/1` — ONE implementation, no second session-call path.
`register_watcher/2` → `{:ok, %Snapshot{}, seq} | {:error, {:not_found, reason}} | {:error, {:bad_state, phase}}`, registers an EXTERNAL cross-node pid too, and answers `{:error, {:not_found, :invalid_consumer}}` for a non-pid instead of raising; `unregister_watcher/2` is idempotent `:ok` (also for a non-pid consumer) and `watch_snapshot/1` never opens the gate.
All three are LOCAL-node session calls, because the session, its watchers and its transcript live on the node that OWNS the agent; `EvoGit.RemoteNode.watch_agent/3`, `unwatch_agent/2` and `watch_snapshot/2` are the caller-side mirrors.
Payload profile: the snapshot carries the FULL transcript ⇒ 🟠 heavy (same class as `get_agent_history/1`), while `unregister_watcher/2` is 🟢 and delta batches are 🟢 PUBLISHED, never RPC-pulled.
`Snapshot.messages` is the session's RAW `%ReqLLM.Context{}.messages` verbatim (`Snapshot.from/2`): the `:system` persona message, the `<context>`+`<objective>`-WRAPPED first user message, injected user messages, assistant messages and `:tool` results — the stream layer filters and projects NOTHING, so a consumer wanting only user-authored turns uses `EvoGit.Agent.MessageMarker.user_authored?/1` and unwraps the first message's `<objective>` for display.

`%Stream.Snapshot{}` fields: `agent_id`, `phase`, `seq`, `turn`, `total_tokens`, `usage`, `messages` (the transcript), `mode`, `model_spec`, `compression_count`.
It is plain data (JSON-clean) and never carries the `%ReqLLM.Context{}`.

**`Sink`** (process-local, default-inert): pd keys `:evogit_stream_session` / `:evogit_stream_agent_id`; `install/2` + `uninstall/0` are called by `Session.Worker.run/3` (install after `Setup.install_process_context/3`, uninstall as the FIRST statement of the worker's existing `try/after`); `stream_opts/0` → `[]` when not installed OR the gate is closed, else `[on_result: …, on_thinking: …, on_tool_call: …, on_chunk: <interrupt check>]`; `emit/1` → `send(session, {:delta, events})` when installed, `:ok` no-op otherwise, never raises; `interrupt_requested?/0` (non-blocking `receive {:evogit_interrupt, _ref}` with an `after 0`, message consumed) and `clear_interrupt/0` (a total mailbox sweep that `install/2` runs, so an interrupt sent around exchange start can never pre-empt the next exchange's first stream).

**Delta wire vocabulary** (exactly): `{:text, binary}` | `{:thinking, binary}` | `{:tool_call, id, name}` | `{:tool_result, id, status}` (`status` ∈ `:ok | :error | :timeout`) | `{:turn, %{usage: %Usage{}, duration_ms: integer | nil, turn: integer, total_tokens: integer}}` | `{:yield, text}` | `{:finished, :completed | :failed}`.

**Emission sites**
- `LLMPrompting.run_llm_attempt/4` wires the real `ReqLLM.StreamResponse.process_stream/2` callbacks: `on_result` → `{:text, chunk}`, `on_thinking` → `{:thinking, chunk}`, `on_tool_call` → `{:tool_call, nil, name}` (a stream chunk carries NO tool-call id; ReqLLM reconstructs ids from the accumulated response).
- `ToolDispatch.process_llm_response/7` emits the id-bearing `{:tool_call, id, name}` list in the model's call order.
- `ToolDispatch.process_regular_tool_calls/4` emits one `{:tool_result, id, status}` per call in the same order via the total `tool_result_status/1`: a `%ToolOutput{}` is `:ok`, a text containing `"timed out"` is `:timeout` (checked BEFORE the `"Error:"` prefix arm), an `"Error:"`-prefixed text is `:error`, else `:ok`.
- `ToolDispatch` also emits the ONE `{:turn, …}` per turn (per-TURN usage, never the cumulative one; `duration_ms` is the LLM attempt duration written by `LLMPrompting` to pd `:evogit_llm_attempt_duration_ms` and deleted on read) and `{:yield, text}` before a yield outcome.
- `Exchange.run/2` emits `{:finished, :completed}` on `{:finish, …}` and `{:finished, :failed}` on `{:error, …}`; a `:yield` deliberately emits NO `{:finished, _}` (it is terminal for the exchange only).

## Watchers, Seq & Batching
The SESSION owns `state.watchers` (`%{pid() => reference()}`) and `state.event_seq`.
`{:watch, pid}` monitors the consumer and stores `watchers[pid] = ref`; a `:DOWN` removes a WATCHER ref (matched via `Watchers.watcher_ref?/3` BEFORE the worker/finalizer `:DOWN` arms).
Re-registering demonitors the old ref; `unregister_ref/3` removes an entry only when the stored ref is the one that went down, so a stale `:DOWN` can never evict a live re-registration.
`event_seq` increments by EXACTLY one per flush that actually broadcasts, and `Watchers.flush/4` is the ONLY broadcast site; a flush with zero watchers drops the accumulated events with NO seq bump.
`publish_checkpoint/2` re-stamps the session's `event_seq` and `watchers` onto the worker's state copy (`adopt_state/2`), so a checkpoint can never roll them back; `watchers` is SESSION-LOCAL transport bookkeeping, never part of a durable snapshot.
Worker `{:delta, events}` info messages accumulate in a session-owned `%Stream.Batcher{}` (`stream/batcher.ex`, pure data) and flush coalesced after `Stream.Batcher.flush_interval_ms/0` = 75 ms.
Only `{:text, …}`/`{:thinking, …}` come from stream-chunk callbacks, so they alone carry the per-attempt gate gap: content streamed during an attempt that began with zero watchers is never emitted, and the completed assistant message only becomes visible in a later snapshot/history at the turn-boundary checkpoint.
Every other event (`{:tool_call, id, name}`, `{:tool_result, …}`, `{:turn, …}`, `{:yield, …}`, `{:finished, …}`) is emitted unconditionally by `ToolDispatch`/`Exchange` whenever the sink is installed and is gated by the session ON ARRIVAL, so a watcher registered earlier in the same turn receives them even when that turn's attempt started unwatched.
A snapshot is built from the session's last checkpointed `%State{}` (`data.state`, adopted once per turn), so a mid-turn snapshot reflects the previous turn, never the in-flight one.
`{:thinking, chunk}` appears only when the provider actually streams `:thinking` chunks (reasoning content) and `chunk.text` is non-nil; `{:text, chunk}` likewise needs a non-nil `chunk.text`, and both are per-chunk deltas, never cumulative.
An immediate flush happens on `{:exchange_finished, …}`, before any transition out of `:running`/`:cancelling`, in `finalize/1`, before a force-cancel stop, and in `terminate/3` (best-effort, must never raise).
`:awaiting_input`/`:finalizing`/`:done` hold NO flush timer (idle contract: an idle session has no timers).

## Inspector Integration Limits
The delta vocabulary has no explicit LLM-attempt start/end, retry identity, slot-wait state or tool-execution start event, so `phase: :running` and the most recent text/thinking chunk do not prove what is executing now.
A streamed `{:tool_call, nil, name}` is a model declaration, not an execution start, and the later id-bearing declaration still precedes dispatch rather than establishing an individual tool task's running lifetime.
`Snapshot.from/2` copies only checkpointed messages and has no live text/thinking accumulator or current execution activity field, even though `seq` is the current transport sequence.
Consequently a mid-turn snapshot cannot reconstruct content already broadcast during that unfinished turn, and dropping batches at or below its sequence only reconciles the checkpointed transcript, not an in-flight streaming bubble.
The 75 ms batcher also holds accepted but unpublished events outside the current `event_seq`, so a future live accumulator applied on receipt cannot be returned under that sequence without first settling the pending batch or otherwise excluding its unsequenced contents.
A future reset/current-call projection must distinguish individual LLM attempts and checkpoint adoption, because existing `:text`/`:thinking` deltas have neither attempt identity nor a reset event, and a retry can otherwise concatenate failed partial text with the next attempt.
Complete mid-attempt attachment is impossible under the existing no-watchers callback gate because the unwatched prefix was never captured, so full live resync requires changing capture independently of the publication gate or explicitly advertising incomplete content.
## Constraints
Gap repair is always a fresh `snapshot/1` + `stale?/2`, never a replay.
`:interrupt` requires an installed stream callback to pre-empt the in-flight turn: with zero watchers there are no callbacks, so it degrades to next-turn-boundary semantics — the message is still delivered exactly once through the pending-message transport and is never lost.
The streaming gate is the session's own watcher count, which no `Registry` or `Phoenix.PubSub` can answer.
The watcher set is session DATA monitored per consumer, never ETS, never a bookkeeping process.
Broadcasts are total: an unavailable or restarted `EvoGit.PubSub` degrades to a dropped batch that a fresh snapshot repairs, never a crashed session.
Subscribing is IDEMPOTENT per consumer: `Stream.subscribe/1` is the ONE subscription primitive (`watch/1` and `EvoGit.RemoteNode.watch_agent/2` both route through it) and its memo is CONSUMER-LOCAL `Process` state, so a consumer must subscribe and `unsubscribe/1` from the same process.
`EvoGit.RemoteNode.watch_agent/2` subscribes the CALLER on its own node BEFORE registering on the owning node, because an `:erpc.call/5` target runs in a throwaway worker that is not the caller.
