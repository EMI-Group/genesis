# HomeLive Support Tests

## Intent

This directory tests the pure support modules and assistant component used by the `/help` reading-first chat page.
All suites use `async: true` and avoid mounting HomeLive or modifying process-global state.

## API Surface

`assistant_message_test.exs` renders `AssistantMessage.assistant_message/1` and tests `AgentStream.extract_failed_message/1` directly.
`chat_state_test.exs`, `messages_test.exs`, and `transcript_test.exs` cover chat-state normalization, message extraction, and transcript normalization.

## Constraints

Assistant answers render in a borderless reading column rather than a nested card, with optional collapsed thought details after the answer and finalized actions last.
Finalized text renders Markdown by default and escaped literal source in raw mode, while streaming remains plain text with a caret or empty-stream dots and never exposes copy/raw actions.
The action footer stays in normal document flow with its own spacing, is visible on mobile and non-hover devices, and is revealed by desktop hover or keyboard focus.
Copy binds a unique `assistant-copy-<entry id>` and `ClipboardCopy` hook to the complete original source, including long text, newlines, quotes and HTML-sensitive characters in either display mode.
The raw toggle binds `toggle_assistant_raw` and the correct entry id, with mode-specific accessible labels and icons.
Action buttons retain touch-sized mobile targets, smaller desktop targets, button semantics and visible keyboard-focus styling.
These component tests pin rendered bindings and classes, not browser clipboard execution or LiveView event-handler behavior, which belong outside this node.
No production files or translation catalogs are maintained here.

## ApprovalWorkflow Coverage

`approval_workflow_test.exs` contains a shared fixture helper, 17 pure async workflow tests and five async runner tests against `apps/evo_dash/lib/evo_dash_web/live/home_live/approval_workflow.ex`.
Both suites drive hand-built `%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, ...}}` sockets without mounting `/help`, touching ChatHistory, invoking a live approval service or evaluating code.
Ownership is source-node plus task OR string/integer-normalized agent identity; the source is `chat_node || current_node`, never evaluator `target_node`, and only legacy requests may omit the source node stamp.
Malformed requests, blank ids, unusable refs and pending remote contexts are rejected, including recovery and response attempts that must not fall back to the local service.
Pure tests pin every captured scope field (chat id, viewed node id/node, chat node, task and agent ids), stale tokens, resets, snapshot replacement and filtering, newer live-arrival precedence, and resolution tombstones for seen and unseen cards.
Resolution is deliberately id-only in the helper, so source-node filtering of resolution broadcasts remains the parent's responsibility.
Response tests pin absent/invalid/unowned/duplicate submission no-ops, retained cards on backend or transport failure, cleared busy state, successful retry, stale response rejection, and removal only on success, not-found or resolution.
Runner tests exercise real supervised SafeCall execution with bare list/backend return values and nested envelopes `{{:approval_pending_loaded, seq, scope}, {:ok, requests}}` and `{{:approval_workflow_response, seq, scope, id}, {:ok, :ok}}`.
The runner suite pins off-process source routing, captured runners despite later seam replacement, strictly increasing tokens across newer loads/reset/retry, pending-runner exits, and recovery retry.
All waits are bounded mailbox handshakes with no sleeps, and blocked runners are released and monitored through normal exit.
`ApprovalWorkflowRunnersTest` is the sole async owner of the BEAM-global `:approval_pending_runner` and `:approval_responder` seams, restoring their previous values after each test.
The sibling `home_live_test.exs` responder writer is synchronous and runs only after this async cohort; any future async seam writer must coordinate ownership rather than assume per-socket isolation.
Approval recovery counters, pending cards, response tokens and errors are runtime-only, and the suite asserts they remain absent from `ChatState.build/1` output.

## Routing Table

This node has no child directories.
