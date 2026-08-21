# Application Source Code

## Intent

Application source code for the EvoDash Phoenix LiveView dashboard. Split into two top-level namespaces:
- `evo_dash/` — Domain logic (OTP application, `NodeContext` remote-development thin client)
- `evo_dash_web/` — Web interface (LiveView pages, components, templates, router, helpers)

The domain-layer persistence/registry modules (`Store`, `Store.Codec`, `TaskInfo`, `RecentProject`, `TaskRegistry` and the `task_registry/` helper submodules) live in the `:evo_git` app as `EvoGit.Store`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`, `EvoGit.TaskRegistry` (and friends). EvoDash owns only the web layer plus the `NodeContext` thin client and the OTP `Application` supervisor (which starts no Store/Registry/TaskRegistry — those are children of `EvoGit.Application`).

## Routing Table

- `./evo_dash/` → Domain modules: `Application` (OTP supervisor — Telemetry, PubSub, TaskSupervisor, Endpoint) and `NodeContext` (SSH remote-development thin client)
- `./evo_dash_web/` → Web interface: LiveViews, components, router, endpoint, helpers
- `./evo_dash_web.ex` → Web module macro (`use EvoDashWeb, :live_view` / `:html` / `:controller` etc.)

## API Surface

### Domain Modules (`./evo_dash/`)

| Module | Purpose |
|--------|---------|
| `EvoDash.Application` | OTP supervisor tree (Telemetry → PubSub → TaskSupervisor → Endpoint). Store/Registry/TaskRegistry live in `EvoGit.Application`. |
| `EvoDash.NodeContext` | Thin client for SSH remote development — wraps `EvoGit.RemoteConnections` (target persistence), `EvoGit.RemoteConnection` (connection lifecycle GenServer, graceful degradation), and `EvoGit.RemoteNode` (cross-node RPC helpers — agents, config, paused?, task history, cancellation). Public API is stable so web files need no changes. **Task cancellation model**: `cancel_task/2` = GRACEFUL (`:pending` → immediate `:cancelled`; `:running` → `:cancelling`, agents informed to save + exit, then `:cancelled` with result/archive preserved); `force_kill_task/2` = BRUTAL force kill (kills all agents + wrapper → `:failed`, result nil'd; escalation from `:cancelling`). Both delegate to `EvoGit.RemoteNode`. |

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
| `HomeLive` | `GET /` | Home chat page — ChatGPT-style chat wired to the self-reflective agent (`:reflect` tasks); see `apps/evo_dash/CONTEXT.md` → "Home Chat Page" |
| `ProjectsLive` | `GET /projects` | Projects page: project tabs, task form, task cards, project settings |
| `AgentsLive` | `GET /agents` | Agent tree inspector with chat history |
| `SettingsLive` | `GET /settings` | Runtime scheduler config (concurrency, retries, depth, model) |
| `SystemLive` | `GET /system` | System controls (scheduler pause/resume, restart/stop VM), system self-check, usage guides and references |

#### Components (`./evo_dash_web/components/`)

| Component | Purpose |
|-----------|---------|
| `CoreComponents` | Phoenix 1.8 base components (input, button, flash, table, list, icon) |
| `ProjectComponents` / `TaskFormComponents` / `TaskCardComponents` | Command-palette project selector, task form, task cards, project settings |
| `AgentsComponents` | Recursive agent path tree with connector lines and status coloring |
| `Layouts` | App layout with navbar, theme toggle, flash group |

### Cross-App Communication: EvoDash → EvoGit

All communication from EvoDash to EvoGit is **direct function calls** (synchronous GenServer calls and direct module calls). Both apps run in the same BEAM VM — no network boundary or serialization.

#### 1. Task Execution (TaskRegistry → EvoGit.Runtime)

`EvoGit.TaskRegistry.execute_task/3` spawns a supervised task that calls:
- `EvoGit.Runtime.Genesis.run(prompt, runtime_opts)` for genesis tasks
- `EvoGit.Runtime.Evolution.run(objective, runtime_opts)` for evolution tasks

Runtime opts passed: `[repo_path:, mode:, task_id:, node_path?:]`

Task status updates are broadcast on `EvoGit.PubSub` topic `"tasks"` as node-identity events (`{:task_updated, task_id, status, node}` / `{:task_deleted, task_id, node}` — see the PubSub Topics table below). The TaskRegistry subscribes to this topic and handles status changes via `handle_info/2`.

`Application.ensure_all_started(:evo_git)` is called before execution to guarantee the core runtime is up.

#### 2. Scheduler Configuration (SystemLive / SettingsLive → EvoGit.AgentScheduler)

`SystemLive` and `SettingsLive` directly call the AgentScheduler GenServer:
- `EvoGit.AgentScheduler.get_config()` — read current scheduler config (concurrency, retries, depth, model, paused)
- `EvoGit.AgentScheduler.update_config(keyword_list)` — push runtime config changes (default_llm_max_concurrency, max_tool_concurrency, agent_max_retries, max_agent_depth, max_retries, llm_model)
- `EvoGit.AgentScheduler.pause()` / `EvoGit.AgentScheduler.resume()` — toggle scheduler pause state (SystemLive)

When AgentScheduler processes these, it broadcasts `{:scheduler_config_updated, node}` (publishing node atom) on `EvoGit.PubSub` topic `"scheduler_config"`.

#### 3. Foreign Repository Management (ProjectsLive — in-memory per-project)

Foreign repos are loaded from `genesis.toml` via `EvoGit.ProjectConfig.foreign_repos/1` when a project is opened. Add/remove operations modify the in-memory list in LiveView socket assigns. When a task is started, foreign repos are passed as `foreign_repos` in opts to `TaskRegistry.start_task/2`.

#### 4. Configuration File Management (SettingsLive → EvoGit.Config)

- `EvoGit.Config.config_status()` — check if all critical config values are set
- `EvoGit.Config.config_dir()` / `config_path()` / `credentials_path()` — get file paths
- `EvoGit.Config.save_user_config(map)` — write parsed TOML config to disk
- `EvoGit.Config.resolve()` — resolve full config (used for task_history settings)

#### 5. PubSub Topics (EvoGit.PubSub — owned by evo_git)

All dashboard-relevant events carry the **BEAM node atom of the publishing node**; consumers only apply an event when its `node` matches the currently-viewed node (local viewing → `node()`, remote viewing → the remote daemon's BEAM name; filter via `EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?/2`). Full contract: `apps/evo_dash/CONTEXT.md` → "Push-based event contract".

| Topic | Events | Subscribers |
|-------|--------|-------------|
| `"tasks"` | `{:task_updated, task_id, status, node}` (status `:pending\|:running\|:finalizing\|:cancelling\|:completed\|:failed\|:cancelled`, or `nil` for review-only mutations), `{:task_deleted, task_id, node}` | TaskRegistry, NodeAware (node-filtered debounced reload), TasksLive, ProjectsLive, ReviewLive, AgentsLive, SettingsLive, SystemLive |
| `"agents"` | `{:agent_registered, id, summary, node}`, `{:agent_updated, id, changed_fields, node}` (changed_fields NEVER contains `:context`; it DOES contain `:message_count` when the agent's context changed), `{:agent_removed, id, node}`, `{:agents_updated, node}` | AgentsLive |
| `"scheduler_config"` | `{:scheduler_config_updated, node}` | SettingsLive, SystemLive |
| `"system"` | `{:system_sample, node, seq, sample}` (3s node-side sampler; sample keys `llm_used, llm_waiting, tool_used, tool_waiting, llm_capacity, tool_capacity, agents_total, agents_running, agents_blocked, agents_waiting, agents_pending, scheduler_alive`) | SystemLive (chart; seed via `EvoDash.NodeContext.get_recent_system_samples/1`) |
| `"recent_projects"` | `{:recent_projects_updated}` | ProjectsLive |

EvoDash has its own `EvoDash.PubSub` but it is not used for cross-app communication.

#### 6. Shared ETS Tables (owned by EvoGit.AgentScheduler)

AgentsLive reads directly from two public ETS tables:
- `:evogit_agent_state` — agent spatial/temporal state
- `:evogit_sched_meta` — scheduling metadata (status, worktree, depth, retries, spec)

No `Application.put_env` calls to `:evo_git` exist in EvoDash. All config changes go through `EvoGit.AgentScheduler.update_config/1`.

## SQL-Lowering Analysis (dashboard → Store data consumption)

READ-ONLY analysis of where dashboard-side Elixir work could be lowered into SQLite. The SQL boundary lives in `:evo_git` (`EvoGit.Store.Queries.build_where/1` — status, project_path, review_status incl. composite `"pending"` = completed + null review + `branch_name IS NOT NULL`, and search over id/opts-JSON/project_path; `safe_select_paginated_tasks/2` — WHERE + `ORDER BY started_at DESC` + LIMIT/OFFSET + `COUNT(*)` with same WHERE). **TasksLive is fully SQL-lowered** (filters + pagination + count all in SQL, `tasks_live.ex:572-595` → `RemoteNode` → `RemoteAPI` → `TaskRegistry` → `Store`).

- **Sidebar "Active Tasks" is SQL-filtered + debounced + deduped + UNIFIED**: a SINGLE implementation in `EvoDashWeb.LiveHooks.NodeAware` (`fetch_active_tasks/1` node-aware fetch with pending-remote guard → `partition_active_tasks/1` pure → `assign_active_tasks/1` assign; `load_running_and_pending_tasks/1` delegating entry) fetches ONLY `@active_statuses = [:running, :pending, :finalizing, :completed]` via `TaskRegistry.list_tasks_summary(statuses)` (local) / `NodeContext.list_tasks_summary(node, statuses)` (remote RPC) — the SQL statuses-IN WHERE clause skips finished tasks that can never appear in the sidebar. Broadcast bursts are coalesced by a 300ms trailing debounce (`:node_aware_reload_tasks` + `:tasks_reload_pending` flag) — one reload per burst per LiveView, not one per broadcast. `assign_node/2` skips the reload when the node context is unchanged (`:tasks_node_loaded` guard). **Dead-render skip**: `on_mount/4` fires the sidebar load ONLY on the connected mount (dead HTTP render keeps empty-list assigns, no query). `list_tasks_summary` decodes on short-lived Task heaps (task_registry.ex:416-427, Task-delegated); `show_review_button?/1` is column-based (`branch_name`) and the summary projection drops `result`.
- **No unfiltered dashboard task-list fetch remains**: the dashboard has no main task list — `Assigns` keeps only `build_notified_task_ids/1` + `assign_form_defaults/1` (no `current_tasks/1`, no `assign_running_and_pending_tasks/1`/`2`, no `lightweight_task/1`/`strip_heavy_fields/1`). The `notified_task_ids` notification path is a **minimal id-only projection**: `Assigns.build_notified_task_ids/1` uses `TaskRegistry.list_task_ids([:completed, :failed, :cancelled])` (id+status+updated_at only — no result/opts JSON decode). Dashboard cards need ONLY summary-contract fields (`components/CONTEXT.md` audit table) — no lazy `get_task(id)` detail load is needed for rendering; `get_task/1` is used ONLY per newly-terminal id for browser notifications; archive UI remains Tasks/Review-page-only.
- **Summary map contract** (statuses API): `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at` (opts = decoded keyword list; `updated_at` = raw fixed-precision ISO string). Heavy fields (`result`, `logs`, `usage`, `archive_metadata`) are excluded.
- **TasksLive is fully push-based (no polls)**: node-filtered `{:task_updated, task_id, status, node}` / `{:task_deleted, task_id, node}` broadcasts → `NodeAware.handle_task_info/2` 300ms trailing-edge debounce → `:node_aware_reload_tasks` full page reload — the SAME code path serves local and remote nodes (no `:remote_poll`, no DirtyTracker, no changed-since transfers). The page renders FULL TaskInfo (expandable cards need archive_metadata/logs/usage — never degraded to summaries). The sidebar has NO poll (broadcast/debounce-driven); AgentsLive is likewise push-based (`"agents"`-topic events, node-filtered).
- **Remaining candidates**: (6) raw archive JSON export for `TaskExportController` (decoded then re-encoded; a raw-column read would serve the stored JSON directly). `get_unique_paths` re-fetch and recent-projects sort are negligible.

## Memory Profile (sustained BEAM memory vs tasks.sqlite size)

Where per-task data is RETAINED in LiveView process heaps (the driver of sustained memory that scales with row count × result-blob size):

- **ProjectsLive retains no unfiltered task list** — the only task data ProjectsLive retains is `:running_tasks`/`:pending_tasks` (statuses-filtered summaries) and the `notified_task_ids` MapSet (ids only).
- **`:running_tasks` / `:pending_tasks`** in EVERY LiveView (NodeAware `on_mount` via `evo_dash_web.ex:49-53`, `node_aware.ex`): statuses-filtered subsets of the SAME summary maps (shared references, not copies; filtered from the same list — no per-assign duplication). Rendered in the sidebar (`layouts.ex:139-146`). Note `pending_tasks` retains full summary maps for every completed-unreviewed task with a branch (derived via the column-based `NodeAware.show_review_button?/1` matching the denormalized `branch_name` column — NO `result` read from summaries).
- **TasksLive `:tasks`/`:filtered_tasks`** = one PAGE (25, `@default_page_size`) of FULL `%TaskInfo{}` structs (logs/usage/archive_metadata) via `list_tasks_paginated` — scales with page_size × blob, not row count.
- **Lifecycle**: phoenix_live_view has NO `live_disconnect_timeout` option (grep deps + config = no matches). The channel stops the LiveView process with `{:stop, {:shutdown, :closed}}` on socket close (`deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:96-103`) — so retention lasts exactly as long as tabs are OPEN (indefinite per tab; N tabs = N copies). No GenServers/ETS/persistent_term caches in evo_dash (greps confirm); `agents_live.ex:624-631` only READS evo_git ETS (agent data, scales with live agents, not DB size).
- **Inline decode on the registry heap**: `list_tasks_summary*` decodes ALL rows inside the TaskRegistry GenServer (inline handler, task_registry.ex) — each call transiently materializes the full decoded list on the evo_git GenServer heap, then hands the maps to the LiveView which retains them. Both heaps scale with DB size.
- **No unfiltered summary fetch runs anywhere in dashboard code**: `notified_task_ids` is served by `Assigns.build_notified_task_ids/1` — the minimal id-only query `TaskRegistry.list_task_ids([:completed, :failed, :cancelled])` (no result/opts decode), unioned cheaply (MapSet union) on mount (`projects_live.ex:450`), `handle_params` fallbacks (`531,551,560`), `activate_project` (`1421`), and `clear_task_history` (unions terminal ids BEFORE clearing, `944-950`). The `:node_aware_reload_tasks` handler (`projects_live.ex:1191-1238`) fetches `list_task_ids([:completed, :failed, :cancelled])`, reduce-diffs against the `notified_task_ids` MapSet, and fetches FULL rows only for newly-terminal ids (`TaskRegistry.get_task(id)` → `Project.task_notification_content(task)` → `push_event "task_notification"`) — decode cost is bounded to newly-terminal rows only; then it re-runs the unified `NodeAware.assign_active_tasks/1` (sidebar) + project-settings refresh + `NodeAware.clear_task_reload_pending/1`. `cancel_task`/`delete_task` `MapSet.put` the affected id into the notified set (`928-929`, `961-962`); `start_task` refreshes the sidebar only. The ONLY summary calls left in dashboard code are the sidebar's statuses-filtered ones.
- **Result-blob display audit**: per-row `result` decode is excluded from summary queries (`EvoGit.Store` `@summary_columns`/`decode_summary_row`) — the summary projection never touches the result blob. The sidebar uses only the `branch_name` summary column (`show_review_button?`, node_aware.ex:165-169 — pattern match, value not rendered); browser notifications use `result` (pr_title/error/exit) only for terminal tasks via `get_task/1`; the "full result" modal (`render_result_full`) is rendered only by TasksLive. TasksLive/ReviewLive consume full structs via `list_tasks_paginated`/`get_task`, where `Codec.decode_result` (rebuilds embedded `%Usage{}` + archive_records — the largest blob in the DB) runs per row.

## Constraints

- Domain modules in `./evo_dash/`, web modules in `./evo_dash_web/`
- All LiveViews use `EvoDashWeb.Gettext` for i18n
- Task state and recent projects are persisted via SQLite in the `:evo_git` app (`EvoGit.Store`); no persistence modules remain under `./evo_dash/`; project state also held in socket assigns
- All EvoGit.PubSub subscriptions are conditional on `connected?(socket)` in LiveViews
- EvoGit.PubSub is owned by the evo_git application; EvoDash subscribes as a consumer
