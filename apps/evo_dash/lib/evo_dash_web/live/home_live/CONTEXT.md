# HomeLive — Genesis Assistant (`/assistant`)

## Intent

Genesis Assistant chat page (`EvoDashWeb.HomeLive`, `GET /assistant`, sidebar **Assistant**); `/help` 302-redirects here via `EvoDashWeb.RedirectController`, query preserved.
A conversation is ONE long-lived interactive agent session (one agent id, one worktree, one `prompt_cache_key`); the agent id IS its address: `/assistant?session=<agent_id>`.
Sessions are repo-less (`repo_less: true`, `agent_module: EvoGit.Agents.SelfReflective`): no worktree, no git op, no subagents.
When the node cannot run interactive sessions the page falls back to one-shot `:reflect` task-per-message mode (`session_mode: :one_shot`) with a gettext notice.

## Routing Table

Each entry names the module's load-bearing API only — the module itself is the full inventory; scenario detail belongs to its owning child CONTEXT.md (`live/CONTEXT.md`, `lib/evo_dash/CONTEXT.md`, `components/CONTEXT.md`, `assets/js/hooks/CONTEXT.md`, `assets/css/CONTEXT.md`, `apps/evo_dash/test/evo_dash_web/live/home_live/CONTEXT.md`).

- `home_live.ex` (one directory up) → `EvoDashWeb.HomeLive` — ROUTER only: `mount/3`, `handle_params/3` → `SessionResolution.run/2`, one-expression `handle_event/3`/`handle_info/2`, `render/1`, `terminate/2` → `Watch.detach/1`, the five `SendPath` hand-offs (`maybe_recover_approvals/1`, `spawn_attach/2`, `attach_stream/1`, `maybe_load_sessions/1`, `async_lookup_agent/1,2`).
- `chat_bootstrap.ex` → mount assigns (`base_assigns/0`, `init/1`), chat scope (`reset_chat/1`, `new_chat/1`, `restore_status/1`), loader guards `stale?/3` (node + `chat_fetch_seq`) / `stale_control?/3` (node + `stop_seq`).
- `session_resolution.ex` → `run/2`, the whole `handle_params/3` pipeline: node → attach chat → selection → new chat on a node/chat-node/selection-scope mismatch → `?session=` → workspace scope → `?wb_draft=` → persist → `ModelSelection.assign_model_select/1` → reconnect params → source check → approval recovery → `TaskTracking.refresh/1` (+ `workspace_loaded/6`, `restore_attached_context/2`).
- `attach_pipeline.ex` → attach/history/agent-lookup/task loaders and their socket-first `handle_info/2` (`apply_attach/2`, `apply_history/3`).
- `attachment_pipeline.ex` → composer attachment events (upload validate/cancel, picker + manual path, chip removal, `{:directory_picker_result, …}`), socket-first `handle_info/2`.
- `stream_fold.ex` → watch lifecycle (`attach_stream/1`, `apply_watch_result/1`, phase/outcome folding, terminal handoff, failure, `finalize_bubble/1`), socket-first `handle_info/2`.
- `task_events.ex` → `"tasks"`/`"agents"` folds, follow/action/picker results, `node_aware_reload_tasks/1`, stop/cancel controls (`stop_reply/1`, `chat_stop_result/2`, `chat_finish_result/2`).
- `approval_dialog_state.ex` → `ApprovalWorkflow` wired into the page (scope-keyed recovery, arrivals/resolutions, decisions, dialog state, `approval_strip_open?/1`).
- `workbench_scope.ex` → workspace picker events, model/reasoning selection + snapshot result, `{:node_selected, …}` / `{:remote_connection_status, …}`, source check/download.
- `session_actions.ex` → the ONLY module talking to the session RPCs: `url/2`, `parse_session/1`, `session_opts/2`, `start/2`, `send_message/6`, `close/3`, `load_attach/2`, `list/1`, `session_unavailable?/1`.
- `session_list.ex` → the BODY of the sidebar **Conversations** section (`load/1`, `build_rows/3`, `spawn_load/2`, `applied/4`, `session_list/1`); the layout owns the header.
- `send_path.ex` → send pipeline + finalize block (`send_draft/3`, `dispatch_send/5`, `apply_send_result/3`, `start_session_chat/4`, `queue_session_message/4`, `restore_send/2`, `finalize_terminal/2`, `finalize_completed/2`, `finalize_failed/2`).
- `composer.ex` → `composer/1` card (textarea, chips + attach menu, model capsule, Send/Stop), `interrupt_button/1`; `compose_disabled?/1` / `send_blocked?/1` own the disabled states.
- `attachments.ex` / `uploads.ex` → staging, caps, `to_message/2`, `describe_error/2`; native browser upload validation/progress/`cancel_all/1`.
- `transcript.ex` → transcript model, normalization/caps, streaming bubbles (`append_streaming_text/2`, `close_streaming/1`), `tool_entry/4`, `put_reasoning/3`.
- `delta.ex` → PURE, TOTAL delta reducer (`new/3`, `seed/3`, `meta/0`, `apply_batch/5`).
- `live_call.ex` → call-id-keyed projection of `:activity` replacements and appended chunks.
- `watch.ex` → consumer-local subscription + one consumer-monitored serial worker: `ready/5`, `push/4`, `closed/4`, `snapshot_result/3`, `stream_active?/1`, `closed?/1`, `failure/1`, `detach/1`.
- `chat_state.ex` → persisted per-chat shape (`build/1`, `persist/1,2`, `restore/1`, `draft_key/1`, `signature/1`, `write_state?/3`, `mark_write/2`) over `EvoDash.ChatHistory`.
- `workspace.ex` / `workspace_component.ex` → selection map, VCT-token draft scope, async loads (`select_mounted/2`, `draft_project/1`, `draft_scope/1`, `apply_result/6`, `normalize/1`, `locked?/1`, `adopt_workbench_scope/1`) + the picker panel.
- `messages.ex` / `display_messages.ex` → `message_text/1` (thinking excluded), `to_entries/1`, the ONE `transcript/1` builder; bubble projection (`bubbles/1`, `user_authored?/1`).
- `agent_stream.ex` → root-agent lookup, `message_count/1` gating, final/failed text extraction, `task_id_from_start/1`.
- `model_select.ex` / `model_selection.ex` → snapshot loading (`load/1`, `task_opts/4`) + canonical selection state (`selection_scope/1`, `pending_remote?/1`, `assign_model_select/1`).
- `approval_workflow.ex` / `approval_dialog.ex` → ephemeral request state, session scoping, off-process recovery, response routing; then the two purely presentational surfaces (`approval_bar/1`, `approval_dialog/1`).
- `assistant_message.ex` / `user_message.ex` / `chat_messages.ex` → chat surface rendering (`empty_state/1`, `session_ended_state/1`, `quick_actions/1`, `message_list/1`).
- `execution_indicator.ex` → `execution_indicator/1` + pure `state/1` / `tool_state/1`.
- `task_tracking.ex` / `task_card.ex` / `task_picker.ex` → followed-task links, action reconciliation, rendering.
- `source_gate.ex` → `SourceGate` (`visible?/1`, `blocked?/1`, `spawn_availability_check/3`, `spawn_clone/3`).

## Module shape (page router + support modules)

`EvoDashWeb.HomeLive` is the ROUTER only (entry points, one-expression clauses, hand-offs); behaviour lives in the support modules.
`AttachPipeline`, `AttachmentPipeline` and `StreamFold` expose `handle_info(socket, msg)` (socket FIRST, so the page forwards the raw self-message); every other module exposes named handlers returning `{:noreply, socket}`.
Delegation is one-directional (no support module calls `EvoDashWeb.HomeLive`); support modules call each other directly, and the only module state is `ChatState`'s per-process write markers.

