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

## Routing Table
There are no child directories.
Streaming and checkpoint suites are owned by the sibling `../stream/` directory and parent agent test node rather than this directory.
