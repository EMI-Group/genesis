# DashboardLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.DashboardLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (three module files: `state_persistence.ex`, `project.ex`, `assigns.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `StatePersistence` | Session persistence helpers (serialize/restore LiveView state to browser localStorage) |
| `Project` | Project-related pure functions (mode detection, path suggestions, config loading, model profiles) |
| `Assigns` | Assign-building helpers (task categorization, form defaults) |

## Constraints

- All modules are pure functions — no I/O, no socket, no process calls (except `StatePersistence` which interacts with assigns/session).
- Follows the project-wide `try/rescue` anti-pattern policy.