## Session model

`session_id` (the session agent id) lives in the URL (`?session=<agent_id>`) and is authoritative in `handle_params/3`: every param change re-resolves it, and a MISSING `session` param means the local draft / new-chat state.
URLs are built ONLY through the pure `SessionActions.url/2` → `/assistant`, `/assistant?session=<id>`, `/assistant?node=<node>`, `/assistant?session=<id>&node=<node>` (session first, node appended with `&`, invalid id omitted); navigation is ALWAYS `push_patch`, never `push_navigate`, so the LiveView process and its transcript survive.
`SessionActions.parse_session/1` is `Integer.parse/1` + a positive guard — no atom conversion, no `String.to_integer/1` rescue.
`session_mode` is `:interactive`, `:one_shot` (the `:reflect` fallback) or `nil` (fresh draft); the agent id is a positive integer, so it doubles as the `EvoDash.ChatHistory` chat id with no synthetic mapping.
Phases (`:starting | :running | :awaiting_input | :cancelling | :finalizing | :done`) map to `chat_status`: `:starting`/`:running` → `:running`, `:awaiting_input` → `:idle` (composer enabled), `:cancelling` → `:cancelling`, session gone / `:finished` → `:ended`.
`chat_task_status` is the DISPLAYED badge status: `:pending`/`:running`/`:finalizing`/`:cancelling`/`:completed`/`:failed`/`:cancelled`/`:paused`/`:pausing` plus `:awaiting_input`, so a restored idle session keeps its badge (unknown status → `nil`).
`EvoDash.NodeContext.close_session/3` is the only non-cancel way out of `:awaiting_input`.

## Send path

`send_chat/2` → `send_draft/3`, guards in order: `send_in_flight == true` → no-op (server backstop for the disabled Send), pending remote target → "connect first" flash, `session_attach_pending?` / `workspace_loading` → "wait for the project selection" flash, vanished draft project → flash; then `do_send_chat/3`.
`do_send_chat/3` trims, refuses a non-sendable status, an upload in progress, and an empty draft with no attachment, converts attachments via `Attachments.to_message/2`, resolves canonical model options through `ModelSelect.task_opts/4`, then dispatches.

