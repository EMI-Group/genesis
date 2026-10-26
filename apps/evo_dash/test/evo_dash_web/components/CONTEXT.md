# Components Test Directory

## Intent

ExUnit suites for the function components in `apps/evo_dash/lib/evo_dash_web/components/` (one test file per component module, 360 tests total).
All suites are `async: true`, import `Phoenix.LiveViewTest`, and render with `render_component/2` + Floki — Floki is always fed a PARSED tree (each file has its own `parse/1` = `Floki.parse_document!/1`, because `Floki.find/2` + `attribute/2` reject a raw binary).
There is **no `live(...)` call anywhere in this directory**: every component is rendered in ISOLATION.

## Routing Table

| File | Module | Describes / tests |
|------|--------|-------------------|
| `project_components_test.exs` | `EvoDashWeb.ProjectComponentsTest` | 8 / 21 — command palette (`project_omnibox/1`) + `project_settings_tab/1` (directory-picker browse buttons, PathAutocomplete wiring, remote gating, foreign-repo writable/base_sha UI) |
| `task_form_components_test.exs` | `EvoDashWeb.TaskFormComponentsTest` | 4 / 43 — `layout_for/1` boundaries, `task_form/1` control order/agent/model selects/attach-file, `task_options_tab/1` mode gating, speed ↔ quality segmented control |
| `commit_graph_view_test.exs` | `EvoDashWeb.CommitGraphViewTest` | 12 / 27 — `AgentsComponents.CommitGraphView.commit_graph_view/1` vertical per-agent-lane temporal view |
| `commit_graph/geometry_test.exs` | `EvoDashWeb.CommitGraphGeometryTest` | 3 / 8 — PURE lane-geometry / jog-staggering units for `CommitGraphView.Geometry` |
| `diff_viewer_test.exs` | `EvoDashWeb.DiffViewerTest` | 11 / 53 — `ReviewComponents.DiffViewer` pure units + tree/DOM contract + render caps |
| `archive_tree_test.exs` | `EvoDashWeb.ArchiveTreeTest` | 18 / 55 — archive tree/details rendering, string-keyed rows, cycles, paged envelope, `ArchiveHelpers` |
| `blob_caps_test.exs` | `EvoDashWeb.BlobCapsTest` | 7 / 26 — the rendering-cap regression suite |
| `task_card_components_test.exs` | `EvoDashWeb.TaskCardComponentsTest` | 9 / 35 — copy-text helpers, task card affordances, Review-button candidacy, structured errors, archive pass-through |
| `setting_card_test.exs` | `EvoDashWeb.SettingCardTest` | 3 / 18 — `setting_card/1` `:list_of_strings` editor, `default_label/1`, appearance accent swatch picker |
| `remote_gate_components_test.exs` | `EvoDashWeb.RemoteGateComponentsTest` | 5 / 16 — `remote_connection_gate/1` states + `gate_active?/1` truth table |
| `model_profiles_editor_test.exs` | `EvoDashWeb.ModelProfilesEditorTest` | 1 / 23 — render-only peak/off-peak concurrency form (events belong to SettingsLive) |
| `custom_agents_editor_test.exs` | `EvoDashWeb.SettingsComponents.CustomAgentsEditorTest` | 2 / 7 — the editor's extra "Custom tools" chip group + alias-aware comparisons |
| `custom_tools_panel_test.exs` | `EvoDashWeb.CustomToolsPanelTest` | 2 / 22 — `custom_tools_panel/1` render contract + pure `custom_tool_names/1` |
| `layouts_test.exs` | `EvoDashWeb.LayoutsTest` | 1 / 2 — `Layouts.app/1` sidebar "Active Tasks" grouping |
| `category_metadata_test.exs` | `EvoDashWeb.CategoryMetadataTest` | 2 / 4 — pure `SettingsComponents.CategoryMetadata` units |

## Coverage Boundary — review-page components

