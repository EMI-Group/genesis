# Application Source Code

## Intent

Application source code for the EvoDash Phoenix LiveView dashboard. Split into two top-level namespaces:
- `evo_dash/` — Domain logic (OTP application, `NodeContext` remote-development thin client)
- `evo_dash_web/` — Web interface (LiveView pages, components, templates, router, helpers)

NOTE: The domain-layer persistence/registry modules (`Store`, `Store.Codec`, `TaskInfo`, `RecentProject`, `TaskRegistry` and the `task_registry/` helper submodules) have been **migrated to the `:evo_git` app** and now live there as `EvoGit.Store`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`, `EvoGit.TaskRegistry` (and friends). They are no longer present under `./evo_dash/`. EvoDash now only owns the web layer plus the `NodeContext` thin client and the OTP `Application` supervisor (which no longer starts Store/Registry/TaskRegistry — those are children of `EvoGit.Application`).

## Routing Table

- `./evo_dash/` → Domain modules: `Application` (OTP supervisor — Telemetry, PubSub, TaskSupervisor, Endpoint) and `NodeContext` (SSH remote-development thin client)
- `./evo_dash_web/` → Web interface: LiveViews, components, router, endpoint, helpers
- `./evo_dash_web.ex` → Web module macro (`use EvoDashWeb, :live_view` / `:html` / `:controller` etc.)

## API Surface

### Domain Modules (`./evo_dash/`)

| Module | Purpose |
|--------|---------|
| `EvoDash.Application` | OTP supervisor tree (Telemetry → PubSub → TaskSupervisor → Endpoint). Store/Registry/TaskRegistry now live in `EvoGit.Application`. |
| `EvoDash.NodeContext` | Thin client for SSH remote development — wraps `EvoGit.RemoteConnections` (target persistence), `EvoGit.RemoteConnection` (connection lifecycle GenServer, graceful degradation), and `EvoGit.RemoteNode` (cross-node RPC helpers — agents, config, paused?). Public API is stable so web files need no changes. |

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
| `SettingsLive` | `GET /settings` | Runtime scheduler config (concurrency, retries, depth, model) |
| `SystemLive` | `GET /system` | System controls (scheduler pause/resume, restart/stop VM), system self-check, usage guides and references |

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

`EvoGit.TaskRegistry.execute_task/3` spawns a supervised task that calls:
- `EvoGit.Runtime.Genesis.run(prompt, runtime_opts)` for genesis tasks
- `EvoGit.Runtime.Evolution.run(objective, runtime_opts)` for evolution tasks

Runtime opts passed: `[repo_path:, mode:, task_id:, node_path?:]`

Task status updates are broadcast on `EvoGit.PubSub` topic `"tasks"` (e.g., `{:task_status, task_id, :finalizing}`). The TaskRegistry subscribes to this topic and handles status changes via `handle_info/2`.

`Application.ensure_all_started(:evo_git)` is called before execution to guarantee the core runtime is up.

#### 2. Scheduler Configuration (SystemLive / SettingsLive → EvoGit.AgentScheduler)

`SystemLive` and `SettingsLive` directly call the AgentScheduler GenServer:
- `EvoGit.AgentScheduler.get_config()` — read current scheduler config (concurrency, retries, depth, model, paused)
- `EvoGit.AgentScheduler.update_config(keyword_list)` — push runtime config changes (max_concurrency, max_tool_concurrency, agent_max_retries, max_agent_depth, max_retries, llm_model)
- `EvoGit.AgentScheduler.pause()` / `EvoGit.AgentScheduler.resume()` — toggle scheduler pause state (SystemLive)

When AgentScheduler processes these, it broadcasts `{:scheduler_config_updated}` on `EvoGit.PubSub` topic `"scheduler_config"`.

#### 3. Foreign Repository Management (DashboardLive — in-memory per-project)

Foreign repos are loaded from `genesis.toml` via `EvoGit.ProjectConfig.foreign_repos/1` when a project is opened. Add/remove operations modify the in-memory list in LiveView socket assigns. When a task is started, foreign repos are passed as `foreign_repos` in opts to `TaskRegistry.start_task/2`.

#### 4. Configuration File Management (SettingsLive → EvoGit.Config)

- `EvoGit.Config.config_status()` — check if all critical config values are set
- `EvoGit.Config.config_dir()` / `config_path()` / `credentials_path()` — get file paths
- `EvoGit.Config.save_user_config(map)` — write parsed TOML config to disk
- `EvoGit.Config.resolve()` — resolve full config (used for task_history settings)

#### 5. PubSub Topics (EvoGit.PubSub — owned by evo_git)

| Topic | Events | Subscribers |
|-------|--------|-------------|
| `"tasks"` | `{:tasks_updated}` | TaskRegistry, DashboardLive |
| `"agents"` | `{:agents_updated}` | AgentsLive |
| `"scheduler_config"` | `{:scheduler_config_updated}` | SettingsLive, SystemLive |
| `"recent_projects"` | `{:recent_projects_updated}` | DashboardLive |

EvoDash has its own `EvoDash.PubSub` but it is not used for cross-app communication.

#### 6. Shared ETS Tables (owned by EvoGit.AgentScheduler)

AgentsLive reads directly from two public ETS tables:
- `:evogit_agent_state` — agent spatial/temporal state
- `:evogit_sched_meta` — scheduling metadata (status, worktree, depth, retries, spec)

No `Application.put_env` calls to `:evo_git` exist in EvoDash. All config changes go through `EvoGit.AgentScheduler.update_config/1`.

## SQL-Lowering Analysis (dashboard → Store data consumption)

READ-ONLY analysis of where dashboard-side Elixir work could be lowered into SQLite. The SQL boundary already lives in `:evo_git` (`EvoGit.Store.Queries.build_where/1` — status, project_path, review_status incl. composite `"pending"` = completed + null review + `branch_name IS NOT NULL`, and search over id/opts-JSON/project_path; `safe_select_paginated_tasks/2` — WHERE + `ORDER BY started_at DESC` + LIMIT/OFFSET + `COUNT(*)` with same WHERE). **TasksLive is already fully SQL-lowered** (filters + pagination + count all in SQL, `tasks_live.ex:572-595` → `RemoteNode` → `RemoteAPI` → `TaskRegistry` → `Store`). Remaining Elixir-side hotspots (all in the dashboard layer, data paths through `EvoGit.TaskRegistry`):

- **Sidebar "Active Tasks" full-scan (biggest, runs on EVERY navigation + EVERY task broadcast + EVERY LiveView mount)**: `NodeAware.load_running_and_pending_tasks/1` (`live_hooks/node_aware.ex:59-83`) calls `TaskRegistry.list_tasks_summary()` (or RPC for remote) → `Store.select_tasks_summary` (`store.ex:607-624`) which has **NO WHERE clause** — scans ALL task rows and JSON-decodes `result` (reconstructs `%Usage{}` etc.) + `opts` per row — then filters in Elixir (`status in [:running,:pending,:finalizing]`; completed + nil review_status + result branch, sorted by finished_at desc). Runs: (a) on every `on_mount` (`node_aware.ex:42`) AND again in `handle_params` via `assign_node/2` (`node_aware.ex:139`) — double fetch on mount; (b) on every `{:tasks_updated}` / `{:task_status,...}` broadcast in EVERY open LiveView with a handler (TasksLive, DashboardLive, ReviewLive, AgentsLive — all subscribe via the on_mount hook). **Remote nodes transfer the entire decoded summary list over `:erpc` per occurrence.** Note `list_tasks_summary` decodes INLINE on the TaskRegistry GenServer heap (unlike `list_tasks_paginated` which delegates to a short-lived Task, `task_registry.ex:287`) — large-term heap pressure.
- **DashboardLive full-column decodes then discards**: `TaskRegistry.list_tasks()` (ALL columns incl. logs ≤500 entries, usage, archive_metadata) called at `dashboard_live.ex:479` (notified_task_ids — only id+status needed), `:560/:583/:595` (invalid/missing project fallback), and via `Assigns.current_tasks/1` (`assigns.ex:114-123`) at `:930/:969/:1035/:1022/:1254/:1298`; `list_tasks_by_path` (`:1484` activate_project, and current_tasks) = SQL project_path filter + LIMIT 5000 but still FULL column decode. All of it is then stripped in Elixir (`lightweight_task/1` `dashboard_live.ex:1377-1379` strips result too — latent bug: dashboard cards lose Review buttons; `Assigns.strip_heavy_fields/1` `assigns.ex:129-131` keeps result — two inconsistent strip helpers). `select_tasks_summary(_by_path)` already exists and includes everything the cards render (id, type, status, review_status, opts, result, started_at, finished_at, agent_count, project_path).
- **`Assigns.assign_running_and_pending_tasks/2` IGNORES its argument** (`assigns.ex:54-71` re-calls `list_tasks_summary()` even when the caller passes a fresh `all_tasks`) — a redundant summary scan in every DashboardLive handler that already holds the list.
- **TaskExportController re-encode round-trip**: `get_task/1` full decode → `normalize_for_json/1` recursive struct→map (`task_export_controller.ex:48-73`) → `Jason.encode!`. `archive_metadata` JSON column is decoded then re-encoded; a raw-column read (`SELECT archive_metadata FROM tasks WHERE id = ?`) would serve the stored JSON directly.
- **Remote 3s polls**: TasksLive `:remote_poll` (`tasks_live.ex:351-362`) re-fetches page (25 full TaskInfo structs) + COUNT over `:erpc` every 3s; AgentsLive `:remote_poll` (`agents_live.ex:175-214`) re-transfers all agent summaries every 3s. No dirty-check (no `updated_at` column exists on `tasks`).
- **`get_unique_paths` re-fetch on every page load/filter change** (`tasks_live.ex:629`) — cheap DISTINCT query, but redundant across interactions.
- **Recent projects** (`list_recent_projects` → `select_all_projects` + Elixir `sort_projects_by_recency`) — ≤10 rows after trim, negligible (could be `ORDER BY last_opened_at DESC` in SQL).

Ranked SQL-lowering candidates (blockers in parens): (1) filter the sidebar summary in SQL (status-IN + pending-review composite) + coalesce/debounce per-LiveView sidebar reloads on broadcasts (needs `select_tasks_summary` to accept `filters:` and `build_where` an OR-group, plus dashboard-local debounce — no API-shape blocker beyond plumbing through NodeContext/RemoteNode/RemoteAPI); (2) skip the duplicate sidebar reload in `assign_node/2` when node context is unchanged (mount + pagination push_patch re-runs); (3) DashboardLive list paths → `list_tasks_summary_by_path` + lazy `get_task` on card expand (summary already has result; expanded details are the only consumers of logs/usage/archive_metadata); (4) replace mount's `list_tasks()` with the summary query (or SQL `SELECT id FROM tasks WHERE status IN ('completed','failed','cancelled')`); (5) remote-poll dirty-check (needs `updated_at` column via `migrate_schema`); (6) raw archive JSON export; (7) make `assign_running_and_pending_tasks/2` use its argument.

## Constraints

- Domain modules in `./evo_dash/`, web modules in `./evo_dash_web/`
- All LiveViews use `EvoDashWeb.Gettext` for i18n
- Task state and recent projects are persisted via SQLite in the `:evo_git` app (`EvoGit.Store`); no persistence modules remain under `./evo_dash/`; project state also held in socket assigns
- All EvoGit.PubSub subscriptions are conditional on `connected?(socket)` in LiveViews
- EvoGit.PubSub is owned by the evo_git application; EvoDash subscribes as a consumer
