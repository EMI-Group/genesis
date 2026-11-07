# HomeLive — Genesis Assistant Chat

## Intent

This directory contains the presentation and support modules for `EvoDashWeb.HomeLive` at `GET /help`.
The page is the Genesis Assistant: a general-purpose agent that understands Genesis and operates it (answering questions, inspecting runtime state, starting and controlling tasks, guiding the user through the dashboard), reachable from the sidebar **Assistant** entry.
The parent `home_live.ex` owns LiveView wiring, socket mutations, task execution, persistence, and async stale guards.
The chat starts repo-less `:reflect` tasks through `EvoDash.NodeContext`, streams agent history, and finalizes from the task's terminal result.

## Routing Table

This is a leaf node with no child directories.
The parent page lives at `../home_live.ex` and the read-only sibling tests live under `apps/evo_dash/test/evo_dash_web/live/home_live/` and `home_live_test.exs`.
Shared tool rendering belongs to `../agents_live/tool_call_display.ex`, shared status presentation to `../../helpers.ex`, and safe Markdown rendering to `EvoDash.MarkdownRender`.

## API Surface

### Presentation

`ChatMessages.empty_state/1` renders a sparkles icon, the greeting "What would you like Genesis to do?", the subtitle "Start a conversation", and four neutral suggestion buttons in a responsive one/two-column grid.
The exact English suggestion labels and submitted prompts are "Show my running tasks", "Check system status and capacity", "Start a task for me", and "Explain how tasks are scheduled", all translated with Gettext.
Every suggestion reads as a natural operator request, so two of them explicitly ask to inspect live runtime state or to start work.
The buttons retain `phx-click="send_message"` and translated `phx-value-message` values, dispatching through the exact same send path as typed input.
Its `source_gate?` attr defaults to false and replaces all suggestion buttons with download guidance when true.
The empty state uses `min-h-full` and vertical padding rather than a fixed height so short screens can scroll.
`ChatMessages.message_list/1` renders oldest-first transcript entries with stable `chat-entry-<id>` wrappers and responsive spacing.
User wrappers remain `flex justify-end` around a direct bubble div; assistant/error wrappers are left-aligned.
Only the last assistant entry receives `chat_task_status` and `thought_process`, while every assistant entry receives its own raw-view flag.
`UserMessage.user_message/1` is the single bubble implementation for typed and suggestion sends, with content-fit `w-fit`, responsive max-width, neutral `bg-base-200`, left-aligned escaped text, and no shadow.

`AssistantMessage.assistant_message/1` prioritizes the answer over task chrome: a circular primary-colored sparkles avatar beside a borderless, shadowless, min-width-zero content column whose content is preceded by a small bold Gettext-wrapped `Genesis Assistant` name label placed outside `group/assistant`.
The optional status row keeps the localized Task label as quiet sentence-case metadata plus the shared status badge, ping dots for running/cancelling, and spinner for finalizing.
Status colors come only from `Helpers.task_status_badge/1` and `task_status_dot_class/1`, not a status-colored card frame.
Empty streaming entries keep the three animated dots, nonempty streaming entries keep escaped raw text with `help-caret`, and neither renders action buttons or Markdown.
Finalized text uses the safe `EvoDash.MarkdownRender.render/1` inside `.md-content`, or escaped plain text when `raw` is true.
The finalized raw/copy toolbar is a normal-flow footer AFTER the body and optional thought disclosure, never absolutely positioned over text.
Its actions are visible by default on mobile and non-hover devices, subdued with `sm:opacity-0` on desktop, and revealed by both `group-hover/assistant` and `group-focus-within/assistant`.
Buttons provide explicit focus-visible outlines, 44px touch targets on small screens and 32px targets on larger screens.
The raw toggle retains `toggle_assistant_raw`, `phx-value-id`, localized title/aria labels, and its code/document icon swap.
The copy button retains stable `assistant-copy-<id>`, `ClipboardCopy`, escaped `data-content` containing the FULL source, and the existing copied-event protocol.
The named `group/assistant` stays separate from the nested thought disclosure's `group` so its chevron responds only to its own open state.
Thought process is a closed-by-default native `details` with a quiet, keyboard-focusable summary and count, no heavy top divider, and an inset left rule when opened.
Thought-entry headers use neutral metadata text; shared tool-result palettes and tool-call rendering remain intact.
Thought entries retain type/turn/time, reasoning details, content/tool result panels and `AgentsLive.ToolCallDisplay.display/1`, with `max-h-32 overflow-y-auto` visual scrolling rather than payload truncation for reasoning/content/results.
Structured tool-call values render full escaped prewrapped text, but nonstructured calls use a single-line CSS `truncate` summary with no expansion control in this component.

