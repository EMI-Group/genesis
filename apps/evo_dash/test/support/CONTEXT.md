# Test Support

## Intent

Shared, production-free support modules for the EvoDash suite: the connection case template, the async-load flush helper, the two directory-picker fakes, the Store/TaskRegistry isolation helper, the per-process config-dir seam, the deadline-bounded temp-tree removal primitive, and the hermetic ChatGPT sign-in stub.
Compiled only in `:test` via `elixirc_paths(:test) = ["lib", "test/support"]` (`apps/evo_dash/mix.exs`).
Nine compiled `.ex` modules carry setup, helpers and fakes only — never test logic or assertions.
The directory also holds TWO test scripts, `config_dir_test.exs` and `fs_cleanup_test.exs`, which are NOT compiled (only `*.ex` is) but loaded by ExUnit like any other suite; they live here because each is the proof module for one support module of this directory.

## Routing Table

Leaf directory — no child directories.

## API Surface

### `EvoDashWeb.ConnCase` (`conn_case.ex`)

ExUnit `CaseTemplate` for tests needing a Phoenix connection: sets `@endpoint EvoDashWeb.Endpoint`, `use EvoDashWeb, :verified_routes`, imports `Plug.Conn` + `Phoenix.ConnTest`, and its default setup returns `{:ok, conn: build_conn()}`.
Its setup also clears the shared `EvoDash.ActiveTasks` sidebar hub for the LOCAL context only (`EvoDash.ActiveTasks.invalidate(nil, node())` plus the same call in `on_exit`), so a snapshot or junk sentinel leaked by an earlier suite never seeds a later whole-page mount and this suite's own writes never leak onward.
`EvoDash.ActiveTasks` is a process-less pure-ETS module (NOT a GenServer) over the boot-created public table `:evo_dash_active_tasks`, owned by the long-lived application process and shared by every suite in one `mix test` run.
`{nil, node()}` is the only context a local whole-page mount seeds from (`NodeAware.hub_snapshot/2`), and the only key shape a junk sentinel from `active_tasks_test` / `page_controller_test` lands in.
The clear is deliberately NOT a table-wide wipe: the suite runs dozens of `async: true` ConnCase modules concurrently, so a whole-table `reset/0` lets one module delete another module's per-test-unique remote-key snapshot between its `put` and its `get` — the proven cause of the `EvoDashWeb.NodeAwareRunWideTest` "an applied result writes the hub" flake.
Remote/pending contexts need no clearing: the NodeAware pending guard only ever writes `{[], []}`, and task-bearing remote keys are per-test-unique; a caller needing a FOREIGN context cold must `invalidate/2` that specific context itself.
`async:` is NOT set by the template, so `use EvoDashWeb.ConnCase` without an option yields `async: false`; callers must state their async policy explicitly.
The local-context-only clear makes concurrent ConnCase modules safe; module-level whole-table `reset/0` survives only in `async: false` modules (and in `active_tasks_test`, which asserts cold foreign contexts).

### `EvoDashWeb.TestHelpers` (`test_helpers.ex`)

`flush_loading(view, marker, flunk_message, timeout \\ 5000)` waits for an async `Task.Supervisor`-backed LiveView load and returns the rendered HTML by polling `render/1` until `marker` disappears, then `flunk`s with `flunk_message` at the deadline.
The render is the expensive part of a poll (~0.2–2 ms: DOM-term copy + HTML build + a synchronous round-trip that also lets the view apply queued diffs); one render after the child exits is therefore a full sync point.
Poll interval is a CALL-TIME seam: `Application.get_env(:evo_dash, :flush_loading_poll_ms, 10)` (booted at 1 ms by `test_helper.exs`).
Render-skip gate: while a `EvoDash.TaskSupervisor` child whose `:"$callers"` contains the view pid is alive the load is provably unfinished, so the loop re-checks only that child (`Task.Supervisor.children/1` + one `Process.info/2`) and skips the render.
The skip is BOUNDED to 8 consecutive polls (`@max_skipped_polls`) and never decides the outcome — the marker alone ends the wait — because a view can own children that outlive the load (e.g. deliberately blocking `:merge_check_runner` stubs living 30 s on the same supervisor); an unbounded gate stalls such a flush for its whole timeout.
The gate is total and fails open (dead pid, non-conforming entry, missing supervisor → render), never raises and never blocks on a child.
Three suites delegate to it with their own marker and flunk message (`tasks_live_test`, `agents_live_test`, `review_live_test` — the review delegate runs its mount funnel first), keeping the helper call-site agnostic; `settings_live_test`, `settings_live_agents_test` and `projects_live_test` use their own `:"$callers"`-based mount funnels instead.
Measured effect: the review suite renders ~263 flushes per run with the gate in place and the wall clock is unchanged — treat the gate as render/CPU-work reduction, not a wall-clock optimization.

