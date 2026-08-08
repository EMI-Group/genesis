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

All pages use the pad shell (`PadComponents.pad_top_bar/1`, nav fixed top-right) — the classic sidebar dashboard (`DashboardLive`) is RETIRED and archived outside the repo (`evox/tmp/original-interface/`).

| LiveView | Route | Purpose |
|----------|-------|---------|
| `HomeLive` | `GET /` | Launchpad home (v3): prompt box, address row, Advanced params, Start button, task rail |
| `ReviewsLive` | `GET /reviews` | Review inbox (awaiting + decided) |
| `AgentsLive` | `GET /agents` | Agent tree inspector with chat history |
| `TasksLive` | `GET /tasks` | Cross-project task list with filters + pagination |
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

READ-ONLY analysis of where dashboard-side Elixir work could be lowered into SQLite. The SQL boundary already lives in `:evo_git` (`EvoGit.Store.Queries.build_where/1` — status, project_path, review_status incl. composite `"pending"` = completed + null review + `branch_name IS NOT NULL`, and search over id/opts-JSON/project_path; `safe_select_paginated_tasks/2` — WHERE + `ORDER BY started_at DESC` + LIMIT/OFFSET + `COUNT(*)` with same WHERE). **TasksLive is already fully SQL-lowered** (filters + pagination + count all in SQL, `tasks_live.ex:572-595` → `RemoteNode` → `RemoteAPI` → `TaskRegistry` → `Store`).

**Status (SQL-lowering round 1 — DONE: evo_dash commits `e03f5bc0`/`751e399e`/`95a2be37`/`51d6c5f2`/`2c639a1e`/`cf7d1fb7` + parallel evo_git statuses API):**
- **Sidebar "Active Tasks" is SQL-filtered + debounced + deduped (was the biggest hotspot)**: `NodeAware.load_running_and_pending_tasks/1` (`live_hooks/node_aware.ex:70-83`) and `Assigns.assign_running_and_pending_tasks/1` fetch ONLY `[:running, :pending, :finalizing, :completed]` via `TaskRegistry.list_tasks_summary(statuses)` (local) / `NodeContext.list_tasks_summary(node, statuses)` (remote RPC) — the SQL statuses-IN WHERE clause (parallel evo_git work) skips finished tasks that can never appear in the sidebar. Broadcast bursts are coalesced by a 300ms trailing debounce (`:node_aware_reload_tasks` + `:tasks_reload_pending` flag) — one reload per burst per LiveView, not one per broadcast. `assign_node/2` skips the reload when the node context is unchanged (`:tasks_node_loaded` guard) — kills the mount double-fetch AND pagination/palette push_patch re-fetches. Note `list_tasks_summary` still decodes INLINE on the TaskRegistry GenServer heap (unlike `list_tasks_paginated` which delegates to a short-lived Task, `task_registry.ex:287`) — now on a WHERE-filtered row set.
- **DashboardLive main list REMOVED (Tasks A-D)**: the dashboard's `@tasks` main list and `Assigns.current_tasks/1` are DELETED — no unfiltered task-list fetch remains in dashboard code (round 1 had made it summary-backed via `list_tasks_summary()` / `list_tasks_summary_by_path(path)`; `lightweight_task/1` and `Assigns.strip_heavy_fields/1` were REMOVED in round 1, fixing the latent bug where `lightweight_task` stripped `result` → dashboard Review buttons / full-result modal were broken). The `notified_task_ids` notification path is now a **minimal id-only projection**: `Assigns.build_notified_task_ids/1` uses `TaskRegistry.list_task_ids([:completed, :failed, :cancelled])` (id+status+updated_at only — no result/opts JSON decode; supersedes the round-1 `cf7d1fb7` `list_tasks_summary()` switch). Template audit: dashboard cards need ONLY summary-contract fields (`components/CONTEXT.md` audit table) — NO lazy `get_task(id)` detail load needed for rendering; `get_task/1` is used ONLY per newly-terminal id for browser notifications; archive UI remains Tasks/Review-page-only.
- **`Assigns.assign_running_and_pending_tasks/2` REMOVED (Tasks A-D)**: the 2-arity variant (which filtered a caller-passed `all_tasks` instead of re-calling `list_tasks_summary()`) is DELETED — the dashboard no longer holds an unfiltered `@tasks` list to filter. The 1-arity `Assigns.assign_running_and_pending_tasks/1` remains as the sidebar path (statuses-filtered `list_tasks_summary([:running, :pending, :finalizing, :completed])`).
- **Summary map contract** (statuses API): `id, status, review_status, result, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at`; heavy fields excluded. (Pre-round-1 `select_tasks_summary` SELECT at `store.ex:607-624` lacked agent_count/branch_name/model_id/base_sha/commit_sha/lease_expires_at — the parallel evo_git work extends the column list.)

