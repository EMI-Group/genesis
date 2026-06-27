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
- `EvoDash.TaskRegistry` — DETS-backed GenServer tracking tasks; spawns `EvoGit.Runtime.*` processes
- `EvoDashWeb.Endpoint` — Phoenix endpoint (LiveView socket, static files, Plug pipeline)
- `EvoDashWeb.Router` — Routes to LiveViews and Phoenix LiveDashboard
- `EvoDashWeb.Helpers` — Shared UI utilities (status badges, datetime formatting, icons, modals)

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

### LiveView Pages (`./lib/evo_dash_web/live/`)

- `DashboardLive` — Main dashboard: project tabs, task form, task cards with logs, inline project settings (genesis.toml, foreign repos). Completed tasks with branches show a "Review" button linking to the review page.
- `ReviewLive` — Code review page (similar to GitHub PR view): shows PR title, agent summary, commit list (GitHub-style), files changed with diff stats, full syntax-highlighted diff (Lumis), and action buttons (Merge, Reject, Continue, Create GitHub PR). Three tabs: Conversation, Commits, Files Changed.
- `AgentsLive` — Agent tree visualization reading directly from ETS tables (`evogit_agent_state`, `evogit_sched_meta`)
- `SettingsLive` — Configuration File tab (GUI editor for config.toml with collapsible sections for LLM, User, Scheduler, Sandbox, Evolution, Truncation, Task History)
- `SystemLive` — System page: scheduler controls (pause/resume), system controls (restart/stop the Erlang VM), system self-check (config status, tools, sandbox, supervisor), plus usage guides and references (example config, CLI usage, FAQ, credentials)

### UI Components (`./lib/evo_dash_web/components/`)

- `CoreComponents` — Phoenix 1.8 base components
- `DashboardComponents` — Task form, scheduler settings, project tabs, task cards (with "Review" button for completed tasks with branches)
- `ReviewComponents` — Review page components: commit list (GitHub-style with SHA badges, messages, author, relative time), diff stats bar, file list, diff viewer (Lumis syntax highlighting), action buttons (merge/reject/continue/create PR)
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
- No database — task state persisted via DETS; project state in LiveView socket assigns
- Single-node (DNSCluster configured but no distributed clustering)
- Naming conventions: domain modules in `./lib/evo_dash/`, web modules in `./lib/evo_dash_web/`
- Build: `mix assets.build` (esbuild + tailwind), `mix assets.deploy` (minified + digested)
- No CI/CD pipeline, no Docker, no `rel/` directory — release packaging not yet configured
