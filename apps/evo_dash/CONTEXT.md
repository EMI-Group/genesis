# EvoDash — Phoenix LiveView Dashboard

## Intent

EvoDash is the web dashboard for the EvoGit umbrella project. It provides a project-based real-time browser interface for launching and monitoring EvoGit tasks (genesis and evolve), inspecting the agent tree hierarchy, viewing task logs, managing runtime scheduler settings, editing user configuration, and managing per-project settings including foreign repositories — powered by Phoenix LiveView.

Users open a Project (a Git repository path), and the dashboard auto-detects the appropriate task mode. Multiple projects can be open simultaneously with tab-based navigation.

This is a Phoenix 1.8 umbrella child app (`:evo_dash`) that depends on the sibling `:evo_git` application.

## Routing Table

- `./assets/` → Frontend source assets (JavaScript, CSS, vendor libraries)
- `./lib/` → Application source code (`evo_dash/` domain logic, `evo_dash_web/` web interface)
- `./test/` → ExUnit test suite

## API Surface

### Core Modules

- `EvoDash.Application` — OTP supervisor (Telemetry → DNSCluster → PubSub → TaskSupervisor → TaskRegistry → Endpoint)
- `EvoDash.TaskRegistry` — ETS+DETS-backed GenServer tracking tasks; spawns `EvoGit.Runtime.*` processes
- `EvoDashWeb.Endpoint` — Phoenix endpoint (LiveView socket, static files, Plug pipeline)
- `EvoDashWeb.Router` — Routes to LiveViews and Phoenix LiveDashboard
- `EvoDashWeb.Helpers` — Shared UI utilities (status badges, datetime formatting, icons, modals)

### Routes

| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `DashboardLive` | Project-based task dashboard with auto-mode detection, task form, project settings |
| `GET /agents` | `AgentsLive` | Recursive agent tree inspector with chat history viewer |
| `GET /settings` | `SettingsLive` | Runtime scheduler configuration panel |
| `GET /help` | `HelpLive` | User config file manager and credentials reference |
| `/dashboard` | Phoenix.LiveDashboard | Built-in metrics/telemetry dashboard |

### LiveView Pages (`./lib/evo_dash_web/live/`)

- `DashboardLive` — Main dashboard: project tabs, task form, task cards with logs, inline project settings (evogit.toml, foreign repos)
- `AgentsLive` — Agent tree visualization reading directly from ETS tables (`evogit_agent_state`, `evogit_sched_meta`)
- `SettingsLive` — Runtime scheduler settings (concurrency, retries, depth, model)
- `HelpLive` — Configuration management (config status, TOML editor, credentials reference)

### UI Components (`./lib/evo_dash_web/components/`)

- `CoreComponents` — Phoenix 1.8 base components
- `DashboardComponents` — Task form, scheduler settings, project tabs, task cards
- `AgentsComponents` — Recursive path tree with connector lines and status coloring
- `Layouts` — App layout with navbar, theme toggle, flash group

## Constraints

- Depends on `:evo_git` at compile and runtime
- Runs on port 4100 in development, uses Bandit adapter
- Tailwind CSS 4 + DaisyUI (no Node.js toolchain)
- No database — task state persisted via DETS; project state in LiveView socket assigns
- Single-node (DNSCluster configured but no distributed clustering)
- Naming conventions: domain modules in `./lib/evo_dash/`, web modules in `./lib/evo_dash_web/`
- Build: `mix assets.build` (esbuild + tailwind), `mix assets.deploy` (minified + digested)