- Component-level coverage of `EvoDashWeb.ReviewComponents` lives in `diff_viewer_test.exs` (`diff_viewer/1`, `file_tree_sidebar/1`, `tree_node/1`, `split_diff_layout/1`, `commit_diff_layout/1`, `commit_detail_header/1`, `parse_hunk_header/1`, `build_split_pairs/1`, plus the rendered-line / rendered-entry caps), `archive_tree_test.exs` (`archive_review_section/1`, `ArchiveComponents.archive_tree/1` + `archive_details/1`) and `blob_caps_test.exs` (`agent_summary/1`, `objective_section/1`, `archive_review_section/1` preview caps).
- The remaining `ReviewComponents` surface — `Actions.task_actions/1` + `extract_skills_modal/1` + `conflict_files_summary/1`, `RepoCards.repo_cards/1` + `repo_has_changes?/1`, `page_header/1` + `short_title/1` + `task_summary/1`, `page_tabs/1`, `diff_stats_bar/1` + `commits_list/1` — has NO dedicated component-test file; it is exercised only through `test/evo_dash_web/live/review_live_test.exs` (hand-built LiveView assigns) or not at all.

## `project_components_test.exs` (8 describes / 21 tests)

- `project_omnibox/1 rendering` (5): trigger renders the active project name + **path** (the only path assertion in the file), placeholder, enlarged typography classes, `palette_keydown` on the SEARCH INPUT (LiveView keydown never walks ancestors), `phx-click-away`/backdrop close event.
- `directory picker browse buttons` (1, folded over all three buttons): the open-path / new-project / foreign-repo browse buttons keep `phx-hook="DirectoryPicker"` and have NO `phx-click` — a leftover `phx-click="pick_directory"` had no `handle_event` clause and crashed the LiveView in the desktop app.
- `browse buttons in remote contexts` (1, folded): gated on `tauri_detected and !remote`; the manual path inputs stay rendered in both contexts (`#foreign-repo-path-input` keeps `phx-hook="PathAutocomplete"`).
- `foreign repo path input autocomplete` (1): `#foreign-repo-path-input` carries `phx-hook="PathAutocomplete"`, `list="foreign-repo-path-suggestions"`, `phx-change="foreign_repo_path_input"`, `phx-debounce="150"`, and a datalist with one `<option value="…">` per suggestion.
- `foreign repo writable/base_sha UI` (9): the add form's `input[name=writable]` (checkbox, `value="true"`, unchecked by default) and `input[name=base_sha]` (value seeded from `new_repo_base_sha`, `""` when the assign is absent); repo rows render a `badge-warning` "Writable" badge + `<code>` base_sha for a writable repo and neither for a read-only one; every non-primary row carries the edit button with its repo id; the primary row has NO edit/remove buttons; `editing_foreign_repo_id` renders the inline edit form (falling back to the repo's own values when `foreign_repo_edit_form` is absent) and nil renders none. Fixtures use `%ForeignRepo{}` structs.
- `new project path input autocomplete` (1), `neutral placeholders` (1), `palette actions in remote contexts` (2 — "Create New Project" hidden on remote, "Open Project by Path" kept).
- No test asserts the `show_add_foreign_repo == false` negative for the add form beyond the edit-form cases above.

## `task_form_components_test.exs` (4 describes / 43 tests)

- `layout_for/1` (9): 1200-grapheme / 32-line thresholds (`:compact` at the boundary, `:expanded` above), non-binary fallback to `:compact`.
- `task_form/1 rendering` (26): `data-layout`; bottom-toolbar DOM order attach "+" (`button#objective-file-button`, first INSIDE `.input-controls`) | mode | (agent) | model | circular send `button#task-launch-button` LAST/rightmost — the right-aligned cluster is packed right by the MODE select's `ml-auto` (free space sits after the attach "+") and the launch button carries NO auto margin; compact `select-sm` classes on the mode/agent/model selects; model select label = bare id with "Auto (by rules)" first; disabled overlay; `flex-nowrap` one-line contract; mode select's 4 options (`genesis_existing`/`genesis_new`/`evolve_simple`/`custom_agent`; reflect removed); `data-mode` on the send button; custom_agent agent-select behaviours (Auto hidden, no-agents warning, evolve placeholder); AdaptiveInput + `phx-update="ignore"` with no per-keystroke event; attach-file button (`FilePicker` hook, `data-picker-id="objective_file"`, `type="button"`, hidden when disabled).
- `task_options_tab/1 rendering` (2): custom_agent shows evolve-family options and hides Build System; genesis_new is the inverse.
- `speed ↔ quality segmented control` (6): `div#quality-level-control` is a DIRECT child of `.input-controls` sitting AFTER the attach dropdown and BEFORE the mode select (bottom-LEFT), with `join`/`shrink-0` classes and `role="group"`; exactly three steps `#quality-level-fast` / `-balanced` / `-high` each carrying `phx-click="select_quality_level"` + its level; `quality_level: "balanced"` (default) / `"fast"` / `"high_quality"` moves the active highlight to exactly one step; every step is `type=button` so it never submits the enclosing task form.
- **NO foreign-repo / multi-repo coverage**: the task form tests never reference foreign repos, repo paths, or multi-repo UI.

