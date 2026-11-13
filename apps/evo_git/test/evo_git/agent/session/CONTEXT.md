# Agent Session Tests

## Intent
This directory tests session summary projection, interactive state lifetime and closure, and responsiveness during worktree setup.
All sessions are started directly with dispatch contexts rather than through scheduler dispatch.

## API Surface
`summary_test.exs` exercises `Session.Summary.publish/3` and `read/1` against production-shaped registration rows in the shared summary ETS table.
`interactive_test.exs` exercises `Session.inspect/2`, `history/2`, `start_input/3`, cancellation, and pure `Session.Input` and `Session.Outcome` contracts with repo-less scripted exchanges.
`interactive_close_test.exs` exercises real worktree lifetime and finalization across multiple interactive exchanges, including git notes and archive rows.
`start_stall_test.exs` exercises public identity, close and force cancellation while the worktree create seam is parked, plus diagnosable setup timeout.

## Constraints
Summary and interactive suites are `async: true` and insert only per-test uniquely keyed production-shaped scheduler rows, deleting their own rows on exit.
The start-stall suite is `async: false` because it mutates the shared `:worktree_create_fun`, `:worktree_create_slow_warn_ms` and `:worktree_create_stall_timeout_ms` app-env seams.
Session fixtures inject `exchange_opts` and `scheduler: self()` so scripted worker behavior and terminal messages are test-local.
Interactive-close finalizers lack the test process dictionary, so archive assertions read uniquely identified rows in the app-global task store.
A sequence shared across exchanges must live outside the exchange worker process dictionary because each exchange has a fresh worker; `interactive_close_test.exs` uses a linked Agent for its reply sequence.

## Coverage and Gaps
Summary tests assert state-owned turn, message count, usage, token count, compression count, context window, current commit, objective preview and last-activity projection while preserving registration fields and excluding conversation context.
Unchanged summary publication preserves the entire row and last-activity timestamp and emits no agent-update delta, while publication to a missing row never recreates it.
Interactive tests assert full history survives yield, idle status is `:awaiting_input`, identity and conversation prefixes survive resumes, idle workers die, graceful idle cancellation produces the last yielded report, and force cancellation produces no result.
No test in this directory subscribes through `Agent.Stream`, asserts an `agent_delta` sequence or snapshot resynchronization, or exercises current-call/execution-activity streaming fields.
No test here directly drives a checkpoint callback or establishes mid-turn summary publication; the summary suite calls the projection helper directly.
`interactive_test.exs` uses process-dictionary reply sequencing despite fresh exchange workers, and its `await_yield` helper can accept an idle phase after missing the expected reply text, so it is not a strong exact cross-exchange reply-order pin.

## Activity Regression Planning and Deterministic Seams
Production session activity is separate from `%State{}` and the summary row, so activity assertions must use `Agent.Stream.watch/1` or `snapshot/1` rather than `Session.inspect/2` or `Summary.read/1` alone.
The sibling `../stream/` suites share `EvoGit.Agent.StreamCase` from `test/support/stream_case.ex`, whose `scripted_llm_call/1`, direct session startup and forwarded `exchange_opts` support parked worker-local `Stream.Sink` calls without global app-env seams.
An activity emitter must synchronize with the session before acknowledging the test, for example by calling `Session.inspect/2` from that same worker after sending activity, because a worker-to-test notice alone does not order a later test-to-session snapshot against the activity messages.
The existing driver uses legacy `Sink.emit/1` rather than call-start and callback activity APIs, so it cannot by itself establish unwatched retained text/thinking or callback identity.
The required activity boundary matrix includes unwatched partial capture followed by mid-call watch, snapshot flush/dedup, advancing versus duplicate/older/current-call checkpoints, stale-worker rejection, and cleanup on error, worker death, force cancellation, interrupt, yield and resume.
An advancing checkpoint preserves activity when its current call's turn is at least the checkpoint turn and retires older activity otherwise, while duplicate and older checkpoints must change neither activity nor transcript nor summary.
Running graceful cancellation preserves current activity and the worker rather than behaving like force cancellation.
Tool declarations, including streamed nil-id declarations, are not execution-start evidence and must not independently set the `:tools` activity phase.
New activity suites can remain `async: true` by reusing unique production-shaped scheduler rows, agent-id-specific stream topics and per-dispatch seams, with no real git fixture needed for projection-only cases.
Exact yield notices and explicit worker release messages are stronger evidence than `interactive_test.exs`'s phase-fallback `await_yield` helper or its auto-releasing five-second blocker.

## Routing Table
There are no child directories.
Streaming and checkpoint suites are owned by the sibling `../stream/` directory and parent agent test node rather than this directory.
