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

## ApprovalWorkflow Coverage Gap

No committed suite in this directory exercises `ApprovalWorkflow`; the existing files cover assistant presentation, stream failure extraction, persisted chat normalization, message conversion and transcript normalization.
The production helper is `apps/evo_dash/lib/evo_dash_web/live/home_live/approval_workflow.ex`, with full integration contracts in that production directory's CONTEXT.md.
Workflow unit tests can drive hand-built `%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, ...}}` sockets without mounting `/help` or touching ChatHistory.
Pure tests should pin source-node and task-or-agent ownership, scope/token stale rejection, snapshot/live-broadcast reconciliation, resolution tombstones, retained cards on response failure and removal on success or not-found.
Async runner tests must account for SafeCall's nested `{tag, result}` messages and outer `{:ok, value}` wrapping, capture the runners at spawn time, and use bounded mailbox handshakes instead of sleeps.
The `:approval_pending_runner` and `:approval_responder` seams are BEAM-global app-env keys, so any tests mutating them must coordinate ownership with other async test modules rather than assuming per-socket isolation.
Approval recovery counters, pending cards, response tokens and errors are runtime-only and should remain absent from `ChatState.build/1` output.

## Routing Table

This node has no child directories.