## `commit_graph_view_test.exs` (12 describes / 27 tests, ~1 640 lines)

`EvoDashWeb.AgentsComponents.CommitGraphView.commit_graph_view/1` — the TEMPORAL commit-history view of the Agents page left panel: a VERTICAL GitKraken/GitLens-style PER-AGENT-LANE graph (one visible row per commit, an absolute left gutter `<svg>` drawing dots + child→parent / agent-level connectors, sticky per-lane header chips), rendered in isolation.
ALL fixtures are HAND-CRAFTED view models (`repo_view/1`, `node_view/1`, `edge_view/1`, `agent_map/1`) rather than `CommitGraph.build/2` output: `happy_repos/0` is a 3-lane / 6-node / 7-edge graph with a virtual merge-back landing (gutter `24 + 3*24 = 96` wide, `7*44 = 308` tall), `happy_two_repo_fixture/0` a second independent repo, and hand-crafted shapes cover what the builder cannot produce (odd/absent grid values, a fixed DOM id, unowned entries, missing colors, non-map entries).
Describes: root markers & states (`#commit-graph` + `phx-hook="CommitGraph"` → `#commit-graph-body-<node_key>`; a non-default `node_key` changes only the body id; `:loading`/`:empty`/`:error` are mutually exclusive; `#commit-graph-stale-warning` renders alongside a still-rendered graph), repo sections (the wrapper `div`'s id IS `repo.repo_dom_id` VERBATIM — the builder already emits `commit-graph-repo-<slug>-<hash>`, the component adds NO prefix), scroll + gutter geometry (`#cg-scroll-<dom>.cg-scroll` hosting the sticky `#cg-lane-header-<dom>` then `#cg-list-<dom>.cg-list` with the absolute `svg.cg-gutter` and `.cg-rows` left-padded by the gutter width; derived `width`/`height`/`viewBox` + `role="img"`/aria-label; the truncation strip `#cg-truncated-<dom>` rendered ONLY on an explicit `truncated: true`), lane chips (neutral "Pre-task" span only when unowned nodes exist, `button#cg-lane-<dom>-<lane>` per agent lane incl. a node-less lane, depth-hue border/text, status dot, `select_agent` contract, two-row `lane mod 2` stagger, `opacity: 0.5` when ended), edges, nodes, rows, row tooltips/keyboard/selection data, tags, selection, ended dimming, and total/defensive degradation.
Edge contract: `path.cg-edge[data-commit-graph-anim="edge"]`, `fill="none"`, stable ids — commit→parent `#commit-edge-<dom>-<from>-<to>` vs agent-level `#commit-edge-<dom>-<kind>-<owner>-<from>-<to>` with an `l<col>r<row>` landing key for a VIRTUAL merge-back (`to_sha: nil`); same-lane is a straight vertical, cross-lane uses two `Q` quarter-turns and NEVER the sharp `L n n L n n L n n` signature; `:parent` is SOLID `stroke-width="2"` while `:merge`/`:spawn`/`:merge_back` are DASHED `"4 3"` width `1.6`. Routed through the BATCH-AWARE `Geometry.edge_geo/3`: a LONE lane-pair edge keeps the canonical midpoint route byte-for-byte, while CONCURRENT edges sharing an unordered lane pair are staggered onto distinct jog ys (`@jog_clear` 8 px steps, asserted via `jog_y/1`).
NOTE: Floki's HTML parser lowercases attribute names, so the SVG's `viewBox` is queried as `viewbox`.
File-local helpers: `parse/1`, `attr/2`, `text/1`, `dom_id/1`, `render_repos/2`, `element_children/1`, `edge_id/2`, `path_start/1`, `jog_y/1`, `node_title/2`; `happy/0` and `happy_selected/1` return a `{repo, dom, tree}` triplet, `happy_ended/0` is the happy fixture with its agent flagged `ended: true` (`mark_agent_ended/2`).
Don't split this file casually — it is a legitimately large render-contract suite.

## `commit_graph/geometry_test.exs` (3 describes / 8 tests)

PURE units for the jog-STAGGERING of concurrent cross-lane edges in `AgentsComponents.CommitGraphView.Geometry`: `edge_geo/2` vs the batch-aware `edge_geo/3` (pixel-identical for a lone pair edge and for a group's FIRST member), distinct routes for 2–4 concurrent pair edges, determinism from edge-list order, span clamping on short spans, interior-row dot-band clearance, virtual-landing (`to_sha: nil`) participation, and the non-staggerable shapes (same-lane edges, a non-list `edges` arg).

## `diff_viewer_test.exs` (11 describes / 53 tests)

`parse_hunk_header/1` (5) + `build_split_pairs/1` (9) pure units; split-view rendering contract (12 — escaped plain text, no server-side highlight, `data-language`, a single `phx-hook="DiffViewer"`); `diff_viewer/1 — lazy diff loading` (3 — unexpanded is metadata-only, expanded + nil diff shows "Loading diff...", per-file `toggle_file_expansion`/`expand_context` payloads incl. the `:all` context level); `file_tree_sidebar/1 — server-driven tree state` (8 — dirs collapsed by default, `toggle_dir` buttons carrying the FULL dir path + `aria-expanded`, no `<details>` in the tree, subtree aggregates, dirs-first case-insensitive sort, `collapse_all_dirs`/`expand_all_dirs`); `file_tree_sidebar/1 — flat filter mode` (4 — `filter_files` input attrs, flat mode preserves `@files` order (no re-sort), "No matching files"); `split_diff_layout/1 — multi-repo toolbar` (6 — `>1` repo gate, `select phx-change="switch_repo"`, option labels + active preselection (Floki normalizes bare `selected` to `selected="selected"`), summed +/− scoped to `div.ml-auto`); `commit_diff_layout/1` (1 — no toolbar); `commit_detail_header/1` (2 — back link, truncated h1 + title attr, sha badge).
Render caps: `diff_viewer/1 — rendered-line cap` (2 — a 5 000-added-line diff renders additions 00001…01995 plus the exact "3,005 more lines not shown" note, and 01996+ never reach the DOM; an under-cap diff renders no note) and `file_tree_sidebar/1 — rendered-entry cap` (1 — 501 files → "Showing 500 of 501 files", 500 rows, `file-0501.txt` absent).

## `archive_tree_test.exs` (18 describes / 55 tests)

- String-keyed + cycle safety for `ReviewComponents.archive_review_section/1`, `ArchiveComponents.archive_tree/1` and `ArchiveComponents.archive_details/1` (string keys render exactly like atom keys; a parent cycle neither crashes nor loops).
- `archive_details/1 — paged archive envelope` (11): the count/range label against the TRUE total (falling back to the loaded count), "Load more" only while more pages exist (disabled + spinner while a page is in flight, an append failure offering the same event as Retry), and per-record results — "Show result" when a paged entry carries none, then spinner → capped result or a retry-able error line, no button when the entry already has one, plus orphan-parent promotion.
- `archive export link (node-aware)` (1) — the export href carries `?node=` on a remote node.
- `normalize_agent_keys/1` (4) — string-keyed nested `usage` (a DB round-trip shape) normalizes so usage tiles read it.
- usage tiles from string-keyed usage for both `archive_tree/1` and `archive_review_section/1` (2, one each).
- `build_tree_capped/2 — orphan-parent promotion` (8) and `build_review_tree_capped/2 — orphan-parent promotion` (2).
- Pure `ArchiveHelpers` units: `result_loaded?/1` (3), `merge_entry/2` (6), `page_bounds/2` (4), `archive_opt?/1` (2), `retain_window/2,3` (5), `retained_page_bounds/3 + more_pages?/3` (2).

## `blob_caps_test.exs` (7 describes / 26 tests)

Regression suite for the rendering caps that stop the dashboard from interpolating unbounded task blobs (a real task carried a 108 MB `result`).
Every test builds a marker-bearing oversized blob, renders the component, and asserts (a) the head is visible, (b) the TAIL MARKER is absent from the rendered body, (c) the dim "Showing X of Y …" note reports the true total.
- `TaskCardComponents.task_card/1 — in-card payload caps` (5): expanded card renders only the 16 384-byte result preview + the exact "Showing 16,384 of <total> bytes" note; the expanded objective preview is capped the same way; the collapsed card renders no result body / no "Agent Message"; `render_result_full/1` (the explicit Full Result modal path) renders the COMPLETE text incl. the tail marker and no note; the in-card `data-content` copy payload is exactly 1 048 576 bytes with the "Copy is limited to the first 1 MB" title.
- `ArchiveComponents.archive_details/1 — record + payload caps` (2): 400 loaded records → exactly 300 record containers (`@max_agent_records`; paging is the real bound), the "Showing 300 of 400 agent records" note with the TRUE loaded total, `agent-301` absent, and a 50 KB result truncated to 8 192 bytes with the tail marker gone; the per-record objective caps at 4 096 bytes.
- `ArchiveHelpers.build_tree_capped/2` (11): default 100 cap with true `total`/`shown`/`truncated?`, at/below-cap, explicit `max`, `max: 0`, negative/garbage `max` → default, non-list input → empty untruncated result, non-map entries skipped and uncounted, parent/child nesting, parent-less (orphan) records PROMOTED to top level and counted as `shown`, roots filling the slice before their children, and a 150-deep chain bounded to the slice.
- `ArchiveHelpers.build_review_tree_capped/2` (3): tuple-shaped `{agent, children}` nodes with the same cap/total contract, nested tuples, non-list totality.
- `ReviewComponents.agent_summary/1 — report caps` (3): the Markdown AND Raw branches both render only the 16 384-byte prefix + note; the copy payload caps at 1 MiB with the truncation hint in the title.
- `ReviewComponents.objective_section/1 — objective caps` (1) and `ReviewComponents.archive_review_section/1 — record caps` (1): the same 300-record / 8 192 / 4 096 arithmetic on the review side.

## Notes for Agents — blob-cap rendering tests (`blob_caps_test.exs`)

- **Assert on VISIBLE TEXT, never raw HTML**: the copy buttons materialize their (legitimately up-to-1-MiB) payload in a `data-content` ATTRIBUTE, so a ~100 KB result's tail marker IS present in the raw HTML even though the body is correctly capped.
  Text is extracted with the file-local `rendered_text/1` (`Floki.text/1` — text nodes only; the binary clause handles `render_component/2` output, the other clause runs `rendered_to_string/1` for a directly-called component such as `TaskCardComponents.render_result_full/1`, whose single argument is the RESULT term).
- **Read a 1 MiB attribute WITHOUT parsing the document**: Floki's mochiweb parser takes ~250 ms on a document carrying a 1 MiB attribute (super-linear attribute parsing), so the two 1 MiB payload tests use the file-local `tag_attrs(html, id)` instead — it locates `id="…"`, cuts the opening tag at the first raw `>`, and each value at the first raw `"` (Phoenix escapes `"`/`>` inside attribute values), returning the `data-content` / `title` attributes straight off the real rendered HTML. Keep this rationale: it is a measured performance fact, not a style choice.
- **Function components need MAP assigns when called directly**: `TaskCardComponents.task_card(task: ..., show_details: true)` raises `BadMapError` — either go through `render_component/2` (keyword list) or pass a map.
- **Exact note strings** (test locale = English msgids): `"Showing %{shown} of %{total} bytes"` (task card 16 384 / archive 8 192 / objective 4 096 / review report 16 384), `"Showing %{shown} of %{total} agent records — export JSON for the full archive"` (the single record-cap note shared by BOTH `ArchiveComponents.archive_tree/1` and `ReviewComponents.archive_review_section/1`, cap 300), `"Showing %{shown} of %{total} files"` (diff sidebar cap 500), `"%{count} more lines not shown"` (diff cap 2 000 lines), `"Copy is limited to the first 1 MB"` (copy-button title). Counts run through `Helpers.format_number/1`, so assert with `Helpers.format_number(byte_size(blob))` rather than hardcoded commas.
- **`ArchiveHelpers` capped builders** are pure and take a RAW record list (atom OR string keys): `shown` counts nodes actually PRESENT in the built tree (a record whose `parent_id` matches nothing in the slice is PROMOTED, so it is shown) while `truncated?` is only ever about records dropped by the CAP — assert both properties separately.
- **Diff cap arithmetic**: the 2 000-line cap counts DIFF lines (header lines included), so a 5 000-added-line file renders additions 00001…01995 and reports `3,005 more lines not shown`. Keep the synthetic fixture's added lines zero-padded (`+added line 00001`) so a content assert can never collide with a gutter line number.

## `task_card_components_test.exs` (9 describes / 35 tests)

- `objective_text/1` (3) — trimmed `:prompt` with `:objective` fallback; empty/nil/whitespace → `""`.
- `result_copy_text/1` (5) — raw agent message on success (incl. `no_changes: true`) and plain maps, inspected reason on error/crash, pretty-inspected fallback.
- `result_repos/1` (3) — the repos map → badge list (STRING keys), primary + foreign, nil for single-repo.
- `task_card/1 summary-map safety` (2) — a 16-key summary map (no result/opts detail) renders without raising.
- `task_card/1 — Review button candidacy` (5) — Review renders for a `:completed` task with no primary branch, for a completed multi-repo task that changed only a foreign repo, and for a cancelled task; a `:reflect` (repo-less) task NEVER renders it (no `/review/` href, no `hero-eye`).
- `task_card/1 — failed-task structured error display` (9) — collapsed error strip (truncated `error.message`, kind-label fallback), expanded detail block (kind + "Source: …" caption chips via `Helpers.task_error_kind_label/1` / `task_error_source_label/1`, full message, last ≤8 stacktrace frames in a `<pre>`), legacy `{:error, _}` result-box coexistence, `error: nil`/non-map safety.
- `task_card/1 — best-effort cost notice` (2) — `Helpers.cost_estimate_notice/1` renders at the card's cost display.
- `Archive accessors — the paged archive envelope` (4) + `task_card/1 — paged archive pass-through` (2) — the per-card archive accessors and their render wiring.

## `setting_card_test.exs` (3 describes / 18 tests)

- `setting_card/1 — :list_of_strings list editor` (8) — repeated text inputs all named after the key (they submit as one list), per-entry remove + one add control (both carrying `phx-value-key_path`), and a hidden sentinel keeping a SET list (even `[]`) distinct from an UNSET (nil) list on submit.
- `default_label/1 — rendered on the Default line` (3).
- `setting_card/1 — :appearance accent swatch picker` (7) — ten GNOME/libadwaita names, the active swatch is the ONLY one carrying `ring-2 ring-offset-2 ring-base-content/70 scale-110`, whitelist rejection on unknown values.

## `remote_gate_components_test.exs` (5 describes / 16 tests)

`remote_connection_gate/1` connecting states (`:connecting`/`:bootstrapping`/`:disconnecting` spinner + "Connecting to <name>…", nil `remote_status` treated as connecting), display-name fallback (`name` attr → `current_node_name` → "Local" — the core regression: the five node-aware LiveViews pass RAW assigns, which carry `current_node_name` but no `:name`), error states, the connected state, and the `gate_active?/1` truth table.

## `custom_tools_panel_test.exs` (2 describes / 22 tests)

`custom_tools_panel/1` (13) — renders the `EvoGit.CustomTools.status/0` value through the shared `CardShell`: ok entries (atom- AND string-keyed) render name/module/file with a `badge-ghost` "Read-only" or `badge-warning` "Write" badge; error entries render file (nil → gettext "unknown file") + reason; the empty state ("No custom tools loaded") renders ONLY for `%{ok: [], errors: []}`-shaped statuses and is MUTUALLY EXCLUSIVE with the `{:error, _}` red banner ("Custom Tools Unavailable" + a `<pre>` with `inspect(reason)`); the Refresh `<button phx-click="reload_custom_tools">` always renders and carries `disabled` (Floki parses it as `["disabled"]`) when `loading: true`; totality on `nil`, non-list `ok`/`errors`, non-map entries, missing `errors` key.
`custom_tool_names/1` (9) — order-preserving extraction, `{:error,_}`/`nil`/bare-list → `[]`, blank + complex entries dropped, dedup, atoms/integers/floats stringified (`%{name: 1}` → `"1"`).

## `custom_agents_editor_test.exs` (2 describes / 7 tests)

Render-only coverage of the "Custom tools" chip group in `CustomAgentsEditor.custom_agents_editor/1` (rendered by the private `agent_edit_form/1`, reached by passing an `editing_agent_id` matching an agent's `id`): a loaded custom tool renders a `checked` `input[name="tools[]"]` INSIDE the `div.mt-3` group while built-in chips still render; a `custom_tool_names` entry colliding with a built-in is DROPPED; `custom_tool_names: []` → no group and no warning; a tool matching neither a built-in nor a loaded custom tool → the amber `p.text-warning` with the exact gettext sentence "Unknown tool names: totally_unknown_tool. They are neither built-in tools nor loaded custom tools."; an empty `tools: []` renders no warning.
Built-in names come from `EvoGit.Agent.Tools.schemas() |> Enum.map(&EvoGit.Agent.tool_name/1) |> Enum.reject(&is_nil/1)`.
The alias describe pins alias-aware comparisons: a legacy `tools: ["read_file", "run_bash"]` renders the read/shell chips as `checked` inputs whose submitted `value` stays the agent's OWN saved spelling (no `value="read"`/`value="bash"` input exists) with NO warning; a `custom_tool_names` entry named after a built-in alias (`read_file`) is dropped from the custom group while a genuinely unknown selected tool still warns.

## `model_profiles_editor_test.exs` (1 describe / 23 tests)

Render-only peak/off-peak form coverage: `peak_concurrency` (incl. `0`), `peak_hours` rows, `timezone`, draft-wins pre-fill, remove-row buttons, plus the days-of-week fields (`off_peak_days` profile chips + per-window `peak_hours[<i>][days]` chips — checked-state derivation, no hidden seed for window days, index threading) and a guard that start/end/remove-row markup coexists. Row events (`add_peak_hours_row` / `remove_peak_hours_row`) belong to SettingsLive and are not exercised here.

## `layouts_test.exs` (1 describe / 2 tests)

`app/1 — sidebar task grouping` — the ONLY suite here that renders the full app shell: `render_component(&Layouts.app/1, ...)` with just `flash: %{}` plus a stubbed `inner_block` slot (every other attr takes its declared default; the embedded `NodeSelectorComponent` `live_component` renders fine outside a LiveView).
Group headers come from `Floki.find("span.sidebar-label:has(.hero-folder)")` (the folder icon makes group headers the only such spans); task links via `[data-sidebar-task-link]`, labels via the inner `span.truncate`.
Coverage: non-map `running_tasks`/`pending_tasks` entries (`:junk_atom`, a binary) are silently OMITTED while a valid task still renders under `Path.basename(project_path)`; well-formed entries keep the `nil` path → `"Other"` group FIRST, then case-insensitive alphabetical group order with running-before-pending inside a group.
Helpers: `render_app/1`, `sidebar_group_names/1`, `sidebar_task_links/1`, `sidebar_task_labels/1`, `task/1`.

## `category_metadata_test.exs` (2 describes / 4 tests)

Pure units for `SettingsComponents.CategoryMetadata`: `category_display_name/1`, `category_icon/1`, `category_description/1`, `sort_categories/1` (pinned on the `:data` category).

## Known Issues / Notes for Agents

- `EvoDashWeb.ProjectComponentsTest` "trigger renders the active project name and path" is the only path-rendering assertion — the open palette's project ROWS are never rendered with a populated project list in any test.
- Helper convention: each file defines its own `attribute/2,3`, `parse/1`, `button_class/1` etc. — there is no shared component-test helper module.