`ApprovalCard.approval_card/1` consumes atom-keyed requests and an optional `busy` boolean, default false, which disables both decision buttons while a response is in flight.
Evaluator requests use the core metadata `kind: :elixir_eval`, `tier: :write | :sudo`, exact original `code`, atom `target_node`, and `warning` (nil for write, an explicit warning for sudo), while retaining legacy command/args/level fields.
Write cards say "Allow once" and show the full escaped, whitespace-preserved original code in a scrollable `pre code` block plus the exact target runtime, with no source truncation or rewriting.
Sudo cards have prominent error styling and unrestricted ordinary Elixir wording covering live processes, files and configuration, no rollback, and explicitly not OS root; a supplied backend warning is also displayed as escaped text.
Legacy requests preserve the informational level-2 and task-side-effect danger level-3 wording, badge classes, escaped command/args, and Confirm/Deny labels.
Payload access is total even for nil/nonmap requests; string-keyed fields are not read and nonbinary text becomes empty text.
Both decisions retain `approval_response`, `request_id`, and `decision` (`approve` or `deny`); no code, tier, execution mode, or session consent is returned from the browser.
The parent owns composer/Stop behavior and delegates approval recovery and responses to `ApprovalWorkflow`, retaining cards on response failure.

### Approval recovery and response workflow

`ApprovalWorkflow` is the socket state machine integrated by the parent page, with `init/1`, `recover/1`, `requested/2`, `resolved/2,3`, `respond/3`, `recovered/3`, `responded/3`, `busy?/2`, and the shared total `own_request?/2` predicate.
`init/1` clears cards, recovery state, response tokens and errors on mount or chat/node reset, invalidating outstanding work without resetting any global sequence.
`recover/1` starts a one-shot supervised snapshot read for a chat with usable task/agent refs and a resolved node; the parent invokes it only on connected sockets after subscribing/restoring refs, after root lookup changes the scope, and on an explicit retry or reconnect, never on a timer.
The actual core API is `EvoGit.CommandApproval.pending/0`, returning public request maps with `request_id`, source `node`, task/agent ids and evaluator metadata, or `[]` when the service is unavailable.
The default pending runner calls `EvoDash.NodeContext.call_remote(chat_node, EvoGit.CommandApproval, :pending, [])` off-process and unwraps its `{:ok, list}` result; no new NodeContext or RemoteAPI pending method is assumed.
Recovery routes by source/chat node, not the evaluator's `target_node`, and transport/API failures preserve existing cards while assigning `approval_error: {:recovery, reason}`.
`requested/2` accepts only nonblank ids belonging to the chat's task OR string/integer-normalized agent id and matching source node; legacy missing-node requests remain accepted, but evaluator requests require a matching node stamp.
A pending remote context whose viewed node has fallen back to local cannot recover or respond against the local approval service.
`respond/3` accepts only a currently pending, owned request id and a string decision in `approve`/`deny`, routes through the existing `NodeContext.approval_response/3`, and leaves the card visible while marking that id busy.
Response success and backend `{:error, :not_found}` remove the card; response failure clears busy state, retains the card, and assigns `approval_error: {:response, request_id, reason}` for a translated parent retry/error surface.
`resolved/3` accepts a stamped source node only when the chat scope is usable and that node matches the chat's source, never the evaluator target, then delegates to `resolved/2`.
`resolved/2` handles legacy unstamped resolutions and acknowledged responses by dropping the card and its in-flight response token and recording an in-flight-recovery tombstone, preventing a late snapshot from resurrecting it.
A successful snapshot replaces pre-existing idle cards, removes stale idle entries absent from the backend, and merges newer requests received while the snapshot was loading.
Cards with in-flight responses survive snapshot omission until the responder acknowledgement or an explicit resolution settles them, so a backend-consumed request cannot disappear before a response failure is reported.
The parent routes source-stamped four-element `{:approval_resolved, id, decision, source_node}` messages to `resolved(socket, id, source_node)` and retains the legacy three-element route.
SafeCall messages are nested: `{{:approval_pending_loaded, seq, scope}, result}` goes to `recovered(socket, tag, result)`, and `{{:approval_workflow_response, seq, scope, request_id}, result}` goes to `responded(socket, tag, result)`.
Scope includes chat id, viewed node id/node, chat node, task id and agent id; unique monotonic tokens plus scope equality reject late results after resets, node switches, newer loads or newer responses.
Task-supervisor startup failures are sent through the same result path, so loading/busy state cannot wedge.
Runners are captured at spawn time through `:approval_pending_runner` (one node argument, list or error result) and existing `:approval_responder` (node/id/decision), allowing bounded deterministic tests without real SSH or evaluation.
The parent delegates both approval broadcasts and response events to this workflow, passes `busy={ApprovalWorkflow.busy?(assigns, request.request_id)}` to each card, and renders `approval_error` with Gettext-wrapped recovery/response retry guidance.
No approval state or sequence belongs in persisted `ChatState`; recovery reconstructs cards from the live core service.

