# EvoGit Agent Streaming

## Intent
Push-only delta streaming for a live agent, plus bounded one-shot inspection: no replay buffer, cursor or polling loop.
`EvoGit.PubSub` topic `"agent:<agent_id>"` carries `{:agent_delta, agent_id, seq, events}`, where events is always a list.
Capture is independent of publication: an installed `Sink` captures the current LLM call even without watchers, while the session's monitored watcher count gates publication.
A consumer resyncs with a fresh snapshot and drops `seq <= snapshot.seq`; nothing is replayed.

## API Surface

### Stream facade and snapshots
`EvoGit.Agent.Stream.topic/1` returns `"agent:<agent_id>"`.
`subscribe/1` memoizes subscriptions in the caller's `:evogit_stream_subscriptions` MapSet to avoid duplicate Phoenix.PubSub delivery; unavailable PubSub returns `{:error, {:not_found, :pubsub_unavailable}}`.
`unsubscribe/1` clears that memo and unsubscribes idempotently, including when PubSub is gone.
`watch/1` subscribes the caller first, registers it with the session, and returns `{:ok, %Snapshot{}, seq}`, unsubscribing on registration failure.
`register_watcher/2` registers an arbitrary local or external pid without subscribing, and `unregister_watcher/2` removes it idempotently.
`unwatch/1` unregisters and unsubscribes the caller; `snapshot/1` is the only resync path.
Facade errors are `{:error, {:not_found, reason}}` or `{:error, {:bad_state, phase}}`, with a 5-second session-call budget and no escaping raises or exits.
`stale?/2` drops `seq <= snapshot_seq` and non-integer pairs; `normalize_batch/1` maps nil to [], a list to itself, and a single event to a singleton list.
Watch and snapshot commands are served in `:starting`, `:running`, `:cancelling` and `:awaiting_input`; only `:finalizing`/`:done` and a non-pid consumer refuse.
A `:starting` session is served through `EvoGit.Agent.Stream.Snapshot.starting/2`, a pre-state snapshot carrying the agent id, `phase: :starting`, empty messages, turn 0 and the session's live activity, and a watcher registered there keeps receiving events once the run starts.
RemoteAPI's `register_watcher/2`, `unregister_watcher/2` and `watch_snapshot/1` delegate to the same implementation on the owning node, while RemoteNode subscribes the consumer on its own node before RPC registration.
Invalid consumer pids are refused as `{:error, {:not_found, :invalid_consumer}}` for registration and ignored for unregistration.
`Snapshot.from(state, phase, opts \\ [])` copies checkpointed transcript and summary fields, with `opts[:activity]` defaulting to `Activity.new/0`.
`%Snapshot{}` fields are `agent_id`, `phase`, `status`, `seq`, `turn`, `total_tokens`, `usage`, `messages`, `mode`, `model_spec`, `compression_count` and `activity`.
`opts[:status]` supplies terminal status `:done | :failed`, defaulting to `nil` for existing callers.
The snapshot is plain data, carries no `%ReqLLM.Context{}`, and exposes raw message structs rather than filtering the transcript.
Consumers displaying only real user turns use `MessageMarker.user_authored?/1` and unwrap the first message's `<objective>`.
The transcript remains checkpointed once per turn, while the activity option supplies the separate live call projection.
Activity deltas carry no messages; consumers needing newly checkpointed transcript contents use a bounded one-shot snapshot resync, not periodic polling.
The session flushes pending deltas after watch registration and before taking either a watch or snapshot reply, returning live activity, live session phase and post-flush seq as a consistent cut so consumers drop already-covered deltas without double-appending.
For terminal watched-inspector handoff, the parent session sends one `{:agent_stream_closed, agent_id, snapshot, seq}` directly to each watcher before summary/result/removal.
When watched and holding a `%State{}`, it builds `Snapshot.from(state, :done, activity: data.activity, status: final_status)` and explicitly sets `snapshot.seq` to the post-flush `event_seq`.
The handoff consumes no sequence number and never publishes the full transcript through PubSub; retention and replay remain unchanged.

