# HomeLive Support Tests

## Intent

This directory tests the support modules and assistant component used by the `/help` reading-first chat page.
All suites use `async: true` and avoid mounting HomeLive; only the approval runner suite owns the app-env seams documented below.
ModelSelect config-loading tests use the existing per-process ConfigDir seam and unique files, never process-global environment changes.
Fixtures resolve the concrete paths through `EvoGit.Config.config_dir/0` and `config_path/0`, because the isolation helper returns the override root rather than the final application directory.

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

## Provider-Profile Selection Coverage

`chat_state_test.exs` preserves the legacy whole-state shape and normalization assertions while testing canonical string-keyed `model_spec` persistence and `restore_selection/2` separately.
Persisted selection contains only provider-profile id, model, optional reasoning effort, exact `{target_id, BEAM_node}` scope and error state; credential-bearing config snapshots, picker bundles and load counters never enter ChatHistory.
Nil is uninitialized, `%{}` is explicit Auto, and false or malformed specs remain `:invalid_model_spec` across repeated save/restore rather than falling back to Auto or a legacy pin.
Persistence validates shape only, leaving current account/model/effort membership to the shared resolver.
Unscoped legacy ids remain whole migration inputs on the local scope only; explicit unscoped specs never use that exception.
Exact target-id and BEAM-node matching includes pending remote targets with local-node fallbacks, so one target cannot borrow another target's pin.
`model_select_test.exs` exercises the actual `ModelSelect.task_opts/4` and shared resolver with canonical multi-account config and legacy config, without spawning any reflect task or touching the scheduler/network.
Task options must use only canonical string-keyed `model_spec` plus `model_id_locked: true`, remove legacy pins, preserve unrelated task options and omit credential-bearing account fields.
Nil selects configured defaults even with rules enabled, Auto removes all model pins, advertised reasoning defaults or first-inventory efforts resolve before submission, and models without inventories omit task reasoning overrides.
Stale accounts/models/efforts and legacy ids return errors, explicit specs outrank migration inputs, and fresh config revalidates restored pins.
Snapshot-node/full-scope mismatch, pending remote contexts, missing snapshots and persisted invalid-spec errors are tested independently of successful resolver calls.
Local load tests expect tagged full-config snapshots with string-keyed canonical provider rows and configured-but-broken rules to remain enabled; an unreachable remote load preserves its error within the real supervised SafeCall envelope.
These tests exercise the public `EvoGit.Config.Schema.provider_profiles/1`, `model_selections/1` and `resolve_model_spec/2` APIs called by `LLMSelection` and normal config validation of the `:provider_profiles` schema type without stubs or skipped integration checks.

## ApprovalWorkflow Coverage

`approval_workflow_test.exs` contains a shared fixture helper, 21 pure async workflow tests and five async runner tests against `apps/evo_dash/lib/evo_dash_web/live/home_live/approval_workflow.ex`.
Both suites drive hand-built `%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, ...}}` sockets without mounting `/help`, touching ChatHistory, invoking a live approval service or evaluating code.
Ownership is source-node plus task OR string/integer-normalized agent identity; the source is `chat_node || current_node`, never evaluator `target_node`, and only legacy requests may omit the source node stamp.
Malformed requests, blank ids, unusable refs and pending remote contexts are rejected, including recovery and response attempts that must not fall back to the local service.
Pure tests pin every captured scope field (chat id, viewed node id/node, chat node, task and agent ids), stale tokens, resets, snapshot replacement and filtering, newer live-arrival precedence, and resolution tombstones for seen and unseen cards.
Source-stamped `resolved/3` accepts only the scoped chat source, rejecting the viewed node and evaluator target when distinct, and rejects unusable scopes and pending remote contexts even when the stamp matches.
Legacy `resolved/2` remains id-only; both paths clear busy/live entries and tombstone seen or unseen cards during recovery, while rejected source stamps cannot poison the snapshot.
Authoritative empty or stale snapshots preserve an owned responding card and its original payload until success, not-found or a source resolution, while removing unrelated stale non-busy cards.
A response failure after such a snapshot retains the card with retry guidance and clears only its busy state.
Response tests pin absent/invalid/unowned/duplicate submission no-ops, retained cards on backend or transport failure, cleared busy state, successful retry, stale response rejection, and removal only on success, not-found or resolution.
Runner tests exercise real supervised SafeCall execution with bare list/backend return values and nested envelopes `{{:approval_pending_loaded, seq, scope}, {:ok, requests}}` and `{{:approval_workflow_response, seq, scope, id}, {:ok, :ok}}`.
The runner suite pins off-process source routing, captured runners despite later seam replacement, strictly increasing tokens across newer loads/reset/retry, pending-runner exits, and recovery retry.
Its responder retry flow applies a real supervised empty pending snapshot before a failed response, proving the preserved card can submit a fresh decision and settle only on the new acknowledgement.
All waits are bounded mailbox handshakes with no sleeps, and blocked runners are released and monitored through normal exit.
`ApprovalWorkflowRunnersTest` is the sole async owner of the BEAM-global `:approval_pending_runner` and `:approval_responder` seams, restoring their previous values after each test.
The sibling `home_live_test.exs` responder writer is synchronous and runs only after this async cohort; any future async seam writer must coordinate ownership rather than assume per-socket isolation.
Approval recovery counters, pending cards, response tokens and errors are runtime-only, and the suite asserts they remain absent from `ChatState.build/1` output.

## Routing Table

This node has no child directories.
