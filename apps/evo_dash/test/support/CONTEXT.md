# Test Support

## Intent

Test support modules for the EvoDash test suite. Provides shared test cases, helpers, and fakes.

## Routing Table

None — leaf directory (test support modules only).

## API Surface

### `EvoDashWeb.ConnCase`

An ExUnit `CaseTemplate` for tests requiring a Phoenix connection. Uses `Phoenix.ConnTest`, sets `@endpoint EvoDashWeb.Endpoint`, and imports `Plug.Conn` and `Phoenix.ConnTest` conveniences.

Its `setup` also resets the shared `EvoDash.ActiveTasks` sidebar hub: `EvoDash.ActiveTasks.reset()` in setup plus an `on_exit` reset, so a snapshot (or junk sentinel) leaked by an earlier suite never seeds a later whole-page mount and this suite's own writes never leak onward.

### `EvoDashWeb.TestHelpers`

Shared test helpers (no test logic). `flush_loading/4` waits for an async `Task.Supervisor`-backed LiveView load to finish and returns the rendered HTML: it polls `Phoenix.LiveViewTest.render/1` until a loading marker string disappears from the HTML, and `flunk`s with the given message if the marker is still there when the timeout elapses (default `5000` ms) — `render_async/2` does NOT await `Task.Supervisor` children, and `render/1` doubles as the sync point (its synchronous ping makes the view process apply queued diffs before the proxy's cached tree is read), so ONE render after the child exits is a full sync. Used by `agents_live_test.exs`, `review_live_test.exs`, and `tasks_live_test.exs` (each keeps a one-line local delegate with its marker/flunk message — the helper stays call-site agnostic). The poll interval is a CALL-TIME app-env seam (`Application.get_env(:evo_dash, :flush_loading_poll_ms, 10)`, booted at 1 ms by `test_helper.exs`).

**Render-skip gate (why it is cheap).** A render is the expensive part of a poll iteration (~0.2–2 ms measured: DOM-term copy + HTML build + a round-trip to the view), so while a `EvoDash.TaskSupervisor` child whose `:"$callers"` contains the view pid is alive the load is provably unfinished and the loop skips the render, re-checking only that child (`Task.Supervisor.children/1` + one `Process.info/2` per child — tens of µs; `Task.Supervisor.start_child/2` records `[spawner | spawner's $callers]`, the same signal `settings_live_test.exs`'s mount funnel uses). The skip is BOUNDED to `@max_skipped_polls` (8) consecutive polls and never decides the outcome — the marker alone ends the wait (a cleared marker is observed at most ~8 polls later; a never-clearing marker still flunks at the deadline, checked in both branches), and the FIRST iteration always renders, so an already-finished load costs exactly the single render it costs with no gate and returns immediately. The bound is load-bearing, not cosmetic: a view can own children that outlive the load it is waiting for (`review_live_test.exs`'s deliberately blocking `:merge_check_runner` stubs live 30 s on the same supervisor), so an unbounded "a child is alive → keep sleeping" gate stalls such a flush for its whole timeout — measured on the single test at `review_live_test.exs:506`: 1.5 s bounded vs 6.4 s with the bound raised to `100_000` (the flush burned the full 5 s deadline). The gate is total and fails open (dead pid / non-conforming entry / missing supervisor → "not pending" → render), never raises, and never blocks on a child.

**Measured effect** (temporary `:counters` instrumentation, whole-file runs): `review_live_test.exs` renders per run 1220 → 263 (the gate fired on 790 polls) and BEAM user CPU ~21 s → ~20 s; `tasks_live_test.exs` and `agents_live_test.exs` are effectively unaffected (their loads are usually already finished at flush time — ~1.0 render per flush before and after), paying only the ~60 µs/poll gate check. WALL clock is unchanged in every measured condition (single file ×2 interleaved rounds, full suite ×4 rounds, and a full suite pinned to 4 cores ×2 rounds: all deltas within noise and sign-flipping) — the skipped renders are off the critical path, because a flush's wall time is dominated by the async load's own duration and the poll cadence, not by the test process's render work. Treat this change as render/CPU-work reduction, not as a wall-clock optimization.

### Directory-picker fakes

- `fake_directory_picker.ex` — `EvoDash.DirectoryPicker.Fake` (installed via the `:directory_picker_module` app env): module-level fake for the directory/file picker, used by the ProjectsLive directory-picker and file-attach tests.
- `fake_directory_picker_wx.ex` — `EvoDash.DirectoryPicker.Wx.Fake` (installed via the `:directory_picker_wx` app env): fake wx seam with ref-typed `get_path/1` dispatch (`:wxFileDialog` vs `:wxDirDialog`), used by `directory_picker_test.exs` and the file-attach tests. Mirrors the real seam's type-dispatched `show_modal`/`get_path`/`destroy`.

### `EvoDash.Test.IsolatedTaskStore`

Deterministic per-test `EvoGit.Store` / `EvoGit.TaskRegistry` isolation for `async: false` suites. `isolate!/1(prefix)` terminates the production children (`EvoGit.Supervisor`, NOT `EvoDash.Supervisor`), starts a temp-sqlite pair under a supervisor this module owns, and registers an `on_exit` that stops the isolated pair FIRST, `rm_rf`s only its own `<tmp>/evogit_test_<prefix>_<int>` dir, then restarts the production children with CHECKED results (a failed restore raises) and verifies the restored `EvoGit.Store`'s `data_dir`. `assert_production!/0` is the read-side guard for suites that use the production pair without isolating; `production_sqlite_path/0` mirrors `EvoGit.Application.start/2`'s derivation.

Only the `on_exit` teardown runs inside `ExUnit.CaptureLog.capture_log/2`: it executes outside ExUnit's per-test log capture, and killing a Store with in-flight offloaded Tasks makes those Tasks crash on the vanished ETS query cache. The setup-time `terminate_production!/0` needs NO capture — `isolate!/1` runs from `setup`, which ExUnit's `capture_log: true` already wraps along with the test body (`ExUnit.Runner.maybe_capture_log/3`), so a capture there would only pay the per-window cost for nothing.

Measured cost per `isolate!/1` call (whole `evo_dash` suite, ~204 calls): ~16 ms for the isolated Store boot — fresh sqlite plus the Ecto migrations `EvoGit.Store.start_link/1` always runs at boot, the dominant term by far; ~4 ms for the production restart (already-migrated schema, so those migrations are a no-op); sub-ms for everything else, including `stop_isolated/1`, which takes its cheap `:ok` branch because the isolated supervisor is linked to the test process and is already dead when `on_exit` runs. There is no cheaper provably-safe boot path.

Used by `test/evo_dash/node_context_test.exs`, `test/evo_dash_web/live_hooks/guide_test.exs`, `test/evo_dash_web/live_hooks/node_aware_test.exs`, `test/evo_dash_web/live/home_live_test.exs`, `test/evo_dash_web/live/tasks_live_test.exs` (`assert_production!/0` additionally by `test/evo_dash_web/live/review_live_test.exs`).

## Constraints

- Test support modules should not contain test logic — only setup, helpers, and shared configuration.
- Keep test cases in the test directories they serve.
