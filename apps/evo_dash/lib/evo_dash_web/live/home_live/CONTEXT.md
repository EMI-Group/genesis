# HomeLive — Home Chat Page

## Intent

`EvoDashWeb.HomeLive` (`home_live.ex`) is the ChatGPT-style chat page rendered at `GET /home` — the conversation surface wired to the repo-less `:reflect` self-reflective agent. The user talks to Genesis itself: send a message → a `:reflect` task starts on the viewed node → the task's root agent (`EvoGit.Agents.SelfReflective`) runs repo-less (read-only Genesis source access + WebSearch + task-control + guide_user tools) → its assistant turns stream into chat bubbles → the terminal task result finalizes the transcript. Everything is push-based (PubSub) and node-aware (`?node=`), with all cross-node fetches off the LiveView process.

The support modules under `home_live/` keep `home_live.ex` (~700 lines) focused on LiveView wiring; all heavy lifting is pure and unit-testable.

## API Surface

### `EvoDashWeb.HomeLive` (`home_live.ex`)

LiveView with `use EvoDashWeb, :live_view` (SetLocale/NodeAware/DesktopQuit/UpdateStatus/Guide on-mount hooks automatic) + `use Gettext, backend: EvoDashWeb.Gettext`. Renders through `EvoDashWeb.Layouts.app` with `current_page={:dashboard}` (the active-nav atom that highlights the Projects nav item — HomeLive renders at `/home`).

**State assigns** (seeded in `mount/3`):

| Assign | Meaning |
|--------|---------|
| `transcript` | `[entry]` — chat transcript, oldest first; entry = `%{id, role: :user\|:assistant\|:error, text, streaming}` |
| `chat_draft` | textarea draft (kept in sync by the `chat_input` phx-change) |
| `chat_status` | `:idle \| :running \| :cancelling` — drives input/Stop/New-chat disabled states |
| `chat_task_id` | the active `:reflect` task id (`nil` when idle) |
| `chat_agent_id` | the root agent id (`nil` until `agent_registered`/lookup succeeds) |
| `agent_message_count` | last observed agent `:message_count` (HistoryGate) |
| `chat_fetch_seq` | monotonic stale-guard counter for agent-lookup + history fetches |
| `chat_task_fetch_seq` | SEPARATE monotonic counter for the terminal `get_task` fetch (see Constraints) |
| `shift_down` | shift-latch for Enter-to-submit (see Notes for Agents) |
| `current_path` | `~p"/home"` — required by NodeAware's node-switch `push_patch` |

**Events**: `send_message` (form `phx-submit`, `"message"` param; a fallback clause uses `chat_draft`), `chat_input` (draft sync), `chat_keydown`/`chat_keyup` (Enter/Shift latch), `new_chat` (reset, idle-only), `stop` (graceful cancel).

**handle_info clauses**: `{:task_updated, id, status, node}` + `{:task_deleted, id, node}` (routed through `NodeAware.handle_task_info/2` — node filter + 300ms sidebar debounce — then chat-specific handling); `{:agent_registered, id, summary, node}` (own-task → set agent id + refetch history); `{:agent_updated, id, changed_fields, node}` (own agent AND `:message_count in changed_fields` → refetch); `{:agent_removed, ...}` (no-op — the terminal task event finalizes); `{:agents_updated, node}` (missed-registration fallback lookup when running-but-no-agent); `:node_aware_reload_tasks` (sidebar reload via `NodeAware.reload_tasks/1` + `clear_task_reload_pending/1`); `{:chat_agent_lookup, ...}` / `{:chat_history_loaded, ...}` / `{:chat_task_loaded, ...}` (async results, stale-guarded); `{:node_selected, ...}` / `{:remote_connection_status, ...}` (delegated to NodeAware); catch-all.

### `EvoDashWeb.HomeLive.Transcript` (`transcript.ex`)

Pure chat-transcript model. Entries are plain maps `%{id: String.t(), role: :user|:assistant|:error, text: String.t(), streaming: boolean()}` (list, oldest first).

- `new/0` → `[]`
- `append(t, entry)` → `t`
- `entry(role, text, opts \\ [])` — opts `:streaming` (default `false`); id from `System.unique_integer([:positive])`
- `put_streaming_text(t, text)` — updates the LAST streaming entry's text, or appends a new streaming assistant entry when none is streaming (idempotent; used when a refetched agent history replaces the in-progress bubble)
- `finalize_assistant(t, text)` — sets the last streaming entry `streaming: false` + replaces its text, or appends a non-streaming assistant entry (terminal-result path)
- `append_error(t, text)`
- `build_preamble(t, opts \\ [])` → `{:ok, String.t()} | :empty` — bounded conversation memory (see Notes for Agents)

