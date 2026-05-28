# EvoDash — Phoenix LiveView Dashboard

## Intent

EvoDash is the **web-based dashboard application** for the EvoGit umbrella project. It provides a **project-based** real-time browser interface for launching and monitoring EvoGit tasks (genesis and evolve), inspecting the agent tree hierarchy, and viewing task logs — all powered by Phoenix LiveView with server-push updates.

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
| `EvoDash` | `./lib/evo_dash.ex` | Domain context placeholder |
| `EvoDash.Application` | `./lib/evo_dash/application.ex` | OTP supervisor (Telemetry → DNSCluster → PubSub → TaskRegistry → Endpoint) |
| `EvoDash.TaskRegistry` | `./lib/evo_dash/task_registry.ex` | ETS-backed GenServer tracking genesis/evolve tasks; spawns `EvoGit.Runtime.*` processes |
| `EvoDash.PubSub` | (started in app) | Phoenix PubSub for real-time event distribution |

### Web Layer (`lib/evo_dash_web/`)
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb` | `./lib/evo_dash_web.ex` | `use`-based macros for controller, live_view, html, etc. |
| `EvoDashWeb.Endpoint` | `./lib/evo_dash_web/endpoint.ex` | Phoenix endpoint (LiveView socket, static files, Plug pipeline) |
| `EvoDashWeb.Router` | `./lib/evo_dash_web/router.ex` | Routes: `/` → DashboardLive, `/agents` → AgentsLive |
| `EvoDashWeb.Telemetry` | `./lib/evo_dash_web/telemetry.ex` | Telemetry metrics supervisor (Phoenix + VM metrics) |
| `EvoDashWeb.Helpers` | `./lib/evo_dash_web/helpers.ex` | Shared utility functions for UI components (status badges, formatting, code deduplication) |

### LiveView Pages (`./lib/evo_dash_web/live/`)
| Module | Route | Purpose |
|--------|-------|---------|
| `EvoDashWeb.DashboardLive` | `GET /` | Project-based task dashboard: open project tabs, auto-mode detection, task form, task cards with logs |
| `EvoDashWeb.AgentsLive` | `GET /agents` | Recursive agent tree inspector with detail panels |

### UI Components (`./lib/evo_dash_web/components/`)
| Module | Purpose |
|--------|---------|
| `CoreComponents` | Phoenix 1.8 base components (header, flash, button, icon, input, table, theme_toggle) |
| `DashboardComponents` | `project_tabs` (multi-project tab bar), `open_project_form` (landing path input), `task_form` (mode-aware, auto-detected), `task_card` with status badges and logs |
| `AgentsComponents` | `agent_tree` — recursive tree with connector lines and status coloring |
| `Layouts` | Root HTML layout with theme persistence and flash group |

### Controllers (`./lib/evo_dash_web/controllers/`)
Standard Phoenix boilerplate: `PageController` (home), `ErrorHTML`, `ErrorJSON`. Most UI is LiveView-based.

### Frontend Assets (`./assets/`)
- **JS** (`./js/app.js`): LiveSocket setup with colocated hooks, topbar progress indicator
- **CSS** (`./css/app.css`): Tailwind CSS 4 + DaisyUI plugin with custom light/dark themes, Heroicons, LiveView loading variants
- **Vendor**: daisyui.js, daisyui-theme.js, heroicons.js, topbar.js

### Test Suite (`./test/`)
Minimal coverage: controller tests (PageController, error handlers) via `EvoDashWeb.ConnCase`. No LiveView tests yet.

## Key Interactions

```
Browser ←→ Endpoint ←→ Router
                          ├─ DashboardLive ←→ TaskRegistry ←→ EvoGit.Runtime.Genesis / Evolution
                          │   (project tabs, auto-mode, filtered task list)
                          └─ AgentsLive     ←→ (agent tree from EvoGit runtime)
```

- `TaskRegistry.start_task(:genesis, opts)` spawns a linked process calling `EvoGit.Runtime.Genesis.run/2`
- `TaskRegistry.start_task(:evolve, opts)` spawns a linked process calling `EvoGit.Runtime.Evolution.run/2`
- `TaskRegistry.list_tasks_by_path(path)` filters tasks by project repo path
- Task logs are piped back via `event_sink: {EvoDash.TaskRegistry, :update_task_log, [task_id]}`
- LiveViews poll TaskRegistry on timers (1s for dashboard, 500ms for agents)

### Persistence & State
- **Task persistence**: Completed task records are saved to `~/.local/share/evogit/` so they survive page reloads and server restarts.
- **Recent projects**: The dashboard tracks recently opened projects, allowing users to quickly reopen previously used repository paths.
- **PathAutocomplete**: A client-side JS hook provides filesystem path autocompletion in the project path input field.

### UI Theme
The dashboard uses a **modern Material Design-inspired theme** built on Tailwind CSS 4 + DaisyUI, with refined light/dark mode styling, consistent spacing, and polished visual hierarchy.

## Constraints

- **Umbrella dependency**: Must have `:evo_git` available at compile and runtime
- **Port**: Runs on port **4100** in development
- **Adapter**: Uses **Bandit** (not Cowboy) as the HTTP adapter
- **CSS framework**: Tailwind CSS 4 + DaisyUI (no Node.js toolchain; vendor files managed manually)
- **No database**: All task state is persisted to `~/.local/share/evogit/` on disk; project state is in LiveView socket assigns — recent projects survive reloads via file persistence
- **Single-node**: DNSCluster configured but no distributed clustering logic yet
- **Naming conventions**:
  - Domain modules: `./lib/evo_dash/<module>.ex`
  - Web modules: `./lib/evo_dash_web/<module>.ex`
  - LiveViews: `<name>_live.ex` / `<name>_live.html.heex`
  - Components: `<domain>_components.ex`
- **Build**: `mix assets.build` (esbuild + tailwind), `mix assets.deploy` (minified + digested)
- **Precommit**: `mix precommit` runs compile --warning-as-errors, deps.unlock --unused, format, test
