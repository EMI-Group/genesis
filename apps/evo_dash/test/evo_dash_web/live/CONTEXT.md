# Test Directory — EvoDashWeb Live Tests

## Intent

ExUnit test files for the EvoDash LiveView pages and their support modules. Mirrors `apps/evo_dash/lib/evo_dash_web/live/` under `apps/evo_dash/test/evo_dash_web/live/`.

## Routing Table

- `./projects_live_test.exs` → Comprehensive `ProjectsLive` dashboard suite (~2200 lines; project form/palette/settings, task notifications, remote-node contexts via the fake `EvoDashWeb.ProjectsLiveTest.ConnectionManager` in `EvoGit.RemoteConnection.Registry`, directory picker, file attach, cross-OS remote path handling)
- `./projects_live/` → Pure unit tests for `ProjectsLive` support modules (`project_flow_test.exs` — path normalization incl. `normalize_remote_project_path/2`, `absolute_path_for_node?/2`, the `path_suggestions/2,3` node-aware recents filter, `build_foreign_repo/4` + `Project.load_foreign_repos/3` raw-storage tests; `state_persistence_test.exs` — `maybe_restore_foreign_repos/2` node-aware restore with minimal LiveView sockets)
- `./settings_live_test.exs` → Settings page (search, custom model providers, whitelist safety)
- `./tasks_live_test.exs` → Cross-project task list (search/filter, cancellation modals, `:cancelling` display, event-driven debounced reloads)
- `./review_live_test.exs` → Review page (missing-task error, ignore action)
- `./welcome_live_test.exs`, `./welcome_complete_live_test.exs` → Onboarding pages
- `./system_live_test.exs`, `./agents_live_test.exs`, `./error_html_test.exs`, `./error_json_test.exs` → System page, agent tree, error templates

## Notes for Agents

- **SystemLive chart tests must stub the seed runner**: any test that asserts on `chart_samples` (e.g. "a foreign-node system sample broadcast is ignored") MUST set `Application.put_env(:evo_dash, :system_samples_runner, stub)` in the test body BEFORE mounting. The default runner reads the real `EvoGit.SystemSampler` ring buffer, which is non-empty whenever any sampler tick has occurred in the VM (the evo_git suite's `system_sampler_test.exs` ticks the registered sampler; umbrella `mix test` runs both apps in one VM). Test env disables the tick via `config/test.exs:32` (`:system_sample_interval_ms, 86_400_000`), but that is an accident of config, not a guarantee — the file-level setup block restores the env in `on_exit`.
- **Remote-node test pattern** (used by the cross-OS path tests): save a unique target via `EvoGit.RemoteConnections.save/1` under per-test isolated `XDG_CONFIG_HOME`, then `start_supervised!` a fake `ConnectionManager` GenServer registered in `EvoGit.RemoteConnection.Registry` with `%{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}`. `:erpc` calls to the fake node fail fast, so RPC-dependent remote success paths (e.g. `NodeContext.dir?/1` → true) are unreachable in tests — only the validation/degradation branches are covered end-to-end.
- **`normalize_remote_project_path/2` tilde seam**: `Application.get_env(:evo_dash, :remote_path_expand_runner)` is read at CALL time; tests inject fakes with `Application.put_env` + `on_exit` restore (see `project_flow_test.exs` `install_expand_runner/1`).
- **Foreign-repo raw storage in remote contexts**: `EvoGit.Core.ForeignRepo.new/3` in core still runs `Path.expand/1` on the root (unchanged core behavior — deliberately NOT modified). EvoDash remote contexts bypass it via the node-aware seam `ProjectFlow.build_foreign_repo/4` (local node → `ForeignRepo.new/3`; remote node → RAW root, no local expansion), wired into the `add_foreign_repo` handler, `Project.load_foreign_repos/3` (remote genesis.toml loading), and `StatePersistence.maybe_restore_foreign_repos/2` (persist/restore round-trip). The tripwire pins in `projects_live_test.exs` are replaced by raw-verbatim assertions (POSIX and Windows roots asserted `==` the exact input, host-OS independent); the three construction sites have unit tests in `project_flow_test.exs` + `state_persistence_test.exs`.
