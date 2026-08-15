# Test Directory — EvoDashWeb Live Tests

## Intent

ExUnit test files for the EvoDash LiveView pages and their support modules. Mirrors `apps/evo_dash/lib/evo_dash_web/live/` under `apps/evo_dash/test/evo_dash_web/live/`.

## Routing Table

- `./projects_live_test.exs` → Comprehensive `ProjectsLive` dashboard suite (~2200 lines; project form/palette/settings, task notifications, remote-node contexts via the fake `EvoDashWeb.ProjectsLiveTest.ConnectionManager` in `EvoGit.RemoteConnection.Registry`, directory picker, file attach, cross-OS remote path handling)
- `./projects_live/` → Pure unit tests for `ProjectsLive` support modules (`project_flow_test.exs` — path normalization incl. `normalize_remote_project_path/2`, `absolute_path_for_node?/2`, and the `path_suggestions/2,3` node-aware recents filter; `dirty_tracker`-style modules live here)
- `./settings_live_test.exs` → Settings page (search, custom model providers, whitelist safety)
- `./tasks_live_test.exs` → Cross-project task list (search/filter, cancellation modals, `:cancelling` display, remote poll smoke)
- `./review_live_test.exs` → Review page (missing-task error, ignore action)
- `./welcome_live_test.exs`, `./welcome_complete_live_test.exs` → Onboarding pages
- `./system_live_test.exs`, `./agents_live_test.exs`, `./error_html_test.exs`, `./error_json_test.exs` → System page, agent tree, error templates

## Notes for Agents

- **Remote-node test pattern** (used by the cross-OS path tests): save a unique target via `EvoGit.RemoteConnections.save/1` under per-test isolated `XDG_CONFIG_HOME`, then `start_supervised!` a fake `ConnectionManager` GenServer registered in `EvoGit.RemoteConnection.Registry` with `%{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}`. `:erpc` calls to the fake node fail fast, so RPC-dependent remote success paths (e.g. `NodeContext.dir?/1` → true) are unreachable in tests — only the validation/degradation branches are covered end-to-end.
- **`normalize_remote_project_path/2` tilde seam**: `Application.get_env(:evo_dash, :remote_path_expand_runner)` is read at CALL time; tests inject fakes with `Application.put_env` + `on_exit` restore (see `project_flow_test.exs` `install_expand_runner/1`).
- **Known core gap (BUG TRIPWIRE)**: `EvoGit.Core.ForeignRepo.new/3` runs `Path.expand/1` on the root, so the `add_foreign_repo` remote raw-preservation contract holds only for paths the LOCAL OS treats as absolute. `projects_live_test.exs` pins the current mangled Windows-path behavior with a loud comment; the POSIX assertion also trips on Windows CI. Fix belongs in `apps/evo_git/lib/evo_git/core/foreign_repo.ex` (out of scope for tests).
