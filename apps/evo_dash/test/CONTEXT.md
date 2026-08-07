# Test Directory

## Intent
Holds all test files for the EvoDash application. Provides the ExUnit test runner configuration and shared test support modules (e.g., `ConnCase`) used across controller and endpoint tests.

NOTE: The domain-layer modules (`Store`, `TaskRegistry`, `TaskInfo`, `RecentProject`) have been **migrated to the `:evo_git` app** and now live there as `EvoGit.Store`, `EvoGit.TaskRegistry`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`. The corresponding domain-layer test suite (Store round-trip tests, TaskRegistry split suite, `task_registry_case.ex`) was removed with the migration — those modules are now tested in `:evo_git`. Web-layer tests still reference `EvoGit.TaskRegistry` / `EvoGit.Store` / `EvoGit.TaskInfo` directly (isolated setup via `EvoGit.Store` / `EvoGit.TaskRegistry` under `EvoDash.Supervisor`).

## Routing Table
- `support/` → Shared test support modules (ConnCase for connection based tests)
- `evo_dash/` → Domain-layer tests (MarkdownRender)
- `evo_dash_web/` → Web-layer tests (controller tests, error handler tests, component tests under `evo_dash_web/components/`)

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
- `markdown_render_test.exs` — `EvoDash.MarkdownRenderTest` — Markdown-to-HTML rendering edge cases (nil, empty, headings, code blocks, tables, bold).

### `evo_dash_web/components/`
- `project_components_test.exs` — `EvoDashWeb.ProjectComponentsTest` — Component-level tests for the command-palette project selector (`project_omnibox/1`): trigger rendering (active project name/path, "Open a project..." placeholder, enlarged `px-4 py-2` trigger + `text-base font-bold text-base-content truncate leading-tight` name span typography), and the client-side wiring — the search input (`input#palette-search-input`) carries `phx-keydown="palette_keydown"` + `phx-change="palette_search"`, the overlay (`.project-palette-overlay`) carries `phx-click-away="close_project_palette"`, and the backdrop (`.project-palette-backdrop`) carries `phx-click="close_project_palette"`. Uses `render_component/2` + Floki helpers (`trigger_class/1`, `attribute/3`, `parse/1`). NOTE: the active_project fixture must include a `:path` key (the component renders `@active_project.path` unconditionally).
- `task_form_components_test.exs` — `EvoDashWeb.TaskFormComponentsTest` — `layout_for/1` boundary tests (300-char / 8-line thresholds, non-binary fallback) plus rendering smoke tests for the UNIFIED control order: both layouts share identical DOM and visual order — mode (order-1) | Launch (order-2, centered via `mx-auto`) | model (order-3); only the textarea size differs per layout. Also covers the no-model-profiles case (Launch stays centered, no `name="model_id"` select), disabled state, mode select options, and textarea `phx-change`/`AdaptiveInput` bindings. A one-line contract test ("controls row stays on one line (flex-nowrap)") pins `.input-controls` as `flex-nowrap` (never `flex-wrap`) with `min-w-0` + `truncate` on both selects.

