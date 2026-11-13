# HomeLive Support Tests

## Intent

This directory tests the support modules and assistant component used by the `GET /assistant` chat page.
All suites use `async: true` and avoid mounting HomeLive; the approval runner suite owns approval app-env seams and `session_actions_test.exs` owns the `:home_session_*_runner` seams it installs.
ModelSelect config-loading tests use the existing per-process ConfigDir seam and unique files, never process-global environment changes.
Fixtures resolve the concrete paths through `EvoGit.Config.config_dir/0` and `config_path/0`, because the isolation helper returns the override root rather than the final application directory.

## API Surface

`assistant_message_test.exs` renders `AssistantMessage.assistant_message/1` and tests `AgentStream.extract_failed_message/1` directly.
`chat_state_test.exs`, `messages_test.exs`, and `transcript_test.exs` cover chat-state normalization, message extraction, and transcript normalization.
`display_messages_test.exs` covers the ordered chat-transcript projection `EvoDashWeb.HomeLive.DisplayMessages` (`bubbles/1`, `bubble/1`, `user_authored?/1`) with hand-built `%ReqLLM.Message{}` fixtures: the `metadata[:user_authored]` marker, its `:unknown` shape-heuristic fallback, and totality on malformed payloads.
`delta_test.exs` covers the pure `EvoDashWeb.HomeLive.Delta` reducer of the push-only agent-delta stream.

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
Both suites drive hand-built `%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, ...}}` sockets without mounting `/assistant`, touching ChatHistory, invoking a live approval service or evaluating code.
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
The mounted `/assistant` suite is `async: false` and owns the process-global `EvoDash.ChatHistory`, `EvoDash.ActiveTasks`, the isolated `EvoGit.Store`/`TaskRegistry` pair and the per-test `:home_session_*` / `:approval_responder` / `:approval_pending_runner` / `:source_*` app-env seams, plus the mounted approval strip + modal-dialog flow; a new mounted `/assistant` test belongs there, never in an async module.
Page-alive/name assertions use `page_heading/1` to pin the `h1` to "Genesis Assistant", not a loose name match that an assistant entry or composer label could satisfy.
Chat state is SEEDED (`seed_chat_state/2`, `seed_running_chat/1`, synthetic `{:task_updated, …}` events) and terminal paths are driven with `finalize_failed/2` / `insert_task_fixture!` — NOT by submitting `send_message` to start a real `:reflect` task.
Exactly ONE real-send canonical pin ("starts a reflect task with the right opts") remains: it asserts synchronous `chat_task_id` tracking (non-nil, matching the persisted reflect row) and NO "Failed to start the task" bubble, and it is network-free by construction because the suite setup pushes `model_profiles: []` into the AgentScheduler (`update_config`, restored in `on_exit`), so `run_agent` rejects every spawn synchronously with `{:error, :llm_not_configured}` before registration or HTTP.
Counterintuitive, verified: a BOGUS `model_id` does NOT fail fast — `Dispatch.resolve_model_for_agent/2` warns and falls back to the FIRST real profile, which would hit the ambient (expired-key) LLM.
The canonical Assistant launch fixture exposes its config directory to the singleton TaskRegistry through the existing config-dir seam and restores that seam after each test; process-local dictionary fixtures alone cannot reach the singleton.
`Store.Codec` atomizes the outer canonical `:model_spec` option key while preserving its string-keyed selection map; explicit locks, no legacy override and no repository path remain pinned.
Also covered are user-bubble classes on both send routes, canonical provider/model/reasoning controls, explicit Auto, ChatHistory remount/new-chat persistence, node-scope isolation, finalized markdown versus mid-stream text, per-message raw toggles and the legacy/evaluator approval strip and modal dialog.
The fused-capsule page contract targets the model capsule's drill-down panel, never the retired provider `<select>`: both capsule roots carry `phx-hook="CapsulePanel"` (`#chat-llm-selection` in the Assistant composer), only the model capsule declares `data-capsule-view="model"`, and its provider rows emit `phx-click="select_provider_profile"` with `phx-value-provider_profile_id` (no `name="provider_profile_id"` field or `phx-change` binding).
`home_live_render_test.exs` pins the same structure attributes, the provider click contract inside `#chat-form`, `approval_error: nil` for the page's approval-state branch, and the assistant name in the heading, composer accessible label/placeholder and empty-chat disclaimer.

