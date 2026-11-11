# HomeLive — Genesis Assistant (`/assistant`)

## Intent

Genesis Assistant chat page (`EvoDashWeb.HomeLive`, route `GET /assistant`, sidebar **Assistant**).
The legacy `/help` URL is a 302 to `/assistant` through `EvoDashWeb.RedirectController`, with the query string preserved (`/help?session=7` → `/assistant?session=7`).
A conversation is ONE long-lived interactive agent session (one agent id, one worktree, one `prompt_cache_key`, many messages), not a fresh `:reflect` task per message.
The session's agent id IS the conversation's addressable identity: `/assistant?session=<agent_id>`.
Repo-less: sessions start with `repo_less: true` and `EvoGit.Agents.SelfReflective`, so there is no worktree, no git operation and no subagent spawning.
When interactive sessions are unavailable on the node, the page falls back to the legacy one-shot `:reflect` task-per-message mode (`session_mode: :one_shot`) with a gettext notice.

## Routing Table

- `home_live.ex` → `EvoDashWeb.HomeLive` — the page module: assigns, `handle_params/3` session resolution, the events (send / stop / interrupt / model selection / attachments / approvals), the approval dialog view state, the async result handlers and the delta funnel
- `session_actions.ex` → `EvoDashWeb.HomeLive.SessionActions` — session identity URL builder/parser, session launch + message send + close executors, attach snapshot loader, conversation-list loader, session-status helpers (the ONLY place that talks to `EvoDash.NodeContext`'s session RPCs)
- `session_list.ex` → `EvoDashWeb.HomeLive.SessionList` — the SECTION BODY of the shared app-layout sidebar's **Conversations** section (async loader, pure row building, `session_list/1` HEEx); the layout owns the section header and renders it below Active Tasks on every dashboard page
- `send_path.ex` → `EvoDashWeb.HomeLive.SendPath` — the send path and the finalize block: `send_chat/2`, `send_draft/3`, `do_send_chat/3`, `sendable_status?/1`, `reflect_objective/2`, `dispatch_send/5`, `queue_session_message/4`, `normalize_send/1`, `push_queued_echo/2`, `message_count_grew?/2`, `send_failure/2`, `start_session_chat/4`, `start_failure/4`, `adopt_session/3`, `start_chat/3` plus `finalize_streaming/2`, `finalize_terminal/2`, `finalize_completed/2`, `finalize_cancelled/2`, `finalize_failed/2`, `clear_task_refs/1`; `home_live.ex` keeps thin `defp` delegations and the page-level handlers
- `composer.ex` → `EvoDashWeb.HomeLive.Composer` — the composer card (textarea, attachment chips + attach menu, model capsule, Send/Stop, Interrupt turn, queued echoes)
- `attachments.ex` → `EvoDashWeb.HomeLive.Attachments` — the page's attachment pipeline (picker ids, staging, caps, submit conversion)
- `transcript.ex` → `EvoDashWeb.HomeLive.Transcript` — transcript model, normalization/caps, per-message reasoning, streaming bubbles (`append_streaming_text/2`, `finalize_streaming/1`), `:tool` entries (`tool_entry/4`, `put_tool_status/3`), bounded preamble
- `delta.ex` → `EvoDashWeb.HomeLive.Delta` — the PURE, TOTAL delta reducer (`new/3`, `seed/3`, `meta/0`, `apply_batch/5`); no processes, no side effects
- `watch.ex` → `EvoDashWeb.HomeLive.Watch` — the watch lifecycle: `attach/1` (LiveView-process subscription + supervised watcher registration whose snapshot seeds the delta), `detach/1`, `snapshot_result/3`, `stream_active?/1`
- `chat_state.ex` → `EvoDashWeb.HomeLive.ChatState` — persisted per-chat shape (`build/1`, `persist/1`, `restore/1`) over `EvoDash.ChatHistory`
- `messages.ex` → `EvoDashWeb.HomeLive.Messages` — ReqLLM history → bubble text / thought-process entries (total), plus `transcript/1`, the ONE shared builder (`%{transcript:, entries:}`) both the history read and the watch snapshot seed through
- `agent_stream.ex` → `EvoDashWeb.HomeLive.AgentStream` — root-agent lookup, `message_count` gating, final-result extraction
- `model_select.ex` / `model_selection.ex` → model snapshot loading and canonical provider/model/reasoning selection state
- `approval_workflow.ex` → `EvoDashWeb.HomeLive.ApprovalWorkflow` — ephemeral approval request state, session scoping, off-process recovery, response routing
- `approval_dialog.ex` → `EvoDashWeb.HomeLive.ApprovalDialog` — the two PURELY PRESENTATIONAL approval surfaces: the fixed-height status strip (`approval_bar/1`) and the single-request modal (`approval_dialog/1`)
- `assistant_message.ex` / `user_message.ex` / `chat_messages.ex` → chat surface rendering: message bubbles plus the two EMPTY states (`empty_state/1` greeting with the four suggestion chips, `session_ended_state/1` ended session)
- `source_gate.ex` → the "Genesis source not downloaded yet" gate

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
`SessionActions.send_message/5` sends `%{text:, attachments:}` when attachments are present and a bare binary otherwise.
The core generates its own random-hex task id and does not return it; the page resolves the session's task id afterwards from the agent summary (`list_agents/1` row `task_id`).
All existing guards hold on both paths: source gate, pending-remote guard, canonical model validation before any send, attachment caps.

## Queue, interrupt and Stop

The composer stays usable while `chat_status == :running`; only `:cancelling`, `:ended`, the source gate, a pending remote target and an unready model snapshot block it.
Sending while running posts policy `:queue` and appends a transient QUEUED echo: `queued_echoes` is a list of `%{id: binary, text: binary, at: integer}` (newest 20, ids from `System.unique_integer([:positive])`), rendered after the last transcript entry with gettext "Queued — sent at the next turn boundary". An echo is NOT a fake assistant message.
Echoes are reconciled away when the agent's real message appears (an `:agent_updated` `message_count` increase) or on stop / close / session switch.
`Interrupt turn` (`#chat-interrupt-button`, visible only while `:running`, labelled "Send now (interrupt turn)") posts policy `:interrupt`.
**`:queue` and `:interrupt` are applied IDENTICALLY today — both land at the next turn boundary.** UI copy must never claim a chunk-level halt; the button label carries a Chinese comment for the translator.
Stop is separate and stays distinct: `NodeContext.cancel_task/2` (graceful cancel) on the session's task id, falling back to `SessionActions.close/3` when no task id is known, leaving the page in `:cancelling` until the terminal event.

## Reattach

`handle_params/3` with `?session=<id>`: sets `session_id`, `current_session_id`, `chat_id = session_id`, `session_mode: :interactive`, clears per-chat refs (`chat_task_id`, `chat_task_status`, `agent_message_count`, queued echoes), and restores the cached transcript from `ChatHistory.get_state(session_id)` through `ChatState.restore/1` (total — garbage degrades to defaults).
ONE supervised attach task per (seq, node, session) gathers `list_agents/1` + `list_awaiting_input/1` + `get_agent_history/2` and returns `SessionActions.load_attach/2`'s bare map `%{summary:, awaiting?:, history:}` (no `{:ok, _}` tag — `EvoDash.SafeCall.run/1` wraps it, which is why `apply_attach/2` matches `{:ok, %{…}}`).
Apply only when the `session_attach_seq` is current, the node matches and the `session_id` matches.
A non-empty history REPLACES the cached transcript (`Messages.to_entries/1`); the phase comes from the summary / awaiting list.
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

With chat id = agent id, `chat_agent_id` is the session agent id and `chat_task_id` is the agent summary's `task_id`, set on adoption AND on reattach.
`ApprovalWorkflow.init/1` + re-recovery run on every session switch (mount, reattach, adoption, new chat, session close), so a previous session's requests never render.
`ApprovalWorkflow` filters on `Map.take(assigns, [:chat_id, :current_node_id, :current_node, :chat_node, :chat_task_id, :chat_agent_id])`.
Pending requests are recovered from the core (`EvoGit.CommandApproval.pending/0`) rather than persisted; approval state stays ephemeral and outside `ChatState`.

`EvoDashWeb.HomeLive.ApprovalDialog` owns BOTH approval surfaces and is purely presentational — every decision still travels through `ApprovalWorkflow` as the request id plus a whitelisted `"approve"` / `"deny"`.
`approval_bar/1` renders `#approval-status-bar`, a FIXED-HEIGHT (`h-10 shrink-0`) strip directly above the composer whose height is reserved whether or not anything is pending, so an arrival or a resolution never reflows the transcript column.
The strip shows the pending count plus a "Review" button (`open_approval_dialog`), preserves `#approval-recovery-error` with "Retry approvals" (`retry_approvals`, disabled while recovering) and `#approval-response-error` (rendered only when there is no recovery error), and truncates its text to one line.
`approval_dialog/1` renders `<dialog id="approval-dialog" class="modal" phx-hook="DialogModal">`, showing ONE pending request at a time with `prev_approval` / `next_approval` chevrons ("1 of N" stepping, disabled at the ends) and a Deny / Allow-once pair (`approval_response` with `phx-value-request_id` / `phx-value-decision`, both disabled while busy).
Evaluator requests show the exact original Elixir plus the target runtime, legacy command approvals render command + args, and sudo / dangerous requests carry danger styling and the sudo warning ("unrestricted Elixir — no rollback").
Page assigns `approval_dialog_open` / `approval_dialog_index` are LOCAL VIEW state (never persisted), kept sane by `pending_approvals/1`, `auto_open_approval_dialog/1` (sync when already open, else open), `open_approval_dialog/1`, `sync_approval_dialog/1`, `step_approval_dialog/2` (clamps the current index first, then wraps with `integer_mod/2`) and `clamp_dialog_index/2` (clamps into `0..count-1`); an empty pending list closes the dialog and zeroes the index.
Events: `open_approval_dialog`, `dialog_closed`, `prev_approval`, `next_approval`, `retry_approvals`, `approval_response`.
On `{:approval_requested, request}` (a genuinely NEW live request, never a recovery snapshot) the page auto-opens the dialog when it is not already open and pushes `task_notification` with `%{title: gettext("Approval needed"), body: gettext("Genesis is waiting for your approval."), tag: "genesis-approval"}` to the hidden `#assistant-notifications` host (`phx-hook="BrowserNotifications"`).
A resolved request (`{:approval_resolved, …}`) re-syncs the dialog index through `sync_approval_dialog/1`.

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
`mounted/0` opens it with `showModal()` only when that function exists and the dialog is not already open, and installs a `close` listener that pushes `dialog_closed` EXACTLY once per user dismissal (ESC or backdrop close, latched).
`updated/0` re-asserts the modal unless the user dismissed it, so a re-render never re-summon a dismissed dialog; an optional `push_event("dialog_open", %{})` clears the latch and re-shows it.
`destroyed/0` removes its listener BEFORE closing, so a server-driven unmount reports nothing to the server.

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

Reasoning is NOT attached per transcript entry today: `Transcript.put_reasoning/3` exists and is unit-tested but has NO production call site, and `AssistantMessage.assistant_message/1` never reads an entry's `:reasoning`.
The rendered thought process is ONE global `@thought_process` assign — the full `Messages.to_entries/1` list of the last `get_agent_history/2` read, rewritten wholesale by `apply_history/3` and cleared only by `reset_chat/1` — passed ONLY to the LAST assistant entry (`ChatMessages.message_list/1`), so earlier assistant entries render no thought section.
Entries built by `Transcript.entry/3` do always carry `reasoning: []`, and `Transcript.normalize/1` preserves an existing `:reasoning` key, so the field is dormant scaffolding for a future per-message migration, not a live path.
`ChatState` persists `thought_process` verbatim and rebuilds it through `normalize_thought_process/1` on restore (`%{turn, timestamp, type, data}`, with `data` kept verbatim).
The delta path reuses that one buffer: `{:thinking, chunk}` accumulates into a SINGLE upserted entry (`type: "assistant"`, `data.metadata.thinking == true`, `data.reasoning_details: [%{text:, type: "thinking"}]`) for the current turn, so the collapsible section grows live and never shows the same text as the bubble (`Messages.message_text/1` excludes `:thinking` parts).

## Async contract (message tags + stale guards)

The LiveView process never blocks on a store/registry/cross-node call. Per-click mutations are `EvoDash.SafeCall.run/1,2` inline; render-critical loads run under `EvoDash.TaskSupervisor`.
`EvoDash.SafeCall.start/4` sends tags NESTED: `{{tag, …}, result}`; tasks spawned with `Task.Supervisor.start_child` + manual `send/2` carry FLAT tags.

| Spawned by | Self-message | Stale guard |
|-----------|--------------|-------------|
| `spawn_attach/2` (reattach / adoption) via `SafeCall.start/4` | `{{:session_attached, seq, node, session_id}, result}` | `session_attach_seq` + node + session_id |
| `SessionList.spawn_load/2` (supervised task + `SafeCall.run/1`) | `{{:session_list_loaded, seq, node}, result}` | `session_list_seq` + node |
| `async_lookup_agent/2` (`Task.Supervisor.start_child`) | `{:chat_agent_lookup, node, seq, task_id, agent}` | `chat_fetch_seq` + node + task_id |
| `async_fetch_history/2` | `{:chat_history_loaded, node, seq, agent_id, result}` | `chat_fetch_seq` + node + agent_id |
| `async_fetch_task/2` | `{:chat_task_loaded, node, seq, task_id, task}` | `chat_task_fetch_seq` + node + task_id |
| `Watch.attach/1` (supervised watcher registration + snapshot) | `{:chat_stream_ready, node, seq, agent_id, result}` | `stream_attach_seq` + node + `session_id` + the current `chat_stream.agent_id` |
| `ModelSelect.load/1` via `SafeCall.start/4` | `{{:model_select_loaded, seq, node}, result}` | `model_select_seq` + node + selection scope |
| `SourceGate.spawn_availability_check/3` | `{:source_availability_loaded, seq, node, result}` | `source_check_seq` + node |
| `ApprovalWorkflow` | `{{:approval_pending_loaded, seq, scope}, result}`, `{{:approval_workflow_response, seq, scope, request_id}, result}` | monotonic token + chat/node/task/agent scope |

Session-list refresh rides the existing node-filtered `"tasks"` broadcast debounce (`handle_info(:node_aware_reload_tasks, …)`) and re-runs after a session is adopted or closed — no polling.
A loading flag always settles: every spawned loader sends its result term, including `{:error, reason}` from `SafeCall.run/1` or supervisor-start failure.

## Test seams (resolved AT SPAWN/CALL TIME)

- `:home_session_attach_runner` (2-arity `(node, session_id)`)
- `:home_session_list_runner` (1-arity `(node)`)
- `:home_session_start_runner` (2-arity `(node, opts)`)
- `:home_session_send_runner` (4-arity `(node, agent_id, message, policy)`)
- `:home_session_close_runner` (3-arity `(node, agent_id, reason)`)
- `:home_agent_watch_runner` (3-arity `(node, agent_id, watcher_pid)`, default `&EvoDash.NodeContext.register_agent_watcher/3`, read inside the spawned registration task)
- `:home_agent_unwatch_runner` (3-arity `(node, agent_id, watcher_pid)`, default `&EvoDash.NodeContext.unregister_agent_watcher/3`, read inside the spawned unregister task)
- `:approval_pending_runner` (pending-approval recovery read)
- `:approval_responder` (approval response route)
- `:source_availability_runner` / `:source_clone_runner` / `:source_update_runner` (Genesis Source gate)

Each is `Application.get_env(:evo_dash, key, default)` read inside the spawned function, so injecting an exiting runner proves the page survives with its loading flag cleared.

## Live delta streaming (push-only, shipped)

Live per-chunk deltas ARE consumed: a mounted `?session=<id>` page holds one `%Delta{}` per watched agent and applies `{:agent_delta, agent_id, seq, batch}` broadcasts through `EvoDashWeb.HomeLive.Delta.apply_batch/5`.
`EvoDashWeb.HomeLive.Watch.attach/1` owns both halves of the attach in the processes that must run them: the consumer-local PubSub subscription is made INLINE by the LiveView, while the watcher registration + snapshot runs in an `EvoDash.TaskSupervisor` child with the LiveVIEW pid as the consumer (the session monitors that pid).
A delta arriving before the snapshot lands is dropped — `chat_stream.delta` is `nil` until then — and a delta covered by the snapshot (`seq <= snapshot.seq`, `EvoGit.Agent.Stream.stale?/2`) is dropped too; the snapshot is the ONLY resync (no replay buffer, no poll loop, never a full-context broadcast).
`EvoDash.NodeContext` is the boundary: `subscribe_agent_deltas/1`, `unsubscribe_agent_deltas/1`, `register_agent_watcher/3`, `unregister_agent_watcher/3`, `watch_agent_snapshot/2`.
Batch events are `{:text, chunk}`, `{:thinking, chunk}`, `{:tool_call, id, name}`, `{:tool_result, id, status}`, `{:turn, info}`, `{:yield, text}`, `{:finished, status}`; the reducer reports `outcome` and the page folds it (`:yield` → idle + `:awaiting_input` + cleared echoes, `{:finished, _}` → ended + the terminal status, anything else → failed).
A WATCHED session never refetches its whole history on an `:agent_updated` message-count change (`Watch.stream_active?/1`), which is the polling that feature removes; the delta path persists chat state instead.
Detach (`new_chat`, `leave_session`, node switch, terminal status, a successful close, `terminate/2`) unsubscribes inline and fires the watcher unregister in a supervised child; the session's own monitor is the real reaper.
The funnel has TWO surfaces, not one: the bubble text is a transcript entry (`text` + `streaming`) rendered by `AssistantMessage.assistant_message/1`, while reasoning and tool calls are THOUGHT-PROCESS entries (`%{turn, timestamp, type, data}` with `data` = `%{content, tool_calls, reasoning_details, tool_name, metadata}`) rendered by the private `AssistantMessage.thought_entry/1`; a `:tool` transcript entry renders as a quiet status row (`AssistantMessage.tool_entry/1`).
Transcript entries are `%{id, role, text, streaming}` plus optional `:reasoning` and, for tool entries, `:tool_name`/`:tool_call_id`/`:tool_status`/`:turn`; `role` is whitelisted to `:user | :assistant | :error | :tool` and `ChatMessages.message_list/1` renders all four plus a total fallback for anything else.
`Transcript.normalize_entry/1` rebuilds every entry from the known keys only, so a NEW entry field does not survive a `ChatState.restore/1` round-trip unless it is added there.
The turn meta line under the last assistant bubble (`Delta.meta/0`: `turn`/`total_tokens`/`duration_ms`/`usage`) is assigned as `chat_stream_meta` and passed to `ChatMessages.message_list/1` as `stream_meta`.
New chat is enabled while `:idle` or `:ended` and clears the draft, per-chat refs, echoes and pending attachments; node switches reset chat state without cancelling the previous session.
Enter submits through a server-maintained Shift latch, Shift+Enter keeps the newline, and model selection stays usable during a run but applies to the NEXT session only.

## Constraints

- No `try/rescue` around config/core loading; `{:error, …}` tuples from `NodeContext` are the failure channel.
- Every new user-facing string is `gettext`-wrapped; Chinese comments only for short/ambiguous labels; never run `mix gettext.extract`/`merge`/`translate` during feature work.
- `?session=` parses with `Integer.parse/1` + a positive guard; no `String.to_atom/1` on client input.
- Never block the LiveView on a cross-node call; every async load carries a monotonic seq + node stale guard; no polling.
- Preserve the render-test DOM markers: `#chat-form`, `#chat-messages`, `#chat-llm-selection`, `#chat-composer-controls`, `#chat-interrupt-button`, `#chat-session-list`, `#chat-session-ended`, `#genesis-source-gate`, `#approval-status-bar`, `#approval-dialog`, `#approval-recovery-error`, `#approval-response-error`, `#assistant-notifications`, the `h1` "Genesis Assistant", the textarea placeholder/aria-label "Message Genesis Assistant…", Send/Stop semantics, "Enter to send · Shift+Enter for a new line", the empty-state heading "What would you like Genesis to do?" and its four suggestion chips.
- Node switches reset chat state without cancelling the previous session; pending remote targets never load local models or launch locally; a failed model snapshot stays an error, never a silent Auto.

## Known Issues

- The assistant message's `status_label/1` (`assistant_message.ex`) renders `:awaiting_input` as the gettext label "Awaiting input"; the badge and dot colours come from `EvoDashWeb.Helpers.task_status_badge/1` / `task_status_dot_class/1` (the violet idle-session family).
- `home_live_test.exs`'s `:reflect` assertions exercise the fallback path only, because its fixture configures `model_profiles: []` (so `start_session` answers `:llm_not_configured`).
