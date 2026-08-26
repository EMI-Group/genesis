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
| `Charts` | Pure SVG/ring-buffer helpers + chart-card components for the SystemLive scheduler-status charts (hand-rolled server-rendered SVG — no JS plotting lib; see the "System page charts (SVG, zero JS)" section in this file for full data semantics). Consumes the PRE-AGGREGATED sample maps broadcast by the evo_git system sampler DIRECTLY — the aggregation logic lives in the evo_git sampler (sample keys `llm_used, llm_waiting, tool_used, tool_waiting, llm_capacity, tool_capacity, agents_total, agents_running, agents_blocked, agents_waiting, agents_pending, scheduler_alive`). Pure functions: `push/2,3` (ring buffer, cap 60), `llm_series/1`/`tool_series/1`/`agents_series/1` (series builders with gettext names), `y_max/1` (max×1.2 headroom, floor 4), `y_for/2`, `path_for/2` + `pad_to_capacity/2` (SVG `d` strings, zero left-pad). Components (`use Phoenix.Component` + gettext + CoreComponents `icon`): `charts_section/1` (full section: header + paused badge + 3-card grid) and `chart_card/1` (legend + SVG sparkline, "Collecting data…" placeholder while `samples == []`) |
| `UpdateCard` | Software update card (auto-update UI, desktop+local-only): `active_task_ids/1` — the ONLY `EvoDash.NodeContext.list_task_ids/2` consumer in the dashboard (always LOCAL `node()`, `@active_statuses = [:running, :pending, :cancelling, :finalizing]`, id-only). See the `## Auto-Update card flows` section below |
| `SourceCard` | Genesis Source card (clone/update UI for the `EvoGit.SelfReflectiveSource` managed checkout, **local-only** — `visible?/1` = `node in [nil, node()]`; a remote `genesis_remote` daemon's self-reflective agent reads the REMOTE host's filesystem, so clone/update must never act remotely). Public spawn functions `spawn_status_load/3`, `spawn_clone/3`, `spawn_update/3` run on `EvoDash.TaskSupervisor` and self-message the LiveView (`{:source_status_loaded, seq, node, result}` / `{:source_clone_result, ...}` / `{:source_update_result, ...}`). Runners resolve from app-env seams AT SPAWN TIME: `:source_status_runner` (raw status map or `{:unavailable, reason}`), `:source_clone_runner` / `:source_update_runner` (`{:ok, status} | {:error, reason} | {:unavailable, reason}`). Default runners guard the backend with `Code.ensure_loaded?(EvoGit.SelfReflectiveSource)` and call it via `apply/3` (a direct call to the missing module would emit an "undefined function" compile warning) — absent backend → `{:unavailable, :module_missing}`; async-boundary rescue → `{:unavailable, :runner_error}`. Card markup + wiring: `system_live.ex` (events `clone_source` / `update_source`; assigns `source_card_visible`, `source_status`, `source_status_loading`, `source_busy`, `source_status_seq`) |

## Constraints