### Directory-picker fakes

`fake_directory_picker.ex` — `EvoDash.DirectoryPicker.Fake`, installed through the `:directory_picker_module` app env: `pick/2` and `pick/3 :directory` always deliver `{:ok, "/fake/picked/dir"}` while `pick/3 :file` delivers the `:persistent_term` value under `{__MODULE__, :file_result}` (default `{:ok, "/fake/picked/file.txt"}`), settable per test with `set_file_result/1` (`{:ok, path} | :cancelled | :unavailable`); call `Fake.reset()` in `on_exit` so the persistent_term value never leaks.
`fake_directory_picker_wx.ex` — `EvoDash.DirectoryPicker.Wx.Fake`, installed through `:directory_picker_wx`: `new_file_dialog/2` returns a `{:wx_ref, 1, :wxFileDialog, []}`-shaped ref, `get_path/1` dispatches on the ref type (`:wxFileDialog` → `"/fake/picked/file.txt"`, `:wxDirDialog` → `"/fake/picked/dir"`), and `set_gate/1` blocks the dialog kind-agnostically so busy-serialization tests work for both kinds.

### `EvoDash.Test.IsolatedTaskStore` (`isolated_task_store.ex`)

Deterministic per-test `EvoGit.Store` + `EvoGit.TaskRegistry` isolation for `async: false` suites: `isolate!/1(prefix)` terminates the production children under `EvoGit.Supervisor`, starts a same-named temp-sqlite pair under a supervisor this helper owns, and registers the ordered teardown.
Lifetime contract: the isolated supervisor is DELIBERATELY UNLINKED from the test process (`Process.unlink/1`), because ExUnit ends a test process with `exit(:shutdown)` BEFORE any `on_exit` callback runs — a linked pair would be torn down by the test's death at a moment where nothing can be ordered.
Teardown order is load-bearing: terminate `EvoGit.TaskRegistry` (no new read worker can spawn) → drain the read workers the registry already started (`await_read_workers/0` → `drain_read_workers/1`, monitor-based, bounded by a 10 s deadline, then a `Task.Supervisor.terminate_child` fallback) → terminate `EvoGit.Store` → stop the supervisor → `rm_rf` only its own `<tmp>/evogit_test_<prefix>_<int>` dir → restart the production children.
That ordering is what guarantees no `[error]` line can print: read workers live under the long-lived `EvoGit.TaskRegistry.ReadSupervisor`, so they outlive the isolated supervisor and would otherwise be mid-`GenServer.call(EvoGit.Store, …)` when the store stops.
The whole teardown runs inside `ExUnit.CaptureLog.capture_log/2` (its result is discarded) because `on_exit` executes outside ExUnit's per-test capture and killing a store with in-flight offloaded tasks logs expected crash reports; the setup-time `terminate_production!/0` needs no capture, since `setup` runs inside the test's own window.
Restores are CHECKED: `restart_child!` raises on `{:error, {:already_started, pid}}` and `{:error, :not_found}` instead of silently leaving the globals bound to a foreign instance, and `verify_restored!/0` re-checks the restored `EvoGit.Store`'s `data_dir` plus the registry's liveness.
`assert_production!/0` is the read-side guard for suites that use the production pair without isolating (every `ReviewLive*Test` module calls it in setup): it raises when `EvoGit.Store` is down or bound to a non-production data dir, or when `EvoGit.TaskRegistry` is down or bound to a foreign `task_store`.
`production_sqlite_path/0` mirrors `EvoGit.Application.start/2`'s derivation (`Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())` + `tasks.sqlite`).
`isolated_supervisor/0` exposes the last `isolate!/1` call's supervisor pid from the CALLING process's dictionary (`Process.get/1`), solely so `isolated_task_store_test.exs` can pin the unlink structurally (`refute self() in Process.info(sup, :links)`).