### Approvals
Approval page contracts render the always-present status strip plus the one-request modal dialog for legacy command/args/level requests and evaluator write grants alike, distinguishing write from sudo authority, including exact escaped code, the target runtime, one-use permission, and sudo's live-runtime/files/configuration/no-rollback/not-OS-root warnings.
The approval block snapshot-restores `:approval_pending_runner` and `:approval_responder`; restored-chat pending recovery uses an actual list-returning supervised runner and responses stay visible with both controls disabled until asynchronous success.
Responder failures retain a visible error and the pending request with retry guidance, and absent/resolved/no-longer-owned request ids cannot reach the responder.
The source/chat node owns request filtering, pending reads and decisions independently of evaluator `target_node`; source-stamped resolutions from foreign nodes are ignored, while legacy three-element resolution events remain supported.
Page tests exercise nested Workflow result routing, live-arrival overlays and resolution tombstones during pending recovery, obsolete generations/scopes, and New-chat invalidation of late responses.
Pure `ApprovalDialog` render tests are async without `/assistant` mounts and live in `test/evo_dash_web/live/approval_dialog_render_test.exs`, whereas these mounted approval strip/dialog flow tests stay in the sync `home_live_test.exs` because they share ChatHistory, the isolated global Store/TaskRegistry pair, scheduler configuration, and the `:approval_responder` / `:approval_pending_runner` app-env seams.

### Genesis-source gate
The two `:source_clone_runner` stubs carry NO artificial delay — "Cloning…" is assigned synchronously by `download_source`, so `render_click/1`'s reply already carries the busy markup; completion is polled via `wait_until(source_busy == nil)` / `await_source_available/3`.
The remote-node negative `refute_receive :availability_runner_called, 50` is backed by construction (`maybe_check_source/1` is the only spawn site, gated on `SourceGate.visible?(current_node)`) plus `assert assigns(view).source_available == nil`.

### Interactive session reattach (`/assistant?session=<agent_id>`)
A reattached session is driven through the call-time `:home_session_attach_runner` (`counting_attach_runner/4` with `:counters` as the drain-proof "exactly one attach" witness) and `:home_session_start_runner` (absent ⇒ no task started).
The cached chat is seeded with `seed_cached_chat/3` (transcript plus optional `thought_process`), while authoritative Watch snapshots supply messages and lifecycle (`:awaiting_input` → writable `:idle`, `:running` → running).
Independent attach answers supply task identity only while Watch owns the display; empty fetched attach history alone does not prove disappearance, but the exact Watch verdict `{:error, {:not_found, :session_not_found}}` does.
That verdict sets `chat_status: :ended` while preserving cached transcript and `thought_process`: a NON-EMPTY cache renders read-only with no streaming caret, composer disabled, New chat enabled and no ended-session empty state; an EMPTY cache renders `#chat-session-ended` ("This session has ended." plus a `phx-click="new_chat"` affordance) instead of the greeting or suggestions.
Uncertain timeout, startup, overflow or registration-worker death keeps the live session unavailable with its cache preserved and Retry offered, not ended; there is no automatic rewatch, and explicit Retry starts a new watch attempt.
A NON-EMPTY authoritative fetched history replaces the cached transcript and reasoning.
Its mounted fixture advertises the same running session through the sidebar list, attach identity and authoritative Watch snapshot, rather than returning an empty live roster that can preserve an ended cached sidebar title.
Watch is held until the sidebar load and attach identity settle, positively preserving the cached body before release and retaining exact transcript, reasoning and whole-page replacement assertions afterwards.
The consumer and serial watch worker are monitored through teardown before restoring the app-global runner seams.

### Mounted watch recovery coverage (`../home_live_test.exs`)
Vanished-session tests use unique nonexistent ids and default NodeContext/core watch registration, positively awaiting `:ended` rather than fabricating not-found answers.
Cached disappearance retains rendered per-entry reasoning and global `thought_process` read-only, while empty disappearance renders the session-ended state; both assert one attach and no task row.
The `describe "mounted watch recovery"` cases cover returned timeout, actual pending-buffer overflow and actual registration-worker death through counted runner attempts.
They retain cached text/reasoning and a live unavailable consumer without declaring the session ended or automatically rewatching, then click the rendered `retry_chat_stream` Retry control to adopt a second authoritative snapshot and newer delta.
Worker-death coverage exposes, monitors and kills the real blocked registration worker, awaits its DOWN and verifies Retry creates a replacement worker.
Consumer/worker teardown is monitored before restoring app-global seams; these mounted contracts belong to the sibling suite, not the async support units here.

