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

- `EvoDash.Application` — OTP supervisor (Telemetry → PubSub → TaskSupervisor → Store → TaskRegistry → Endpoint)
- `EvoDash.Store` — SQLite (xqlite) backed persistent store (single GenServer holding one connection, column-based tables) for task history and recent projects; started under supervision before TaskRegistry. Uses **explicit durability PRAGMAs** (`journal_mode=WAL`, `synchronous=NORMAL`) and **graceful connection close** in `terminate/2`. Delegates ALL serialization to `EvoDash.Store.Codec` (pure functions). Data is stored in **proper typed columns** (TEXT, INTEGER) — not `term_to_binary` blobs — and JSON encoding (via Jason) for ALL complex nested fields (opts, logs, usage, archive_metadata, result); the `result` field stores runtime return tuples (`{:ok, %{...}}`, `{:error, _}`, `{:exit, _}`) as tagged JSON with a `"__result_tag__"` discriminator, reconstructing tuples + atom keys + the embedded `%EvoGit.Agent.Usage{}` struct on decode. Atom fields (`type`, `status`, `review_status`) use `encode_atom/1` which accepts nil, atoms, and strings for full round-trip safety, and `decode_atom/1` using `String.to_existing_atom/1` (returns nil for unknown values, never crashes). Defines `EvoDash.TaskInfo` and `EvoDash.RecentProject` structs. Provides crash-safe read/recovery helpers (`safe_select_all_tasks/1`, `safe_select_all_projects/1`, `integrity_check/1`) that survive corrupt (un-deserializable) entries by **quarantining** them (moving to `<table>_quarantine`) rather than dropping. `integrity_check/1` runs a SQLite `PRAGMA integrity_check` and scans all rows, quarantining undecodable ones. `integrity_check` is called by TaskRegistry on init. Schema evolution is handled by `migrate_schema/1` (idempotent `ALTER TABLE ... ADD COLUMN` guarded by `PRAGMA table_info`) — runs on Store init after table creation, so existing DBs gain the `lease_expires_at INTEGER` column without data loss.
- `EvoDash.TaskRegistry` — GenServer tracking tasks, persisted to SQLite; spawns `EvoGit.Runtime.*` processes. Implements a **Lease & Heartbeat** pattern (see Data-safety architecture) for multi-instance robustness: tasks carry a `lease_expires_at` timestamp; the owning instance renews leases via a periodic `:heartbeat` timer; lease **checking/sweeping** is a **two-check, one-shot** design — it runs once at startup (via `reconcile_task_status/2`) and once more after the lease duration (via a one-shot `:lease_sweep` timer scheduled in `init`), NOT continuously on every heartbeat; startup reconciliation marks running tasks `:failed` only when the lease has genuinely expired (not just because the pid is dead/foreign)
- `EvoDashWeb.Endpoint` — Phoenix endpoint (LiveView socket, static files, Plug pipeline)
- `EvoDashWeb.Router` — Routes to LiveViews and Phoenix LiveDashboard
- `EvoDashWeb.Helpers` — Shared UI utilities (status badges, datetime formatting, icons, modals)
- `EvoDashWeb.TaskExportController` — JSON download endpoint for a task's `archive_metadata` (`GET /tasks/:task_id/export`); normalizes structs/DateTimes to plain JSON-safe maps before encoding with Jason

### Mix Tasks

- `mix translate` — AI-powered POT file translation using `deepseek-v4-flash`; usage: `mix translate <pot_file> <lang1|all> [lang2] ... [--force] [--prefix <prefix>]`

### Routes

| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `DashboardLive` | Project-based task dashboard with auto-mode detection, task form, project settings |
| `GET /review/:task_id` | `ReviewLive` | Code review page — diff viewer with Lumis syntax highlighting, merge/reject/continue actions, optional GitHub PR creation |
| `GET /agents` | `AgentsLive` | Recursive agent tree inspector with chat history viewer and token/cost usage display |
| `GET /settings` | `SettingsLive` | Configuration File GUI editor (config.toml) with collapsible sections for LLM, User, Scheduler, Sandbox, Evolution, Truncation, Task History |
| `GET /system` | `SystemLive` | System page: scheduler controls (pause/resume), system controls (restart/stop the Erlang VM), system self-check, plus usage guides and references (example config, CLI usage, FAQ, credentials) |
| `/dashboard` | Phoenix.LiveDashboard | Built-in metrics/telemetry dashboard |

### Task Archive Feature

When a task is started with the **archive** option enabled (checkbox in the task form), the core runtime collects per-agent metadata (`archive_records`) and EvoDash stores it in `TaskInfo.archive_metadata`. Archived tasks display the agent parent-child tree, per-agent details (objective, return message, start/end commits, token usage, archive refs), and provide JSON export.

- **Opt-in**: When archive is not enabled, the UI is identical to current (no archive sections shown).
- **`TaskInfo.archive_metadata`**: `[map()] | nil` — list of per-agent records (backfill-safe via `Map.merge(%TaskInfo{}, task)` in `normalize_tasks/1`).
- **Threading**: `:archive` opt → `build_common_runtime_opts/2` → runtime opts → core runtime. On completion, `archive_records` extracted from result map → `update_task_status/4` → `do_handle_update_status/5` → persisted.
- **JSON export**: `GET /tasks/:task_id/export` → `TaskExportController` normalizes structs to plain maps and serves a downloadable JSON file.
- **i18n**: All archive UI strings use gettext.

### LiveView Pages (`./lib/evo_dash_web/live/`)

- `DashboardLive` — Main dashboard: project tabs, task form, task cards with logs, inline project settings (genesis.toml, foreign repos). Completed tasks with branches show a "Review" button linking to the review page.
- `ReviewLive` — Code review page (similar to GitHub PR view): shows PR title, agent summary, commit list (GitHub-style), files changed with diff stats, full syntax-highlighted diff (Lumis), and action buttons (Merge, Reject, Continue, Create GitHub PR). Three tabs: Conversation, Commits, Files Changed.
- `AgentsLive` — Agent tree visualization reading directly from ETS tables (`evogit_agent_state`, `evogit_sched_meta`)
- `SettingsLive` — Configuration File tab (GUI editor for config.toml with collapsible sections for LLM, User, Scheduler, Sandbox, Evolution, Truncation, Task History)
- `SystemLive` — System page: scheduler controls (pause/resume), system controls (restart/stop the Erlang VM), system self-check (config status, tools, sandbox, supervisor), plus usage guides and references (example config, CLI usage, FAQ, credentials)

### UI Components (`./lib/evo_dash_web/components/`)

- `CoreComponents` — Phoenix 1.8 base components
- `DashboardComponents` — Task form, scheduler settings, project tabs, task cards (with "Review" button for completed tasks with branches)
- `ReviewComponents` — Review page components: review header + task summary/usage strip (tokens, cost, cache hit rate, agent count), commit list (GitHub-style with SHA badges, messages, author, relative time), diff stats bar, file list, diff viewer (Lumis syntax highlighting), action buttons (merge/reject/continue/create PR)
- `AgentsComponents` — Recursive path tree with connector lines and status coloring
- `Layouts` — App layout with navbar, theme toggle, flash group

## Desktop Mode (Tauri Shell)

The backend is a **standalone web server** with NO GUI dependencies (no `:desktop`, no `:wx`). Desktop mode is provided externally by a **Tauri shell** (in `./desktop/` at the repository root) that launches this backend as a sidecar process.

- **Directory picking** is handled client-side via the browser File System Access API, or Tauri's native dialog plugin when running in a Tauri webview.
- The former `EvoDashWeb.NativePicker` module (server-side `:wx` directory dialog) has been removed.
- There are NO references to `:desktop`, `:wx`, `Desktop.Window`, `desktop_port`, `is_desktop`, `?client=desktop`, `detect_desktop_client`, or `EVOGIT_DESKTOP` in the codebase.

