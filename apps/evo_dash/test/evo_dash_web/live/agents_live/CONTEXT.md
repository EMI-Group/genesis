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
| `commit_graph_test.exs` | `EvoDashWeb.AgentsLive.CommitGraphTest` (16 describes, 57 tests) | `EvoDashWeb.AgentsLive.CommitGraph` — the assembler behind the Agents page's TEMPORAL (git commit history) view, rendered as a VERTICAL, commit-centric DAG (one ROW per commit, ordered top → bottom by agent depth, plus a left GUTTER COLUMN per node). Covers `grouping_key/1`, `repo_display_name/1` (localized: tests run in the default `:en` locale, so English msgids are asserted), and `build/2`: the `repo_view` output shape (`Map.keys`-exact key sets — repo `~w(agents column_count edge_count edges node_count nodes repo_dom_id repo_key repo_name row_count)a`; node `~w(author_name column date depth end_ids kind message owner_id refs row sha short_sha start_ids)a`; edge `~w(from_column from_row from_sha kind owner_id to_column to_row to_sha)a`; agent `~w(agent_id color depth end_sha ended start_sha status task_local_id)a` — plus counts agreeing with the lists, `row_count == node_count`, `column_count == max(node.column) + 1`) AND an explicit guard that no view/node/edge/agent carries the retired keys (`refute Map.has_key?(repo, :lanes)` / `:lane_count` / `:max_x`, `refute Map.has_key?(node, :x)` / `:y`, `refute Map.has_key?(edge, :from)` / `:to`); per-repo grouping + `{repo_name, repo_dom_id}` sorting, deterministic DOM-safe `repo_dom_id` (sanitized slug + `phash2` suffix, so same-slug keys stay distinct), NODES (one per ADDRESSABLE fetched commit — non-empty binary `:sha`, de-duplicated — plus one synthesized `kind: :base` node per agent `base_commit` absent from the fetch, `message: ""`/`author_name: nil`/`date: nil`/`refs: []`; a fetched commit equal to a `base_commit` stays a NORMAL `:commit` node), node metadata (`short_sha` = own value else 8-char sha prefix, first-line `message`, binary-or-nil `author_name`, `%DateTime{}`-or-nil `date`, `refs` from `raw.refs`), ROWS (rows are exactly `0 .. node_count - 1`, each UNIQUE; grouped contiguously per owner in `{depth, task_local_id, agent_id}` order), GUTTER COLUMNS (`column == depth` → a staircase, `column_count` counts the gutter: a depth-5 owner yields a `6`-wide gutter, `1` when the repo has no nodes), EDGES (`kind: :parent` for the first PRESENT parent in `:parents` order, `:merge` for every other present parent, `{from_column, from_row}` → `{to_column, to_row}` endpoints, `owner_id` = the child's owner, de-duplicated by `{from_sha, to_sha}`, absent parents produce none, a base node is a target only), node OWNERSHIP (a commit on ≥1 progress path → the deepest owner, ties on the smallest agent-order index; an off-path commit inherits the owner of its deepest first-parent child, else the first agent; a base node → the shallowest owner forked from it), the `agents` list ordered `{depth, task_local_id, agent_id}` with normalized depth (non-integer/nil/negative → 0), `color` (the depth hue), `start_sha`/`end_sha` (nil for non-binary), and `ended` (true ONLY for an agent whose map carries `:ended == true` — a retained/ended agent, else false); `start_ids`/`end_ids` annotations in agent order (a node can be a start for one agent and an end for another); the first-parent progress walk (stops WITHOUT collecting at a non-binary sha, the agent's own `base_commit`, an already-seen sha, or a sha absent from the fetch); depth → hue colors (exact hex pins for depths 0/1/2/3/5 via `ThemeColor.hsl_to_hex/3`); and determinism (nodes by ascending `row`, edges by `{from_sha, to_sha}`, `agents` by `{depth, task_local_id, agent_id}`, repeat builds + permuted agent input identical). Plus total/defensive degradation for odd inputs (absent repo key, non-map `raw_by_repo`, non-map / non-list / malformed `commits` and `refs`, unaddressable or duplicate shas, struct-shaped commits, a repo with no agents → NO repo views, a single agent map, a non-binary repo key, an empty agent map). All fixtures are hand-crafted agent + `%{commits, refs}` maps — no repo I/O, no LLM, no sockets. |

## Constraints

- Pure unit tests only: `use ExUnit.Case, async: true`, no `ConnCase`, no
  `EvoDash.TaskSupervisor`, no app-env seams, no global hub resets.
- Fixtures are built with file-local helpers (`agent/3`, `commit/2`,
  `chain/1`, `raw/2`) deliberately mirroring the shapes the module reads.
- Assertion styles follow the sibling convention: one-sentence explanatory
  comments above non-obvious expectations.
- `commit_graph_test.exs` is ~1311 lines — a legitimately long suite (one
  `describe` per model rule group plus an explicit totality matrix); don't split
  casually.
