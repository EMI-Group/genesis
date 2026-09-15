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
| `task_export_controller_test.exs` | `EvoDashWeb.TaskExportControllerTest` | 195 (194 newline-terminated) | 7 | `async: false` (explicit, line 2) |
| `page_controller_test.exs` | `EvoDashWeb.PageControllerTest` | 101 | 3 | `async: false` (ConnCase default — NO `async:` option is passed) |
| `error_html_test.exs` | `EvoDashWeb.ErrorHTMLTest` | 15 | 2 | `async: true` |
| `error_json_test.exs` | `EvoDashWeb.ErrorJSONTest` | 12 | 2 | `async: true` |

All four use `EvoDashWeb.ConnCase`; none mounts a LiveView through `live/3` (pure HTTP requests + `render_to_string/4` / `render_component`).

## Notes for Agents — concurrency / async-flip facts

- **Cross-check the `async:` flag before assuming it**: `page_controller_test.exs` passes NO `async:` option, so it is `async: false` by ExUnit default (it seeds/writes the shared `EvoDash.ActiveTasks` hub at lines 66-98, which is why it must stay serialized).
- `task_export_controller_test.exs` does NOT isolate the Store/TaskRegistry (lines 158-164): `seed_completed_task/1` writes into the PRODUCTION `EvoGit.Store` (line 182, unique `export_test_<int>` ids) and `on_exit` deletes the row via `TaskRegistry.delete_task/1` + a `TaskRegistry.list_tasks()` cast-sync (lines 184-193); the comment's rationale is that a leaked row breaks `evo_git`'s task-list tests, because both apps' `test_helper.exs` redirect `XDG_DATA_HOME` to the SAME `System.tmp_dir!()/evogit_test_data` SQLite database.
- The two tests in `describe "...with ?node= param"` replace the process-wide `XDG_CONFIG_HOME` with a unique temp dir (lines 97-120) so `EvoGit.RemoteConnections` (a pure-function TOML module reading `EvoGit.Config.config_dir/0`) never touches the developer's real `~/.config/genesis`; restored in `on_exit`.
- The export controller resolves local tasks through the hardcoded global `EvoGit.TaskRegistry.get_task/1` (controller lines 50-56) — there is NO injection seam, so the suite cannot be made store-isolated without a core change.
- Async-safety invariant observed by the whole suite as of this audit: no `async: true` module under `apps/evo_dash/test/` reads or writes `EvoGit.Store`/`EvoGit.TaskRegistry`, `EvoGit.Config`/`EvoGit.RemoteConnections`, or `System.put_env("XDG_CONFIG_HOME", ...)` — those global touch points live exclusively in `async: false` modules, which ExUnit never runs concurrently with `async: true` ones.
