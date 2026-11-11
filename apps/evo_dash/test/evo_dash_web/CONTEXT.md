# EvoDash Web Test Suites

## Intent

ExUnit suites mirroring `apps/evo_dash/lib/evo_dash_web/` — LiveView pages, function components, classic controllers and the on-mount hooks — plus the cross-cutting web helper suites at this level.
One suite answers one question about the web layer; the domain layer (`apps/evo_dash/test/evo_dash/`) and the core (`apps/evo_git/test/`) are tested elsewhere.
The app-wide Async-Safety Policy, the module census, the mount funnels, the global-state inventory and the deterministic-wait rules live in the parent `apps/evo_dash/test/CONTEXT.md`; this node only adds web-layer specifics.

## Routing Table

- `./live/` → LiveView page suites and the pure unit suites for their support modules (`home_live_test.exs`, `home_live_render_test.exs`, `tasks_live_test.exs`, `system_live_test.exs`, `settings_live*`, `review_live_test.exs`, `projects_live_test.exs`, `agents_live*`, `processes_live_test.exs`, `welcome_*`, `approval_dialog_render_test.exs`, `platform_info_test.exs`) — `live/CONTEXT.md` (cross-suite mechanics), with per-suite detail pushed down to `live/projects_live/CONTEXT.md`, `live/settings_live/CONTEXT.md`, `live/agents_live/CONTEXT.md` and `live/home_live/CONTEXT.md`
- `./live/home_live/` → Genesis Assistant support-module unit suites AND the mounted `GET /assistant` page-suite contracts (chat seeding, the approval strip + modal dialog, genesis-source gate, interactive session reattach, push-only delta streaming), including the interactive-session boundary (`session_actions_test.exs`, `session_list_test.exs`, `chat_state_test.exs`, `chat_state_session_fields_test.exs`, `transcript_test.exs`, `messages_test.exs`, `model_select_test.exs`, `approval_workflow_test.exs`, `assistant_message_test.exs`, `delta_test.exs`) — `live/home_live/CONTEXT.md`
- `./components/` → function-component render/contract suites (`task_card_components_test.exs` incl. the `:awaiting_input` session panel and the Cancel/Force-kill ranges, `layouts_test.exs` incl. the sidebar "Sessions" group, profile-editor/task-form/LLM-selection suites) — `components/CONTEXT.md`
- `./controllers/` → error templates, the streamed task-archive export, the legacy `GET /help` → `/assistant` 302 alias (raw query string preserved), and the `GET /server/status` operational probe (busy set excludes `:awaiting_input`) — `controllers/CONTEXT.md`
- `./live_hooks/` → on-mount hook suites (NodeAware sidebar load, Guide, Appearance, DesktopQuit, UpdateStatus) — `live_hooks/CONTEXT.md`
- `./helpers_test.exs` → status badge/dot/tint, datetime, icons, modals, `truncate_string/2`, `with_node_param/2`
- `./helpers_blob_preview_test.exs` → `blob_preview/2` and `list_preview/2` render caps
- `./theme_color_test.exs` → the ONLY file asserting colour VALUES (exact OKLCH strings per mode)
- `./model_label_test.exs` → the shared `EvoDashWeb.ModelLabel` task/agent model-line derivation
- `./content_text_test.exs` → content-text helpers

## API Surface — interactive-session coverage map

The `/assistant` page runs ONE long-lived interactive session per conversation (`/assistant?session=<agent_id>`); `:awaiting_input` is a non-terminal, idle status surfaced across the dashboard.
Coverage is deliberately split so no suite duplicates another:

