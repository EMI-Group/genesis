# EvoDash Web Interface

## Intent
The web interface layer for the EvoDash Phoenix application — a real-time dashboard for the EvoGit evolutionary software development system. Contains the Phoenix endpoint, router, telemetry supervisor, and delegates interactive UI to LiveView pages, reusable components, and classic controllers in subdirectories.

The parent module `EvoDashWeb` (at `lib/evo_dash_web.ex`, one level up) acts as the single entrypoint via a `__using__/1` macro, injecting common imports and verified routes into controllers, LiveViews, components, and HTML modules.

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
| `live/` | Phoenix LiveView pages | `DashboardLive` (task management dashboard), `AgentsLive` (agent tree inspector) |
| `components/` | Reusable HEEx function components | `CoreComponents` (buttons, forms, flash), `DashboardComponents` (task cards, forms), `AgentsComponents` (agent tree), `Layouts` (root layout) |
| `controllers/` | Classic HTTP controllers & error handlers | `PageController`, `ErrorHTML`, `ErrorJSON`, `PageHTML` |

### Parent Module (lib/evo_dash_web.ex)
`EvoDashWeb` — `__using__/1` macro dispatching to `:router`, `:channel`, `:controller`, `:live_view`, `:live_component`, `:html`. Provides `static_paths/0`, `verified_routes/0`, and `html_helpers/0` (imports CoreComponents, Phoenix.HTML, JS, Layouts).

## Constraints
- All web modules use `use EvoDashWeb, <role>` as their entrypoint — do not bypass the shared `__using__` macro.
- New interactive pages should be LiveViews in `live/`, not controllers in `controllers/`.
- Subdirectory naming conventions: `<name>_live.ex` for LiveViews, `<name>_components.ex` for component modules, `<name>_controller.ex` for controllers.
- Static assets served from `priv/static` under paths defined in `EvoDashWeb.static_paths/0`.
- Styling is Tailwind CSS + daisyUI throughout.
