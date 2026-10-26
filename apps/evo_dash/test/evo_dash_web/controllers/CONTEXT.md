# Controllers Tests (`apps/evo_dash/test/evo_dash_web/controllers`)

## Intent

Test suites for the classic (non-LiveView) HTTP controllers and error templates of `EvoDashWeb`: the task-archive JSON export endpoint and the router/error responses.

## Routing Table

- Self-contained leaf node — all four suites live directly in this directory; no child directories.
- Export endpoint under test: `apps/evo_dash/lib/evo_dash_web/controllers/task_export_controller.ex` (detail → `apps/evo_dash/CONTEXT.md`).
- Shared `EvoDashWeb.ConnCase` (ActiveTasks hub reset + verified routes + built conn) → `../support/conn_case.ex` (detail → `apps/evo_dash/test/CONTEXT.md`).

## API Surface

| File | Module | Lines | Tests | async |
|------|--------|-------|-------|-------|
| `task_export_controller_test.exs` | `EvoDashWeb.TaskExportControllerTest` | 492 | 15 | `async: false` (explicit — mutates the process-global `XDG_CONFIG_HOME` + the two export runner seams) |
| `page_controller_test.exs` | `EvoDashWeb.PageControllerTest` | 101 | 3 | `async: false` (ConnCase default — NO `async:` option is passed; same `XDG_CONFIG_HOME` mutation) |
| `error_html_test.exs` | `EvoDashWeb.ErrorHTMLTest` | 14 | 2 | `async: true` |
| `error_json_test.exs` | `EvoDashWeb.ErrorJSONTest` | 12 | 2 | `async: true` |

All four use `EvoDashWeb.ConnCase`; none mounts a LiveView through `live/3` (pure HTTP requests + `render_to_string/4` / `render_component`).

## Notes for Agents — concurrency / async-flip facts

- **Cross-check the `async:` flag before assuming it**: `page_controller_test.exs` passes NO `async:` option, so it is `async: false` by ExUnit default (it seeds/writes the shared `EvoDash.ActiveTasks` hub at lines 66-98, which is why it must stay serialized).
- `task_export_controller_test.exs` writes NOTHING to the Store: both reads are injected through the module-level seams `:task_export_task_runner` (2-arity `fn node, task_id -> end`) and `:task_export_archive_runner` (3-arity `fn node, task_id, opts -> end`) — restored in `on_exit` — so the suite runs without `EvoDash.Test.IsolatedTaskStore` and cannot leak rows into `evo_git`'s task-list tests.
- Coverage: the flat envelope (head fields + `archive_records`), paging order/`include_results: true, include_settings: true, limit: 200` per page (both projections asserted on EVERY page, and `:include_total` asserted absent so the count default holds), stopping at the reported `total`, `normalize_for_json/1` on records, a failed page mid-pagination (truncated but valid document + warning), a failed FIRST page (empty archive → 404), an unexpected page shape (paging stops), an unencodable record/head field (500 + no temp file left behind), and the 404 paths (missing task, no archive data).
- The four tests in `describe "...with ?node= param"` replace the process-wide `XDG_CONFIG_HOME` with a unique temp dir (so `EvoGit.RemoteConnections.save/1` never touches the developer's real `~/.config/genesis`) and restore it in `on_exit`; they pin unknown node → 404 WITHOUT calling either runner, a known-but-disconnected target → 404, a connected target → both runners receive the remote node atom, and `?node=local` → the local path.
- `task_export_controller_test.exs` is `async: false` **because of the env mutation and the app-env seams, not the Store**: `XDG_CONFIG_HOME` is process-global and is the only config-dir seam (`EvoGit.Config.config_dir/0` → `Path.join(EvoGit.Platform.config_dir("genesis"))`; no `Application.get_env` override exists), and the runner seams live in the shared `:evo_dash` app env — so an async module could observe this suite's temp dir or runner. The other async ConnCase users here (`error_html_test` / `error_json_test`) are pure render tests.
