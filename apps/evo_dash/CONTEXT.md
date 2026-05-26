# EvoDash — Phoenix LiveView Dashboard

## Intent

EvoDash is the **web-based dashboard application** for the EvoGit umbrella project. It provides a real-time browser interface for launching and monitoring EvoGit tasks (genesis and evolve), inspecting the agent tree hierarchy, and viewing task logs — all powered by Phoenix LiveView with server-push updates.

The dashboard supports **project-based navigation**: users open repository paths as project tabs, with tasks filtered per project. **Auto mode detection** inspects the project directory to suggest the appropriate task mode (genesis_new, genesis_existing, or evolve_simple) based on whether the directory exists, is empty, or contains a CONTEXT.md file.

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
| `EvoDash.TaskRegistry` | `./lib/evo_dash/task_registry.ex` | ETS-backed GenServer tracking genesis/evolve tasks; `repo_path` field for project filtering; `list_tasks_by_repo/1` for per-project queries |
| `EvoDash.PubSub` | (started in app) | Phoenix PubSub for real-time event distribution |

### Web Layer (`lib/evo_dash_web/`)
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb` | `./lib/evo_dash_web.ex` | `use`-based macros for controller, live_view, html, etc. |
| `EvoDashWeb.Endpoint` | `./lib/evo_dash_web/endpoint.ex` | Phoenix endpoint (LiveView socket, static files, Plug pipeline) |
| `EvoDashWeb.Router` | `./lib/evo_dash_web/router.ex` | Routes: `/` → DashboardLive, `/agents` → AgentsLive |
| `EvoDashWeb.Telemetry` | `./lib/evo_dash_web/telemetry.ex` | Telemetry metrics supervisor (Phoenix + VM metrics) |

### LiveView Pages (`./lib/evo_dash_web/live/`)
| Module | Route | Purpose |
|--------|-------|---------|
| `EvoDashWeb.DashboardLive` | `GET /` | Project-based dashboard: landing page → open project tabs → task form with auto mode detection + task cards |
| `EvoDashWeb.AgentsLive` | `GET /agents` | Recursive agent tree inspector with detail panels |

### UI Components (`./lib/evo_dash_web/components/`)
| Module | Purpose |
|--------|---------|
| `CoreComponents` | Phoenix 1.8 base components (header, flash, button, icon, input, table, theme_toggle) |
| `DashboardComponents` | `landing_page` (welcome + open project form), `project_tabs` (tab bar with switch/close), `task_form` (auto mode detection, hidden path when project active), `task_card` (status badges, expandable details, logs) |
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
                          │   ├─ Landing page (no project) → open_project event
                          │   ├─ Project tabs → switch_project / close_project events
                          │   ├─ Task form → auto mode detection → task_submit event
                          │   └─ Task cards → cancel / details / view result
                          └─ AgentsLive     ←→ (agent tree from EvoGit runtime)
```

- `TaskRegistry.start_task(:genesis, opts)` spawns a linked process calling `EvoGit.Runtime.Genesis.run/2`
- `TaskRegistry.start_task(:evolve, opts)` spawns a linked process calling `EvoGit.Runtime.Evolution.run/2`
- `TaskRegistry.list_tasks_by_repo(path)` filters tasks by expanded repo_path
- Task logs are piped back via `event_sink: {EvoDash.TaskRegistry, :update_task_log, [task_id]}`
- LiveViews poll TaskRegistry on timers (1s for dashboard, 500ms for agents)
- Auto mode detection: empty/non-existent dir → genesis_new, no CONTEXT.md → genesis_existing, has CONTEXT.md → evolve_simple
- Project state lives in LiveView assigns (not persisted across page reloads)

## Constraints

- **Umbrella dependency**: Must have `:evo_git` available at compile and runtime
- **Port**: Runs on port **4100** in development
- **Adapter**: Uses **Bandit** (not Cowboy) as the HTTP adapter
- **CSS framework**: Tailwind CSS 4 + DaisyUI (no Node.js toolchain; vendor files managed manually)
- **No database**: All task state is in-memory (ETS); lost on restart
- **Single-node**: DNSCluster configured but no distributed clustering logic yet
- **Naming conventions**:
  - Domain modules: `./lib/evo_dash/<module>.ex`
  - Web modules: `./lib/evo_dash_web/<module>.ex`
  - LiveViews: `<name>_live.ex` / `<name>_live.html.heex`
  - Components: `<domain>_components.ex`
- **Build**: `mix assets.build` (esbuild + tailwind), `mix assets.deploy` (minified + digested)
- **Precommit**: `mix precommit` runs compile --warning-as-errors, deps.unlock --unused, format, test
