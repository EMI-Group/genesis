# ReviewComponents — Sub-Components

## Intent

Sub-component modules extracted from `EvoDashWeb.ReviewComponents` to keep each component focused: `DiffViewer` (diff viewer system — plain-text diff parsing/rendering; syntax highlighting is applied client-side), `Header` (review header, task summary, agent summary), `Actions` (action buttons and skills extraction modal), `Stats` (diff stats bar and commit list).

## Routing Table

None — leaf directory (four module files: `diff_viewer.ex`, `header.ex`, `actions.ex`, `stats.ex`).

## API Surface

### `DiffViewer` — Diff Parsing & Rendering (`diff_viewer.ex`, 649 lines)

`DiffViewer` has a single responsibility: parse raw git diff text and render it. **Syntax highlighting is applied CLIENT-SIDE by the `DiffViewer` JS hook** — the backend renders escaped plain-text diff lines only (no `Phoenix.HTML.raw`, no server-side highlighting, no Floki, no try/rescue for highlighting). This crash-isolates the highlighter: a frontend highlight failure is a harmless cosmetic issue, whereas a server-side Tree-sitter (Lumis/html5ever NIF) crash could kill a BEAM process mid-task.

Rendering contract:

- The `#diff-viewer` container (`diff_viewer/1`) carries `phx-hook="DiffViewer"`. **LiveView 1.2 supports exactly ONE hook name per element** — the whole attribute value is looked up as a single hook name; space-separated lists are pre-1.2 behavior and silently attach NOTHING (the console then warns `unknown hook found for "<value>"`). That is why scroll-to-file and highlighting were merged into the single `DiffViewer` hook. Each per-file `<div class="diff-file-section">` carries `data-language={file.language}` — the backend passes through `EvoGit.Review.language_for_file/1` Lumis-style names (`elixir`, `c_sharp`, `text`, …; `nil` → attribute omitted; `Review` stamps every file, defaulting unknown extensions to `"text"`).
- `render_diff_content/3` and `diff_split_row/1` render `line.content` directly as escaped text inside `phx-no-format` spans — no highlight markup is ever produced server-side.
- `commit_diff_layout/1` (commit-inspection view) shares the same `<.diff_viewer>` component as `split_diff_layout/1` (branch-review view).
- Context expansion (`expand_context`) re-fetches the diff with a wider window and `update_file_diff_in_socket/4` swaps only the file's `diff` field — no full-file content fetches, no `:preserve` sentinel.

Client-side highlighting flow (`assets/js/hooks/diff_viewer.js`, vendored highlight.js 11.11.1):

- The `DiffViewer` hook registers the `scroll_to_file` event handler in `mounted()` (it replaced the old separate scroll-to-file hook) and runs its highlight pass in BOTH `mounted()` and `updated()`: morphdom applies in-place patches (lazy file load, `expand_context`, `select_file`) without re-initializing hooks, so `updated()` re-highlights new/changed rows; `mounted()` covers full remounts (tab switches destroy/recreate `#diff-viewer`, task reloads collapse files).
- Per `.diff-file-section`, reads `data-language` and maps lumis→hljs names (`c_sharp` → `csharp`, `text` → `plaintext`, everything else passes through). Unknown languages (`hljs.getLanguage` undefined) skip the whole section — a wrong grammar is worse than no highlighting.
- Per `.diff-split-cell` (skipping cells marked `dataset.hl === "1"` and empty/whitespace-only cells): reads `textContent`, calls `hljs.highlight(code, {language})` inside try/catch (a throw leaves the cell as plain text — never breaks the page), assigns `innerHTML`, and sets `dataset.hl = "1"` (morphdom replaces changed leaf cells without the marker, so only new cells are processed).
- No-ops gracefully if hljs failed to load (cells stay plain text).

Parsing/rendering functions:

- `parse_diff_lines/1` — splits the raw diff into typed lines (`:header`, `:hunk`, `:addition`, `:deletion`, `:meta`, `:no_newline`, `:context`), stripping `+`/`-` markers.
- `parse_hunk_header/1` — extracts `{old_start, new_start}` from `@@` headers.
- `build_diff_segments/1` — groups lines into `{:pre_hunk, lines}` (meta/header before the first hunk) and `{:hunk, hunk_line, pairs}` segments.
- `build_split_pairs/2` — converts a hunk body into paired split-view rows (context on both sides; deletions left-only; additions right-only; consecutive del+add blocks zipped with `nil` padding on the shorter side).
- `diff_split_row/1` — renders one split-view row (4 grid cells: old gutter | old content | new gutter | new content).
- `file_tree_sidebar/1` + `tree_node/1` — sidebar file tree with per-directory aggregate add/delete counts.
- `diff_expand_bar/1` — expandable context bar at hunk edges (fires the `expand_context` event).

The split layout uses a 4-column CSS grid (`.diff-split-table`). Hunk headers (`@@ -x,y +a,b @@`) and expand bars span all 4 columns via `grid-column: 1 / -1`.

### Highlight token CSS

