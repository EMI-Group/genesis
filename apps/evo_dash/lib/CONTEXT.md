# `apps/evo_dash/lib/` — Application Source Code

## Intent

Application source code for the EvoDash Phoenix LiveView dashboard. Split into two top-level namespaces:
- `evo_dash/` — Domain logic (OTP application, task registry)
- `evo_dash_web/` — Web interface (LiveView pages, components, templates, router, helpers)

## Routing Table

- `./evo_dash/` → Domain modules: `Application` (OTP supervisor), `TaskRegistry` (ETS+DETS GenServer)
- `./evo_dash_web/` → Web interface: LiveViews, components, router, endpoint, helpers
- `./evo_dash_web.ex` → Web module macro (`use EvoDashWeb, :live_view` / `:html` / `:controller` etc.)

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
| `CoreComponents` | Phoenix 1.8 base components (input, button, flash, table, list, icon) |
| `DashboardComponents` | Task form, scheduler settings, project tabs, task cards, open project form |
| `AgentsComponents` | Recursive agent path tree with connector lines and status coloring |
| `Layouts` | App layout with navbar, theme toggle, flash group |

### Cross-App Communication: EvoDash → EvoGit

All communication from EvoDash to EvoGit is **direct function calls** (synchronous GenServer calls and direct module calls). Both apps run in the same BEAM VM — no network boundary or serialization.

#### 1. Task Execution (TaskRegistry → EvoGit.Runtime)

`TaskRegistry.execute_task/3` spawns a supervised task that calls:
- `EvoGit.Runtime.Genesis.run(prompt, runtime_opts)` for genesis tasks
- `EvoGit.Runtime.Evolution.run(objective, runtime_opts)` for evolution tasks

Runtime opts passed: `[repo_path:, mode:, task_id:, node_path?:, seed_content?:]`
Task status updates are broadcast on `EvoGit.PubSub` topic `"tasks"` (e.g., `{:task_status, task_id, :finalizing}`). The TaskRegistry subscribes to this topic and handles status changes via `handle_info/2`.
`Application.ensure_all_started(:evo_git)` is called before execution to guarantee the core runtime is up.

#### 2. Scheduler Configuration (SettingsLive → EvoGit.AgentScheduler)

`SettingsLive` directly calls the AgentScheduler GenServer:
- `EvoGit.AgentScheduler.get_config()` — read current scheduler config (concurrency, retries, depth, model, paused)
- `EvoGit.AgentScheduler.update_config(keyword_list)` — push runtime config changes (max_concurrency, max_tool_concurrency, agent_max_retries, max_agent_depth, max_retries, llm_model)
- `EvoGit.AgentScheduler.pause()` / `EvoGit.AgentScheduler.resume()` — toggle scheduler pause state

When AgentScheduler processes these, it broadcasts `{:scheduler_config_updated}` on `EvoGit.PubSub` topic `"scheduler_config"`.

#### 3. Foreign Repository Management (DashboardLive — in-memory per-project)

Foreign repos are loaded from `evogit.toml` via `EvoGit.ProjectConfig.foreign_repos/1` when a project is opened. Add/remove operations modify the in-memory list in LiveView socket assigns. When a task is started, foreign repos are passed as `foreign_repos` in opts to `TaskRegistry.start_task/2`.

#### 4. Configuration File Management (HelpLive → EvoGit.Config)

- `EvoGit.Config.config_status()` — check if all critical config values are set
- `EvoGit.Config.config_dir()` / `config_path()` / `credentials_path()` — get file paths
- `EvoGit.Config.save_user_config(map)` — write parsed TOML config to disk
- `EvoGit.Config.resolve()` — resolve full config (used for task_history settings)

#### 5. PubSub Topics (EvoGit.PubSub — owned by evo_git)

| Topic | Events | Subscribers |
|-------|--------|-------------|
| `"tasks"` | `{:tasks_updated}` | TaskRegistry, DashboardLive |
| `"agents"` | `{:agents_updated}` | AgentsLive |
| `"scheduler_config"` | `{:scheduler_config_updated}` | SettingsLive |
| `"recent_projects"` | `{:recent_projects_updated}` | DashboardLive |

EvoDash has its own `EvoDash.PubSub` but it is not used for cross-app communication.

#### 6. Shared ETS Tables (owned by EvoGit.AgentScheduler)

AgentsLive reads directly from two public ETS tables:
- `:evogit_agent_state` — agent spatial/temporal state
- `:evogit_sched_meta` — scheduling metadata (status, worktree, depth, retries, spec)

No `Application.put_env` calls to `:evo_git` exist in EvoDash. All config changes go through `EvoGit.AgentScheduler.update_config/1`.

## Constraints

- Domain modules in `./evo_dash/`, web modules in `./evo_dash_web/`
- All LiveViews use `EvoDashWeb.Gettext` for i18n
- No database — state in ETS/DETS and socket assigns
- All EvoGit.PubSub subscriptions are conditional on `connected?(socket)` in LiveViews
- EvoGit.PubSub is owned by the evo_git application; EvoDash subscribes as a consumer
