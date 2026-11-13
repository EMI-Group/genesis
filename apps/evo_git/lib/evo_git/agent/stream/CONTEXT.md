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
Watch and snapshot commands are served in `:running`, `:cancelling` and `:awaiting_input`, not `:starting`, `:finalizing` or `:done`.
RemoteAPI's `register_watcher/2`, `unregister_watcher/2` and `watch_snapshot/1` delegate to the same implementation on the owning node, while RemoteNode subscribes the consumer on its own node before RPC registration.
Invalid consumer pids are refused as `{:error, {:not_found, :invalid_consumer}}` for registration and ignored for unregistration.
`Snapshot.from(state, phase, opts \\ [])` copies checkpointed transcript and summary fields, with `opts[:activity]` defaulting to `Activity.new/0`.
`%Snapshot{}` fields are `agent_id`, `phase`, `seq`, `turn`, `total_tokens`, `usage`, `messages`, `mode`, `model_spec`, `compression_count` and `activity`.
The snapshot is plain data, carries no `%ReqLLM.Context{}`, and exposes raw message structs rather than filtering the transcript.
Consumers displaying only real user turns use `MessageMarker.user_authored?/1` and unwrap the first message's `<objective>`.
The transcript remains checkpointed once per turn, while the activity option supplies the separate live call projection.
Activity deltas carry no messages; consumers needing newly checkpointed transcript contents use a bounded one-shot snapshot resync, not periodic polling.
The session flushes pending deltas after watch registration and before taking either a watch or snapshot reply, returning live activity, live session phase and post-flush seq as a consistent cut so consumers drop already-covered deltas without double-appending.

### Activity pure projection
`Activity.new/0` returns `%{phase: :idle, current_call: nil}`.
`Activity.apply(activity, event)` returns `{new_activity, public_events}` with no process, timer, publication or replay state.
Valid phases are `:idle`, `:llm_waiting`, `:llm`, `:llm_complete`, `:retry_wait` and `:tools`.
`{:start_call, id, turn, attempt}` replaces the call with `%{id: id, turn: turn, attempt: attempt, text: "", thinking: ""}` and sets `:llm_waiting`.
`{:call_phase, id, phase}` changes only a matching current call, clearing it for `:retry_wait` or `:idle` and retaining it for `:llm_complete` and other valid phases.
`{:phase, phase}` changes the phase and preserves the current call except that `:idle` clears it.
`:reset` replaces the projection with idle and no call.
Start, valid phase and reset events emit `{:activity, new_projection}` replacement public events.
`{:chunk, id, :text | :thinking, binary}` appends only to the matching current call and emits the existing `{:text | :thinking, binary}` public append event, not a replacement.
Stale call identities, invalid phases, malformed chunks and unknown events are no-ops.
Start-call validation checks only that the id is binary, not that it is nonempty or that turn/attempt are nonnegative integers; matching chunks are accepted in every phase while a current call remains, including `:llm_complete` and `:tools`.
Unkeyed `{:phase, phase}` and `:reset` events have no call-id validation, so stale-worker rejection belongs to the session rather than this projection.
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
No replay or periodic snapshot polling may be added.
Capture must remain independent of the watcher gate so mid-attempt attachment and interruption do not depend on prior watchers.
Publication is gated by the session's watcher map, never inferred from Registry or PubSub subscriber counts.
Subscriptions and their consumer-local memo must be managed from the same consumer process.
Snapshots carry the full transcript and are heavy RPC payloads; ordinary deltas and unwatch are lightweight.

## Routing Table
This directory has no child directories.
`activity.ex` owns pure live projection, `sink.ex` owns worker-local capture, `snapshot.ex` owns snapshot shape, `watchers.ex` owns monitors/publication, `batcher.ex` owns coalescing data, and `interrupted.ex` owns the stream interrupt exception.
