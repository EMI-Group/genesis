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
| `commit_graph_test.exs` | `EvoDashWeb.AgentsLive.CommitGraphTest` (15 describes, 49 tests) | `EvoDashWeb.AgentsLive.CommitGraph` — the assembler behind the Agents page's TEMPORAL (git commit history) view, rendered as a COMMIT-CENTRIC HORIZONTAL DAG (one NODE per commit, one EDGE per child → parent link, ancestry left → right oldest → newest, one horizontal LANE per agent). Covers `grouping_key/1`, `repo_display_name/1` (localized: tests run in the default `:en` locale, so English msgids are asserted), and `build/2`: the `repo_view` output shape (`Map.keys`-exact key sets for repo/node/edge/lane + counts agreeing with the lists, `row_count == lane_count`, `max_x` = widest node column), per-repo grouping + `{repo_name, repo_dom_id}` sorting, deterministic DOM-safe `repo_dom_id` (sanitized slug + `phash2` suffix, so same-slug keys stay distinct), NODES (one per ADDRESSABLE fetched commit — non-empty binary `:sha`, de-duplicated — plus one synthesized `kind: :base` node per agent `base_commit` absent from the fetch, `message: ""`/`author_name: nil`/`date: nil`/`refs: []`; a fetched commit equal to a `base_commit` stays a NORMAL `:commit` node), the `x` topological rank (memoized `1 + max` over the FETCHED parents, NOT fetch order; unfetched parents contribute nothing; base node `x = min_real_rank − 1`, `-1` when there is no real commit; a malformed parent CYCLE terminates deterministically), node metadata (`short_sha` = own value else 8-char sha prefix, first-line `message`, binary-or-nil `author_name`, `%DateTime{}`-or-nil `date`, `refs` from `raw.refs`), EDGES (`kind: :parent` for the first PRESENT parent in `:parents` order, `:merge` for every other present parent, `{x, y}` coordinates, `owner_id` = the child's owner, de-duplicated by `{from_sha, to_sha}`, absent parents produce none, a base node is a target only), node OWNERSHIP (a commit on ≥1 progress path → the deepest lane, ties on the smallest lane index; an off-path commit inherits the owner of its deepest first-parent child, else the first lane; a base node → the shallowest lane forked from it), LANES ordered `{depth, id}` with normalized depth (non-integer/nil/negative → 0), `y` = lane index, `x_start`/`x_end` over the owned nodes (nil when it owns none), `start_sha`/`end_sha` (nil for non-binary), and `node_count`; `start_ids`/`end_ids` annotations in lane order (a node can be a start for one agent and an end for another); the first-parent progress walk (stops WITHOUT collecting at a non-binary sha, the agent's own `base_commit`, an already-seen sha, or a sha absent from the fetch); depth → hue colors (exact hex pins for depths 0/1/2/3/5 via `ThemeColor.hsl_to_hex/3`); and determinism (`nodes` by `{x, y, sha}`, `edges` by `{from_sha, to_sha}`, `lanes` by `{depth, id}`, repeat builds + permuted agent input identical). Plus total/defensive degradation for odd inputs (absent repo key, non-map `raw_by_repo`, non-map / non-list / malformed `commits` and `refs`, unaddressable or duplicate shas, struct-shaped commits, a repo with no agents → NO repo views, a single agent map, a non-binary repo key, an empty agent map). All fixtures are hand-crafted agent + `%{commits, refs}` maps — no repo I/O, no LLM, no sockets. |

## Constraints

- Pure unit tests only: `use ExUnit.Case, async: true`, no `ConnCase`, no
  `EvoDash.TaskSupervisor`, no app-env seams, no global hub resets.
- Fixtures are built with file-local helpers (`agent/3`, `commit/2`,
  `chain/1`, `raw/2`) deliberately mirroring the shapes the module reads.
- Assertion styles follow the sibling convention: one-sentence explanatory
  comments above non-obvious expectations.
