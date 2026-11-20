# Store Operations

## Intent
Pure Ecto operation modules implement task/project persistence and bind the store's unnamed repo PID through `RepoScope.with_repo/2`.
Codec owns wire decoding; operation query errors propagate to the facade's failure-isolated read boundary.
`Operations.Decoding.decode_skipping_bad/4` is the ONE per-row skip-and-log decode boundary shared by Tasks, Safety and Summaries.

## API Surface
`Summaries.select_tasks_summary/3,4`, `select_tasks_summary_by_path/4,5`, and `select_tasks_changed_since/2` return lists of exactly 18-key maps: `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error, session_mode, pause_kind`.
Summary reads omit `result`, `logs`, and `usage`, but select and decode the entire `opts` and `error` columns without projection/redaction or byte limits.
Summary filters accept status atoms (`[]` means all), optional strict raw-text `updated_at > since`, and exact project-path equality, and skip undecodable rows with a warning.
`select_tasks_summary/3,4` and `select_tasks_summary_by_path/4,5` take an ADD-ONLY `:limit`: a positive integer applies `ORDER BY updated_at DESC` and `LIMIT min(n, 1_000)` (`idx_tasks_updated_at` serves the order), while absent/nil/non-integer/non-positive keeps the unchanged unordered, unbounded query.
`Pages.select_tasks_page/2` returns `%{rows: [summary], total: integer}` ordered by `started_at DESC`, defaults limit to 25, caps positive limits at 50, clamps invalid offsets to zero, and redirects an offset at/past the end to the last page.
The page is ONE statement carrying `count(*) OVER ()` (a SQLite co-routine) with `where_renderable/1` applied ONCE, so the multi-MB `opts` blob is type-tested once per page instead of twice.
Because the window function must see every matching row, `ORDER BY started_at DESC` falls to `USE TEMP B-TREE FOR ORDER BY` (documented honestly in the module) — one pass over the filtered set replaces two.
The last-page redirect runs the cheap `COUNT(*)` and a second page read only when the page is empty AND the requested offset is > 0.
Pages accepts nested `:filters` plus top-level `status/project_path/review_status/search` overrides, and applies the renderable-opts SQL predicate once per page statement.
`Tasks.safe_select_paginated_tasks/2` returns `{[TaskInfo], total}`, reads filters ONLY from nested `:filters`, defaults invalid/nonpositive limits to 50 but does NOT cap positive limits, and does NOT redirect out-of-range offsets.
Legacy pagination counts undecodable rows even when its per-row decoder skips them.
`Tasks.get_task/2` and `Pages.get_task_lite/2` both return full `%TaskInfo{}` or nil with `ref: nil`, including full `opts`, `logs`, `result`, `usage`, and `error`; lite selects 20 decode-relevant columns and omits only store-internal `updated_at`.
`Tasks.get_task_status/2` distinguishes missing nil from existing unreadable `{:unknown, raw}`.
`Tasks.select_task_update_info/2` is ONE typed query returning EXACTLY four keys: `%{status, opts, finished_at, lease_expires_at}` or nil.
The 4-key shape is load-bearing (a test asserts `map_size == 4`), and `opts` is still selected because `EvoGit.TaskRegistry` derives the repo path from `opts[:path]`; narrowing that read to the `project_path` scalar requires a `task_registry.ex` change and is NOT done.
`Tasks.put_task/2` is ONE `Repo.insert_all(TaskRow, [...], on_conflict: :replace_all, conflict_target: :id)` over a COMPLETE row inside one `:immediate` transaction (semantically identical to the old `INSERT OR REPLACE`); it is NOT delete+insert.
`Tasks.delete_task/2`, `delete_tasks/2` and `clear_tasks/1` run the task `delete_all` AND the explicit `task_agent_archives` cascade inside ONE `:immediate` transaction.
For `Tasks.delete_tasks/2` EVERY id chunk plus the archive delete commit together — the old per-chunk commit semantics are gone.
`Safety.safe_select_all_tasks/1` loads the whole set first; on a LOADER failure it re-reads ids once and then in chunks of 100, narrowing to per-row loads only inside a chunk that still fails.
Every `Safety` rescue is restricted to `[ArgumentError, FunctionClauseError, Ecto.Query.CastError]` (Ecto's loader raises `ArgumentError`), so a genuine database/adapter error PROPAGATES instead of degrading to `[]`.
`VctMounts.save/2` is a TRANSACTIONAL DIFF against the stored rows: upsert changed rows with `on_conflict: :replace_all, conflict_target: :point`, then delete the points that disappeared, inside ONE `:immediate` transaction, deduping input points.
An empty `VctMounts.save/2` input list still empties the table, and a bad entry still raises `ArgumentError` before any statement.
`VctMounts.list/1` returns every mount as a STRING-KEYED entry (`"point"`, `"path"`, `"name"`, `"kind"`, `"last_opened_at"`, `"members"`, `"description"`) newest first (`last_opened_at` DESC with `nil` LAST, then `point` ASC), where `path` is NULLABLE (a workspace mount owns no OS path), `description` is `nil | String.t()`, and `members` is DECODED from JSON TEXT (`NULL` or undecodable → `[]` with one warning per row).
`VctMounts.save/2` accepts atom- OR string-keyed entries and is the ONE ENCODING boundary for members, so a git mount round-trips to `[]` and a non-list-of-maps value raises a descriptive `ArgumentError`.
`Filters` exposes the one parameterized `clamp_limit/2` (`default:`, `max:`, `non_positive:`) behind `clamp_limit/1`, `clamp_page_limit/1`, `clamp_offset/1`, and `Archives.list/3` uses it (its clamped-to-1..N semantics are unchanged).
`Decoding.decode_skipping_bad(rows, table, id_fun, decoder)` skips and logs one undecodable row at a time; only `decoder.(row)` sits inside the rescue, so a raising query or `id_fun` propagates.
The skip warning keeps the pre-extraction spelling: `Store: skipping undecodable row in <table> (id: <id>): <message>`.

## Constraints and Audit Hazards
Despite the introductory Pages moduledoc, `get_task_lite/2` is a full-detail read, not a blob-light or inherently bounded inspection projection.
Summary/page row limits do not bound payload bytes because `opts` remains whole, potentially containing long objectives, foreign-repo metadata, media attachments, or caller-provided sensitive values.
`Filters` uses exact stored string equality for status/path/review filters, with literal `"all"` disabling each filter and `"pending"` review meaning completed plus NULL review status plus non-NULL branch name.
Search matches escaped literal substrings in `id`, raw JSON `opts`, `project_path`, and `branch_name`, never `result`, and imposes no input-length bound.
Filters expect keyword lists and correctly typed strings; they do not normalize arbitrary Assistant input or validate enum values.
`started_at DESC` has no tie-breaker.
Do not infer legacy pagination bounds or get-task-lite payload bounds from its name; the contracts above describe the actual operation returns, not evaluator-specific substitutes.
`VctMounts.list/1` raises on an absent `vct_mounts` table and relies on the facade's read offload to degrade to `[]`, which is indistinguishable from a genuinely empty table.
A `VctMounts.save/2` against an absent `vct_mounts` table raises before any statement and is not repaired or skipped by this operation.
VCT writes depend on boot migrations establishing the physical table rather than merely having corresponding migration-ledger entries; non-disk-full write failures propagate through the serialized writer according to the parent Store contract.
No Operations module reads legacy `tasks.archive_metadata` or the legacy `projects` table; their imports belong to migrations 5 and 7 before runtime writes begin.
`Tasks.put_task/2` writes only current schema fields, so an unconverted legacy `archive_metadata` value would be discarded; `VctMounts.save/2` reconciles only current mount rows and cannot import legacy projects.

## Routing Table
There are no child subdirectories.
- `tasks.ex` owns task CRUD, legacy full-row pagination, status/update-info reads, and row conversion.
- `pages.ex` owns the single-statement summary page and the full-detail lite query.
- `summaries.ex` owns canonical summary projection, summary filters, the renderable-opts predicate, the add-only `:limit`, and skip/log decoding.
- `decoding.ex` owns the shared per-row skip-and-log decode boundary used by Tasks, Safety and Summaries.
- `filters.ex` owns shared paginated WHERE clauses and the one parameterized pagination clamp.
- `lightweight.ex` owns narrow id/path/lease/cleanup reads.
- `archives.ex` owns relational per-agent archives.
- `vct_mounts.ex` owns VCT mount listing and transactional diff persistence; project recents are not a separate projects operation.
- `safety.ex` owns safe full-table reads (whole-set load then chunked loader-failure fallback) and counts.