**Who still calls it (6 call sites, ≈174 calls per run)**: `home_live_test` (module setup, 74 tests), `tasks_live_test` (module setup, 81 tests), `node_aware_test` (the five describes carrying `setup :setup_isolated_registry`, 16 tests) and `isolated_task_store_test` (3 tests, one call each).
Every other store-touching suite uses the run-wide store idiom — per-test unique ids, id/`project_path`-anchored exact assertions, and `on_exit` cleanup through the DIRECT Store (`EvoGit.Store.delete_task(EvoGit.Store, id)`, never a `TaskRegistry` cast, so no `"tasks"` PubSub broadcast escapes) — because a per-test Store swap serialises a whole module against every other module and buys nothing when ids already make assertions exact.

**Measured cost: ≈6.5 ms per `isolate!/1` call end-to-end** — ≈1.7 ms for the production-pair restart, ≈4–5 ms for the teardown's `ExUnit.CaptureLog.capture_log/2` window (the log-window setup/teardown dominates), and sub-millisecond terminate/boot/restore work.
That figure is the reason nobody should "optimize" the helper further: at ≈174 calls per run it is ≈1.1 s of a ~18 s suite, so an `async: false` module's serialisation cost dwarfs its isolation cost.

### `EvoDash.Test.IsolatedVCT` (`isolated_vct.ex`)
`isolate!/1(opts)` gives a test a PRIVATE project registry: its own uniquely-named `EvoGit.VCT` over its own uniquely-named `EvoGit.Store` (sqlite seeded from `IsolatedTaskStore.store_template_path/0`) on a `<tmp>/evogit_vct-<os pid>-<int>-<random>` tree.
It isolates the mount TABLE only — mounts, workspaces, members and the project cap are per-test state, so no concurrent test can see or damage them.
It deliberately SHARES `EvoGit.PubSub`, so a mutation still broadcasts `{:vct_updated, node()}` on the same `"vct"` topic and a mounted page's broadcast-driven refresh is exercised exactly as in production.
It exists because the registry is a run-wide, store-backed SINGLETON: without it a bare `/projects` mount auto-activates a stranger's project and `clear_projects/0` destroys other tests' fixtures mid-run.
The designation travels through the SPAWN CHAIN: `isolate!/1` puts the instance name into the calling process dictionary under `:evogit_vct_server`, which `EvoDash.VCTScope` resolves through `$callers`/`$ancestors`, so a mounted page and its load tasks resolve the private instance with no `lib/` change.
`isolate!/1` also calls `EvoGit.Config.Cache.invalidate/0`, because booting its store settles this test's config snapshot while `config.toml` is still empty (tests write it directly, bypassing `save_user_config/1`'s reload event).
Teardown is ONE `on_exit` that STOPS the stack (`Supervisor.stop/1`, `:noproc` ignored) and only then removes the tree through `EvoDash.Test.FsCleanup.rm_rf!/1`; the supervisor is `Process.unlink/1`ed for the reason `IsolatedTaskStore` documents.
**Measured cost: ≈2 ms per `isolate!/1` call** (the pre-migrated template makes the boot migrator a verified no-op), which is why `projects_live_test.exs` runs all 182 of its tests against it.
### `EvoDash.Test.ConfigDir` (`config_dir.ex`)

