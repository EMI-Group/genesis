# Test Directory

## Intent

Holds all test files for the EvoDash application: the ExUnit test runner configuration, shared test support modules (ConnCase, TestHelpers, picker fakes), and suites for the domain layer, web layer, LiveView pages, components, controllers, and live hooks.

NOTE: The domain-layer modules (`Store`, `TaskRegistry`, `TaskInfo`, `RecentProject`) live in the `:evo_git` app as `EvoGit.Store`, `EvoGit.TaskRegistry`, `EvoGit.TaskInfo`, `EvoGit.RecentProject` and are tested there — this app has no domain-layer test suite for them. Web-layer tests reference `EvoGit.TaskRegistry` / `EvoGit.Store` / `EvoGit.TaskInfo` directly (isolated setup via `EvoGit.Store` / `EvoGit.TaskRegistry` under `EvoDash.Supervisor`).

## Routing Table

- `support/` → Shared test support modules (ConnCase, TestHelpers, directory-picker fakes)
- `evo_dash/` → Domain-layer tests (AttachedFile, SettingsUtils, DesktopLifetime, NodeContext, DirectoryPicker, MarkdownRender, UpdateStatus)
- `evo_dash_web/` → Web-layer tests — LiveView suites, components, controllers, live hooks, shared helpers
- `evo_dash_web/live/` → LiveView page test suites + support-module unit tests (has its own CONTEXT.md)
- `evo_dash_web/live_hooks/` → Live-hook tests (NodeAware, Guide, DesktopQuit, UpdateStatus)
- `evo_dash_web/components/` → Function-component tests
- `evo_dash_web/controllers/` → Controller / error-template tests

## API Surface

### Top-Level
- `test_helper.exs` — Bootstraps ExUnit (`ExUnit.start()`). Entry point for the test suite.

### `support/`
- `conn_case.ex` — `EvoDashWeb.ConnCase`: shared `ExUnit.CaseTemplate` for connection-based tests. Endpoint registration (`@endpoint EvoDashWeb.Endpoint`), verified routes (`use EvoDashWeb, :verified_routes`), imports `Plug.Conn` / `Phoenix.ConnTest`, default setup returns a built `%Conn{}`.
- `test_helpers.ex` — `EvoDashWeb.TestHelpers`: shared `flush_loading/4` — polls the LiveView test proxy's rendered HTML until a loading marker disappears (async `Task.Supervisor`-backed page loads) or `flunk`s on timeout. `render_async/2` does NOT await TaskSupervisor children, so page-load tests must flush. The LiveView test files' private `flush_*_load` helpers are one-line delegates to it.
- `fake_directory_picker.ex` / `fake_directory_picker_wx.ex` — `EvoDash.DirectoryPicker.Fake` (module-level fake, installed via the `:directory_picker_module` env) and `EvoDash.DirectoryPicker.Wx.Fake` (wx seam fake, via the `:directory_picker_wx` env); used by the directory-picker and attach-file tests (see "Notes for Agents — attach-file" below).

### `evo_dash/` (domain-layer tests)
- `attached_file_test.exs` — `EvoDash.AttachedFileTest` — attached-file reading/trimming behind the objective editor's file attach.
- `settings_utils_test.exs` — `EvoDash.SettingsUtilsTest`
- `desktop_lifetime_test.exs` — `EvoDash.DesktopLifetimeTest`
- `node_context_test.exs` — `EvoDash.NodeContextTest` — NodeContext delegation shape incl. `cancel_task/2` / `force_kill_task/2` smoke tests (see task-cancellation notes).
- `directory_picker_test.exs` — `EvoDash.DirectoryPickerTest` (async: false) — Real picker GenServer + `EvoDash.DirectoryPicker.Wx.Fake` (per-test `enabled: true` override + `:directory_picker_wx` env injection): `pick/2` and `pick/3` (file mode) — file pick delivers the file path via the fake's `new_file_dialog` + ref-typed `get_path`, `pick/2` ≡ `pick/3 :directory`, kind-agnostic busy serialization (`set_gate/1` dialog block), wx init-failure/server-death degradation to `:unavailable` with busy cleared, disabled-config rejection.
- `markdown_render_test.exs` — `EvoDash.MarkdownRenderTest` — Markdown-to-HTML rendering edge cases (nil, empty, headings, code blocks, tables, bold).
- `update_status_test.exs` — `EvoDash.UpdateStatusTest`

