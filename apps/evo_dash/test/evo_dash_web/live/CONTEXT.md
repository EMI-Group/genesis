# Test Directory — EvoDashWeb Live Tests

## Intent

ExUnit test files for the EvoDash LiveView pages and their support modules. Mirrors `apps/evo_dash/lib/evo_dash_web/live/` under `apps/evo_dash/test/evo_dash_web/live/`.

## Routing Table

- `./projects_live_test.exs` → Comprehensive `ProjectsLive` dashboard suite (~3500 lines; project form/palette/settings, task notifications, remote-node contexts via a fake `ConnectionManager` in `EvoGit.RemoteConnection.Registry`, directory picker, file attach, cross-OS remote path handling)
- `./projects_live/` → Pure unit tests for `ProjectsLive` support modules (`project_flow_test.exs` — path normalization incl. `normalize_remote_project_path/2`, `absolute_path_for_node?/2`, node-aware `build_foreign_repo/4` + `Project.load_foreign_repos/3` raw-storage tests, `path_suggestions/2,3`; `state_persistence_test.exs` — `maybe_restore_foreign_repos/2` node-aware restore with minimal LiveView sockets; `project_test.exs`)
- `./home_live_test.exs` → Home chat page (`GET /help`, `:reflect` self-reflective agent) — full suite notes in `../CONTEXT.md`
- `./settings_live_test.exs` → Settings page (search, custom model providers, whitelist safety)
- `./settings_live_agents_test.exs` → Settings **Agents** category (custom agents + model-selection script editors)
- `./settings_live/` → Pure unit tests for SettingsLive support modules (`model_profile_helpers_test.exs`, `config_io_test.exs`)
- `./tasks_live_test.exs` → Cross-project task list (search/filter, cancellation modals, `:cancelling` display, event-driven debounced reloads)
- `./review_live_test.exs` → Review page (missing-task error, ignore action)
- `./welcome_live_test.exs`, `./welcome_complete_live_test.exs` → Onboarding pages
- `./system_live_test.exs` → System page (scheduler controls, system check, Status sandbox helpers)
- `./system_live/` → `charts_test.exs` — SystemLive chart/ring-buffer tests
- `./agents_live_test.exs` → Agent tree (node-aware async loads, push-driven refresh)
- `./agents_live/` → `optimistic_messages_test.exs` — agents page optimistic-message handling
- `./platform_info_test.exs` → Pure unit tests for `EvoDashWeb.PlatformInfo` (platform gating)
- `../components/` → Function-component tests (sibling — read-only, escalate writes to parent)
- `../live_hooks/` → Live-hook tests (NodeAware, Guide, DesktopQuit, UpdateStatus) (sibling — read-only, escalate writes to parent)
- `../controllers/` → Controller / error-template tests (`error_html_test.exs`, `error_json_test.exs` live HERE, not in `live/`) (sibling — read-only, escalate writes to parent)

## Notes for Agents

- **SystemLive chart tests must stub the seed runner**: any test that asserts on `chart_samples` (e.g. "a foreign-node system sample broadcast is ignored") MUST set `Application.put_env(:evo_dash, :system_samples_runner, stub)` in the test body BEFORE mounting. The default runner reads the real `EvoGit.SystemSampler` ring buffer, which is non-empty whenever any sampler tick has occurred in the VM (the evo_git suite's `system_sampler_test.exs` ticks the registered sampler; umbrella `mix test` runs both apps in one VM). Test env disables the tick via `config/test.exs:32` (`:system_sample_interval_ms, 86_400_000`), but that is an accident of config, not a guarantee — the file-level setup block restores the env in `on_exit`.
- **Remote-node test pattern** (used by the cross-OS path tests): save a unique target via `EvoGit.RemoteConnections.save/1` under per-test isolated `XDG_CONFIG_HOME`, then `start_supervised!` a fake `ConnectionManager` GenServer registered in `EvoGit.RemoteConnection.Registry` with `%{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}`. `:erpc` calls to the fake node fail fast, so RPC-dependent remote success paths (e.g. `NodeContext.dir?/1` → true) are unreachable in tests — only the validation/degradation branches are covered end-to-end.
- **`normalize_remote_project_path/2` tilde seam**: `Application.get_env(:evo_dash, :remote_path_expand_runner)` is read at CALL time; tests inject fakes with `Application.put_env` + `on_exit` restore (see `project_flow_test.exs` `install_expand_runner/1`).
- **Foreign-repo raw storage in remote contexts**: `EvoGit.Core.ForeignRepo.new/3` runs `Path.expand/1` on the root, so EvoDash remote contexts bypass it via the node-aware seam `ProjectFlow.build_foreign_repo/4` (local node → `ForeignRepo.new/3`; remote node → RAW root, no local expansion). Wired into the `add_foreign_repo` handler, `Project.load_foreign_repos/3` (remote genesis.toml loading), and `StatePersistence.maybe_restore_foreign_repos/2` (persist/restore round-trip). Tests assert raw-verbatim roots (POSIX and Windows, host-OS independent) in `project_flow_test.exs` + `state_persistence_test.exs`.