### Activity pure projection
`Activity.new/0` returns `%{phase: :idle, current_call: nil}`.
`Activity.apply(activity, event)` returns `{new_activity, public_events}` with no process, timer, publication or replay state.
Valid phases are `:idle`, `:llm_waiting`, `:llm`, `:llm_complete`, `:retry_wait`, `:tools`, `:compressing` and `:preparing`.
`{:start_call, id, turn, attempt}` replaces the call with `%{id: id, turn: turn, attempt: attempt, text: "", thinking: "", checkpointed: false}` and sets `:llm_waiting`.
`{:call_phase, id, phase}` changes only a matching current call, clearing it for `:retry_wait`, `:idle`, `:compressing` or `:preparing` and retaining it — `checkpointed` included — for `:llm_waiting`, `:llm`, `:llm_complete` and `:tools`.
`{:phase, phase}` changes the phase and preserves the current call except that `:idle`, `:compressing` and `:preparing` clear it.
`{:call_checkpointed, id}` flips `checkpointed` to `true` on the MATCHING current call only and emits ONE `{:activity, new_projection}` replacement event.
An already-marked call, a call already retired and a stale id are no-ops that publish nothing, so applying the marker twice is idempotent.
`:compressing` and `:preparing` are non-call phases: they describe work outside an LLM request, so they retire the call exactly like `:idle`, and a late `{:call_phase, old_id, _}` or `{:chunk, old_id, …}` after that retirement is an ordinary no-op because no current call remains.
`:reset` replaces the projection with idle and no call.
Start, valid phase and reset events emit `{:activity, new_projection}` replacement public events.
`{:chunk, id, :text | :thinking, binary}` appends only to the matching current call, PRESERVES its `checkpointed` marker, and emits the existing `{:text | :thinking, binary}` public append event, not a replacement.
Stale call identities, invalid phases, malformed chunks and unknown events are no-ops.
Start-call validation checks only that the id is binary, not that it is nonempty or that turn/attempt are nonnegative integers; matching chunks are accepted in every phase while a current call remains, including `:llm_complete` and `:tools`.
Unkeyed `{:phase, phase}` and `:reset` events have no call-id validation, so stale-worker rejection belongs to the session rather than this projection.
`current_call.checkpointed` is the ONE authoritative "this live call is already in the checkpointed transcript" signal a consumer renders against: `false` for a fresh call, `true` only after an explicit `{:call_checkpointed, id}`, never inferred from content, turn or bytes.
The session raises it when the batch-START checkpoint is adopted (see `../session/CONTEXT.md`), and every retirement path (`:reset`, a fresh call id, `:retry_wait`/`:idle`/`:compressing`/`:preparing`) clears it by retiring the call.
Retained call text and thinking cover one current attempt only, never a replay of earlier attempts.

### Sink
`Sink.install/2` installs session and agent identity in the exchange worker's process dictionary and clears stale call, turn and interrupt state; `uninstall/0` removes its keys.
The process-local keys are `:evogit_stream_session`, `:evogit_stream_agent_id`, `:evogit_stream_turn` and `:evogit_stream_call`.
`start_turn(turn)` records the turn and resets activity; `start_call(attempt)` allocates a unique string id, records it, emits start-call for the recorded turn (default 0), and returns the id.
`call_phase(id, phase)`, `phase(phase)` and `reset/0` emit internal activity events to the session as `{:activity, worker_pid, event}`.
`stream_opts/0` returns [] only without an installed sink, otherwise the four callbacks `on_result`, `on_thinking`, `on_tool_call` and `on_chunk`, irrespective of watcher count.
ReqLLM.StreamResponse.process_stream/2 passes `chunk.text` binaries to `on_result` and `on_thinking`, but the full tool-call chunk to `on_tool_call`, matching Sink's callback shapes (`deps/req_llm/lib/req_llm/stream_response.ex`, `invoke_callbacks/2`).
Text and thinking closures capture session pid, worker pid and call id at installation, so a late callback never acquires a newer attempt's identity by reading mutable process-local state.
The interrupt callback is always installed with a sink and consumes `{:evogit_interrupt, ref}` in the worker, raising `%Interrupted{}` for ReqLLM to return as an error.
`interrupt_requested?/0` is a non-blocking consuming peek, and `clear_interrupt/0` drains stale signals at exchange start.
`emit/1` deliberately preserves the compatible legacy `{:delta, events}` message without worker identity, normalizing to a non-empty list and no-oping when uninstalled.
The streamed tool-call closure captures the session but preserves the same legacy envelope and `{:tool_call, nil, name}` declaration because ReqLLM reconstructs tool ids later.
Session integration owns rejecting stale worker activity and applying the projection; the sink neither broadcasts nor batches.

### Public delta vocabulary
Events are `{:activity, projection}`, `{:text, binary}`, `{:thinking, binary}`, `{:tool_call, id, name}`, `{:tool_result, id, :ok | :error | :timeout}`, `{:turn, %{usage: %Usage{}, duration_ms: integer | nil, turn: integer, total_tokens: integer}}`, `{:yield, text}` and `{:finished, :completed | :failed}`.
ToolDispatch emits id-bearing declarations, ordered results, per-turn usage and yield events, while Exchange emits terminal finished events and no finished event for a yield.
A tool declaration is not proof of tool execution lifetime, and process execution details belong to ProcessManager.

