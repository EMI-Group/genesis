# SystemLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SystemLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (one module file: `status.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `Status` | Status-checking pure functions that derive overall status (`:ok`/`:error`/`:info`/`:warning`) from system-check result maps, plus backend name and config item label formatting |

## Constraints

- The module contains pure functions — no I/O, no socket, no process calls.
- Follows the project-wide `try/rescue` anti-pattern policy.
