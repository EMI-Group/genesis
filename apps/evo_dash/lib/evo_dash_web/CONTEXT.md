# EvoDash Web Interface

## Intent
The web interface layer for the EvoDash Phoenix application — a real-time dashboard for the EvoGit evolutionary software development system. Contains the Phoenix endpoint, router, telemetry supervisor, and delegates interactive UI to LiveView pages, reusable components, and classic controllers in subdirectories.

The parent module `EvoDashWeb` (at `lib/evo_dash_web.ex`, one level up) acts as the single entrypoint via a `__using__/1` macro, injecting common imports and verified routes into controllers, LiveViews, components, and HTML modules.

## Routing Table
- `live/` → Phoenix LiveView pages (Dashboard, Agents, Settings, Help & Config)
- `components/` → Reusable HEEx UI components and layout templates
- `controllers/` → Classic HTTP controllers and error handlers

## API Surface

### Top-Level Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.Endpoint` | `endpoint.ex` | Phoenix endpoint — configures LiveView socket (`/live`), static file serving, code reloading, and the Plug pipeline (RequestId → Telemetry → Parsers → MethodOverride → Head → Session → Router). Sessions stored in signed cookies. |
| `EvoDashWeb.Router` | `router.ex` | Routes with `:browser` pipeline (HTML, session, flash, root layout, CSRF, secure headers). Live routes: `GET /` → `DashboardLive`, `GET /agents` → `AgentsLive`, `GET /settings` → `SettingsLive`, `GET /help` → `HelpLive`. Includes a commented-out `:api` pipeline for future JSON endpoints. |
| `EvoDashWeb.Telemetry` | `telemetry.ex` | Supervisor running `TelemetryPoller`. Defines summary metrics for Phoenix endpoint/router/channel performance, VM memory, and run queue lengths. |
| `EvoDashWeb.Helpers` | `helpers.ex` | Shared utility functions used across components (status badge helpers, formatting, etc.). Provides centralized code deduplication for the component layer. |

### Subdirectories
| Directory | Purpose | Key Exports |
|-----------|---------|-------------|
| `live/` | Phoenix LiveView pages | `DashboardLive` (project-based task dashboard with auto-mode detection), `AgentsLive` (agent tree inspector), `SettingsLive` (scheduler runtime config), `HelpLive` (config file management & help) |
| `components/` | Reusable HEEx function components | `CoreComponents` (buttons, forms, flash with `:info`/`:error`/`:warning` kinds), `DashboardComponents` (project tabs, open project form, task form, task cards, scheduler settings), `AgentsComponents` (agent tree), `Layouts` (app layout with nav, root layout) |
| `controllers/` | Classic HTTP controllers & error handlers | `PageController`, `ErrorHTML`, `ErrorJSON`, `PageHTML` |

### LiveView Routes
| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `DashboardLive` | Project-based task dashboard with auto-mode detection |
| `GET /agents` | `AgentsLive` | Agent tree inspector with real-time hierarchy |
| `GET /settings` | `SettingsLive` | Runtime scheduler configuration (concurrency, retries, depth, model) with config status warnings |
| `GET /help` | `HelpLive` | Configuration file management, TOML editor, config reference |

### DashboardLive — Project-Based Workflow
The dashboard uses a **Project** concept where users open a repository path first, then work within that project context:
- **No active project**: Shows an "Open Project" landing form + all tasks (unfiltered)
- **Active project**: Shows project tab bar, task form (path locked to project), and filtered tasks
- **Auto-mode detection**: When opening a project, the mode is auto-selected:
  - Empty directory → `genesis_new` (New Codebase)
  - Has files but no CONTEXT.md → `genesis_existing` (Existing Codebase)
  - Has CONTEXT.md → `evolve_simple` (Simple Top-down)
- **Multiple projects**: Users can open multiple repos and switch between them via tabs
- Events: `open_project`, `switch_project`, `close_project`, `show_open_project_form`, `hide_open_project_form`

### SettingsLive — Scheduler Configuration
The settings page provides runtime control over agent execution parameters:
- Displays current scheduler config from `EvoGit.AgentScheduler.get_config/0`
- Shows config status warnings from `EvoGit.Config.config_status/0` (missing model, API keys, username)
- Inline form for updating: `max_concurrency`, `max_tool_concurrency`, `agent_max_retries`, `max_agent_depth`, `max_retries`, `llm_model`
- Updates via `EvoGit.AgentScheduler.update_config/1`; blocks concurrency changes while agents are running
- Auto-refreshes every 2 seconds

### HelpLive — Configuration Management
The help page provides an in-browser configuration editor:
- Displays config status (all configured / missing warnings)
- Shows config file locations with existence indicators
- TOML editor for `config.toml` with validation and save via `EvoGit.Config.save_user_config/1`
- Configuration reference with example values for all supported settings

### Navigation
All pages use `EvoDashWeb.Layouts.app/1` which provides:
- Sticky navigation bar with links to Dashboard, Agents, Settings, Help
- Active page highlighting via `current_page` assign
- Theme toggle (system/light/dark)
- Responsive mobile hamburger menu
- Flash message group (`:info`, `:error`, `:warning`)

### Parent Module (lib/evo_dash_web.ex)
`EvoDashWeb` — `__using__/1` macro dispatching to `:router`, `:channel`, `:controller`, `:live_view`, `:live_component`, `:html`. Provides `static_paths/0`, `verified_routes/0`, and `html_helpers/0` (imports CoreComponents, Phoenix.HTML, JS, Layouts).

## Constraints
- All web modules use `use EvoDashWeb, <role>` as their entrypoint — do not bypass the shared `__using__` macro.
- New interactive pages should be LiveViews in `live/`, not controllers in `controllers/`.
- Subdirectory naming conventions: `<name>_live.ex` for LiveViews, `<name>_components.ex` for component modules, `<name>_controller.ex` for controllers.
- Static assets served from `priv/static` under paths defined in `EvoDashWeb.static_paths/0`.
- Styling is Tailwind CSS + daisyUI throughout.
