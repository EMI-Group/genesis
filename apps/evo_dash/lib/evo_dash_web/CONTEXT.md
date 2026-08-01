# EvoDash Web Interface

## Intent
The web interface layer for the EvoDash Phoenix application — a real-time dashboard for the EvoGit evolutionary software development system. Contains the Phoenix endpoint, router, telemetry supervisor, and delegates interactive UI to LiveView pages, reusable components, and classic controllers in subdirectories.

## Routing Table
- `live/` → Phoenix LiveView pages (Dashboard, Agents, Settings, System & Config)
- `live_hooks/` → On-mount hooks: `SetLocale` (locale), `NodeAware` (node-aware dashboard)
- `components/` → Reusable HEEx UI components and layout templates
- `controllers/` → Classic HTTP controllers and error handlers
- `plugs/` → HTTP middleware plugs (Locale)

## API Surface

### Top-Level Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.Endpoint` | `endpoint.ex` | Phoenix endpoint with LiveView socket, static files, and Plug pipeline. |
| `EvoDashWeb.Router` | `router.ex` | Browser-pipeline routes to all LiveView pages, plus a classic controller route for JSON export. |
| `EvoDashWeb.Telemetry` | `telemetry.ex` | Supervisor with TelemetryPoller for endpoint/channel/VM metrics. |
| `EvoDashWeb.Helpers` | `helpers.ex` | Shared utilities for status badges, formatting, and icon helpers. |
| `EvoDashWeb.Gettext` | `gettext.ex` | Gettext backend for i18n (`use Gettext, otp_app: :evo_dash`). Imported via `html_helpers/0` into all LiveViews/components. |
| `EvoDashWeb` | `evo_dash_web.ex` | Shared `__using__` macro dispatching to role-specific `import`s/`use`s. **On-mount hooks**: the `live_view/0` macro registers `EvoDashWeb.LiveHooks.SetLocale` and `EvoDashWeb.LiveHooks.NodeAware`, so ALL LiveViews are locale-set and node-aware by default. |
| `EvoDashWeb.LiveHooks.SetLocale` | `live_hooks/set_locale.ex` | On-mount hook that sets the Gettext locale from the `locale` session/param. |
| `EvoDashWeb.LiveHooks.NodeAware` | `live_hooks/node_aware.ex` | On-mount hook + helpers for **SSH Remote Development** (node-aware dashboard, Phase 2). Sets node-context assigns (`@current_node`, `@current_node_name`, `@current_node_id`, `@remote_targets`, `@connection_statuses`) with safe local defaults and subscribes to the `EvoGit.PubSub` `"remote_connections"` topic. Helpers: `assign_node/2` (reads the `?node=` query param in `handle_params`, resolving a saved+connected target or falling back to local), `handle_node_selected/2` (builds a `push_patch` to update the URL), `handle_connection_status/2`. |

### Subdirectories
| Directory | Purpose |
|-----------|---------|
| `live/` | Phoenix LiveView pages: Dashboard, Agents, Settings, System, Tasks, Review. Also contains the `live/components/` subdirectory (LiveComponents like `NodeSelectorComponent`). |
| `live/components/` | LiveComponents (`use EvoDashWeb, :live_component`): `NodeSelectorComponent` (navbar node selector + connection manager modal for SSH Remote Development). |
| `live_hooks/` | On-mount hooks: `SetLocale` (locale), `NodeAware` (node-aware dashboard). |
| `components/` | Reusable HEEx components: CoreComponents, DashboardComponents, AgentsComponents, Layouts. |
| `controllers/` | Classic HTTP controllers and error handlers. Includes `TaskExportController` (JSON export of archived task metadata). |

