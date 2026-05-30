# LiveView Pages

## Intent
Phoenix LiveView modules and templates for the EvoDash interactive UI — real-time task management, agent inspection, runtime configuration, and user help.

## API Surface

| Module | Route | Summary |
|--------|-------|---------|
| `DashboardLive` | `GET /` | Project-based task dashboard with genesis/evolve forms, auto-mode detection, real-time task cards, and project tabs. Delegates to `TaskRegistry` and `DashboardComponents`. |
| `AgentsLive` | `GET /agents` | Recursive agent tree inspector with selectable agent detail panel. Reads from ETS tables, auto-refreshes every 500ms. Uses `AgentsComponents.agent_tree/1`. |
| `SettingsLive` | `GET /settings` | Runtime scheduler configuration (concurrency, retries, depth, LLM model). Shows config status warnings. Updates via `AgentScheduler.update_config/1`. Auto-refreshes every 2s. |
| `HelpLive` | `GET /help` | Configuration file manager with in-browser TOML editor, syntax validation, and save via `Config.save_user_config/1`. Shows config file paths and reference values. |

### Templates
- **`agents_live.html.heex`** — Companion template for `AgentsLive` with sidebar tree + detail panel layout.

### Shared Conventions
- All LiveViews use `use EvoDashWeb, :live_view` and import `CoreComponents` and `Layouts`.
- All pages use `EvoDashWeb.Layouts.app/1` layout with `current_page` for nav highlighting.
- Styled with DaisyUI/Tailwind CSS; business logic delegated to context modules.

## Constraints
- Each LiveView uses either an inline `render/1` or a companion `.html.heex` template — not both. (Three render inline; `AgentsLive` uses a separate template.)
- Auto-refresh intervals must be gated behind `connected?/1` to avoid leaking timers.
- Naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
