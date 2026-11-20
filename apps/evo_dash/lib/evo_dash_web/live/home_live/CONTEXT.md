# HomeLive — Genesis Assistant (`/assistant`)

## Intent

Genesis Assistant chat page (`EvoDashWeb.HomeLive`, route `GET /assistant`, sidebar **Assistant**).
The legacy `/help` URL is a 302 to `/assistant` through `EvoDashWeb.RedirectController`, with the query string preserved (`/help?session=7` → `/assistant?session=7`).
A conversation is ONE long-lived interactive agent session (one agent id, one worktree, one `prompt_cache_key`, many messages), not a fresh `:reflect` task per message.
The session's agent id IS the conversation's addressable identity: `/assistant?session=<agent_id>`.
Repo-less: sessions start with `repo_less: true` and `EvoGit.Agents.SelfReflective`, so there is no worktree, no git operation and no subagent spawning.
When interactive sessions are unavailable on the node, the page falls back to the legacy one-shot `:reflect` task-per-message mode (`session_mode: :one_shot`) with a gettext notice.

## Routing Table

- `home_live.ex` → `EvoDashWeb.HomeLive` — the page ROUTER: `mount/3`, `handle_params/3`, one-expression `handle_event/3` / `handle_info/2` clauses, `render/1`, `terminate/2`, the five `defdelegate` hand-offs `SendPath` calls back into (`maybe_recover_approvals/1`, `spawn_attach/2`, `attach_stream/1`, `maybe_load_sessions/1`, `async_lookup_agent/1,2`) and the two `defp` composer delegations (`send_chat/2`, `send_draft/3`); every behaviour below lives in its own support module, and the one `handle_info` clause owning a bare `%Socket{}` result (`{{:chat_send_result, seq}, result}` → `SendPath.apply_send_result/3`) and the `{:assistant_workspace_loaded, …}` forward (`SessionResolution.workspace_loaded/6`) stay here
- `chat_bootstrap.ex` → `EvoDashWeb.HomeLive.ChatBootstrap` — the mount assign seed (`base_assigns/0`, `init/1`: assistant client id, the `assign_new` defaults for remote targets / connection statuses / accent, `ApprovalWorkflow.init/1`, upload setup) and the chat scope: which `EvoDash.ChatHistory` chat this tab is on, the resets that retire it, and the identity guards every loader reads (`stale?/3`, `stale_control?/3`)
- `session_resolution.ex` → `EvoDashWeb.HomeLive.SessionResolution` — the whole `handle_params/3` pipeline behind `run/2`: assign node → attach chat → restore the saved selection → a node / chat-node / selection-scope mismatch starts a new chat → `?session=` resolution → workspace-scope restore → `?wb_draft=` open/adopt → chat persistence → model-select assign → `current_path` / workbench reconnect params → source check → approval recovery → task-tracking refresh, plus the async `workspace_loaded/6`
- `attach_pipeline.ex` → `EvoDashWeb.HomeLive.AttachPipeline` — the session / history / task attach loaders (`spawn_attach/2`, `async_lookup_agent/1,2`, `async_fetch_history/1,2`, `async_fetch_task/1,2`), the socket-first `handle_info/2` settling their results, and `maybe_load_sessions/1` (the sidebar Conversations refresh)
- `attachment_pipeline.ex` → `EvoDashWeb.HomeLive.AttachmentPipeline` — the composer's attachment events: browser-upload validate/cancel/clear-error, the native picker and its manual-path fallback, chip removal, and the `{:directory_picker_result, …}` settlement
- `stream_fold.ex` → `EvoDashWeb.HomeLive.StreamFold` — the watch lifecycle plumbing (`attach_stream/1`, `apply_watch_result/1`, outcome and phase folding, terminal snapshot, watch failure, streaming-bubble finalization) behind a socket-first `handle_info/2`
- `task_events.ex` → `EvoDashWeb.HomeLive.TaskEvents` — the `"tasks"` / `"agents"` PubSub folds, the assistant task-picker result family, and the chat control results (`cancel_chat_task/1`, `stop_reply/1` and their private `finish_chat/4`, settled by `chat_stop_result/2` / `chat_finish_result/2`)
- `approval_dialog_state.ex` → `EvoDashWeb.HomeLive.ApprovalDialogState` — `ApprovalWorkflow` wired into the page: scope-keyed recovery (`maybe_recover_approvals/1`), live arrivals / resolutions, decision dispatch, the dialog open/step/close state, and the public `approval_strip_open?/1`
- `workbench_scope.ex` → `EvoDashWeb.HomeLive.WorkbenchScope` — the page-local scope wiring: workspace picker events, provider/model/reasoning selection events and the model-snapshot result, the `{:node_selected, …}` / `{:remote_connection_status, …}` node moves, and the Genesis source gate
- `session_actions.ex` → `EvoDashWeb.HomeLive.SessionActions` — session identity URL builder/parser, session launch + message send + close executors, attach snapshot loader, conversation-list loader, session-status helpers (the ONLY place that talks to `EvoDash.NodeContext`'s session RPCs)
- `session_list.ex` → `EvoDashWeb.HomeLive.SessionList` — the SECTION BODY of the shared app-layout sidebar's **Conversations** section (async loader, pure row building, `session_list/1` HEEx); the layout owns the section header and renders it below Active Tasks on every dashboard page
- `send_path.ex` → `EvoDashWeb.HomeLive.SendPath` — the send path and the finalize block: `send_chat/2`, `send_draft/3`, `do_send_chat/3`, `sendable_status?/1`, `reflect_objective/2`, `dispatch_send/5`, `queue_session_message/4`, `normalize_send/1`, `push_queued_echo/2`, `message_count_grew?/2`, `send_failure/2`, `start_session_chat/4`, `start_failure/4`, `adopt_session/3`, `start_chat/3` plus `finalize_streaming/2`, `finalize_terminal/2`, `finalize_completed/2`, `finalize_cancelled/2`, `finalize_failed/2`, `clear_task_refs/1`; `home_live.ex` keeps only the two thin `defp` delegations (`send_chat/2`, `send_draft/3`)
- `composer.ex` → `EvoDashWeb.HomeLive.Composer` — the composer card (textarea, attachment chips + attach menu, model capsule, Send/Stop, Interrupt turn, queued echoes)
- `attachments.ex` → `EvoDashWeb.HomeLive.Attachments` — the page's attachment pipeline (picker ids, staging, caps, submit conversion)
- `transcript.ex` → `EvoDashWeb.HomeLive.Transcript` — transcript model, normalization/caps, per-message reasoning, streaming bubbles (`append_streaming_text/2`, `finalize_streaming/1`, `close_streaming/1` — a non-empty bubble is finalized, an empty placeholder dropped), `:tool` entries (`tool_entry/4`, `put_tool_status/3`), bounded preamble
- `delta.ex` → `EvoDashWeb.HomeLive.Delta` — the PURE, TOTAL delta reducer (`new/3`, `seed/3`, `meta/0`, `apply_batch/5`, `streamed_text?/1`); one assistant bubble per turn accumulated across tool calls; no processes, no side effects
- `live_call.ex` → `EvoDashWeb.HomeLive.LiveCall` — call-id-keyed display projection of whole `:activity` replacements and appended chunks, with one live answer/reasoning entry, failed-attempt removal on retry and committed-output preservation on checkpoint retirement
- `watch.ex` → `EvoDashWeb.HomeLive.Watch` — consumer-local subscription, one consumer-monitored serial registration worker, generation-guarded `ready/5`, buffered `push/4`, authoritative terminal-handoff admission `closed/4`, worker `down/4`, atomic display-surface `snapshot_result/3` and history-ownership `stream_active?/1`.
- `chat_state.ex` → `EvoDashWeb.HomeLive.ChatState` — persisted per-chat shape (`build/1`, `persist/1`, `restore/1`) over `EvoDash.ChatHistory`
- `workspace.ex` / `workspace_component.ex` → `EvoDashWeb.HomeLive.Workspace` (total project/workspace selection map, VCT-token draft scope, async project + workspace loading with seq/node/chat guards) and the picker panel with its Projects and Workspaces groups
- `messages.ex` → `EvoDashWeb.HomeLive.Messages` — ReqLLM history → per-message display text (`message_text/1`, thinking parts excluded) and thought-process entries (`to_entries/1`, total), plus `transcript/1`, the ONE shared builder (`%{transcript:, entries:}`) both the history read and the watch snapshot seed through: `entries` is the raw thought-process projection and `transcript` the ordered display bubbles produced by `DisplayMessages.bubbles/1`
- `display_messages.ex` → `EvoDashWeb.HomeLive.DisplayMessages` — the chat-transcript projection rule (`bubbles/1`, `bubble/1`, `user_authored?/1`): `[{:user | :assistant, text}]` in chronological order, skipping `:system`/`:tool` messages and every user-role turn the harness injected (the `<context>` block, the turn-0 wrapper's `<objective>` body is unwrapped and shown, `metadata[:checkpoint]`, the runtime-context refresh, `[NOTICE]`/`[WARNING]`/`[URGENT]` notices, the turn-budget grace warning, the graceful-cancel save-work message); the core's `metadata[:user_authored]` marker is authoritative when present and the shape heuristics are the fallback
- `agent_stream.ex` → `EvoDashWeb.HomeLive.AgentStream` — root-agent lookup, `message_count` gating, final-result extraction
- `model_select.ex` / `model_selection.ex` → model snapshot loading and canonical provider/model/reasoning selection state
- `approval_workflow.ex` → `EvoDashWeb.HomeLive.ApprovalWorkflow` — ephemeral approval request state, session scoping, off-process recovery, response routing
- `approval_dialog.ex` → `EvoDashWeb.HomeLive.ApprovalDialog` — the two PURELY PRESENTATIONAL approval surfaces: the fixed-height status strip (`approval_bar/1`) and the single-request modal (`approval_dialog/1`)
- `assistant_message.ex` / `user_message.ex` / `chat_messages.ex` → chat surface rendering: message bubbles plus the two EMPTY states (`empty_state/1` greeting with the four suggestion chips, `session_ended_state/1` ended session)
- `execution_indicator.ex` → `ExecutionIndicator.execution_indicator/1`, the fixed-row textual execution phase, and shared pure `state/1` / `tool_state/1` presentation.
- `source_gate.ex` → the "Genesis source not downloaded yet" gate

## Module shape (page router + support modules)

`EvoDashWeb.HomeLive` is the ROUTER: the entry points (`mount/3`, `handle_params/3`, `render/1`, `terminate/2`), one-expression `handle_event/3` and `handle_info/2` clauses, and the `defdelegate` hand-offs.
Behaviour lives in the support modules: a page clause either delegates one event/message and wraps the returned socket in `{:noreply, _}`, or forwards the whole message to a module that already knows its own shape.
Two handler shapes, deliberately asymmetric: `AttachPipeline`, `AttachmentPipeline` and `StreamFold` expose `handle_info(socket, msg)` (the SOCKET comes first, so the page forwards the raw self-message), while every other module exposes NAMED handlers that already return `{:noreply, socket}`.
Every page-facing support module takes a socket and returns a socket; the only module state is `ChatState`'s per-process write markers (see the persistence section below).
Delegation is strictly one-directional — no support module calls `EvoDashWeb.HomeLive` — and the page's only public functions are the `ChatBootstrap` seed (`base_assigns/0`) plus the five hand-offs `EvoDashWeb.HomeLive.SendPath` invokes: `maybe_recover_approvals/1` (`ApprovalDialogState`), `spawn_attach/2`, `maybe_load_sessions/1` and `async_lookup_agent/1,2` (`AttachPipeline`), `attach_stream/1` (`StreamFold`).
Support modules call each other directly where a behaviour belongs to both (for example `ChatBootstrap` borrowing `AttachPipeline`'s loaders, `TaskEvents` delegating to `TaskTracking` / `TaskPicker`), never through the page.

## Session model

A conversation state is identified by `session_id` (the session agent id) stored in the URL as `?session=<agent_id>`.
`session_id` is authoritative in `handle_params/3`: every param change re-resolves it; a MISSING `session` param means the local draft / new-chat state.
URLs are built ONLY through the pure `SessionActions.url/2`, which yields `/assistant`, `/assistant?session=<id>`, `/assistant?node=<node>` or `/assistant?session=<id>&node=<node>` (session first, node appended with `&`, an invalid session id omitted); navigation is ALWAYS `push_patch`, never `push_navigate`, so the LiveView process (and its transcript) survives.
`SessionActions.parse_session/1` parses the param with `Integer.parse/1` plus a positive guard — no atom conversion, no `String.to_integer/1` rescue.
`session_mode` is `:interactive` (a live session) or `:one_shot` (the legacy `:reflect` fallback), or `nil` for a fresh draft.
An agent id is a positive integer, so it doubles as the `EvoDash.ChatHistory` chat id — no synthetic id mapping exists.

Session phases (`:starting | :running | :awaiting_input | :cancelling | :finalizing | :done`) map to the page's `chat_status`:
- `:awaiting_input` → `:idle` (the composer is enabled; the session is waiting for the user)
- `chat_task_status` (the DISPLAYED badge status) accepts `:awaiting_input` alongside `:pending`/`:running`/`:finalizing`/`:cancelling`/`:completed`/`:failed`/`:cancelled`, so a restored idle session keeps its badge; any unknown status restores as `nil`
- `:running` / `:starting` → `:running`
- `:cancelling` → `:cancelling`
- session gone / `:finished` → `:ended`

`EvoDash.NodeContext.close_session/3` is the only non-cancel way out of `:awaiting_input`.

## Send path

`HomeLive.send_chat/2` → `send_draft(socket, text, policy)` gates on pending-remote and the source gate, then `do_send_chat/3` trims, drops a non-sendable status, converts attachments, and resolves the canonical model options through `ModelSelect.task_opts/4` BEFORE any send.

| Situation | Action |
|-----------|--------|
| no session yet (`session_id == nil`) | `SessionActions.start/2` with `agent_module: EvoGit.Agents.SelfReflective, repo_less: true, objective: <message text, NO preamble>, model_spec: <canonical, omitted for Auto>, attachments: <pending>` → on `{:ok, agent_id}` adopt the session (chat id = agent id, `session_mode: :interactive`) and `push_patch` to `?session=<agent_id>` |
| session exists and is `:awaiting_input` or `:running` | `SessionActions.send_message(node, agent_id, %{text:, attachments:}, policy)` — NO new task, NO new chat |
| `{:error, {:session, :finished \| :not_found}}` on send | mark the session `:ended`, keep the cached transcript, show a gettext note offering New chat |
| `start_session` unavailable / refuses interactive mode | fall back to `NodeContext.start_task(node, :reflect, mode: "reflect", objective: preamble <> "New message: " <> text, model_spec: …)`, set `session_mode: :one_shot`, show the one-shot-mode notice |

Reflect-fallback triggers (`SessionActions.session_unavailable?/1`): `function_exported?/3` false, `:llm_not_configured`, `:session_api_unavailable` (the session API is absent), or a refusal (`{:interactive_root_only, _}`, `{:invalid_session_opts, _}`, `{:unsupported_session_mode, _}`), including each wrapped in `{:start_session_failed, reason}` by the remote API.
Transport errors (`{:erpc, :noconnection}`, `:timeout`) are NOT fallback triggers: they flash an error and never silently change mode.
Any OTHER start reason is not a fallback trigger either: `{:unexpected_start_result, other}` (a start that answered outside the `{:ok, {:ok, agent_id}}` / `{:ok, {:error, reason}}` shapes) and `:unexpected_session_start` (the uniform TEST-FIXTURE start-runner error that records whether a declined send reached the node) both roll the optimistic bubble, draft and attachments back through `send_pending.prev` and flash "Failed to start the conversation: …", so no session is adopted and the mode never changes.
`{:unexpected_send_result, other}` plays the same role on the message path (`SendPath.normalize_send/1`): an unknown send answer is a send failure with the draft intact, never a silent state change.
`SessionActions.send_message/5` sends `%{text:, attachments:}` when attachments are present and a bare binary otherwise.
The core generates its own random-hex task id and does not return it; the page resolves the session's task id afterwards from the agent summary (`list_agents/1` row `task_id`).
All existing guards hold on both paths: source gate, pending-remote guard, canonical model validation before any send, attachment caps.

## Queue, interrupt and Stop

The composer stays usable while `chat_status == :running`; only `:cancelling`, `:ended`, the source gate, a pending remote target and an unready model snapshot block it.
`send_in_flight` / `send_seq` gate the controls: the composer's private `send_blocked?/1` disables the Send and interrupt-turn buttons while a send job is in flight (besides a pending attach/workspace load, an upload in progress, a missing or invalid model and an empty draft), `SendPath.send_draft/3` refuses the same state server-side, and `SendPath.apply_send_result/3` drops any result carrying an older `send_seq` — a superseded send can neither re-enable nor mutate a chat it no longer owns.
Sending while running posts policy `:queue` and appends a transient QUEUED echo: `queued_echoes` is a list of `%{id: binary, text: binary, at: integer}` (newest 20, ids from `System.unique_integer([:positive])`), rendered after the last transcript entry with gettext "Queued — sent at the next turn boundary". An echo is NOT a fake assistant message.
Echoes are reconciled away when the agent's real message appears (an `:agent_updated` `message_count` increase) or on stop / close / session switch.
`Interrupt turn` (`#chat-interrupt-button`, visible only while `:running`, labelled "Send now (interrupt turn)") posts policy `:interrupt`.
**`:queue` and `:interrupt` are applied IDENTICALLY today — both land at the next turn boundary.** UI copy must never claim a chunk-level halt; the button label carries a Chinese comment for the translator.
Stop is separate and stays distinct: `NodeContext.cancel_task/2` (graceful cancel) on the session's task id, falling back to `SessionActions.close/3` when no task id is known, leaving the page in `:cancelling` until the terminal event.

## Reattach

`handle_params/3` with `?session=<id>`: sets `session_id`, `current_session_id`, `chat_id = session_id`, `session_mode: :interactive`, clears per-chat refs (`chat_task_id`, `chat_task_status`, `agent_message_count`, queued echoes), and restores the cached transcript from `ChatHistory.get_state(session_id)` through `ChatState.restore/1` (total — garbage degrades to defaults).
ONE supervised attach task per (seq, node, session) gathers `list_agents/1` + `list_awaiting_input/1` + `get_agent_history/2` and returns `SessionActions.load_attach/2`'s bare map `%{summary:, awaiting?:, history:}` (no `{:ok, _}` tag — `EvoDash.SafeCall.run/1` wraps it, which is why `apply_attach/2` matches `{:ok, %{…}}`).
Apply only when the `session_attach_seq` is current, the node matches and the `session_id` matches.
A non-empty independent attach history replaces the cached transcript through `Messages.transcript/1` only when no watch owns the surface and the captured `stream_attach_seq` still matches; its phase then comes from the summary / awaiting list.
An EMPTY history never wipes a non-empty cached transcript: `apply_history/3` keeps the cached transcript and its thought process (rendered read-only) instead of assigning `[]`.
A first-ever attach with no cache keeps the empty transcript.
Session gone (no summary, not awaiting) with an empty cache → the ended-session empty state (`HomeLive.ChatMessages.session_ended_state/1`, `#chat-session-ended`), composer disabled, New chat affordance.
Session gone with a cached transcript → render it read-only (composer disabled) plus New chat.
Reattach NEVER starts a task on read.

## Empty states (inside `#chat-messages`)

An EMPTY transcript renders exactly one of two states, both inside the existing `#chat-messages` scroller.
`ChatMessages.empty_state/1` is the greeting ("What would you like Genesis to do?", "Start a conversation" and four suggestion chips, or the Genesis-source note when the gate blocks chatting) for a live/idle chat.
`ChatMessages.session_ended_state/1` (`#chat-session-ended`) is the ended-session state for `chat_status == :ended` with an empty transcript: the gettext message "This session has ended.", "Start a new chat to continue." and a `phx-click="new_chat"` affordance.
It deliberately replaces the greeting's suggestion chips, because an ended session cannot send anything (the composer is already disabled for `:ended`).
A non-empty transcript always renders `message_list/1` regardless of status.

## Conversation list (shared sidebar Conversations section)

The page has NO left rail: `SessionList.session_list/1` renders only the BODY of the shared app-layout sidebar's **Conversations** section, which `EvoDashWeb.Layouts.app` renders below Active Tasks on EVERY dashboard page.
The page passes `session_list`, `session_list_loading`, `session_list_error`, `current_session_id` (and `current_page`) to `Layouts.app`.
Rows are the UNION of live root self-reflective agents parked at `:awaiting_input` or `:running` (`SessionActions.list/1` = `list_agents/1` + `list_awaiting_input/1`, read defensively, via the call-time `:home_session_list_runner` seam) and locally cached `EvoDash.ChatHistory.list_chats/0` conversations.
A live session wins over a cached chat with the same id, because the agent id IS the chat id.
Rows are `%{id, title, marker}` with markers `:awaiting_input | :running | :ended`, ordered awaiting (newest id first), then running (newest id first), then ended in cached order.
`row_title/2` takes the cached transcript's first user message, else the core row's `objective` keys, else `gettext("Session %{id}")`, capped at 80 characters.
The load contract: `load/1` builds the rows for a node, `spawn_load/2` bumps `session_list_seq`, sets `session_list_loading: true`, clears the error and always reports `{{:session_list_loaded, seq, node}, result}` through `EvoDash.SafeCall.start/4` (a supervisor-start failure clears loading and records the error), and `applied/4` applies only when BOTH the seq and the node still match — success replaces the rows, an error keeps the shown rows and records the error, and a matching result always clears `session_list_loading`.
Rendering: `id="chat-session-list"`, a `gettext("Loading…")` line while loading, a `gettext("Could not load conversations.")` alert for the error, `gettext("No conversations yet.")` when empty, and rows `id={"chat-session-#{id}"}`.
On `current_page == :assistant` a row PATCHES through `SessionActions.url/2`; on any other page it NAVIGATES, because patching to a different LiveView is illegal.
The current row is highlighted from `current_session_id` and carries `aria-current="page"`; markers read "Waiting for you" (`:awaiting_input`, violet), "Running" (a running dot) and "Ended" (muted).
The load OWNER is `EvoDashWeb.LiveHooks.NodeAware` (connected local mount, node-context change, and the `:node_aware_reload_tasks` debounce); the page only asks for a page-local refresh after it adopts or closes a session, and on `{:node_selected, _}` / `{:remote_connection_status, _, _}`.
There is no polling: the section refreshes on the broadcast debounce and after those lifecycle events.

## Approvals

With chat id = agent id, `chat_agent_id` is the session agent id and `chat_task_id` is the agent summary's `task_id`, set on adoption AND on reattach (it may legitimately stay `nil` when the summary carries none).
`ApprovalWorkflow.init/1` + re-recovery run on every session switch (mount, reattach, adoption, new chat, session close), so a previous session's requests never render.
`ApprovalWorkflow` filters on `Map.take(assigns, [:chat_id, :current_node_id, :current_node, :chat_node, :chat_task_id, :chat_agent_id])`.
Pending requests are recovered from the core (`EvoGit.CommandApproval.pending/0`) rather than persisted; approval state stays ephemeral and outside `ChatState`.
Approval surfacing for an interactive `/assistant` session matches a request by `agent_id` OR the scheduler-MINTED `task_id` and requires NO `tasks` row: a repo-less session's task id comes from `SchedMeta` and is never persisted as a task.
A task-less session is recovered via `EvoGit.CommandApproval.pending/0` → `NodeContext.call_remote/4` and answered via `NodeContext.approval_response/3`; the recovery, auto-open and notification gates key on `chat_node` plus those ids only (`scoped?/1` accepts a usable `chat_agent_id` alone).
Nothing in this path reads a `tasks` row, the task list or task-store membership, so a summary without `task_id`, a minted id with no row, and a task-backed one behave identically.

`EvoDashWeb.HomeLive.ApprovalDialog` owns BOTH approval surfaces and is purely presentational — every decision still travels through `ApprovalWorkflow` as the request id plus a whitelisted `"approve"` / `"deny"`.
`approval_bar/1` renders `#approval-status-bar`, a FIXED-HEIGHT (`h-10 shrink-0`) strip directly above the composer whose height is reserved whether or not anything is pending, so an arrival or a resolution never reflows the transcript column.
The strip shows the pending count plus a "Review" button (`open_approval_dialog`), preserves `#approval-recovery-error` with "Retry approvals" (`retry_approvals`, disabled while recovering) and `#approval-response-error` (rendered only when there is no recovery error), and truncates its text to one line.
`approval_dialog/1` renders `<dialog id="approval-dialog" class="modal" phx-hook="DialogModal">`, showing ONE pending request at a time with `prev_approval` / `next_approval` chevrons ("1 of N" stepping, disabled at the ends) and a Deny / Allow-once pair (`approval_response` with `phx-value-request_id` / `phx-value-decision`, both disabled while busy).
Evaluator requests show the exact original Elixir plus the target runtime (`target_text/1` reads the request's `:target_node`, the field the core stamps — an atom or string node name; anything else renders "Unknown target"), legacy command approvals render command + args, and sudo / dangerous requests carry danger styling and the sudo warning ("unrestricted Elixir — no rollback").
The request's OWN optional `:warning` is rendered for ANY tier in `#approval-request-warning` (whitespace-preserved, break-words, error styling) exactly once: text identical to the fixed sudo body copy is never duplicated.
Page assigns `approval_dialog_open` / `approval_dialog_index` are LOCAL VIEW state (never persisted), kept sane by `pending_approvals/1`, `auto_open_approval_dialog/1` (sync when already open, else open), `open_approval_dialog/1`, `sync_approval_dialog/1`, `step_approval_dialog/2` (clamps the current index first, then wraps with `integer_mod/2`) and `clamp_dialog_index/2` (clamps into `0..count-1`); an empty pending list closes the dialog and zeroes the index.
EVERY path that mutates `pending_approvals` — a response success/not-found, a recovery snapshot apply, and either resolution broadcast — runs `sync_approval_dialog/1`, so an emptied list always closes the dialog and a shorter one always clamps the cursor.
Events: `open_approval_dialog`, `dialog_closed`, `prev_approval`, `next_approval`, `retry_approvals`, `approval_response`.
`ApprovalWorkflow.requested_with_notification/2` returns `{socket, payload_or_nil}` and is the live-arrival admission boundary; only first owned live arrivals produce a payload, while duplicates, recovered requests and resolved-id replays do not notify.
The privacy-safe payload contains generic gettext `title`/`body`, the string `request_id`, an opaque `scope` and a stable request-scoped `tag`, never code, commands, credentials or evaluator targets.
These notification APIs are the integration contract between `EvoDashWeb.HomeLive.ApprovalDialogState` (the page wiring) and the browser assets.
`notification_host/1` returns `%{scope:, request_ids:}` for the visible `#assistant-notifications` wrapper around the fixed-height approval bar; bind `data-approval-scope` to `scope` and `data-approval-request-ids` to `Jason.encode!(request_ids)` rather than exposing requests.
`notification_host_json/1` encodes that WHOLE metadata object, not the ids-only attribute value.
The host supplies gettext `data-notification-label-{unsupported,denied,default,granted,requesting,error}` labels for all six browser permission/delivery states.
The browser's `review_approval_notification` event requires `%{request_id: string, scope: string}`; page wiring uses `dialog_index/3` to validate the captured opaque scope AND exact CURRENTLY pending ownership before selecting its index, treating nil as a no-op and never calling `respond/3`.
Missing, malformed or stale scopes fail closed even when a different chat reuses the same pending request id, while `notification_scope?/2` supports browser scope reconciliation.
Review and dismissal confer no authorization; `respond/3` independently rechecks owned pending id, decision whitelist and busy state, and resolved-id tombstones prevent snapshot or broadcast resurrection.
A resolved request (`{:approval_resolved, …}`) re-syncs the dialog index through `sync_approval_dialog/1`.
The dialog is accessibly named/described and initially focuses its static heading (`data-dialog-title`, `data-dialog-initial-focus`, `tabindex="-1"`, `autofocus`), never a decision button.
Its `data-dialog-return-focus="approval-review-button"` matches the strip's Review button ID, and Close uses `data-dialog-dismiss` without `phx-click` or autofocus so the hook reports dismissal exactly once.
It announces busy consent submission and accepts optional `approval_error` for an honest retry message.
`ApprovalWorkflow.approval_responses` maps request ids to response sequence tokens only, not decisions or execution outcomes, and `responded/3` treats `{:ok, :ok}` as a response acknowledgement and `{:ok, {:error, :not_found}}` as already resolved.
Neither acknowledgement proves that an approved evaluation executed successfully, and this subtree has no request-id-to-tool-call execution correlation.
The live `Delta` tool-result projection receives only call id and coarse status, rendering Running/Done/Failed/Timed out through `AssistantMessage.tool_entry/1`, while complete result text is available only in checkpoint history's Thought process projection.
`Messages.transcript/1` deliberately omits raw tool messages from top-level bubbles, so snapshot replacement can remove live informational tool rows rather than preserve an execution audit trail.

## Execution presentation

`ExecutionIndicator.execution_indicator/1` takes `chat_status`, `chat_task_status`, `chat_stream` and optional `pending_approval_count` from actual pending requests, and belongs beside the interrupt button inside the existing fixed-height status row.
It reads only `chat_stream.delta.activity.phase` and `chat_stream.error`, never streamed answer/thinking text, tool arguments/results or approval acknowledgements.
Every core activity phase has its own busy/waiting projection, including the long non-call phases `:compressing` ("Compressing context…", busy) and `:preparing` ("Preparing next turn…", busy), which must never fall through to the generic "Working…" state.
Lifecycle and watch errors outrank cached activity; absent activity means Working, stream failure means Live updates unavailable rather than execution failed, and unknown tool outcomes say Status unavailable rather than Done.
Its stable `#assistant-execution-status` is a polite atomic phase-only live region, while shared tool rows explicitly disable live announcements.
Both surfaces expose `.assistant-execution-indicator` / `.assistant-execution-dot` plus `data-state` / `data-busy` for asset-owned styling, without adding layout rows or changing push-only scrolling.
Pure `state/1` and `tool_state/1` expose `%{state:, label:, busy?:, tone:}`; busy means active processing rather than waiting for a slot, approval or retry.

## Layout stability & scrolling

The transcript column is layout-stable end to end: no layout-shifting wrapper sits around the transcript, the approval strip or the composer column.
The per-message action footer reserves its height while streaming, and the interrupt affordance sits in a constant `h-7` row (`shrink-0 flex h-7 items-center justify-end px-3 sm:px-4`) between the approval strip and the composer, so nothing outside the scroller changes height mid-turn.
`#chat-messages` (`phx-hook="AgentHistoryAutoScroll"`, classes `flex-1 min-h-0 min-w-0 overflow-y-auto overscroll-contain scrollbar-thin`) is scrolled by the `AgentHistoryAutoScroll` hook: instant and coalesced, NEVER animated and never rAF-eased.
A single coalesced `requestAnimationFrame` assigns `scrollTop = scrollHeight`; "pinned" means within 56 px of the bottom (`shouldFollowLatest/4`), so short content and unmeasurable geometry count as pinned.
Only user input (scroll, wheel, touchmove, keydown) re-evaluates the pin; programmatic scrolls never unpin.
A ResizeObserver on the scroller and its direct children re-follows late layout changes (Markdown render, images, `<details>`), and a MutationObserver re-syncs the observed child set; both observers are disconnected while unpinned and everything is released in `destroyed()`.
CSS invariants live in `assets/css/app.css`: `#chat-messages` keeps `overflow-anchor: none`, `overscroll-behavior: contain`, `scroll-behavior: auto` (load-bearing because `html { scroll-behavior: smooth }`) and `min-height: 0`.

## DialogModal hook contract (page-level dependency)

`phx-hook="DialogModal"` is mounted ON the `<dialog>` element.
`mounted/0` opens the dialog with `showModal()` when available, otherwise exposes an honestly nonmodal visible fallback, and focuses static review content rather than Allow/Deny.
Escape, backdrop and `data-dialog-dismiss` controls report `dialog_closed` EXACTLY once per user dismissal through the hook's latch, never denial or authorization.
`updated/0` preserves focus and re-asserts the modal unless dismissed; optional `push_event("dialog_open", %{})` clears the latch and re-shows it.
`destroyed/0` removes its listeners BEFORE closing so a server-driven unmount reports nothing, then restores viable explicit return focus or prior focus without stealing focus already outside.

## Attachments

The attachment pipeline mirrors `ProjectsLive.AttachFile`:
- picker ids: `"chat_file"` (text), `"chat_file_image"`, `"chat_file_audio"`; `EvoDash.DirectoryPicker.pick(self(), picker_id, :file)`; results arrive as `{:directory_picker_result, picker_id, {:ok, path} | :cancelled | :unavailable}`.
- text files append the Markdown block `"\n\n---\n## Attached file: <basename>\n\n" <> content` to the message text.
- image/audio files stage `%{"type" => "image" | "audio", "name" => basename, "media_type" => IANA, "data" => raw bytes}`; base64 is applied ONLY at submit, producing `%{"type", "name", "media_type", "data" => Base.encode64(bytes)}`.
- caps: 4 attachments, 15 MiB each raw; errors flash through `Attachments.describe_error/2` (which delegates `EvoDash.AttachedFile.describe_error/2`).
- pending attachment chips carry a remove action (`chat_attachment_remove`, `phx-value-index`), and pending attachments are cleared exactly on a successful send.
- attaching requires the LOCAL node (`current_node == node()`); a remote/pending node or a picker error only sets `attach_unavailable` and offers the manual-path form, whose reads run on the LOCAL filesystem.
The attach menu sits OUTSIDE `#chat-form`, and the textarea is NOT `phx-update="ignore"`, so staging a text file simply assigns the draft server-side.

## Caps

- transcript: at most 200 entries (newest kept), at most 8 000 graphemes of rendered text per entry
- reasoning: at most 40 entries per transcript entry (`Transcript` cap on the dormant `:reasoning` field) and the delta path caps the live `@thought_process` buffer at 40 entries (newest kept); a history-read rebuild assigns the whole `Messages.to_entries/1` list, which is uncapped
- queued echoes: at most 20
- attachments: 4 files, 15 MiB each raw
- preamble (one-shot fallback only): last 8 exchanges, 600 chars per entry, 4 000-char total

## Reasoning retention

Reasoning belongs to each transcript entry's `:reasoning` list, preserved by `Transcript.normalize/1` and `ChatState` restore.
`Messages.transcript/1` attaches each reply's own history projection, including preceding assistant/tool-only entries since the previous bubble, bounded to 40 entries and reset on an authored user message.
`LiveCall` replaces the current bubble's reasoning from its call-id-keyed complete thinking projection, while legacy text/thinking deltas attach their current-turn bucket through `Transcript.put_reasoning/3`.
`ChatMessages.message_list/1` passes each assistant entry's reasoning to `AssistantMessage`, so completed replies retain their own Thought process section instead of borrowing the last global buffer.
The global `thought_process` remains a reducer/history output but is not the presentation authority; callers that update a transcript without adopting `Messages.transcript/1` must explicitly attach the corresponding reasoning.
Whole activity replacement overwrites captured prefixes, retry removes the failed call's answer and thinking, and checkpoint retirement preserves the committed entry's reasoning.

## Optimistic send & rollback (async send/stop)

`send_draft/3`'s FIRST guard is `send_in_flight == true` → `{:noreply, socket}`: the server-side backstop mirroring the composer's disabled Send, so a refused or already-in-flight send never double-submits; every existing guard (pending remote, missing workspace project, canonical model options) still runs after it.
`start_session_chat/4` bumps `send_seq`, applies the OPTIMISTIC UI synchronously (user bubble through `Transcript.append/2` + `Transcript.entry/2`, `Transcript.put_streaming_text(…, "")`, cleared `chat_draft`/`pending_attachments`, `chat_status: :running`, `chat_node`, `send_in_flight: true`, `send_seq`), stashes the rollback context in `send_pending: %{kind: :start, seq:, text:, task_opts:, node:, prev: %{transcript:, chat_draft:, pending_attachments:, chat_status:}}`, persists, then spawns `SessionActions.start/2`.
`queue_session_message/4` instead sets only `send_in_flight`/`send_seq`/`send_pending` (`kind: :message`, plus `queued?: chat_status == :running`, `policy`, text and the session identity) so a failed queue send loses no draft text, and touches nothing else synchronously.
`SendPath.apply_send_result/3` settles both kinds: a seq that no longer matches `send_seq` (a newer send, `reset_chat/1`, a node or session change) is STALE and returns the socket unchanged apart from clearing the in-flight flag/pending map when they still belong to that seq; a live result clears them and dispatches on the stashed kind — `:start` adopts through `adopt_session/3`, or falls back to the one-shot `:reflect` path with the user bubble ALREADY appended (`start_chat/4`'s `user_appended?`, so the fallback never duplicates it), or restores `prev` and flashes "Failed to start the conversation: …"; `:message` appends the user bubble (plus the queued echo when it was queued), clears draft/attachments and refreshes `TaskTracking`, or runs `send_failure/2` with the draft intact.
`SessionActions.session_unavailable?/1` is the fallback classifier: no session API, `:llm_not_configured`, `:session_api_unavailable`, `{:interactive_root_only, _}`, `{:invalid_session_opts, _}`, `{:unsupported_session_mode, _}` — also inside a `{:start_session_failed, reason}` wrapper; transport errors such as `{:erpc, :noconnection}` and `:timeout` are NOT fallback triggers.
No path can strand `send_in_flight: true`: `reset_chat/1` clears the flag/pending map and advances `send_seq`/`stop_seq`, and a stale or dropped result always leaves the composer usable.
`stop_reply/1` and `finish_chat/4` (the `cancel_chat_task/1` path) follow the same shape with their own `stop_seq`: the spawned call carries `{:chat_stop_result, seq, node, session_id}` / `{:chat_finish_result, seq, node, task_id, assigns, reload?}`, and the matching `handle_info` clause drops a result whose seq no longer matches or whose node/session/task identity moved before applying today's outcomes (the info flash / `stop_ok/3`, else `stop_flash/2`).

## Motion (approval strip + raw/markdown toggle)

`#assistant-notifications` is ALWAYS mounted and animates its own height with the shared layout helper: `motion-collapse-grid` + `data-motion-open={to_string(@approval_strip_open)}`, wrapping ONE child div carrying the `h-10 flex items-center` bar plus the notification end-slot, so un-hiding the strip grows `grid-template-rows` 0fr → 1fr instead of jumping the transcript column by 40 px, and a visible strip still reserves its full `h-10`.
`@approval_strip_open` is `not ((transcript == [] or chat_status == :ended) and pending_approvals == [])`: the strip collapses to zero height only for an empty or ended chat with nothing pending, and reserves its full height in every other state (including a request arriving in a fresh chat).
The per-message raw/markdown toggle fades in BOTH directions: the raw branch is a `<span class="motion-panel motion-panel-open min-w-0 break-words whitespace-pre-wrap">` and the markdown branch keeps `motion-panel motion-panel-open md-content …`; `md-content` is deliberately OFF the raw branch (a raw entry must render no `.md-content`) and the raw branch stays a `<span>`.
No transcript scroller is ever animated: `#chat-messages` and every scrolling container stay instant (see Layout stability & scrolling) — motion is confined to these two layout-stable surfaces, and motion.css's global `prefers-reduced-motion` backstop covers both.

## Async contract (message tags + stale guards)

The LiveView process never blocks on a store/registry/cross-node call. Every interactive-session mutation — `SendPath.start_session_chat/4`, `SendPath.queue_session_message/4`, `TaskEvents.stop_reply/1` and their private `finish_chat/4` — is dispatched with `EvoDash.SafeCall.start(self(), tag, fun)` and settled by a tagged `handle_info` clause, so delta processing and timers keep running for the whole RPC; render-critical loads run under `EvoDash.TaskSupervisor`.
`EvoDash.SafeCall.start/4` sends tags NESTED: `{{tag, …}, result}`; tasks spawned with `Task.Supervisor.start_child` + manual `send/2` carry FLAT tags.

| Spawned by | Self-message | Stale guard |
|-----------|--------------|-------------|
| `spawn_attach/2` (reattach / adoption) via `SafeCall.start/4` | `{{:session_attached, seq, node, session_id}, result}` | `session_attach_seq` + node + session_id |
| `SessionList.spawn_load/2` (supervised task + `SafeCall.run/1`) | `{{:session_list_loaded, seq, node}, result}` | `session_list_seq` + node |
| `async_lookup_agent/2` (`Task.Supervisor.start_child`) | `{:chat_agent_lookup, node, seq, task_id, agent}` | `chat_fetch_seq` + node + task_id |
| `async_fetch_history/2` | `{:chat_history_loaded, node, seq, agent_id, result}` | `chat_fetch_seq` + node + agent_id |
| `async_fetch_task/2` | `{:chat_task_loaded, node, seq, task_id, task}` | `chat_task_fetch_seq` + node + task_id |
| `SendPath.start_session_chat/4` / `queue_session_message/4` via `SafeCall.start/4` | `{{:chat_send_result, seq}, result}` | `send_seq` (matched against the stashed `send_pending.seq`) + the `send_pending` node / session identity |
| `TaskEvents.stop_reply/1` via `SafeCall.start/4` | `{{:chat_stop_result, seq, node, session_id}, result}` | `stop_seq` + node + `session_id` |
| `TaskEvents.cancel_chat_task/1` (`finish_chat/4`) via `SafeCall.start/4` | `{{:chat_finish_result, seq, node, task_id, assigns, reload?}, result}` | `stop_seq` + node + `chat_task_id` |
| `Watch.attach/1` (supervised watcher registration + snapshot) | `{:chat_stream_ready, node, seq, agent_id, result}` | `stream_attach_seq` + node + `session_id` + the current `chat_stream.agent_id` |
| `ModelSelect.load/1` via `SafeCall.start/4` | `{{:model_select_loaded, seq, node}, result}` | `model_select_seq` + node + selection scope |
| `SourceGate.spawn_availability_check/3` | `{:source_availability_loaded, seq, node, result}` | `source_check_seq` + node |
| `ApprovalWorkflow` | `{{:approval_pending_loaded, seq, scope}, result}`, `{{:approval_workflow_response, seq, scope, request_id}, result}` | monotonic token + chat/node/task/agent scope |

What each settles: `{:chat_send_result, …}` finishes the optimistic send in `SendPath.apply_send_result/3` (session adoption, the one-shot fallback, or a rollback to `send_pending.prev`), `{:chat_stop_result, …}` / `{:chat_finish_result, …}` finish the stop and cancel controls in `TaskEvents.chat_stop_result/2` / `chat_finish_result/2` (the info flash, or `stop_ok/3` then `ChatState.persist`), and `{:chat_task_loaded, …}` finishes the one-shot terminal handoff in `TaskEvents.chat_task_loaded/2` → `SendPath.finalize_terminal/2` (dropped outright for a sealed watch).

Session-list refresh rides the existing node-filtered `"tasks"` broadcast debounce (`handle_info(:node_aware_reload_tasks, …)`) and re-runs after a session is adopted or closed — no polling.
A loading flag always settles: every spawned loader sends its result term, including `{:error, reason}` from `SafeCall.run/1` or supervisor-start failure.

## Test seams (resolved AT SPAWN/CALL TIME)

- `:home_session_attach_runner` (2-arity `(node, session_id)`)
- `:home_session_list_runner` (1-arity `(node)`)
- `:home_session_start_runner` (2-arity `(node, opts)`)
- `:home_session_send_runner` (4-arity `(node, agent_id, message, policy)`)
- `:home_session_close_runner` (3-arity `(node, agent_id, reason)`)
- `:home_session_stop_runner` (2-arity `(node, agent_id)`, default `&EvoDash.NodeContext.stop_current_turn/2`, read by `TaskEvents.stop_reply/1`)
- `:home_agent_watch_runner` (3-arity `(node, agent_id, watcher_pid)`, default `&EvoDash.NodeContext.register_agent_watcher/3`, read inside the spawned registration task)
- `:home_agent_unwatch_runner` (3-arity `(node, agent_id, watcher_pid)`, default `&EvoDash.NodeContext.unregister_agent_watcher/3`, read inside the spawned unregister task)
- `:home_agent_history_runner` (2-arity `(node, agent_id)`, default `&EvoDash.NodeContext.get_agent_history/2`, read by `async_fetch_history/2` before the spawned task)
- `:approval_pending_runner` (pending-approval recovery read)
- `:approval_responder` (approval response route)
- `:source_availability_runner` / `:source_clone_runner` / `:source_update_runner` (Genesis Source gate)

Each is `Application.get_env(:evo_dash, key, default)` read inside the spawned function, so injecting an exiting runner proves the page survives with its loading flag cleared.

## Live delta streaming (push-only, shipped)

Live per-chunk deltas ARE consumed: a mounted `?session=<id>` page holds one `%Delta{}` per watched agent and applies `{:agent_delta, agent_id, seq, batch}` broadcasts through `EvoDashWeb.HomeLive.Delta.apply_batch/5`.
`EvoDashWeb.HomeLive.Watch.attach/1` owns both halves of the attach in the processes that must run them: the consumer-local PubSub subscription is made INLINE by the LiveView, while the watcher registration + snapshot runs in an `EvoDash.TaskSupervisor` child with the LiveVIEW pid as the consumer (the session monitors that pid).
`EvoDashWeb.HomeLive.Delta.apply_batch/5` keeps ONE assistant bubble per turn: it accumulates EVERY text segment of that turn across tool calls into the same entry and closes it only at a turn boundary (`{:turn, info}`, `{:yield, text}`, `{:finished, status}`), where `EvoDashWeb.HomeLive.Transcript.close_streaming/1` DROPS a bubble that never received text.
`{:tool_call, id, name}` appends the `:running` `:tool` row without finalizing the bubble, so text arriving after a tool call continues the same bubble and a thinking/tool-only turn renders no bubble at all.
`Delta.streamed_text?/1` is the per-turn streamed-text flag (`text_in_turn` for the open turn, `text_in_closed_turn` for the turn closed last).
Batches arriving before the snapshot lands are buffered by Watch and replayed in arrival order only when newer than the snapshot; covered batches (`seq <= snapshot.seq`) are ignored.
A matching `{:chat_stream_ready, …}` result atomically installs Watch's hydrated transcript, thought process, metadata and sequence baseline, applies `snapshot.phase`, then folds replayed outcomes; the snapshot remains the only resync, with no polling or independent history overwrite.
A `{:finished, status}` with no current or last-closed turn answer text requests exactly ONE final atomic snapshot through the same serial watch worker, never an independent history read.
The final request advances `stream_attach_seq`, retains the subscription and last coherent surface, buffers newer batches and admits only its matching node/session/token result at or above the finish sequence before replaying newer deltas.
Buffered silent finishes replayed after initial registration take this same route, while streamed finishes and duplicate finish batches never request another automatic snapshot.
The terminal outcome is retained across a final snapshot so an earlier phase in the reply cannot reopen the composer, and snapshot errors or worker/session disappearance retain the cached transcript and failed-watch history ownership for explicit retry.
The terminal `{:agent_stream_closed, agent_id, %Snapshot{phase: :done}, seq}` handoff is admitted by `Watch.closed/4` directly, without a registration or history read, even before initial registration settles or after its failure.
The handoff requires matching agent/session, BEAM node, target identity and current watch generation, matching snapshot/envelope sequences and a sequence at least as new as every applied, buffered or required watermark.
Equal sequence is admitted deliberately because terminal checkpoint messages may share the already-observed finish batch's sequence.
Admission replaces the whole checkpoint/activity display surface through `snapshot_result/3`, closes streaming entries, clears buffered batches and errors, advances the watch generation and seals the watch with `closed_seq`.
No message text, turn, count or index heuristic is used to deduplicate terminal history.
A sealed watch keeps history ownership but ignores every subsequent ready reply, delta, duplicate handoff or worker failure, so late traffic cannot reopen or overwrite the terminal surface.
`StreamFold` routes the handoff to `Watch.closed/4` and installs its returned surface atomically through the same `apply_watch_result/1` funnel, applying the authoritative snapshot's terminal status as well as its `:done` phase.
`Watch.closed?/1` identifies a sealed watch in the current scope so parent task/summary lifecycle handlers can ignore reordered non-authoritative lifecycle events after the handoff instead of reopening or changing its terminal status.
The handoff has no registration token, so it is admitted as session-authoritative truth for the currently owned scope rather than attributed to an old registration request.
A missing handoff still retains the cached transcript if the legacy final read loses the session-removal race; there is no polling, independent history fallback or new durability guarantee.
The core captures current-call text/thinking unconditionally, including before any watcher attaches, and `Watch.snapshot_result/3` includes that captured prefix in its returned display surface.
A history reply that lands when no writer is left (`chat_status` `:ended` or `:idle`) is finalized by `finalize_bubble/1`, so it never stays `streaming: true`.
`EvoDash.NodeContext` is the boundary: `subscribe_agent_deltas/1`, `unsubscribe_agent_deltas/1`, `register_agent_watcher/3`, `unregister_agent_watcher/3`, `watch_agent_snapshot/2`.
Batch events are `{:text, chunk}`, `{:thinking, chunk}`, `{:tool_call, id, name}`, `{:tool_result, id, status}`, `{:turn, info}`, `{:yield, text}`, `{:finished, status}`; the reducer reports `outcome` and the page folds it (`:yield` → idle + `:awaiting_input` + cleared echoes, `{:finished, _}` → ended + the terminal status, anything else → failed).
A WATCHED session never refetches its whole history on an `:agent_updated` message-count change (`Watch.stream_active?/1`), which is the polling that feature removes; the delta path persists chat state instead.
Detach (`new_chat`, `leave_session`, node switch, terminal status, a successful close, `terminate/2`) unsubscribes inline and fires the watcher unregister in a supervised child; the session's own monitor is the real reaper.
The funnel has TWO surfaces, not one: the bubble text is a transcript entry (`text` + `streaming`) rendered by `AssistantMessage.assistant_message/1`, while reasoning and tool calls are THOUGHT-PROCESS entries (`%{turn, timestamp, type, data}` with `data` = `%{content, tool_calls, reasoning_details, tool_name, metadata}`) rendered by the private `AssistantMessage.thought_entry/1`; a `:tool` transcript entry renders as a quiet status row (`AssistantMessage.tool_entry/1`).
Transcript entries are `%{id, role, text, streaming}` plus optional `:reasoning` and, for tool entries, `:tool_name`/`:tool_call_id`/`:tool_status`/`:turn`; `role` is whitelisted to `:user | :assistant | :error | :tool` and `ChatMessages.message_list/1` renders all four plus a total fallback for anything else.
`Transcript.normalize_entry/1` rebuilds every entry from the known keys only, so a NEW entry field does not survive a `ChatState.restore/1` round-trip unless it is added there.
The turn meta line under the last assistant bubble (`Delta.meta/0`: `turn`/`total_tokens`/`duration_ms`/`usage`) is assigned as `chat_stream_meta` and passed to `ChatMessages.message_list/1` as `stream_meta`.
New chat is enabled while `:idle` or `:ended` and clears the draft, per-chat refs, echoes and pending attachments; node switches reset chat state without cancelling the previous session.
The AssistantComposer hook submits the form on Enter and Shift+Enter keeps the newline, and model selection stays usable during a run but applies to the NEXT session only.

## Signature-gated chat persistence (streaming write coalescing)

`EvoDashWeb.HomeLive.ChatState.persist/1,2` is the ONLY writer of chat state into `EvoDash.ChatHistory`, and it COALESCES pure streamed-text growth because a delta batch arrives roughly every 75 ms while `ChatHistory.put_state/2` deep-copies the whole transcript + thought process through a GenServer call.
`build/1` stays the pure, defensive assigns → map extractor and `restore/1` stays the total mount-direction normalizer, so the persisted shape is unchanged in both directions.
`write_state?/3` gates every write on `signature/1` — a signature of the AUTHORITATIVE parts of the state only: `chat_status`, `chat_task_status`, `chat_task_id`, `chat_agent_id`, `session_id`, `session_mode`, `chat_node`, `chat_draft`, `agent_message_count`, `selected_model_id`, `model_spec`, `model_selection_scope`, `model_selection_error`, `workbench_draft_key`, `assistant_conversation_id`, the NUMBER of queued echoes, and the transcript's length plus each entry's `{id, role, streaming, tool_status}` metadata.
Streamed CONTENT is deliberately outside the signature — an entry's `text`/`html`, its `:reasoning`, and the `thought_process` buffer are exactly what grows on every batch — so a growing bubble alone never counts as a state change.
A CHANGED signature writes IMMEDIATELY, whatever the elapsed time, so every lifecycle and structural change (status, task/agent/session identity, draft, message count, selection, echo count, an appended or finalized or tool-status-changed transcript entry) reaches the store at once.
`force: true` (`ChatState.persist(socket, force: true)`) always writes regardless of the signature, for call sites that must write unconditionally.
An UNCHANGED signature (only streamed text grew) still writes once `@throttle_ms` (1000 ms) has elapsed since this chat's previous write, so a long turn's text is at most about one second stale instead of invisible indefinitely.
The markers are PROCESS-DICTIONARY entries `{ChatState, :last_signature, chat_id}` and `{ChatState, :last_write, chat_id}` (the latter a `System.monotonic_time(:millisecond)` stamp read by `throttle_elapsed?/1`), written together by `mark_write/2` — never a GenServer, ETS table or `:persistent_term`: `persist/2` only ever runs in the owning LiveView process, so they die with that process (a remounted tab is a fresh process whose missing `:no_signature` marker writes immediately) and a chat switch simply uses a different key.
The trade-off is bounded and stated in the moduledoc: at most about one second of streamed text can be missing from the cache if a tab closes mid-turn, while the next signature change restores the full authoritative state.
`persist/2` still returns the socket and stays TOTAL (garbage or absent chat state neither raises nor gains a `try/rescue`), and every existing option — notably `clear_empty_draft: true` and the draft / draft-key branches — behaves exactly as before.

## Masked-assign (`assigns[:key] || default`) audit

Every `assigns[:key] || default` read under `home_live/**` stays a masked read: the map is seeded by `ChatBootstrap.base_assigns/0` + `init/1` and completed by the `EvoDashWeb.LiveHooks.NodeAware` / `Appearance` on-mount hooks, but a helper may still be handed a hand-built partial map, so a `KeyError` would be a real regression instead of a caught bug.
`ChatState.build/1` keeps every default deliberately: it is a pure extractor that must also persist a hand-built partial assign map (`transcript`, `thought_process`, `chat_draft`, `chat_status`, `queued_echoes`, `task_action_ids`, `task_action_pending`), and tests persist such maps.
`Watch` (`chat_stream`, `chat_stream_meta`, `chat_stream_worker`, `chat_stream_worker_monitor`, `stream_attach_seq`, `transcript`, `thought_process`), `SendPath` (`queued_echoes`, `transcript`, `assistant_conversation_id`), `TaskTracking`/`TaskCard` (`task_action_ids`, `task_action_pending`, `task_action_checking`, `task_tracking_seq`, `task_tracking_scope`, `task_tracking_timer`, `task_tracking_loading`, `task_tracking_error`, `tracked_tasks`), `TaskPicker` (`task_picker`), `ApprovalWorkflow` (`pending_approvals`, `approval_responses`, `approval_recovery_new`, `approval_recovery_removed`, `approval_resolved_requests`, `chat_node`), `SessionList` (`session_list`, `session_list_loading`, `session_list_error`, `session_list_seq`, `current_session_id`, `current_page`), `Workspace` (`workspace`, `workspace_expanded`, `workbench_draft_key`, `session_attach_pending?`), `Composer` (`chat_draft`, `provider_profiles`, `model_selections`, `model_spec`), `Uploads` (`pending_attachments`, `chat_upload_scope`) and `ModelSelection` (`current_node`, `current_node_id`) all read keys `ChatBootstrap.init/1` seeds at mount.
Making those reads explicit requires `assign_new/3`-seeding each key in `ChatBootstrap.init/1`, so the defensive reads stay the contract and NEW keys read the same masked way.
Three keys are seeded rather than masked: `remote_targets` (→ `[]`), `connection_statuses` (→ `%{}`) and `accent_color` (→ `"blue"`) get `assign_new/3` in `ChatBootstrap.init/1` (mirrored by `render/1`, which covers a direct template render with a partial assign map) and are read as `@remote_targets` / `@connection_statuses` / `@accent_color`, because the `NodeAware` / `Appearance` on-mount hooks always set them.
`workbench_draft` and the `current_node` / `current_node_id` family keep their masked reads.

## Known Issues — remaining hot-path costs and the out-of-package call sites

Each item is verified against this package's HEAD and names the exact file that must change; the one that remains lives OUTSIDE this package's write scope (`apps/evo_dash/lib/evo_dash/chat_history.ex`), so the owning parent node must make the change.

- **The whole transcript still re-renders on every delta.** `ChatMessages.message_list/1` is a plain function component, so one growing bubble re-renders up to 200 history rows per ~75 ms batch. The O(n²) rescans are gone (the last-assistant index is computed once before the loop, and a finalized answer re-uses its cached `:html`), but unaffected bubbles are still diffed per batch; the remaining lever is a change-tracked `live_component` keyed by entry id for the assistant bubble.
- **`EvoDash.ChatHistory` serializes every read/write through one GenServer** (`apps/evo_dash/lib/evo_dash/chat_history.ex`): `put_state/2` deep-copies the whole transcript per call, `list_chats/0` full-scans so `SessionList.cached_chats/1` issues 1 + N `get_state/1` calls, and the `{{:current}, chat_id}` pointer has no client/node key, so a second browser on a shared host adopts the first viewer's conversation. Single-key `get_state`/`put_state`/`list_chats` can run directly on the public ETS table, with a bulk `conversations/0` read for the sidebar, a `{client_id, node}`-keyed current pointer and creation-time pruning — all with the public function names unchanged.

## Constraints

- No `try/rescue` around config/core loading; `{:error, …}` tuples from `NodeContext` are the failure channel.
- Config/model-selection state is loaded ONLY by `ModelSelection.assign_model_select/1` from the `handle_params/3` pipeline (`session_resolution.ex:102`), i.e. on mount, every `push_patch`/`push_navigate` (session adoption, New chat, node switch, connection-transition patch) and never on a timer; there is no refresh event, so an existing cached bundle (`model_snapshot`, `model_selection_bundle`, `provider_profiles`, `model_selections`, `model_selection_enabled`) stays until the next param change.
- The page subscribes to `"tasks"`, `"agents"` and `"approvals"` only (`home_live.ex:300-302`) plus `"agent:<id>"` via `Watch` — never `"config"` or `"scheduler_config"`, so a config reload broadcast does not reach it.
- No code in this subtree reads `config.toml`/`credentials.toml` or computes config paths; the only file reads are user attachments (`attachment_pipeline.ex:133`, `:178`).
- Every new user-facing string is `gettext`-wrapped; Chinese comments only for short/ambiguous labels; never run `mix gettext.extract`/`merge`/`translate` during feature work.
- `?session=` parses with `Integer.parse/1` + a positive guard; no `String.to_atom/1` on client input.
- Never block the LiveView on a cross-node call; every async load carries a monotonic seq + node stale guard. Assistant messages remain push-only with no history polling. `TaskTracking` separately refreshes linked active/pausing task summaries every three seconds, stops at resting/terminal states, and ignores other node/conversation results.
- Preserve interaction markers: `#chat-form`, `#chat-messages`, `#chat-llm-selection`, `#chat-composer-controls`, `#chat-interrupt-button`, `#chat-session-list`, `#chat-session-ended`, `#approval-status-bar`, `#approval-dialog`, `#approval-recovery-error`, `#approval-response-error`, and `#assistant-notifications`. The empty surface now uses `#assistant-welcome` with the existing Genesis logo and translated slogan; four quick actions sit below the composer and disappear after conversation starts. Source availability no longer gates chat. Keep the textarea label, Send/Stop and Enter/Shift+Enter semantics.

## Assistant workspace and task controls

`Workspace` and `WorkspaceComponent` select an optional existing project or VCT workspace without reading its files.
The picker has TWO labelled groups: "Projects" (the recent project mounts, event `workspace_select`) and "Workspaces" (workspace mounts with their resolved member count and a missing marker), and a workspace row expands through a pure server assign (`workspace_expand`) into its resolved members plus every unresolvable ref, while picking the row itself posts `workspace_pick`.
A selection is the total, term-safe map `%{kind: :project | :workspace, point: point | nil, path: abs_os_path, name: binary, node: node(), node_id: node_id | nil, members: [member], missing: [ref]}` that is persisted into `ChatHistory`, so `Workspace.normalize/1` also accepts a legacy map with no `:kind`/`:point` and defaults it to `kind: :project, point: nil`.
A workspace is a draft/conversation SCOPE, never an execution target: its selection carries the WORKSPACE point as identity and the FIRST resolved member's OS path as `path`, so everything reaching a task start or an agent-session start is an absolute OS path and never a `vct:` value.
Members resolve in stored order inside the same supervised `SafeCall.start/3` load as the list (never in the LiveView, never polled); a workspace with no resolvable member is refused with a message naming the missing refs and no selection is applied, and a workspace whose resolution errors keeps `members: []` with every ref reported as missing.
The panel shows both identities of an active workspace selection (the workspace name plus the concrete execution project) and lists the missing refs, `Workspace.select_mounted/2` accepts either an absolute path or a VCT point (a project point selects that project, a workspace point selects the workspace scope), and it keeps its "no longer open on the selected node" error for a vanished project.
Draft and conversation scope identity is the VCT token (`DraftScope.project/1`-or-`DraftScope.workspace/1`, with the raw absolute path as the legacy fallback), so `workbench_draft_key` is `{node_id, target_node, scope_token, draft_id}` and the same repo re-selected under another path spelling or through a workspace keeps ONE draft while two different points over one OS path stay separate.
`?wb_project=` keeps carrying a PATH (the spelling the workbench client builds) and is resolved server-side: when `select_mounted/2` lands a selection whose point differs from the token baked into `workbench_draft_key`, `adopt_workbench_scope/1` re-settles the key to the point-keyed version and adopts the draft or one-shot chat found under the legacy path key, deleting that retired spelling.
Adoption never runs while a turn is streaming or a session owns the chat (`current_session_id` guard), `Workspace.draft_project/1` still returns the EXECUTION path (the value workbench.js compares with the active project), and `Workspace.draft_scope/1` returns the token.
`TaskTracking` owns followed task links and action reconciliation; `TaskCard` renders them. `TaskPicker` loads searchable, paginated summaries on menu open and follows by selection, with manual ID entry secondary. Node/conversation/sequence guards reject stale asynchronous responses and pending remote targets never use local data.

`Uploads` owns native browser upload validation, progress and consumption; `Attachments` stages text/media and encodes media once at send. Browser upload works independently of the deployment host. Server-path attachment is a separate, local-node-only entry. An empty/whitespace draft with no completed attachment cannot send; uploads in progress block all send events while leaving the draft editable. New chat and session/node switches cancel pending uploads.

The shared task catalog is `EvoGit.TaskControl.Tools`; Assistant actions use real structured approvals, while MCP retains its own transport authorization. Startup checks tracked static assets and performs a full navigation on a version mismatch before initializing the Assistant, preserving node/session parameters.
- Node switches reset chat state without cancelling the previous session; pending remote targets never load local models or launch locally; a failed model snapshot stays an error, never a silent Auto.

## Transcription contract (history → display bubbles)

`Messages.transcript/1` returns `%{transcript: transcript, entries: entries}`: `entries` is the raw `Messages.to_entries/1` projection feeding the collapsible thought-process panel, while `transcript` is the ORDERED display bubble list built by `DisplayMessages.bubbles/1`.
Bubbles are `{:user | :assistant, text}` pairs in chronological order (user1 → assistant1 → user2 → assistant2), one per surviving history message — never all user turns followed by one joined assistant blob.
`:system` messages never bubble; an `:assistant` message bubbles through `Messages.message_text/1` (thinking parts excluded) and an empty/thinking-only one is skipped; `:tool` role messages never bubble, because live tool rows come from the deltas and the thought-process panel keeps the raw detail.
A `:user` message bubbles ONLY when it is user-authored: `DisplayMessages.user_authored?/1` returns the core's `metadata[:user_authored]` marker (atom or string key, boolean values only) and `:unknown` when the marker is absent.
With `:unknown`, the shape heuristics decide: the turn-0 wrapper is unwrapped so only its `<objective>…</objective>` body shows, a `<context>`-prefixed message is dropped, `metadata[:checkpoint] == true` is dropped, and injected notices are dropped (the runtime-context refresh notice, `[NOTICE] `/`[WARNING] `/`[URGENT] ` prefixes, the turn-budget warning and the graceful-cancel save-work message).
`Messages.transcript/1` is the SINGLE builder for both the history read (`apply_history/3`) and the watch snapshot (`{:chat_stream_ready, …}`), so the projection also governs every attach/reattach and the persisted `ChatState` transcript.
`bubbles/1` is total — nil or garbage input yields `[]` and it never raises.

## Mounted integration assertion boundaries
`ChatMessages.message_list/1` wraps every transcript row in `#chat-entry-<entry.id>`, and `Transcript.entry/3` generates unique-integer string ids, so history rebuilds do not preserve row ids across remounts.
A streamed assistant answer has `.help-caret`, while a finalized answer exposes `button[id^="assistant-copy-"][data-content]` and ordinarily `.md-content`; scope answer assertions outside the Thought process details because history-derived thought entries can repeat the answer text.
`Watch.snapshot_result/3` combines checkpoint messages with complete captured `snapshot.activity` through Delta, including already-emitted current-call answer and thinking prefixes.
`Delta` ignores unknown events, so consumers must implement any richer core event vocabulary explicitly rather than assuming it is rendered here.
`Delta` retains the streamed bubble's entry id across a turn boundary, so a subsequent authoritative yield updates that reply rather than appending a duplicate answer.

## Watch/Delta reuse constraints

`Watch.snapshot_result/3` accepts only `%EvoGit.Agent.Stream.Snapshot{}` inside the flat registration answer or its SafeCall wrapper and returns `%{snapshot:, delta:, meta:, transcript:, thought_process:}`.
Its display surface combines checkpoint messages through `Messages.transcript/1` with the complete captured `snapshot.activity` through the same Delta reducer used for live batches.
The parent page must atomically install that surface and its sequence baseline, apply `snapshot.phase` as lifecycle authority and replay only buffered batches newer than the snapshot.
A current call is keyed by its fresh attempt id, whole activity replacements overwrite its prefixes, chunks append, `:retry_wait` removes failed-attempt output and idle checkpoint retirement preserves the committed answer.
`Delta.apply_batch/5` never advances `delta.seq` or rejects stale batches, so every consumer must perform sequence gating and update the accepted sequence outside the reducer.
The live tool events carry only call id/name and result status, so Delta cannot reconstruct tool arguments, result bodies, raw history roles or session phase for a full inspector.
`Watch.ready/5` admits only the current node/session/generation result and returns `{:ok, socket, surface}`, with the atomic checkpoint/activity surface followed by arrival-ordered buffered batches strictly above its sequence.
`Watch.push/4` returns `{:buffered, socket}` before seeding, `{:ok, socket, surface}` for a newer seeded batch, or `{:ignored, socket}` for obsolete scope or sequence.
Both APIs return `{:error, socket, reason}` on failure, retain the failed watch's history ownership and expose the reason at `chat_stream.error` rather than silently falling back to an independent history read.
The parent installs returned `transcript`, `thought_process` and `meta` with the returned socket in the same callback, applies `surface.snapshot.phase` before replayed `surface.outcome` on ready, and forwards worker `:DOWN` messages to `Watch.down/4`.
`stream_active?/1` includes pending and failed watches in the current scope, so independent attach/history results cannot overwrite either their display surface or phase; independent reads must additionally capture `stream_attach_seq` and reject results after it changes, even following detach.
Registration-time buffers cap at 128 batches or 1 MiB and overflow is an explicit failure requiring reattachment, not silent event loss.
The worker serializes every register/unregister command, including detach during a blocked registration, and monitors the consumer to clean up after its death.
Healthy same-scope attaches are no-ops; scope identity includes both node and agent, detach advances the generation, and worker-start failures settle as `{:watch_start_failed, reason}`.
A `:starting` session ACCEPTS the watch: the core answers with its pre-state snapshot (`phase: :starting`, `status` nil, `seq` 0, empty messages, its live activity), keeps the registration and continues the same sequence once the run starts — so slow setup never defers the dashboard's first cut, and the admitted `:starting` snapshot already maps to `chat_status: :running` with `chat_task_status: :running`.
The bounded ten-second readiness retry (`:home_agent_watch_start_timeout_ms`) is therefore LEGACY-NODE tolerance only: it fires solely when a node still refuses with `{:error, {:bad_state, :starting}}`, and that refusal is logged as `reason=starting_timeout` and delivered as one failed readiness reply.
Cleanup RPC failures are logged without automatic retries, and unexpected worker death fails the watch explicitly while the core's own consumer monitor remains its final reaper.

## Presentation and test notes

- The assistant message's `status_label/1` (`assistant_message.ex`) renders `:awaiting_input` as the gettext label "Awaiting input"; the badge and dot colours come from `EvoDashWeb.Helpers.task_status_badge/1` / `task_status_dot_class/1` (the violet idle-session family).
- `home_live_test.exs`'s `:reflect` assertions exercise the fallback path only, because its fixture configures `model_profiles: []` (so `start_session` answers `:llm_not_configured`).