The `.hljs-*` token palette lives in `assets/css/app.css` (light + `[data-theme="dark"]` variants, GitHub-light/dark inspired). The span-neutralizer rules (`.diff-line-content span` / `.diff-split-cell span` → inline, transparent background, inherited font — but NOT `color: inherit`, so the token colors show through) keep the injected highlight spans from breaking the diff grid.

### Full-content fields (inert)

`EvoGit.Review.FileInfo` still carries `full_new_content`/`full_old_content` struct fields (nil by default), but nothing populates them — `ReviewLive` fetches only the diff text (via `load_file_diff`/`load_commit_file_diff`). They are leftovers of the removed server-side file-level highlighting; do not reintroduce full-file fetches (client-side highlighting needs only the diff lines).

### Other Modules

- **`Header`** — Review header, task summary, and agent summary.
- **`Actions`** — Action buttons (merge/reject/resume/create PR) and skills extraction modal.
- **`Stats`** — Diff stats bar and commit list.

### Field-consumption audit (which data fields each component reads)

Verified against `review_live.ex` wiring (lines 63-183) + the four module files. All components are **purely display** — none re-fetches data (no `EvoDash.NodeContext`/`EvoGit.Review`/`TaskRegistry` calls in the subtree); every event they fire (`switch_tab`, `select_file`, `toggle_file_expansion`, `expand_context`, `inspect_commit`, `merge`, `merge_target_change`, `reject`, `resume`, `create_pr`, `ignore`, `auto_resolve`, `extract_skills`, `confirm_extract_skills`, `cancel_extract_skills`, `toggle_summary_view`) is handled by ReviewLive, which does the actual fetches (`EvoDash.NodeContext.load_file_diff*`, `load_commit_files`, …).