## Watchers, Seq and Batching
The session owns `%{consumer_pid => monitor_ref}` watchers and `event_seq`; checkpoints must not roll these session-local fields backward.
Re-registering demonitors the old ref, and `Watchers.unregister_ref/3` removes an entry only when its stored ref matches, so stale DOWN messages cannot evict a new registration.
`Watchers.flush/4` is the only broadcast site and increments seq exactly once per non-empty flush with watchers, even when the best-effort broadcast fails.
A flush without watchers drops events without consuming seq; publication failure degrades to a dropped batch, not a crashed session.
`Batcher` is unchanged pure data with a 75 ms coalescing interval and session-owned timers.
Activity retirement does not always flush immediately: successful resume, yield and finalizer startup may leave public reset events pending.
Terminal delivery, current-worker down, force cancellation and termination reset activity and flush; watch and snapshot also flush, while running graceful cancel preserves activity and the pending batch.
At most one flush timer exists; a bounded pending yield/reset batch may briefly keep it in `:awaiting_input` or `:finalizing`, and `:flush_deltas` is handled in every phase.
Once the pending batch settles, no flush timer remains; there is no idle TTL or polling timer.

## Constraints
A phase must describe work that is actually running: context compression and turn preparation now publish `:compressing` and `:preparing`, and any other new pre-turn work (drains, setup) must likewise publish a named phase rather than leaving `:idle`, or a busy agent is reported as idle for its whole duration.
No replay or periodic snapshot polling may be added.
Capture must remain independent of the watcher gate so mid-attempt attachment and interruption do not depend on prior watchers.
Publication is gated by the session's watcher map, never inferred from Registry or PubSub subscriber counts.
Subscriptions and their consumer-local memo must be managed from the same consumer process.
Snapshots carry the full transcript and are heavy RPC payloads; ordinary deltas and unwatch are lightweight.

## Routing Table
This directory has no child directories.
`activity.ex` owns pure live projection, `sink.ex` owns worker-local capture, `snapshot.ex` owns snapshot shape, `watchers.ex` owns monitors/publication, `batcher.ex` owns coalescing data, and `interrupted.ex` owns the stream interrupt exception.
<!-- genesis:local -->
## Activity Timeline — every busy window has a name

`Activity.t()` carries NO timestamp — only `%{phase: …, current_call: %{id, turn, attempt, text, thinking, checkpointed} | nil}` — so a consumer cannot distinguish a fresh `:idle` from a 60-second-old one and must not invent a staleness rule.
The session's initial `data.activity` is `Activity.new/0`, and a crash-retry wait publishes `:retry_wait` from the start task through the session (accepted only from the current start task), so a consumer attached during `:starting` can observe `:retry_wait` rather than a stale `:idle`.
Per-turn publication sequence: `:idle` at `Sink.start_turn/1` → `:preparing` published in `EvoGit.Agent.ToolDispatch.do_turn/6` immediately after that reset and BEFORE the synchronous `EvoGit.Agent.Session.Worker.boundary(state, :llm)` gate → `:llm_waiting` at `Sink.start_call/1` → `:llm` INSIDE `with_llm_slot/2` and before `ReqLLM.stream_text/3` → `:llm_complete` → the batch-start checkpoint keeps it (`pending_tool_batch != nil`) and marks it `checkpointed: true` → `:tools` → `:llm_complete` → the boundary checkpoint RESETS it to `:idle`.
That reset is `keep_activity?/2` comparing `current_call.turn` with the adopted `state.turn`: `advance_turn_context/2` makes the state turn `current_call.turn + 1`, so every post-BATCH and post-FINISH checkpoint resets.
The batch-start adoption is also where the retained call is marked `checkpointed: true`, because the assistant message it describes is already in that adopted transcript.
At the TOP of the NEXT loop iteration `EvoGit.Agent.ContextCompression.compress_if_needed/2` publishes `:compressing`, but ONLY when the window-relative `Threshold.exceeded?/2` gate opens; it covers stage-1 model-free pruning and the whole stage-2 summarising call, including that call's slot wait and its retries.
That same iteration then publishes `:preparing` at the top of `EvoGit.Agent.Exchange.continue_loop/3`, which covers the pending-input drain, the background-job notices, the cancel-grace check and the pause probe.
The cycle then repeats: `:idle` (the next `start_turn` reset) → `:preparing` → `:llm_waiting`.
Slot queueing is NOT idle by construction: `start_call/1` precedes `AgentScheduler.with_llm_slot/2`, so congestion renders `:llm_waiting`, not `:idle`.
Phases that outlive the work they name: `:llm_complete` also covers the post-batch `ConflictState.refresh/1` git call and the commit reads (before the boundary checkpoint), and `:tools` also covers tool-slot and subagent queueing.
Remaining genuine `:idle` sites: `Sink.call_phase(id, :idle)` on a stream interrupt, `Session.resume/3` before the next exchange worker, and the exit/reset paths that reset before flushing.
Consumer mapping (owned outside this node): `EvoDashWeb.AgentsLive.StreamPresentation.activity/1` + `StreamPanel.activity_label/1` render `:idle` as "Idle", `:llm_waiting` as "Waiting for model capacity", `:llm` as "Generating response", `:tools` as "Executing tools", `:llm_complete` as "Response generated" and `:retry_wait` as "Waiting to retry", with no timer and no staleness heuristic; `:compressing` and `:preparing` are the two new labels owned by the dashboard, which falls back to "Activity unavailable" for anything it does not label.
