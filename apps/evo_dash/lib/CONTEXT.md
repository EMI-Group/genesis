# `apps/evo_dash/lib/` — Application Source Code

## Intent

Application source code for the EvoDash Phoenix LiveView dashboard. Split into two top-level namespaces:
- `evo_dash/` — Domain logic (OTP application, task registry)
- `evo_dash_web/` — Web interface (LiveView pages, components, templates, router, helpers)

## Routing Table

- `./evo_dash/` → Domain & business logic (Application supervisor, TaskRegistry)
- `./evo_dash_web/` → Web interface (LiveViews, components, router, templates, helpers)

## API Surface

### Cross-App Communication: EvoDash → EvoGit

All communication from EvoDash to EvoGit is **direct function calls** (synchronous GenServer calls and direct module calls). There is no message queue, no REST API, and no custom IPC — both apps run in the same BEAM VM.

#### 1. Task Execution (TaskRegistry → EvoGit.Runtime)

`TaskRegistry.execute_task/3` spawns a supervised task that calls:
- `EvoGit.Runtime.Genesis.run(prompt, runtime_opts)` for genesis tasks
- `EvoGit.Runtime.Evolution.run(objective, runtime_opts)` for evolution tasks

Runtime opts passed: `[repo_path:, mode:, task_id:, event_sink:, node_path?:, seed_content?:]`
The `event_sink` is `{EvoDash.TaskRegistry, :update_task_log, [task_id]}` — EvoGit calls this MFA to pipe logs back.
`Application.ensure_all_started(:evo_git)` is called before execution to guarantee the core runtime is up.

#### 2. Scheduler Configuration (SettingsLive → EvoGit.AgentScheduler)

`SettingsLive` directly calls the AgentScheduler GenServer:
- `EvoGit.AgentScheduler.get_config()` — read current scheduler config (concurrency, retries, depth, model, paused)
- `EvoGit.AgentScheduler.update_config(keyword_list)` — push runtime config changes (max_concurrency, max_tool_concurrency, agent_max_retries, max_agent_depth, max_retries, llm_model)
- `EvoGit.AgentScheduler.pause()` / `EvoGit.AgentScheduler.resume()` — toggle scheduler pause state

When AgentScheduler processes these, it broadcasts `{:scheduler_config_updated}` on `EvoGit.PubSub` topic `"scheduler_config"` (via `EvoGit.AgentScheduler.PubSub.broadcast_config_updated/0`).

#### 3. Foreign Repository Management (DashboardLive → EvoGit.AgentScheduler)

- `EvoGit.AgentScheduler.register_foreign_repo(%ForeignRepo{})` — register a foreign repo
- `EvoGit.AgentScheduler.unregister_foreign_repo(atom)` — remove a foreign repo
- `EvoGit.AgentScheduler.get_foreign_repos()` — list registered foreign repos

#### 4. Configuration File Management (HelpLive → EvoGit.Config)

- `EvoGit.Config.config_status()` — check if all critical config values are set
- `EvoGit.Config.config_dir()` / `config_path()` / `credentials_path()` — get file paths
- `EvoGit.Config.save_user_config(map)` — write parsed TOML config to disk
- `EvoGit.Config.resolve()` — resolve full config (used for task_history settings)

#### 5. PubSub Topics (EvoGit.PubSub — owned by evo_git)

EvoDash subscribes to these `EvoGit.PubSub` topics:
- `"tasks"` — TaskRegistry broadcasts `{:tasks_updated}` on task status changes; LiveViews subscribe to refresh UI
- `"agents"` — AgentScheduler broadcasts `{:agents_updated}` on agent state changes; AgentsLive subscribes
- `"scheduler_config"` — broadcasts `{:scheduler_config_updated}` on config/pause/resume; SettingsLive subscribes
- `"recent_projects"` — TaskRegistry broadcasts `{:recent_projects_updated}`; DashboardLive subscribes

Note: EvoDash also has its own `EvoDash.PubSub` (started in its supervision tree) but it is not used for cross-app communication. All cross-app events go through `EvoGit.PubSub`.

#### 6. Shared ETS Tables (owned by EvoGit.AgentScheduler)

AgentsLive reads directly from two ETS tables owned by the AgentScheduler:
- `:evogit_agent_state` — agent spatial/temporal state, event_sink, context, phylo_node
- `:evogit_sched_meta` — scheduling metadata (status, worktree, depth, parent, retries, spec)

These are `:public` named tables. AgentsLive uses `:ets.whereis/1` to check existence before reading.

#### 7. Application.put_env / Application.get_env

No `Application.put_env` calls to `:evo_git` exist in EvoDash. All config changes go through the `EvoGit.AgentScheduler.update_config/1` GenServer call. EvoDash only uses `Application.get_env(:evo_dash, ...)` for its own desktop mode settings.

## Constraints

- No `Application.put_env` is used to modify EvoGit configuration — all changes go through the AgentScheduler GenServer API
- EvoDash directly calls EvoGit GenServers (same BEAM VM) — no network boundary or serialization
- All EvoGit.PubSub subscriptions are conditional on `connected?(socket)` in LiveViews to avoid stale subscriptions
- AgentsLive reads ETS directly (no GenServer call) for performance — tables are public
- EvoGit.PubSub is owned by the evo_git application; EvoDash subscribes as a consumer
