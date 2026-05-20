# Test Directory

## Intent
Holds all test files for the EvoDash application. Provides the ExUnit test runner configuration and shared test support modules (e.g., `ConnCase`) used across controller and endpoint tests.

## API Surface

### Top-Level
- `test_helper.exs` — Bootstraps ExUnit (`ExUnit.start()`). Entry point for the test suite.

### `support/`
- `conn_case.ex` — `EvoDashWeb.ConnCase` module: a shared `ExUnit.CaseTemplate` for connection-based tests. Provides:
  - Endpoint registration (`@endpoint EvoDashWeb.Endpoint`)
  - Verified routes via `use EvoDashWeb, :verified_routes`
  - Imports: `Plug.Conn`, `Phoenix.ConnTest`, and the case module itself
  - Default setup returning a built `%Conn{}`

### `evo_dash_web/controllers/`
- `page_controller_test.exs` — `EvoDashWeb.PageControllerTest` — Verifies the root `GET /` returns 200 and contains "EvoGit Dashboard".
- `error_html_test.exs` — `EvoDashWeb.ErrorHTMLTest` — Validates HTML error templates (404 → "Not Found", 500 → "Internal Server Error").
- `error_json_test.exs` — `EvoDashWeb.ErrorJSONTest` — Validates JSON error responses (404/500 with appropriate `%{errors: %{detail: ...}}` shape).

## Routing Table

This directory has no child subdirectories — all test work is handled by the individual test files within this directory, organized by source path (e.g., `evo_dash_web/controllers/`). The `support/` subdirectory contains shared test helpers (e.g., `conn_case.ex`). For any test additions or modifications, work directly on the relevant file in this node; no subagent delegation to child paths is needed.

## Constraints
- Follow standard Phoenix test conventions: mirror the `lib/` directory structure under `test/`.
- All connection-based tests must `use EvoDashWeb.ConnCase`.
- Support modules live in `support/` and are compiled automatically by Mix.
- Test file naming: `*_test.exs`.
- No LiveView tests exist yet; add them under `evo_dash_web/live/` when needed.
- The suite is minimal and currently covers only the page controller and error modules.