- The module contains pure functions — no I/O, no socket, no process calls. (`UpdateCard`/`SourceCard` are the exceptions: async spawn helpers that run on `EvoDash.TaskSupervisor`.)
- Follows the project-wide `try/rescue` anti-pattern policy — the ONLY rescue is at the async boundary in the `SourceCard` spawn functions (a crashing runner must not wedge the card's loading/busy state).
- The Genesis Source card is **local-only** by design: `SourceCard.visible?/1` returns `node in [nil, node()]`, so clone/update never act on a remote node (a remote daemon's self-reflective agent reads the remote host's filesystem).

## Notes for Agents — System self-check design (health banner + check grid)

The self-check section (System page) is a merged health banner + responsive 2D grid of check-term cells:

- **Overall health banner** (full-width, top of the self-check section, ALWAYS rendered — including during `:checking`, where it shows a neutral spinning "Checking system health..." state): derived by `Status.overall_health/1` from `health_checks/1` (private in `system_live.ex`) — a map of the five check assigns plus `sandbox_shown`/`nix_shown` flags mirroring the cell gating in the template. Returns `%{status: :ok | :warning | :error | :loading, reasons: [String.t()]}`:
  - `:loading` when any ALWAYS-critical assign (supervisor/config/tools) is nil — nil checks render neutral, never as errors.
  - `:error` when any critical check fails: process tree (`Status.supervisor_healthy?/1`), configuration (`Status.config_ok?/1`), tools (`Status.tools_status/1 != :ok`), or sandbox (`Status.sandbox_status/1 != :ok` **only when `sandbox_shown`**).
  - `:warning` when only non-critical issues exist: nix enabled-but-not-built (`Status.nix_status/1 != :ok`, **only when `nix_shown`**) — deliberately NOT a hard failure (nix is optional).
  - `reasons` are gettext-wrapped human-readable strings ("Required settings are missing or invalid", "A required tool (git or ripgrep) is missing", "Sandbox is unavailable", …) rendered as a bullet list under the banner headline ("System running correctly" / "System needs attention" / "System running, but needs attention").
  - `@config_status` carries the remote config status on a remote node, so the banner needs no extra RPC.
- **Check grid**: `div.grid.grid-cols-1.md:grid-cols-2.gap-3` with one `check_cell/1` per term: Configuration, Required Tools, Sandbox (gated `EvoDashWeb.PlatformInfo.show_sandbox?(@platform_os)`), Nix Environment (gated `@nix_check != nil and enabled and available`), LLM Connection (info status, `~p"/settings?category=llm&node=…"` link).
- **DOM contract (AUTHORITATIVE — do not deviate)**: check cells do NOT emit `<details>`/`<summary>` — the header is a plain `<div class="flex items-center gap-3 p-4">`, and the detail + `:fix` slot are always rendered (fix gated `@status not in [:ok, :info] and @fix != []`). Do NOT re-add a disclosure.
- **Test markers**: title spans render exactly as `<span class="font-semibold text-sm">{title}</span>` so `>Sandbox</span>` / `>Nix Environment</span>` markers match; "flake.nix"/"Flake valid"/"hero-lock-closed"/"sandbox-exec (macOS)"/"bwrap (Linux)" detail strings are unchanged. `Status.format_backend/1` maps `:bwrap` → "bwrap (Linux)" (badge `badge-success` in the check grid); `Status.sandbox_status/1` treats bwrap with `capabilities.filesystem_isolation` as `:ok`.
- **Supervisor health feeds ONLY the merged banner**: there is no "Genesis Process Tree" row and no `supervisor_status/1` component.
- **`~p` gotcha**: interpolating into the PATH portion of a static route (`~p"/settings#{…}"`) emits a compile-time "no route path" warning (test_path materializes the interpolation as `"1"` → `/settings1`); use `with_node_param/2` (appends `?node=` — only safe for query-less URLs) or interpolate in the query portion only.

## System page charts (SVG, zero JS)

- Hand-rolled server-rendered SVG — ZERO JS dependencies (the vendored asset set is fixed; do not add JS/CSS for charts).
- `EvoDashWeb.SystemLive.Charts`: `push/2,3` (ring buffer, cap 60), `llm_series/1`/`tool_series/1`/`agents_series/1` (series builders with gettext names), `y_max/1` (max×1.2 headroom, floor 4), `y_for/2`, `path_for/2` + `pad_to_capacity/2` (SVG `d` strings, zero left-pad). Components (`use Phoenix.Component` + gettext + CoreComponents `icon`): `charts_section/1` (header + paused badge + 3-card grid) and `chart_card/1` (legend + SVG sparkline, "Collecting data…" placeholder while `samples == []`). Markup: `<svg viewBox="0 0 300 100" preserveAspectRatio="none">` + `vector-effect="non-scaling-stroke"`; the Capacity series renders as a `static: true` dashed horizontal line.
- **Consumes the PRE-AGGREGATED sample maps broadcast by the evo_git system sampler DIRECTLY** — the aggregation logic lives in the evo_git sampler, NOT here. Sample keys: `llm_used, llm_waiting, tool_used, tool_waiting, llm_capacity, tool_capacity, agents_total, agents_running, agents_blocked, agents_waiting, agents_pending, scheduler_alive`.
- **Push contract**: `{:system_sample, node, seq, sample}` every 3s from a node-side sampler. **Seed**: on mount/node-switch ONE async `EvoDash.NodeContext.get_recent_system_samples(current_node)` runs via `EvoDash.TaskSupervisor` + self-message `{:system_samples_seeded, seq, node, result}` + stale-guard (monotonic `chart_seed_seq` + node); on error ONE retry after 3s (one-shot, gated by `chart_seed_retried` — NOT periodic); on node switch the buffer is cleared + re-seeded. The `:system_samples_runner` app-env test seam is resolved AT SPAWN TIME. `{:scheduler_config_updated, node}` → `spawn_paused_load/1`. Remote nodes: pure PubSub (samples arrive via the cluster).

## Async node-aware loads on System page

- `spawn_node_loads/1` spawns TWO `EvoDash.TaskSupervisor` tasks: `spawn_paused_load/1` → `{:paused_state, node, paused}` (gated by `scheduler_alive?/1`) and `PlatformInfo.os_for_node(node)` → `{:platform_os_result, node, os}`.
- Both `handle_info` clauses are stale-guarded on `socket.assigns.current_node == node`.
- Mount defaults: `scheduler_paused: false`; `platform_os` takes the local fast-path only (`current_node in [nil, node()]` → synchronous `os_for_node` call, preserving the `:platform_os_override` test seam).
- Test idiom: `await_view_assign(view, key, value)`.

## Genesis Source card detail

- Local-only (`SourceCard.visible?/1` = `node in [nil, node()]`); a remote daemon's self-reflective agent reads the REMOTE host's filesystem, so clone/update must never act remotely.
- Guarded backend: `Code.ensure_loaded?(EvoGit.SelfReflectiveSource)` + `apply/3` (a direct call to the missing module emits an "undefined function" compile warning) — absent backend → `{:unavailable, :module_missing}`; async-boundary rescue → `{:unavailable, :runner_error}`.
- Seams resolved at spawn: `:source_status_runner` (raw status map or `{:unavailable, reason}`), `:source_clone_runner` / `:source_update_runner` (`{:ok, status} | {:error, reason} | {:unavailable, reason}`).
- Status map contract: `%{dir:, exists:, is_git_repo:, valid:, commit:, branch:, version:, remote_url:, reference:, is_reference:}`.

## SystemLive platform gating (EvoDashWeb.PlatformInfo)

- Sandbox self-check **cell** wrapped in `if PlatformInfo.show_sandbox?(@platform_os)` (no "Not Available"/"Disabled" messaging on Windows/unknown); Nix Environment **cell** wrapped in `if @nix_check != nil and @nix_check.enabled and @nix_check.available` (nix hidden when disabled in config OR binary not found — `EvoGit.Nix.enabled?/0` + `EvoGit.Platform.nix_available?/0`).
- `platform_os` assigned in mount + handle_params (after `assign_node/2`). `safe_system_checks/1` — checks run on the LOCAL VM; only the config status is fetched remotely. The same gating predicates drive the health-banner aggregation via `health_checks/1`.
