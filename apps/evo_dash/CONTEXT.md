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

### Mix Tasks

- `mix translate` — AI-powered POT file translation using `deepseek-v4-flash`; usage: `mix translate <pot_file> <lang1|all> [lang2] ... [--force] [--prefix <prefix>]`

### Routes

| Route | LiveView | Purpose |
|-------|----------|---------|
| `GET /` | `DashboardLive` | Project-based task dashboard with auto-mode detection, task form, project settings |
| `GET /review/:task_id` | `ReviewLive` | Code review page — diff viewer with Lumis syntax highlighting, merge/reject/continue actions, optional GitHub PR creation |
| `GET /agents` | `AgentsLive` | Recursive agent tree inspector with chat history viewer and token/cost usage display |
| `GET /settings` | `SettingsLive` | Two-tab settings: Runtime Settings (scheduler/sandbox) + Configuration File (GUI editor for config.toml) |
| `GET /help` | `HelpLive` | Guidance page: config status, example config, CLI usage examples, FAQ, credentials reference |
| `/dashboard` | Phoenix.LiveDashboard | Built-in metrics/telemetry dashboard |

### LiveView Pages (`./lib/evo_dash_web/live/`)

- `DashboardLive` — Main dashboard: project tabs, task form, task cards with logs, inline project settings (evogit.toml, foreign repos). Completed tasks with branches show a "Review" button linking to the review page.
- `ReviewLive` — Code review page (similar to GitHub PR view): shows PR title, agent summary, commit list (GitHub-style), files changed with diff stats, full syntax-highlighted diff (Lumis), and action buttons (Merge, Reject, Continue, Create GitHub PR). Three tabs: Conversation, Commits, Files Changed.
- `AgentsLive` — Agent tree visualization reading directly from ETS tables (`evogit_agent_state`, `evogit_sched_meta`)
- `SettingsLive` — Two-tab layout: Runtime Settings tab (scheduler pause/resume, scheduler/sandbox config forms, current runtime values) and Configuration File tab (GUI editor for config.toml with collapsible sections for LLM, User, Scheduler, Sandbox, Evolution, Truncation, Task History)
- `HelpLive` — Guidance and reference page: config status check, example TOML configuration, CLI usage examples, FAQ section, credentials reference

### UI Components (`./lib/evo_dash_web/components/`)

- `CoreComponents` — Phoenix 1.8 base components
- `DashboardComponents` — Task form, scheduler settings, project tabs, task cards (with "Review" button for completed tasks with branches)
- `ReviewComponents` — Review page components: commit list (GitHub-style with SHA badges, messages, author, relative time), diff stats bar, file list, diff viewer (Lumis syntax highlighting), action buttons (merge/reject/continue/create PR)
- `AgentsComponents` — Recursive path tree with connector lines and status coloring
- `Layouts` — App layout with navbar, theme toggle, flash group

## Desktop Mode

EvoDash can run as a native desktop application using the `:desktop` Hex package (v1.5.3) and Erlang `:wx`. When enabled, it opens a native OS window wrapping the Phoenix web interface.

### Activation

Desktop mode is controlled by two config flags, both of which must be set:

1. **`config :evo_dash, desktop: true`** — Application-level config (compile-time default: `false`)
2. **`config :evo_dash, desktop_port: 4100`** — Port for the embedded HTTP server

At runtime, set env var `EVOGIT_DESKTOP=1` (and optionally `EVOGIT_DESKTOP_PORT`) to activate. In `config/runtime.exs`, these are read and applied as application env. In dev mode (`config/dev.exs`), desktop is explicitly set to `false`.

### Architecture

- **`EvoDash.Application`** — Conditionally adds `{Desktop.Window, [...]}` to the supervision tree when `:desktop` is `true`. The window is configured with title "EvoGit Dashboard", size `{1280, 800}`, and loads `http://localhost:<port>/?client=desktop`.
- **`EvoDashWeb.Router`** — Contains a custom plug `detect_desktop_client/2` that checks for `?client=desktop` query param and sets `session[:is_desktop] = true`.
- **`EvoDashWeb.NativePicker`** — Server-side native OS directory picker using Erlang's `:wxDirDialog`. Runs in a separate `Task` process with 120s timeout. Requires `:wx` extra application (declared in `mix.exs`).
- **`DashboardLive`** — Reads `session["is_desktop"]` and assigns it as `@is_desktop`, passes it to `DirectoryPicker` JS hook via `data-is-desktop` attribute.
- **`DirectoryPicker` JS hook** — In desktop mode (`data-is-desktop="true"`), bypasses browser File System Access API and directly calls server-side `pick_directory` event (→ `NativePicker.pick_directory()`).

### Native Window Configuration

```elixir
{Desktop.Window, [
  app: :evo_dash,
  id: :evo_dash_window,
  title: "EvoGit Dashboard",
  url: "http://localhost:#{port}/?client=desktop",
  size: {1280, 800}
]}
```

### Release Configuration

- **No `rel/` directory exists** — no custom release steps, no Dockerfile, no CI configuration.
- The umbrella `mix.exs` defines a release named `:evogit` including both apps (`evo_git: :permanent`, `evo_dash: :permanent`).
- `config/runtime.exs` handles `PHX_SERVER=true` to enable the Phoenix server in release mode.
- Production requires `SECRET_KEY_BASE` and `PHX_HOST` env vars.

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
- Desktop mode requires Erlang `:wx` — not available in all OTP builds (headless servers)
- No CI/CD pipeline, no Docker, no `rel/` directory — release packaging not yet configured
- The `:desktop` dependency (hex package v1.5.3) provides the native window wrapper via `Desktop.Window`