Per-process config-dir isolation — the `:evo_dash` MIRROR of `EvoGit.TestSupport.ConfigDir` (which lives in `:evo_git`'s support dir and is not on this app's compile path).
It is the resolver behind the DEFAULT-INERT `:config_dir_fun` seam of `EvoGit.Platform.config_dir/1`, installed suite-wide by `test_helper.exs`; production never sets that key, so production resolution is unchanged.
API: `resolve/0` (the installed fun — own `:evogit_config_dir` dictionary entry, then the first override found in the process' SPAWN CHAIN — `$callers` then `$ancestors`, LOCAL-node pids — so a plain `GenServer` child, which never gets `$callers`, still resolves the test's override), `activate/1`, `isolate_module!/1` (unique `<tmp>/<prefix>-<os pid>-<int>-<random>` dir + `on_exit` cleanup + an owner marker, no dictionary write), `isolate!/1` (`isolate_module!` + `activate`, i.e. the plain-`setup` convenience, no marker), `config_dir/0` (`EvoGit.Platform.config_dir/0`, the concrete `<override>/genesis` path), `await_supervised_writers/2` (registrar-only drain, `:ok | :timeout`) and `await_dir_writers/3` (the cleanup drain: registrar, resolved destination, or recorded owner).
The OS pid and random components in the name are load-bearing: `System.unique_integer/1` is unique only within one BEAM, so two suites sharing one `TMPDIR` used to compute the same path and remove each other's LIVE dir mid-test.
A module-level dir records its activating pids as empty files under `<dir>/.evodash-owners/<pid>` (read back with `:erlang.list_to_pid/1`, no process needed); the registry sits INSIDE the dir so removal is self-cleaning and a marker for a dead pid is never matched.
**Cleanup invariant** — the `on_exit` removal captures the REGISTRAR pid (`self()` at `isolate_module!` time, i.e. the test process for `isolate!/1`) and FIRST waits, monitor-based and bounded (`@cleanup_writer_budget_ms` 5 s, re-scanning so a still-live view's next load is awaited too), for every live `EvoDash.TaskSupervisor` child attributable to this dir: its spawn chain (`$callers` then `$ancestors`) names the registrar, or resolves this dir, or names a pid recorded in the dir's owner registry; only then does it remove the tree through `EvoDash.Test.FsCleanup.rm_rf!/2`, with that same drain passed as the `:before_attempt` hook (it receives the removal's REMAINING window and runs before EVERY attempt).
The pid stays readable in the CHILD's dictionary after the test process died, which is what makes the drain deterministic (`ExUnit.OnExitHandler` runs `on_exit` after `exit(:shutdown)`).
Why it is required: the shared `EvoDash.TaskSupervisor` never stops children per test, and an async page load resolves `<override>/genesis` and writes a skeleton (`EvoGit.RemoteConnections.list/0` → `File.mkdir_p/1` + `File.write/2`), so removing the tree while such a child is in flight recreates it and fails `File.rm_rf` with `{:error, :eexist, _}` (the observed once-per-full-run `File.Error` inside `on_exit`).
`isolate!/1` and `isolate_module!/1` are the config directory's ONLY removal owner: `on_exit` is LIFO, so a suite registering its OWN raw `File.rm_rf!` for the same dir removes the tree FIRST with no drain at all and the drained callback is the one that loses the race — a second raw `File.rm_rf!` reinstates the flake by construction.
A re-creator whose spawn chain identifies no registrar and no recorded owner — a raw `spawn/1` — is covered by the primitive's single deadline rather than a fixed attempt count: the drain runs before EVERY attempt, so a writer that keeps winning the race is retried (20 ms cadence, one 10 s budget, paid only on that path) instead of counted, and per-test `isolate!/1` and module-level `isolate_module!` are both fully covered.
A non-transient removal error, or a transient one outliving the deadline, still raises `File.Error`, so a real failure keeps failing loudly.
Both apps' helpers share the same process-dictionary key, so a root `mix test` resolves identically whichever helper installed the fun last.
Spawn-chain inheritance covers `Task` children (`$callers`) AND `proc_lib` children (`$ancestors` — every `GenServer`/`Supervisor`, `Task.Supervisor.start_child/2` included, the `EvoDash.SafeCall` path) started from the test process, plus a `Phoenix.LiveViewTest` view (its channel sets `$callers` to the test pid, `deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:1297`); it does NOT cover a raw `spawn/1` or the boot-time app-global singletons (`EvoGit.AgentScheduler`, `EvoGit.TaskRegistry`, `EvoGit.Store`, `EvoGit.PeakHourEngine`, `EvoDash.ChatHistory`, `EvoDash.UpdateStatus`), so modules whose config reads happen inside those stay `async: false`.
Proof + usage contract, all three levels asserted empirically in `config_dir_test.exs`: `EvoDash.Test.ConfigDirTest` keeps the supervised-task inheritance, nested-task transitivity, `$ancestors`-only `GenServer` child (and its no-override `nil` counterpart), raw-spawn escape boundary and fallback redirect proofs async (4 tests), plus a `cleanup ordering (supervised writers)` describe that pins the drain (it waits for a supervised writer holding the test pid, whose late `mkdir_p` + write lands before removal, and it IGNORES a writer spawned from a foreign caller chain).
`EvoDash.Test.ConfigDirMountedTest` owns the positive mounted proof and is `async: true`: the Projects runner seams resolve through `EvoDash.Seam.get/2` on the caller's spawn chain, so another test's `:projects_async_load_runner` fixture cannot bypass its real configuration load.
The mounted proof asserts that no foreign batch runner is installed, checks the view's `$callers` chain, waits with a bounded poll for the real Projects `model_selection_ready?`, checks its sole canonical provider and selected spec, and verifies Settings' isolated config path and rendered provider action.
The shared fixture helper is defined before the async module, creates a unique config directory per test and never changes process-wide state; config-directory isolation itself remains async-safe.

### `EvoDash.Test.PersistedConfig` (`persisted_config.ex`)

`user_config/0` answers the user config of the CALLING test's own config directory from that directory's CURRENT bytes (`EvoGit.Config.Cache.reload/0`).
It exists because the production read `EvoGit.Config.user_config/0` answers a BEAM-global `:persistent_term` snapshot kept per config DIRECTORY, whose content is whichever refresh stored LAST (a save's synchronous reload, an explicit `Cache.reload/0,1`, or a `Cache.get/1` miss build), while a Settings pin asserts the persisted file.
`Cache.reload/0` builds from disk and answers ITS OWN build (the stored snapshot only when the two fingerprints, i.e. the content, are identical), so the value is correct even if another process stores a different snapshot immediately afterwards, and the pin still covers the RAM path the dashboard reads.
The directory resolves at call time in the calling process, so the per-test `EvoDash.Test.ConfigDir` override keeps every reload inside that test's own directory.
Used by the Settings suites' "what got persisted" assertions (`live/settings_live/provider_panel_live_test.exs`, `live/settings_live/provider_wizard_test.exs`).

### `EvoDash.Test.Seam` (`seam.ex`)
`put/2` installs an `EvoDash.Seam` override in the CALLING process dictionary (in an ExUnit test: the test process) and registers an `on_exit` restore; `delete/1` clears it mid-test and `put_all/1` installs a keyword list.
It never writes app env, so the override reaches exactly the pages, LiveView processes and `EvoDash.TaskSupervisor` children descended from the test and nothing else — two `async: true` modules can hold different fixtures for the same seam at the same time, with nothing to restore and nothing to serialize.
The consumer side is `EvoDash.Seam.get/2` (own dictionary, then `$callers`, then `$ancestors`, then `Application.get_env(:evo_dash, key, default)`), so a fixture for a seam a page or load task reads needs no app-env write, while a raw `spawn/1` or a boot-time singleton resolves the production value.
Only a seam consumed by a BOOT-time singleton (today `EvoDash.DirectoryPicker`'s `:directory_picker` / `:directory_picker_module`) stays on app env.
Proof: `test/evo_dash_web/live/projects_live/seam_scope_test.exs`.
### `EvoDash.Test.FsCleanup` (`fs_cleanup.ex`)

`rm_rf!/2(path, opts \\ [])` is the ONE deadline-bounded recursive removal for a test-owned temp tree: `File.rm_rf/1` lists, deletes, then `rmdir`s the parent, so a LIVE writer in between fails the final rmdir with `{:error, :eexist, _}` (`:enotempty` on other filesystems) and `File.rm_rf!/1` raises a `File.Error` ExUnit attributes to the wrong test.
It retries ONLY those transient reasons until ONE deadline (`:budget_ms`, default 10 s, `:retry_delay_ms` cadence 20 ms) — paid only when a writer actually keeps winning the race — and calls the `:before_attempt` hook with the REMAINING window before EVERY attempt, including the first.
Any other reason, or a transient one outliving the deadline, logs a `Logger.error` naming the root path and the residual entries, then raises `File.Error`, so a genuinely unremovable tree still fails loudly.
The config-dir seam is its first caller (it passes its writer drain as `:before_attempt`); proven by `fs_cleanup_test.exs`, an uncompiled ExUnit script in this directory.

### `EvoDash.Test.ChatGPTLoginStub` (`chatgpt_login_stub.ex`)

Hermetic per-test stand-in for `EvoDash.ChatGPTLogin`, installed through `EvoDashWeb.LLMSetup.ChatGPTSignIn.login_module/0`'s CALL-TIME `$callers` seam (`:chatgpt_login_module`) plus the per-test Agent pid under `:chatgpt_stub_pid`.
`install!/1(begin: {...}, statuses: [...])` starts the Agent in the CALLING process's dictionary, shrinks the poll to 5 ms and seeds the SIWC call-budget seam (`Process.put(:chatgpt_signin_call_timeout_ms, 30_000)`); `begin/2`, `status/1` and `cancel/1` resolve the Agent through `$callers` too, because the boundary calls from `Task.async`/poll tasks, never only from the view.
Every call notifies the test pid (`{:chatgpt_stub, :begin, account}` / `:status` / `:cancel`) and a cancelled flow always answers `:pending`, so no loopback listener, network or BEAM-global state is involved.
Used by `live/settings_live/provider_wizard_test.exs` (wizard surface) and the generalized-sign-in suites `chatgpt_sign_in_state_test.exs` / `chatgpt_sign_in_surfaces_test.exs` (detail + status surfaces).

### Migrated-sqlite template

`EvoGit.Store` always runs the Ecto migrations at boot (`EvoGit.Store.Boot.start_dynamic/2` → `Ecto.Migrator.run(…, all: true)`), which on a brand-new file means the whole baseline-adoption DDL (~10 ms of the ~11 ms fresh boot, the dominant term); the same boot against an already-migrated file is ~0.9 ms.
So the helper builds the migrated template ONCE per run at `<evo_git data_dir>/isolated_store_template.sqlite` (resolved lazily BEFORE the production pair is touched) and every `isolate!/1` seeds its private `tasks.sqlite` with a ~0.07 ms `File.cp/2` of the template's MAIN file alone.
That path is unique PER BEAM RUN: `config/test.exs` derives the data dir from the OS pid plus an Erlang-unique integer.
The build is ATOMIC — `build_attempt/2` migrates a dot-prefixed, per-attempt unique build path in the destination's own directory, `verify_template/1` proves the artifact there, and `publish_template/2` makes it read-only and then `File.rename/2`s it onto the destination, so the published name only ever exists complete and read-only and two builders can never migrate the same file.
The migrated schema is flushed with an explicit `PRAGMA wal_checkpoint(TRUNCATE)` before the rename — required, because a plain clean close left the DDL in a still-present `-wal` in 25 of 30 measured builds.
`verify_template/1` copies the main file alone and asserts every `EvoGit.Store.Boot.migration_source/0` version is applied (0.2 ms, once per run); its `{:error, detail}` (`mismatch` with both version lists, or `unreadable` with the adapter message) is exactly what the failure warning reports.
**A failed build is NEVER cached**: only a build that passed its self-check publishes a `:persistent_term` path, so one interrupted build is retried by the next caller (bounded to `@build_attempts` attempts per call, no `Process.sleep`) instead of being handed to every caller for the rest of the run.
A build that RAISES on every attempt keeps raising, with the attempt count, the destination and the underlying cause in the banner; a self-check or publish failure ends as ONE `Logger.warning` naming the attempts, the failure and the path, i.e. no template for that call only.
What a caller may assume: `store_template_path/0` answers either `nil` (no template — boot a fresh database, correct and slower) or a path whose file already exists and is read-only, because every call re-checks the cached path with one `File.stat/1` and rebuilds it when the artifact was deleted behind the helper's back.
`seed_store!/1` copies that main file, and a copy that fails because the artifact vanished between the check and the copy drops the cache entry and rebuilds once; a missing DESTINATION directory still raises, so the two `:enoent` causes are told apart.
Pinned by `test/evo_dash/isolated_task_store_test.exs`: a deleted template is rebuilt rather than handed out dead, and a forced failed build leaves no cached entry (the next call produces a working, fully migrated template).
No template is built when the `:evo_git, :data_dir` app env is absent — deliberately no fallback to `EvoGit.Platform.data_dir/0`, which is the developer's real data dir on macOS.
Measured per-call breakdown: ~0.9 ms already-migrated boot + ~0.07 ms copy + ~1.7 ms production-pair restart, on top of the ≈4–5 ms log-capture window described above.

## Constraints

- Keep support modules free of test logic and assertions.
- `config_dir_test.exs` / `fs_cleanup_test.exs` are TEST files placed here because each proves one support module: only `*.ex` files are compiled through `elixirc_paths(:test)`, so a `_test.exs` is loaded by ExUnit as an ordinary test file (and carries the assertions).
- Keep the isolation helper's shutdown ORDER (registry → read-worker drain → store → supervisor) and the unlink; both are load-bearing for zero stray console output.
- **Two concurrent runs of the same suite under one `TMPDIR` collide**: isolated roots are `<tmp>/evogit_test_<prefix>_<unique_integer>`, and `System.unique_integer/1` is unique only WITHIN one BEAM.
  Symptoms look unrelated — `isolated_task_store_test.exs`'s `assert [^root] = isolated_root_dirs()` failing, a `File.CopyError` while seeding, then a cascade of `EvoGit.Store`/`EvoGit.TaskRegistry` "no process" failures (a failed `isolate!/1` leaves the production children terminated for the rest of that run).
  Genesis worker tasks share one per-task `TMPDIR`, which is exactly that condition; give one run a private `export TMPDIR=$(mktemp -d)` (or re-run standalone) before suspecting a real regression.
  Within ONE run the contract above is untouched: isolated roots are unique.
- Test-support modules must not be called from `lib/`.