### Push-only delta streaming coverage
`delta_test.exs` pins the pure reducer `EvoDashWeb.HomeLive.Delta` (`new/3`, `seed/3`, `apply_batch/5`), including text/thinking/tool/turn/yield/finished folding, the 8 000-grapheme and 40-thought caps, and malformed-batch totality.
Continuous multi-batch tests pass the complete prior reducer result, preserving call identity, accumulated thinking, turn/meta state and streamed-text flags rather than reconstructing `Delta.new/3`.
Whole `%{phase:, current_call:}` projections use the production call shape (`id`, `turn`, `attempt`, `text`, `thinking`) and pin captured-prefix hydration followed by append-only chunks, same-call replacement across completion/tools phases, reasoning timestamp retention and explicit thinking clearing.
Retry regressions pin removal of only the failed attempt's bubble and reasoning while retaining prior completed content, fresh waiting-attempt state, and replacement by a new same-turn call id even when the captured content is identical.
New-turn identities preserve distinct answers and reasoning even with identical content, and completion/yield/idle retirement retains exactly one finalized answer with its reasoning while ignoring stray chunks after retirement.
Thinking-only/no-call phases never fabricate answer text, and invalid phases or malformed call identities leave the entire active surface unchanged.
Legacy chunk-only fixtures retain turn-bucket reasoning and tool-row behavior as compatibility coverage rather than claiming to model current activity-owned call identities.
Snapshot fixtures here assert seq and turn only; unconditional pre-watch capture, default watch lifecycle, actual SSE producer compatibility and mounted rendering remain integration concerns rather than contracts established by this pure suite.
There is no helper-level `Watch` lifecycle or real-session snapshot integration suite in this directory; those require the mounted or core-owned test boundary, not an async helper test that starts an unisolated session.
The sibling mounted suite's private `seed_scripted_session!/3` uses `HomeLiveTest.ScriptedAgent` and per-session `:llm_call`/`:tool_batch` replacements for checkpoint/history regressions, not real ReqLLM SSE producer compatibility.
Real producer compatibility is covered by seven synchronous cases in `../real_stream_consumers_test.exs`, using actual SelfReflective Sessions, default attach/watch registration and a file-local gated loopback SSE provider decoded by ReqLLM, with no fabricated snapshots/deltas or `llm_call` overrides.
Assistant scenarios cover unwatched-prefix capture, late attachment, yield, first mount after yield, actual unmount/remount, same-session follow-up and two completed answers with thinking scoped to each answer and no stale streaming caret.
The same suite covers inspector retirement/checkpoint reconciliation, real read-tool success/error, HTTP 503 retry identities and truncated-stream retries clearing abandoned text/thinking.
Its snapshot predicates establish pre-watch capture and idle retirement, and monitored teardown drains mounted consumers, watch workers, Session/exchange/provider descendants and the TCP fixture before restoring scheduler pools and shared chat state.
Mounted assertions use finalized answer copy payloads and per-message Thought process disclosures rather than transcript ids, which are regenerated on history rebuild.
The `describe "push-only delta streaming"` block of `../home_live_test.exs` mounts `/assistant?session=<id>`, drives the call-time `:home_agent_watch_runner` / `:home_agent_unwatch_runner` seams and broadcasts `{:agent_delta, agent_id, seq, batch}` on `"agent:<id>"`, pinning that the LiveView process itself subscribes and applies a published batch, that `seq <= snapshot.seq` batches are dropped through `EvoGit.Agent.Stream.stale?/2` while a newer seq applies, that another agent's delta is dropped, that the attach snapshot seeds the transcript and thought process, that thinking/tool/turn deltas reach both surfaces, that `:yield` parks the session and `:finished` ends it, that a watched session keeps `chat_fetch_seq` unchanged on a `{:agent_updated, …}` message-count change, and that New chat detaches through the unwatch runner.
The page boundary is `EvoDashWeb.HomeLive.Watch` over `EvoDash.NodeContext.subscribe_agent_deltas/1`, `unsubscribe_agent_deltas/1`, `register_agent_watcher/3` and `unregister_agent_watcher/3`.
Independent `{:chat_history_loaded, node, history_seq, agent_id, stream_attach_seq, messages}` fixtures carry both generations and agent identity, with mounted rejection assertions for unscoped, stale-history, wrong-agent, obsolete-watch and foreign-node replies.
Snapshot-ready coverage atomically captures checkpoint history plus the current call's prefix and replays a buffered suffix exactly once, rather than preserving an arbitrary pre-watch bubble.
The silent-finished regression remains an unresolved source blocker: after a finished delta with no streamed text, the consumer must request exactly one authoritative final Watch snapshot, never substitute an independent legacy history read.
The mounted regression asserts that atomic reconciliation and is not a passing-coverage claim.
