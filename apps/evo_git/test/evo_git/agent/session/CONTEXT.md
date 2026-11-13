# Agent Session Tests

## Intent
This directory tests session summary projection, interactive state lifetime and closure, execution-activity snapshots and cleanup, and responsiveness during worktree setup.
All sessions are started directly with dispatch contexts rather than through scheduler dispatch.

## API Surface
`summary_test.exs` exercises `Session.Summary.publish/3` and `read/1` against production-shaped registration rows in the shared summary ETS table.
`interactive_test.exs` exercises `Session.inspect/2`, `history/2`, `start_input/3`, cancellation, and pure `Session.Input` and `Session.Outcome` contracts with repo-less scripted exchanges.
`interactive_close_test.exs` exercises real worktree lifetime and finalization across multiple interactive exchanges, including git notes and archive rows.
`start_stall_test.exs` exercises public identity, close and force cancellation while the worktree create seam is parked, plus diagnosable setup timeout.
`activity_projection_test.exs` exercises unwatched partial capture, mid-call watch, consistent watch/snapshot cuts and sequence-based deduplication, checkpoint retirement/preservation and stale or unauthenticated message rejection.
`activity_lifecycle_test.exs` exercises rejection, worker death, graceful versus force cancellation, exact interactive yield/resume cleanup, genuine unwatched chunk interruption, and streamed tool declaration versus actual tool-batch phase.

## Constraints
Summary, interactive and activity suites are `async: true` and insert only per-test uniquely keyed production-shaped scheduler rows, deleting their own rows on exit.
The start-stall suite is `async: false` because it mutates the shared `:worktree_create_fun`, `:worktree_create_slow_warn_ms` and `:worktree_create_stall_timeout_ms` app-env seams.
Session fixtures inject `exchange_opts` and `scheduler: self()` so scripted worker behavior and terminal messages are test-local.
Interactive-close finalizers lack the test process dictionary, so archive assertions read uniquely identified rows in the app-global task store.
A sequence shared across exchanges must live outside the exchange worker process dictionary because each exchange has a fresh worker; `interactive_close_test.exs` uses a linked Agent for its reply sequence.

## Coverage and Gaps
Summary tests assert state-owned turn, message count, usage, token count, compression count, context window, current commit, objective preview and last-activity projection while preserving registration fields and excluding conversation context.
Unchanged summary publication preserves the entire row and last-activity timestamp and emits no agent-update delta, while publication to a missing row never recreates it.
Interactive tests assert full history survives yield, idle status is `:awaiting_input`, identity and conversation prefixes survive resumes, idle workers die, graceful idle cancellation produces the last yielded report, and force cancellation produces no result.
The activity projection suite pins session-owned watchers and sequence against stale worker state copies, retirement of calls older than advancing checkpoints, preservation of same/ahead-turn calls, and no transcript, summary or activity changes from duplicate, older, identity-free or stale-worker checkpoints.
The activity lifecycle suite pins exact yield notices and fresh resumed workers/call identities independently of the older interactive suite's fallback helpers.
`interactive_test.exs` uses process-dictionary reply sequencing despite fresh exchange workers, and its `await_yield` helper can accept an idle phase after missing the expected reply text, so it is not a strong exact cross-exchange reply-order pin.
Tool-batch phase coverage establishes the session projection boundary, not ProcessManager execution lifetime or real provider callback integration.
No test here mounts a dashboard consumer or proves terminal-history recovery after session exit; terminal fixtures assert result/closed messages and process death, while interactive fixtures inspect retained history before close.
A resumed worker sees newly drained user input before the public checkpoint transcript includes it, explicitly pinned by `activity_projection_test.exs:269-273`, so a running snapshot must not be assumed to include queued or freshly drained input.

