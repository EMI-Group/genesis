# EvoDash — Phoenix LiveView Dashboard

## Intent

EvoDash is the **web-based dashboard application** for the EvoGit umbrella project. It provides a **project-based** real-time browser interface for launching and monitoring EvoGit tasks (genesis and evolve), inspecting the agent tree hierarchy, viewing task logs, managing runtime scheduler settings, editing user configuration, and managing per-project settings including foreign repositories — all powered by Phoenix LiveView with server-push updates.

Users open a **Project** (a Git repository path), and the dashboard auto-detects the appropriate task mode based on the project state (empty directory, existing codebase with/without CONTEXT.md). Multiple projects can be open simultaneously with tab-based navigation.

This is a Phoenix 1.8 umbrella child app (`:evo_dash`) that depends on the sibling `:evo_git` application for all evolutionary code generation runtime operations.

## Routing Table
- `./assets/` → Frontend source assets (JavaScript, CSS, vendor libraries)
- `./lib/` → Application source code (`evo_dash/` domain logic, `evo_dash_web/` web interface)
- `./test/` → ExUnit test suite (controller tests, error handler tests, support modules)

## API Surface

### Application Entry & Supervision
| Module | File | Purpose |
|--------|------|---------|
| `EvoDash` | `./lib/evo_dash.ex` | Domain context placeholder (empty module) |
| `EvoDash.Application` | `./lib/evo_dash/application.ex` | OTP supervisor (Telemetry → DNSCluster → PubSub → TaskSupervisor → TaskRegistry → Endpoint) |
| `EvoDash.TaskRegistry` | `./lib/evo_dash/task_registry.ex` | ETS+DETS-backed GenServer tracking genesis/evolve tasks; spawns `EvoGit.Runtime.*` processes; one-time JSON→DETS migration on startup |
| `EvoDash.PubSub` | (started in app) | Phoenix PubSub for real-time event distribution |

### Web Layer (`lib/evo_dash_web/`)
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb` | `./lib/evo_dash_web.ex` | `use`-based macros for controller, live_view, html, etc. Imports CoreComponents and Helpers into all HTML/LiveView modules. |
| `EvoDashWeb.Endpoint` | `./lib/evo_dash_web/endpoint.ex` | Phoenix endpoint (LiveView socket, static files, Plug pipeline) |
| `EvoDashWeb.Router` | `./lib/evo_dash_web/router.ex` | Routes: `/` → DashboardLive, `/agents` → AgentsLive, `/settings` → SettingsLive, `/help` → HelpLive |
| `EvoDashWeb.Telemetry` | `./lib/evo_dash_web/telemetry.ex` | Telemetry metrics supervisor (Phoenix + VM metrics) |
| `EvoDashWeb.Helpers` | `./lib/evo_dash_web/helpers.ex` | Shared utility functions for UI components (status badges/colors, datetime formatting, icon mapping, modal component, tool call parsing, code deduplication) |

### Routes
| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `DashboardLive` | Project-based task dashboard: open project tabs, auto-mode detection, task form, project settings (evogit.toml, foreign repos), task cards with logs |
| `GET /agents` | `AgentsLive` | Recursive agent tree inspector with detail panels, chat history viewer |
| `GET /settings` | `SettingsLive` | Runtime scheduler configuration panel (concurrency, retries, depth, model) |
| `GET /help` | `HelpLive` | Configuration file manager: view/edit user config.toml, config status, .env reference |
| `/dashboard` | Phoenix.LiveDashboard | Built-in Phoenix dashboard (metrics/telemetry) |

### LiveView Pages (`./lib/evo_dash_web/live/`)
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.DashboardLive` | `dashboard_live.ex` | Main dashboard. Manages project tabs, task form, task list with expand/collapse, result/options modals, inline project settings panel (evogit.toml config, foreign repo add/remove). Polls TaskRegistry every 1s. Auto-detects mode on project open. Uses `@active_project` directly for project config reads. |
| `EvoDashWeb.AgentsLive` | `agents_live.ex` + `agents_live.html.heex` | Agent tree visualization. Reads directly from ETS tables (`evogit_agent_state`, `evogit_sched_meta`). Shows path-organized tree with expandable agent details, chat history, modals for full messages/objectives. Polls every 1s. |
| `EvoDashWeb.SettingsLive` | `settings_live.ex` | Runtime scheduler settings. Reads from `EvoGit.AgentScheduler.get_config/0`. Updates via `EvoGit.AgentScheduler.update_config/1`. Blocks concurrency changes while agents running. Polls every 2s. |
| `EvoDashWeb.HelpLive` | `help_live.ex` | Configuration management. Shows config status (missing fields), config file locations, TOML editor with save (validates TOML syntax before saving via `EvoGit.Config.save_user_config/1`), .env reference (read-only), configuration reference. |

