# HomeLive — Home Chat Page

## Intent

`EvoDashWeb.HomeLive` (`home_live.ex`) is the ChatGPT-style chat page rendered at `GET /help` — the conversation surface wired to the repo-less `:reflect` self-reflective agent. The user talks to Genesis itself: send a message → a `:reflect` task starts on the viewed node → the task's root agent (`EvoGit.Agents.SelfReflective`) runs repo-less (read-only Genesis source access + WebSearch + task-control + guide_user tools) → its assistant turns stream into chat bubbles → the terminal task result finalizes the transcript. Everything is push-based (PubSub) and node-aware (`?node=`), with all cross-node fetches off the LiveView process.

The support modules under `home_live/` keep `home_live.ex` (~1000 lines, at the ~1000 concern threshold) focused on LiveView wiring; all heavy lifting is pure and unit-testable. The render-only message surface (empty state + transcript list) lives in `EvoDashWeb.HomeLive.ChatMessages`, and the user bubble in `EvoDashWeb.HomeLive.UserMessage`.

## API Surface

### `EvoDashWeb.HomeLive` (`home_live.ex`)

LiveView with `use EvoDashWeb, :live_view` (SetLocale/NodeAware/DesktopQuit/UpdateStatus/Guide on-mount hooks automatic) + `use Gettext, backend: EvoDashWeb.Gettext`. Renders through `EvoDashWeb.Layouts.app` with `current_page={:help}` (the active-nav atom that highlights the sidebar Help nav item — HomeLive renders at `/help`).

**State assigns** (seeded by `base_assigns/0` in `mount/3`, then overlaid by `attach_chat/1` on connected mounts):

| Assign | Meaning |
|--------|---------|
| `transcript` | `[entry]` — chat transcript, oldest first; entry = `%{id, role: :user\|:assistant\|:error, text, streaming}` |
| `chat_draft` | textarea draft (kept in sync by the `chat_input` phx-change; NOT persisted — documented choice) |
| `chat_status` | `:idle \| :running \| :cancelling` — drives input/Stop/New-chat disabled states |
| `chat_task_id` | the active `:reflect` task id (`nil` when idle) |
| `chat_agent_id` | the root agent id (`nil` until `agent_registered`/lookup succeeds) |
| `agent_message_count` | last observed agent `:message_count` (HistoryGate) |
| `chat_task_status` | the mini-card status badge — `nil \| :pending \| :running \| :finalizing \| :cancelling \| :completed \| :failed \| :cancelled`; set by every task event + `finalize_terminal/2`; KEPT after finalize (the final badge stays visible on the card) |
| `thought_process` | `[Messages.to_entries/1 entry]` — the agent's context-history entries for the card's collapsible "Thought process" section; kept after finalize (agents leave ETS after task end) |
| `chat_id` / `chat_node` | the persisted `EvoDash.ChatHistory` chat id and the node the chat's task belongs to (`chat_node` set on first send; `nil` while fresh) |
| `chat_fetch_seq` | monotonic stale-guard counter for agent-lookup + history fetches |
| `chat_task_fetch_seq` | SEPARATE monotonic counter for the terminal `get_task` fetch (see Constraints) |
| `shift_down` | shift-latch for Enter-to-submit (see Notes for Agents) |
| `raw_entry_ids` | ephemeral UI state: `MapSet` of transcript entry ids currently shown in RAW (plain text) view instead of the markdown render (Issue-1 per-message toggle). NEVER persisted (persisted entries keep the total 4-key `Transcript.normalize` shape); seeded empty in `base_assigns/0`, cleared in `reset_chat/0` with the transcript. Streaming refetches replace entries by index — ids are stable, so a raw flag survives a mid-stream update |
| `current_path` | `~p"/help"` — required by NodeAware's node-switch `push_patch` |

