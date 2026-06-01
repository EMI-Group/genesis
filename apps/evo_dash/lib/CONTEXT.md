# EvoDash — Application Source Code (lib/)

## Intent

Contains the business logic (`evo_dash/`) and web interface (`evo_dash_web/`) for the EvoDash Phoenix LiveView dashboard.

## Routing Table

- `./evo_dash/` → Domain modules: `Application` (OTP supervisor), `TaskRegistry` (ETS+DETS GenServer)
- `./evo_dash_web/` → Web interface: LiveView pages, components, router, endpoint, helpers
- `./evo_dash_web.ex` → Web module macro (`use EvoDashWeb, :live_view` / `:html` / `:controller` etc.)
- `./evo_dash.ex` → Domain module macro or placeholder

## API Surface

### Domain Modules (`./evo_dash/`)

| Module | Purpose |
|--------|---------|
| `EvoDash.Application` | OTP supervisor tree (Telemetry → DNSCluster → PubSub → TaskSupervisor → TaskRegistry → Endpoint) |
| `EvoDash.TaskRegistry` | ETS+DETS GenServer for task tracking; spawns `EvoGit.Runtime.*` processes |

### Web Modules (`./evo_dash_web/`)

| Module | Purpose |
|--------|---------|
| `EvoDashWeb.Endpoint` | Phoenix endpoint |
| `EvoDashWeb.Router` | Routes to LiveViews and LiveDashboard |
| `EvoDashWeb.Helpers` | Shared UI utilities (status badges, datetime, icons, modals) |
| `EvoDashWeb.Gettext` | i18n backend |

#### LiveViews (`./evo_dash_web/live/`)

| LiveView | Route | Purpose |
|----------|-------|---------|
| `DashboardLive` | `GET /` | Main dashboard: project tabs, task form, task cards, project settings |
| `AgentsLive` | `GET /agents` | Agent tree inspector with chat history |
| `SettingsLive` | `GET /settings` | Runtime scheduler config (concurrency, retries, depth, model, pause/resume) |
| `HelpLive` | `GET /help` | User config file manager, TOML editor, credentials reference |

#### Components (`./evo_dash_web/components/`)

| Component | Purpose |
|-----------|---------|
| `CoreComponents` | Phoenix 1.8 base components |
| `DashboardComponents` | Task form, scheduler settings, project tabs, task cards, open project form |
| `AgentsComponents` | Recursive agent path tree with connector lines |
| `Layouts` | App layout with navbar, theme toggle, flash group |

## Constraints

- Domain modules in `./evo_dash/`, web modules in `./evo_dash_web/`
- All LiveViews use `EvoDashWeb.Gettext` for i18n
- No database — state in ETS/DETS and socket assigns
