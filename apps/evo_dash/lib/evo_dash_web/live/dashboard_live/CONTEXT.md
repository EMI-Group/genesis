# DashboardLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.DashboardLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (four module files: `state_persistence.ex`, `project.ex`, `project_flow.ex`, `assigns.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `StatePersistence` | Session persistence helpers (serialize/restore LiveView state to browser localStorage) |
| `Project` | Project-related pure functions (mode detection, path suggestions, config loading, model profiles) |
| `ProjectFlow` | Event handler implementations for project creation/opening (create_project, open_project, select_project, toggle_open_project_form, toggle_new_project_form) — extracted from DashboardLive (commit `b86ae86e`) |
| `Assigns` | Assign-building helpers (task categorization, form defaults) |

## Notes

- **Server-driven task-form layout**: The task-form layout (compact vs expanded) is computed server-side from prompt length via `TaskFormComponents.layout_for/1` (threshold 300 chars / 8 lines). `DashboardLive` tracks the prompt as the user types via the `task_prompt_change` event (`%{"prompt" => prompt}`, debounced 200ms) — required because the textarea is `phx-update="ignore"`, so the server's `@task_prompt` must mirror the visible text itself.
- **Post-submit prompt preservation**: After a successful `task_submit`, `assign_form_defaults/1` resets `task_prompt: ""` but the visible textarea keeps the submitted text — so `task_submit` re-assigns `:task_prompt` to the submitted prompt to keep the server-side layout in sync (side effect: the draft prompt now survives reloads via localStorage, intentional).

## Constraints

- All modules are pure functions — no I/O, no socket, no process calls (except `StatePersistence` which interacts with assigns/session).
- Follows the project-wide `try/rescue` anti-pattern policy.
