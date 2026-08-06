# LiveView Pages

## Intent
Phoenix LiveView modules and templates for the EvoDash interactive UI — real-time task management, agent inspection, runtime configuration, and user help.

## Routing Table
- `components/` → LiveComponents (`use EvoDashWeb, :live_component`) — `NodeSelectorComponent` for the SSH Remote Development node selector
- `dashboard_live/` → Support modules extracted from `DashboardLive`: `StatePersistence`, `Project`, `Assigns`. Note: `dashboard_live.ex` is ~1390 lines and growing — a future split of more event handlers into this support directory may be warranted (the recent prompt-sync change was only ~7 lines).
- `settings_live/` → Support modules extracted from `SettingsLive`: `ModelProfileHelpers` (pure data-transformation for `[[llm.models]]` CRUD), `ConfigIO` (config loading, runtime updates, atom whitelists)
- `system_live/` → Support modules extracted from `SystemLive`: `Content` (static guides/references), `Status` (health-check status helpers)

## API Surface

| Module | Route | Summary |
|--------|-------|---------|
| `DashboardLive` | `GET /` | Project-based task dashboard with genesis/evolve forms, auto-mode detection, real-time task cards, and project tabs. Delegates to `TaskRegistry` and `DashboardComponents`. |
| `WelcomeLive` | `GET /welcome` | Onboarding tutorial with 4 steps — LLM configuration, project setup, and getting started. Redirects to dashboard if already completed. |
| `ReviewLive` | `GET /review/:task_id` | Code review page — diff viewer with syntax highlighting, commit list, agent summary, and action buttons (Merge, Reject, Continue, Create GitHub PR, Extract Skills). The Extract Skills action opens a modal for an optional user note, then starts an `:extract_skills` task via `TaskRegistry` that spawns a `SkillExtractor` agent to distill PR knowledge into `.agents/skills/` files. |
| `AgentsLive` | `GET /agents` | Recursive agent tree inspector with selectable agent detail panel. Reads from ETS tables, auto-refreshes every 500ms. Uses `AgentsComponents.agent_tree/1`. |
| `TasksLive` | `GET /tasks` | Task history list across all projects. |
| `SettingsLive` | `GET /settings` | Runtime scheduler configuration (concurrency, retries, depth, LLM model). Shows config status warnings. Updates via `AgentScheduler.update_config/1`. Auto-refreshes every 2s. |
| `SystemLive` | `GET /system` | System page: scheduler controls (pause/resume), system controls (restart/stop the Erlang VM), system self-check, plus usage guides and references (example config, CLI usage, FAQ, credentials). |

### LiveComponents (`./components/`)
- **`NodeSelectorComponent`** (`components/node_selector_component.ex`) — `EvoDashWeb.NodeSelectorComponent`, a `use EvoDashWeb, :live_component` LiveComponent rendered in the navbar (next to the brand logo, via `Layouts.app/1`). Shows the current node with a status dot + a dropdown (Local / saved targets / "Manage Connections...") and a full **connection manager modal** (add/edit/delete targets, bootstrap/connect/disconnect, status badges). Manages its own state; selects nodes by sending `{:node_selected, id}` to the parent LiveView. Subscribes to the `"remote_connections"` PubSub topic via the parent LiveView's subscription.

### Templates
- **`agents_live.html.heex`** — Companion template for `AgentsLive` with sidebar tree + detail panel layout.

### Node-Aware Integration (SSH Remote Development, Phase 2)
All LiveViews register the `EvoDashWeb.LiveHooks.NodeAware` on-mount hook (via the `live_view/0` macro in `evo_dash_web.ex`). As part of the node-aware pattern, each LiveView:
- Calls `assign_node/2` in `handle_params/3` (reads the `?node=<id>` query param, resolving it to a saved+connected target or falling back to local).
- Passes `current_node_id` / `current_node_name` (and `remote_targets` / `connection_statuses`) to the `Layouts.app/1` call.
- Handles `{:node_selected, _}` (delegated to `NodeAware.handle_node_selected/2`) and `{:remote_connection_status, _, _}` messages (delegated to `NodeAware.handle_connection_status/2`).