`SourceGate.source_gate/1` renders the local-only source-download banner with stable ids `genesis-source-gate` and `genesis-source-download`, `download_source`, a disabled/busy cloning state, and a node-aware System link.
`SourceGate.visible?/1` permits only nil/local nodes and `blocked?/1` blocks only a known `source_available == false`, never unknown or backend-unavailable results.
`spawn_availability_check/3` and `spawn_clone/2` capture `:source_availability_runner` and shared `:source_clone_runner` at spawn time before starting supervised tasks, then invoke the runners inside `EvoDash.SafeCall` so every runner outcome sends a result message.
The messages are `{:source_availability_loaded, seq, node, result}` and `{:source_clone_result, node, result}`; default implementations delegate to the total `EvoDash.SourceStatus` wrapper, never directly to the optional core backend.
Availability failures degrade to `{:unavailable, :runner_error}`; clone failures become error values so loading flags cannot wedge.

### Transcript and stream helpers

`Transcript` owns oldest-first normalized entries `%{id, role: :user | :assistant | :error, text, streaming}` and total append, streaming replacement, finalization, and error helpers.
`normalize/1` drops non-map entries and whitelists roles, but its text coercion assumes `String.Chars` support for non-binary values.
`build_preamble/2` skips errors, pairs adjacent user/assistant entries or keeps standalone entries as blocks, keeps the last eight blocks by default, truncates each entry to 600 graphemes, and truncates the whole "Previous conversation:" preamble to 4000 graphemes.
Each truncation appends an ellipsis beyond its limit, so the actual maximum preamble length is 4001 graphemes, not a token or byte budget.
The final truncation keeps the beginning of those retained blocks, so a full budget can cut off the most recent retained exchange rather than the oldest.
Only role-labelled bubble text enters the preamble, not thought-process tool results, reasoning details, approvals, or structured task references.
Transcript append/restore, `Messages.to_entries/1`, and persisted `thought_process` have no per-chat count or byte cap in these support modules; the thought panels' `max-h-32` limits visual height only.
`Transcript.normalize/1` is not fully total despite its documentation: non-binary text uses `to_string/1`, which can raise for maps or tuples without `String.Chars` support.
`Messages.assistant_text/1`, `message_text/1`, and `to_entries/1` are total converters over native ReqLLM history and malformed RPC payloads.
Text extraction uses `EvoDashWeb.ContentText.text_of/1` so explicit thinking/media parts never leak into the assistant response; reasoning remains in `reasoning_details` for the thought disclosure.
`AgentStream` provides root-agent lookup, message-count gating, task-id extraction from a bare map or `{:ok, map}`, final-result extraction, and total structured failure-message extraction.
`extract_failed_message/1` accepts atom/string message keys and returns only a nonblank binary, preserving its original whitespace.

### Persisted chat and model choice

