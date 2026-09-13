# Components Test Directory

## Intent

ExUnit suites for the function components in `./lib/evo_dash_web/components/` (one test file per component module). All suites are `async: true`, import `Phoenix.LiveViewTest`, and use `render_component/2` + Floki (parsed via `Floki.parse_document!/1` — the file-local `parse/1` helper — because `Floki.find/2` + `attribute/2` require a parsed tree, not a raw binary).

## Routing Table

- `project_components_test.exs` → `EvoDashWeb.ProjectComponentsTest` — command-palette project selector (`project_omnibox/1`) + `project_settings_tab/1` (directory-picker browse buttons, PathAutocomplete wiring, remote gating)
- `task_form_components_test.exs` → `EvoDashWeb.TaskFormComponentsTest` — `layout_for/1` boundaries, `task_form/1` control order/agent/model selects/attach-file, `task_options_tab/1` mode gating
- `remote_gate_components_test.exs` → `EvoDashWeb.RemoteGateComponentsTest`
- `archive_tree_test.exs` → `EvoDashWeb.ArchiveTreeTest`
- `diff_viewer_test.exs` → `EvoDashWeb.DiffViewerTest` (50 tests) — `parse_hunk_header/1` + `build_split_pairs/1` pure units, split-view rendering contract (escaped plain text, no server-side highlight, `data-language`, single `phx-hook="DiffViewer"`), and the redesigned tree/DOM via `render_component/2` + Floki: server-driven tree state (dirs collapsed by default, `toggle_dir` buttons carrying the FULL dir path + `aria-expanded`, no `<details>` in the tree, subtree aggregates), dirs-first case-insensitive sort, `filter_files` input attrs + flat filter mode + "No matching files" (filter mode preserves `@files` order — no re-sort), `collapse_all_dirs`/`expand_all_dirs` buttons, lazy diffs (unexpanded → metadata-only header; expanded + nil diff → "Loading diff..."), per-file `toggle_file_expansion`/`expand_context` payloads, `:all` context level, `split_diff_layout/1` repo toolbar (`>1` repo gate, `select phx-change="switch_repo"`, option labels + active preselection — Floki normalizes bare `selected` to `selected="selected"`, summed +/− scoped to `div.ml-auto`), `commit_diff_layout/1` (no toolbar), `commit_detail_header/1` (back link, truncated h1 + title attr, sha badge)
- `task_card_components_test.exs` → `EvoDashWeb.TaskCardComponentsTest` — task-card affordances incl. cancel/force-kill button visibility + the failed-task structured-error display (`describe "task_card/1 — failed-task structured error display"`): collapsed error strip (truncated `error.message`, kind-label fallback), expanded detail block (kind + "Source: …" caption chips via `Helpers.task_error_kind_label/1`/`task_error_source_label/1`, full message, last ≤8 stacktrace frames in a `<pre>`), legacy `{:error,_}` result box coexistence, `error: nil`/non-map/16-key-summary-map safety, and the `:failed`-never-renders-a-Review-button pin
- `setting_card_test.exs` → `EvoDashWeb.SettingCardTest`
- `model_profiles_editor_test.exs` → `EvoDashWeb.ModelProfilesEditorTest` — render-only peak/off-peak form coverage: peak_concurrency (incl. 0), peak_hours rows, timezone, draft-wins pre-fill, remove-row buttons, PLUS the days-of-week fields (`off_peak_days` profile chips + per-window `peak_hours[<i>][days]` chips — checked-state derivation, no hidden seed for window days, index threading, and a regression guard that start/end/remove-row markup coexists)
- `category_metadata_test.exs` → `EvoDashWeb.CategoryMetadataTest` — pure units for `SettingsComponents.CategoryMetadata` (`category_display_name/1`/`category_icon/1`/`category_description/1`/`sort_categories/1`, pinned on the `:data` category)

## Coverage Boundary — review-page components

- This tree renders every component in ISOLATION via `render_component/2`; there is **no `live(...)` call anywhere in `test/evo_dash_web/components/`**. Review-page COMPOSITION (what the assembled page looks like) is therefore covered only by `test/evo_dash_web/live/review_live_test.exs`.
- Only two `EvoDashWeb.ReviewComponents` modules have component-level tests: `DiffViewer` (`diff_viewer_test.exs`, including `diff_viewer/1`, `file_tree_sidebar/1`, `tree_node/1`, `split_diff_layout/1`, `commit_diff_layout/1`, `commit_detail_header/1`, `parse_hunk_header/1`, `build_split_pairs/1`) and `archive_review_section/1` (`archive_tree_test.exs`, describes at lines 80, 110, 124, 282 — string/atom keys, cycle safety, usage tiles).
- `ReviewComponents.merge_box/1` + `extract_skills_modal/1` + `conflict_files_summary/1` (`review_components/actions.ex`), `page_header/1` + `short_title/1` + `agent_summary/1` + `objective_section/1` + `task_summary/1` (`review_components/header.ex`), `page_tabs/1` + `merge_outcomes_panel/1` + `archive_tree_node/1` (`review_components.ex`), and `diff_stats_bar/1` + `commits_list/1` (`review_components/stats.ex`) have NO dedicated component-test file — they are exercised only through `review_live_test.exs` (hand-built LiveView assigns) or not at all.

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

- `layout_for/1` (9 tests): 1200-grapheme / 32-line thresholds (`:compact` at boundary, `:expanded` above), non-binary fallback to `:compact`.
- `task_form/1 rendering` (20 tests): `data-layout` attr; bottom-toolbar DOM order attach "+" (`button#objective-file-button`, first INSIDE `.input-controls`) | mode | (agent) | model | circular send `button#task-launch-button` LAST/rightmost pinned via Floki — the right-aligned cluster [mode | (agent) | model | send] is packed right by the MODE select's `ml-auto` (free space sits after the attach "+", before the cluster), and the launch button carries NO auto margin; compact `select-sm` classes on the mode/agent/model selects; model select label = bare id, "Auto (by rules)" first; disabled state overlay; `flex-nowrap` one-line contract; mode select 4 options (`genesis_existing`/`genesis_new`/`evolve_simple`/`custom_agent`; reflect removed); `data-mode` on the send button; custom_agent agent-select behaviors (Auto hidden, no-agents warning, evolve placeholder); AdaptiveInput + `phx-update="ignore"`, no per-keystroke event; attach-file button (`FilePicker` hook, `data-picker-id="objective_file"`, `type="button"`, hidden when disabled).
- `task_options_tab/1 rendering` (2 tests): custom_agent shows evolve-family options, hides Build System; genesis_new inverse.

**NO foreign-repo / multi-repo coverage**: grep for `foreign|repo|path` (case-insensitive) matches nothing — the task form tests never reference foreign repos, repo paths, or any multi-repo UI.

## Known Issues / Notes for Agents

- `EvoDashWeb.ProjectComponentsTest` test "trigger renders the active project name and path" passes `active_project: %{name: ..., path: "/home/user/my-project"}` — the palette row-rendering path is UNTESTED (open palette with a project list is never rendered in any test).
- Helper convention: each file defines its own `attribute/3`, `button_class/1`, `parse/1` etc. — no shared component-test helper module.
