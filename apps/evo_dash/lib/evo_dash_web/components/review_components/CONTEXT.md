# ReviewComponents — Sub-Components
## Intent
Sub-component modules extracted from `EvoDashWeb.ReviewComponents` to keep each component focused.
## Modules
- `DiffViewer` — Diff viewer system (file tree sidebar, syntax-highlighted diffs, split/commit layouts)
- `Header` — Review header, task summary, and agent summary
- `Actions` — Action buttons (merge/reject/continue/create PR) and skills extraction modal
- `Stats` — Diff stats bar and commit list

## DiffViewer — Syntax Highlighting (file-level primary, hunk-level fallback)

The diff viewer highlights code via Tree-sitter (Lumis). It uses a **file-level-primary / hunk-level-fallback** design:

- **File-level (primary):** When the full file content at the new/old commit is available (`FileInfo.full_new_content` / `full_old_content`), the ENTIRE file is highlighted in a single Lumis call per side. Tree-sitter then has full context (imports, function boundaries, multi-line constructs) and produces consistent highlighting. The diff lines are walked hunk-by-hunk; each hunk's `@@` header provides 1-indexed starting line numbers in the old/new files, which are used to index into the full-file highlight arrays (converted to 0-indexed). Context lines prefer `new_hl`, addition lines use `new_hl`, deletion lines use `old_hl`. Out-of-bounds or nil lookups fall back to the raw line content (not empty string).
- **Hunk-level (fallback):** When full content is unavailable (fetch failed for added/deleted files, or the file exceeds `@max_full_file_lines` = 5000 lines), the original approach is used: reconstruct clean old/new code strings from each hunk and call Lumis once per hunk code block. This is extracted as `precompute_highlights_hunk_level/2`.

Entry point: `precompute_highlights(lines, language, full_new_content, full_old_content)` dispatches to the appropriate path.

Helpers reused by both paths: `highlight_code_block/2` (single Lumis-call helper), `split_html_by_newline/1`, `strip_lumis_wrappers/1`. The `highlight_code_block/2` try/rescue is the ONLY justified try/rescue in this subtree (Lumis.highlight!/2 raises, non-bang variant also raises internally).

### Full-content fields
`EvoGit.Review.FileInfo` carries `full_new_content` (content at the head/new commit) and `full_old_content` (content at the base/old commit), both nil by default. These are populated by `ReviewLive` on initial lazy-load (`maybe_load_review_diff`/`maybe_load_commit_diff`) via `Review.get_file_content/3`, and preserved across context-expansion (`expand_context` passes `:preserve` so the existing values are carried forward — content doesn't change, only the diff context window).