`ChatState.build/1` and `restore/1` own the map stored in the local in-memory `EvoDash.ChatHistory`, preserving transcript, statuses, refs, message count, thought process and chat node.
Selection fields are `model_spec` (a string-keyed map or nil), `model_selection_scope` (`{current_node_id, current_node || node()}`), and `model_selection_error` (nil or `:invalid_model_spec`); they are persisted when the parent seeds either new selection field.
The only accepted spec keys are `"provider_profile_id"`, `"model"` and `"reasoning_effort"`, with binary values; malformed explicit data becomes a sticky error rather than silent Auto, while partial provider/model drafts remain intact for shared validation.
`selected_model_id` remains legacy migration input only, is discarded when an explicit spec is present, and is never emitted by the new task-option boundary.
`ChatState.restore_selection/2` runs after node resolution: same-scope selection survives New chat, a different scope clears to an uninitialized nil spec, and unscoped legacy ids migrate only on the local scope.
The shared helper reconciles nil to the viewed node's configured default, an empty map is explicit Auto, and false is malformed rather than Auto.
A canonical spec, including the empty Auto map, removes `selected_model_id` during build/restore so an old pin cannot reappear after reconciliation.
A scope includes the remote target id even while its node resolves locally, preventing a disconnected target from borrowing the local pin.
Runtime seq counters, loaded configs, raw-view ids, approvals and source-gate state are never persisted.
`ModelSelect.load/1` returns `{:ok, %{node: node, config: resolved_config, model_selection_enabled: boolean}}` or an error; nil normalizes to local.
Invalid nonatom or boolean nodes return `:invalid_model_selection_node`, and a remote success with a nonmap config returns `:invalid_model_config_response` rather than becoming a usable snapshot.
The config snapshot is the full server-only resolved config, not a persisted task selection or browser payload.
The remote script predicate is read through `NodeContext.call_remote/4` against `EvoGit.CustomAgents.ModelSelector.enabled?/0`, not `list_custom_agents/1`, whose client wrapper masks transport failures as successful empty data.
Loaded configs are ephemeral and may contain authentication settings, so they must never enter ChatHistory or rendered attributes.
Remote loads remain supervised `SafeCall.start/4` work with nested result tags and independent monotonic `model_select_seq` plus node stale guards; the parent rejects pending remote targets before attempting a load or send.
`ModelSelect.task_opts(snapshot, selection_state, scope, opts \\ [])` requires a matching snapshot node and persisted selection scope, rejects malformed state and pending-remote fallback-local sends, and calls parent-owned `EvoDashWeb.LLMSelection.task_opts/3` directly.
A launch scope is exactly `{nil, node()}` locally or a nonblank target id paired with a nonlocal node atom remotely; nil/nonatom/boolean nodes and remote snapshots without a target id are rejected even for Auto.
ChatState's shape validation also rejects boolean node values rather than retaining them as valid persisted scopes.
Only a nil spec may fall back to the legacy migration id; false and other malformed non-nil values reach shared validation unchanged rather than silently becoming Auto or a default.
The shared helper contract is `task_opts(config, spec_or_legacy_id, opts) -> {:ok, keyword} | {:error, reason}`: resolve through core `Schema.resolve_model_spec/2`, validate canonical selections, resolve the default reasoning effort before submit, emit string-keyed `:model_spec` plus `model_id_locked: true` for explicit choice, strip model_spec/model_id/model_id_locked for Auto, and reject stale profiles/models/efforts rather than silently choosing Auto.
Core `resolved.model_spec` is a ReqLLM-ready string or endpoint-override map, NOT the persisted task selection map.
The shared helper reconstructs only provider_profile_id/model/reasoning_effort from the resolved top-level fields; generation_params, runtime_profile and provider_profile can contain credentials and never belong in picker state, browser data or ChatHistory.
Provider/model event transitions and reasoning-slider conversion belong in the shared parent helper and `LLMSelectionComponents.resolve_reasoning_effort/3`, not duplicated in Assistant code.
The core projection contract is `Schema.provider_profiles(config)` string maps and `Schema.model_selections(config)` ordered atom maps containing provider_profile_id/profile_name/provider/model/reasoning_efforts/default_reasoning_effort/context_window.
The parent seeds the selection fields, projects loaded snapshots with `LLMSelection.from_config/2`, renders `LLMSelectionComponents` with provider/model/reasoning events, reconciles migration/defaults and clears the legacy id, and handles task-option errors before appending bubbles or clearing drafts.
`handle_params/3` restores selection scope before resetting a cross-node chat; `reset_chat/1` clears transcript/runtime refs without clearing the already-scoped selection, so same-scope New chat keeps the choice.
Config snapshots and loaded bundles remain ephemeral server-only assigns and are never persisted by `ChatState`.
`Transcript.normalize/1` reconstructs only id/role/text/streaming, so selection metadata never enters the next task's textual preamble.
State and transcript restoration expect atom-keyed outer maps rather than JSON string-keyed state.

## Constraints