- **`review_header`** (`header.ex:18-50`): reads `title` (:25), `status` atom only — via `Helpers.review_status_badge/icon/label` (:27-29; helpers.ex:126-150, pure atom→string/class maps), `task_type` (capitalized text, :31), `branch_name` (badge, gated `if`, :32-37), `commit_sha` (only `String.slice(sha, 0..7)` for the badge, :38-43). No other task fields.
- **`task_summary`** (`header.ex:92-287`): reads `usage` (a `%EvoGit.Agent.Usage{}` struct or nil; accessed only via `Map.get` — total_tokens :102/:195, total_cost :110/:259, `format_cache_hit_rate` :118/:224 which itself reads `:input_tokens`+`:cached_tokens` (helpers.ex:741-752), input_tokens :179/:229, output_tokens :187, cached_tokens :208/:230, cache_creation_tokens :216, input_cost :247, output_cost :253; the details block is gated on `@usage` truthy :96/:164 and the cache row on cached/cache_creation > 0 :200), `agent_count` (:122-129 strip + :265-274 details footer, `format_number`), `status` (capitalized, :130-137 — fed `@task_status`, the task status NOT review status), `task_type` (capitalized, :138-145), `started_at`/`finished_at` (`relative_time/1`, :146-161), `model_id` (details footer only, :275-279).
- **`review_tabs`** (`review_components.ex:36-86`): `active_tab` (5 comparisons :42/:50/:58/:67/:77), `commits_count` badge (:62), `files_count` badge (:71), `show_archive` gate (:73), `agents_count` badge on the archive tab (:81). Wired from review_live.ex:96-99: `files_count` = `@review_data.changed_files_count`, `commits_count` = `length(@commits)`, `show_archive` = `@archive_metadata not in [nil, []]`, `agents_count` = `length(@archive_metadata)`.
- **`agent_summary`** (`header.ex:296-352`): reads only `summary` (the agent's result string — raw `<pre>` when `summary_raw` :309-310, else `raw(EvoDash.MarkdownRender.render(@summary))` :312-314) and `summary_raw` toggle (:321/:330); copy button embeds `data-content={@summary}` (:343). `MarkdownRender` runs server-side in the LiveView (in-process, no external fetch).
- **`diff_stats_bar`** (`stats.ex:17-46`): `files_count` (:24), `additions` (:29), `deletions` (:32), `commits_count` (:40). Wired from `@review_data` keys `changed_files_count`/`total_additions`/`total_deletions` (review_live.ex:119-121) — the ONLY place those three review_data top-level keys are consumed by components.
- **`split_diff_layout` / `commit_diff_layout`** (`diff_viewer.ex:133-198`): both just render `file_tree_sidebar` + `diff_viewer` with the same four attrs (`files`, `expanded_files`, `selected_file`, `file_context_levels`). Per-`FileInfo` field reads: **`path`** (tree build :584, header :92/:97, `file_path_to_id` :92), **`status`** (:105 + tree :64 via `file_status_icon/color` :566-574 — string atom-ish values "added"/"deleted"/"modified", catch-all else), **`additions`/`deletions`** (header :109-110, tree file node :70-71, dir aggregates :44-45), **`language`** (:93 → `data-language` attr; from `EvoGit.Review.language_for_file/1`, stamped on every file, default "text"), **`diff`** (only in `render_diff_content` :205/:220). **Drivers**: `expanded_files` map (`Map.get(@expanded_files, file.path, false)` :102 — file body renders only when true :112); `file_context_levels` map (`Map.get(@file_context_levels, file.path, 3)` :114 — default 3, `:all` disables expand bars); `selected_file` is declared on `diff_viewer/1` (:83) and passed through (:140) but **never referenced in its body** — it only drives the tree row highlight (`tree_node` :60). **Lazy diff confirmed**: `render_diff_content` checks `file.diff` twice — `if file.diff, do: parse_diff_lines(file), else: []` (:205) and `is_nil(@file.diff)` → "Loading diff…" spinner (:220-224); ReviewLive swaps in `file.diff` via `update_file_diff_in_socket/4` after the `load_file_diff` event (review_live.ex:383-410, 1032-1052). So the header/stats render from metadata alone; full diff text renders only for expanded files whose diff has been fetched.
- **`commits_list`** (`stats.ex:54-90`): per `%EvoGit.Review.CommitInfo{}` reads `sha` (:70 `phx-value-sha`), `short_sha` (:73), `message` (:75 title+text), `author_name` (:79), `date` (:82 `relative_time`). `length(@commits)` for the count (:61).
- **`action_buttons`** (`actions.ex:19-176`): `branch_exists` (:30 gate on merge/reject/resume/divider, :92 gate on Create PR, :112 gate on Extract Skills; `not branch_exists` :124 warning box + :154 resume), `has_pr` (:92/:102), `pr_url` (:102-103), `loading` (disables all buttons), `is_no_changes` (:127/:135-143 — warning vs info styling/message), `merge_targets` (:31, options :41) + `default_merge_target` (:43 `selected`, :53 confirm text), `merge_status` (:27 → `merge_status_block`). `merge_status_block` (:185-230) pattern-matches only `%{state: :checking}` (:188), `%{state: :clean}` (:193), `%{state: :conflict, files: files}` (:198 — `length(files)` :199 and `conflict_files_summary(files)` :209/:234-241 = first 4 paths joined + "…"); **`merge_status.target` is NOT read** by the component (ReviewLive uses it for the merge call), and `state: :error` (or any other shape) hits the `_ ->` catch-all (:227) and renders nothing (old fallback behavior). `can_resume` (:154) gates the extra Resume button when the branch is gone.
- **`commit_detail_header`** (`diff_viewer.ex:153-175`): reads `message` (:160), `sha` (:164, sliced 0..7), `author_name` (:166), `date` (:168) of the `@commit` map (fed `@commit_header` = the matching `%CommitInfo{}` from `@commits`, review_live.ex:1085-1093).
- **`extract_skills_modal`** (`actions.ex:249-310`): reads only `show` (:251 gate). No data fields (user_note textarea is client-side).
- **`objective_section`** (`header.ex:58-78`): reads only `objective` (:60 gate, :71 text).
- **`archive_review_section`/`archive_tree_node`** (`review_components.ex:95-260`): `archive_metadata` (:96 → `ArchiveHelpers.build_archive_tree_for_review`) + `task_id` (export link :108-109); per-agent keys `agent_id`, `depth`, `started_at`, `objective`, `result`, `base_commit`, `final_commit`, `archive_ref_start`, `archive_ref_final`, `usage[:input_tokens|:output_tokens|:total_tokens|:cost]`, `completed_at` (string-keyed after DB round-trip — see the evo_dash_web CONTEXT.md known-issues for the `:cost`/nested-key gotchas).
- **Full content rendering**: the ONLY full-content rendering is `render_diff_content` (split-view diff text for expanded files) and `agent_summary` (markdown/raw). `full_new_content`/`full_old_content` FileInfo fields are never read (inert — see above).

### Merge-target branch selector (`Actions.action_buttons/1`)

The review page's merge action can merge into a user-selectable branch instead of always the repo default. `action_buttons/1` takes `merge_targets` (list of local branch names) and `default_merge_target` (resolved default branch name, or nil). When `merge_targets != []`, the Merge button is wrapped in a `<form phx-submit="merge" class="contents">` alongside a compact `<select name="target_branch">` (DaisyUI `select-sm select-bordered rounded-lg`) pre-selecting `default_merge_target`; the Merge button becomes `type="submit"` (keeping `phx-confirm`). When `merge_targets == []` (branches couldn't be listed), the plain `phx-click="merge"` button renders. The event params' `"target_branch"` lands in the `merge` handler. Data sources (all in `EvoGit.Review`, called from `ReviewLive.load_task_data/2` with plain `case` on the tuple returns — no try/rescue): `list_branches/1` (names filtered to non-blank binaries), `default_merge_target/1`, and `merge_branch/3` (merge_branch/2 is the default-resolving path — do not remove it).

## Constraints

### `try/rescue` Policy

`try/rescue` is normally an anti-pattern in Elixir. Within these component files:

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`. When normalizing potentially untrusted DB-sourced data (e.g., agent archive maps after a Jason.decode round-trip), use an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) with `Map.get/3` defaulting to the original key. This avoids dynamic atom creation AND avoids try/rescue.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.
