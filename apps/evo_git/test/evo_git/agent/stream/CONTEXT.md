# evo_git/agent/stream — Push-Only Streaming Tests

## Intent
ExUnit coverage for push-only agent streaming, watcher-gated publication, capture-independent current-call activity, snapshot reconciliation and interruption.
Production contracts live in `apps/evo_git/lib/evo_git/agent/stream/CONTEXT.md` and `apps/evo_git/lib/evo_git/agent/session/CONTEXT.md`.
Source and shared support are outside this test node's write scope.

## Routing Table
This node has no child directories.
- `activity_test.exs` → pure Activity projection, exact public replacement/append events, current-attempt replacement, valid phases, retirement and stale/malformed event rejection.
- `sink_activity_test.exs` → process-local Sink installation, turn/reset/uninstall behavior, fresh IDs across `[0, 1, 0]` attempt indices, captured callback identity, stale callback rejection through Activity, positive current-call controls and interrupts.
- `activity_snapshot_test.exs` → pending-batch consistent cuts for snapshot and repeated watch, exact live activity, post-flush sequence, covered-delta rejection and subsequent appends applied exactly once.
- `gate_test.exs` → no-sink callbacks absent, installed-sink callbacks present regardless of watchers, actual unwatched callback capture/interruption, public silence, watched coalescing, ordering and synthetic subscribe–snapshot gap.
- `pure_contract_test.exs` → topics, stale predicate, normalization, Batcher, Watchers, snapshot shape with default/explicit activity and Interrupted exceptions.
- `subscription_test.exs` → consumer-local idempotent subscription memo, refused-watch cleanup and RemoteNode watch/snapshot local-node contracts.
- `watcher_lifecycle_test.exs` → monitored watcher removal, self-subscribed consumer lifecycle and unwatched publication silence.
- `interrupt_test.exs` → append-before-interrupt ordering, consuming interrupt peek and early-turn context delivery through the exchange seam.
- `inspection_test.exs` → summary-only roster reads, live/gone bounded history and total missing-target reads.
- `../session/` → session-owned stale-worker rejection, midcall lifecycle, yield/cancel/terminal retirement (sibling — read-only, escalate writes to parent).

## API Surface
Tests invoke `EvoGit.Agent.Stream`, its Activity/Sink/Batcher/Watchers/Snapshot helpers, real directly started Session processes and scheduler RemoteAPI inspection reads.
The shared `test/support/stream_case.ex` CaseTemplate is the single session harness, with uniquely keyed production-shaped AgentState/SchedMeta rows, repo-less dispatch contexts and process-local exchange seams.
Its inline InteractiveAgent and OneshotAgent roles are defined before the template.
`start_session/1`, `dispatch_ctx/3`, `driver_llm_call/1`, `response/2`, `collect_deltas/3`, pending-message helpers and bounded event waits are shared infrastructure, not a second session implementation.
Local custom LLM seams may invoke the real installed Sink callbacks while keeping the worker parked.

## Constraints
All modules are `async: true` except `inspection_test.exs`, whose table-wide reads of the app-global scheduler ETS tables force serialization and are documented in-file.
Session fixtures write only their unique scheduler rows, delete only those rows and assert on their own agent topic.
Pure Sink fixtures use process-dictionary state and the test mailbox, never app-env overrides.
No external network, global scheduler mutation or artificial host load is needed for this node's suites.
Keep assertions exact and waits event-driven; do not substitute sleep windows for a causal barrier.
Source defects must be reported upstream rather than repaired in this test node.

## Test Strategy
Run `ERL_FLAGS='+S 4:4' mix test apps/evo_git/test/evo_git/agent/stream --no-deps-check --seed 42` from the repository cwd.
The suite contains 71 tests, and every file remains below 1000 lines.
Capture and public delivery are separate: four callbacks exist whenever Sink is installed, but zero watchers means no public batch, timer, broadcast or sequence consumption.
Fresh call identity, not attempt index, separates an empty-response nudge from an earlier attempt zero.
Captured callbacks for call A retain A even after B starts, and Activity rejects A's late chunks/phases without modifying B or emitting public events.
A matching current-call control must accompany stale-callback tests so inert callbacks cannot vacuously pass.
Pending-batch tests suspend the session, let the current worker send real callback activity followed by a watch/snapshot request, and resume only after that FIFO ordering is established.
The reply must contain the complete live projection and post-flush seq; queued deltas at or below it are stale, and newer appends apply exactly once.
Suspended sessions are resumed in unconditional cleanup.
Snapshots are transcript checkpoints plus live activity, not a replay mechanism or a polling contract.
`Stream.subscribe/1` is consumer-local and idempotent, but raw Phoenix.PubSub subscription is not; repeated raw subscriptions duplicate deliveries.

## Coverage Boundaries
The `[0, 1, 0]` Sink test pins fresh IDs for retry/nudge-shaped attempt inputs, not actual LLMPrompting retry or nudge wiring.
The `:llm_call` exchange seam replaces LLMPrompting, so it cannot prove real provider callback installation, request retries or empty-response nudge behavior.
Actual LLMPrompting integration needs the existing serialized scheduler/loopback HTTP machinery or a lower-level process-local seam coordinated above this node.
The pending-snapshot suite invokes real Sink callbacks in a genuine worker but does not invoke ReqLLM's network stream decoder.
`activity_snapshot_test.exs` orders callback messages and the snapshot/watch request from the SAME worker while the session is suspended, proving pending-batch flushing but not checkpoint-versus-history or worker-completion races.
`inspection_test.exs` reads history only after `await_yield/2`, so its exact RPC/session equality does not establish a coherent mid-turn snapshot/history cut.
No test in this directory drives a failed provider attempt through a genuine Session or pins tool-free terminal text delivery during one-shot completion; the session fixtures here park interactive replies instead.
Real cross-node RemoteNode watch routing needs another BEAM and is not established by local-node subscription tests.
Managed tool execution lifetimes, overlap, execution identities and tool results are not established by synthetic tool declarations here.
Snapshot no-context assertions inspect top-level values rather than recursively JSON-encoding the whole projection.

## Known Source Limitations
Activity start-call validation accepts any binary ID, including empty IDs, and does not validate turn/attempt ranges.
Matching chunks remain accepted while a current call is retained in `:llm_complete` or `:tools`.
The legacy streamed tool declaration uses unkeyed `{:delta, [{:tool_call, nil, name}]}` and lacks keyed text/thinking callbacks' stale-call protection.
These are documented source behaviors, not proof of a production failure in the tested inspector path.

## Notes for Agents
A scripted response with non-catalog `test:model` may emit a best-effort cost warning, which stays captured by the suite's log capture.
Do not use `process_stream/2` tracing to claim network stream coverage when the exchange seam bypasses it entirely.
`{:interrupted, reason}` is the early-turn non-error seam contract; replacing it with `{:error, reason}` exercises a different failure path.
`interrupt_test.exs` still contains stale comments claiming zero watchers makes `Sink.stream_opts/0` empty and prevents callback interruption, contradicted by the real installed-Sink assertions in `gate_test.exs:48-141` and the pure Sink suite.
The interrupt suite's second case uses a scripted reply that never invokes callbacks, so its next-exchange delivery is a fixture behavior rather than evidence of watcher-dependent production interruption.