### UI Components (`./lib/evo_dash_web/components/`)
| Module | Purpose |
|--------|---------|
| `CoreComponents` | Phoenix 1.8 base components (header, flash, button, icon, input, table, list, error display) |
| `DashboardComponents` | `task_form` (mode + prompt), `scheduler_settings` (6-field runtime config panel), `project_tabs` (multi-project tab bar), `open_project_form` (landing path input with recent projects), `task_card` (status badge, expandable details, logs, options, result display) |
| `AgentsComponents` | `path_tree` — recursive tree with connector lines and status coloring |
| `Layouts` | `app/1` layout (sticky navbar with Dashboard/Agents/Settings/Help links, mobile hamburger, config warning banner, flash group), `root.html.heex` (HTML skeleton with theme persistence), `theme_toggle/1` (system/light/dark toggle), `flash_group/1` |

### Controllers (`./lib/evo_dash_web/controllers/`)
Standard Phoenix boilerplate: `PageController` (home), `ErrorHTML`, `ErrorJSON`. Most UI is LiveView-based.

### Frontend Assets (`./assets/`)
- **JS** (`./js/app.js`): LiveSocket setup with `PathAutocomplete` hook (Tab completion + real-time autocomplete), colocated hooks, topbar progress indicator
- **CSS** (`./css/app.css`): Tailwind CSS 4 + DaisyUI plugin with custom light/dark themes (Material Design 3 inspired, oklch colors), Heroicons, LiveView loading variants, scrollbar styling, glass morphism, smooth theme transitions
- **Vendor**: daisyui.js, daisyui-theme.js, heroicons.js, topbar.js

### Test Suite (`./test/`)
- **Controller tests**: PageController, error handlers via `EvoDashWeb.ConnCase`
- **LiveView tests** (`test/evo_dash_web/live/dashboard_live_test.exs`): DashboardLive tests covering project settings integration — project open/close, settings panel toggle, config display, foreign repos, route removal verification (14 tests)

## Key Interactions

```
Browser ←→ Endpoint ←→ Router
                          ├─ DashboardLive     ←→ TaskRegistry ←→ EvoGit.Runtime.Genesis / Evolution
                          │   (project tabs, auto-mode, filtered task list)
                          │   ←→ EvoGit.AgentScheduler (get_foreign_repos, register/unregister_foreign_repo)
                          │   ←→ EvoGit.ProjectConfig (read, worktree_script)
                          ├─ AgentsLive        ←→ ETS tables (evogit_agent_state, evogit_sched_meta)
                          ├─ SettingsLive      ←→ EvoGit.AgentScheduler (get_config/update_config)
                          └─ HelpLive          ←→ EvoGit.Config (config_status, save_user_config, paths)
```

### TaskRegistry ↔ EvoGit Runtime
- `TaskRegistry.start_task(:genesis, opts)` spawns a linked process calling `EvoGit.Runtime.Genesis.run/2`
- `TaskRegistry.start_task(:evolve, opts)` spawns a linked process calling `EvoGit.Runtime.Evolution.run/2`
- `TaskRegistry.list_tasks_by_path(path)` filters tasks by project repo path
- Task logs are piped back via `event_sink: {EvoDash.TaskRegistry, :update_task_log, [task_id]}`
- Tasks run under `EvoDash.TaskSupervisor` (Task.Supervisor)

### AgentsLive ↔ EvoGit ETS Tables
- Directly reads `:evogit_agent_state` and `:evogit_sched_meta` ETS tables
- No GenServer call — reads agent state, context paths, phylo nodes, LLM history
- Parses `ReqLLM.Context` messages into history entries

### SettingsLive ↔ EvoGit.AgentScheduler
- `EvoGit.AgentScheduler.get_config/0` → current runtime config
- `EvoGit.AgentScheduler.update_config/1` → update with `{:error, :agents_running}` guard
- Config fields: max_concurrency, max_tool_concurrency, agent_max_retries, max_agent_depth, max_retries, llm_model