All user-facing strings are Gettext-wrapped, with Chinese meaning comments where useful; never modify PO/POT files during feature work.
Use existing Tailwind/DaisyUI tokens and HEEx, with no new CSS dependency and no hardcoded theme colors.
Preserve stable DOM ids, event names, hooks, escaped raw text, safe Markdown, streaming behavior, approvals and source-download semantics when changing presentation.
The parent owns all business state and uses `EvoDash.NodeContext` for node-aware operations; no support component should introduce store or RPC calls on the render path.
Store/RPC calls use `EvoDash.SafeCall` either as guarded click mutations or supervised async tasks, never bare try/rescue.
`SafeCall.start/4` sends nested tags verbatim: `{:tag, seq, node}` arrives as `{{:tag, seq, node}, result}`.
There is no polling; refreshes follow user actions or node-filtered PubSub events.
Keep agent-history `chat_fetch_seq`, terminal-task `chat_task_fetch_seq`, source `source_check_seq`, and remote model `model_select_seq` separate so late history updates cannot discard terminal results.
Real agent changed_fields payloads are keyword lists and history refetches require `is_list(changed_fields) and Keyword.has_key?(changed_fields, :message_count)`.
Terminal completed/cancelled/failed tasks finalize from the lite task read; live or unknown statuses must retain task refs rather than finalize.
Chat persistence is local-node-only and in-memory; remount reconciliation is one-shot, New chat retains old chats with a cap of ten, and tests touching it reset the shared ChatHistory store.

## Verification

Run `mix test apps/evo_dash/test/evo_dash_web/live/home_live apps/evo_dash/test/evo_dash_web/live/home_live_test.exs` for scoped coverage.
Sibling test changes require the parent agent; approval feature coverage belongs in new async component/workflow modules, with synchronous tests only where an app-env runner or the singleton CommandApproval service is mutated.
Approval tests should pin write/sudo wording, full escaped code and target, nil warning, explicit sudo warning, legacy presentation, busy buttons, pending recovery via the actual public API, task/agent/source-node filters, disconnected remote guards, stale seq/scope rejection, snapshot/broadcast races, absent-card submission rejection and retained cards on responder failure.
Parent integration tests must assert retained cards while responding and reject responses for nonpending ids, rather than expecting optimistic removal.
Normal Mix startup supports canonical providers: core exports `Schema.provider_profiles/1`, `model_selections/1`, `resolve_model_spec/2` and validates the `:provider_profiles` descriptor without a facade shim or validation bypass.
`model_select_test.exs` and `chat_state_test.exs` pin canonical defaults, inventories, explicit Auto, false/sticky errors, whole legacy ids, secret-free task opts, scope rejection and string-spec persistence.
The two local-load fixtures in `model_select_test.exs` write config.toml and agents.toml to the wrong directory: `EvoDash.Test.ConfigDir.isolate!/1` returns the override ROOT, while `Platform.config_dir/0` appends `/genesis`.
Those fixtures must create/use `EvoGit.Config.config_dir/0`, write config via `Config.config_path/0`, and write agents.toml inside that actual config directory; production `ModelSelect.load/1` must not read the override root as a fallback.
Mounted explicit-pin sends require the app-global TaskRegistry admission process to see the same config as the LiveView; a per-test `$callers` directory override does not reach a singleton booted before the test.
The three mounted canonical-send tests currently find no task because that registry resolves its own empty config and rejects the account before enqueueing; the test harness must align singleton config without removing admission or weakening the stored-options assertions.
Core Store.Codec atomizes the outer model_spec key while keeping model_id_locked string-keyed, so `HomeLiveTest.assert_task_selection/2` must read `:model_spec` and `"model_id_locked"` instead of its stale string-only spec assertion once admission fixtures are aligned.
Additional sibling regressions should cover nonatom/nil-node scopes, unscoped remote snapshots and invalid load-node arguments.
Keep business assertions for four suggestion sends, source gate, direct user bubble shape, raw/copy attributes, safe Markdown and streaming markers intact.
No sibling tests are modified by helper-only work; persistent additions and mounted event/send/persistence coverage belong to the parent integration.

### Parent-page integration requirements

The shared picker renders individual phx-change inputs that require a caller-owned form; HomeLive currently puts its header fieldset outside any form, and direct `render_change(view, event, params)` tests do not exercise native browser form wiring.
Wrap the header picker in a separate form (never the composer or a nested form) while retaining provider/model/reasoning event names and zero-based slider decoding through `LLMSelection.select_reasoning_effort/3`.
Provider/model transitions, canonical reconstruction and strict pre-send validation already delegate to the shared helper; do not replace them with resolved.model_spec or raw generation_params.
`assign_model_select/1` must handle `SafeCall.start/4` returning `{:error, reason}` immediately, clearing model_select_loading and setting a retryable load error, because failed task startup sends no result message.
Successful async loads still arrive as `{{:model_select_loaded, seq, target_node}, {:ok, snapshot_result}}`; the existing seq/node/pending guards reject stale target results, including two target ids sharing one BEAM node.
A reload invalidates the snapshot and bundle before starting work; do not preserve a previous node's credentials or silently convert a failed load to Auto.
