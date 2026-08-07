# ReviewComponents — Sub-Components

## Intent

Sub-component modules extracted from `EvoDashWeb.ReviewComponents` to keep each component focused: `DiffViewer` (diff viewer system with syntax highlighting), `Header` (review header, task summary, agent summary), `Actions` (action buttons and skills extraction modal), `Stats` (diff stats bar and commit list).

## Routing Table

None — leaf directory (four module files).

## API Surface

### `DiffViewer` — Syntax Highlighting (file-level primary, hunk-level fallback)

The diff viewer highlights code via Tree-sitter (Lumis). It uses a **file-level-primary / hunk-level-fallback** design:

- **File-level (primary):** When the full file content at the new/old commit is available (`FileInfo.full_new_content` / `full_old_content`), the ENTIRE file is highlighted in a single Lumis call per side. Tree-sitter then has full context (imports, function boundaries, multi-line constructs) and produces consistent highlighting. The diff lines are walked hunk-by-hunk; each hunk's `@@` header provides 1-indexed starting line numbers in the old/new files, which are used to index into the full-file highlight arrays (converted to 0-indexed). Context lines prefer `new_hl`, addition lines use `new_hl`, deletion lines use `old_hl`. Out-of-bounds or nil lookups fall back to the raw line content (not empty string).
- **Hunk-level (fallback):** When full content is unavailable (fetch failed for added/deleted files, the content is binary — detected via null-byte heuristic in the first 8KB, or the file exceeds `@max_full_file_bytes` = 500_000 bytes), the original approach is used: reconstruct clean old/new code strings from each hunk and call Lumis once per hunk code block. This is extracted as `precompute_highlights_hunk_level/2`.

Entry point: `precompute_highlights(lines, language, full_new_content, full_old_content)` dispatches to the appropriate path.

Helpers reused by both paths: `highlight_code_block/2` (single Lumis-call helper that calls `parse_lumis_lines/1`). The `highlight_code_block/2` try/rescue is the ONLY justified try/rescue in this subtree (Lumis.highlight!/2 raises, non-bang variant also raises internally).

### Lumis HTML Parsing (Floki-based)

`parse_lumis_lines/1` parses Lumis's `html_multi_themes` formatter output into a map `%{line_number => inner_html}`. It uses **Floki** (configured with the **html5ever** Rust NIF parser via `Application.put_env(:floki, :html_parser, Floki.HTMLParser.Html5ever)` in `EvoDash.Application.start/2`). The previous regex-based approach was replaced because Lumis HTML can contain nested `<div>` tags and multi-line spans that broke regex matching.

The parser:
1. Calls `Floki.parse_document/1` on the raw Lumis HTML (returns `{:ok, document}` or `{:error, _}`)
2. Uses `Floki.find(".l-line")` with a CSS selector to find all line divs
3. Reads the `data-line` attribute via `Floki.attribute("data-line")` for the 1-based line number
4. Extracts inner HTML via `Floki.children()` + `Floki.raw_html/1` (preserves `<span>` highlighting tags)
5. Returns `%{}` on parse failure

### Split View Rendering (GitHub-style)

`render_diff_content/3` renders a **split view** (old version on left, new version on right, side by side) instead of a unified single-column diff. The layout uses a 4-column CSS grid (`.diff-split-table`): old gutter | old content | new gutter | new content.

Key functions:
- `build_diff_segments/1` — Groups parsed diff lines into `{:pre_hunk, lines}` (meta/header before first hunk) and `{:hunk, hunk_line, pairs}` segments.
- `build_split_pairs/2` — Converts a hunk's body lines into paired rows for the split view. Walks the hunk maintaining `old_line_num`/`new_line_num` counters (from the `@@` header). Context lines appear on both sides; deletions only on the left (with blank right); additions only on the right (with blank left). Consecutive del+add blocks are zipped together, padding the shorter side with `nil` placeholders.
- `diff_split_row/1` — Renders a single split-view row (4 grid cells).
- Hunk headers (`@@ -x,y +a,b @@`) and expand bars span all 4 columns via `grid-column: 1 / -1`.

### Full-content fields

`EvoGit.Review.FileInfo` carries `full_new_content` (content at the head/new commit) and `full_old_content` (content at the base/old commit), both nil by default. These are populated by `ReviewLive` on initial lazy-load (`maybe_load_review_diff`/`maybe_load_commit_diff`) via `Review.get_file_content/3`, and preserved across context-expansion (`expand_context` passes `:preserve` so the existing values are carried forward — content doesn't change, only the diff context window).

### Other Modules

- **`Header`** — Review header, task summary, and agent summary.
- **`Actions`** — Action buttons (merge/reject/continue/create PR) and skills extraction modal.
- **`Stats`** — Diff stats bar and commit list.

### Merge-target branch selector (`Actions.action_buttons/1`)

The review page's merge action can merge into a user-selectable branch instead of always the repo default. `action_buttons/1` takes `merge_targets` (list of local branch names) and `default_merge_target` (resolved default branch name, or nil). When `merge_targets != []`, the Merge button is wrapped in a `<form phx-submit="merge" class="contents">` alongside a compact `<select name="target_branch">` (DaisyUI `select-sm select-bordered rounded-lg`) pre-selecting `default_merge_target`; the Merge button becomes `type="submit"` (keeping `phx-confirm`). When `merge_targets == []` (branches couldn't be listed), the plain `phx-click="merge"` button renders exactly as before. The event params' `"target_branch"` lands in the `merge` handler. Data sources (all in `EvoGit.Review`, called from `ReviewLive.load_task_data/2` with plain `case` on the tuple returns — no try/rescue): `list_branches/1` (names filtered to non-blank binaries), `default_merge_target/1`, and `merge_branch/3` (merge_branch/2 remains the legacy default-resolving path — do not remove it).

## Constraints

### `try/rescue` Policy

`try/rescue` is normally an anti-pattern in Elixir. Within these component files:

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`. When normalizing potentially untrusted DB-sourced data (e.g., agent archive maps after a Jason.decode round-trip), use an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) with `Map.get/3` defaulting to the original key. This avoids dynamic atom creation AND avoids try/rescue.
- **The ONLY justified `try/rescue`** in this subtree is `highlight_code_block/2` in `diff_viewer.ex`, which wraps `Lumis.highlight!/2` for syntax highlighting (called once for the full file in file-level mode, or per code block in hunk-level fallback). It is justified because: (1) the non-bang `Lumis.highlight/2` also raises internally (does not return `{:error, _}`), so `case`/`with` cannot replace it; (2) falling back to raw un-highlighted code is the correct graceful degradation for a single file/hunk failure. This rescue **must** carry the inline justification comment — do not remove it.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.