| Situation | Action |
|-----------|--------|
| no session yet (`session_id == nil`, `chat_status == :idle`) | `SessionActions.start/2` with `session_opts/2` (`agent_module: EvoGit.Agents.SelfReflective`, `repo_less: true`, `objective:` = the text with NO preamble, `model_spec` only for an explicit canonical selection, non-empty `attachments`, `assistant_workspace`, `assistant_conversation_id`) → `{:ok, agent_id}` adopts it (chat id = agent id, `session_mode: :interactive`) + `push_patch` to `?session=<agent_id>` |
| session exists (`:idle` / `:running` / `:awaiting_input`) | `SessionActions.send_message/6` with text + attachments + policy — NO new task, NO new chat; with `:assistant_workspace` it routes through `NodeContext.send_message_with_workspace/5`, so a running exchange accepts only the SAME project and otherwise answers `{:error, :workspace_changed}` (flashed as a project-selection change, draft restored) |
| `{:error, {:session, :finished \| :not_found}}` on send | mark `:ended`, keep the cached transcript, flash "This conversation has ended…" with New chat |
| `start_session` unavailable / refuses interactive mode | fall back to `NodeContext.start_task(node, :reflect, mode: "reflect", objective: preamble <> "New message: " <> text, model_spec: …)`, set `session_mode: :one_shot`, show the one-shot notice; the optimistic user bubble is NOT duplicated (`start_chat/4`'s `user_appended?`) |

Reflect-fallback triggers (`SessionActions.session_unavailable?/1`): no session API, `:llm_not_configured`, `:session_api_unavailable`, and the refusals `{:interactive_root_only, _}`, `{:invalid_session_opts, _}`, `{:unsupported_session_mode, _}` (each also inside `{:start_session_failed, reason}`); transport errors (`{:erpc, :noconnection}`, `:timeout`) are NOT triggers — they flash and never silently change mode.
Any other start reason (`{:unexpected_start_result, other}`, `:unexpected_session_start`) rolls the optimistic bubble, draft and attachments back through `send_pending.prev` with "Failed to start the conversation: …" — no session adopted, mode unchanged; `{:unexpected_send_result, other}` plays the same role on the message path (`normalize_send/1`).
The core mints its own random-hex task id and never returns it, so the page resolves the session's task id afterwards from the agent summary (`list_agents/1` row `task_id`).

## Queue, interrupt and Stop

The composer stays usable while `chat_status == :running`; only `:cancelling`, `:ended`, a pending remote target, an in-flight send and an unready model block it.
`send_in_flight` / `send_seq` gate the controls: `send_blocked?/1` disables Send and the interrupt button, `send_draft/3` refuses the same state server-side, `apply_send_result/3` drops a result carrying an older `send_seq`.
Sending while running posts policy `:queue` and appends a transient QUEUED echo: `queued_echoes` holds `%{id, text, at}` (newest 20, ids via `System.unique_integer([:positive])`), rendered after the last transcript entry as gettext "Queued — sent at the next turn boundary"; an echo is NOT a fake assistant message and is reconciled away on a real `message_count` increase or on stop/close/session switch.
`Interrupt turn` (`#chat-interrupt-button`, only while `:running`, labelled "Send now (interrupt turn)", Chinese comment for the translator) posts `:interrupt`; **`:queue` and `:interrupt` are applied IDENTICALLY — both land at the next turn boundary**, so no copy may promise a chunk-level halt.
Stop is separate: `NodeContext.cancel_task/2` (graceful) on the session's task id, falling back to `SessionActions.close/3` when none is known, leaving the page `:cancelling` until the terminal event.
Echo exit ownership is split because two patches discard two nodes: each `#chat-queued-echo-<id>` ROW owns its exit (`JS.remove_class("motion-panel-open motion-panel-slide") |> JS.hide(transition: {"motion-exit-lift", "motion-exit-visible", "motion-exit-hidden"})`) for the one-echo-delivered case, while the `#chat-queued-echoes` WRAPPER (the node carrying `:if`) owns the list-became-empty fade — a descendant's `phx-remove` never runs when an ancestor unmounts.

## Reattach

`handle_params/3` with `?session=<id>` sets `session_id`, `current_session_id`, `chat_id = session_id`, `session_mode: :interactive`, clears per-chat refs (`chat_task_id`, `chat_task_status`, `agent_message_count`, echoes), and restores the cached transcript from `ChatHistory.get_state(session_id)` via `ChatState.restore/1` (total — garbage degrades to defaults).
`spawn_attach/2` takes watch ownership FIRST (`StreamFold.attach_stream/1`), then spawns ONE supervised task tagged `{{:session_attached, seq, node, session_id, stream_seq}, …}` gathering `list_agents/1` + `list_awaiting_input/1` + `get_agent_history/2`, returning `SessionActions.load_attach/2`'s bare `%{summary:, awaiting?:, history:}` (no `{:ok, _}` tag — `SafeCall.run/1` wraps it, hence `apply_attach/2` matching `{:ok, %{…}}`).
It applies only while `session_attach_seq` is current and node + `session_id` match; the captured `stream_seq` decides whether the attach surface applies (`apply_attach/2`) or only identity is taken.
A non-empty independent history replaces the cache through `Messages.transcript/1` only while no watch owns the surface; an EMPTY history never wipes a non-empty cached transcript (`apply_history/3` keeps it and its thought process, read-only); a first-ever attach with no cache keeps the empty transcript.
Session gone (no summary, not awaiting) with an empty cache → `#chat-session-ended`, disabled composer, New chat; with a cached transcript → read-only transcript + New chat; a history reply landing with no writer left (`chat_status` `:ended`/`:idle`) is finalized by `StreamFold.finalize_bubble/1`, never left `streaming: true`.
Reattach NEVER starts a task on read.

## Empty states (inside `#chat-messages`)

An EMPTY transcript renders exactly one of two states inside the scroller; a non-empty one always renders `message_list/1` regardless of status.
`ChatMessages.empty_state/1` is the greeting (`#assistant-welcome`: brand mark, "Turn ideas into working software") for a live/idle chat; `quick_actions/1` (`#assistant-quick-actions`) renders below the composer while `transcript == [] and chat_status != :ended`.
`ChatMessages.session_ended_state/1` (`#chat-session-ended`) is the ended state ("This session has ended.", "Start a new chat to continue.", `phx-click="new_chat"`), replacing the greeting because an ended session cannot send.
The render wrapper carries `.assistant-column.is-empty` under the same condition (centers the column; layout in `assets/css/assistant.css`).

## Conversation list (shared sidebar Conversations section)

No left rail: `SessionList.session_list/1` renders only the BODY of the shared app-layout sidebar's **Conversations** section, which `EvoDashWeb.Layouts.app` renders below Active Tasks on EVERY page; the page passes `session_list`, `session_list_loading`, `session_list_error`, `current_session_id` (and `current_page`).
Rows are the UNION of live root self-reflective agents parked at `:awaiting_input`/`:running` (`SessionActions.list/1` = `list_agents/1` + `list_awaiting_input/1`, read defensively through the call-time `:home_session_list_runner` seam) and cached `EvoDash.ChatHistory.list_chats/0` conversations; a live session wins over a cached chat with the same id (the agent id IS the chat id).
Rows are `%{id, title, marker}`, markers `:awaiting_input | :running | :ended`, ordered awaiting (newest id first), running (newest id first), then ended in cached order; `row_title/2` takes the cached first user message, else the core row's `objective`, else `gettext("Session %{id}")`, capped at 80 characters.
Load contract: `spawn_load/2` bumps `session_list_seq`, sets `session_list_loading: true`, clears the error and always reports `{{:session_list_loaded, seq, node}, result}` via `EvoDash.SafeCall.start/4` (supervisor-start failure → loading cleared + error recorded); `applied/4` applies only while BOTH seq and node match — success replaces rows, an error keeps them and records it, and any matching result clears the flag.
Rendering: `id="chat-session-list"`, "Loading…", a "Could not load conversations." alert, "No conversations yet." when empty, rows `id={"chat-session-#{id}"}`; on `current_page == :assistant` a row PATCHES via `SessionActions.url/2`, elsewhere it NAVIGATES (a cross-LiveView patch is illegal); the current row is highlighted from `current_session_id` with `aria-current="page"`, markers "Waiting for you" (`:awaiting_input`, violet), "Running" (running dot), "Ended" (muted).
The load OWNER is `EvoDashWeb.LiveHooks.NodeAware` (connected local mount, node-context change, `:node_aware_reload_tasks` debounce); the page refreshes locally only after adopting or closing a session and on `{:node_selected, _}` / `{:remote_connection_status, _, _}` — no polling.

## Approvals

`chat_agent_id` is the session agent id, `chat_task_id` the summary's `task_id` (legitimately `nil`), both set on adoption AND reattach.
`ApprovalWorkflow.init/1` + re-recovery run on every session switch (mount, reattach, adoption, new chat, close), so a previous session's requests never render; scope = `Map.take(assigns, [:chat_id, :current_node_id, :current_node, :chat_node, :chat_task_id, :chat_agent_id])`.
Requests are recovered from the core (`EvoGit.CommandApproval.pending/0` → `NodeContext.call_remote/4`), never persisted (ephemeral, outside `ChatState`), and answered through the `:approval_responder` seam (default `NodeContext.approval_response/3`); matching is by `agent_id` OR the scheduler-MINTED `task_id` with NO `tasks` row required (a repo-less session's task id comes from `SchedMeta`); recovery/auto-open/notification gates key on `chat_node` plus those ids only (`scoped?/1` accepts a usable `chat_agent_id` alone).
`ApprovalDialog` is purely presentational — decisions travel through `ApprovalWorkflow` as the request id plus a whitelisted `"approve"`/`"deny"`.
`approval_bar/1` renders `#approval-status-bar`: a FIXED-HEIGHT (`h-10 shrink-0`) strip directly above the composer, height reserved whether or not anything is pending (arrival/resolution never reflows the column), holding the pending count, a "Review" button (`open_approval_dialog`), `#approval-recovery-error` with "Retry approvals" (`retry_approvals`, disabled while recovering) and `#approval-response-error` (only without a recovery error), truncated to one line.
`approval_dialog/1` renders `<dialog id="approval-dialog" class="modal" phx-hook="DialogModal">` with ONE request, `prev_approval`/`next_approval` chevrons ("1 of N", disabled at the ends) and a Deny / Allow-once pair (`approval_response` with `phx-value-request_id`/`phx-value-decision`, both disabled while busy).
The page mounts it only under `:if={@approval_dialog_open}`, so the `<dialog>` IS the node a patch discards: it carries `phx-remove={JS.hide(transition: {"motion-exit-fade", "motion-exit-visible", "motion-exit-hidden"})}`, covering every SERVER-initiated removal (pending list emptying, session switch) and completing the hook's own `_hide()` fade (exit-recipe rationale: `live/CONTEXT.md`).
Tiers: evaluator requests show the exact original Elixir plus the target runtime (`target_text/1` reads the core-stamped `:target_node`; anything else → "Unknown target"), legacy command approvals show command + args, sudo/dangerous ones carry danger styling plus the sudo warning ("unrestricted Elixir — no rollback"); a request's OWN optional `:warning` renders for ANY tier in `#approval-request-warning` exactly once (text identical to the fixed sudo copy is never duplicated).
`approval_dialog_open`/`approval_dialog_index` are LOCAL VIEW state (never persisted, reset by `reset_chat/1`), kept sane by `pending_approvals/1`, `auto_open_approval_dialog/1`, `step_approval_dialog/2` (clamp then wrap), `clamp_dialog_index/2`; an empty list closes the dialog, and EVERY `pending_approvals` mutation (response success/not-found, recovery apply, either resolution broadcast) runs `sync_approval_dialog/1`.
Events: `open_approval_dialog`, `dialog_closed`, `prev_approval`, `next_approval`, `retry_approvals`, `approval_response`.
`ApprovalWorkflow.requested_with_notification/2` → `{socket, payload_or_nil}` is the live-arrival admission boundary: only a FIRST owned live arrival yields a privacy-safe payload (gettext `title`/`body`, `request_id`, opaque `scope`, request-scoped `tag` — never code, commands, credentials or targets); duplicates, recovered requests and resolved-id replays yield none.
`notification_host/1` → `%{scope:, request_ids:}` for the always-mounted `#assistant-notifications` wrapper (`data-approval-scope` / `data-approval-request-ids` via `Jason.encode!/1`; `notification_host_json/1` encodes the object) and the host supplies gettext `data-notification-label-{unsupported,denied,default,granted,requesting,error}` for all six browser states; the `BrowserNotifications` wrapper requires explicit `data-enable-notifications` opt-in and never requests permission itself.
`review_approval_notification` requires `%{request_id: string, scope: string}`: `dialog_index/3` validates the captured scope AND current pending ownership before selecting an index, nil is a no-op and `respond/3` is never called, and missing/malformed/stale scopes fail closed even when another chat reuses the id (`notification_scope?/2` supports browser reconciliation).
Review and dismissal confer no authorization: `respond/3` rechecks owned pending id, decision whitelist and busy state, resolved-id tombstones block snapshot/broadcast resurrection, and `{:approval_resolved, …}` re-syncs the index.
The dialog is accessibly named/described, initially focuses its static heading (`data-dialog-title`, `data-dialog-initial-focus`, never a decision button), returns focus to `approval-review-button`, and Close uses `data-dialog-dismiss` without `phx-click`/autofocus so the hook reports dismissal once; `approval_error` renders an honest retry message.
`approval_responses` maps request ids to response sequence tokens only: `responded/3` treats `{:ok, :ok}` as acknowledged and `{:ok, {:error, :not_found}}` as already resolved, and neither proves an approved evaluation ran (no request-id-to-tool-call correlation).
The live `Delta` tool-result projection gets only call id + coarse status (Running/Done/Failed/Timed out via `AssistantMessage.tool_entry/1`) and `Messages.transcript/1` omits raw tool messages, so complete result text lives only in checkpoint history's Thought process, and snapshot replacement can drop live informational tool rows.

## Execution presentation

`ExecutionIndicator.execution_indicator/1` takes `chat_status`, `chat_task_status`, `chat_stream`, `pending_approval_count`, sits beside the interrupt button in the fixed-height status row, and reads only `chat_stream.delta.activity.phase` and `chat_stream.error` — never answer/thinking text, tool args/results or approval acknowledgements.
Every core activity phase has its own busy/waiting projection, including the long non-call phases `:compressing` ("Compressing context…") and `:preparing` ("Preparing next turn…"), which must never fall through to the generic "Working…".
Lifecycle and watch errors outrank cached activity; absent activity means Working, a stream failure means Live updates unavailable (not execution failed), and unknown tool outcomes say Status unavailable (not Done).
`#assistant-execution-status` is a polite atomic phase-only live region while shared tool rows disable live announcements; both surfaces expose `.assistant-execution-indicator` / `.assistant-execution-dot` plus `data-state`/`data-busy`, adding no layout rows.
`state/1` / `tool_state/1` return `%{state:, label:, busy?:, tone:}`; busy means active processing, not waiting for a slot, approval or retry.

## Layout, scrolling & motion

The transcript column is layout-stable end to end: an assistant entry's action footer ALWAYS renders (buttons appear once finalized), and the interrupt affordance sits in a constant `h-7` row (hidden only for an empty transcript with no pending approvals) that also hosts `ExecutionIndicator.execution_indicator/1`, so nothing outside the scroller changes height mid-turn.
`#chat-messages` (`phx-hook="AgentHistoryAutoScroll"`, classes `assistant-messages scrollbar-thin`) is scrolled by that hook — instant, coalesced, NEVER animated: one `requestAnimationFrame` sets `scrollTop = scrollHeight`; "pinned" = within 56 px of the bottom (`shouldFollowLatest/4`, exported with `STICK_TO_BOTTOM_THRESHOLD_PX`); only user input re-evaluates the pin; a ResizeObserver + MutationObserver re-follow late layout, disconnected while unpinned and released in `destroyed()` (hook internals: `assets/js/hooks/CONTEXT.md`).
`assets/css/assistant.css` owns layout/overflow (`.assistant-messages`, `.assistant-column.is-empty`); `assets/css/app.css`'s `#chat-messages, .agent-history-scroll` block keeps `min-height: 0`, `overflow-anchor: none`, `overscroll-behavior: contain`, `scroll-behavior: auto` (load-bearing against `html { scroll-behavior: smooth }`).
`#assistant-notifications` is ALWAYS mounted and animates its own height with the shared helper (`motion-collapse-grid` + `data-motion-open={to_string(@approval_strip_open)}`, ONE child div carrying the `h-10` bar plus the notification end-slot), so un-hiding grows `grid-template-rows` 0fr → 1fr instead of jumping the column by 40 px; `@approval_strip_open` is `not ((transcript == [] or chat_status == :ended) and pending_approvals == [])`.
The per-message raw/Markdown toggle keeps ONE outer wrapper whose classes never change, so only the INNER `motion-panel` node is replaced at turn end: streaming is an inline `span.motion-panel.motion-panel-open` plus `.help-caret`, the raw branch a BLOCK `div` (`phx-no-format`, markdown-free — no `md-content`, no `raw/1`) with `leading-[1.7]` mirroring `.md-content`, the markdown branch `div.motion-panel.motion-panel-open.md-content`.
The thought-process disclosure (`<details id="assistant-thought-<entry_id>" class="motion-disclosure">`) animates in BOTH directions: motion.css's `[open]` rule owns the open, and `phx-hook="DisclosureMotion"` writes `data-disclosure-state="closing"` before dropping `open` so the exit keyframe plays (`phx-mounted={JS.ignore_attributes("open")}` keeps `open` browser-owned); no transcript scroller is ever animated, and motion.css's global `prefers-reduced-motion` backstop covers both.
Every other Assistant disclosure is symmetric on that recipe with a browser-owned `open`: `#assistant-tracked-panel` (followed tasks), `#assistant-task-menu` plus its `#assistant-task-by-id` sub-section, and `#chat-attach-menu` plus its `#chat-server-attachment` sub-section.
The two transient menus (`#assistant-task-menu`, `#chat-attach-menu`) add `data-disclosure-dismiss="true"`: the hook owns outside-pointerdown/Escape dismissal CLIENT-side (animated close, focus back to the summary on Escape), so neither may carry a server-driven `phx-click-away`/`phx-window-keydown` `JS.remove_attribute("open")` — that strips `open` before the exit keyframe and fights the hook for it.

## DialogModal hook contract (page-level dependency)

`phx-hook="DialogModal"` is mounted ON the `<dialog>`; `mounted/0` opens it with `showModal()` when available (else an honestly nonmodal visible fallback) and focuses static review content, never Allow/Deny.
Escape, backdrop and `data-dialog-dismiss` report `dialog_closed` EXACTLY once per dismissal through the hook's latch, never denial or authorization.
`updated/0` preserves focus and re-asserts the modal unless dismissed (optional `push_event("dialog_open", %{})` clears the latch and re-shows it); `destroyed/0` removes its listeners BEFORE closing, so a server-driven unmount reports nothing, then restores viable explicit return focus or prior focus without stealing focus already outside.

## Attachments & uploads

The attachment pipeline mirrors `ProjectsLive.AttachFile`:
- picker ids `"chat_file"` (text), `"chat_file_image"`, `"chat_file_audio"` via `EvoDash.DirectoryPicker.pick(self(), picker_id, :file)`; results arrive as `{:directory_picker_result, picker_id, {:ok, path} | :cancelled | :unavailable}`.
- a text file appends `"\n\n---\n## Attached file: <basename>\n\n" <> content` to the message text.
- image/audio files stage `%{"type" => "image" | "audio", "name" => basename, "media_type" => IANA, "data" => raw bytes}`; base64 is applied ONLY at submit (`Base.encode64/1`).
- at most 4 attachments of at most 15 MiB raw each; errors flash through `Attachments.describe_error/2` (delegating `EvoDash.AttachedFile.describe_error/2`).
- pending chips carry a remove action (`chat_attachment_remove`, `phx-value-index`) and pending attachments are cleared exactly on a successful send.
- attaching requires the LOCAL node (`current_node == node()`); a remote/pending node or a picker error only sets `attach_unavailable` and offers the manual-path form, whose reads run on the LOCAL filesystem (`attachment_pipeline.ex` → `AttachedFile.read/1`).

The attach menu sits OUTSIDE `#chat-form`, and the textarea is NOT `phx-update="ignore"`, so staging a text file simply assigns the draft server-side.
`Uploads` owns native browser upload validation, progress and consumption: an empty/whitespace draft with no completed attachment cannot send, uploads in progress block every send event while leaving the draft editable, browser upload works independently of the deployment host, server-path attachment is a separate local-node-only entry, and New chat / session / node switches cancel pending uploads.

## Caps

- transcript: at most 200 entries (newest kept), at most 8 000 graphemes of rendered text per entry
- reasoning: at most 40 entries per transcript entry and at most 40 live `thought_process` entries (newest kept); a history-read rebuild assigns the whole `Messages.to_entries/1` list, which is uncapped
- queued echoes: at most 20
- attachments: 4 files, 15 MiB each raw
- preamble (one-shot fallback only): last 8 exchanges, 600 chars per entry, 4 000-char total

## Reasoning retention

Reasoning belongs to each transcript entry's `:reasoning` list, preserved by `Transcript.normalize/1` and `ChatState` restore.
`Messages.transcript/1` attaches each reply's own history projection, including preceding assistant/tool-only entries since the previous bubble, bounded to 40 entries and reset on an authored user message.
`LiveCall` replaces the current bubble's reasoning from its call-id-keyed complete thinking projection, legacy text/thinking deltas attach their current-turn bucket through `Transcript.put_reasoning/3`, and `ChatMessages.message_list/1` passes each assistant entry's reasoning to `AssistantMessage`, so completed replies keep their own Thought process section instead of borrowing the last global buffer.
The global `thought_process` is a reducer/history output but NOT the presentation authority: a transcript updated without adopting `Messages.transcript/1` must attach the corresponding reasoning explicitly; whole activity replacement overwrites captured prefixes, retry removes the failed call's answer and thinking, and checkpoint retirement preserves the committed entry's reasoning.

## Optimistic send & rollback

`start_session_chat/4` bumps `send_seq`, applies the OPTIMISTIC UI synchronously (user bubble via `Transcript.append/2` + `Transcript.entry/2`, `Transcript.put_streaming_text(…, "")`, cleared `chat_draft`/`pending_attachments`, `chat_status: :running`, `chat_node`, `send_in_flight: true`, `send_seq`), stashes `send_pending: %{kind: :start, seq:, text:, task_opts:, node:, session_id:, prev: %{transcript:, chat_draft:, pending_attachments:, chat_status:}}`, persists, then spawns `SessionActions.start/2`.
`queue_session_message/4` is optimistic the same way (`send_pending: %{kind: :message, queued?: chat_status == :running, policy:, text:, node:, session_id:, prev:}`): it appends the user bubble, adds the empty reply placeholder only for a fresh turn, pushes ONE echo when the turn was already running, clears draft/attachments and spawns `SessionActions.send_message/6`; `prev` also carries `queued_echoes`.
`apply_send_result/3` settles both kinds: a seq no longer matching `send_seq` (a newer send, `reset_chat/1`, a node or session move) is STALE and returns the socket unchanged apart from clearing the in-flight flag/pending map when they still belong to that seq; a live result dispatches on the stashed kind — `:start` adopts through `adopt_session/3`, or falls back to the one-shot `:reflect` path with the user bubble ALREADY appended, or restores `prev` and flashes "Failed to start the conversation: …"; `:message` is settled-only — `send_succeeded/2` re-asserts draft/attachments and `chat_status: :running` and refreshes `TaskTracking` (no second bubble, no duplicate echo), while `send_failure/3` runs `restore_send/2` with `prev` before reporting the refusal.
No path can strand `send_in_flight: true`: `reset_chat/1` clears the flag/pending map and advances `send_seq`/`stop_seq`, and a stale or dropped result always leaves the composer usable.
`stop_reply/1` and `finish_chat/4` (the `cancel_chat_task/1` path) follow the same shape with `stop_seq`: the spawned call carries `{:chat_stop_result, seq, node, session_id}` / `{:chat_finish_result, seq, node, task_id, assigns, reload?}` and the matching clause drops a result whose `stale_control?/3` or identity no longer matches before applying `stop_ok/3` or `stop_flash/2`.

## Streaming (Watch + Delta, push-only)

A mounted `?session=<id>` page holds one `%Delta{}` per watched agent and folds `{:agent_delta, agent_id, seq, batch}` through `Delta.apply_batch/5`; batches are `{:activity, projection}`, `{:text, chunk}`, `{:thinking, chunk}`, `{:tool_call, id, name}`, `{:tool_result, id, status}`, `{:turn, info}`, `{:yield, text}`, `{:finished, status}`; the reducer reports `outcome` (page fold: `:yield` → idle + `:awaiting_input` + cleared echoes, `{:finished, _}` → ended + terminal status, anything else → failed).
`Delta` is PURE and TOTAL (`new/3`, `seed/3`, `meta/0`, `apply_batch/5`, `streamed_text?/1` = per-turn `text_in_turn`/`text_in_closed_turn`): it never advances `delta.seq`, never rejects stale batches and ignores unknown events (richer core vocabulary must be implemented explicitly), so the CALLER sequence-gates — a batch with `seq <= snapshot.seq` is dropped via `EvoGit.Agent.Stream.stale?/2`.
It keeps ONE assistant bubble per turn, accumulating text across tool calls and closing only at a boundary (`{:turn, …}`, `{:yield, …}`, `{:finished, …}`) through `Transcript.close_streaming/1`, which DROPS a text-less bubble; `{:tool_call, id, name}` appends the `:running` `:tool` row without finalizing the bubble, so a thinking/tool-only turn renders no bubble.
`Watch.attach/1` runs each half where it must run: the consumer-local PubSub subscription INLINE in the LiveView, watcher registration + snapshot in an `EvoDash.TaskSupervisor` child with the LiveView pid as consumer (the session monitors that pid).
`Watch.ready/5` admits only the current node/session/generation result, `Watch.push/4` buffers before seeding then replays a newer batch, and `{:ignored, socket}` covers an obsolete scope or sequence; failures answer `{:error, socket, reason}`, RETAIN the failed watch's history ownership and surface at `chat_stream.error` (`#chat-stream-error`, Retry → `attach_stream/1`) — never an independent history read.
Batches arriving before the snapshot are buffered and replayed in order only when newer; `{:chat_stream_ready, …}` atomically installs the hydrated transcript, thought process, metadata and sequence baseline, applies `snapshot.phase`, then folds replayed outcomes — the snapshot is the ONLY resync (no polling, no independent overwrite).
`Watch.snapshot_result/3` accepts only `%EvoGit.Agent.Stream.Snapshot{}` inside the flat registration answer or its SafeCall wrapper and returns `%{snapshot:, delta:, meta:, transcript:, thought_process:}`, combining checkpoint messages (`Messages.transcript/1`) with `snapshot.activity` through the same reducer, including already-emitted current-call prefixes (the core captures them before any watcher attaches).
`stream_active?/1` includes pending AND FAILED watches in the current scope, so an independent attach/history result cannot overwrite their surface or phase; independent reads capture `stream_attach_seq` and reject results after it changes, even after detach; `Watch.down/4` and `Watch.failure/1` complete the API.
Registration buffers cap at 128 batches / 1 MiB and overflow is an explicit failure requiring reattachment (never silent loss); the worker serializes every register/unregister (including detach during a blocked registration), monitors the consumer, treats a healthy same-scope attach as a no-op, keys scope on node AND agent, advances the generation on detach, settles worker-start failures as `{:watch_start_failed, reason}` and logs cleanup RPC failures without retries.
A `{:finished, status}` with no current or last-closed turn answer requests exactly ONE final atomic snapshot through that same serial worker (never an independent history read): it advances `stream_attach_seq`, retains subscription and last coherent surface, buffers newer batches and admits only its matching node/session/token result at or above the finish sequence; streamed/duplicate finishes never re-request, and the terminal outcome survives so an earlier phase cannot reopen the composer.
The terminal `{:agent_stream_closed, agent_id, %Snapshot{phase: :done}, seq}` handoff is admitted by `Watch.closed/4` directly (no registration, no history read, even before registration settles or after its failure) and requires matching agent/session, BEAM node, target identity, current watch generation, matching snapshot/envelope sequences, and a sequence at least as new as every applied/buffered/required watermark (equal admitted deliberately: terminal checkpoint messages may share the finish batch's sequence).
It replaces the whole surface through `snapshot_result/3`, closes streaming entries, clears buffers and errors, advances the generation and seals the watch with `closed_seq`; no text/turn/count/index heuristic deduplicates terminal history.
`StreamFold` installs it atomically through `apply_watch_result/1` (the snapshot's terminal status as well as its `:done` phase); a sealed watch keeps history ownership but ignores later ready replies, deltas, duplicate handoffs and worker failures, `Watch.closed?/1` lets parent lifecycle handlers ignore reordered non-authoritative events, and a missing handoff still retains the cached transcript when the legacy final read loses the session-removal race.
A `:starting` session ACCEPTS the watch (the core answers its pre-state snapshot — `phase: :starting`, `status` nil, `seq` 0, empty messages, live activity — keeps the registration and continues the sequence; the snapshot maps to `chat_status: :running` / `chat_task_status: :running`); the bounded 10 s retry (`:home_agent_watch_start_timeout_ms`) is LEGACY-NODE tolerance only, firing when a node answers `{:error, {:bad_state, :starting}}` (logged `reason=starting_timeout`, delivered as one failed readiness reply).
`EvoDash.NodeContext` is the boundary: `subscribe_agent_deltas/1`, `unsubscribe_agent_deltas/1`, `register_agent_watcher/3`, `unregister_agent_watcher/3`, `watch_agent_snapshot/2`; a WATCHED session never refetches its whole history on an `:agent_updated` message-count change (`Watch.stream_active?/1`) — the delta path persists chat state instead.
TWO surfaces: bubble text is a transcript entry (`text` + `streaming`) rendered by `AssistantMessage.assistant_message/1`; reasoning and tool calls are THOUGHT-PROCESS entries (`%{turn, timestamp, type, data}`) rendered by the private `AssistantMessage.thought_entry/1`; a `:tool` entry is a quiet status row (`AssistantMessage.tool_entry/1`).
Transcript entries are `%{id, role, text, streaming}` plus optional `:reasoning` and, for tool entries, `:tool_name`/`:tool_call_id`/`:tool_status`/`:turn`; `role` is whitelisted to `:user | :assistant | :error | :tool` (`ChatMessages.message_list/1` renders all four plus a total fallback) and `Transcript.normalize_entry/1` rebuilds entries from known keys only, so a NEW field needs adding there to survive `ChatState.restore/1`.
The turn meta line under the last assistant bubble (`Delta.meta/0`: `turn`/`total_tokens`/`duration_ms`/`usage`) is `chat_stream_meta`, passed to `message_list/1` as `stream_meta`; New chat (`:idle`/`:ended`) clears draft, per-chat refs, echoes, uploads and pending attachments, and a node switch resets chat state without cancelling the session.
Detach (`new_chat`, leaving the session, node switch, terminal status, a successful close, `terminate/2`) unsubscribes inline and fires the watcher unregister in a supervised child; the session's own monitor is the real reaper.
`AssistantComposer` submits on Enter and keeps the newline on Shift+Enter; model selection stays usable during a run but applies to the NEXT session only.

## Transcription contract (history → display bubbles)

`Messages.transcript/1` returns `%{transcript: transcript, entries: entries}`: `entries` is the raw `Messages.to_entries/1` projection feeding the collapsible thought-process panel, `transcript` the ORDERED display bubbles from `DisplayMessages.bubbles/1`.
Bubbles are `{:user | :assistant, text}` in chronological order (user1 → assistant1 → user2 → assistant2), one per surviving history message — never all user turns followed by one joined assistant blob: `:system` never bubbles, an `:assistant` message bubbles through `Messages.message_text/1` (thinking parts excluded) with an empty/thinking-only one skipped, and `:tool` role messages never bubble (live tool rows come from deltas; the thought-process panel keeps the raw detail).
A `:user` message bubbles ONLY when user-authored: `DisplayMessages.user_authored?/1` returns the core's `metadata[:user_authored]` marker (atom or string key, boolean only) and `:unknown` when absent; with `:unknown` the shape heuristics decide — the turn-0 wrapper is unwrapped to its `<objective>…</objective>` body, and a `<context>`-prefixed message, `metadata[:checkpoint] == true` and injected notices (runtime-context refresh, `[NOTICE] `/`[WARNING] `/`[URGENT] ` prefixes, the turn-budget warning, the graceful-cancel save-work message) are dropped (heuristics: `live/CONTEXT.md`).
`Messages.transcript/1` is the SINGLE builder for both the history read (`apply_history/3`) and the watch snapshot, so this projection governs every attach/reattach and the persisted `ChatState` transcript; `bubbles/1` is total (nil/garbage → `[]`, never raises).

## Signature-gated chat persistence

`ChatState.persist/1,2` is the ONLY writer of chat state into `EvoDash.ChatHistory` and it COALESCES pure streamed-text growth, because a delta batch arrives roughly every 75 ms while `ChatHistory.put_state/2` deep-copies the whole transcript + thought process through a GenServer call; `build/1` stays the pure defensive assigns → map extractor and `restore/1` the total mount-direction normalizer, so the persisted shape is unchanged both ways.
`write_state?/3` gates every write on `signature/1`, covering the AUTHORITATIVE parts only: `chat_status`, `chat_task_status`, `chat_task_id`, `chat_agent_id`, `session_id`, `session_mode`, `chat_node`, `chat_draft`, `agent_message_count`, `selected_model_id`, `model_spec`, `model_selection_scope`, `model_selection_error`, `workbench_draft_key`, `assistant_conversation_id`, the NUMBER of queued echoes, and the transcript length plus each entry's `{id, role, streaming, tool_status}`.
Streamed CONTENT is deliberately outside the signature (an entry's `text`/`html`, its `:reasoning`, the `thought_process` buffer are what grows per batch), so a growing bubble alone never counts as a change; a CHANGED signature writes IMMEDIATELY, so every lifecycle and structural change reaches the store at once, and `force: true` always writes.
An UNCHANGED signature still writes once `@throttle_ms` (1000 ms) has elapsed since this chat's previous write, so a long turn's text is at most about one second stale (worst case ~1 s of streamed text missing if a tab closes mid-turn, restored by the next signature change).
The markers are PROCESS-DICTIONARY entries `{ChatState, :last_signature, chat_id}` and `{ChatState, :last_write, chat_id}` (a monotonic-ms stamp), written together by `mark_write/2` — never a GenServer, ETS table or `:persistent_term`: `persist/2` only runs in the owning LiveView process, so they die with it (a remounted tab's missing marker writes immediately) and a chat switch uses another key.
`persist/2` still returns the socket and stays TOTAL (garbage/absent state neither raises nor gains a `try/rescue`), and every option — notably `clear_empty_draft: true` and the draft / draft-key branches — behaves as documented.

## Assigns discipline (masked reads)

Every `assigns[:key] || default` read under `home_live/**` stays a MASKED read: keys are seeded by `ChatBootstrap.base_assigns/0` + `init/1` and completed by the `NodeAware`/`Appearance` on-mount hooks, but a helper may still receive a hand-built partial map, so a `KeyError` would be a real regression.
`ChatState.build/1` keeps every default on purpose — it is a pure extractor that must also persist a hand-built partial map (`transcript`, `thought_process`, `chat_draft`, `chat_status`, `queued_echoes`, `task_action_ids`, `task_action_pending`), and tests persist such maps; `Watch`, `SendPath`, `TaskTracking`/`TaskCard`, `TaskPicker`, `ApprovalWorkflow`, `SessionList`, `Workspace`, `Composer`, `Uploads` and `ModelSelection` all read their own keys masked.
Three keys are SEEDED rather than masked — `remote_targets` (→ `[]`), `connection_statuses` (→ `%{}`), `accent_color` (→ `"blue"`) get `assign_new/3` in both `ChatBootstrap.init/1` and `render/1` (covering a direct template render with a partial map) and are read as `@remote_targets` / `@connection_statuses` / `@accent_color`; `workbench_draft` and the `current_node` / `current_node_id` family keep masked reads.
Making a read explicit requires seeding the key with `assign_new/3` — the defensive reads stay the contract and NEW keys read the same masked way.

## Workspace, task controls & session assertions

`Workspace`/`WorkspaceComponent` select an optional existing project or VCT workspace without reading its files.
The picker has TWO labelled groups — "Projects" (recent project mounts, `workspace_select`) and "Workspaces" (workspace mounts with resolved member count and a missing marker) — and a workspace row expands through a pure server assign (`workspace_expand`) into its resolved members plus every unresolvable ref, while picking the row posts `workspace_pick`.
`#workspace-panel` stays MOUNTED and is toggled through the server-owned `data-motion-want` intent so the shared `MotionPanel` hook can fade it out (`data-motion-state` + `hidden` are hook-owned; `assets/js/hooks/CONTEXT.md`), which is why click-away and Escape push the idempotent `workspace_close` (`Workspace.close/1`) instead of `workspace_toggle` — the panel's `phx-window-keydown` still fires while it is closed, and a toggle would OPEN it from anywhere on the page.
A selection is the total, term-safe map `%{kind: :project | :workspace, point: point | nil, path: abs_os_path, name:, node:, node_id:, members: [member], missing: [ref]}` persisted into `ChatHistory`; `normalize/1` also accepts a legacy map with no `:kind`/`:point` and defaults it to `kind: :project, point: nil`.
A workspace is a GROUPING point (`vct:///workspaces/<slug>`, no OS path): its selection carries the WORKSPACE point as identity and the FIRST RESOLVED MEMBER's OS path as `path`, so everything reaching `mount_project`, `start_task` or an agent-session start is an absolute OS path and never a `vct:` value; a workspace with no resolvable member yields NO selection (the missing refs are named), and one whose resolution errors keeps `members: []` with every ref reported missing.
Members resolve in stored order inside the same supervised `SafeCall.start/3` load as the list (never in the LiveView, never polled); a selection is LOCKED (`locked?/1`) while `session_attach_pending?` or `chat_status in [:running, :cancelling]`.
The panel shows both identities of an active workspace selection (workspace name plus the concrete execution project) and lists missing refs; `select_mounted/2` accepts an absolute path or a VCT point (project point → that project, workspace point → the workspace scope) and keeps its "no longer open on the selected node" error.
Draft and conversation scope identity is the VCT token (`DraftScope.project/1`-or-`DraftScope.workspace/1`, raw absolute path as the legacy fallback), so `workbench_draft_key` is `{node_id, target_node, scope_token, draft_id}`: one repo re-spelled keeps ONE draft while two points over one OS path stay separate.
`?wb_project=` keeps carrying a PATH and is resolved server-side: when `select_mounted/2` lands a point differing from the key's token, `adopt_workbench_scope/1` re-settles the key to the point-keyed version and adopts the draft or one-shot chat under the legacy path key, deleting that retired spelling; adoption never runs while a turn is streaming or a session owns the chat, and `draft_project/1` returns the EXECUTION path (what workbench.js compares with the active project) while `draft_scope/1` returns the token.
`TaskTracking` owns followed task links and action reconciliation, `TaskCard.card/1` renders them, and `TaskPicker` loads searchable paginated summaries on menu open with manual ID entry secondary; node/conversation/sequence guards reject stale responses, pending remote targets never use local data, and linked active/pausing summaries refresh every 3 s and stop at resting/terminal states.
The shared task catalog is `EvoGit.TaskControl.Tools`; Assistant actions use real structured approvals while MCP keeps its own transport authorization.
A failed model snapshot stays an error, never a silent Auto; pending remote targets never load local models or launch locally.
Static startup checks the assets and performs a full navigation on a version mismatch before initializing the Assistant, preserving node/session params.

## Async contract (message tags + stale guards)

The LiveView never blocks on a store/registry/cross-node call: every interactive-session mutation is dispatched with `EvoDash.SafeCall.start/3,4` and settled by a tagged `handle_info` clause, so delta processing and timers keep running; render-critical loads run under `EvoDash.TaskSupervisor`.
`SafeCall.start/4` sends tags NESTED (`{{tag, …}, result}`); tasks spawned with `Task.Supervisor.start_child` + manual `send/2` carry FLAT tags.

| Spawned by | Self-message | Stale guard |
|-----------|--------------|-------------|
| `spawn_attach/2` (after `attach_stream/1`) | `{{:session_attached, seq, node, session_id, stream_seq}, result}` | `session_attach_seq` + node + `session_id`; inner `stream_seq` decides whether the attach surface applies |
| `SessionList.spawn_load/2` | `{{:session_list_loaded, seq, node}, result}` | `session_list_seq` + node |
| `async_lookup_agent/2` (`Task.Supervisor.start_child`) | `{:chat_agent_lookup, node, seq, task_id, stream_seq, agent}` | `stale?/3` + `chat_task_id` + `stream_attach_seq` + not `stream_active?/1` |
| `async_fetch_history/2` | `{:chat_history_loaded, node, seq, agent_id, stream_seq, result}` | `stale?/3` + `chat_agent_id` + `stream_attach_seq` + not `stream_active?/1` |
| `async_fetch_task/2` | `{:chat_task_loaded, node, seq, task_id, task}` | `chat_task_fetch_seq` + node + task_id |
| `SendPath.start_session_chat/4` / `queue_session_message/4` | `{{:chat_send_result, seq}, result}` | `send_seq` against the stashed `send_pending.seq` + its node/session identity |
| `TaskEvents.stop_reply/1` | `{{:chat_stop_result, seq, node, session_id}, result}` | `stale_control?/3` + `session_id` |
| `TaskEvents.cancel_chat_task/1` (`finish_chat/4`) | `{{:chat_finish_result, seq, node, task_id, assigns, reload?}, result}` | `stale_control?/3` + `chat_task_id` |
| `Watch.attach/1` (registration + snapshot) | `{:chat_stream_ready, node, seq, agent_id, result}` | `stream_attach_seq` + node + `session_id` + current `chat_stream.agent_id` |
| `ModelSelect.load/1` | `{{:model_select_loaded, seq, target_node}, result}` | `model_select_seq` + target node + selection scope |
| `Workspace` loads | `{{:assistant_workspace_loaded, seq, request_scope, chat_id, kind}, result}` | seq + request scope + chat id |
| `SourceGate.spawn_availability_check/3` / `spawn_clone/3` | `{:source_availability_loaded, seq, node, result}` / `{:source_clone_result, node, result}` | `source_check_seq` + node |
| `TaskTracking` / `TaskPicker` | `{:assistant_action_reconcile, scope}`, `{{:assistant_action_status, scope, id}, result}`, `{{:assistant_follow_result, scope}, result}`, `{{:assistant_task_choices, seq, scope, offset}, result}`, `:assistant_tasks_tick`, `{{:assistant_tasks_loaded, seq, scope}, result}`, `{{:assistant_task_action, scope, id}, result}` | captured `{node, conversation}` scope + seq |
| `ApprovalWorkflow` | `{{:approval_pending_loaded, seq, scope}, result}`, `{{:approval_workflow_response, seq, scope, request_id}, result}` | monotonic token + chat/node/task/agent scope |

`{:chat_send_result, …}` finishes the optimistic send in `apply_send_result/3` (adoption, one-shot fallback, or rollback to `send_pending.prev`), `{:chat_stop_result, …}` / `{:chat_finish_result, …}` finish stop and cancel in `chat_stop_result/2` / `chat_finish_result/2`, and `{:chat_task_loaded, …}` finishes the one-shot terminal handoff in `chat_task_loaded/2` → `SendPath.finalize_terminal/2` (dropped outright for a sealed watch).
Fallback refetches of the whole history are gated by `chat_fetch_seq` (agent lookup/history) and `chat_task_fetch_seq` (task reads), and `{:agent_updated, …}`'s `changed_fields` is a KEYWORD LIST (never a map) guarded with `is_list` + `Keyword.has_key?`, so a broadcast can never crash the fold.
Session-list refresh rides the node-filtered `"tasks"` debounce (`handle_info(:node_aware_reload_tasks, …)` → `TaskEvents.node_aware_reload_tasks/1`) and re-runs after a session is adopted or closed — no polling.
A loading flag always settles: every spawned loader sends its result term, including `{:error, reason}` from `SafeCall.run/1` or a supervisor-start failure.

## Test seams (resolved AT SPAWN/CALL TIME)

- `:home_session_attach_runner` (2-arity `(node, session_id)`), `:home_session_list_runner` (1-arity `(node)`), `:home_session_start_runner` (2-arity `(node, opts)`)
- `:home_session_send_runner` (4-arity `(node, agent_id, message, policy)`); `:home_session_workspace_send_runner` (5-arity `(node, agent_id, message, policy, workspace)`, used whenever `:assistant_workspace` is present)
- `:home_session_close_runner` (3-arity `(node, agent_id, reason)`); `:home_session_stop_runner` (2-arity `(node, agent_id)`, default `&EvoDash.NodeContext.stop_current_turn/2`, read by `TaskEvents.stop_reply/1`)
- `:home_agent_watch_runner` / `:home_agent_unwatch_runner` (3-arity `(node, agent_id, watcher_pid)`, defaults `register_agent_watcher/3` / `unregister_agent_watcher/3`, read inside the spawned task); `:home_agent_history_runner` (2-arity `(node, agent_id)`, default `&EvoDash.NodeContext.get_agent_history/2`)
- `:home_agent_watch_start_timeout_ms` (legacy `:starting`-refusal retry budget, default 10 s)
- `:approval_pending_runner` (pending-approval recovery read), `:approval_responder` (response route)
- `:source_availability_runner` / `:source_clone_runner` (Genesis Source check/download)

Each is `Application.get_env(:evo_dash, key, default)` read inside the spawned/loading function, so injecting an exiting runner proves the page survives with its loading flag cleared.

## Test pins

`ChatMessages.message_list/1` wraps every transcript row in `#chat-entry-<entry.id>`, and `Transcript.entry/3` generates unique-integer string ids, so history rebuilds do not preserve row ids across remounts.
Assert answer text OUTSIDE the Thought process details (history-derived thought entries can repeat it): a streamed answer has `.help-caret`, a finalized one exposes `button[id^="assistant-copy-"][data-content]` and ordinarily `.md-content`; the assistant message's `status_label/1` renders `:awaiting_input` as "Awaiting input" with the violet idle-session badge/dot colours from `EvoDashWeb.Helpers.task_status_badge/1` / `task_status_dot_class/1`.
`home_live_test.exs`'s `:reflect` assertions exercise the fallback path only, because its fixture configures `model_profiles: []` (so `start_session` answers `:llm_not_configured`).
`Delta` retains the streamed bubble's entry id across a turn boundary, so an authoritative yield updates that reply instead of appending a duplicate, and it ignores unknown events.
Per-suite coverage (mounted delta/`seq` cases, real-producer suites, approval and workspace fixtures): `apps/evo_dash/test/evo_dash_web/live/home_live/CONTEXT.md`.

## Known Issues

- **The whole transcript still re-renders on every delta.** `ChatMessages.message_list/1` is a plain function component, so one growing bubble re-renders up to 200 history rows per ~75 ms batch; a finalized answer re-uses its cached `:html` but unaffected bubbles are still diffed; the remaining lever is a change-tracked `live_component` keyed by entry id.
- **`EvoDash.ChatHistory` serializes every read/write through one GenServer** (`apps/evo_dash/lib/evo_dash/chat_history.ex`, OUTSIDE this node): `put_state/2` deep-copies the whole transcript per call, `list_chats/0` full-scans so `SessionList`'s private `cached_chats/1` issues 1 + N `get_state/1` calls, and the `{:current}` pointer has no client/node key, so a second browser on a shared host adopts the first viewer's conversation.

## Constraints

- No `try/rescue` around config/core loading; `{:error, …}` tuples from `NodeContext` are the failure channel.
- Config/model-selection state is loaded ONLY by `ModelSelection.assign_model_select/1` from the `handle_params/3` pipeline, i.e. on mount and every `push_patch`/`push_navigate` (session adoption, New chat, node switch, connection-transition patch) and never on a timer; there is no refresh event, so a cached bundle (`model_snapshot`, `model_selection_bundle`, `provider_profiles`, `model_selections`, `model_selection_enabled`) stays until the next param change.
- Starting or sending a conversation refreshes NO shared state: `SessionActions.start/2` → `NodeContext.start_session/2` is a pure forward (the core start path performs no `Config.Cache.reload`, no `Watcher.notify_change`, publishes no `"config"`/`"vct"` event and mutates no VCT mount), so another page's stale model list can never be healed from here — only the full navigation that remounts that page can.
- `ModelSelect.load/1` keeps no cache of its own: the local branch calls `Config.resolve()` synchronously (`model_select.ex:46`), i.e. the core's `:persistent_term` snapshot, and the connected-remote branch reads `NodeContext.get_resolved_config/1` in a supervised task; `model_select_loading` is set `true` only on that remote spawn (`model_selection.ex:53`) and cleared by BOTH result arms (`:75`, `:85`).
- The page subscribes to `"tasks"`, `"agents"` and `"approvals"` only (`home_live.ex`, in `mount/3`) plus `"agent:<id>"` via `Watch` — never `"config"` or `"scheduler_config"`, so a config reload broadcast does not reach it.
- No code in this subtree reads `config.toml`/`credentials.toml` or computes config paths; the only file reads are user attachments (`attachment_pipeline.ex`, `attachments.ex`).
- Every new user-facing string is `gettext`-wrapped; Chinese comments only for short/ambiguous labels; never run `mix gettext.extract`/`merge`/`translate` during feature work.
- `?session=` parses with `Integer.parse/1` + a positive guard; no `String.to_atom/1` on client input.
- Never block the LiveView on a cross-node call; every async load carries a monotonic seq + node stale guard, and assistant messages remain push-only with no history polling.
- Genesis-source availability does NOT gate chatting or sending: `SourceGate.blocked?/1` has no production caller, `ChatMessages.empty_state/1`'s `source_gate?` attr defaults to `false`, and the gate is local-nodes-only (`@current_node in [nil, node()]`); the wired path is the availability check, `download_source` and the System page card.
- Preserve interaction markers: `#chat-form`, `#chat-messages`, `#chat-llm-selection`, `#chat-composer-controls`, `#chat-interrupt-button`, `#chat-session-list`, `#chat-session-ended`, `#approval-status-bar`, `#approval-dialog`, `#approval-recovery-error`, `#approval-response-error`, `#approval-request-warning`, `#assistant-notifications`, `#assistant-welcome`, `#assistant-quick-actions`, `#assistant-execution-status`, `#chat-stream-error`; keep the textarea label, Send/Stop, the interrupt label and Enter/Shift+Enter semantics.
