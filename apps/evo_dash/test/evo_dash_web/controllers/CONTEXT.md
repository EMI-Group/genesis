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
| `task_export_controller_test.exs` | `EvoDashWeb.TaskExportControllerTest` | 203 | 7 | `async: false` (explicit — mutates the process-global `XDG_CONFIG_HOME`) |
| `page_controller_test.exs` | `EvoDashWeb.PageControllerTest` | 101 | 3 | `async: false` (ConnCase default — NO `async:` option is passed; same `XDG_CONFIG_HOME` mutation) |
| `error_html_test.exs` | `EvoDashWeb.ErrorHTMLTest` | 14 | 2 | `async: true` |
| `error_json_test.exs` | `EvoDashWeb.ErrorJSONTest` | 12 | 2 | `async: true` |

All four use `EvoDashWeb.ConnCase`; none mounts a LiveView through `live/3` (pure HTTP requests + `render_to_string/4` / `render_component`).

## Notes for Agents — concurrency / async-flip facts

- **Cross-check the `async:` flag before assuming it**: `page_controller_test.exs` passes NO `async:` option, so it is `async: false` by ExUnit default (it seeds/writes the shared `EvoDash.ActiveTasks` hub at lines 66-98, which is why it must stay serialized).
- `task_export_controller_test.exs` does NOT isolate the Store/TaskRegistry (lines 168-190): `seed_completed_task/1` writes into the PRODUCTION `EvoGit.Store` (line 185, unique `export_test_<int>` ids) and `on_exit` deletes the row via `TaskRegistry.delete_task/1` + a `TaskRegistry.list_tasks()` cast-sync (lines 187-196); the comment's rationale is that a leaked row breaks `evo_git`'s task-list tests, because both apps' `test_helper.exs` redirect `XDG_DATA_HOME` to the SAME `System.tmp_dir!()/evogit_test_data` SQLite database.
- The three tests in `describe "...with ?node= param"` replace the process-wide `XDG_CONFIG_HOME` with a unique temp dir (lines 96-123) so `EvoGit.RemoteConnections` (a pure-function TOML module reading `EvoGit.Config.config_dir/0`) never touches the developer's real `~/.config/genesis`; restored in `on_exit`.
- The export controller resolves local tasks through the hardcoded global `EvoGit.TaskRegistry.get_task/1` (controller lines 50-56) — there is NO injection seam, so the suite cannot be made store-isolated without a core change.
- `task_export_controller_test.exs` is `async: false` **because of the env mutation, not the Store**: `XDG_CONFIG_HOME` is process-global and is the only config-dir seam (`EvoGit.Config.config_dir/0` → `Path.join(EvoGit.Platform.config_dir("genesis"))`; no `Application.get_env` override exists), so an async module reading config concurrently could observe this suite's temp dir instead of the real one. Its Store writes alone would be flip-safe (uniquely-id'd `export_test_*` rows + unconditional `on_exit` cleanup) — the `?node=` describe's `XDG_CONFIG_HOME` save/restore is what forces sync, exactly like `page_controller_test` / `node_context_test`. The other async ConnCase users here (`error_html_test` / `error_json_test`) are pure render tests.
