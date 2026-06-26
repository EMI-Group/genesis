# Test Directory

## Intent
Holds all test files for the EvoDash application. Provides the ExUnit test runner configuration and shared test support modules (e.g., `ConnCase`) used across controller and endpoint tests.

## Routing Table
- `support/` → Shared test support modules (ConnCase for connection-based tests)
- `evo_dash_web/` → Web-layer tests (controller tests, error handler tests)

## API Surface

### Top-Level
- `test_helper.exs` — Bootstraps ExUnit (`ExUnit.start()`). Entry point for the test suite.

### `support/`
- `conn_case.ex` — `EvoDashWeb.ConnCase` module: a shared `ExUnit.CaseTemplate` for connection-based tests. Provides:
  - Endpoint registration (`@endpoint EvoDashWeb.Endpoint`)
  - Verified routes via `use EvoDashWeb, :verified_routes`
  - Imports: `Plug.Conn`, `Phoenix.ConnTest`, and the case module itself
  - Default setup returning a built `%Conn{}`

### `evo_dash/`
- `task_registry_test.exs` — `EvoDash.TaskRegistryTest` — Covers cleanup_expired_tasks (age/count limits, running/pending preservation), set_review_metadata, DETS backfill of new TaskInfo fields, DETS corruption safety (`from_dets/3` converts `{:error, _}` → `[]`; `safe_match_object`/`safe_lookup` on healthy tables), and GenServer resilience (registry stays alive and preserves task state across mutation operations that trigger cleanup). Uses an isolated TaskRegistry (unique temp data_dir + test DETS table names, `async: false`).
- `markdown_render_test.exs` — `EvoDash.MarkdownRenderTest` — Markdown-to-HTML rendering edge cases (nil, empty, headings, code blocks, tables, bold).

### `evo_dash_web/live/`
- `tasks_live_test.exs` — `EvoDashWeb.TasksLiveTest` — Cross-project task list: search (by prompt/objective/ID, case-insensitive), filter selects, reset. Includes regression tests for the `:finalizing` crash fix: `handle_info({:task_status, _, :finalizing})` and the catch-all `handle_info(_msg, _)` clauses no longer crash the LiveView when broadcast on the `EvoGit.PubSub` "tasks" topic.
- `error_html_test.exs` — `EvoDashWeb.ErrorHTMLTest` — Validates HTML error templates (404 → "Not Found", 500 → "Internal Server Error").
- `error_json_test.exs` — `EvoDashWeb.ErrorJSONTest` — Validates JSON error responses (404/500 with appropriate `%{errors: %{detail: ...}}` shape).

## Constraints
- Follow standard Phoenix test conventions: mirror the `lib/` directory structure under `test/`.
- All connection-based tests must `use EvoDashWeb.ConnCase`.
- Support modules live in `support/` and are compiled automatically by Mix.
- Test file naming: `*_test.exs`.
- No LiveView tests exist yet; add them under `evo_dash_web/live/` when needed.
- The suite is minimal and currently covers only the page controller and error modules.
