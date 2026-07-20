# LiveView Pages

## Intent
Phoenix LiveView modules and templates for the EvoDash interactive UI — real-time task management, agent inspection, runtime configuration, and user help.

## Routing Table
- `components/` → LiveComponents (`use EvoDashWeb, :live_component`) — `NodeSelectorComponent` for the SSH Remote Development node selector
- `dashboard_live/` → Support modules extracted from `DashboardLive`: `StatePersistence`, `Project`, `Assigns`
- `settings_live/` → Support modules extracted from `SettingsLive`: `ModelProfileHelpers` (pure data-transformation for `[[llm.models]]` CRUD), `ConfigIO` (config loading, runtime updates, atom whitelists)
- `system_live/` → Support modules extracted from `SystemLive`: `Content` (static guides/references), `Status` (health-check status helpers)

## API Surface

| Module | Route | Summary |
|--------|-------|---------|
| `DashboardLive` | `GET /` | Project-based task dashboard with genesis/evolve forms, auto-mode detection, real-time task cards, and project tabs. Delegates to `TaskRegistry` and `DashboardComponents`. |
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

## Constraints
- Each LiveView uses either an inline `render/1` or a companion `.html.heex` template — not both. (Three render inline; `AgentsLive` uses a separate template.)
- Auto-refresh intervals must be gated behind `connected?/1` to avoid leaking timers.
- Naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
- **No `try/rescue` around config/core-value loading.** LiveViews must NOT wrap `EvoGit.Config.*`, `EvoGit.AgentScheduler.*`, or `EvoGit.SystemCheck.*` calls in `try/rescue`. If these crash, the LiveView SHOULD crash truthfully — displaying a wrong default value (e.g. `false`, `%{}`, `100_000`) is worse than a visible crash, and the supervision tree handles recovery. Defensive `rescue _ -> default` around these functions is an anti-pattern and must be removed.
- **`try/rescue` for external boundaries requires a justification comment.** The only accepted use is around genuinely untrusted external execution (e.g. `System.cmd` running project-config-defined shell commands in `DashboardLive`'s `run_command`), where a user-friendly error flash is better UX than a LiveView crash. Every retained `try/rescue` must carry a comment explaining why it is justified.
- **Atom conversion from untrusted input uses whitelist lookups, not `try/rescue`.** For converting user-supplied strings (URL params, form POST data) to atoms, use explicit `Map` lookups (`Map.get/2`, `Map.fetch/2`) or `case` against a known whitelist — never `String.to_existing_atom/1` wrapped in `try/rescue`, and never `String.to_atom/1` (atom-table exhaustion DoS risk).