### `evo_dash_web/` (top-level web tests)
- `helpers_test.exs` — `EvoDashWeb.HelpersTest` — shared UI helpers (status badges, datetime formatting, icons, modals), incl. the exact-string `:cancelling` badge test.
- `theme_color_test.exs` — `EvoDashWeb.ThemeColorTest`

### `evo_dash_web/components/`
- `project_components_test.exs` — `EvoDashWeb.ProjectComponentsTest` — command-palette project selector (`project_omnibox/1`): trigger rendering + client-side wiring (`phx-keydown`/`phx-change` search input, `phx-click-away`/`phx-click` overlay/backdrop). Uses `render_component/2` + Floki helpers; the active_project fixture must include a `:path` key.
- `task_form_components_test.exs` — `EvoDashWeb.TaskFormComponentsTest` — `layout_for/1` boundary tests (600-char / 16-line thresholds), unified control order (mode | Launch | model), no-model-profiles case, disabled state, textarea bindings (`phx-update="ignore"` + `phx-hook="AdaptiveInput"`, no per-keystroke server event), `.input-controls` `flex-nowrap` contract pin, and the attach-file "+" button (`button#objective-file-button`, `phx-hook="FilePicker"`, NOT inside `.input-controls`).
- `diff_viewer_test.exs` — `EvoDashWeb.DiffViewerTest` — `parse_hunk_header/1` + `build_split_pairs/1` pure units and split-view rendering contract: diff renders as ESCAPED plain text (no HTML injection), no server-side highlight markup, `data-language` attribute per `.diff-file-section`, hunk headers as plain text, gutters/content on both sides, file header with path + stats. Floki used purely as an HTML query helper. No other test file asserts on diff body content.
- `model_profiles_editor_test.exs` — `EvoDashWeb.ModelProfilesEditorTest`
- `task_card_components_test.exs` — `EvoDashWeb.TaskCardComponentsTest` — task card affordances incl. the cancel/force-kill button visibility rules.
- `archive_tree_test.exs` — `EvoDashWeb.ArchiveTreeTest`
- `remote_gate_components_test.exs` — `EvoDashWeb.RemoteGateComponentsTest`
- `setting_card_test.exs` — `EvoDashWeb.SettingCardTest`

### `evo_dash_web/controllers/`
- `error_html_test.exs` — `EvoDashWeb.ErrorHTMLTest` — HTML error templates (404 → "Not Found", 500 → "Internal Server Error").
- `error_json_test.exs` — `EvoDashWeb.ErrorJSONTest` — JSON error responses (404/500 with the `%{errors: %{detail: ...}}` shape).
- `page_controller_test.exs` — `EvoDashWeb.PageControllerTest`
- `task_export_controller_test.exs` — `EvoDashWeb.TaskExportControllerTest` — JSON export endpoint.

### `evo_dash_web/live_hooks/`
- `node_aware_test.exs` — `EvoDashWeb.NodeAwareTest` (async: false) — Tests `EvoDashWeb.LiveHooks.NodeAware` WITHOUT booting a real LiveView (minimal `%Phoenix.LiveView.Socket{}` via a `socket/1` helper, `patch_to/1` push_patch extractor): connection-status transitions (local→remote `:connected`, remote→local `:disconnected`/`:error`), `load_running_and_pending_tasks/1` node-aware sourcing, `partition_active_tasks/1` pure partitioning, `assign_node/2` sidebar reload. Uses an isolated Store+TaskRegistry, a fake `ConnectionManager` GenServer registered in `EvoGit.RemoteConnection.Registry`, and per-test `XDG_CONFIG_HOME` isolation.
- `guide_test.exs` — `EvoDashWeb.LiveHooks.GuideTest` — guide overlay hook.
- `desktop_quit_test.exs` — `EvoDashWeb.LiveHooks.DesktopQuitTest` — tray-quit confirm hook.
- `update_status_test.exs` — `EvoDashWeb.LiveHooks.UpdateStatusTest`

