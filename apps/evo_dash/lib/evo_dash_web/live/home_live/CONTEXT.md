# HomeLive — Genesis Assistant (`/help`)

## Intent

Genesis Assistant chat page (`EvoDashWeb.HomeLive`, route `GET /help`, sidebar **Assistant**).
A conversation is ONE long-lived interactive agent session (one agent id, one worktree, one `prompt_cache_key`, many messages), not a fresh `:reflect` task per message.
The session's agent id IS the conversation's addressable identity: `/help?session=<agent_id>`.
Repo-less: sessions start with `repo_less: true` and `EvoGit.Agents.SelfReflective`, so there is no worktree, no git operation and no subagent spawning.
When interactive sessions are unavailable on the node, the page falls back to the legacy one-shot `:reflect` task-per-message mode (`session_mode: :one_shot`) with a gettext notice.

## Routing Table

- `session_actions.ex` → `EvoDashWeb.HomeLive.SessionActions` — session identity URL builder/parser, session launch + message send + close executors, attach snapshot loader, conversation-list loader, session-status helpers (the ONLY place that talks to `EvoDash.NodeContext`'s session RPCs)
- `session_list.ex` → `EvoDashWeb.HomeLive.SessionList` — the left-rail conversation list panel (async loader, pure row building, `session_list/1` HEEx)
- `send_path.ex` → `EvoDashWeb.HomeLive.SendPath` — the send path and the finalize block moved out of the page module: `send_chat/2`, `send_draft/3`, `do_send_chat/3`, `sendable_status?/1`, `reflect_objective/2`, `dispatch_send/5`, `queue_session_message/4`, `normalize_send/1`, `push_queued_echo/2`, `message_count_grew?/2`, `send_failure/2`, `start_session_chat/4`, `start_failure/4`, `adopt_session/3`, `start_chat/3` plus `finalize_streaming/2`, `finalize_terminal/2`, `finalize_completed/2`, `finalize_cancelled/2`, `finalize_failed/2`, `clear_task_refs/1`; `home_live.ex` keeps thin `defp` delegations and the page-level handlers
- `composer.ex` → `EvoDashWeb.HomeLive.Composer` — the composer card (textarea, attachment chips + attach menu, model capsule, Send/Stop, Interrupt turn, queued echoes)
- `attachments.ex` → `EvoDashWeb.HomeLive.Attachments` — the `/help` attachment pipeline (picker ids, staging, caps, submit conversion)
- `transcript.ex` → `EvoDashWeb.HomeLive.Transcript` — transcript model, normalization/caps, per-message reasoning, bounded preamble
- `chat_state.ex` → `EvoDashWeb.HomeLive.ChatState` — persisted per-chat shape (`build/1`, `persist/1`, `restore/1`) over `EvoDash.ChatHistory`
- `messages.ex` → `EvoDashWeb.HomeLive.Messages` — ReqLLM history → bubble text / thought-process entries (total)
- `agent_stream.ex` → `EvoDashWeb.HomeLive.AgentStream` — root-agent lookup, `message_count` gating, final-result extraction
- `model_select.ex` / `model_selection.ex` → model snapshot loading and canonical provider/model/reasoning selection state
- `approval_workflow.ex` / `approval_card.ex` → ephemeral approval cards, scoping, remount recovery
- `assistant_message.ex` / `user_message.ex` / `chat_messages.ex` → chat bubble rendering
- `source_gate.ex` → the "Genesis source not downloaded yet" gate

## Session model

A conversation state is identified by `session_id` (the session agent id) stored in the URL as `?session=<agent_id>`.
`session_id` is authoritative in `handle_params/3`: every param change re-resolves it; a MISSING `session` param means the local draft / new-chat state.
URLs are built ONLY through the pure `SessionActions.url/2` (`"/help?session=7&node=t1"`); navigation is ALWAYS `push_patch`, never `push_navigate`, so the LiveView process (and its transcript) survives.
`SessionActions.parse_session/1` parses the param with `Integer.parse/1` plus a positive guard — no atom conversion, no `String.to_integer/1` rescue.
`session_mode` is `:interactive` (a live session) or `:one_shot` (the legacy `:reflect` fallback), or `nil` for a fresh draft.
An agent id is a positive integer, so it doubles as the `EvoDash.ChatHistory` chat id — no synthetic id mapping exists.

Session phases (`:starting | :running | :awaiting_input | :cancelling | :finalizing | :done`) map to the page's `chat_status`:
- `:awaiting_input` → `:idle` (the composer is enabled; the session is waiting for the user)
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

Reflect-fallback triggers (`SessionActions.session_unavailable?/1`): `function_exported?/3` false, or `{:interactive_root_only, _}`, `{:invalid_session_opts, _}`, `{:unsupported_session_mode, _}`, `:llm_not_configured` — including each wrapped in `{:start_session_failed, reason}` by the remote API. Transport errors (`{:erpc, :noconnection}`, `:timeout`) are NOT fallback triggers: they flash an error and never silently change mode.
The core generates its own random-hex task id and does not return it; the page resolves the session's task id afterwards from the agent summary (`list_agents/1` row `task_id`).
All existing guards hold on both paths: source gate, pending-remote guard, canonical model validation before any send, attachment caps.

## Queue, interrupt and Stop

The composer stays usable while `chat_status == :running`; only `:cancelling`, `:ended` and the source gate block it.
Sending while running posts policy `:queue` and appends a transient QUEUED echo: `queued_echoes` is a list of `%{id: binary, text: binary, at: integer}` (newest 20, ids from `System.unique_integer([:positive])`), rendered after the last transcript entry with gettext "Queued — sent at the next turn boundary". An echo is NOT a fake assistant message.
Echoes are reconciled away when the agent's real message appears (an `:agent_updated` `message_count` increase) or on stop / close / session switch.
`Interrupt turn` (`#chat-interrupt-button`, visible only while `:running`) posts policy `:interrupt`.
**`:queue` and `:interrupt` are applied IDENTICALLY today — both land at the next turn boundary.** UI copy must never claim a chunk-level halt; the button reads "Send now (interrupt turn)" with a Chinese comment for the translator.
Stop is separate and stays distinct: `NodeContext.cancel_task/2` (graceful cancel) on the session's task id, falling back to `close_session/3` when no task id is known.

## Reattach

`handle_params/3` with `?session=<id>`: sets `session_id`, `current_session_id`, `chat_id = session_id`, `session_mode: :interactive`, clears per-chat refs (`chat_task_id`, `chat_task_status`, `agent_message_count`, queued echoes), and restores the cached transcript from `ChatHistory.get_state(session_id)` through `ChatState.restore/1` (total — garbage degrades to defaults).
ONE supervised attach task per (seq, node, session) gathers `list_agents/1` + `list_awaiting_input/1` + `get_agent_history/2` and returns `SessionActions.load_attach/2`'s `{:ok, %{summary:, awaiting?:, history:}}`.
Apply only when the `session_attach_seq` is current, the node matches and the `session_id` matches.
A non-empty history REPLACES the cached transcript (`Messages.to_entries/1`); the phase comes from the summary / awaiting list.
Session gone (no summary, not awaiting) with an empty cache → "This session has ended." empty state, composer disabled, New chat affordance.
Session gone with a cached transcript → render it read-only (composer disabled) plus New chat.
Reattach NEVER starts a task on read.

## Approvals

With chat id = agent id, `chat_agent_id` is the session agent id and `chat_task_id` is the agent summary's `task_id`, set on adoption AND on reattach.
`ApprovalWorkflow.init/1` + re-recovery run on every session switch (mount, reattach, adoption, new chat, session close), so a previous session's cards never render.
`ApprovalWorkflow` filters on `Map.take(assigns, [:chat_id, :current_node_id, :current_node, :chat_node, :chat_task_id, :chat_agent_id])`.
Pending requests are recovered from the core (`EvoGit.CommandApproval.pending/0`) rather than persisted; approval state stays ephemeral and outside `ChatState`.

## Attachments

The `/help` attachment pipeline mirrors `ProjectsLive.AttachFile`:
- picker ids: `"chat_file"` (text), `"chat_file_image"`, `"chat_file_audio"`; `EvoDash.DirectoryPicker.pick(self(), picker_id, :file)`; results arrive as `{:directory_picker_result, picker_id, {:ok, path} | :cancelled | :unavailable}`.
- text files append the Markdown block `"\n\n---\n## Attached file: <basename>\n\n" <> content` to the message text.
- image/audio files stage `%{"type" => "image" | "audio", "name" => basename, "media_type" => IANA, "data" => raw bytes}`; base64 is applied ONLY at submit, producing `%{"type", "name", "media_type", "data" => Base.encode64(bytes)}`.
- caps: 4 attachments, 15 MiB each raw; errors flash through `Attachments.describe_error/2` (which delegates `EvoDash.AttachedFile.describe_error/2`).
- pending attachment chips carry a remove action (`chat_attachment_remove`), and pending attachments are cleared exactly on a successful send.
- attaching requires the LOCAL node (`current_node == node()`); a remote/pending node or a picker error only sets `attach_unavailable` and offers the manual-path form on the local filesystem.
The `/help` textarea is NOT `phx-update="ignore"`, so staging a text file simply assigns the draft server-side.

## Caps

- transcript: at most 200 entries (newest kept), at most 8 000 graphemes of rendered text per entry
- reasoning: at most 40 reasoning entries per assistant message (per-message, not one global last-turn buffer)
- queued echoes: at most 20
- attachments: 4 files, 15 MiB each raw
- preamble (one-shot fallback only): last 8 exchanges, 600 chars per entry, 4 000-char total

## Reasoning retention

Reasoning is attached PER assistant transcript entry (an optional `:reasoning` field on the entry) instead of one global last-turn buffer, so scrolling back shows each turn's own reasoning.
It is derived from the same `get_agent_history/2` read through the `Messages` funnel and stays total (unreadable shapes yield no reasoning, never a crash).
`Transcript.put_reasoning/3` updates one entry by id; `ChatState` persists the bounded shape.

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
- `:approval_responder` (approval response route)
- `:source_availability_runner` / `:source_clone_runner` / `:source_update_runner` (Genesis Source card)

Each is `Application.get_env(:evo_dash, key, default)` read inside the spawned function, so injecting an exiting runner proves the page survives with its loading flag cleared.

## Live delta streaming — DEFERRED (documented contract, not consumed)

Live per-chunk deltas are NOT consumed yet: the whole-history read `get_agent_history/2` triggered by the `:agent_updated` `:message_count` event remains the ONLY live transcript path, and `Messages.to_entries/1` → transcript entries → `AssistantMessage` (+ thought process) is the single funnel.
Future contract when deltas are wired in:
- `EvoGit.Agent.Stream.watch/1` → `{:ok, snapshot, seq}` — the snapshot is the ONLY resync.
- delivery on `EvoGit.PubSub` topic `"agent:<id>"` as message `{:agent_delta, agent_id, seq, batch}`.
- batch variants: `{:text, binary}`, `{:thinking, binary}`, `{:tool_call, id, name}`, `{:tool_result, id, status}`, `{:turn, %{usage, duration_ms}}`, `{:yield, text}`, `{:finished, status}`.
- reconciliation drops any batch with `seq <= snapshot.seq`; there is NO replay buffer and NO polling — watcher registration + monitor is the consumer gate (zero watchers ⇒ no callbacks and no broadcast).

## Constraints

- No `try/rescue` around config/core loading; `{:error, …}` tuples from `NodeContext` are the failure channel.
- Every new user-facing string is `gettext`-wrapped; Chinese comments only for short/ambiguous labels; never run `mix gettext.extract`/`merge`/`translate` during feature work.
- `?session=` parses with `Integer.parse/1` + a positive guard; no `String.to_atom/1` on client input.
- Never block the LiveView on a cross-node call; every async load carries a monotonic seq + node stale guard; no polling.
- Preserve the render-test DOM markers: `#chat-form`, `#chat-messages`, `#chat-llm-selection`, `#chat-composer-controls`, the `h1` "Genesis Assistant", the textarea placeholder/aria-label "Message Genesis Assistant…", Send/Stop semantics, "Enter to send · Shift+Enter for a new line", the empty-state heading "What would you like Genesis to do?" and its four suggestion chips.
- Node switches reset chat state without cancelling the previous session; pending remote targets never load local models or launch locally; a failed model snapshot stays an error, never a silent Auto.

## Known Issues

- `EvoDashWeb.Helpers.task_status_badge/1` has no `:awaiting_input` clause, so the page renders that status through its own local total helper rather than editing Helpers.
- A genuinely new row in the conversation list animates nowhere — the panel has no enter animation by design (it is re-rendered from a plain list on every reload).
- `home_live_test.exs`'s `:reflect` assertions exercise the fallback path only, because its fixture configures `model_profiles: []` (so `start_session` answers `:llm_not_configured`).
