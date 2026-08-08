# DashboardLive Support Modules (mostly retired)

## Intent

Only `project.ex` (`EvoDashWeb.DashboardLive.Project`) remains here:
project-related pure functions (mode detection, path suggestions, config
loading, model profiles, foreign-repo loading) that **`HomeLive` depends
on** (`detect_mode/path_suggestions/load_model_profiles/load_foreign_repos`).

The rest of the classic dashboard interface is **RETIRED** (the pad shell
is now the single global chrome for every page). Archived OUTSIDE the repo
at `evox/tmp/original-interface/` (preserving `apps/evo_dash/...` relative
paths): `live/dashboard_live.ex`, `live/dashboard_live/assigns.ex`,
`live/dashboard_live/project_flow.ex`, `live/dashboard_live/state_persistence.ex`,
and `test/evo_dash_web/live/dashboard_live_test.exs`. The `/classic` and
`/dashboard` routes were removed from the router (Phoenix LiveDashboard
stays at `/phoenix/dashboard`).

## Routing Table

None — leaf directory (one module file: `project.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `Project` | Project-related pure functions (mode detection, path suggestions, config loading, model profiles) — used by `HomeLive` |

## Constraints

- All modules are pure functions — no I/O, no socket, no process calls.
- Follows the project-wide `try/rescue` anti-pattern policy.
