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
- `task_registry_test.exs` — `EvoDash.TaskRegistryTest` — Covers cleanup_expired_tasks (age/count limits, running/pending preservation), set_review_metadata, TaskInfo field backfill (normalize_tasks backfills base_sha/commit_sha as nil), persistence (get_task retrieves seeded tasks; tasks survive registry restart with the same store), recent projects round-trip persistence (project survives registry restart with same store), projects table schema migration (self-heals a stale `path`-PK schema to `id` via TaskStore init repair, migrating rows), and GenServer resilience (registry stays alive and preserves task state across mutation operations that trigger cleanup). Uses an isolated TaskRegistry + TaskStore (unique temp root + SQLite database file; terminates production children and restarts them in `on_exit`, `async: false`).
- `markdown_render_test.exs` — `EvoDash.MarkdownRenderTest` — Markdown-to-HTML rendering edge cases (nil, empty, headings, code blocks, tables, bold).

### `evo_dash_web/live/`
- `settings_live_test.exs` — `EvoDashWeb.SettingsLiveTest` — Settings page: search input rendering, search handler (value-key matching, results panel, no-results message, clear-to-category-view), and search-input-within-form regression. Also covers custom model providers (OpenRouter / OpenAI-Compatible): form rendering (model name, base URL, placeholders, warning, hidden quick-select buttons), saving (openrouter: spec pre-fill + openai-compatible map spec pre-fill), and validation errors (empty model name, empty base URL). NOTE: these custom-model tests render the LLM category via `select_category`, which currently crashes due to a pre-existing `:model_spec` gap in `setting_card` (see note below).
- `tasks_live_test.exs` — `EvoDashWeb.TasksLiveTest` — Cross-project task list: search (by prompt/objective/ID, case-insensitive), filter selects, reset. Includes regression tests for the `:finalizing` crash fix: `handle_info({:task_status, _, :finalizing})` and the catch-all `handle_info(_msg, _)` clauses no longer crash the LiveView when broadcast on the `EvoGit.PubSub` "tasks" topic. Uses an isolated TaskRegistry + TaskStore (unique temp root + SQLite database file; terminates production children and restarts them in `on_exit`, `async: false`).
- `review_live_test.exs` — `EvoDashWeb.ReviewLiveTest` — Review page: non-existent task error display, and the "ignore" action (button always shown; clicking sets review_status to :ignored and navigates to dashboard). Uses the production TaskRegistry + TaskStore directly (seeds tasks via EvoDash.TaskStore.put, cleans up via delete_task).
- `error_html_test.exs` — `EvoDashWeb.ErrorHTMLTest` — Validates HTML error templates (404 → "Not Found", 500 → "Internal Server Error").
- `error_json_test.exs` — `EvoDashWeb.ErrorJSONTest` — Validates JSON error responses (404/500 with appropriate `%{errors: %{detail: ...}}` shape).

## Constraints
- Follow standard Phoenix test conventions: mirror the `lib/` directory structure under `test/`.
- All connection-based tests must `use EvoDashWeb.ConnCase`.
- Support modules live in `support/` and are compiled automatically by Mix.
- Test file naming: `*_test.exs`.
- Tests requiring an isolated TaskRegistry/TaskStore terminate the production children from `EvoDash.Supervisor` and restart them via `Supervisor.restart_child/2` in `on_exit` to avoid breaking other suites.
- All task persistence in tests goes through `EvoDash.TaskStore` (SQLite-backed, namespaced `{:task, id}` keys) — no DETS or CubDB is used.