**Status (SQL-lowering round 2 — remote-poll dirty-check DONE: evo_dash commit `43a7440b` consuming the evo_git changed-since API):** TasksLive `:remote_poll` now transfers ONLY the lightweight changed-since summaries (usually `[]`) per 3s tick and reloads the full page only when `EvoDashWeb.TasksLive.DirtyTracker` reports a change. The page still renders FULL TaskInfo (expandable cards need archive_metadata/logs/usage — never degraded to summaries); a periodic full re-sync every 10 ticks (~30s) bounds deletion staleness (changed-since cannot detect deletions). Local-node PubSub path unchanged. AgentsLive `:remote_poll` still re-transfers agent summaries; the sidebar has NO poll (broadcast/debounce-driven).

**Remaining candidates (blockers in parens):** (6) raw archive JSON export for `TaskExportController` (decoded then re-encoded; a raw-column read would serve the stored JSON directly). `get_unique_paths` re-fetch and recent-projects sort are negligible. ~~(8) dead dashboard `@tasks` machinery~~ — **DONE (Tasks A-D)**: the dead machinery was removed — `tasks` attr deleted from `Layouts.app`, dead `view_full_result`/`view_full_options`/`toggle_task_details` handlers + `use EvoDashWeb.ModalHelpers` deleted from DashboardLive (only TasksLive uses ModalHelpers now), `expanded_task_ids`/`selected_result`/`selected_options` assigns and the "Full Result/Options Modal" render blocks deleted, and `Assigns.current_tasks/1` deleted. `notified_task_ids` now comes from the minimal id-only projection (`TaskRegistry.list_task_ids([:completed, :failed, :cancelled])`), and `seed_dirty_tracker` uses `list_task_ids` — **no unfiltered summary fetch remains in dashboard code**.

## Memory Profile (sustained BEAM memory vs tasks.sqlite size)

Where per-task data is RETAINED in LiveView process heaps (the driver of sustained memory that scales with row count × result-blob size):