### DashboardLive (Project Settings) ↔ EvoGit.AgentScheduler + ProjectConfig
- `EvoGit.AgentScheduler.get_foreign_repos/0` → list of all registered ForeignRepo structs (including primary)
- `EvoGit.AgentScheduler.register_foreign_repo/1` → add a new foreign repo
- `EvoGit.AgentScheduler.unregister_foreign_repo/1` → remove a foreign repo
- `EvoGit.ProjectConfig.read/1` → read evogit.toml config map from project root (uses `@active_project`)
- Project root comes directly from `@active_project` assign (not from scheduler state)
- All calls wrapped in try/rescue for resilience when scheduler is not running

### HelpLive ↔ EvoGit.Config
- `EvoGit.Config.config_status/0` → %{missing, warnings, ok?}
- `EvoGit.Config.config_dir/0`, `config_path/0`, `env_path/0` → file locations
- `EvoGit.Config.save_user_config/1` → writes parsed TOML to config file

### Polling Intervals
| LiveView | Timer Interval | Purpose |
|----------|---------------|---------|
| DashboardLive | 1000ms | Refresh task list + refresh project settings when panel is open |
| AgentsLive | 1000ms | Refresh agent tree |
| SettingsLive | 2000ms | Refresh scheduler config |

### Persistence & State
- **Task persistence**: Completed task records are persisted via DETS (Erlang's built-in disk storage) to the platform-appropriate data directory (resolved by `EvoGit.Platform.data_dir/0`). Up to 10 most recent finished tasks are kept. DETS corruption is auto-recovered.
- **Recent projects**: Up to 10 recently opened projects persisted via DETS with `last_opened_at` timestamps.
- **PathAutocomplete**: A client-side JS hook provides filesystem path autocompletion with Tab completion and real-time auto-fill.
- **Scheduler configuration**: Runtime overrides via `EvoGit.AgentScheduler.update_config/1`. These are session-level and don't persist across restarts (per three-level config architecture: defaults → user config TOML → runtime override).

### UI Theme
The dashboard uses a **Material Design 3-inspired theme** built on Tailwind CSS 4 + DaisyUI, with custom light/dark mode themes defined in oklch color space, consistent spacing, and polished visual hierarchy. Theme is persisted in `localStorage` via `phx:theme` key.

## Component Patterns

### File Organization
- LiveViews: `<name>_live.ex` for logic, `<name>_live.html.heex` for templates (some LiveViews use inline `~H` sigils instead)
- Components: `<domain>_components.ex` files with function components using `attr`/`slot` declarations
- Shared helpers: `Helpers` module imported via `use EvoDashWeb, :html` and `use EvoDashWeb, :live_view`
- Layout: `Layouts` module with `app/1` function component wrapping all pages

### Common Patterns
- All LiveViews wrap content in `<EvoDashWeb.Layouts.app flash={@flash} current_page={:page_atom} config_status={@config_status}>`
- Forms use `<.form for={%{}} phx-submit="event" phx-change="event">` (non-changeset forms)
- Modals use DaisyUI `modal modal-open` pattern with backdrop click-to-close
- Icons use `<.icon name="hero-..." />` component from CoreComponents
- Status colors use helper functions from `Helpers` module (agent_status_color, task_status_badge, etc.)
- Cards use DaisyUI card classes with custom `rounded-2xl shadow-lg border border-base-200` styling

## Constraints

- **Umbrella dependency**: Must have `:evo_git` available at compile and runtime
- **Port**: Runs on port **4100** in development
- **Adapter**: Uses **Bandit** (not Cowboy) as the HTTP adapter
- **CSS framework**: Tailwind CSS 4 + DaisyUI (no Node.js toolchain; vendor files managed manually)
- **No database**: All task state is persisted via DETS to the platform-appropriate data directory; project state is in LiveView socket assigns — recent projects survive reloads via DETS persistence
- **Single-node**: DNSCluster configured but no distributed clustering logic yet
- **Naming conventions**:
  - Domain modules: `./lib/evo_dash/<module>.ex`
  - Web modules: `./lib/evo_dash_web/<module>.ex`
  - LiveViews: `<name>_live.ex` / `<name>_live.html.heex`
  - Components: `<domain>_components.ex`
- **Build**: `mix assets.build` (esbuild + tailwind), `mix assets.deploy` (minified + digested)
- **Precommit**: `mix precommit` runs compile --warning-as-errors, deps.unlock --unused, format, test
- **Colocated hooks**: Uses `phoenix-colocated` package for JS hooks alongside LiveView templates
