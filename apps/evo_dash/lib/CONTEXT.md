# Application Source Code

## Intent

Application source code for the EvoDash Phoenix LiveView dashboard. Split into two top-level namespaces:
- `evo_dash/` — Domain logic (OTP application, `NodeContext` remote-development thin client, `DirectoryPicker`, `UpdateStatus`, `DesktopLifetime`, small helpers)
- `evo_dash_web/` — Web interface (LiveView pages, components, templates, router, helpers)

The domain-layer persistence/registry modules (`Store`, `Store.Codec`, `TaskInfo`, `RecentProject`, `TaskRegistry` and the `task_registry/` helper submodules) live in the `:evo_git` app as `EvoGit.Store`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`, `EvoGit.TaskRegistry` (and friends). EvoDash owns only the web layer plus the `NodeContext` thin client and the OTP `Application` supervisor (which starts no Store/Registry/TaskRegistry — those are children of `EvoGit.Application`).

## Routing Table

- `./evo_dash/` → Domain modules: `Application` (OTP supervisor), `NodeContext` (SSH remote-development thin client), `DirectoryPicker` (+ `Wx` seam), `UpdateStatus` (auto-update hub), `DesktopLifetime` (desktop shell watcher), `ChatHistory` (in-memory ETS-backed chat store), `AttachedFile`, `MarkdownRender`, `SettingsUtils`
- `./evo_dash_web/` → Web interface: LiveViews, components, router, endpoint, helpers
- `./evo_dash_web.ex` → Web module macro (`use EvoDashWeb, :live_view` / `:html` / `:controller` etc.)

## API Surface

### Domain Modules (`./evo_dash/`)

| Module | Purpose |
|--------|---------|
| `EvoDash.Application` | OTP supervisor tree (Telemetry → PubSub → TaskSupervisor → ChatHistory → DirectoryPicker → UpdateStatus → Endpoint; `DesktopLifetime` appended when `EVOGIT_DESKTOP=1` + `EVOGIT_LIFETIME_PORT`). Store/Registry/TaskRegistry live in `EvoGit.Application`. |
| `EvoDash.NodeContext` | Thin client for SSH remote development — wraps `EvoGit.RemoteConnections` (target persistence), `EvoGit.RemoteConnection` (connection lifecycle GenServer, graceful degradation), and `EvoGit.RemoteNode` (cross-node RPC helpers — agents, config, paused?, task history, cancellation). Public API is stable so web files need no changes. **Task cancellation model**: `cancel_task/2` = GRACEFUL (`:pending` → immediate `:cancelled`; `:running` → `:cancelling`, agents informed to save + exit, then `:cancelled` with result/archive preserved); `force_kill_task/2` = BRUTAL force kill (kills all agents + wrapper → `:failed`, result nil'd; escalation from `:cancelling`). Both delegate to `EvoGit.RemoteNode`. |
| `EvoDash.DirectoryPicker` | GenServer serializing native directory/file-dialog usage (Browse buttons + objective attach-file). Native-first (osascript/zenity/PowerShell), wx fallback (`EvoDash.DirectoryPicker.Wx`). Never raises. |
| `EvoDash.UpdateStatus` | Auto-update state hub for the Tauri updater UI; broadcasts transitions on `EvoGit.PubSub` `"updates"` topic. |
| `EvoDash.DesktopLifetime` | Desktop Tauri-shell lifetime watcher (TCP pipe) — stops the VM when the shell dies. Desktop-only. |
| `EvoDash.ChatHistory` | In-memory chat-history store for the Home chat page (issue: transcripts survive LiveView remounts, NOT BEAM restarts — no disk persistence). GenServer owning a named public ETS table; shape-agnostic per-chat state (`put_state/2`/`get_state/1`, opaque `term()` — `HomeLive.ChatState` owns the shape); chat lifecycle: `new_chat/0`, `current_chat_id/0`, `set_current_chat/1`, `list_chats/0` (newest-first), `delete_chat/1`, `prune/1` (caller-driven cap), `reset/0` (test helper). |
| `EvoDash.AttachedFile` / `EvoDash.MarkdownRender` / `EvoDash.SettingsUtils` | Pure helpers — attached-file reading (.txt/.md/.docx/.pdf), MDEx safe HTML rendering, config-form value utilities. |

Full per-module detail: `./evo_dash/CONTEXT.md`.

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
| `ProjectsLive` | `GET /`, `GET /projects` (same LiveView + action, direct route, no redirect); `GET /dashboard` (`:system_dashboard` action) | Projects page — project tabs, task form, task cards, project settings |
| `HomeLive` | `GET /help` | Home chat page — ChatGPT-style chat wired to the self-reflective agent (`:reflect` tasks); see `apps/evo_dash/CONTEXT.md` → "Home Chat Page" |
| `TasksLive` | `GET /tasks` | Task history page — status filters, pagination, archive, cancel/force-kill, review links |
| `ReviewLive` | `GET /review/:task_id` (+ `:commit` action) | Code review page — diff viewer, merge/reject/resume, GitHub PR creation |
| `AgentsLive` | `GET /agents` | Agent tree inspector with chat history |
| `SettingsLive` | `GET /settings` | Config GUI editor (categories), model-profiles editor, custom agents + model-selection script editor |
| `SystemLive` | `GET /system` | System controls (scheduler pause/resume, restart/stop VM), self-check, update card, usage guides |
| `WelcomeLive` | `GET /welcome` | First-run onboarding — stepwise LLM quick setup |
| `WelcomeCompleteLive` | `GET /welcome/complete` | Post-setup page — example objective + "Go to Dashboard" |

#### Components (`./evo_dash_web/components/`)

| Component | Purpose |
|-----------|---------|
| `CoreComponents` | Phoenix 1.8 base components (input, button, flash, table, list, icon) |
| `Layouts` | App layout with navbar, theme toggle, flash group |
| `ProjectComponents` / `TaskFormComponents` / `TaskCardComponents` | Command-palette project selector, task form, task cards, project settings |
| `AgentsComponents` | Recursive agent path tree with connector lines and status coloring |
| `SettingsComponents` | Settings page sections (model profiles, custom agents, model-selection script editors) |
| `ReviewComponents` | Review page actions (merge/reject/resume, async merge-check block) |
| `GitHubComponents` | GitHub issues modal |
| `ArchiveComponents` | Task archive tree display |
| `RemoteGateComponents` | Remote-connection gate (full-page connecting/error gate) |

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
| `"system"` | `{:system_sample, node, seq, sample}` (3s node-side sampler; sample keys `llm_used, llm_waiting, tool_used, tool_waiting, llm_capacity, tool_capacity, agents_total, agents_running, agents_blocked, agents_waiting, agents_pending, scheduler_alive` — legacy aggregates — plus **`llm_slots`**: per-model map `%{model_id => %{used:, waiting:, capacity:}}`, REAL per-model slot counts, key set covers every configured model profile incl. peak-paused 0-capacity ones, `%{}` when the scheduler is dead; the LLM Slots chart plots ONE selected model from it, tool/agents charts still use the aggregate keys) | SystemLive (chart; seed via `EvoDash.NodeContext.get_recent_system_samples/1`) |
| `"recent_projects"` | `{:recent_projects_updated}` | ProjectsLive |
| `"updates"` | auto-update state transitions | SystemLive update card (via `EvoDash.UpdateStatus`) |

EvoDash has its own `EvoDash.PubSub` but it is not used for cross-app communication.

#### 6. Shared ETS Tables (owned by EvoGit.AgentScheduler)

AgentsLive reads directly from two public ETS tables:
- `:evogit_agent_state` — agent spatial/temporal state
- `:evogit_sched_meta` — scheduling metadata (status, worktree, depth, retries, spec)

No `Application.put_env` calls to `:evo_git` exist in EvoDash. All config changes go through `EvoGit.AgentScheduler.update_config/1`.

## Dashboard → Store Data Flow & Memory Profile

The SQL boundary lives in `:evo_git` (`EvoGit.Store.Queries.build_where/1` — status, project_path, review_status incl. composite `"pending"` = completed + null review + `branch_name IS NOT NULL`, and search over id/opts-JSON/project_path; `safe_select_paginated_tasks/2` — WHERE + `ORDER BY started_at DESC` + LIMIT/OFFSET + `COUNT(*)` with the same WHERE).

- **TasksLive is fully SQL-lowered**: filters + pagination + count all in SQL (`tasks_live.ex:572-595` → `RemoteNode` → `RemoteAPI` → `TaskRegistry` → `Store`); renders one page (25, `@default_page_size`) of FULL `%TaskInfo{}` structs (expandable cards need logs/usage/archive_metadata) — memory scales with page_size × blob, not row count.
- **Sidebar "Active Tasks"** — ONE unified implementation in `EvoDashWeb.LiveHooks.NodeAware` (`fetch_active_tasks/1` node-aware fetch with pending-remote guard → `partition_active_tasks/1` pure → `assign_active_tasks/1`): fetches ONLY `@active_statuses = [:running, :pending, :finalizing, :completed]` via `TaskRegistry.list_tasks_summary(statuses)` (local) / `NodeContext.list_tasks_summary(node, statuses)` (remote RPC). Broadcast bursts coalesce via a 300ms trailing-edge debounce (`:node_aware_reload_tasks` + `:tasks_reload_pending` flag); `assign_node/2` dedup-guards via `:tasks_node_loaded`; the dead-render `on_mount` skips the query. Summary decodes run on short-lived Task heaps (task_registry.ex:416-427); `show_review_button?/1` is column-based (`branch_name`), the projection drops `result`.
- **No unfiltered dashboard task-list fetch remains**: there is no main task list (no `current_tasks/1`, no `assign_running_and_pending_tasks`, no stripping helpers). Browser notifications use the minimal id-only projection `TaskRegistry.list_task_ids([:completed, :failed, :cancelled])` (`Assigns.build_notified_task_ids/1`); `get_task/1` runs only per newly-terminal id in the `:node_aware_reload_tasks` handler (list_task_ids → reduce-diff vs the `notified_task_ids` MapSet → full rows only for new ids → `Project.task_notification_content/1` → `push_event "task_notification"`).
- **Summary map contract**: `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at` (opts = decoded keyword list; `updated_at` = raw fixed-precision ISO string). Heavy fields (`result`, `logs`, `usage`, `archive_metadata`) are excluded; `Codec.decode_result/1` (rebuilds embedded `%Usage{}` + archive_records — the largest DB blob) runs only on the full-struct paths (TasksLive paginated, ReviewLive `get_task`).
- **TasksLive / sidebar / AgentsLive are fully push-based**: node-filtered `{:task_updated, task_id, status, node}` / `{:task_deleted, task_id, node}` broadcasts → `NodeAware.handle_task_info/2` 300ms trailing-edge debounce → full page reload — the same code path serves local and remote nodes (no polling, no DirtyTracker, no changed-since transfers).
- **Retention = tab lifetime**: phoenix_live_view has no `live_disconnect_timeout`; the channel stops the LiveView process (`{:stop, {:shutdown, :closed}}`) on socket close, so retained task data lasts exactly as long as tabs are open (N tabs = N copies). EvoDash holds no GenServers/ETS/persistent_term caches of task data; `agents_live.ex` only reads evo_git ETS. `list_task_ids` replies inline on the TaskRegistry GenServer (cheap, no decode); summary/list variants decode on short-lived Tasks — both heaps scale with DB size.
- **Remaining raw-column candidate**: `TaskExportController` decodes archive JSON then re-encodes; a raw-column read would serve the stored JSON directly.

## Constraints

- Domain modules in `./evo_dash/`, web modules in `./evo_dash_web/`
- All LiveViews use `EvoDashWeb.Gettext` for i18n
- Task state and recent projects are persisted via SQLite in the `:evo_git` app (`EvoGit.Store`); no persistence modules remain under `./evo_dash/`; project state also held in socket assigns
- All EvoGit.PubSub subscriptions are conditional on `connected?(socket)` in LiveViews
- EvoGit.PubSub is owned by the evo_git application; EvoDash subscribes as a consumer