### Release Configuration

- **No `rel/` directory exists within this app** — no custom release steps, no Dockerfile.
- The umbrella `mix.exs` defines a release named `:evogit` including both apps (`evo_git: :permanent`, `evo_dash: :permanent`).
- `config/runtime.exs` handles `PHX_SERVER=true` to enable the Phoenix server in release mode.
- Production requires `SECRET_KEY_BASE` and `PHX_HOST` env vars.
- The Tauri desktop shell (separate project at `./desktop/`) packages the backend as a sidecar for desktop distribution.

### Static Assets (`priv/static/`)

| File | Purpose |
|------|---------|
| `favicon.ico` | Browser tab icon |
| `robots.txt` | Standard web crawler directives (all commented out) |
| `images/logo.svg` | Default Phoenix logo SVG (not EvoGit-branded) |

## Internationalization (i18n)

EvoDash uses **Gettext** for internationalization. All user-facing strings in LiveViews, components, helpers, and templates are wrapped with `gettext/1,2` calls.

- **Backend**: `EvoDashWeb.Gettext` (`lib/evo_dash_web/gettext.ex`) — `use Gettext, otp_app: :evo_dash`
- **Import**: `import EvoDashWeb.Gettext` in `evo_dash_web.ex` `html_helpers/0` — available in all LiveViews and HTML components
- **Translation files**: `priv/gettext/default.pot` (template, 253 messages), `priv/gettext/en/LC_MESSAGES/default.po` (English source strings)
- **Dynamic locale**: `root.html.heex` uses `Gettext.get_locale(EvoDashWeb.Gettext)` for the `<html lang>` attribute
- **Workflow**: `mix gettext.extract` → `mix gettext.merge priv/gettext --locale=<lang>` to add new languages
- **AI Translation**: `mix translate apps/evo_dash/priv/gettext/default.pot all` — translates POT file to all supported languages using LLM (`deepseek-v4-flash`). Supports `--force/-f` to re-translate existing entries and `--prefix/-p` to filter by source file prefix. See `lib/mix/tasks/translate.ex`.
- **CLI excluded**: The `:evo_git` CLI interface does NOT use gettext — only the web dashboard is internationalized

## Constraints

