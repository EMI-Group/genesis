# Controllers Tests (`apps/evo_dash/test/evo_dash_web/controllers`)

## Intent

ExUnit suites for the classic (non-LiveView) HTTP controllers and error templates of `EvoDashWeb`: the task-archive JSON export endpoint and the router/error responses.
Leaf node — all four suites live directly here, none of them calls `live/3` (pure HTTP requests plus `render_to_string/4`).

## Routing Table

- Self-contained leaf node; no child directories.
- Export endpoint under test: `apps/evo_dash/lib/evo_dash_web/controllers/task_export_controller.ex`.
- Shared `EvoDashWeb.ConnCase` (built conn, verified routes, `ActiveTasks` hub reset) → `../../support/conn_case.ex`, detail → `apps/evo_dash/test/CONTEXT.md`.

## API Surface

| File | Module | Lines | Tests | async |
|------|--------|-------|-------|-------|
| `task_export_controller_test.exs` | `EvoDashWeb.TaskExportControllerTest` | 489 | 11 | `async: false` (explicit — mutates the process-global `XDG_CONFIG_HOME` plus two app-env seams; carries `@moduletag :capture_log`) |
| `page_controller_test.exs` | `EvoDashWeb.PageControllerTest` | 96 | 2 | `async: false` (ConnCase default — NO `async:` option is passed; same `XDG_CONFIG_HOME` mutation) |
| `error_html_test.exs` | `EvoDashWeb.ErrorHTMLTest` | 14 | 2 | `async: true` |
| `error_json_test.exs` | `EvoDashWeb.ErrorJSONTest` | 12 | 2 | `async: true` |
| `health_controller_test.exs` | `EvoDashWeb.HealthControllerTest` | 34 | 3 | `async: true` |

## `task_export_controller_test.exs`

Two describes: `GET /tasks/:task_id/export` (8 tests) and `... with ?node= param` (3 tests).

- **Seams, not the Store**: the suite writes NOTHING to the task store. Both reads are injected through module-level app-env seams restored in `on_exit` — `:task_export_task_runner` (2-arity `fn node, task_id -> TaskInfo.t() | nil end`) and `:task_export_archive_runner` (3-arity `fn node, task_id, opts -> %{entries: [...], total: n} end`) — so it needs no `EvoDash.Test.IsolatedTaskStore` and cannot leak rows into `evo_git`'s task-list tests.
- **Coverage (main describe)**: the flat envelope (head fields + `archive_records`, export-only settings columns shipped verbatim); paging order with `offset` 0 → 200, `limit: 200`, `include_results: true`, `include_settings: true` asserted on EVERY page plus `:include_total` asserted ABSENT (the count default is what stops the loop); the three paging stops (reported `total`, a short page, an empty page); `normalize_for_json/1` on non-JSON record terms; a failing page mid-pagination (truncated but valid 200 document); a failing FIRST page or an unexpected page shape (→ empty-archive 404); an unencodable record or head field (500, no temp file left behind); and the 404 paths (missing task, no archive data, no archive read at all for the missing-task case).
- **`?node=` describe**: unknown node id → 404 WITHOUT calling either runner; a saved-but-disconnected target → 404 likewise; a connected target (suite-local fake `ConnectionManager` registered in `EvoGit.RemoteConnection.Registry`) → both runners receive the remote node atom; `?node=local` → the local path.
- `async: false` is required by the env mutation and the app-env seams, not by the Store: `XDG_CONFIG_HOME` is process-global and is the ONLY config-dir seam (`EvoGit.Config.config_dir/0` derives the path from it), and the runner seams live in the shared `:evo_dash` app env.

## `page_controller_test.exs`

`async: false` by ConnCase default (no `async:` option) because it isolates `XDG_CONFIG_HOME` and writes the shared `EvoDash.ActiveTasks` hub.
- Setup points `XDG_CONFIG_HOME` at a per-test temp dir and calls `EvoGit.Config.VersionState.complete_onboarding/0` so `/` and `/help` render instead of redirecting to `/welcome`.
- Test 1: `GET /` renders ProjectsLive (palette + `AdaptiveInput`, no `chat-form`) and `GET /help` renders HomeLive (`#chat-form`, "Chat with Genesis").
- Test 2: a whole-page render survives malformed `EvoDash.ActiveTasks` hub entries (`:junk_atom`, a bare binary) — the mount hook's `hub_snapshot/2` sanitizes them, so `Layouts.group_tasks_by_project/2` cannot `BadMapError`; the test clears the shared hub before AND after itself.

## `error_html_test.exs` / `error_json_test.exs`

Pure render tests (`async: true`, no store, no env): the 404 and 500 templates for both formats via `render_to_string/4`.

## `health_controller_test.exs`

`async: true`, pure HTTP: `GET /health` answers `200` `application/json` with `"status" == "ok"`, a non-empty `"version"` (pinned to `Application.spec(:evo_dash, :vsn)`), and a non-negative integer `"uptime_ms"`; a bare connection with no session/cookies is enough and the probe never redirects (`conn.state == :sent`).