### `evo_dash_web/live/`
- `settings_live/model_profile_helpers_test.exs` — `EvoDashWeb.SettingsLive.ModelProfileHelpersTest` — Pure unit tests (async, no LiveView) for `ModelProfileHelpers`: draft-profile dropping/keeping, quick-setup regression (no profile without `:model`), `parse_model_profile_params/2` serialization (compact `"provider:model"` string vs map spec with overrides), profile **id naming** (derived from model value: after-first-colon / plain string / map `:id`, slugified), conflict suffixes (`-2`, `-3`), `profile-N` fallbacks, and `generate_profile_id/2` (base/base-2/base-3 skipping existing ids, nil/one-arity → `profile-N`).
- `welcome_live_test.exs` — `EvoDashWeb.WelcomeLiveTest` — Welcome/onboarding page: flat model grid (multi-provider, variants, alphabetical sort), search, all-set state, skip/get-started redirects, credential detection, **back navigation** (Back button with client-side `history.back()` fallback — NOTE: the rendered onclick HTML-escapes quotes, so assert `window.location.href = &#39;/&#39;;`), and the **LLM connection test** UI (Test Connection button only when a model is selected, `:testing` spinner, `Connected` + model display name, error reason, status reset on model select). The last test ("typed API key is saved before the connection test runs") spawns a real background task with a bogus key that fails fast — same precedent as settings_live_test.
- `dashboard_live_test.exs` — `EvoDashWeb.DashboardLiveTest` — Dashboard: task form, project palette, project settings, task notifications. **Empty-state contract**: when no project is active the launch panel (`.input-controls`, `hero-rocket-launch`) is NOT rendered — instead the hint overlay `"Open a project to get started"` shows. Tests in "dashboard without active project" and "task notifications" (which clear recent projects) pin this with `refute html =~ "hero-rocket-launch"` + the hint string. Tests with an active project still assert the launch button.
- `settings_live_test.exs` — `EvoDashWeb.SettingsLiveTest` — Settings page: search input rendering, search handler (value-key matching, results panel, no-results message, clear-to-category-view), and search-input-within-form regression. Also covers custom model providers (OpenRouter / OpenAI-Compatible): form rendering (model name, base URL, placeholders, warning, hidden quick-select buttons), saving (openrouter: spec pre-fill + openai-compatible map spec pre-fill), and validation errors (empty model name, empty base URL). Also covers whitelist safety regression: unknown category/provider/variant/key-path values safely map to nil/default instead of crashing (with positive cases confirming valid conversions). NOTE: these custom-model tests render the LLM category via `select_category`, which currently crashes due to a pre-existing `:model_spec` gap in `setting_card` (see note below).
- `tasks_live_test.exs` — `EvoDashWeb.TasksLiveTest` — Cross-project task list: search (by prompt/objective/ID, case-insensitive), filter selects, reset. Includes regression tests for the `:finalizing` crash fix: `handle_info({:task_status, _, :finalizing})` and the catch-all `handle_info(_msg, _)` clauses no longer crash the LiveView when broadcast on the `EvoGit.PubSub` "tasks" topic. Uses an isolated TaskRegistry + TaskStore (unique temp root + SQLite database file; terminates production children and restarts them in `on_exit`, `async: false`). Also includes a `:remote_poll` smoke test on the local node (no crash; `:remote_poll_timer` → false, stop-polling branch).
- `tasks_live/dirty_tracker_test.exs` — `EvoDashWeb.TasksLive.DirtyTrackerTest` — pure unit tests (async, no LiveView harness) for the remote-poll dirty tracker: `new/1` (defaults + `full_resync_every` override), `seed/3` (node binding, max-baseline advancement, `""` sentinel for empty summaries, tick reset), `max_updated_at/1` (lexicographic ordering, empty → `""`), `evaluate/2` (`:reload`/`:noop`/`:resync` actions, tick counting, resync fires exactly at `full_resync_every`, nil-baseline defensive clause).
- `review_live_test.exs` — `EvoDashWeb.ReviewLiveTest` — Review page: non-existent task error display, and the "ignore" action (button always shown; clicking sets review_status to :ignored and navigates to dashboard). Uses the production TaskRegistry + TaskStore directly (seeds tasks via `EvoGit.Store.put`, cleans up via delete_task).
- `error_html_test.exs` — `EvoDashWeb.ErrorHTMLTest` — Validates HTML error templates (404 → "Not Found", 500 → "Internal Server Error").
- `error_json_test.exs` — `EvoDashWeb.ErrorJSONTest` — Validates JSON error responses (404/500 with appropriate `%{errors: %{detail: ...}}` shape).

## Constraints
- Follow standard Phoenix test conventions: mirror the `lib/` directory structure under `test/`.
- All connection-based tests must `use EvoDashWeb.ConnCase`.
- Support modules live in `support/` and are compiled automatically by Mix.
- Test file naming: `*_test.exs`.
- Tests requiring an isolated TaskRegistry/TaskStore terminate the production children from `EvoDash.Supervisor` and restart them via `Supervisor.restart_child/2` in `on_exit` to avoid breaking other suites. (These children now live in `EvoGit.Application`'s supervision tree; tests reference them via `EvoGit.Store` / `EvoGit.TaskRegistry`.)
- All task persistence in tests goes through `EvoGit.Store` (SQLite-backed) — no legacy storage formats are used.
- **`try/rescue`/`catch` policy for test files:** While the codebase's design philosophy treats `try/rescue` as an anti-pattern, in test files it is acceptable — and encouraged — in `on_exit`/teardown cleanup paths, because a teardown failure should NOT mask or obscure an actual test failure. Such cleanup rescues must be accompanied by a brief comment documenting why. Rescues that wrap actual test assertions or mask real behavior under test are forbidden; if an assertion would fail, the test must fail loudly.
