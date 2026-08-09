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
| `ProjectFlow` | Event handler implementations for project creation/opening (create_project, open_project, select_project) — extracted from DashboardLive (commit `b86ae86e`). The old `toggle_open_project_form`/`toggle_new_project_form` handlers were removed when the address bar was replaced by the command palette. |
| `Assigns` | Assign-building helpers (task categorization, form defaults) |

## Notes

- **Task-form layout — server-seeded + client-driven**: The task-form layout (compact vs expanded) is seeded server-side at render from prompt length via `TaskFormComponents.layout_for/1` (threshold > 600 graphemes OR > 16 lines) and updated client-side while typing by the AdaptiveInput JS hook (mirrors the same thresholds). There is no per-keystroke prompt-change event — the textarea has no `phx-change`, so `@task_prompt` is updated only by `restore_state` and `task_submit` (single, non-keystroke events). Prompt draft persistence is purely client-side (the StatePersistence input watcher in app.js).
- **Post-submit prompt preservation**: After a successful `task_submit`, `assign_form_defaults/1` resets `task_prompt: ""` but the visible textarea keeps the submitted text — so `task_submit` re-assigns `:task_prompt` to the submitted prompt to keep the server-seeded layout in sync (side effect: the draft prompt now survives reloads via localStorage, intentional).

## Constraints

- All modules are pure functions — no I/O, no socket, no process calls (except `StatePersistence` which interacts with assigns/session).
- Follows the project-wide `try/rescue` anti-pattern policy.
