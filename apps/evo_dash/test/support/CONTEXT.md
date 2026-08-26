# Test Support

## Intent

Test support modules for the EvoDash test suite. Provides shared test cases, helpers, and fakes.

## Routing Table

None — leaf directory (test support modules only).

## API Surface

### `EvoDashWeb.ConnCase`

An ExUnit `CaseTemplate` for tests requiring a Phoenix connection. Uses `Phoenix.ConnTest`, sets `@endpoint EvoDashWeb.Endpoint`, and imports `Plug.Conn` and `Phoenix.ConnTest` conveniences.

### `EvoDashWeb.TestHelpers`

Shared test helpers (no test logic). `flush_loading/4` waits for an async `Task.Supervisor`-backed LiveView load to finish: it polls `Phoenix.LiveViewTest.render/1` until a loading marker string disappears from the HTML (10ms interval, default 5000ms timeout) and returns the rendered HTML, or `flunk`s with the given message on timeout — `render_async/2` does NOT await TaskSupervisor children. Used by `agents_live_test.exs`, `review_live_test.exs`, and `tasks_live_test.exs` (each keeps a one-line local delegate with its marker/flunk message).

### Directory-picker fakes

- `fake_directory_picker.ex` — `EvoDash.DirectoryPicker.Fake` (installed via the `:directory_picker_module` app env): module-level fake for the directory/file picker, used by the ProjectsLive directory-picker and file-attach tests.
- `fake_directory_picker_wx.ex` — `EvoDash.DirectoryPicker.Wx.Fake` (installed via the `:directory_picker_wx` app env): fake wx seam with ref-typed `get_path/1` dispatch (`:wxFileDialog` vs `:wxDirDialog`), used by `directory_picker_test.exs` and the file-attach tests. Mirrors the real seam's type-dispatched `show_modal`/`get_path`/`destroy`.

## Constraints

- Test support modules should not contain test logic — only setup, helpers, and shared configuration.
- Keep test cases in the test directories they serve.
