# Test Support

## Intent

Test support modules for the EvoDash test suite. Provides shared test cases and helpers.

## Routing Table

None — leaf directory (test support modules only).

## API Surface

### `EvoDashWeb.ConnCase`

An ExUnit `CaseTemplate` for tests requiring a Phoenix connection. Uses `Phoenix.ConnTest`, sets `@endpoint EvoDashWeb.Endpoint`, and imports `Plug.Conn` and `Phoenix.ConnTest` conveniences.

### `EvoDashWeb.TestHelpers`

Shared test helpers (no test logic). `flush_loading/4` waits for an async `Task.Supervisor`-backed LiveView load to finish: it polls `Phoenix.LiveViewTest.render/1` until a loading marker string disappears from the HTML (10ms interval, default 5000ms timeout) and returns the rendered HTML, or `flunk`s with the given message on timeout. Used by `agents_live_test.exs`, `review_live_test.exs`, and `tasks_live_test.exs` (each keeps a one-line local delegate with its marker/flunk message).

## Constraints

- Test support modules should not contain test logic — only setup, helpers, and shared configuration.
- Keep test cases in the test directories they serve.
