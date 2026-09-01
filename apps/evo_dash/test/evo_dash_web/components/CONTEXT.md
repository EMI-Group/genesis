# Components Test Directory

## Intent

ExUnit suites for the function components in `./lib/evo_dash_web/components/` (one test file per component module). All suites are `async: true`, import `Phoenix.LiveViewTest`, and use `render_component/2` + Floki (parsed via `Floki.parse_document!/1` — the file-local `parse/1` helper — because `Floki.find/2` + `attribute/2` require a parsed tree, not a raw binary).

## Routing Table

- `project_components_test.exs` → `EvoDashWeb.ProjectComponentsTest` — command-palette project selector (`project_omnibox/1`) + `project_settings_tab/1` (directory-picker browse buttons, PathAutocomplete wiring, remote gating)
- `task_form_components_test.exs` → `EvoDashWeb.TaskFormComponentsTest` — `layout_for/1` boundaries, `task_form/1` control order/agent/model selects/attach-file, `task_options_tab/1` mode gating
- `remote_gate_components_test.exs` → `EvoDashWeb.RemoteGateComponentsTest`
- `archive_tree_test.exs` → `EvoDashWeb.ArchiveTreeTest`
- `diff_viewer_test.exs` → `EvoDashWeb.DiffViewerTest` — `parse_hunk_header/1` + `build_split_pairs/1` pure units, split-view rendering contract (escaped plain text, no server-side highlight)
- `task_card_components_test.exs` → `EvoDashWeb.TaskCardComponentsTest` — task-card affordances incl. cancel/force-kill button visibility
- `setting_card_test.exs` → `EvoDashWeb.SettingCardTest`
- `model_profiles_editor_test.exs` → `EvoDashWeb.ModelProfilesEditorTest` — render-only peak/off-peak form coverage: peak_concurrency (incl. 0), peak_hours rows, timezone, draft-wins pre-fill, remove-row buttons, PLUS the days-of-week fields (`off_peak_days` profile chips + per-window `peak_hours[<i>][days]` chips — checked-state derivation, no hidden seed for window days, index threading, and a regression guard that start/end/remove-row markup coexists)

## API Surface

### project_components_test.exs (7 describes, 20 tests)

- `project_omnibox/1 rendering` (5 tests): trigger renders active-project name + **path** (`assert html =~ "/home/user/my-project"` — the ONLY path-rendering assertion in this file; no test asserts paths in the open palette's project ROWS, only the collapsed trigger), placeholder, typography classes, `palette_keydown` binding, `phx-click-away="close_project_palette"`.
- `directory picker browse buttons` (3 tests): regression guards — open-path / new-project / **foreign-repo** browse buttons keep `phx-hook="DirectoryPicker"` and have NO `phx-click` (a leftover `phx-click="pick_directory"` had no handle_event clause and crashed the LiveView in the desktop app).
- `browse buttons in remote contexts` (6 tests): browse buttons hidden when `remote: true` (incl. **foreign-repo form** — asserts `#foreign-repo-path-browse-button` absent, input keeps `phx-hook="PathAutocomplete"`); kept on local node.
- `foreign repo path input autocomplete` (1 test): `#foreign-repo-path-input` carries `phx-hook="PathAutocomplete"`, `list="foreign-repo-path-suggestions"`, `phx-change="foreign_repo_path_input"`, `phx-debounce="150"`, and a datalist with one `<option value="...">` per `@foreign_repo_path_suggestions` entry.
- `new project path input autocomplete` (1 test): mirrors the above for `#new-project-path-input`.
- `neutral placeholders` (1 test): "Project path" placeholder, no baked example paths.
- `palette actions in remote contexts` (2 tests): "Create New Project" hidden on remote, "Open Project by Path" kept.

**Foreign-repo coverage note**: ALL foreign-repo fixtures pass `foreign_repos: []` — no test renders existing foreign-repo ROWS/list items; coverage is limited to the add-form (browse button hook/click contract, PathAutocomplete wiring, remote gating). No test asserts the `show_add_foreign_repo` toggle rendering in the negative (e.g. `false` hides the form).

### task_form_components_test.exs (3 describes, 31 tests)

- `layout_for/1` (9 tests): 600-grapheme / 16-line thresholds (`:compact` at boundary, `:expanded` above), non-binary fallback to `:compact`.
- `task_form/1 rendering` (20 tests): `data-layout` attr; unified control DOM order mode(order-1) | Launch(order-2, mx-auto) | model(order-3) pinned via Floki children; model select label = bare id, "Auto (by rules)" first; disabled state overlay; `flex-nowrap` one-line contract; mode select 4 options (`genesis_existing`/`genesis_new`/`evolve_simple`/`custom_agent`; reflect removed); `data-mode` on Launch; custom_agent agent-select behaviors (Auto hidden, no-agents warning, evolve placeholder); AdaptiveInput + `phx-update="ignore"`, no per-keystroke event; attach-file button (`FilePicker` hook, `data-picker-id="objective_file"`, `type="button"`, NOT inside `.input-controls`, hidden when disabled).
- `task_options_tab/1 rendering` (2 tests): custom_agent shows evolve-family options, hides Build System; genesis_new inverse.

**NO foreign-repo / multi-repo coverage**: grep for `foreign|repo|path` (case-insensitive) matches nothing — the task form tests never reference foreign repos, repo paths, or any multi-repo UI.

## Known Issues / Notes for Agents

- `EvoDashWeb.ProjectComponentsTest` test "trigger renders the active project name and path" passes `active_project: %{name: ..., path: "/home/user/my-project"}` — the palette row-rendering path is UNTESTED (open palette with a project list is never rendered in any test).
- Helper convention: each file defines its own `attribute/3`, `button_class/1`, `parse/1` etc. — no shared component-test helper module.