- **DashboardLive `:tasks` REMOVED (Tasks A-D)** — the dashboard no longer retains any unfiltered summary-map list (previously it was the FULL 16-key summary-map list incl. decoded `result` JSON — `Codec.decode_result` reconstructs the `{:ok, %{...}}` tuple with embedded `%Usage{}` and archive_records; see `store.ex:58` + `store.ex:987-1023` — re-fetched on EVERY task-broadcast burst). The only task data DashboardLive retains is `:running_tasks`/`:pending_tasks` (statuses-filtered summaries) and the `notified_task_ids` MapSet (ids only; see the "DashboardLive `@tasks` is GONE" bullet below).
- **`:running_tasks` / `:pending_tasks`** in EVERY LiveView (NodeAware `on_mount` via `evo_dash_web.ex:49-53`, `node_aware.ex:70-99` + `assigns.ex:33-69`): statuses-filtered subsets of the SAME summary maps (shared references, not copies; filtered from the same list — no per-assign duplication). Rendered in the sidebar (`layouts.ex:139-146`). Note `pending_tasks` retains full summary maps for every completed-unreviewed task with a branch (pattern-matches `result: {:ok, %{branch_name: _}}`, `assigns.ex:75`).
- **TasksLive `:tasks`/`:filtered_tasks`** = one PAGE (25, `@default_page_size`) of FULL `%TaskInfo{}` structs (logs/usage/archive_metadata) via `list_tasks_paginated` — scales with page_size × blob, not row count. `:dirty_tracker` stores only `last_seen_updated_at` + tick counter (no maps).
- **Lifecycle**: phoenix_live_view 1.2.8 has NO `live_disconnect_timeout` (option removed in LV 1.0; grep deps + config = no matches). The channel stops the LiveView process with `{:stop, {:shutdown, :closed}}` on socket close (`deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:96-103`) — so retention lasts exactly as long as tabs are OPEN (indefinite per tab; N tabs = N copies). No GenServers/ETS/persistent_term caches in evo_dash (greps confirm); `agents_live.ex:624-631` only READS evo_git ETS (agent data, scales with live agents, not DB size).
- **Inline decode on the registry heap**: `list_tasks_summary*`/`list_tasks_changed_since` decode ALL rows inside the TaskRegistry GenServer (`task_registry.ex:403-406`-era inline handler; see round-1 note above) — each call transiently materializes the full decoded list on the evo_git GenServer heap, then hands the maps to the LiveView which retains them. Both heaps scale with DB size.
- **DashboardLive `@tasks` is GONE (Tasks A-D — dead machinery removed; the biggest avoidable full-scan identified by investigator T1-A2)**: the dead dashboard task list was deleted — `Layouts.app` no longer declares `attr(:tasks, :list, default: [])` (`layouts.ex` keeps only `attr(:running_tasks, ...)` / `attr(:pending_tasks, ...)`), the dead `view_full_result` / `view_full_options` / `toggle_task_details` handlers were removed from `dashboard_live.ex` (ModalHelpers is now used ONLY by TasksLive), and the `expanded_task_ids` / `selected_result` / `selected_options` assigns + "Full Result/Options Modal" render blocks are gone. The UNFILTERED summary fetch no longer runs anywhere in dashboard code: `notified_task_ids` is served by `Assigns.build_notified_task_ids/1` — the minimal id-only query `TaskRegistry.list_task_ids([:completed, :failed, :cancelled])` (no result/opts decode), unioned cheaply (MapSet union) on mount (`dashboard_live.ex:450`), `handle_params` fallbacks (`531,551,560`), `activate_project` (`1421`), and `clear_task_history` (unions terminal ids BEFORE clearing, `944-950`). The `:node_aware_reload_tasks` handler (`dashboard_live.ex:1191-1238`) fetches `list_task_ids([:completed, :failed, :cancelled])`, reduce-diffs against the `notified_task_ids` MapSet, and fetches FULL rows only for newly-terminal ids (`TaskRegistry.get_task(id)` → `Project.task_notification_content(task)` → `push_event "task_notification"`) — decode cost is bounded to newly-terminal rows only; then it re-runs the 1-arity `Assigns.assign_running_and_pending_tasks/1` (sidebar) + project-settings refresh + `NodeAware.clear_task_reload_pending/1`. `cancel_task`/`delete_task` `MapSet.put` the affected id into the notified set (`928-929`, `961-962`); `start_task` refreshes the sidebar only. The ONLY summary calls left in dashboard code are the sidebar's statuses-filtered ones.
- **Result-blob display audit (investigator T1-A2)**: the heavy per-row `result` decode in summary queries is displayed NOWHERE in dashboard UI. The sidebar uses only `result.branch_name` PRESENCE (`show_review_button?`, `assigns.ex:75` / `node_aware.ex:101` — pattern match, value not rendered); browser notifications use `result` (pr_title/error/exit) only for terminal tasks; the "full result" modal (`render_result_full`) is dead on the dashboard (removed in Tasks A-D) but still rendered by TasksLive. TasksLive/ReviewLive consume full structs via `list_tasks_paginated`/`get_task`, NOT the summary query. So per-row `Codec.decode_result` (rebuilds embedded `%Usage{}` + archive_records — the largest blob in the DB) is essentially wasted work for the current dashboard UI; only branch_name presence + terminal-task pr_title/error text are ever read from it. (Dropping `result` from the summary projection would require re-sourcing `show_review_button?` and notification text — e.g. via review_status/branch_name columns or a targeted query.)
- **TasksLive remote dirty-tracker baselines are minimal-projection (FIXED, Tasks A-D)**: both call sites — `seed_dirty_tracker/1` (`tasks_live.ex:767`) and the `:remote_poll` belt-and-braces reseed (`tasks_live.ex:439`) — now use `EvoDash.NodeContext.list_task_ids(current_node)` (minimal id/status/updated_at projection via `EvoGit.RemoteNode.list_task_ids/2`, no result/opts JSON decode) instead of the old unfiltered `list_tasks_summary(node)`. A node switch no longer triggers a full scan + full decode on the remote node.
- **Git history (design intent, investigator T1-A2)**: evo_git `ec48b124` (2026-07-31) introduced `select_tasks_summary` as a full scan with NO WHERE/LIMIT/ORDER BY and decoded `result` from day one (the commit message's "no heavy JSON fields" claim is inaccurate — result is the heaviest field). The statuses arg + SQL pushdown arrived in evo_git `c196be51`. evo_dash never filtered the dashboard main list by status and never paginated it; the dashboard evolution was: (a) server-side pagination added to the Tasks page (`f27b4d75` LIMIT/OFFSET), (b) active tasks moved into the sidebar (`07d201c4`/`2da36db0`), (c) dashboard task-card list REMOVED in `208a0891` while the unfiltered `@tasks` fetch was KEPT (re-carried through the summary-maps migration `751e399e`), (d) ~30MB binary retention mitigated earlier by post-fetch stripping (`6e8d2ff4`), (e) sidebar statuses-filtered only (`e03f5bc0`), (f) the dead `@tasks` fetch finally REMOVED (Tasks A-D minimal-projection rework — notifications via `list_task_ids` + per-id `get_task`, dirty-tracker baselines via `list_task_ids`).

## Constraints

- Domain modules in `./evo_dash/`, web modules in `./evo_dash_web/`
- All LiveViews use `EvoDashWeb.Gettext` for i18n
- Task state and recent projects are persisted via SQLite in the `:evo_git` app (`EvoGit.Store`); no persistence modules remain under `./evo_dash/`; project state also held in socket assigns
- All EvoGit.PubSub subscriptions are conditional on `connected?(socket)` in LiveViews
- EvoGit.PubSub is owned by the evo_git application; EvoDash subscribes as a consumer
