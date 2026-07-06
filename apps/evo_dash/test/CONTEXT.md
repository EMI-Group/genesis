# Test Directory

## Intent
Holds all test files for the EvoDash application. Provides the ExUnit test runner configuration and shared test support modules (e.g., `ConnCase`) used across controller and endpoint tests.

## Routing Table
- `support/` → Shared test support modules (ConnCase for connection-based tests, TaskRegistryCase for TaskRegistry tests)
- `evo_dash/` → Domain-layer tests (Store, MarkdownRender, and TaskRegistry split suite)
- `evo_dash/task_registry/` → Focused TaskRegistry tests — cleanup, persistence, store integrity, reconciliation, lease & heartbeat
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
- `task_registry_case.ex` — `EvoDash.TaskRegistryCase` module: a shared `ExUnit.CaseTemplate` for TaskRegistry tests. Provides:
  - Isolated Store + TaskRegistry setup on a temporary SQLite database (terminates production children, starts supervised replacements, cleans up on exit)
  - Helper functions: `trigger_cleanup!/0`, `cleanup_process/1`, `old_age_days/0`, `within_age_days/0`, `restart_registry!/1`
  - Aliases for `EvoDash.TaskRegistry` and `EvoDash.TaskInfo` in the `using` block

### `evo_dash/`
- `store_test.exs` — `EvoDash.StoreTest` — Column-based SQLite round-trip tests for all TaskInfo/RecentProject field types (scalars, DateTime, opts keyword lists, logs, result tuples, usage structs, archive_metadata, atom fields). Covers quarantine/integrity_check (undecodable rows quarantined, not destroyed) and atom-field round-trip safety (encode_atom/decode_atom regression — no crashes on string values in atom fields, unknown values decode to nil). Uses an isolated Store with a unique tmp SQLite path (`async: false`; terminates and restarts production children).
- `markdown_render_test.exs` — `EvoDash.MarkdownRenderTest` — Markdown-to-HTML rendering edge cases (nil, empty, headings, code blocks, tables, bold).

### `evo_dash/task_registry/` — Focused TaskRegistry test suite (split from former `task_registry_test.exs`)
- `cleanup_test.exs` — `EvoDash.TaskRegistry.CleanupTest` — task_history_config defaults (1 test) and cleanup_expired_tasks (age-based removal, recent preservation, running/pending protection, combined age+count limits — 4 tests).
- `persistence_test.exs` — `EvoDash.TaskRegistry.PersistenceTest` — set_review_metadata (4 tests), TaskInfo field backfill (2 tests), CRUD persistence (2 tests), recent projects persistence (1 test), GenServer resilience (2 tests), corruption resilience — structural (3 tests), archive_metadata (3 tests), status recovery from spurious :failed (5 tests).
- `store_integrity_test.exs` — `EvoDash.TaskRegistry.StoreIntegrityTest` — Store.integrity_check: healthy store → :ok, undecodable TASKS rows hard-deleted + repaired count, undecodable PROJECTS rows QUARANTINED (3 tests).
- `reconciliation_test.exs` — `EvoDash.TaskRegistry.ReconciliationTest` — restart reconciliation (normalize_tasks liveness check): live PID survives restart, dead/nil PID marked failed, ETS sched_meta recovery keeps task :running, DOWN handler marks completed/failed (6 tests).
- `lease_heartbeat_test.exs` — `EvoDash.TaskRegistry.LeaseHeartbeatTest` — lease & heartbeat: startup reconciliation respects valid leases, marks expired leases as failed, lease cleared on completion, heartbeat does NOT sweep, lease_sweep sweeps expired unowned tasks (5 tests).

### `evo_dash_web/live/`
- `settings_live_test.exs` — `EvoDashWeb.SettingsLiveTest` — Settings page: search input rendering, search handler (value-key matching, results panel, no-results message, clear-to-category-view), and search-input-within-form regression. Also covers custom model providers (OpenRouter / OpenAI-Compatible): form rendering (model name, base URL, placeholders, warning, hidden quick-select buttons), saving (openrouter: spec pre-fill + openai-compatible map spec pre-fill), and validation errors (empty model name, empty base URL). Also covers whitelist safety regression: unknown category/provider/variant/key-path values safely map to nil/default instead of crashing (with positive cases confirming valid conversions). NOTE: these custom-model tests render the LLM category via `select_category`, which currently crashes due to a pre-existing `:model_spec` gap in `setting_card` (see note below).
- `tasks_live_test.exs` — `EvoDashWeb.TasksLiveTest` — Cross-project task list: search (by prompt/objective/ID, case-insensitive), filter selects, reset. Includes regression tests for the `:finalizing` crash fix: `handle_info({:task_status, _, :finalizing})` and the catch-all `handle_info(_msg, _)` clauses no longer crash the LiveView when broadcast on the `EvoGit.PubSub` "tasks" topic. Uses an isolated TaskRegistry + TaskStore (unique temp root + SQLite database file; terminates production children and restarts them in `on_exit`, `async: false`).
- `review_live_test.exs` — `EvoDashWeb.ReviewLiveTest` — Review page: non-existent task error display, and the "ignore" action (button always shown; clicking sets review_status to :ignored and navigates to dashboard). Uses the production TaskRegistry + TaskStore directly (seeds tasks via EvoDash.Store.put, cleans up via delete_task).
- `error_html_test.exs` — `EvoDashWeb.ErrorHTMLTest` — Validates HTML error templates (404 → "Not Found", 500 → "Internal Server Error").
- `error_json_test.exs` — `EvoDashWeb.ErrorJSONTest` — Validates JSON error responses (404/500 with appropriate `%{errors: %{detail: ...}}` shape).

## Constraints
- Follow standard Phoenix test conventions: mirror the `lib/` directory structure under `test/`.
- All connection-based tests must `use EvoDashWeb.ConnCase`.
- Support modules live in `support/` and are compiled automatically by Mix.
- Test file naming: `*_test.exs`.
- Tests requiring an isolated TaskRegistry/TaskStore terminate the production children from `EvoDash.Supervisor` and restart them via `Supervisor.restart_child/2` in `on_exit` to avoid breaking other suites.
- All task persistence in tests goes through `EvoDash.Store` (SQLite-backed) — no legacy storage formats are used.
- **`try/rescue`/`catch` policy for test files:** While the codebase's design philosophy treats `try/rescue` as an anti-pattern, in test files it is acceptable — and encouraged — in `on_exit`/teardown cleanup paths, because a teardown failure should NOT mask or obscure an actual test failure. Such cleanup rescues must be accompanied by a brief comment documenting why. Rescues that wrap actual test assertions or mask real behavior under test are forbidden; if an assertion would fail, the test must fail loudly.
