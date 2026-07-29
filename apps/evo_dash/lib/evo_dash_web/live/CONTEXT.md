# LiveView Pages

## Intent
Phoenix LiveView modules and templates for the EvoDash interactive UI — real-time task management, agent inspection, runtime configuration, and user help.

## Routing Table
- `components/` → LiveComponents (`use EvoDashWeb, :live_component`) — `NodeSelectorComponent` for the SSH Remote Development node selector (rendered only inside Settings → Remote Connections; no longer in the sidebar)
- `dashboard_live/` → Support modules extracted from `DashboardLive`: `StatePersistence`, `Project`, `Assigns`
- `settings_live/` → Support modules extracted from `SettingsLive`: `ModelProfileHelpers` (pure data-transformation for `[[llm.models]]` CRUD), `ConfigIO` (config loading, runtime updates, atom whitelists), `SystemSection` (`:system` / `:help` pseudo-category UI — ported from the retired `/system` page), `HelpContent` (static guides/references)

## API Surface

| Module | Route | Summary |
|--------|-------|---------|
| `DashboardLive` | `GET /` | Project-based task dashboard in a **numbered 3-step workflow**: `step_header` ① Select Project (**browser-style project tab bar** — projects as switchable tabs with active highlight + New/Open icon buttons, active path panel below), ② Describe the Task (slim prompt composer: mode + prompt + execute only), ③ Tasks (merged task-history section: filter by status/project/review, search, server-side pagination). Everything else (model/build/archive selects, evolve advanced options, genesis.toml project settings, foreign repos) lives in a single obvious **Advanced** collapsible. |
| `WelcomeLive` | `GET /welcome` | Onboarding tutorial with 4 steps — LLM configuration, project setup, and getting started. Redirects to dashboard if already completed. |
| `ReviewLive` | `GET /review/:task_id` | Code review page — diff viewer with syntax highlighting, commit list, agent summary, and action buttons (Merge, Reject, Continue, Create GitHub PR, Extract Skills). The Extract Skills action opens a modal for an optional user note, then starts an `:extract_skills` task via `TaskRegistry` that spawns a `SkillExtractor` agent to distill PR knowledge into `.agents/skills/` files. |
| `AgentsLive` | `GET /agents` | **Task evolution graph** (`EvolutionGraph` JS hook, ported from `evogit-tree-lr.html`): animated left-to-right agent tree on a dark canvas with state-colored nodes/edges, zoom/pan, legend, and hover tips. Fed by real agent data (`graph_payload/2` + `push_event("agents:sync")`). **One tree per view** — agents are grouped by task and a tab bar (`select_tree` event) switches between independent project trees; the payload is filtered to the selected task. `?demo=1` serves a built-in two-tree demo set through the real code path. Selecting a node opens the agent detail panel (chat history, usage, objective) on the right. |
| `SettingsLive` | `GET /settings` | Runtime scheduler configuration (concurrency, retries, depth, LLM model) plus pseudo-categories: `:remote_connections` (SSH targets), `:system` (scheduler pause/resume, restart/stop with confirmation, system self-check — ported from the retired `/system` page), `:help` (guides/FAQ/config reference). Shows config status warnings. Updates via `AgentScheduler.update_config/1`. Auto-refreshes every 2s. |

**Retired routes** (404): `/tasks` (merged into `/`), `/system` (split into Settings `:system` / `:help` categories), `/dashboard` (Phoenix LiveDashboard iframe removed; `live_dashboard("/phoenix/dashboard")` remains for development).

### LiveComponents (`./components/`)
- **`NodeSelectorComponent`** (`components/node_selector_component.ex`) — `EvoDashWeb.NodeSelectorComponent`, a `use EvoDashWeb, :live_component` LiveComponent **no longer rendered in the sidebar** (removed in the workflow decluttering); SSH remote targets are now managed under Settings → Remote Connections, and the `?node=<id>` query param mechanism (via `Layouts.with_node_param/2`) is unchanged. Shows the current node with a status dot + a dropdown (Local / saved targets / "Manage Connections...") and a full **connection manager modal**. Manages its own state; selects nodes by sending `{:node_selected, id}` to the parent LiveView. Subscribes to the `"remote_connections"` PubSub topic via the parent LiveView's subscription.

### Templates
- **`agents_live.html.heex`** — Companion template for `AgentsLive` with the evolution-graph canvas (left) + detail panel (right) layout.

### Node-Aware Integration (SSH Remote Development, Phase 2)
All LiveViews register the `EvoDashWeb.LiveHooks.NodeAware` on-mount hook (via the `live_view/0` macro in `evo_dash_web.ex`). As part of the node-aware pattern, each LiveView:
- Calls `assign_node/2` in `handle_params/3` (reads the `?node=<id>` query param, resolving it to a saved+connected target or falling back to local).
- Passes `current_node_id` / `current_node_name` (and `remote_targets` / `connection_statuses`) to the `Layouts.app/1` call.
- Handles `{:node_selected, _}` (delegated to `NodeAware.handle_node_selected/2`) and `{:remote_connection_status, _, _}` messages (delegated to `NodeAware.handle_connection_status/2`).

### Shared Conventions
- All LiveViews use `use EvoDashWeb, :live_view` and import `CoreComponents` and `Layouts`.
- All pages use `EvoDashWeb.Layouts.app/1` layout with `current_page` for nav highlighting. Sidebar nav: **Tasks (`/`), Agents (`/agents`), Settings (`/settings`)**.
- Styled with DaisyUI/Tailwind CSS; business logic delegated to context modules.

## Constraints
- Each LiveView uses either an inline `render/1` or a companion `.html.heex` template — not both. (Three render inline; `AgentsLive` uses a separate template.)
- Auto-refresh intervals must be gated behind `connected?/1` to avoid leaking timers.
- Naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
- **No `try/rescue` around config/core-value loading.** LiveViews must NOT wrap `EvoGit.Config.*`, `EvoGit.AgentScheduler.*`, or `EvoGit.SystemCheck.*` calls in `try/rescue`. If these crash, the LiveView SHOULD crash truthfully — displaying a wrong default value (e.g. `false`, `%{}`, `100_000`) is worse than a visible crash, and the supervision tree handles recovery. Defensive `rescue _ -> default` around these functions is an anti-pattern and must be removed.
- **`try/rescue` for external boundaries requires a justification comment.** The only accepted use is around genuinely untrusted external execution (e.g. `System.cmd` running project-config-defined shell commands in `DashboardLive`'s `run_command`), where a user-friendly error flash is better UX than a LiveView crash. Every retained `try/rescue` must carry a comment explaining why it is justified.
- **Atom conversion from untrusted input uses whitelist lookups, not `try/rescue`.** For converting user-supplied strings (URL params, form POST data) to atoms, use explicit `Map` lookups (`Map.get/2`, `Map.fetch/2`) or `case` against a known whitelist — never `String.to_existing_atom/1` wrapped in `try/rescue`, and never `String.to_atom/1` (atom-table exhaustion DoS risk).
