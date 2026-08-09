# SystemLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SystemLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (one module file: `status.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `Status` | Status-checking pure functions that derive overall status (`:ok`/`:error`/`:info`/`:warning`/`:loading`) from system-check result maps, plus backend name and config item label formatting. Includes `overall_health/1` — the merged system-health derivation for the self-check health banner: takes the per-check maps plus `sandbox_shown`/`nix_shown` flags and returns `%{status: :ok \| :warning \| :error \| :loading, reasons: [String.t()]}` with gettext-wrapped, human-readable failure reasons (`:loading` while any critical assign is nil; sandbox/nix only count when their cells are actually rendered) |

## Constraints

- The module contains pure functions — no I/O, no socket, no process calls.
- Follows the project-wide `try/rescue` anti-pattern policy.
