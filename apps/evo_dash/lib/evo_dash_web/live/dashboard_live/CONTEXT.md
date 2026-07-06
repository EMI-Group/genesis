# DashboardLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.DashboardLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Modules

- `StatePersistence` — Session persistence helpers (serialize/restore LiveView state to browser localStorage)
- `Project` — Project-related pure functions (mode detection, path suggestions, config loading, model profiles)
- `Assigns` — Assign-building helpers (task categorization, form defaults)
