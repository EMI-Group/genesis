# Test Directory

## Intent

ExUnit suite for the `:evo_dash` app: the runner bootstrap, shared support modules, and suites that mirror `apps/evo_dash/lib/`.
70 test files (`*_test.exs`: 69 mirroring `lib/` + `support/config_dir_test.exs`) plus `test_helper.exs` and `support/`: 51 901 lines in the test files, 1 146 in `support/*.ex`.
`support/` holds 6 compiled `.ex` modules plus ONE test script — `support/config_dir_test.exs`, placed there because it is the proof module for that directory's seam (only `*.ex` files are compiled, so ExUnit loads the `_test.exs` like any other suite).
108 `defmodule`s: 102 in the test files (85 case modules + 17 helpers), 6 in `support/*.ex`.
1 788 statically declared `test` blocks (the four `for`-generated declarations in `components/remote_gate_components_test.exs` expand to 12) plus 2 doctests (`EvoDash.SettingsUtils`) → 1 798 tests at runtime.
Measured run: 1 798 passed in 14.2–15.5 s — 4.9–5.4 s async, 9.3–9.6 s sync — ~18 s wall clock, zero stray console lines.
The ~3–4 s gap between ExUnit's total and the wall clock is the umbrella's app boot, paid once per `mix test` invocation.
Stable across explicit seeds (0, 1, 2, 12345, 533180, 8000147, 987654321) and across back-to-back runs.
`mix test apps/evo_dash/test` from the umbrella root runs exactly this app's suite; bare root `mix test` also runs the `evo_git` suite first (~67 s).
The domain singletons (`EvoGit.Store`, `EvoGit.TaskRegistry`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`) live in `:evo_git` and are tested there; no suite here owns them.
Web-layer tests reference those singletons directly; per-test Store/TaskRegistry isolation is `EvoDash.Test.IsolatedTaskStore` (they are children of `EvoGit.Supervisor`, NOT `EvoDash.Supervisor`).

## Routing Table

- `support/` → `ConnCase`, `TestHelpers` (`flush_loading/4`), the two directory-picker fakes, `EvoDash.Test.IsolatedTaskStore`, `EvoDash.Test.ConfigDir` (the per-process config-dir seam + its proof test `support/config_dir_test.exs`) — detail: `support/CONTEXT.md`.
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
It is only the FALLBACK: a suite that needs its own config dir isolates it per process (`EvoDash.Test.ConfigDir.isolate!/1` in `setup`) and never repoints the BEAM-global env var.
`ExUnit.after_suite/1` removes ONLY this run's own data dir and config dir, never the shared `<tmp>/evogit_test_data` / `<tmp>/evogit_test_config` parents (a concurrent run owns siblings).
Directory picker disabled (`Application.put_env(:evo_dash, :directory_picker, enabled: false)`, mirrored by `config/test.exs`) so no native modal dialog can hang the suite.
`:evo_git, :nix_enabled` pinned `false` so `EvoGit.Nix.enabled?/0` never reads the developer's config or shells out to real nix; suites needing nix enable it explicitly.
Five CALL-TIME timer seams are shrunk: `:agents_live_flush_ms` (10), `:agents_live_commit_graph_tick_ms` (10), `:system_samples_seed_retry_ms` (10), `:flush_loading_poll_ms` (1), `:node_aware_reload_debounce_ms` (10).
Each seam is read at the call site via `Application.get_env(:evo_dash, key, <prod default>)`, so production timings (e.g. the 300 ms reload debounce and AgentsLive flush) are untouched when the block is absent.
`ExUnit.start(capture_log: true)` keeps the default `max_cases` (28).
It also installs the DEFAULT-INERT per-process config-dir seam — `Application.put_env(:evo_git, :config_dir_fun, {EvoDash.Test.ConfigDir, :resolve, []})`, the same `{m, f, a}` shape and process-dictionary key (`:evogit_config_dir`) `:evo_git`'s own helper installs, so a root `mix test` resolves identically whichever helper loaded last and production (which never sets the key) is byte-identical.
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
Apply the file-local funnel right after `live/3` (and after the relevant `render_patch/2`), BEFORE driving any event: `settings_live_test.await_mount_async_loads/1`, `review_live_test.flush_review_load/2` + `settle_debounced_task_reload/1`, `projects_live_test.await_async_loads/1`, `tasks_live_test.flush_tasks_load/2`, `settings_live_agents_test`'s `mount_settings/1` → `await_view_async_loads/1`.
They locate this mount's children by the view pid in the child's `:"$callers"` entry (`mount_async_task_pids/1` + `task_callers/1`) and wait for those pids to exit, after which the queued apply is drained by a `render(view)` (or, for `settings_live_test`'s monitor-only variant, by the test's next synchronous `render`/`:sys.get_state`).
The `:"$callers"` filter is load-bearing, not cosmetic: `EvoDash.TaskSupervisor` never kills children per test, so a wait on EVERY supervisor child made each `settings_live_agents_test` mount pay its whole deadline whenever any long-lived child existed — the owner-aware poll (2 ms cadence, ~5 s best-effort cap) looks only at this mount's tasks and returns the instant they are gone.
`review_live_test.flush_review_load/2` composes the funnel with `EvoDashWeb.TestHelpers.flush_loading/4` (funnel first, then the loading marker), and `tasks_live_test.flush_tasks_load/2` adds a `tasks_loading == false` poll plus a final `render(view)`.
Reuse one of these helpers instead of re-deriving the race — a sleep cannot cover it deterministically.
`render_async/2` does NOT await `Task.Supervisor` children, which is why `EvoDashWeb.TestHelpers.flush_loading/4` and the funnels exist.

### Definition order inside a test file is load-bearing
An `async: true` module is handed to the ExUnit runner as soon as its `defmodule` is evaluated, i.e. while the rest of the file is still loading.
Any module an async module references at runtime (`start_supervised!` target, fake `ConnectionManager`, helper module) must therefore sit ABOVE it; a module defined lower can still be `:non_existing` and raise "was given as a child to a supervisor but it does not exist".
Only `async: false` modules may sit at the end of a file.
Files that depend on this ordering: `projects_live_test.exs`, `settings_live_test.exs`, `settings_live_agents_test.exs`, `system_live_test.exs`, `welcome_live_test.exs`, `welcome_complete_live_test.exs`, `task_export_controller_test.exs`, `live_hooks/appearance_test.exs` (its fake `ConnectionManager` must stay above the async module — it lived below it and intermittently raised "does not implement child_spec/1"), and `review_live_test.exs` (its fake `ConnectionManager` sits above every test module).

### Flipping a module to async exposes run-wide-store hazards
Every suite shares ONE `EvoGit.Store`; only the `IsolatedTaskStore` users swap it.
A test that sweeps globally — `clear_finished_tasks/0` (`clear_task_history`), retention/cleanup sweeps, deleting rows it did not create — removes another module's live fixture the moment it runs concurrently, so such a test belongs in an `async: false` module (`ProjectsLiveSyncTest` owns exactly those two notification tests).
`projects_live_test.exs`'s `Helpers.clear_recent_projects/0` removes EVERY recent project from the process-global registry — safe only while no other module asserts on recents.
The matching quiet-side rule: a `refute_push_event`/`refute_receive` about a `"tasks"` broadcast is conclusive only when no async module can publish one.

### Async review actions — every review test must await the settle
`ReviewLive` runs every review action through `spawn_action/4` (supervised task) and applies it in `handle_info({:review_action_result, task_id, node, action, ref, result})`, so a `render_click` proves dispatch only.
Any test asserting action-derived state (a repo's `resolution`, `local_repo_resolutions`, `review_status`, the completion banner, the hub snapshot) or inspecting an injected runner-seam message MUST call `await_review_action_settled/1` after the click — this is the hard rule for every new review test.
`await_review_action_settled/1` (one `Helpers` function in the shared `EvoDashWeb.ReviewLiveTest.Helpers` module, imported by all eight review suites) polls `assigns(view)[:review_action] == nil` (a stopped view counts as settled via a conditional `catch :exit`) and returns the post-settle render, or `""` when the view is gone.
The two nav-away cases (`ignore`, `auto_resolve`) synchronize a different way: `render_click` → `assert_redirect`, then a synchronous `EvoGit.TaskRegistry.get_task/1` proves the queued cast landed, so the hub `== :empty` assertion right after it is non-vacuous.
Do not read action-derived state right after a bare `render_click` anywhere else.

### Push-based event contract testing
Events are injected by hand: `send(view.pid, {:task_updated, id, status, node()})`, `{:task_deleted, id, node()}`, `{:agent_updated, id, changed_fields, node}` (the `:agent_updated` payload `changed_fields` is a KEYWORD LIST — guard with `is_list`/`Keyword.has_key?`), `{:system_sample, node, seq, sample}`, `{:remote_connection_status, id, status_map}`.
Foreign-node events (`node != node()`) must be asserted ignored.
Stale-guard paths are driven by injecting the pages' own result messages: `{:tasks_page_loaded, seq, node, result}`, `{:agents_data_loaded, ...}`, `{:agents_refresh_result, seq, node, result}`, `{:system_checks_result, result}`, `{:system_samples_seeded, seq, node, result}`, `{:chat_history_loaded, node, seq, id, msgs}`, `{:chat_task_loaded, node, seq, id, result}`.
The event table itself: `apps/evo_dash/CONTEXT.md` → "Push-based event contract".

### Global state inventory and isolation
Boot-created, process-wide named hubs shared by ALL suites: `EvoDash.ActiveTasks` (`:evo_dash_active_tasks`, process-less pure ETS, keyed by node context), `EvoDash.ChatHistory` (`:evo_dash_chat_history`, GenServer-owned, flat chat ids + `{:current}`), `EvoDash.AccentCache` (`:evo_dash_accent_cache`, keyed by connection-target id), plus the `EvoGit.AgentScheduler` tables.
None of them is per-test scoped, so an EXACT-contents assertion is safe only against writers that cannot run concurrently.
**`EvoDash.ActiveTasks` rule — an async-visible clear deletes ONLY the local context**: use `EvoDash.ActiveTasks.invalidate(nil, node())`, never the whole-table `reset/0`.
`EvoDashWeb.ConnCase` does that in `setup` and in `on_exit`; the `async: true` modules that mount whole pages and clear the hub themselves (`settings_live_test`, `settings_live_agents_test`, the six async review modules, `desktop_quit_test`, `agents_live_test`, `projects_live_test` via `Helpers.reset_active_tasks_hub/1`) do the same.
Whole-table `reset/0` survives ONLY inside `async: false` modules (`active_tasks_test`, `page_controller_test`, `home_live_test`, `tasks_live_test`, `system_live_test`'s sync module, `settings_live_test`'s sync module, `node_aware_test`'s sync module, the three sync review modules), which ExUnit never runs concurrently with anything.
Why the scoping is required: `reset/0` is `:ets.delete_all_objects`, and in the parallel phase (~1 700 clears per run, ~400/s) one module's wipe deleted another module's per-test-unique `{target, remote_node}` snapshot between its `put/4` and its `get/2` (instrumentally proven; a unique KEY cannot defend against a table-wide wipe).
Why it loses nothing: a local whole-page mount seeds only from `{nil, node()}`, a pending context only ever holds `{[], []}` (`NodeAware.fetch_active_tasks/2`'s pending guard), task-bearing remote keys require a successful cross-node `:erpc` (impossible in-process), and remote keys are per-test-unique.
Consequence for new tests: an exact `EvoDash.ActiveTasks.get/2` assertion may stay `async: true` for any non-local key (`NodeAwareRunWideTest` keeps the remote half); never reintroduce a whole-table clear into an async module.
**`EvoDash.ChatHistory` is written by every connected `/help` mount** (`HomeLive` calls `current_chat_id() || new_chat()` + `put_state` — `home_live.ex`), so the exact-global reader `evo_dash/chat_history_test.exs` (async) is safe only because EVERY `/help` mounter is `async: false`: `home_live_test`, `page_controller_test` (plain GET dead render), and the "mounts HomeLive at /help" case in `ProjectsLiveSyncTest`. The async `projects_live_test` module deliberately hosts no `/help` mount — a new async `/help` mount would race that module, so it belongs in a sync module.
`EvoDash.AccentCache` has the same structural pattern but no live victim: only `appearance_test` resets it, its reads use keys written by that same module, and a concurrent miss merely re-resolves.
Process-global `EvoGit.Store`/`EvoGit.TaskRegistry` isolation is `EvoDash.Test.IsolatedTaskStore.isolate!/1`, and only four suites still call it (6 call sites): `home_live_test` (module setup, 74 tests), `tasks_live_test` (module setup, 81 tests), `node_aware_test` (the five describes whose assertions need a store-backed registry, 16 tests) and `isolated_task_store_test` itself (3 tests) — ≈174 calls per run.
`isolate!/1` costs ≈6.5 ms per call end-to-end (≈1.7 ms production-pair restart + ≈4–5 ms for the teardown's `ExUnit.CaptureLog.capture_log/2` window + sub-millisecond terminate/boot/restore), so per-test isolation is NOT the significant cost — serialisation is.
Every other store-touching suite writes into the RUN-WIDE per-run store instead (`EvoGit.Store`, started once per run and never terminated) in a whole-store-safe way: per-test unique ids (`System.unique_integer/1`, sometimes under a unique `project_path` so a filtered paged read is an exact-count anchor), assertions scoped to exactly those ids, and an `on_exit` that deletes the row through the DIRECT Store (`EvoGit.Store.delete_task(EvoGit.Store, id)` — never a `TaskRegistry` cast, which broadcasts on `"tasks"` and would arm every mounted page's reload debounce).
Suites using that idiom: `node_context_test`'s async module (its config module writes only config), `NodeAwareRunWideTest`, every `ReviewLive*Test` module (fixture cleanup via `delete_seeded_task!/1`), `projects_live_test`, and `agents_live_test`'s per-test agent ids.
`review_live_test` runs on the production pair and asserts it with `IsolatedTaskStore.assert_production!/0` in every module's `setup`.
Prefer unique task ids plus explicit cleanup over assumptions about global emptiness.
`XDG_CONFIG_HOME` is process-global, but no suite writes it: the config dir is resolved per process through the `:config_dir_fun` seam the helper installs (`EvoDash.Test.ConfigDir.isolate!/1` in `setup` — own process dictionary, then the `$callers` chain), proven end-to-end by `support/config_dir_test.exs` (test process, a real page render in the mounted view, `Task.Supervisor` children via `EvoDash.SafeCall.start/4`; a raw `spawn/1` and the boot-time app-global singletons are the documented escape classes).

### Async policy
Census by MODULE (the unit ExUnit parallelises), not by file: 85 case modules across the 70 files — 70 `async: true` (1 452 declared tests) and 15 `async: false` (336).
Eight files hold both kinds (`review_live_test.exs` 9 case modules, `node_context_test.exs` 2, `node_aware_test.exs` 2, and `projects_live_test.exs`, `settings_live_test.exs`, `system_live_test.exs`, `welcome_live_test.exs`, `welcome_complete_live_test.exs` with one async + one sync module each); the other 62 files are a single case module.
The other 23 `defmodule`s in this tree (108 total) are helpers with no case template: 17 in the test files (the review/settings/system/projects `Helpers` modules, the fake `ConnectionManager` GenServers, `SafeCallTest.SlowServer`, the diff-viewer `Foo`) and 6 in `support/`; three of them (`review_live_test`, `system_live_test`, `settings_live_test`) still `use EvoDashWeb.ConnCase` for its imports without running tests.
ExUnit drains ALL async modules before starting any sync one (`ExUnit.Runner.async_loop/4`), so a flip is unsafe only when a module shares a MUTABLE global with another ASYNC module.
No `async: false` module is blocked by the config dir: `EvoGit.Platform.config_dir/1` resolves through the `:config_dir_fun` seam per process (own dictionary, then the `$callers` chain — LiveViewTest sets a view's `$callers` to the test pid), so a config-writing module isolates with `setup`-time `EvoDash.Test.ConfigDir.isolate!/1` and stays async.
The 15 sync modules and the one global that forces each (per-file evidence: the child docs `evo_dash/CONTEXT.md`, `live/CONTEXT.md`, `live_hooks/CONTEXT.md`, `controllers/CONTEXT.md`):

| File → module | Tests | Forcing global |
|---------------|-------|----------------|
| `evo_dash/active_tasks_test.exs` | 9 | writes junk sentinel shapes into the `{nil, node()}` `EvoDash.ActiveTasks` key that async whole-page mounts seed from |
| `evo_dash/isolated_task_store_test.exs` | 3 | terminates/restarts the process-global `EvoGit.Store`+`TaskRegistry` pair and asserts ABSOLUTE properties of the replacement |
| `live/tasks_live_test.exs` | 81 | `EvoDash.Test.IsolatedTaskStore.isolate!/1` (the singleton NAME) |
| `live/home_live_test.exs` | 74 | `isolate!/1` + `EvoDash.ChatHistory` (every test mounts `/help`) + `EvoGit.AgentScheduler` `model_profiles: []` + per-test `:approval_responder`/`:source_*_runner` seams; no mount-free test exists, so there is no async subset |
| `live/projects_live_test.exs` → `ProjectsLiveSyncTest` | 20 | global-quiet `refute_push_event` after a `"tasks"` publish; the `clear_task_history` run-wide-store sweep; `:sys.suspend(EvoGit.TaskRegistry)`; `:directory_picker` (shared with async `directory_picker_test`) and `:remote_path_expand_runner` (shared with async `project_flow_test`); the `/help` mount (a connected `HomeLive` mount writes the process-wide `EvoDash.ChatHistory`) |
| `live/settings_live_test.exs` → `SettingsLiveGlobalStateTest` | 25 | `:nix_available_override` + `:platform_os_override` (also written by async `platform_info_test`) + `EvoGit.AgentScheduler.pause/resume` + the `"scheduler_config"` broadcast |
| `live/system_live_test.exs` → `SystemLiveSyncTest` | 30 | `:platform_os_override` (async peer); the `EvoDash.UpdateStatus` hub and `:update_*`/`:desktop_release` (async `evo_dash/update_status_test`); `AgentScheduler.pause` + `"scheduler_config"`; test-owned ETS counters inside process-global `:system_samples_runner`/`:source_status_runner` closures |
| `live/welcome_live_test.exs` → `WelcomeLiveTest.TaskBroadcast` | 1 | publishes `{:task_updated, …}` on the global `"tasks"` topic (arms every mounted page's NodeAware debounce; `agents_live_test`'s negative `:tasks_reload_pending` poll is the canary) |
| `live/welcome_complete_live_test.exs` → `TaskBroadcast` | 1 | same `"tasks"` broadcast |
| `live/review_live_test.exs` → `ReviewLiveMergeTest` | 24 | task-mutating merge/reject clicks broadcasting on `"tasks"` |
| `live/review_live_test.exs` → `ReviewLiveAutoResolveTest` | 3 | same (`start_task` + `set_review_status` clicks) |
| `live/review_live_test.exs` → `ReviewLiveSyncTest` | 19 | same, plus writes `:review_archive_runner`/`:review_archive_agent_runner` (owned by the ASYNC `ReviewLiveArchiveTest`), `PATH`, and the LOCAL `{nil, node()}` ActiveTasks key |
| `live_hooks/node_aware_test.exs` → `NodeAwareTest` | 33 | exact reads of the LOCAL `{nil, node()}` ActiveTasks key + `Process.unregister(EvoGit.TaskRegistry)` + `IsolatedTaskStore.isolate!/1` |
| `live_hooks/update_status_test.exs` | 11 | the `EvoDash.UpdateStatus` hub + `:update_notify_only_override`/`:desktop_quit_stop_fun` seams shared with the async `evo_dash/update_status_test` and `desktop_quit_test` |
| `controllers/page_controller_test.exs` | 2 | writes junk sentinel shapes into the `{nil, node()}` ActiveTasks key |

Remaining levers, in the order they would pay off (each one is a PRODUCTION change, since every surviving sync module is blocked by a BEAM-global singleton):
- Scoped/per-task `EvoGit.TaskRegistry` broadcasts → the three `"tasks"`-publisher review modules, the two `TaskBroadcast` tests and `ProjectsLiveSyncTest`'s broadcast half.
- Per-process `EvoGit.Store`/`TaskRegistry` instances → `tasks_live_test`, `home_live_test`, `NodeAwareTest`'s store half and `isolated_task_store_test`.
- A per-process `EvoDash.ChatHistory` seam → `home_live_test`.
- Per-process seams for the `EvoDash.ActiveTasks`/`EvoDash.UpdateStatus` hubs and for `:platform_os_override`/`:nix_available_override` → `active_tasks_test`, `page_controller_test`, `update_status_test`, `SettingsLiveGlobalStateTest`, `SystemLiveSyncTest`.

### Async first — test runtime is part of test quality
New tests default to `async: true`; an unnecessary `async: false` module is a defect, because the sync phase is serial and every future development cycle pays its full cost.
Prefer event-driven synchronization and bounded polls over fixed sleeps, and prefer ONE mount driving a state machine over many mounts of the same page.
Remember what the executor actually parallelises: ExUnit parallelises across MODULES, never within one, so a single `async: true` module gains nothing — splitting one long file into several modules is what shortens the run (see `review_live_test.exs`).

### Suite runtime: what actually costs time
There is NO hidden per-test tax: the slowest ten tests in the whole suite are 190–320 ms and together are 2.3 s (≈11 % of a run), while a typical LiveView test mounts and clicks in 20–100 ms.
`config :phoenix_live_view, enable_expensive_runtime_checks: true` (root `config/test.exs`) is a COMPILE-time flag that only enables function-environment checks on `start_async`/`assign_async` — it is not a per-render cost.
`EvoDash.Test.IsolatedTaskStore` costs ≈6.5 ms per call, so it is not a lever either.
The real cost structure is three terms: ~3–4 s of app boot per `mix test` invocation, a SERIAL `async: false` phase, and a PARALLEL phase whose floor is the single largest async module.
Same-session A/B on this host: the serial phase went 14.5–15.2 s → 9.3–9.6 s, "Finished in" 18.4–19.0 s → 14.5–15.0 s, and the async phase 3.3–4.0 s → 4.9–5.4 s because it absorbed the moved work — the run is now bounded by the parallel phase plus app boot, not by a serial queue.
Per-module A/B in the same session: `projects_live_test.exs` 108.5 s serial → 3.7–4.3 s; `settings_live_test.exs` 248.7 s serial → 3.0–3.4 s async + 0.3 s sync.
The remaining serial floor IS the 15 sync modules listed under "Async policy", and ExUnit parallelises per MODULE (never within one), so splitting a long file into modules is the only test-side lever left — clearing that floor needs the production levers listed there.
Measurement discipline: this host is SHARED, so absolute timings swing by 10–30× purely on load (the same unchanged file measured at 4.2 s and 124.5 s; the same suite at 17.7 s and 116.7 s). Always compare same-session A/B numbers and never trust a single run.

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
