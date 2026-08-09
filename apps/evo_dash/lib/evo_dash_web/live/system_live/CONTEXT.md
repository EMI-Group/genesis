# SystemLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SystemLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (two module files: `status.ex`, `charts.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `Status` | Status-checking pure functions that derive overall status (`:ok`/`:error`/`:info`/`:warning`/`:loading`) from system-check result maps, plus backend name and config item label formatting. Includes `overall_health/1` — the merged system-health derivation for the self-check health banner: takes the per-check maps plus `sandbox_shown`/`nix_shown` flags and returns `%{status: :ok \| :warning \| :error \| :loading, reasons: [String.t()]}` with gettext-wrapped, human-readable failure reasons (`:loading` while any critical assign is nil; sandbox/nix only count when their cells are actually rendered) |
| `Charts` | Pure SVG/ring-buffer helpers + chart-card components for the SystemLive scheduler-status charts (hand-rolled server-rendered SVG — no JS plotting lib; see the parent `live/CONTEXT.md` "Notes for Agents — System page charts" for full data semantics). Pure functions: `push/2,3` (ring buffer, cap 60), `build_sample/2` + `status_counts/1` (agents → sample map; "used" = `:running` count proxy, "waiting" = `:blocked`), `config_totals/1` (config → `%{llm_capacity, tool_capacity}`), `llm_series/1`/`tool_series/1`/`agents_series/1` (series builders with gettext names), `y_max/1` (max×1.2 headroom, floor 4), `path_for/2` + `pad_to_capacity/2` (SVG `d` strings, zero left-pad). Components (`use Phoenix.Component` + gettext + CoreComponents `icon`): `charts_section/1` (full section: header + paused badge + 3-card grid) and `chart_card/1` (legend + SVG sparkline, "Collecting data…" placeholder while `samples == []`) |

## Constraints

- The module contains pure functions — no I/O, no socket, no process calls.
- Follows the project-wide `try/rescue` anti-pattern policy.
