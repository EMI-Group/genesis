# LiveView Pages

## Intent
Contains Phoenix LiveView modules and templates that form the interactive UI layer of the EvoDash dashboard. These pages provide real-time task management, agent inspection, runtime configuration, and user help for the EvoGit evolutionary software development system.

## API Surface

### Modules
- **`EvoDashWeb.DashboardLive`** (`dashboard_live.ex`) — Main dashboard page mounted at route `/`.
  - Renders inline HEEx template with tab-based UI (Genesis / Evolve)
  - Genesis form: path, prompt, mode (new/existing), concurrency, retries, agent_max_retries
  - Evolve form: path, objective, mode (simple/complex), concurrency, retries, agent_max_retries
  - Displays running/recent task cards with status badges and expandable details
  - Auto-refreshes task list every 1 second via `Process.send_interval` (connected only)
  - Events handled: `set_tab`, `genesis_submit`, `evolve_submit`, `cancel_task`, `toggle_task_details`
  - Depends on `EvoDash.TaskRegistry` for all task CRUD operations
  - Delegates form rendering to `EvoDashWeb.DashboardComponents` (genesis_form/evolve_form)

- **`EvoDashWeb.AgentsLive`** (`agents_live.ex`) — Agent tree inspector mounted at route `/agents`.
  - Displays recursive agent hierarchy from `EvoDash.AgentTree`
  - Shows agent status (pending/running/waiting), module names, retry counts
  - Click-to-select agents; detail panel shows config, status, children, and step history
  - Auto-refreshes every 500ms
  - Uses `EvoDashWeb.AgentsComponents.agent_tree/1` for recursive tree rendering

- **`EvoDashWeb.SettingsLive`** (`settings_live.ex`) — Scheduler settings page mounted at route `/settings`.
  - Displays runtime configuration for agent execution (concurrency, retries, depth, LLM model)
  - Shows config status warnings if critical settings are missing (via `EvoGit.Config.config_status/0`)
  - Inline form for updating scheduler config at runtime (delegates to `EvoGit.AgentScheduler.update_config/1`)
  - Displays current runtime values in a grid summary
  - Auto-refreshes every 2 seconds via `Process.send_interval` (connected only)
  - Events handled: `scheduler_config_change`, `update_scheduler_config`
  - Uses `EvoDashWeb.DashboardComponents.scheduler_settings/1` for the settings form
  - Uses `EvoDashWeb.Layouts.app/1` layout with `current_page: :settings` for nav highlighting

- **`EvoDashWeb.HelpLive`** (`help_live.ex`) — Help & configuration page mounted at route `/help`.
  - Shows config status (ok/warning) with `EvoGit.Config.config_status/0`
  - Displays config file locations (config directory, config.toml, credentials.toml) with existence indicators
  - Provides an in-browser TOML editor for `config.toml` (edit/save/cancel workflow)
  - Validates TOML syntax before saving via `TomlElixir.decode/1`
  - Persists config changes via `EvoGit.Config.save_user_config/1`
  - Shows a configuration reference with example TOML values
  - Events handled: `edit_config`, `cancel_edit`, `config_text_change`, `save_config`
  - Uses `EvoDashWeb.Layouts.app/1` layout with `current_page: :help` for nav highlighting

### Templates
- **`agents_live.html.heex`** — Companion HEEx template for `AgentsLive` with a responsive sidebar (agent tree) + main panel (agent details) layout.

### Shared Conventions
- All LiveViews use `use EvoDashWeb, :live_view`
- Import `EvoDashWeb.CoreComponents` and `EvoDashWeb.Layouts`
- Styled with DaisyUI/Tailwind CSS classes
- All pages use `EvoDashWeb.Layouts.app/1` layout with `current_page` assign for navigation highlighting

## Constraints
- Each LiveView must be a single `.ex` file with an inline `render/1` callback **or** a companion `.html.heex` template — not both. (`DashboardLive`, `SettingsLive`, `HelpLive` render inline; `AgentsLive` uses a separate template.)
- LiveViews must not perform direct business logic; delegate to context modules (`TaskRegistry`, `AgentTree`, `AgentScheduler`, `Config`, etc.).
- Auto-refresh intervals should only be started in `connected?/1` checks to avoid leaking timers in disconnected renders.
- File naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
- Module naming: `EvoDashWeb.<Name>Live` matching the file name.
