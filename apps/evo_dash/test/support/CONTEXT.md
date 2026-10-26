# Test Support

## Intent

Shared, production-free support modules for the EvoDash suite: the connection case template, the async-load flush helper, the two directory-picker fakes, and the Store/TaskRegistry isolation helper.
Compiled only in `:test` via `elixirc_paths(:test) = ["lib", "test/support"]` (`apps/evo_dash/mix.exs`).
Modules here carry setup, helpers and fakes only — never test logic or assertions.

## Routing Table

Leaf directory — no child directories.

## API Surface

### `EvoDashWeb.ConnCase` (`conn_case.ex`)

ExUnit `CaseTemplate` for tests needing a Phoenix connection: sets `@endpoint EvoDashWeb.Endpoint`, `use EvoDashWeb, :verified_routes`, imports `Plug.Conn` + `Phoenix.ConnTest`, and its default setup returns `{:ok, conn: build_conn()}`.
Its setup also resets the shared `EvoDash.ActiveTasks` sidebar hub (`EvoDash.ActiveTasks.reset()` plus an `on_exit` reset), so a snapshot or junk sentinel leaked by an earlier suite never seeds a later whole-page mount and this suite's own writes never leak onward.
`async:` is NOT set by the template, so `use EvoDashWeb.ConnCase` without an option yields `async: false` (used by `page_controller_test` and `projects_live_test`).
The two async ConnCase users (`error_html_test`, `error_json_test`) are pure render tests that never read the hub, which is why the reset stays safe for them.

### `EvoDashWeb.TestHelpers` (`test_helpers.ex`)

`flush_loading(view, marker, flunk_message, timeout \\ 5000)` waits for an async `Task.Supervisor`-backed LiveView load and returns the rendered HTML by polling `render/1` until `marker` disappears, then `flunk`s with `flunk_message` at the deadline.
The render is the expensive part of a poll (~0.2–2 ms: DOM-term copy + HTML build + a synchronous round-trip that also lets the view apply queued diffs); one render after the child exits is therefore a full sync point.
Poll interval is a CALL-TIME seam: `Application.get_env(:evo_dash, :flush_loading_poll_ms, 10)` (booted at 1 ms by `test_helper.exs`).
Render-skip gate: while a `EvoDash.TaskSupervisor` child whose `:"$callers"` contains the view pid is alive the load is provably unfinished, so the loop re-checks only that child (`Task.Supervisor.children/1` + one `Process.info/2`) and skips the render.
The skip is BOUNDED to 8 consecutive polls (`@max_skipped_polls`) and never decides the outcome — the marker alone ends the wait — because a view can own children that outlive the load (e.g. deliberately blocking `:merge_check_runner` stubs living 30 s on the same supervisor); an unbounded gate stalls such a flush for its whole timeout.
The gate is total and fails open (dead pid, non-conforming entry, missing supervisor → render), never raises and never blocks on a child.
Three suites delegate to it with their own marker and flunk message (`tasks_live_test`, `agents_live_test`, `review_live_test` — the review delegate runs its mount funnel first), keeping the helper call-site agnostic; `settings_live_test` and `projects_live_test` use their own `:"$callers"`-based mount funnels instead.
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
`assert_production!/0` is the read-side guard for suites that use the production pair without isolating (`review_live_test.exs` calls it in setup): it raises when `EvoGit.Store` is down or bound to a non-production data dir, or when `EvoGit.TaskRegistry` is down or bound to a foreign `task_store`.
`production_sqlite_path/0` mirrors `EvoGit.Application.start/2`'s derivation (`Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())` + `tasks.sqlite`).
`isolated_supervisor/0` exposes the last `isolate!/1` call's supervisor pid from the CALLING process's dictionary (`Process.get/1`), solely so `isolated_task_store_test.exs` can pin the unlink structurally (`refute self() in Process.info(sup, :links)`).

### Migrated-sqlite template

`EvoGit.Store` always runs the Ecto migrations at boot (`EvoGit.Store.Boot.start_dynamic/2` → `Ecto.Migrator.run(…, all: true)`), which on a brand-new file means the whole baseline-adoption DDL (~10 ms of the ~11 ms fresh boot, the dominant term); the same boot against an already-migrated file is ~0.9 ms.
So the helper builds the migrated template ONCE per run at `<evo_git data_dir>/isolated_store_template.sqlite` (resolved lazily BEFORE the production pair is touched) and every `isolate!/1` seeds its private `tasks.sqlite` with a ~0.07 ms `File.cp!/2` of the template's MAIN file alone.
The template is built through the same `EvoGit.Store.Boot.start_dynamic/2` (`pool_size: 1`) and then flushed with an explicit `PRAGMA wal_checkpoint(TRUNCATE)` — required, because a plain clean close left the DDL in a still-present `-wal` in 25 of 30 measured builds.
The build then self-checks by copying the main file alone and asserting every `EvoGit.Store.Boot.migration_source/0` version is applied (0.2 ms, once per run); a failing template is discarded with a `Logger.warning` and the run boots fresh databases (correct, unoptimized).
No template is built when the `:evo_git, :data_dir` app env is absent — deliberately no fallback to `EvoGit.Platform.data_dir/0`, which is the developer's real data dir on macOS.
Measured cost per `isolate!/1`: ~0.9 ms already-migrated boot + ~0.07 ms copy + ~1.7 ms production-pair restart (~204 calls per suite run).

## Constraints

- Keep support modules free of test logic and assertions.
- Keep the isolation helper's shutdown ORDER (registry → read-worker drain → store → supervisor) and the unlink; both are load-bearing for zero stray console output.
- **Two concurrent runs of the same suite under one `TMPDIR` collide**: isolated roots are `<tmp>/evogit_test_<prefix>_<unique_integer>`, and `System.unique_integer/1` is unique only WITHIN one BEAM.
  Symptoms look unrelated — `isolated_task_store_test.exs`'s `assert [^root] = isolated_root_dirs()` failing, a `File.CopyError` while seeding, then a cascade of `EvoGit.Store`/`EvoGit.TaskRegistry` "no process" failures (a failed `isolate!/1` leaves the production children terminated for the rest of that run).
  Genesis worker tasks share one per-task `TMPDIR`, which is exactly that condition; give one run a private `export TMPDIR=$(mktemp -d)` (or re-run standalone) before suspecting a real regression.
  Within ONE run the contract above is untouched: isolated roots are unique.
- Test-support modules must not be called from `lib/`.
