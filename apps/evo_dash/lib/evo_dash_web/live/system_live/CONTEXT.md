# SystemLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SystemLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (four module files: `status.ex`, `charts.ex`, `update_card.ex`, `source_card.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `Status` | Status-checking pure functions that derive overall status (`:ok`/`:error`/`:info`/`:warning`/`:loading`) from system-check result maps, plus backend name and config item label formatting. Includes `overall_health/1` — the merged system-health derivation for the self-check health banner: takes the per-check maps plus `sandbox_shown`/`nix_shown` flags and returns `%{status: :ok \| :warning \| :error \| :loading, reasons: [String.t()]}` with gettext-wrapped, human-readable failure reasons (`:loading` while any critical assign is nil; sandbox/nix only count when their cells are actually rendered) |
| `Charts` | Pure SVG/ring-buffer helpers + chart-card components for the SystemLive scheduler-status charts (hand-rolled server-rendered SVG — no JS plotting lib; see the parent `live/CONTEXT.md` "Notes for Agents — System page charts" for full data semantics). Consumes the PRE-AGGREGATED sample maps broadcast by the evo_git system sampler DIRECTLY (sample keys `llm_used, llm_waiting, tool_used, tool_waiting, llm_capacity, tool_capacity, agents_total, agents_running, agents_blocked, agents_waiting, agents_pending, scheduler_alive` — the old `build_sample/2`/`status_counts/1`/`config_totals/1` aggregations were deleted; that logic lives in the evo_git sampler). Pure functions: `push/2,3` (ring buffer, cap 60), `llm_series/1`/`tool_series/1`/`agents_series/1` (series builders with gettext names), `y_max/1` (max×1.2 headroom, floor 4), `y_for/2`, `path_for/2` + `pad_to_capacity/2` (SVG `d` strings, zero left-pad). Components (`use Phoenix.Component` + gettext + CoreComponents `icon`): `charts_section/1` (full section: header + paused badge + 3-card grid) and `chart_card/1` (legend + SVG sparkline, "Collecting data…" placeholder while `samples == []`) |
| `UpdateCard` | Software update card (auto-update UI, desktop+local-only): `active_task_ids/1` — the ONLY `EvoDash.NodeContext.list_task_ids/2` consumer in the dashboard (always LOCAL `node()`, `@active_statuses = [:running, :pending, :cancelling, :finalizing]`, id-only). See the Auto-Update section in `apps/evo_dash/CONTEXT.md` |
| `SourceCard` | Genesis Source card (clone/update UI for the `EvoGit.SelfReflectiveSource` managed checkout, **local-only** — `visible?/1` = `node in [nil, node()]`; a remote `genesis_remote` daemon's self-reflective agent reads the REMOTE host's filesystem, so clone/update must never act remotely). Public spawn functions `spawn_status_load/3`, `spawn_clone/3`, `spawn_update/3` run on `EvoDash.TaskSupervisor` and self-message the LiveView (`{:source_status_loaded, seq, node, result}` / `{:source_clone_result, ...}` / `{:source_update_result, ...}`). Runners resolve from app-env seams AT SPAWN TIME: `:source_status_runner` (raw status map or `{:unavailable, reason}`), `:source_clone_runner` / `:source_update_runner` (`{:ok, status} | {:error, reason} | {:unavailable, reason}`). Default runners guard the backend with `Code.ensure_loaded?(EvoGit.SelfReflectiveSource)` and call it via `apply/3` (a direct call to the missing module would emit an "undefined function" compile warning) — absent backend → `{:unavailable, :module_missing}`; async-boundary rescue → `{:unavailable, :runner_error}`. Card markup + wiring: `system_live.ex` (events `clone_source` / `update_source`; assigns `source_card_visible`, `source_status`, `source_status_loading`, `source_busy`, `source_status_seq`) |

## Constraints

- The module contains pure functions — no I/O, no socket, no process calls. (`UpdateCard`/`SourceCard` are the exceptions: async spawn helpers that run on `EvoDash.TaskSupervisor`.)
- Follows the project-wide `try/rescue` anti-pattern policy — the ONLY rescue is at the async boundary in the `SourceCard` spawn functions (a crashing runner must not wedge the card's loading/busy state).
- The Genesis Source card is **local-only** by design: `SourceCard.visible?/1` returns `node in [nil, node()]`, so clone/update never act on a remote node (a remote daemon's self-reflective agent reads the remote host's filesystem).