**Events**: `send_message` (form `phx-submit`, `"message"` param; ALSO the suggestion chips' `phx-click="send_message"` + `phx-value-message` — BOTH routes hit the same `handle_event("send_message", %{"message" => text}, ...)` clause and share the `send_chat/2` path, so a quick-message send threads the pinned model EXACTLY like a typed submit via `ModelSelect.task_opts/2`; a fallback clause uses `chat_draft`), `chat_input` (draft sync), `chat_keydown`/`chat_keyup` (Enter/Shift latch), `select_chat_model` (header model selector; `"model_id"` OR `"value"` param shapes), `toggle_assistant_raw` (per-message raw/markdown toggle; `%{"id" => entry_id}` binary guard + fallback no-op clause), `copied` (ClipboardCopy hook acknowledgement → info flash `gettext("Copied to clipboard")`), `new_chat` (idle-only; `start_new_chat/1`), `stop` (graceful cancel).

**handle_info clauses**: `{:task_updated, id, status, node}` + `{:task_deleted, id, node}` (routed through `NodeAware.handle_task_info/2` — node filter + 300ms sidebar debounce — then chat-specific handling); `{:agent_registered, id, summary, node}` (own-task → set agent id + refetch history); `{:agent_updated, id, changed_fields, node}` (own agent AND the KEYWORD-LIST guard `is_list(changed_fields) and Keyword.has_key?(changed_fields, :message_count)` → refetch — see Constraints); `{:agent_removed, ...}` (no-op — the terminal task event finalizes); `{:agents_updated, node}` (missed-registration fallback lookup when running-but-no-agent); `:node_aware_reload_tasks` (sidebar reload via `NodeAware.reload_tasks/1` + `clear_task_reload_pending/1`); `{:chat_agent_lookup, ...}` / `{:chat_history_loaded, ...}` / `{:chat_task_loaded, ...}` (async results, stale-guarded); `{:node_selected, ...}` / `{:remote_connection_status, ...}` (delegated to NodeAware); catch-all.

### `EvoDashWeb.HomeLive.Transcript` (`transcript.ex`)

Pure chat-transcript model. Entries are plain maps `%{id: String.t(), role: :user|:assistant|:error, text: String.t(), streaming: boolean()}` (list, oldest first). ALL functions total.

- `new/0` → `[]`
- `normalize(term)` → `t` — coerces arbitrary (persisted) entry data into the current entry shape: non-lists → `[]`; non-map entries dropped; ids coerced to binaries (missing/malformed ids get a fresh unique id); roles whitelisted (`:user|:assistant|:error`, unknown → `:assistant`); text coerced to binary; `streaming` boolean-ized. Used to restore persisted state.
- `append(t, entry)` → `t`
- `entry(role, text, opts \\ [])` — opts `:streaming` (default `false`); id from `System.unique_integer([:positive])`
- `put_streaming_text(t, text)` — updates the LAST streaming entry's text, or appends a new streaming assistant entry when none is streaming (idempotent; used when a refetched agent history replaces the in-progress bubble)
- `finalize_assistant(t, text)` — sets the last streaming entry `streaming: false` + replaces its text, or appends a non-streaming assistant entry (terminal-result path)
- `append_error(t, text)`
- `build_preamble(t, opts \\ [])` → `{:ok, String.t()} | :empty` — bounded conversation memory (see Notes for Agents); normalizes its input first and tolerates entries missing `:text`/`:role`

### `EvoDashWeb.HomeLive.Messages` (`messages.ex`)

Converts native `%ReqLLM.Message{}` lists (as returned by `EvoDash.NodeContext.get_agent_history/2`) into bubble text and thought-process entries. EVERY function total — nil/absent content, plain-binary content, non-map content parts, nil metadata, missing keys all degrade safely (the history payload crosses an async/RPC boundary owned by `:evo_git`).

- `assistant_text(messages)` → `String.t()` — text of every `:assistant` message joined with `"\n"`; user/system/tool messages skipped (the reflect agent's user-role messages echo the sent objective — HomeLive renders the user bubble itself)
- `message_text(message)` → `String.t()` — nil → `""`; binary content → itself; content-part list → the `:text` of each map part (binary parts kept, non-map/`:thinking`-only parts skipped — thinking surfaces via `reasoning_details` in `to_entries/1` instead, keeping the bubble clean)
- `to_entries(messages)` → `[%{turn, type, data}]` — mirrors `EvoDashWeb.AgentsLive`'s conversion shape (`content`/`tool_calls`/`reasoning_details`/`tool_name`/`metadata` ride along in `data`); feeds the assistant card's "Thought process" section. The `%ReqLLM.Message{}` clause falls back to `%{}` on nil metadata.

### `EvoDashWeb.HomeLive.AgentStream` (`agent_stream.ex`)

Pure helpers for the agent stream + final result. Never raises.

- `find_root_agent(agents, task_id)` → `map | nil` — first summary with `:task_id == task_id`, preferring `agent_module == EvoGit.Agents.SelfReflective` when several match
- `message_count(agent)` → `non_neg_integer()` (0 when absent)
- `changed?(prev_count, agent)` → boolean — HistoryGate-style: `message_count(agent) != (prev_count || 0)`
- `task_id_from_start({:ok, map} | map)` → `{:ok, id} | {:error, :no_task_id}` — accepts the full `{:ok, map}` tuple OR a bare task map (a struct is a map, so call sites that destructure the tuple and pass the struct also work); accepts both `:id` and `"id"` keys; nil map → error
- `extract_final_text(task_result)` → `{:ok, String.t()} | :empty | :error` — decodes the tagged-tuple result (`{:ok, %{result: text, ...}}`, atom OR string keys); `:empty` = succeeded with no text; `:error` = `{:error, _}` / `{:exit, _}` / anything else

### `EvoDashWeb.HomeLive.ChatState` (`chat_state.ex`)

Owns the PERSISTED chat-state shape (one plain map, stored per-chat via `EvoDash.ChatHistory.put_state/2`):

```elixir
%{
  transcript: [entry],              # normalized on restore
  chat_draft: String.t(),
  chat_status: :idle | :running | :cancelling,
  chat_task_id: String.t() | nil,
  chat_agent_id: term() | nil,
  agent_message_count: non_neg_integer() | nil,
  chat_task_status: nil | :pending | :running | :finalizing | :cancelling | :completed | :failed | :cancelled,
  chat_node: node() | nil,
  selected_model_id: String.t() | nil,   # pinned model profile id (nil = Auto)
  thought_process: [to_entries entry]
}
```

`build/1` derives the map from LiveView assigns (persist direction); `restore/1` normalizes a stored map back into assign values (mount direction; the transcript goes through `Transcript.normalize/1`; statuses are whitelisted; malformed fields degrade per key). Both total. The seq counters (`chat_fetch_seq`/`chat_task_fetch_seq`) are runtime-only, never persisted.

`selected_model_id` is the chat's pinned model profile id, `nil` = Auto (the runtime's model-selection script or default decides). It is NOT validated against the configured profiles on restore — a stored id that no longer exists just threads an unknown id on the next send (the core falls back gracefully). Restore semantics: non-empty binary → itself; anything else → `nil`.

**Model choice SURVIVES a new chat and a node switch**: `reset_chat/0` does NOT clear `selected_model_id` (only `base_assigns/0` seeds `nil`, so a first-ever mount with no restored chat starts on Auto). `ChatState.build/1`/`restore/1` round-trip it per chat, so after a `new_chat` the freshly-created empty chat is persisted with the CURRENT pinned id, and subsequent sends (typed OR suggestion-chip) still thread it via `ModelSelect.task_opts/2`. On a node switch, `handle_params/3` re-runs `assign_model_select/1` for the resolved node; a pinned id absent from the new node's profiles threads harmlessly (the core falls back gracefully). `raw_entry_ids` is deliberately NOT part of the persisted shape (never in `build/1`).

### `EvoDashWeb.HomeLive.ModelSelect` (`model_select.ex`)

Model-profile loading for the chat header's model selector. `load(node)` → `{model_profiles, model_selection_enabled}` — node-aware, mirroring the ProjectsLive task-form loading (`EvoDashWeb.ProjectsLive.Project.load_model_profiles/1` + `AsyncLoad.load_custom_agents/1`): local node → `Config.resolve()` + `EvoGit.CustomAgents.ModelSelector.enabled?/0`; remote node → `EvoDash.NodeContext.get_resolved_config/1` + `list_custom_agents/1` (configured-but-broken scripts still count as enabled, matching `ModelSelector.enabled?/0`). RPC failure → `{[], false}` — never crashes. The Auto option label convention lives in the LiveView template: "Auto (by rules)" when `model_selection_enabled`, else plain "Auto".

### `EvoDashWeb.HomeLive.AssistantMessage` (`assistant_message.ex`)

Function component (`use EvoDashWeb, :html` + Gettext) rendering the assistant entry as a mini combined "task card" chat message — COSMETIC ONLY (no backend machinery; the existing push flow + `EvoDash.TaskSupervisor` async fetches + the two stale-guard seqs are unchanged, no polling):

- sparkles avatar (existing look) + card frame (`relative group/assistant overflow-hidden rounded-lg border bg-base-100 shadow-sm`, status-tinted border via `card_border/1`)
- top strip (only when `task_status != nil`): "Task" kicker + badge reusing `EvoDashWeb.Helpers.task_status_badge/1` EXACTLY like `TaskCardComponents` does (running = warning ping dot, cancelling = violet ping dot, finalizing = spinner, same badge classes; statuses running/completed/failed/cancelled/cancelling + pending via the helper's catch-all)
- text body by entry state: pulsing three-dot pill while empty+streaming (unchanged); while streaming WITH text, the raw partial text + blinking `.help-caret` (NEVER markdown-rendered mid-stream — a half-rendered stream would flicker); for FINALIZED (non-streaming) text, a **Markdown render** via `{raw(EvoDash.MarkdownRender.render(entry_text(@entry)))}` inside `<div class="md-content text-[15px] leading-relaxed text-base-content">` — the exact helper + call pattern the tasks/review pages use (`EvoDash.MarkdownRender.render/1`, MDEx `unsafe_: true` with an HTML-escaped fallback — always-safe HTML for untrusted/LLM text; `.md-content` styles are project-wide in `assets/css/app.css`). When the per-message `raw` attr is true the finalized body renders the plain HTML-escaped source text instead (the raw toggle's view)
- **hover-revealed bottom-right action group** (finalized entries only — nothing meaningful to toggle/copy mid-stream): `absolute bottom-1.5 right-1.5 ... opacity-0 group-hover/assistant:opacity-100` inside the card's NAMED `group/assistant` (named group so the thought-process `<details class="group">`'s `group-open:rotate-180` chevron stays scoped to the details). Buttons: (a) raw/markdown toggle `phx-click="toggle_assistant_raw" phx-value-id={entry_id(@entry)}` (icon swaps `hero-code-bracket` ↔ `hero-document-text`; gettext title/aria "Show raw text" / "Show rendered markdown" + zh_CN comments); (b) copy-whole-text button `id={"assistant-copy-" <> entry_id(@entry)} phx-hook="ClipboardCopy" data-content={entry_text(@entry)}` (the global clipboard hook reads `data-content`, pushes `"copied"` → HomeLive info flash; Phoenix HTML-escapes attribute values, so multi-line raw text is safe — same pattern as the review/task-card copy buttons)
- collapsible zero-JS `<details>/<summary>` "Thought process" section (gettext + zh_CN comment) listing `thought_process` entries: type/turn header, reasoning text, content (or tool result for `"tool"` entries), and tool calls rendered via `EvoDashWeb.AgentsLive.ToolCallDisplay.display/1`
- `task_status`/`thought_process` are passed ONLY for the transcript's LAST assistant entry (the one tied to the current/last chat task); earlier assistant entries render the frame without badge/details
- Total: every payload access is `Map.get`-guarded; `entry_text/1` falls back to `""` and `entry_id/1` to `""` for malformed entries (the copy-button DOM id and `phx-value-id` never raise)

The task-card helpers from `TaskCardComponents` (`objective_text/1`, `render_result/2`, …) are NOT used here — the streamed text already IS the result text.

### `EvoDashWeb.HomeLive.ChatMessages` (`chat_messages.ex`)

Function-component module (`use EvoDashWeb, :html` + Gettext, imports `AssistantMessage`, aliases `UserMessage`) hosting the message-surface render sections extracted from `home_live.ex`:

- `empty_state/1` — the no-transcript empty state (brand logo light/dark variants, kicker + greeting, and the FOUR suggestion chips). Each chip is a button `phx-click="send_message"` + `phx-value-message={gettext(...)}` OUTSIDE `#chat-form` — a quick-message send dispatches to the SAME `handle_event("send_message", %{"message" => text}, ...)` clause as a typed submit and threads the pinned model identically through `send_chat/2` → `ModelSelect.task_opts/2`
- `message_list/1` — the transcript (attrs `transcript`, `chat_task_status`, `thought_process`, `raw_entry_ids`): per-entry wrapper `id={"chat-entry-" <> entry_id(entry)}`; `:user` entries via `<UserMessage.user_message entry={entry}/>`; `:assistant` via `<.assistant_message entry={entry} raw={MapSet.member?(@raw_entry_ids, Map.get(entry, :id))} .../>` (raw passed ONLY for the last assistant entry's id — the component's `attr(:raw, :boolean, default: false)` keeps earlier entries rendered); `:error` rows with the exclamation icon + soft red tint. Helpers `bubble_wrapper_class/1`, `last_assistant_index/1`, `entry_id/1` (total) moved verbatim from the LiveView

### `EvoDashWeb.HomeLive.UserMessage` (`user_message.ex`)

Function component (`use EvoDashWeb, :html`) rendering the user chat bubble — the SINGLE implementation for BOTH typed sends and suggestion-chip sends (both produce the same normalized `:user` entry): right-aligned content-fit bubble `w-fit max-w-[85%] sm:max-w-[80%] rounded-3xl rounded-br-md bg-base-300 px-4 py-2.5 text-left text-[15px] leading-relaxed whitespace-pre-wrap break-words text-base-content shadow-sm`. Soft neutral DaisyUI token `bg-base-300` + `text-base-content` read correctly in both light/dark themes (no hardcoded hex); `w-fit` + the `flex justify-end` wrapper (from `ChatMessages.bubble_wrapper_class/1`) kill the old empty leading space; the message text is left-aligned INSIDE the bubble; the flattened `rounded-br-md` corner is kept as the intentional detail. Total (`Map.get`-guarded).

## Constraints

- **Scope**: `home_live.ex` + these support modules are self-contained (no other `lib/` files were touched by this feature); all node data goes through `EvoDash.NodeContext`. Router wiring: `live("/help", HomeLive, :index)`; the root `/` maps to the Projects page (`ProjectsLive`, also mounted at `/projects`).
- **All node data goes through `EvoDash.NodeContext`** (start/cancel/history/get_task/list_agents) with a `socket.assigns[:current_node] || node()` fallback.
- **Async-only cross-node fetches**: agent lookup, history fetch, and terminal `get_task` run in `Task.Supervisor.start_child(EvoDash.TaskSupervisor, ...)` with `send(pid, ...)` results. Justified `try/rescue` at the async boundary ONLY (the closure runs OUTSIDE the LiveView process; a crash must never silently lose the result message — rescue returns `[]`/`nil` so the caller degrades instead of wedging). No `try/rescue` in the LiveView process itself.
- **Two stale-guard counters — keep them separate**: `chat_fetch_seq` guards agent-lookup + history results; `chat_task_fetch_seq` (SEPARATE) guards the terminal `get_task` result. A late `agent_updated` broadcast (cross-topic PubSub reordering, graceful-cancel grace window) bumps the shared counter, which would stale-guard-drop the terminal result and wedge the chat in `:running` forever.
- **`agent_updated` kwlist guard (CURRENT behavior)**: `changed_fields` is a KEYWORD LIST in real core broadcasts (`[message_count: n, ...]` from `EvoGit.AgentScheduler.Store.put_agent_state`), so the refetch gate is `is_list(changed_fields) and Keyword.has_key?(changed_fields, :message_count)` — the exact pattern `AgentsLive` uses (agents_live.ex). HistoryGate choice kept: the core guarantees `:message_count` in changed_fields whenever the agent's context changed, so refetch only when the conversation actually moved.
- **Terminal handling**: `:completed`/`:cancelled` → `async_fetch_task` → `finalize_terminal/2` (nil task → "The conversation was deleted." + clear refs; `:completed` → `extract_final_text` → text / "No response." / "The task failed."; `:cancelled` → preserved result text or "Stopped." — graceful cancel preserves the result when the agent completed; `:failed` → "The task failed."). `{:task_deleted, ...}` → "The conversation was deleted." + `clear_task_refs`. `clear_task_refs` nils task/agent refs + `chat_status: :idle`, KEEPS the transcript AND the final `chat_task_status` badge AND `thought_process` (New chat re-enabled; prevents duplicate finalization from repeated broadcasts).
- **Non-terminal task events NEVER finalize**: `finalize_terminal/2` only finalizes+clears for `@terminal_statuses = [:completed, :cancelled, :failed]`; `:cancelling`/`:running`/`:pending`/`:finalizing` (and a missing/unknown `:status`) only refresh the badge/status assigns and KEEP the refs — the task is still alive (a mount-reconciliation fetch of a live task must not wed the chat). `handle_task_event/3` mirrors this: `:cancelling` sets `chat_status: :cancelling` + badge; `:pending`/`:finalizing` badge-only; `nil` = review-only mutation → no-op; every applied event updates `chat_task_status`.
- **Node switch** (`handle_params/3`): capture `prev_node` BEFORE `NodeAware.assign_node/2`; a change → `start_new_chat/1` (a NEW persisted chat — the old chat STAYS in memory; its task belongs to the old node and events are node-filtered anyway). A restored chat whose `chat_node` mismatches the viewed node also starts a new chat. `prev_node == nil` on the FIRST handle_params (mount → params) never counts as a switch — wiping the just-restored chat there would defeat the persistence. `current_path` re-assigned `~p"/help"` on every params run.
- **Onboarding**: dead-render only, `Code.ensure_loaded?(EvoGit.Config.VersionState)`-guarded `onboarding_needed?/0` → `push_navigate(socket, to: "/welcome")` (mirrors ProjectsLive; avoids redirect loops).
- **i18n**: all user-facing strings gettext-wrapped; ambiguous labels carry zh_CN meaning comments (e.g. "Chat with Genesis" → "与 Genesis 对话", "New chat" → "新对话", "Stop" → "停止", "Send" → "发送", "Thought process" → "思考过程"). NO gettext extract/merge/translate during development.

## ChatHistory persistence (in-memory, LOCAL-NODE ONLY)

- **Local-only decision**: chat state lives in `EvoDash.ChatHistory` (a local GenServer + ETS in the dashboard BEAM). Remote-node chats are NOT rehydrated across a LiveView remount — the store is process-local and never shipped over `:erpc`; a remount while viewing a remote node starts a fresh chat. (The user's chats are local conversations; remote reflect tasks are transient.)
- **State shape**: ONE plain map per chat, owned by `ChatState` (see above). The store is shape-agnostic; `HomeLive` owns the shape.
- **Restore** (`attach_chat/1`, connected mount only — the dead render deliberately skips the store so the initial HTTP request never creates a chat per page load): `current_chat_id()` → `get_state/1` → `ChatState.restore/1` (transcript normalized). No current chat → `new_chat()` + fresh-empty behavior.
- **ONE-SHOT reconciliation** (`reconcile_chat/1`, NOT polling): when the restored `chat_status` is `:running`/`:cancelling` with a `chat_task_id`, spawn ONE `async_fetch_task` (terminal events were missed while away → finalizes, or a live status just refreshes the badge) plus ONE history refetch (agent id known) or ONE agent lookup (agent never observed). All fetches target the chat's OWN `chat_node`, not the viewed node.
- **Persist points** (`persist_state/1`, skipped on dead renders): send (`send_chat/2`), `stop` (on `:ok`), `:agent_registered`, `:chat_agent_lookup` (agent found), `:chat_history_loaded`, `:chat_task_loaded` (via `finalize_terminal/2`), every applied task/agent status event, `handle_task_deleted`, both send-error paths, `new_chat`, and node switches (`start_new_chat/1`). The `chat_input` draft is deliberately NOT persisted per keystroke (documented choice — keystroke-level GenServer calls are noise; the draft survives in the same LiveView anyway).
- **New chat / node switch**: `start_new_chat/1` calls `ChatHistory.new_chat()` (fresh id; OLD chats KEPT — there is no chat-switching UI yet) + `ChatHistory.prune(10)` (cap: keep the newest 10 chats — bounded memory; pruning is never automatic) + resets all live chat assigns EXCEPT `selected_model_id` (the pinned model survives — `reset_chat/0` no longer nils it; `persist_state` writes the fresh empty state carrying the current pinned id) + persists the fresh empty state. `raw_entry_ids` is never persisted (ephemeral per-entry raw-view flags, cleared with the transcript on reset).
- **Test-agent note**: the store is PROCESS-SHARED — `home_live_test.exs` (and any test touching HomeLive persistence) must call `EvoDash.ChatHistory.reset()` in setup so state never leaks between tests.

## Known Issues

- **Live post-send crash (NOT reproducible in the test env)**: every handler in the post-send flow is total against real payloads (integer ids, nil status, nil timestamps, real `%ReqLLM.Message{}` structs — exercised by the repro files). If the crash recurs live, capture the LiveView's stacktrace directly — `Process.info(<HomeLive pid>, :current_stacktrace)` (or `:sys.get_state` on the pid, or run `mix phx.server` with the page open) — the test env cannot reproduce it.

## Notes for Agents — Chat data-flow

1. **Send** (`send_chat/2`): build the objective (`Transcript.build_preamble(transcript)` → `"Previous conversation:\nUser: …\nAssistant: …\n\nNew message: <text>"`, or bare text on `:empty`) → append optimistic user bubble + empty streaming assistant bubble (pulsing dots) → `chat_status: :running` + `chat_node: current_node` → `EvoDash.NodeContext.start_task(node, :reflect, mode: "reflect", objective: objective)` — NO `:path` key → `AgentStream.task_id_from_start/1` → set `chat_task_id` + `chat_task_status: :pending` → persist → `async_lookup_agent`. `{:error, reason}` / no-id → `finalize_streaming` error text + back to `:idle` + persist.
2. **Agent stream**: `{:agent_registered, id, summary, node}` for the task → set `chat_agent_id` + `agent_message_count` → persist → `async_fetch_history`; `{:agent_updated, id, changed_fields, node}` with the kwlist `:message_count` guard → refetch; `{:agents_updated, node}` → lookup fallback when running-but-no-agent. History → `Messages.assistant_text/1` → `Transcript.put_streaming_text/2` (idempotently replaces the in-progress bubble). `{:chat_history_loaded, ...}` updates `agent_message_count` to `length(msgs)` and `thought_process` to `Messages.to_entries(msgs)`.
3. **Terminal**: `{:task_updated, id, status, node}` for the task → `:completed`/`:cancelled` → `async_fetch_task` (its OWN seq counter); `:failed` → finalize + clear refs. `{:chat_task_loaded, ...}` → `finalize_terminal/2`. The agent may finish before any intermediate message was observed — the terminal fetch always renders the final result.
4. **Memory**: agents are transient (each reflect task = one run) — the LiveView transcript IS the conversation memory. `Transcript.build_preamble/2` prepends a bounded summary: skips `:error` entries, pairs user→assistant into exchanges (unpaired user entries included as `"User: …"`), keeps the last `max_exchanges` (default 8), truncates per-entry text to `max_entry_chars` (default 600, `"…"` suffix), caps the whole preamble at `max_chars` (default 4000). The reflect agent's own `get_task`/`list_tasks` tools are separate — OUR preamble carries the chat context.

## Notes for Agents — Enter-to-submit, Stop, New chat

- **Enter-to-submit (zero-JS)**: form `id="chat-form"` with `phx-submit="send_message"` + `phx-change="chat_input"`; the textarea has `phx-keydown`/`phx-keyup` with a `shift_down` latch ("Shift" keydown→true, keyup→false; "Enter" keydown → submit via the `send_chat` path when NOT shift-held, else no-op so the browser inserts the newline). `phoenix_live_view` 1.2.10 has NO server-side `Phoenix.LiveView.submit_form/2` (test macro only) and `phx-keydown` payloads carry only `%{"key" => ...}` (no shiftKey/modifier flags) — hence the latch. Documented micro-edge: a missed Shift keyup on window blur means the next Enter inserts a newline until a Shift cycle.
- **Stop**: visible only while `:running`; calls `EvoDash.NodeContext.cancel_task/2` (GRACEFUL: `:pending` → immediate `:cancelled`; `:running` → `:cancelling`, agents save + exit, result preserved) → `:ok` sets `chat_status: :cancelling` + `chat_task_status: :cancelling` + persist (the `:cancelled` task event completes the transition); `{:error, reason}` → error flash.
- **New chat**: disabled while `chat_status != :idle` (Stop is the in-flight control — the cleanest semantics: New chat never races a running task); `start_new_chat/1` creates a NEW persisted chat + `prune(10)` + resets transcript/all chat refs/badge/thought process + both seq counters + `raw_entry_ids`. The pinned `selected_model_id` is NOT reset (Issue 2(b): the user's model choice survives new chat — see the Model selector notes).
- **Auto-scroll**: `id="chat-messages"` carries `phx-hook="AgentHistoryAutoScroll"` (the generic hook in `assets/js/app.js` — tracks isAtBottom on its element, smooth-scrolls on every `updated()`); NO asset changes needed (Tailwind 4 scans `../../lib/evo_dash_web`).
- **Styling (hand-crafted Tailwind + DaisyUI theme tokens — no hardcoded hex)**: the empty state (`@transcript == []`, rendered by `ChatMessages.empty_state/1`) shows the brand logo mark (light/dark variants via `dark:hidden` / `hidden dark:block`), a "Start a conversation" kicker + "How can I help you today?" greeting, and 4 suggestion chips wired to the existing `send_message` event via `phx-value-message`; user entries (`UserMessage.user_message/1`) are compact right-aligned content-fit bubbles — `w-fit max-w-[85%] sm:max-w-[80%] rounded-3xl rounded-br-md bg-base-300 px-4 py-2.5 text-left ... text-base-content` (soft neutral DaisyUI token, readable in both themes; the `flex justify-end` wrapper handles alignment; text left-aligned inside) — NOT the old saturated `bg-primary text-primary-content` full-width look; assistant entries are the `AssistantMessage` mini task-card (avatar + bordered card + optional badge/details + hover raw/copy action group — see API Surface); error entries use a soft red tint (`border-error/25 bg-error/10 text-error`) with an exclamation icon. The composer is a rounded-3xl `.help-composer` container (styles in the "Help Chat Page (GET /help)" section at the end of `assets/css/app.css`, theme-token color-mix only) with the circular Send button morphing into the Stop button while running — both buttons stay in the DOM (the inactive one `hidden` + disabled) so `button[phx-click="stop"]` remains assertable on idle; the header has the model selector + ghost "New chat" button.

## Notes for Agents — Model selector (fully wired)

The per-chat LLM model selector feature is **fully implemented**: the support modules in THIS directory (`ChatState.selected_model_id` field + public `ChatState.normalize_model_id/1` + `ModelSelect.load/1` + `ModelSelect.task_opts/2` above) plus the `home_live.ex` LiveView wiring (alias, `assign_model_select/1` in `mount/3` + `handle_params/3`, `base_assigns/0`/`reset_chat/0` seeding, header form-less select, dual-shape `select_chat_model` handler, `send_chat/2` threading via `ModelSelect.task_opts/2`). The tests live under `apps/evo_dash/test/...` (a separate subtree — handled by the test agent). Wiring recipe record:

- `home_live.ex`:
  - Alias: add `ModelSelect` to the existing `alias EvoDashWeb.HomeLive.{...}` line.
  - `mount/3` (after `attach_chat/1`): `|> assign_model_select()` where `assign_model_select/1` does `{profiles, enabled} = ModelSelect.load(socket.assigns[:current_node] || node())` and assigns `model_profiles` + `model_selection_enabled`. Re-run it in `handle_params/3` after the node-switch block (re-loads for the resolved `?node=` target).
  - `base_assigns/0`: seed `selected_model_id: nil, model_profiles: [], model_selection_enabled: false`. `reset_chat/0` does NOT touch `selected_model_id` — the user's pinned choice SURVIVES a new chat AND a node switch (`start_new_chat/1` persists the fresh empty chat with the current pinned id via ChatState); only a first-ever mount with no restored chat stays Auto (nil from `base_assigns/0`). `reset_chat/0` DOES reset `raw_entry_ids: MapSet.new()` (its entries are gone with the transcript).
  - Header UI: a form-less `<select name="model_id" phx-change="select_chat_model" aria-label={gettext("Chat model")}>` in the header (OUTSIDE `#chat-form`), hidden when `@model_profiles == []`; options = Auto (`value=""`, `selected={@selected_model_id in [nil, ""]}`, label `gettext("Auto (by rules)")` when `@model_selection_enabled` else `gettext("Auto")` — both with zh_CN comments) + one option per `profile.id`.
  - Event: two clauses `handle_event("select_chat_model", %{"model_id" => id}, socket)` AND `%{"value" => id}` (form-less phx-change may send either) → `assign(selected_model_id: ChatState.normalize_model_id(id)) |> persist_state()`.
  - `send_chat/2`: replace the `start_task(node, :reflect, mode: "reflect", objective: objective)` call with `EvoDash.NodeContext.start_task(node, :reflect, ModelSelect.task_opts(socket.assigns[:selected_model_id], mode: "reflect", objective: objective))` — threads `:model_id` + `:model_id_locked` only when pinned, nothing on Auto.
- Tests:
  - `test/.../home_live/chat_state_test.exs`: the two exact-map `build/1` assertions FAIL until the expected maps gain `selected_model_id` (add `selected_model_id: "profile-a"` to the populated-assigns case; `selected_model_id: nil` to the empty case). Also add restore cases for `ChatState.normalize_model_id/1` (`"p1"` → `"p1"`, `""`/`nil`/`42` → `nil`).
  - `test/.../home_live_test.exs`: selector-render (write a `[[llm.models]]` config to `EvoGit.Config.config_path()` before mounting — `projects_live_test.exs` `write_model_profile_config/0` pattern; assert `present?/2` on `select[name="model_id"][phx-change="select_chat_model"]`, "Auto" label, profile option; assert hidden when no profiles), threading (`opt(task, :model_id) == "profile-a"` + `opt(task, :model_id_locked) == true` when pinned; `refute has_opt?(task, ...)` on Auto — helpers already exist at `home_live_test.exs:101-102`), and remount persistence (`GenServer.stop(view.pid)` → `live(conn, "/help")` → `assigns(view2).selected_model_id` restored; suite already resets `EvoDash.ChatHistory` in setup).