| Contract | Where it is pinned |
|----------|--------------------|
| Send-path branches: no session → `start_session` + adopt + `push_patch`; existing session → `send_session_message` (`:queue`) with no new task; reflect fallback on `:llm_not_configured` / `{:interactive_root_only, _}`; `{:session, :finished \| :not_found}` → `:ended` | `live/home_live_test.exs` (`describe "interactive session send path"`) |
| Queue echo + interrupt policy, echo reconciliation on message-count growth / Stop / new chat | `live/home_live_test.exs` (`describe "interactive session queue echo and interrupt"`) |
| Attachments reach the send call (bare binary for text, `%{text:, attachments: [...]}` for media) plus the 4-file / 15 MiB caps | `live/home_live_test.exs` (`describe "interactive session attachments"`) |
| Reattach: one attach per `?session=`, no task started, status mapping, vanished session keeping a cached transcript read-only (ended, no streaming) or rendering `#chat-session-ended` for an empty cache, a NON-EMPTY fetched history replacing the cache | `live/home_live_test.exs` (`describe "interactive session reattach (?session=)"`) |
| Mounted conversation rail: row order, markers, `?session=` links preserving `?node=`, stale-seq/foreign-node rejection | `live/home_live_test.exs` (`describe "interactive session list (mounted)"`) |
| Pure URL/param/session-option/status helpers and every call-time `:home_session_*` seam normalization | `live/home_live/session_actions_test.exs` |
| Pure rail row building (ordering, live-over-cached, title cap), panel render and the nested `{{:session_list_loaded, seq, node}, result}` guard | `live/home_live/session_list_test.exs` |
| Persisted chat shape incl. `session_id`, `session_mode`, `queued_echoes` (bounds + per-key totality) | `live/home_live/chat_state_test.exs` + `chat_state_session_fields_test.exs` |
| Transcript caps (200 entries, 8 000 graphemes/entry, 40 reasoning items/message) and per-message reasoning retention | `live/home_live/transcript_test.exs` |
| Composer render contract (idle / running-queueable / `:awaiting_input` / `:cancelling` / `:ended`, queued echoes, interrupt affordance, rail panel) | `live/home_live_render_test.exs` |
| `:awaiting_input` badge/dot/tint families and cross-status distinctness | `helpers_test.exs` |
| Card reply box + Close session (only for an idle session), Cancel range `[:pending, :running, :awaiting_input]`, Force kill range `[:running, :awaiting_input, :cancelling]` | `components/task_card_components_test.exs` |
| Sidebar "Sessions" group (interactive rows, violet dot, never "Other") | `components/layouts_test.exs` |
| Tasks page: server-side `session_mode` filter (rows AND total, whitelist, clear), `:awaiting_input` status filter, reply/close flows | `live/tasks_live_test.exs` |
| `/server/status` busy set = `[:running, :pending, :finalizing, :cancelling]` atom-exactly | `controllers/server_status_controller_test.exs` |
| Update wind-down closes idle sessions via `close_session`, drops a stuck session after the grace polls, never force-kills one | `live/system_live_test.exs` (`SystemLiveSyncTest`) |

## Notes for Agents

- `live/home_live_test.exs` is one large `async: false` module: it owns the process-global `EvoDash.ChatHistory`, `EvoDash.ActiveTasks`, the isolated Store/TaskRegistry pair and the per-test `:home_session_*` / `:approval_*` / `:source_*` app-env seams.
  Its `install_session_seam/2` helper snapshots and restores every seam in `on_exit` — use it instead of writing `Application.put_env/3` ad hoc.
  A new mounted `/assistant` test belongs here (never in an async module); the page suite's seeded-state, approval and interactive-session contracts are documented in `live/home_live/CONTEXT.md`.
- The interactive-session send path is exercised through the call-time seams (`:home_session_start_runner`, `:home_session_send_runner`, `:home_session_close_runner`, `:home_session_attach_runner`, `:home_session_list_runner`), never by stubbing module internals; each is resolved inside the spawned function, so a test must restore it.
- The page's attach/list results use NESTED self-message tags (`{{:session_attached, seq, node, session_id}, result}`, `{{:session_list_loaded, seq, node}, result}`); the chat history/task reads use FLAT tags (`{:chat_history_loaded, node, seq, agent_id, result}`).
- `EvoDashWeb.HomeLive.Composer` reads every assign defensively, so the render fixture in `home_live_render_test.exs` must carry only presentation assigns — adding a page-level assign there is not needed.
- `tasks_live_test.exs`'s local `attribute/3` helper expects exactly ONE matching element (`[el] = Floki.find(...)`); for multi-element selectors assert on a plain attribute match or use `Floki.attribute/2` directly.
- `mix format --check-formatted` at `apps/evo_dash` must stay clean; no `mix gettext.extract` / `merge` / `translate` during feature work.

## Known Issues

- `apps/evo_dash/lib/evo_dash_web/live/home_live/CONTEXT.md:71` says the attach loader returns `{:ok, %{summary:, awaiting?:, history:}}`; the source returns the bare map (no `{:ok, _}` tag) — the unit tests pin the bare map.