### `evo_dash_web/live/` (LiveView page suites — see its own CONTEXT.md for routing)
- `home_live_test.exs` — `EvoDashWeb.HomeLiveTest` (async: false) — **Home chat page** (`GET /help`, ChatGPT-style chat wired to the `:reflect` self-reflective agent; the Projects page is served at `GET /` and `GET /projects`). 22 tests: idle render, send-message (real `render_submit` → assert the persisted task ROW via `EvoGit.Store.safe_select_all_tasks`: `mode: "reflect"`, NO `:path` key; a second message's objective = `Transcript.build_preamble` + text), whitespace no-op, new-chat reset, onboarding dead-render redirect, streaming display (inject `{:agent_registered, ...}` / `{:agent_updated, id, [:message_count], node()}`; agent history via home_live's OWN result messages `{:chat_agent_lookup, ...}` / `{:chat_history_loaded, ...}` — the two-seq stale-guards `chat_fetch_seq`/`chat_task_fetch_seq`), completion/error rendering (seed a `%EvoGit.TaskInfo{}` fixture via `EvoGit.Store.put_task` and inject `{:task_updated, ...}`), stop/cancel flow, node-awareness (fake ConnectionManager in `EvoGit.RemoteConnection.Registry`). **IMPORTANT — ETS sweep**: the real-send tests spawn a REAL reflect agent that stays alive/blocked (no LLM creds in the isolated config); `cleanup_task_on_exit/1` cancels + deletes the task AND sweeps `:evogit_sched_meta`/`:evogit_agent_state` rows by task_id (cancel/delete do NOT remove them) — without the sweep the blocked agent leaks into `agents_live_test.exs` (which expects an empty agent registry).
- `welcome_live_test.exs` — `EvoDashWeb.WelcomeLiveTest` — Welcome/onboarding page: flat model grid (multi-provider, variants, alphabetical sort), search, all-set state, skip/get-started redirects (to `/welcome/complete`), credential detection, back navigation (client-side `history.back()` fallback — the rendered onclick HTML-escapes quotes), LLM connection-test UI, and the example-task teaching section is NOT rendered on `/welcome` (it lives on `/welcome/complete`).
- `welcome_complete_live_test.exs` — `EvoDashWeb.WelcomeCompleteLiveTest` — `/welcome/complete`: high-level-prompt explanation + example objective (`EvoDashWeb.ExampleTask.example_objective()`, asserted via HTML-special-free distinctive lines since `<`/`&` are escaped in the `<pre>` block) + copy button (`welcome-example-copy`, `ClipboardCopy` hook), and the "Go to Dashboard" CTA — clicking `go_to_dashboard` asserts `assert_redirect(view, "/projects")` AND onboarding completion via `EvoGit.Config.VersionState` (`onboarding_needed?() == false`), under the same per-test temp `XDG_CONFIG_HOME` isolation as `welcome_live_test.exs`.
- `projects_live_test.exs` — `EvoDashWeb.ProjectsLiveTest` — Projects page (served at `GET /` and `GET /projects`): task form, command-palette project selector, project settings, task notifications, directory-picker browse flows, and the file-attach flow (`file_pick` event + `"objective_file"` picker id — happy path pins the exact appended block; manual fallback `file_pick_manual`). **Empty-state contract**: with no active project the launch panel (`.input-controls`, `hero-rocket-launch`) is NOT rendered — the hint overlay `"Open a project to get started"` shows. NOTE: ~3500 lines — a legitimately large suite; don't split casually.
- `settings_live_test.exs` — `EvoDashWeb.SettingsLiveTest` — Settings page: search input/handler/results, custom model providers (OpenRouter / OpenAI-Compatible) form rendering + saving, and whitelist safety (unknown category/provider/variant/key-path values safely map to nil/default instead of crashing).
- `settings_live_agents_test.exs` — `EvoDashWeb.SettingsLiveAgentsTest` — the Settings **Agents** category (custom agents + model-selection script editors), incl. its own fake ConnectionManager.
- `tasks_live_test.exs` — `EvoDashWeb.TasksLiveTest` — Cross-project task list: search (by prompt/objective/ID), filter selects, pagination, node-aware behavior, `:cancelling` status display, review button, cancel/force-kill modal actions. **Event-driven broadcast tests** (the page is fully push-based — no polling): manually injected `{:task_updated, ...}` / `{:task_deleted, ...}` (does-not-crash + catch-all), stale page-load results dropped by the `tasks_load_seq` stale-guard, a matching-node broadcast triggering the debounced reload (two-phase `:tasks_reload_pending` true→false pattern), foreign-node broadcasts ignored. Uses an isolated TaskRegistry + Store (`async: false`).
- `review_live_test.exs` — `EvoDashWeb.ReviewLiveTest` — Review page: non-existent task error display, and the "ignore" action (sets `review_status: :ignored`, navigates to `/projects`). Uses the production TaskRegistry + TaskStore directly.
- `platform_info_test.exs` — `EvoDashWeb.PlatformInfoTest` — Pure unit tests (async, no LiveView) for `EvoDashWeb.PlatformInfo`: `os_for_node/1` with the `:platform_os_override` injection seam, `show_sandbox?/1` + `sandbox_backend_for/1` truth tables, `filter_schemas_by_category/2`, and the round-trip safety pin (macOS-filtered schemas must NOT deep-delete hidden sandbox keys absent from form params).
- `system_live_test.exs` — `EvoDashWeb.SystemLiveTest` — System page: scheduler pause/resume, system controls (remote-node-only confirm paths via direct `SystemLive.handle_event/3` — the local VM-killing confirm paths are intentionally NOT unit-tested), system self-check, Status sandbox helpers (incl. the `:bwrap` clauses), modal-test idiom.
- `agents_live_test.exs` — `EvoDashWeb.AgentsLiveTest` — agent tree: node-aware async loads, push-driven refresh via injected `"agents"`-topic events, history gating.
- Support-module unit tests (pure, no LiveView): `projects_live/` (`project_flow_test.exs` — path normalization incl. `normalize_remote_project_path/2` tilde seam + node-aware `build_foreign_repo/4`/`load_foreign_repos/3`, `path_suggestions/2,3`; `state_persistence_test.exs` — `maybe_restore_foreign_repos/2`; `project_test.exs`), `settings_live/` (`model_profile_helpers_test.exs`, `config_io_test.exs`), `agents_live/optimistic_messages_test.exs`, `system_live/charts_test.exs`.

