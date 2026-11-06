# Store Operations

## Intent
Pure Ecto operation modules implement task/project persistence and bind the store's unnamed repo PID through `RepoScope.with_repo/2`.
Codec owns wire decoding; operation query errors propagate to the facade's failure-isolated read boundary.

## API Surface
`Summaries.select_tasks_summary/3`, `select_tasks_summary_by_path/4`, and `select_tasks_changed_since/2` return lists of exactly 16-key maps: `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error`.
Summary reads omit `result`, `logs`, and `usage`, but select and decode the entire `opts` and `error` columns without projection/redaction or byte limits.
Summary filters accept status atoms (`[]` means all), optional strict raw-text `updated_at > since`, and exact project-path equality; they impose no ordering or limit and skip undecodable rows with a warning.
`Pages.select_tasks_page/2` returns `%{rows: [summary], total: integer}` ordered by `started_at DESC`, defaults limit to 25, caps positive limits at 50, clamps invalid offsets to zero, and redirects an offset at/past the end to the last page.
Pages accepts nested `:filters` plus top-level `status/project_path/review_status/search` overrides, and applies renderable-opts SQL predicates to both count and page.
`Tasks.safe_select_paginated_tasks/2` returns `{[TaskInfo], total}`, reads filters ONLY from nested `:filters`, defaults invalid/nonpositive limits to 50 but does NOT cap positive limits, and does NOT redirect out-of-range offsets.
Legacy pagination counts undecodable rows even when its per-row decoder skips them.
`Tasks.get_task/2` and `Pages.get_task_lite/2` both return full `%TaskInfo{}` or nil with `ref: nil`, including full `opts`, `logs`, `result`, `usage`, and `error`; lite selects 18 decode-relevant columns and omits only store-internal `updated_at`.
`Tasks.get_task_status/2` distinguishes missing nil from existing unreadable `{:unknown, raw}`; `select_task_update_info/2` returns `%{status, opts, finished_at, lease_expires_at}` or nil using two SELECTs.

## Constraints and Audit Hazards
Despite the introductory Pages moduledoc, `get_task_lite/2` is a full-detail read, not a blob-light or inherently bounded inspection projection.
Summary/page row limits do not bound payload bytes because `opts` remains whole, potentially containing long objectives, foreign-repo metadata, media attachments, or caller-provided sensitive values.
`Filters` uses exact stored string equality for status/path/review filters, with literal `"all"` disabling each filter and `"pending"` review meaning completed plus NULL review status plus non-NULL branch name.
Search matches escaped literal substrings in `id`, raw JSON `opts`, `project_path`, and `branch_name`, never `result`, and imposes no input-length bound.
Filters expect keyword lists and correctly typed strings; they do not normalize arbitrary Assistant input or validate enum values.
Page count and selection are separate statements without a shared snapshot, and `started_at DESC` has no tie-breaker.
Do not infer legacy pagination bounds or get-task-lite payload bounds from its name; the contracts above describe the actual operation returns, not evaluator-specific substitutes.

## Routing Table
There are no child subdirectories.
- `summaries.ex` owns canonical summary projection, summary filters, renderable-opts predicate, and skip/log decoding.
- `pages.ex` owns summary pagination and full-detail lite query.
- `filters.ex` owns shared paginated WHERE clauses and distinct legacy/page clamps.
- `tasks.ex` owns task CRUD, legacy full-row pagination, status/update-info reads, and row conversion.
- `lightweight.ex` owns narrow id/path/lease/cleanup reads.
- `archives.ex` owns relational per-agent archives.
- `projects.ex` owns project CRUD.
- `safety.ex` owns safe full-table reads and counts.
