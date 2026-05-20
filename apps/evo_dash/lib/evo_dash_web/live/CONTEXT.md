# LiveView Pages

## Intent
Contains Phoenix LiveView modules and templates that form the interactive UI layer of the EvoDash dashboard. These pages provide real-time task management and agent inspection capabilities for the EvoGit evolutionary software development system.

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

### Templates
- **`agents_live.html.heex`** — Companion HEEx template for `AgentsLive` with a responsive sidebar (agent tree) + main panel (agent details) layout.

### Shared Conventions
- Both LiveViews use `use EvoDashWeb, :live_view`
- Import `EvoDashWeb.CoreComponents` and `EvoDashWeb.Layouts`
- Styled with DaisyUI/Tailwind CSS classes

## Routing Table

This directory has no child subdirectories — all work is handled by the individual LiveView files within this directory (`dashboard_live.ex`, `agents_live.ex`) and their companion templates. For any changes to LiveView pages or their templates, work directly on the relevant file in this node; no subagent delegation to child paths is needed.

## Constraints
- Each LiveView must be a single `.ex` file with an inline `render/1` callback **or** a companion `.html.heex` template — not both. (`DashboardLive` renders inline; `AgentsLive` uses a separate template.)
- LiveViews must not perform direct business logic; delegate to context modules (`TaskRegistry`, `AgentTree`, etc.).
- Auto-refresh intervals should only be started in `connected?/1` checks to avoid leaking timers in disconnected renders.
- File naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
- Module naming: `EvoDashWeb.<Name>Live` matching the file name.