## Notes for Agents — testing the push-based event contract

The dashboard is fully push-based (node-identity PubSub events on `EvoGit.PubSub`; see "Push-based event contract" in `apps/evo_dash/CONTEXT.md`). LiveView tests drive events by **manual injection** — `send(view.pid, {:task_updated, id, status, node()})`, `send(view.pid, {:task_deleted, id, node()})`, `send(view.pid, {:agent_updated, id, changed_fields, node()})`, `send(view.pid, {:system_sample, node, seq, sample})`, etc. — with **foreign-node broadcasts** (`node != node()`) asserted ignored. Async page loads still run in `EvoDash.TaskSupervisor` children that `render_async/2` cannot see: flush with `EvoDashWeb.TestHelpers.flush_loading/4` (file-local `flush_*_load/2` delegates) and stale-guard paths with `send(view.pid, ...)` result-message injection (`{:tasks_page_loaded, seq, node, result}`, `{:agents_data_loaded, ...}`, `{:agents_refresh_result, seq, node, result}`, `{:system_samples_seeded, seq, node, result}`). The 300ms reload debounce is asserted with the two-phase `:tasks_reload_pending` true→false pattern (tasks_live_test.exs). **Any test asserting on `chart_samples` MUST stub the seed runner** (`Application.put_env(:evo_dash, :system_samples_runner, stub)` in the test body BEFORE mounting — the runner is resolved at spawn time; the default runner reads the REAL `EvoGit.SystemSampler` ring buffer, non-empty whenever any sampler tick has occurred in the VM). Full story: `./evo_dash_web/live/CONTEXT.md` → Notes for Agents.