- Depends on `:evo_git` at compile and runtime
- Runs on port 4100 in development, uses Bandit adapter
- Tailwind CSS 4 + DaisyUI (no Node.js toolchain)
- Task state and recent projects persisted via SQLite (xqlite — Rust-based panic-free NIF bindings with precompiled binaries for Windows, macOS, and Linux incl. ARM); no external database server
- **Data-safety architecture**: The TaskRegistry GenServer `handle_*` callbacks have NO try/rescue — if a Store call fails, the GenServer crashes and the supervisor restarts it. The Store GenServer's `handle_*` callbacks also have NO try/rescue — SQLite failures crash it and the supervisor restarts with a fresh connection (data is safe in WAL mode). Serialization is delegated to `EvoDash.Store.Codec` (pure functions: TOTAL encode via non-crashing `Jason.encode/1` + `case`, raise-on-bad-decode). `select_all_tasks`/`select_all_projects` use `EvoDash.Store.safe_select_all_tasks/1` / `safe_select_all_projects/1` which **quarantine** rows whose data fails to decode (per-row rescue, never raises; bad rows moved to `<table>_quarantine`, not dropped). `EvoDash.Store.integrity_check/1` runs on TaskRegistry init to heal a corrupted DB (runs `PRAGMA integrity_check` + scans for undecodable rows, quarantines corrupt rows). Batch deletions go through `EvoDash.Store.delete_tasks/2`. `cleanup_expired_tasks` runs only on task-completion transitions, explicit `clear_finished_tasks`, and `init` — not on every mutation — and uses a single-pass scan. The completed task's `EvoDash.Store.put_task` in `update_status` runs BEFORE `cleanup_expired_tasks`, so a crash mid-cleanup never loses the completed task. On registry restart, `reconcile_task_status/2` uses a **lease & heartbeat** pattern for multi-instance robustness: a running task carries a `lease_expires_at` timestamp (granted on start, renewed every 60s via a `:heartbeat` timer, cleared on terminal status). A running task with a dead/nil pid is marked `:failed` ONLY if its lease has genuinely expired (`lease_valid?/1` returns false for nil or past timestamps) — this prevents a second BEAM VM instance from incorrectly marking the first instance's running tasks as `:failed` just because the foreign pid is dead and the per-VM `:evogit_sched_meta` ETS is empty. Tasks with a valid lease are left `:running` (the one-shot `:lease_sweep` will catch them if the lease eventually expires — no periodic per-task recheck). The lease-expiry sweep is a **two-check, one-shot** design, NOT continuous-on-every-heartbeat: a one-shot `:lease_sweep` timer (scheduled in `init`, firing after the lease duration + a buffer) sweeps unowned running tasks with expired leases; the `:heartbeat` handler now does ONLY lease renewal for owned tasks. Same-VM result recovery (`:recheck_task`) is a separate concern (reuses the existing same-VM `:recheck_task` periodic mechanism for tasks whose wrapper died but agents are still running in our ETS). `reconcile_task_status/2` still checks `:evogit_sched_meta` ETS (via `:ets.info/1`, non-crashing) for active agents as a same-VM recovery edge case.
- **Supervision robustness**: `EvoDash.Supervisor` uses `:one_for_one` with `max_restarts: 10, max_seconds: 60` so the Phoenix Endpoint survives a transient TaskRegistry restart. `:one_for_one` (not `:rest_for_one`) is correct because TaskStore must stay alive across TaskRegistry restarts (TaskRegistry holds no state — it reads the store fresh on every call, so a restart loses nothing durable).
- Single-node (no distributed clustering)
- Naming conventions: domain modules in `./lib/evo_dash/`, web modules in `./lib/evo_dash_web/`
- Build: `mix assets.build` (esbuild + tailwind), `mix assets.deploy` (minified + digested)
- No CI/CD pipeline, no Docker, no `rel/` directory — release packaging not yet configured
- **`try/rescue` anti-pattern policy**: `try/rescue` is normally an anti-pattern in Elixir. The following rules apply across the codebase:
  - **LiveView config/core-value loading** (e.g. `EvoGit.Config.resolve`, `EvoGit.AgentScheduler.get_config`, `EvoGit.Config.config_status`): do NOT wrap in `try/rescue` swallowing to a default. Let the LiveView crash truthfully — a visible crash is better than displaying a wrong/default value that hides a real bug in the core system.
  - **JSON encoding**: use the non-crashing `Jason.encode/1` (returns `{:ok, _} | {:error, _}`) with `case`, NOT `Jason.encode!` wrapped in `try/rescue`. (The built-in `JSON` module exists in Elixir 1.20 but does not export `encode/1` — `Jason.encode/1` is the correct non-crashing variant.)
  - **Atom conversion from untrusted input** (DB-sourced strings, URL params): use a whitelist `Map.get/3` lookup instead of `try/rescue` around `String.to_existing_atom/1`. For trusted input where the atom is expected to exist, let it crash.
  - **ETS table existence checks**: use `:ets.info/1` (returns `:undefined` for missing tables, non-crashing), NOT `try/rescue` around `:ets.match/2`.
  - **Acceptable `try/rescue` (rare, each MUST have a comment answering: (1) do we expect this error? (2) is try/rescue the cleanest approach?)**: `terminate/2` in GenServers (shutdown safety), deliberate data-recovery boundaries (the Store's quarantine logic for corrupt DB rows), and boundaries with untrusted persisted data where no non-crashing variant exists (`:erlang.list_to_pid`, `String.to_existing_atom` for best-effort decode). Test-cleanup rescues in `on_exit`/teardown are acceptable (cleanup failures should not mask test results) but must have a comment.
