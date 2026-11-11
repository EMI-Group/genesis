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
## Mounted Page Suite (owned by `../home_live_test.exs`)
The mounted `/help` suite is `async: false` and owns the process-global `EvoDash.ChatHistory`, `EvoDash.ActiveTasks`, the isolated `EvoGit.Store`/`TaskRegistry` pair and the per-test `:home_session_*` / `:approval_*` / `:source_*` app-env seams; a new mounted `/help` test belongs there, never in an async module.
Page-alive/name assertions use `page_heading/1` to pin the `h1` to "Genesis Assistant", not a loose name match that an assistant entry or composer label could satisfy.
Chat state is SEEDED (`seed_chat_state/2`, `seed_running_chat/1`, synthetic `{:task_updated, …}` events) and terminal paths are driven with `finalize_failed/2` / `insert_task_fixture!` — NOT by submitting `send_message` to start a real `:reflect` task.
Exactly ONE real-send canonical pin ("starts a reflect task with the right opts") remains: it asserts synchronous `chat_task_id` tracking (non-nil, matching the persisted reflect row) and NO "Failed to start the task" bubble, and it is network-free by construction because the suite setup pushes `model_profiles: []` into the AgentScheduler (`update_config`, restored in `on_exit`), so `run_agent` rejects every spawn synchronously with `{:error, :llm_not_configured}` before registration or HTTP.
Counterintuitive, verified: a BOGUS `model_id` does NOT fail fast — `Dispatch.resolve_model_for_agent/2` warns and falls back to the FIRST real profile, which would hit the ambient (expired-key) LLM.
The canonical Assistant launch fixture exposes its config directory to the singleton TaskRegistry through the existing config-dir seam and restores that seam after each test; process-local dictionary fixtures alone cannot reach the singleton.
`Store.Codec` atomizes the outer canonical `:model_spec` option key while preserving its string-keyed selection map; explicit locks, no legacy override and no repository path remain pinned.
Also covered are user-bubble classes on both send routes, canonical provider/model/reasoning controls, explicit Auto, ChatHistory remount/new-chat persistence, node-scope isolation, finalized markdown versus mid-stream text, per-message raw toggles and legacy/evaluator approval cards.
The fused-capsule page contract targets the model capsule's drill-down panel, never the retired provider `<select>`: both capsule roots carry `phx-hook="CapsulePanel"` (`#chat-llm-selection` in the Assistant composer), only the model capsule declares `data-capsule-view="model"`, and its provider rows emit `phx-click="select_provider_profile"` with `phx-value-provider_profile_id` (no `name="provider_profile_id"` field or `phx-change` binding).
`home_live_render_test.exs` pins the same structure attributes, the provider click contract inside `#chat-form`, `approval_error: nil` for the page's approval-state branch, and the assistant name in the heading, composer accessible label/placeholder and empty-chat disclaimer.

### Approvals
Approval page contracts preserve legacy command/args/level cards while distinguishing evaluator write grants from sudo authority, including exact escaped code, the target runtime, one-use permission, and sudo's live-runtime/files/configuration/no-rollback/not-OS-root warnings.
The approval block snapshot-restores `:approval_pending_runner` and `:approval_responder`; restored-chat pending recovery uses an actual list-returning supervised runner and responses stay visible with both controls disabled until asynchronous success.
Responder failures retain a visible error and retryable card, and absent/resolved/no-longer-owned request ids cannot reach the responder.
The source/chat node owns request filtering, pending reads and decisions independently of evaluator `target_node`; source-stamped resolutions from foreign nodes are ignored, while legacy three-element resolution events remain supported.
Page tests exercise nested Workflow result routing, live-arrival overlays and resolution tombstones during pending recovery, obsolete generations/scopes, and New-chat invalidation of late responses.
Pure helper and card tests are async without `/help` mounts, whereas these mounted-page approval tests remain in the existing sync suite because they share ChatHistory, the isolated global Store/TaskRegistry pair, scheduler configuration, and approval app-env seams.

### Genesis-source gate
The two `:source_clone_runner` stubs carry NO artificial delay — "Cloning…" is assigned synchronously by `download_source`, so `render_click/1`'s reply already carries the busy markup; completion is polled via `wait_until(source_busy == nil)` / `await_source_available/3`.
The remote-node negative `refute_receive :availability_runner_called, 50` is backed by construction (`maybe_check_source/1` is the only spawn site, gated on `SourceGate.visible?(current_node)`) plus `assert assigns(view).source_available == nil`.

### Interactive session reattach (`/help?session=<agent_id>`)
A reattached session is driven through the call-time `:home_session_attach_runner` (`counting_attach_runner/4` with `:counters` as the drain-proof "exactly one attach" witness) and `:home_session_start_runner` (absent ⇒ no task started).
The cached chat is seeded with `seed_cached_chat/3` (transcript plus optional `thought_process`); `parked_attach/2` maps `:awaiting_input` to a writable `:idle` page, `running_attach_state/2` keeps `:running`, and `gone_attach/0` is the core's "session no longer known" answer (`summary: nil`, empty history).
A vanished session with a NON-EMPTY cached conversation keeps that transcript AND its `thought_process` (an empty fetched history never wipes the cache), settles at `chat_status: :ended` and renders read-only: no assistant streaming bubble (`.help-caret` absent), composer disabled, no ended-session empty state, New chat enabled, exactly one attach and no task row.
A vanished session with an EMPTY cache renders `#chat-session-ended` ("This session has ended." plus a `phx-click="new_chat"` affordance) instead of the greeting, so no suggestion chip is rendered, and the header's New chat stays enabled.
A NON-EMPTY fetched history always wins: the cached transcript and reasoning are replaced by the fetched entries.