## Notes for Agents — task-cancellation UX tests

The backend ships `EvoGit.RemoteNode.cancel_task/2` (graceful: `:pending`/`:running` → `:cancelling` → persisted `:cancelled` with result preserved) and `EvoGit.RemoteNode.force_kill_task/2` (brutal: kills agents+wrapper from `:running`/`:cancelling`, result nil'd), with `EvoDash.NodeContext.cancel_task/2` and `force_kill_task/2` delegating. Current test coverage and facts:

- **`:cancelling` is store-safe**: `EvoGit.Store.Codec`'s `@known_atoms` whitelist includes `:cancelling` (and `:cancelled`); `Store.put_task` round-trips it (verified in evo_git `store_test.exs`). A fixture is created with the standard `insert_fixture!(status: :cancelling, ...)` idiom (tasks_live_test.exs, node_aware_test.exs) — direct `EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{status: :cancelling, ...})` — no backend changes needed.
- **`filter_tasks` has NO status whitelist**: `status_filter` stays a string end-to-end (tasks_live.ex) and binds into SQL as a string (`Store.Queries.build_where`), so the filter `<option value="cancelling">` works without core changes.
- **Cancel-button affordance**: task_card_components.ex shows the graceful Cancel button for `[:pending, :running]`; the three-dot dropdown "Force kill" item shows for `[:running, :cancelling]` under a "Danger zone" divider. The menu `<ul>` is always in the DOM (CSS-hidden) so tests assert item presence/absence directly. `:finalizing`/`:cancelling`/terminal statuses get NO cancel button.
- **`partition_active_tasks/1` unit tests**: `node_aware_test.exs` has a pure `describe "partition_active_tasks/1 — pure partitioning"` (`:cancelling` → running partition; `:cancelled` → not; `:running`/`:pending`/`:finalizing` regression) plus an integration test in the `load_running_and_pending_tasks/1` describe (a `:cancelling` fixture with `finished_at: nil` appears in `running_tasks`).
- **Cancel/force-kill handler tests**: `tasks_live_test.exs` has `describe "cancelling status display"`, `describe "cancel task action"`, `describe "force kill action"` (15 tests) covering the modal open/close idiom, `:pending`→`:cancelled` and `:running`→`:cancelling` store-verified transitions, `:completed`→"Failed to cancel task" flash, nil-guard no-ops, filter `value="cancelling"`, and the force-kill success path via `:sys.replace_state(EvoGit.TaskRegistry, ...)` owned-wrapper injection. `helpers_test.exs` has the exact-string `:cancelling` badge test + differs-from-fallback test.
- **`node_context_test.exs`**: `EvoDash.NodeContext.cancel_task/2` / `force_kill_task/2` delegation smoke tests on the real local path (`{:error, :not_found}` for missing ids) + a `:pending`→`:cancelled` round-trip (`:pending` cancels immediately — no live wrapper needed).
- **Force-kill msgid**: the force-kill error-flash test asserts the msgid `"Failed to force kill task"` (tasks_live.ex). Do NOT weaken that assertion back to the old shared `"Failed to cancel task: %{reason}"` wording.
- **Modal-test idiom** (system_live_test.exs): `render_click(view, "request_X")` opens (assert modal title string appears), `render_click(view, "cancel_X")` closes (refute). Handlers that would tear down the local VM are tested via direct `SystemLive.handle_event/3` on a hand-built `%Phoenix.LiveView.Socket{}` with a non-local `current_node` (safe: RPC to a non-existent node degrades to `:ok`); the local VM-killing confirm paths are intentionally NOT unit-tested.
- **Dropdown idiom** (projects_live_test.exs): dropdown content stays in the DOM (hidden via CSS); tests assert the `phx-click="close_configure_dropdown"` click-catcher overlay appears/disappears on `toggle_configure_dropdown`.

## Notes for Agents — attach-file (picker file-mode) tests

The dashboard attach-file flow (`file_pick` event → `EvoDash.DirectoryPicker.pick/3 :file` → `handle_info({:directory_picker_result, "objective_file", ...})` in projects_live.ex) is tested end-to-end via the two support fakes:

- **Module-level fake** (`EvoDash.DirectoryPicker.Fake`, installed via the `:directory_picker_module` env): `pick/2` and `pick/3 :directory` always deliver `{:ok, "/fake/picked/dir"}`; `pick/3 :file` delivers the result stored under `:persistent_term` key `{__MODULE__, :file_result}` (default `{:ok, "/fake/picked/file.txt"}`). Set per test with `set_file_result/1` (`{:ok, path} | :cancelled | :unavailable`): the happy path must point at a REAL temp file (EvoDash.AttachedFile reads it), the error path at a nonexistent one. Always call `Fake.reset()` in on_exit so the persistent_term result never leaks across tests.
- **wx seam fake** (`EvoDash.DirectoryPicker.Wx.Fake`, installed via the `:directory_picker_wx` env): `new_file_dialog/2` returns `{:wx_ref, 1, :wxFileDialog, []}`; `get_path/1` branches on the ref type (`:wxFileDialog` → `"/fake/picked/file.txt"`, `:wxDirDialog` → `"/fake/picked/dir"`). The `set_gate/1` dialog-block is kind-agnostic (busy serialization tests work for both kinds).
- **Exact block shape** (pinned by the happy-path test): `"\n\n---\n## Attached file: <basename>\n\n<content>\n"` appended to the `file_pick` event's `prompt` snapshot — NOT the stale `@task_prompt` (the `file_pick_bases` snapshot is consumed and cleared). `EvoDash.AttachedFile.read/1` trims plain text; a missing file flashes `"Failed to attach file: File not found: <path>"` and pushes `%{error: true}`.
- Remote-node and disabled-config `file_pick` cases push `%{unavailable: true}` synchronously from `handle_event` (no picker involvement); `:cancelled`/`:unavailable` result kinds hit the generic `handle_info` clauses.

## Known Issues

- **`File.mkdir_p/1` returns `:ok | {:error, reason}` — never `{:ok, _}`**: `EvoDashWeb.ProjectsLive.ProjectFlow.create_project/2` must match the plain `:ok` returned by `File.mkdir_p/1`. The projects_live_test cases "creates and activates a new project" and "creates a fully non-existent nested path recursively" pin this behavior.

## Constraints
- Follow standard Phoenix test conventions: mirror the `lib/` directory structure under `test/`.
- All connection-based tests must `use EvoDashWeb.ConnCase`.
- Support modules live in `support/` and are compiled automatically by Mix.
- Test file naming: `*_test.exs`.
- Tests requiring an isolated TaskRegistry/TaskStore terminate the production children from `EvoDash.Supervisor` and restart them via `Supervisor.restart_child/2` in `on_exit` to avoid breaking other suites. (These children live in `EvoGit.Application`'s supervision tree; tests reference them via `EvoGit.Store` / `EvoGit.TaskRegistry`.)
- All task persistence in tests goes through `EvoGit.Store` (SQLite-backed) — no other storage formats are used.
- **`try/rescue`/`catch` policy for test files:** While the codebase's design philosophy treats `try/rescue` as an anti-pattern, in test files it is acceptable — and encouraged — in `on_exit`/teardown cleanup paths, because a teardown failure should NOT mask or obscure an actual test failure. Such cleanup rescues must be accompanied by a brief comment documenting why. Rescues that wrap actual test assertions or mask real behavior under test are forbidden; if an assertion would fail, the test must fail loudly.
- **LiveViewTest `render/1` cannot see `:sys.replace_state` mutations** on the LiveView process: the test proxy (ClientProxy) renders from its own cached `html_tree`, updated only via channel diffs — a direct `:sys.replace_state` on the live view pid is never reflected by `render/1`. To test transient states (like a `:testing` spinner), drive the real event path (`render_click`/`render_change`) or send the actual `handle_info` message to `view.pid` — not `:sys.replace_state`.