### `EvoDashWeb.HomeLive.Messages` (`messages.ex`)

Converts native `%ReqLLM.Message{}` lists (as returned by `EvoDash.NodeContext.get_agent_history/2`) into bubble text. Never raises.

- `assistant_text(messages)` → `String.t()` — text parts of every `:assistant` message joined with `"\n"`; user/system/tool messages skipped (the reflect agent's user-role messages echo the sent objective — HomeLive renders the user bubble itself)
- `to_entries(messages)` → `[%{turn, type, data}]` — mirrors `EvoDashWeb.AgentsLive`'s conversion shape (tool_calls/reasoning_details/tool_name/metadata ride along in `data`); kept for parity/testing

### `EvoDashWeb.HomeLive.AgentStream` (`agent_stream.ex`)

Pure helpers for the agent stream + final result. Never raises.

- `find_root_agent(agents, task_id)` → `map | nil` — first summary with `:task_id == task_id`, preferring `agent_module == EvoGit.Agents.SelfReflective` when several match
- `message_count(agent)` → `non_neg_integer()` (0 when absent)
- `changed?(prev_count, agent)` → boolean — HistoryGate-style: `message_count(agent) != (prev_count || 0)`
- `task_id_from_start({:ok, map})` → `{:ok, id} | {:error, :no_task_id}` — accepts both `:id` and `"id"` keys; nil map → error
- `extract_final_text(task_result)` → `{:ok, String.t()} | :empty | :error` — decodes the tagged-tuple result (`{:ok, %{result: text, ...}}`, atom OR string keys); `:empty` = succeeded with no text; `:error` = `{:error, _}` / `{:exit, _}` / anything else

## Constraints

- **Scope**: `home_live.ex` + these support modules are self-contained (no other `lib/` files were touched by this feature); all node data goes through `EvoDash.NodeContext`. Router wiring: `live("/home", HomeLive, :index)`; the root `/` maps to the Projects page (`ProjectsLive`, also mounted at `/projects`).
- **All node data goes through `EvoDash.NodeContext`** (start/cancel/history/get_task/list_agents) with a `socket.assigns[:current_node] || node()` fallback.
- **Async-only cross-node fetches**: agent lookup, history fetch, and terminal `get_task` run in `Task.Supervisor.start_child(EvoDash.TaskSupervisor, ...)` with `send(pid, ...)` results. Justified `try/rescue` at the async boundary ONLY (the closure runs OUTSIDE the LiveView process; a crash must never silently lose the result message — rescue returns `[]`/`nil` so the caller degrades instead of wedging). No `try/rescue` in the LiveView process itself.
- **Two stale-guard counters — keep them separate**: `chat_fetch_seq` guards agent-lookup + history results; `chat_task_fetch_seq` (SEPARATE) guards the terminal `get_task` result. A late `agent_updated` broadcast (cross-topic PubSub reordering, graceful-cancel grace window) bumps the shared counter, which would stale-guard-drop the terminal result and wedge the chat in `:running` forever.
- **Terminal handling**: `:completed`/`:cancelled` → `async_fetch_task` → `finalize_terminal` (nil task → "The conversation was deleted."; `:completed` → `extract_final_text` → text / "No response." / "The task failed."; `:cancelled` → preserved result text or "Stopped." — graceful cancel preserves the result when the agent completed). `:failed` → "The task failed." + `clear_task_refs`. `{:task_deleted, ...}` → "The conversation was deleted." + `clear_task_refs`. `clear_task_refs` nils task/agent refs + `chat_status: :idle`, KEEPS the transcript (New chat re-enabled; prevents duplicate finalization from repeated broadcasts).
- **Node switch** (`handle_params/3`): capture `prev_node` BEFORE `NodeAware.assign_node/2`; a change → `reset_chat/1` (the old task belongs to the old node; prevents foreign task/agent matches). `current_path` re-assigned `~p"/home"` on every params run.
- **Onboarding**: dead-render only, `Code.ensure_loaded?(EvoGit.Config.VersionState)`-guarded `onboarding_needed?/0` → `push_navigate(socket, to: "/welcome")` (mirrors ProjectsLive; avoids redirect loops).
- **i18n**: all user-facing strings gettext-wrapped; ambiguous labels carry zh_CN meaning comments (e.g. "Chat with Genesis" → "与 Genesis 对话", "New chat" → "新对话", "Stop" → "停止", "Send" → "发送", "Start a conversation" → "开始对话"). NO gettext extract/merge/translate during development.

## Notes for Agents — Chat data-flow

1. **Send** (`send_chat/2`): build the objective (`Transcript.build_preamble(transcript)` → `"Previous conversation:\nUser: …\nAssistant: …\n\nNew message: <text>"`, or bare text on `:empty`) → append optimistic user bubble + empty streaming assistant bubble (pulsing dots) → `chat_status: :running` → `EvoDash.NodeContext.start_task(node, :reflect, mode: "reflect", objective: objective)` — NO `:path` key → `AgentStream.task_id_from_start/1` → `async_lookup_agent`. `{:error, reason}` / no-id → `finalize_streaming` error text + back to `:idle`.
2. **Agent stream**: `{:agent_registered, id, summary, node}` for the task → set `chat_agent_id` + `agent_message_count` → `async_fetch_history`; `{:agent_updated, id, changed_fields, node}` with `:message_count` in changed_fields → refetch; `{:agents_updated, node}` → lookup fallback when running-but-no-agent. History → `Messages.assistant_text/1` → `Transcript.put_streaming_text/2` (idempotently replaces the in-progress bubble). `{:chat_history_loaded, ...}` updates `agent_message_count` to `length(msgs)`.
3. **Terminal**: `{:task_updated, id, status, node}` for the task → `:completed`/`:cancelled` → `async_fetch_task` (its OWN seq counter); `:failed` → finalize + clear refs. `{:chat_task_loaded, ...}` → `finalize_terminal/2`. The agent may finish before any intermediate message was observed — the terminal fetch always renders the final result.
4. **Memory**: agents are transient (each reflect task = one run) — the LiveView transcript IS the conversation memory. `Transcript.build_preamble/2` prepends a bounded summary: skips `:error` entries, pairs user→assistant into exchanges (unpaired user entries included as `"User: …"`), keeps the last `max_exchanges` (default 8), truncates per-entry text to `max_entry_chars` (default 600, `"…"` suffix), caps the whole preamble at `max_chars` (default 4000). The reflect agent's own `get_task`/`list_tasks` tools are separate — OUR preamble carries the chat context.

## Notes for Agents — Enter-to-submit, Stop, New chat

- **Enter-to-submit (zero-JS)**: form `id="chat-form"` with `phx-submit="send_message"` + `phx-change="chat_input"`; the textarea has `phx-keydown`/`phx-keyup` with a `shift_down` latch ("Shift" keydown→true, keyup→false; "Enter" keydown → submit via the `send_chat` path when NOT shift-held, else no-op so the browser inserts the newline). `phoenix_live_view` 1.2.10 has NO server-side `Phoenix.LiveView.submit_form/2` (test macro only) and `phx-keydown` payloads carry only `%{"key" => ...}` (no shiftKey/modifier flags) — hence the latch. Documented micro-edge: a missed Shift keyup on window blur means the next Enter inserts a newline until a Shift cycle.
- **Stop**: visible only while `:running`; calls `EvoDash.NodeContext.cancel_task/2` (GRACEFUL: `:pending` → immediate `:cancelled`; `:running` → `:cancelling`, agents save + exit, result preserved) → `:ok` sets `chat_status: :cancelling` (the `:cancelled` task event completes the transition); `{:error, reason}` → error flash.
- **New chat**: disabled while `chat_status != :idle` (Stop is the in-flight control — the cleanest semantics: New chat never races a running task); `reset_chat/1` clears transcript + all chat refs + both seq counters.
- **Auto-scroll**: `id="chat-messages"` carries `phx-hook="AgentHistoryAutoScroll"` (the generic hook in `assets/js/app.js` — tracks isAtBottom on its element, smooth-scrolls on every `updated()`); NO asset changes needed (Tailwind 4 scans `../../lib/evo_dash_web`).
- **Bubble styling**: user right-aligned (`flex justify-end`, `bg-primary text-primary-content`), assistant/error left (`flex justify-start`); a streaming-empty assistant bubble renders three bouncing dots, streaming-with-text appends a pulsing dot. `rounded-lg` + subtle borders per the professional design language — no gradient hero boxes.
