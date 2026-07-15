# SystemLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SystemLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Modules

- `Content` — Static content helpers: example configuration, credentials, and usage reference strings (with path interpolation) and the runtime-built FAQ content list
- `Status` — Status-checking pure functions that derive overall status (`:ok`/`:error`/`:info`/`:warning`) from system-check result maps, plus backend name and config item label formatting
