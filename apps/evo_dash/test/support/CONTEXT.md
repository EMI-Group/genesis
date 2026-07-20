# CONTEXT — Test Support

## Intent

Test support modules for the EvoDash test suite. Provides shared test cases and helpers.

## API Surface

### `EvoDashWeb.ConnCase`

An ExUnit `CaseTemplate` for tests requiring a Phoenix connection. Uses `Phoenix.ConnTest`, sets `@endpoint EvoDashWeb.Endpoint`, and imports `Plug.Conn` and `Phoenix.ConnTest` conveniences.

## Constraints

- Test support modules should not contain test logic — only setup, helpers, and shared configuration.
- Keep test cases in the test directories they serve.

## Routing Table

None — leaf directory.
