# Test Directory

## Intent

ExUnit suite for the `:evo_dash` app: the runner bootstrap, shared support modules, and suites that mirror `apps/evo_dash/lib/`.
68 test files (`*_test.exs`) + `test_helper.exs` + `support/`: 51 541 lines, 1771 statically declared `test` blocks plus 2 doctests (`EvoDash.SettingsUtils`).
Measured run: 1781 passed (1779 tests + 2 doctests) in ~21 s — 3.3 s async, 17.8 s sync — ~25 s wall clock, zero stray console lines.
Stable across explicit seeds (0, 1, 2, 12345, 533180, 8000147, 987654321) and across back-to-back runs.
`mix test apps/evo_dash/test` from the umbrella root runs exactly this app's suite; bare root `mix test` also runs the `evo_git` suite first (~67 s).
The domain singletons (`EvoGit.Store`, `EvoGit.TaskRegistry`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`) live in `:evo_git` and are tested there; no suite here owns them.
Web-layer tests reference those singletons directly; per-test isolation is owned by `EvoDash.Test.IsolatedTaskStore` (they are children of `EvoGit.Supervisor`, NOT `EvoDash.Supervisor`).

## Routing Table

- `support/` → `ConnCase`, `TestHelpers` (`flush_loading/4`), the two directory-picker fakes, `EvoDash.Test.IsolatedTaskStore` — detail: `support/CONTEXT.md`.
- `evo_dash/` → domain-layer suites (ActiveTasks, ChatHistory, AttachedFile, NodeContext, DirectoryPicker, SafeCall, DesktopLifetime, UpdateStatus, SettingsUtils, MarkdownRender, ConnectionDiagnostics) — detail: `evo_dash/CONTEXT.md`.
- `evo_dash_web/` (root) → cross-cutting web-layer suites with no child doc: `helpers_test.exs` (85 tests, status badges/datetime/icons/modals), `helpers_blob_preview_test.exs` (23, `blob_preview/2` + `list_preview/2` caps), `theme_color_test.exs` (27, color VALUES), `content_text_test.exs` (9).
- `evo_dash_web/live/` → LiveView page suites + pure unit tests for their support modules — detail: `live/CONTEXT.md`, `live/agents_live/CONTEXT.md`.
- `evo_dash_web/live_hooks/` → the on-mount hook suites (NodeAware, Guide, Appearance, DesktopQuit, UpdateStatus) — detail: `live_hooks/CONTEXT.md`.
- `evo_dash_web/components/` → function-component render/contract suites (all `async: true`, `render_component/2` + Floki) — detail: `components/CONTEXT.md`.
- `evo_dash_web/controllers/` → error templates + the streamed task-archive export endpoint — detail: `controllers/CONTEXT.md`.
- No CONTEXT.md exists at `evo_dash_web/` or at the individual page subdirectories (`projects_live/`, `home_live/`, `settings_live/`, `system_live/`, `tasks_live/`, `review_live/`).

## API Surface

### `test_helper.exs`

`XDG_DATA_HOME` → `<tmp>/evogit_test_data`; the real per-run database dir comes from `config/test.exs`'s `:evo_git, :data_dir` (`.../evogit_test_data/genesis-<os pid>-<unique int>`), shared by both umbrella apps within one run and unique per BEAM across runs.
`XDG_CONFIG_HOME` → a run-unique EMPTY dir (`.../evogit_test_config/genesis-<os pid>-<unique int>`), so nothing reads or writes the developer's real `~/.config/genesis`; this redirect is a no-op on macOS (`EvoGit.Platform.base_dir/3` ignores XDG there).
Suites that WRITE config point `XDG_CONFIG_HOME` at their own per-test temp dir and restore the prior value in `on_exit` (which is why they are `async: false`).
`ExUnit.after_suite/1` removes ONLY this run's own data dir and config dir, never the shared `<tmp>/evogit_test_data` / `<tmp>/evogit_test_config` parents (a concurrent run owns siblings).
Directory picker disabled (`Application.put_env(:evo_dash, :directory_picker, enabled: false)`, mirrored by `config/test.exs`) so no native modal dialog can hang the suite.
`:evo_git, :nix_enabled` pinned `false` so `EvoGit.Nix.enabled?/0` never reads the developer's config or shells out to real nix; suites needing nix enable it explicitly.
Five CALL-TIME timer seams are shrunk: `:agents_live_flush_ms` (10), `:agents_live_commit_graph_tick_ms` (10), `:system_samples_seed_retry_ms` (10), `:flush_loading_poll_ms` (1), `:node_aware_reload_debounce_ms` (10).
Each seam is read at the call site via `Application.get_env(:evo_dash, key, <prod default>)`, so production timings (e.g. the 300 ms reload debounce and AgentsLive flush) are untouched when the block is absent.
`ExUnit.start(capture_log: true)` keeps the default `max_cases` (28).
`config/test.exs` additionally disables the system sampler (`:system_sample_interval_ms` 86 400 000) and shortens the finalizing watchdog grace to 1 minute.

## Notes for Agents — cross-cutting rules

### Console output must be zero stray lines
`capture_log: true` is WINDOW-based (ExUnit swaps the `:default` handler only while ≥1 test runs), so a Logger line emitted in a between-test gap by a global/async process prints to the console.
Any test that triggers logged work from a process OUTSIDE the test process (TaskRegistry wrapper crash, offloaded `EvoGit.Store` read, reflect-task `:llm_not_configured`, provider request, remote-connection warning, desktop-lifetime watcher) must capture the triggering action AND await that work inside the same capture window.
Use `ExUnit.CaptureLog.capture_log/2` for fire-and-forget work and `with_log/2` when the call's return value is also asserted.
Never silence noise by raising the global Logger level.
The one leak class the suite structurally prevents is a `EvoGit.TaskRegistry` read worker calling a store that is being stopped; `IsolatedTaskStore`'s ordered teardown is the mechanism, so keep that ordering rather than reaching for a Logger-level silencing.

### Deterministic waits (no fixed sleeps, no tight windows)
Bounded polls run at a 1–2 ms cadence (`@wait_poll_ms 2`, `@poll_ms 1`); a fixed `Process.sleep` is never a wait mechanism.
`refute_receive`/`refute_push_event` may use a 0 ms window ONLY after a preceding drain or `:sys.get_state` round-trip has provably completed the mailbox.
Never shorten a window that IS the detection mechanism; positive assertions keep generous second-scale timeouts so real breakage still fails loudly.
`assigns/1` is a synchronous `:sys.get_state(view.pid)` round-trip and Erlang guarantees per-sender ordering, so `send(view.pid, msg)` followed by any `assigns/1` read is already synchronized.
Debounce-sensitive waits poll the page's own pending flag or reuse the file-local `wait_until/2` / `flush_*_load/2` helper.
Per-suite wait contracts: `live/CONTEXT.md`, `live_hooks/CONTEXT.md`, `evo_dash/CONTEXT.md`.

### Mount funnels — a page-load result must never clobber test-driven state
Some LiveViews spawn an `EvoDash.TaskSupervisor` child at mount or on a `handle_params` patch, and its result message REPLACES assigns with the mount-time snapshot.
Apply the file-local funnel right after `live/3` (and after the relevant `render_patch/2`), BEFORE driving any event: `settings_live_test.await_mount_async_loads/1`, `review_live_test.flush_review_load/2` + `settle_debounced_task_reload/1`, `projects_live_test.await_async_loads/1`, `tasks_live_test.flush_tasks_load/2`, `settings_live_agents_test`'s `mount_settings/1` (bounded `wait_until/2`).
They locate this mount's children by the view pid in the child's `:"$callers"` entry (`mount_async_task_pids/1` + `task_callers/1`) and wait for those pids to exit, after which the queued apply is drained by a `render(view)` (or, for `settings_live_test`'s monitor-only variant, by the test's next synchronous `render`/`:sys.get_state`).
`review_live_test.flush_review_load/2` composes the funnel with `EvoDashWeb.TestHelpers.flush_loading/4` (funnel first, then the loading marker), and `tasks_live_test.flush_tasks_load/2` adds a `tasks_loading == false` poll plus a final `render(view)`.
Reuse one of these helpers instead of re-deriving the race — a sleep cannot cover it deterministically.
`render_async/2` does NOT await `Task.Supervisor` children, which is why `EvoDashWeb.TestHelpers.flush_loading/4` and the funnels exist.

### Async review actions — every review test must await the settle
`ReviewLive` runs every review action through `spawn_action/4` (supervised task) and applies it in `handle_info({:review_action_result, task_id, node, action, ref, result})`, so a `render_click` proves dispatch only.
Any test asserting action-derived state (a repo's `resolution`, `local_repo_resolutions`, `review_status`, the completion banner, the hub snapshot) or inspecting an injected runner-seam message MUST call the file-local `await_review_action_settled/1` after the click — this is the hard rule for every new review test.
`await_review_action_settled/1` polls `assigns(view)[:review_action] == nil` (a stopped view counts as settled via a conditional `catch :exit`) and returns the post-settle render, or `""` when the view is gone.
The two nav-away cases (`ignore`, `auto_resolve`) synchronize a different way: `render_click` → `assert_redirect`, then a synchronous `EvoGit.TaskRegistry.get_task/1` proves the queued cast landed, so the hub `== :empty` assertion right after it is non-vacuous.
Do not read action-derived state right after a bare `render_click` anywhere else.

### Push-based event contract testing
Events are injected by hand: `send(view.pid, {:task_updated, id, status, node()})`, `{:task_deleted, id, node()}`, `{:agent_updated, id, changed_fields, node}` (the `:agent_updated` payload `changed_fields` is a KEYWORD LIST — guard with `is_list`/`Keyword.has_key?`), `{:system_sample, node, seq, sample}`, `{:remote_connection_status, id, status_map}`.
Foreign-node events (`node != node()`) must be asserted ignored.
Stale-guard paths are driven by injecting the pages' own result messages: `{:tasks_page_loaded, seq, node, result}`, `{:agents_data_loaded, ...}`, `{:agents_refresh_result, seq, node, result}`, `{:system_checks_result, result}`, `{:system_samples_seeded, seq, node, result}`, `{:chat_history_loaded, node, seq, id, msgs}`, `{:chat_task_loaded, node, seq, id, result}`.
The event table itself: `apps/evo_dash/CONTEXT.md` → "Push-based event contract".

### Global state inventory and isolation
Boot-created, process-wide named hubs shared by ALL suites: `EvoDash.ActiveTasks` (`:evo_dash_active_tasks`), `EvoDash.ChatHistory` (`:evo_dash_chat_history`), `EvoDash.AccentCache` (`:evo_dash_accent_cache`), plus the `EvoGit.AgentScheduler` tables.
`EvoDashWeb.ConnCase` resets `EvoDash.ActiveTasks` in `setup` and `on_exit`; any non-ConnCase suite that mounts whole pages resets it itself.
Process-global `EvoGit.Store`/`EvoGit.TaskRegistry` isolation is `EvoDash.Test.IsolatedTaskStore.isolate!/1`, used by the six sync suites `home_live_test`, `tasks_live_test`, `live_hooks/node_aware_test`, `live_hooks/guide_test`, `node_context_test`, `isolated_task_store_test`.
`review_live_test` runs on the production pair and asserts it with `IsolatedTaskStore.assert_production!/0` in setup.
Everything else uses the run's single unique data dir.
Prefer unique task ids plus explicit cleanup over assumptions about global emptiness.
`XDG_CONFIG_HOME` is process-global and has no `Application.get_env` override seam, so any suite that SETS it is `async: false`.

### Async policy
49 modules are `async: true`; 19 are `async: false` (17 declare it explicitly, 2 inherit the ConnCase default: `page_controller_test`, `projects_live_test`).
ExUnit drains ALL async modules before starting any sync one (`ExUnit.Runner.async_loop/4`), so a flip is unsafe only when a module shares a MUTABLE global with another ASYNC module.
Sync reasons, all documented per file: writing `XDG_CONFIG_HOME`/config, terminating the global Store+TaskRegistry pair, resetting the boot-created ETS hubs (`active_tasks_test`), or sharing an app-env seam/hub with an async peer (`live_hooks/update_status_test` vs async `desktop_quit_test`; `settings_live_test`'s `:nix_available_override`/`:platform_os_override` vs async `platform_info_test`).
Every sync module either WRITES config or mutates a shared hub/app-env/seam, so no flip candidates remain.
`agents_live_test` (`/agents`) and `desktop_quit_test` (`/system`) mount whole pages while async and read config through the NodeAware/Appearance hooks, so a config writer must never run concurrently with them.
Enablers for flipping the config-isolated majority would be production changes (an injectable config dir, a `server`-arg TaskRegistry, a store/registry seam in `NodeContext`); a process-dictionary override cannot work because LiveView processes do not inherit the test process's dictionary.
Per-file evidence lives in the child docs: `evo_dash/CONTEXT.md`, `live/CONTEXT.md`, `live_hooks/CONTEXT.md`, `controllers/CONTEXT.md`.

### Test-file `try/rescue`
Allowed — and encouraged — in `on_exit`/teardown cleanup, because a teardown failure must not mask a real test failure; each such rescue carries a brief comment explaining why.
Forbidden around assertions or the behavior under test: if an assertion would fail, the test must fail loudly.

### LiveViewTest and module-loading limits
`render/1` cannot see `:sys.replace_state` mutations on the LiveView process (the test proxy renders its own cached `html_tree`); drive the real event path or send the actual `handle_info` message instead.
For transient states (a `:testing` spinner) the same rule applies: no direct state surgery.
`function_exported?/3` does NOT load a module, so a test asserting an export must call `Code.ensure_loaded!/1` first (`evo_dash/node_context_test.exs` carries the regression example).

### Pins that must not be weakened
Force-kill error flash asserts the msgid `"Failed to force kill task"` (`tasks_live.ex`) — never widen it to the generic `"Failed to cancel task: %{reason}"` wording.
Modal idiom (`system_live_test`, `tasks_live_test`): `render_click(view, "request_X")` opens (assert the title string), `render_click(view, "cancel_X")` closes (refute); handlers that would tear down the local VM are exercised via a direct `SystemLive.handle_event/3` on a hand-built `%Phoenix.LiveView.Socket{}` with a non-local `current_node` (RPC to a missing node degrades to `:ok`) — the local VM-killing paths are intentionally untested.
Dropdown idiom (`projects_live_test`): the menu content stays in the DOM (CSS-hidden); tests assert the click-catcher overlay (`phx-click="close_configure_dropdown"`) appearing/disappearing.
Color pins: `theme_color_test.exs` is the ONLY file asserting color VALUES (exact OKLCH strings per mode, `default_color/0`, `#rrggbb` hash output); `helpers_test.exs` pins DaisyUI token classes and the Adwaita status scheme (`bg-warning/10 text-warning` etc.).
Accent swatches are distinguished ONLY by the `ring-base-content/70` fragment — every chip carries `focus-visible:ring-2` in its base classes, so never match a generic `ring-2`.
Nothing in this tree asserts theme-toggle markup, `dark:` variants, or generated CSS assets.
`:cancelling` color/dot pins live in `helpers_test.exs`, `tasks_live_test.exs` and `system_live/charts_test.exs` (chart series are CSS vars, never hex literals).

### Speed ↔ quality control
The task form's segmented control is covered at component level (`task_form_components_test.exs`, `#quality-level-control` markup + exact active/inactive class strings) and at page level (`projects_live_test.exs`, `select_quality_level` assign movement and `:quality_level` opt threading).

## Constraints

Follow standard Phoenix conventions: mirror `lib/` under `test/`, name files `*_test.exs`, and use `EvoDashWeb.ConnCase` for connection-based tests.
Support modules live in `support/` and are auto-compiled through `elixirc_paths(:test)` in `apps/evo_dash/mix.exs`.
All task persistence in tests goes through `EvoGit.Store` (SQLite) — no other storage format.
