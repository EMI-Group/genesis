# EvoDash Web Interface

## Intent
The web interface layer for the EvoDash Phoenix application — a real-time dashboard for the EvoGit evolutionary software development system. Contains the Phoenix endpoint, router, telemetry supervisor, and delegates interactive UI to LiveView pages, reusable components, and classic controllers in subdirectories.

## Routing Table
- `live/` → Phoenix LiveView pages (Dashboard, Agents, Settings, System & Config)
- `components/` → Reusable HEEx UI components and layout templates
- `controllers/` → Classic HTTP controllers and error handlers

## API Surface

### Top-Level Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.Endpoint` | `endpoint.ex` | Phoenix endpoint with LiveView socket, static files, and Plug pipeline. |
| `EvoDashWeb.Router` | `router.ex` | Browser-pipeline routes to all LiveView pages. |
| `EvoDashWeb.Telemetry` | `telemetry.ex` | Supervisor with TelemetryPoller for endpoint/channel/VM metrics. |
| `EvoDashWeb.Helpers` | `helpers.ex` | Shared utilities for status badges, formatting, and icon helpers. |
| `EvoDashWeb.Gettext` | `gettext.ex` | Gettext backend for i18n (`use Gettext, otp_app: :evo_dash`). Imported via `html_helpers/0` into all LiveViews/components. |

### Subdirectories
| Directory | Purpose |
|-----------|---------|
| `live/` | Phoenix LiveView pages: Dashboard, Agents, Settings, System. |
| `components/` | Reusable HEEx components: CoreComponents, DashboardComponents, AgentsComponents, Layouts. |
| `controllers/` | Classic HTTP controllers and error handlers. |

### LiveView Routes
| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `DashboardLive` | Unified dashboard — project selector, task form, project settings, task history. URL-based project state via `?project=<path>` query param. |
| `GET /review/:task_id` | `ReviewLive` (`:show`) | Code review page — diff viewer with expandable context, commit list, merge/reject/continue actions. Supports post-merge re-review via persisted SHAs. |
| `GET /review/:task_id/commit/:commit_sha` | `ReviewLive` (`:commit`) | Single-commit inspection — reuses the shared diff viewer component to show changes for one commit. |
| `GET /agents` | `AgentsLive` | Agent tree inspector with real-time hierarchy |
| `GET /settings` | `SettingsLive` | Runtime scheduler configuration |
| `GET /system` | `SystemLive` | Scheduler controls, system controls (restart/stop), system self-check, and usage guides/references |

## Constraints
- All web modules use `use EvoDashWeb, <role>` as their entrypoint — do not bypass the shared `__using__` macro.
- New interactive pages should be LiveViews in `live/`, not controllers in `controllers/`.
- Subdirectory naming conventions: `<name>_live.ex` for LiveViews, `<name>_components.ex` for component modules, `<name>_controller.ex` for controllers.
- Static assets served from `priv/static` under paths defined in `EvoDashWeb.static_paths/0`.
- Styling is Tailwind CSS + daisyUI throughout.