### LiveView Routes
| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `SimpleLive.Home` | **Simple-mode home (default)** — minimal Google/Quark-style task input: one big prompt box with a small project-switcher popover. Launching a task navigates to `/tree`. First-open (onboarding needed) redirects to `/welcome`. A small "Pro" corner link enters the pro dashboard. |
| `GET /dashboard` | `DashboardLive` | Pro dashboard — project selector, task form, project settings, task history. URL-based project state via `?project=<path>` query param. |
| `GET /welcome` | `WelcomeLive` | Simple-mode onboarding (step 1): minimal single-column LLM setup (search + model grid + API key, merged save). Uses the bare `Layouts.simple`. |
| `GET /tree` | `AgentsLive` (`:simple`) | Simple-mode fullscreen agent tree (step 3): no sidebar, thin top bar (home link, task tabs, review entry, pro link). |
| `GET /review/:task_id` | `ReviewLive` (`:show`) | Code review page — diff viewer with expandable context, commit list, merge/reject/continue actions. Supports post-merge re-review via persisted SHAs. |
| `GET /review/:task_id/commit/:commit_sha` | `ReviewLive` (`:commit`) | Single-commit inspection — reuses the shared diff viewer component to show changes for one commit. |
| `GET /agents` | `AgentsLive` | Agent tree inspector with real-time hierarchy (pro mode, full `Layouts.app` shell) |
| `GET /settings` | `SettingsLive` | Runtime scheduler configuration |
| `GET /system` | `SystemLive` | Scheduler controls, system controls (restart/stop), system self-check, and usage guides/references |
| `GET /tasks/:task_id/export` | `TaskExportController` (`:export`) | Downloads a task's `archive_metadata` as a JSON file (`archive-<task_id>.json`). Returns 404 when the task or archive data is missing. |

## Constraints
- All web modules use `use EvoDashWeb, <role>` as their entrypoint — do not bypass the shared `__using__` macro.
- New interactive pages should be LiveViews in `live/`, not controllers in `controllers/`.
- Subdirectory naming conventions: `<name>_live.ex` for LiveViews, `<name>_components.ex` for component modules, `<name>_controller.ex` for controllers.
- Static assets served from `priv/static` under paths defined in `EvoDashWeb.static_paths/0`.
- Styling is Tailwind CSS + daisyUI throughout. Simple-mode pages (`/`, `/welcome`, `/tree`) use the bare `Layouts.simple` shell inside a `.simple-ui` scope (fixed light palette in `app.css`) that is isolated from the `data-art` art-style system; pro pages keep `Layouts.app` and the full theme/art-style machinery. Isolation is two-way: the root-layout inline script removes `data-art` from `<html>` while a `.simple-ui` page is mounted (restoring it on return to pro pages), because art styles use global element selectors that would otherwise leak in.
- **Simple-mode themes**: a fixed top-right switcher (`Layouts.simple_theme_selector`) offers 4 themes — 白天 day (default), 黑夜 night, 水墨 ink, 终端 terminal — persisted client-side as `phx:simple-theme` → `data-simple-theme` on `<html>`; per-theme CSS blocks in `app.css` are scoped to `.simple-ui` (daisy vars + utility overrides + `--sc-*` tree-chrome vars + `--evo-*` graph palette; day/night use the EVOX logo red `#C8383C`).
- **Demo seeding (dev only)**: `GET /demo/seed` (`DemoController`) → `EvoDash.DemoSeed` (demo repo + `demo-1`/`demo-2` completed tasks matching the built-in `?demo=1` agent trees) and `EvoDash.DemoSeedRich` (`demo-3`, a content-rich review: 5 commits / 11 files / long markdown summary). View via `/tree?demo=1` → 审查 → `/tree/review/demo-N`.
- **Professional design language** (Settings, Tasks, Review, System pages): compact, dense, "power-tool" aesthetic inspired by VS Code / GitHub — `rounded-lg`/`rounded-md` radii (no `rounded-3xl`/`rounded-2xl` large cards), subtle borders, restrained color, no gradient hero boxes or decorative blurs. Settings uses one-config-value-per-full-width-row layout; the config file path is shown at the top with a copy-to-clipboard button (`ClipboardCopy` hook).
- **`try/rescue` is an anti-pattern here.** Do NOT wrap config/core-value loading (`EvoGit.Config.*`, `EvoGit.AgentScheduler.*`, `EvoGit.SystemCheck.*`) in `try/rescue` — if these crash, the LiveView SHOULD crash truthfully so the real error is visible (displaying a wrong default like `%{}`, `false`, or `100_000` is worse than a visible crash). The only accepted `try/rescue` uses are: (1) genuinely untrusted external execution like `System.cmd` running user-defined shell commands (`DashboardLive`), and (2) `Lumis.highlight!` per-line in `review_components.ex` (no non-crashing variant exists). Every retained `try/rescue` MUST carry an inline justification comment. For converting untrusted strings to atoms, use whitelist `Map` lookups (`Map.get/2`/`Map.fetch/2`) — never bare `String.to_existing_atom/1` on client input, and never `String.to_atom/1` (atom-table exhaustion DoS risk).
