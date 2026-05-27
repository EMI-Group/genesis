# EvoDash Web Interface

## Intent
The web interface layer for the EvoDash Phoenix application — a real-time dashboard for the EvoGit evolutionary software development system. Contains the Phoenix endpoint, router, telemetry supervisor, and delegates interactive UI to LiveView pages, reusable components, and classic controllers in subdirectories.

The parent module `EvoDashWeb` (at `lib/evo_dash_web.ex`, one level up) acts as the single entrypoint via a `__using__/1` macro, injecting common imports and verified routes into controllers, LiveViews, components, and HTML modules.

## Routing Table
- `live/` → Phoenix LiveView pages (Dashboard with project-based task management, Agents tree inspector)
- `components/` → Reusable HEEx UI components and layout templates
- `controllers/` → Classic HTTP controllers and error handlers

## API Surface

### Top-Level Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.Endpoint` | `endpoint.ex` | Phoenix endpoint — configures LiveView socket (`/live`), static file serving, code reloading, and the Plug pipeline (RequestId → Telemetry → Parsers → MethodOverride → Head → Session → Router). Sessions stored in signed cookies. |
| `EvoDashWeb.Router` | `router.ex` | Routes with `:browser` pipeline (HTML, session, flash, root layout, CSRF, secure headers). Live routes: `GET /` → `DashboardLive`, `GET /agents` → `AgentsLive`. Includes a commented-out `:api` pipeline for future JSON endpoints. |
| `EvoDashWeb.Telemetry` | `telemetry.ex` | Supervisor running `TelemetryPoller`. Defines summary metrics for Phoenix endpoint/router/channel performance, VM memory, and run queue lengths. |

### Subdirectories
| Directory | Purpose | Key Exports |
|-----------|---------|-------------|
| `live/` | Phoenix LiveView pages | `DashboardLive` (project-based task dashboard with auto-mode detection), `AgentsLive` (agent tree inspector) |
| `components/` | Reusable HEEx function components | `CoreComponents` (buttons, forms, flash), `DashboardComponents` (project tabs, open project form, task form, task cards), `AgentsComponents` (agent tree), `Layouts` (root layout) |
| `controllers/` | Classic HTTP controllers & error handlers | `PageController`, `ErrorHTML`, `ErrorJSON`, `PageHTML` |

### DashboardLive — Project-Based Workflow
The dashboard now uses a **Project** concept where users open a repository path first, then work within that project context:
- **No active project**: Shows an "Open Project" landing form + all tasks (unfiltered)
- **Active project**: Shows project tab bar, task form (path locked to project), and filtered tasks
- **Auto-mode detection**: When opening a project, the mode is auto-selected:
  - Empty directory → `genesis_new` (New Codebase)
  - Has files but no CONTEXT.md → `genesis_existing` (Existing Codebase)
  - Has CONTEXT.md → `evolve_simple` (Simple Top-down)
- **Multiple projects**: Users can open multiple repos and switch between them via tabs
- Events: `open_project`, `switch_project`, `close_project`, `show_open_project_form`, `hide_open_project_form`

### Parent Module (lib/evo_dash_web.ex)
`EvoDashWeb` — `__using__/1` macro dispatching to `:router`, `:channel`, `:controller`, `:live_view`, `:live_component`, `:html`. Provides `static_paths/0`, `verified_routes/0`, and `html_helpers/0` (imports CoreComponents, Phoenix.HTML, JS, Layouts).

## Constraints
- All web modules use `use EvoDashWeb, <role>` as their entrypoint — do not bypass the shared `__using__` macro.
- New interactive pages should be LiveViews in `live/`, not controllers in `controllers/`.
- Subdirectory naming conventions: `<name>_live.ex` for LiveViews, `<name>_components.ex` for component modules, `<name>_controller.ex` for controllers.
- Static assets served from `priv/static` under paths defined in `EvoDashWeb.static_paths/0`.
- Styling is Tailwind CSS + daisyUI throughout.