## Deterministic Activity Seams
Production session activity is separate from `%State{}` and the summary row, so activity assertions use `Agent.Stream.watch/1` or `snapshot/1` rather than `Session.inspect/2` or `Summary.read/1` alone.
The activity suites reuse `EvoGit.Agent.StreamCase` from `test/support/stream_case.ex` with direct session startup and forwarded per-dispatch `exchange_opts`, avoiding network and app-env mutations.
Activity is emitted through actual worker-local `Stream.Sink` call-start and callback APIs rather than only the harness driver's legacy `Sink.emit/1` path.
An emitter synchronizes with the session by calling `Session.inspect/2` from that same worker before acknowledging the test, because a worker-to-test notice alone does not order a later test-to-session snapshot against activity messages.
Exact yield notices and explicit worker release messages provide deterministic ordering without timed sleeps or automatic fallback releases.
Zero watchers suppress public buffering, timers and sequence consumption but not retained partial activity or chunk interruption.
Running graceful cancellation preserves current activity and the worker rather than behaving like force cancellation.
Tool declarations, including streamed nil-id declarations, are not execution-start evidence and must not independently set the `:tools` activity phase.

## Integration Fixture Pointers
`activity_projection_test.exs:279-352` provides private `parked_session/1`, `run/2`, `begin_call/2` and `pending_cut/3` helpers with explicit worker commands and same-worker `Session.inspect/2` ordering barriers.
Its driver reports `{:projection_worker, worker, context}`, accepts `{:projection_command, ref, fun}` and replies `{:projection_ack, ref, result}`, or accepts `{:reply, text}` to yield.
`activity_lifecycle_test.exs:255-333` provides private `start_activity/2`, `drive_call/3`, `barrier/0` and `capture/3`, with `{:activity_call, worker, call, context, callbacks}` readiness, `{:capture, text, thinking}` / `{:captured, worker}` acknowledgements and explicit reply/rejection/tool gates.
Its exact yield/resume case at lines 97-162 asserts `{:agent_session_yield, id, pid, text}`, worker `:DOWN`, idle snapshot/history, `Session.start_input(pid, text, :queue)`, `{:agent_session_resumed, id, pid}`, fresh worker/call, stable cache key and a second exact yield.
`interactive_test.exs:536-575` constructs a repo-less dispatch keyword list with `agent_id`, `depth`, `repo_root`, `repo_id`, `worktree_path`, `retries`, `spec`, `meta`, `repo_less`, `repo_less_repo_path`, `notify`, `scheduler` and `exchange_opts`, passing the latter through after deleting its test-only `:agent_module` selector.
Its registration row at lines 496-517 carries `llm_model: nil`, a legacy pool `model_id`, `llm_context_window: 200_000` and `llm_generation_params: [temperature: 0.2, provider_options: [prompt_cache_key: key]]`, so it is a scripted fixture rather than a working real-provider request setup.
No test source in this node mentions `stream_start` or `stream_start: nil`, so these tests do not establish that disabling a stream-start seam is necessary for actual LLMPrompting integration.
`activity_lifecycle_test.exs:260-262` explicitly calls `Sink.start_call(0)`, `Sink.call_phase(call, :llm)` and `Sink.stream_opts()` inside its scripted LLM, while `activity_projection_test.exs:321-324` additionally calls `Sink.start_turn(turn)` before `Sink.start_call(1)`.
Both activity suites import `EvoGit.Agent.StreamCase`, so its out-of-node `test/support/stream_case.ex` implementation must be checked for implicit `stream_start` defaults and dispatch option merging before adapting these fixtures to actual LLMPrompting.
`ActivityLifecycleTest.start_activity/2` force-cancels and monitors the session during teardown to reap its parked worker, whereas the older interactive `start_session/1` helper only kills the session as a last resort.

## Routing Table
There are no child directories.
Pure Activity/Sink, watcher gating and general stream transport tests belong to sibling `../stream/` (sibling — read-only, escalate writes to parent).
Shared stream fixture changes belong to `../../../support/` (outside this node — read-only, escalate writes to parent).