### Shared Conventions
- All LiveViews use `use EvoDashWeb, :live_view` and import `CoreComponents` and `Layouts`.
- All pages use `EvoDashWeb.Layouts.app/1` layout with `current_page` for nav highlighting.
- Styled with DaisyUI/Tailwind CSS; business logic delegated to context modules.

### UI Patterns (modals, forms, events)
These patterns are used consistently across the LiveViews. Follow them when adding new interactive features.

- **Modal pattern (rendered in the LiveView's own template/component):** A modal is conditionally rendered with `<%= if @some_assign do %>` wrapping a `<div class="modal modal-open bg-black/50" id="...">` containing a `<div class="modal-box ...">`. The open/close state is driven by a `nil`/value socket assign. Opening: a `phx-click="open_modal"` handler sets the assign (optionally carrying an `phx-value-id`). Closing: a `phx-click="close_modal"` handler resets the assign to `nil`. The backdrop `<div class="modal-backdrop" phx-click="close_modal">` also closes. See `AgentsLive`'s `view_full_message`/`close_message_modal` and `view_full_objective`/`close_objective_modal` (in `agents_live.html.heex` + `agents_live.ex`), and `EvoDashWeb.Helpers`'s reusable modal component.
- **Inline form submission (inline editor pattern):** Instead of a full modal, list editors use a `<form phx-submit="save_..." >` with hidden `<input type="hidden" name="id" value=...>` + visible inputs, submitted by a `<button type="submit">`. The edit state is toggled by an `@editing_...` assign. See `SettingsComponents.ModelProfilesEditor.model_profile_edit_form/1` (`phx-submit="save_model_profile"`).
- **Event naming:** Events use `phx-click` (buttons) and `phx-submit` (forms). Values passed via `phx-value-<key>="<value>"` (received in the handler's params map as string keys). IDs that are integers arrive as strings — `String.to_integer/1` is used to convert (e.g. `select_agent` → `%{"id" => id}`).
- **`ModalHelpers` (`live/modal_helpers.ex`):** A `__using__` macro injecting shared modal event handlers (`view_full_result/2`, `close_result_modal/1`, etc.) into a host LiveView. `DashboardLive`/`TasksLive` `use EvoDashWeb.ModalHelpers`.
- **LiveComponent event routing:** Inside a `use EvoDashWeb, :live_component`, events use `JS.push("event", target: @myself, value: %{...})` (targets the component itself) or plain `phx-click` (targets the parent LiveView). See `NodeSelectorComponent` (`select_node` targets `@myself`, then `send(self(), {:node_selected, id})` to the parent).
- **Server-driven task-form layout:** The task form's layout (compact vs expanded) is computed server-side from prompt length via `TaskFormComponents.layout_for/1` (threshold 300 chars / 8 lines). `DashboardLive` keeps `@task_prompt` in sync with the never-cleared textarea (`phx-update="ignore"`) through the `task_prompt_change` event (`%{"prompt" => prompt}`, debounced 200ms). After `task_submit`, the submitted prompt is re-assigned post-`assign_form_defaults` so the layout matches the visible textarea content (and the draft survives reloads via localStorage — intentional).

### Design Notes — Dashboard Top Bar & Command Palette Keyboard

- **Palette keyboard binding must live on the focused element:** LiveView `phx-keydown` bindings do NOT bubble to ancestor elements — the handler only fires when the focused element itself carries the binding. The command palette's `phx-keydown="palette_keydown"` must therefore be on the search input (project_components.ex), NOT on the overlay div. Since `handle_palette_key/3` (`dashboard_live.ex`) only acts on special keys — `"Escape"` (closes, any mode), `"ArrowDown"`/`"ArrowUp"` (menu index nav), `"Enter"` (menu selection) — and has a catch-all clause returning the socket unchanged for everything else, printable characters typed into the search input are no-ops server-side: typing + `palette_search` filtering (a separate `phx-change` event) coexist without interference. Event path: input `phx-keydown` → `handle_event("palette_keydown", %{"key" => key}, socket)` → `handle_palette_key/3` (clauses at `dashboard_live.ex:1381-1447`, catch-all `:1447`). Palette close event name: `close_project_palette` (`handle_event` at `dashboard_live.ex:649`; the backdrop uses `phx-click="close_project_palette"` and click-away uses the same name).
- **Enlarged top bar spacing (`DashboardLive.top_bar/1`):** container `dashboard-topbar` uses `gap-3 px-4 py-3` (was `gap-2 px-3 py-2`); the Configure button is `btn btn-md btn-ghost gap-2` (was `btn-sm`); dropdown section headers ("Task Options" / "Project Settings") use `text-xs` (was `text-[11px]`). The omnibox trigger (left side) lives in project_components.ex and is unchanged. All strings remain gettext-wrapped — no .pot/.po edits.

## Notes for Agents — Session-memory message timestamps

The agents-page chat history (`AgentsLive` → `messages_to_history_entries/1` → `message_to_history_entry/1`) consumes `%ReqLLM.Message{}` structs from `EvoGit.AgentScheduler.RemoteAPI.get_agent_history/1`, which returns the raw `AgentState.context.messages` list.

- **Timestamps are stamped at the source** by the `:evo_git` runtime into each message's `metadata[:timestamp]` (a free-form map). Representation: **Unix-seconds integer** or a **`DateTime`** (the dashboard formatter also accepts ISO8601 binaries defensively). Historical messages may lack the key.
- **Dashboard rendering**: `message_to_history_entry/1` carries the raw value as `timestamp:` in the entry map; the agents detail panel renders a short **LOCAL** 24h time (`"HH:MM:SS"`, seconds precision) next to "Turn x" via `EvoDashWeb.Helpers.format_history_timestamp/1`. Local conversion uses the offset between `:calendar.local_time/0` and `:calendar.universal_time/0` (stdlib-only; no tz DB — the default `Calendar.UTCOnlyTimeZoneDatabase` only supports "Etc/UTC"). **Graceful fallback**: when `timestamp` is absent, no time is rendered — just "Turn x", no placeholders.

## Constraints
- Each LiveView uses either an inline `render/1` or a companion `.html.heex` template — not both. (Three render inline; `AgentsLive` uses a separate template.)
- Auto-refresh intervals must be gated behind `connected?/1` to avoid leaking timers.
- Naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
- **No `try/rescue` around config/core-value loading.** LiveViews must NOT wrap `EvoGit.Config.*`, `EvoGit.AgentScheduler.*`, or `EvoGit.SystemCheck.*` calls in `try/rescue`. If these crash, the LiveView SHOULD crash truthfully — displaying a wrong default value (e.g. `false`, `%{}`, `100_000`) is worse than a visible crash, and the supervision tree handles recovery. Defensive `rescue _ -> default` around these functions is an anti-pattern and must be removed.
- **`try/rescue` for external boundaries requires a justification comment.** The only accepted use is around genuinely untrusted external execution (e.g. `System.cmd` running project-config-defined shell commands in `DashboardLive`'s `run_command`), where a user-friendly error flash is better UX than a LiveView crash. Every retained `try/rescue` must carry a comment explaining why it is justified.
- **Atom conversion from untrusted input uses whitelist lookups, not `try/rescue`.** For converting user-supplied strings (URL params, form POST data) to atoms, use explicit `Map` lookups (`Map.get/2`, `Map.fetch/2`) or `case` against a known whitelist — never `String.to_existing_atom/1` wrapped in `try/rescue`, and never `String.to_atom/1` (atom-table exhaustion DoS risk).
