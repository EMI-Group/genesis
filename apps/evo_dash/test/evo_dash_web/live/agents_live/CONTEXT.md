# Test Directory — AgentsLive Support Modules

## Intent

Pure unit tests for the `EvoDashWeb.AgentsLive.*` support modules (mirrors
`apps/evo_dash/lib/evo_dash_web/live/agents_live/`). Everything here is
`async: true` and free of LiveView/Phoenix/store/app-env dependencies — the
stateful AgentsLive page integration tests live in `../agents_live_test.exs`
(parent directory, owned elsewhere).

## API Surface

| File | Module | Covers |
|------|--------|--------|
| `optimistic_messages_test.exs` | `EvoDashWeb.AgentsLive.OptimisticMessagesTest` | `EvoDashWeb.AgentsLive.OptimisticMessages` — optimistic user-message append/merge/latest-turn helpers. |
| `commit_graph_test.exs` | `EvoDashWeb.AgentsLive.CommitGraphTest` (12 describes, 59 tests) | `EvoDashWeb.AgentsLive.CommitGraph` — the assembler behind the Agents page's TEMPORAL (git commit history) view, rendered as a HORIZONTAL agent swimlane (one row per agent, one column per commit, oldest left → newest right). Covers `grouping_key/1`, `repo_display_name/1` (localized: tests run in the default `:en` locale, so English msgids are asserted), and `build/2`: the `repo_view` output shape (key sets of repo/column/lane/agent/marker, each marker's `:column` indexing into `columns`), per-repo grouping + `{repo_name, repo_dom_id}` sorting, deterministic DOM-safe `repo_dom_id` (sanitized slug + `phash2` hash suffix, so same-slug keys stay distinct), the COLUMN timeline = the deduplicated UNION of every agent's first-parent progress path ordered OLDEST → NEWEST by `{rank, date_unix, sha}` (memoized topological `rank` = `1 + max` over the FETCHED parents, tie-breaks on date then sha, cycle-terminating), the first-parent walk (stops at/excludes `base_commit`, at a sha absent from the fetch, or at an already-seen sha), LANES ordered by `{depth, id}` with normalized depth and a `%{id, task_local_id, status, depth, color}` agent map, per-lane markers + `from_column`/`to_column`/`tip_column` (`tip?` only on the agent's own `current_commit`), depth → hue colors (exact hex pins), and the column/marker field rules (`short_sha` = own value else 8-char sha prefix, first-line `message`, binary-or-nil `author_name`, `%DateTime{}`-or-nil `date`, `refs` from `raw.refs`). Plus total/defensive degradation for odd inputs (absent repo key, non-map `raw_by_repo`, malformed commits/refs, unaddressable/duplicate shas, struct-shaped commits, a single agent map, a non-binary repo key, an empty agent map). All fixtures are hand-crafted agent + `%{commits, refs}` maps — no repo I/O, no LLM, no sockets. |

## Constraints

- Pure unit tests only: `use ExUnit.Case, async: true`, no `ConnCase`, no
  `EvoDash.TaskSupervisor`, no app-env seams, no global hub resets.
- Fixtures are built with file-local helpers (`agent/3`, `commit/2`,
  `chain/1`, `raw/2`) deliberately mirroring the shapes the module reads.
- Assertion styles follow the sibling convention: one-sentence explanatory
  comments above non-obvious expectations.
