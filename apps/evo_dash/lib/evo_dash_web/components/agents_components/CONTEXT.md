# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: a **VERTICAL, GitKraken/GitLen-style commit graph** — ONE ROW per commit, ordered top → bottom by agent depth, with a fixed-width left GUTTER `<svg>` overlay that draws the commit DOTS and the child → parent EDGES between the rows. Vertical scrolling is native: there is NO pan/zoom and NO viewport transform.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView` (`commit_graph_view.ex`)

Public function component `commit_graph_view/1` (`use EvoDashWeb, :html` + `use Gettext, backend: EvoDashWeb.Gettext`).
The file is ~980 lines — a single cohesive renderer (state blocks + repo/list/edge/node/row sub-components + geometry/paint/total-read helpers); kept whole on purpose.
It is purely presentational: NO data assembly, NO I/O, never touches the socket.
ALL graph modeling (`row`/`column` per node, edge endpoints, the `agents` list, the depth hues) is owned by the pure assembly module `EvoDashWeb.AgentsLive.CommitGraph` (`build/2`); this renderer owns ONLY the grid → pixel mapping (the gutter geometry constants), the row markup, the paint, and the selection marking/readout.
Selection REUSES the existing `select_agent` event (`phx-value-id`) — there is no new event handler.

Attributes (all declared with `attr/3`, UNCHANGED):

- `:repos` (`:list`, **required**) — per-repo graph views from `CommitGraph.build/2` (input contract below).
- `:selected_id` (`:any`, default `nil`) — the selected agent id; rings its START/END nodes, accents its rows, renders the readout.
- `:loading` (`:boolean`, default `false`) — a fetch is in flight.
- `:error` (`:any`, default `nil`) — last fetch failed.
- `:node_key` (`:string`, default `"local"`) — the viewed node's identity; scopes the graph wrapper so a node switch resets the DOM.

#### Input contract (per repo, FROZEN)

```elixir
%{
  repo_key, repo_dom_id: String.t(), repo_name: String.t(),
  node_count, edge_count, row_count, column_count,
  nodes: [%{sha, short_sha, message, author_name, date, refs,
            row: non_neg_integer(),     # unique top → bottom position (0 = top)
            column: non_neg_integer(),  # GUTTER COLUMN (= the owner agent's depth)
            depth: non_neg_integer(),   # the OWNER agent's normalized depth
            kind: :commit | :base,
            owner_id: term() | nil,     # owning agent's id (INTEGER in practice)
            start_ids: [term()], end_ids: [term()]}],
  edges: [%{from_sha, to_sha, from_column, from_row, to_column, to_row,
            kind: :parent | :merge, owner_id}],
  agents: [%{agent_id, task_local_id, status, depth, color: String.t(),  # color = depth hue
             start_sha: String.t() | nil, end_sha: String.t() | nil,
             ended: boolean()}]  # OPTIONAL: true = the agent has ended / been recycled (retained in-session)
}
```

`row_count == node_count` (one row per node, the rows are exactly `0 .. node_count - 1`), `column_count` is `max(column) + 1` (never below `1`), and `agents` is metadata only — the vertical model has NO per-agent row bands; everything is a plain map (NO structs).
`ended` is OPTIONAL at the renderer (read TOTALLY via `agent_ended?/1` — `Map.get(agent, :ended) == true`, any non-`true`/missing value = live agent).

#### Render tree

- `commit_graph_view/1` → `#commit-graph` root (`phx-hook="CommitGraph"`, rendered ONCE per page and PERSISTS across node switches) → `#commit-graph-body-<node_key>` (`space-y-4`) → `view_state/3` dispatch.
- `view_state/3` (private clauses): `[]` + loading → `:loading`; `[]` + not loading + no error → `:empty`; `[]` + error → `:error`; otherwise `:repos`.
- The `:repos` state renders the stale-warning strip when `@error != nil`, then one `repo_section/1` per map entry (non-map entries dropped).
- `repo_section/1` → a wrapper `div` whose `id` IS `repo.repo_dom_id` VERBATIM (the builder already emits `commit-graph-repo-<slug>-<hash>` — add NO extra prefix) and `data-cg-repo-id` → repo header (the `hero-server-stack` icon in a `bg-primary` rounded chip + the name in a bold `truncate` span with `title`) → `commit_list/1`.
- `commit_list/1` → the optional `#cg-selection-readout-<repo_dom_id>` readout line, then the relative list wrapper `#cg-list-<repo_dom_id>.cg-list.relative` holding the absolute gutter `<svg>` plus the `.cg-rows` container (left-padded by the gutter width); a repo with NO nodes renders a `p.cg-empty-note` note instead of the gutter.
- State blocks: `#commit-graph-error` (gettext "Could not load commit history.") and `#commit-graph-stale-warning` (gettext "Showing the last loaded commit graph — refresh failed.").

#### The gutter (geometry + paint)

- `svg#cg-gutter-<repo_dom_id>.cg-gutter.absolute.left-0.top-0.pointer-events-none` spans the whole list height; `width` = gutter width, `height` = `node_count * @row_h`, `viewBox` = `"0 0 <gutter_w> <total_h>"` (so 1 SVG user unit == 1 CSS pixel 1:1), `role="img"`, `aria-label` = gettext `"Git commit history graph"`.
- Its children in DOM order (= paint order) are every `path.cg-edge`, then every `g.cg-node`. The click contract deliberately lives on the ROWS — the gutter is `pointer-events: none`.
- Grid → pixels: commit at row `i` sits at `y = i * @row_h + @row_h / 2`; gutter column `c` sits at `x = @gutter_pad + c * @col_w + @col_w / 2`.
- `edge_path/1` → `path#commit-edge-<dom>-<from_sha>-<to_sha>.cg-edge[data-commit-graph-anim="edge"]` with `d` = a VERTICAL cubic bezier (`M fx fy C fx my, tx my, tx ty`, control points at the vertical midpoint between the two rows) so same-column edges read as straight lines and cross-column edges sweep gently; a zero-length edge is dropped (`:if={d}`).
- `:merge` edges are DASHED (`stroke-width="1.6"` + `stroke-dasharray="4 3"`); `:parent` edges are `stroke-width="2"`.
- Stroke = the CHILD owner's depth hue (agent looked up by `edge.owner_id`) at `stroke-opacity 0.75` (an edge owned by an ENDED agent → `0.4`); an unowned edge falls back to `var(--color-base-content)` at `0.3`.
- `node_dot/1` → `g#commit-node-<dom>-<sha>.cg-node[data-commit-graph-anim="node"][data-cg-sha][data-cg-agent-id={owner_id}]` containing a native `<title>` (`base` prefix for a base node, then message first line · short sha · author · date · refs; empties dropped) and a `circle.cg-node-dot` (`cx`/`cy`/`r` = `@base_r` for a base node else `@node_r`, `stroke-width="1.5"`, inline `fill` / `fill-opacity` / `stroke`).
- Node fill: a base node is HOLLOW (`fill: none`, base-content stroke, opacity `1`); a node that is its owner's END (`owner_id ∈ node.end_ids`) → `EvoDashWeb.Helpers.agent_status_svg_color(<owner status>)`; every other owned node → its owner agent's depth hue; an unowned non-base node → muted `var(--color-base-content)` at `fill-opacity 0.55`. A node owned by an ENDED agent keeps its hue/status color but drops to `fill-opacity 0.5`.
- Selection rings (an EXTRA `circle.cg-node-ring` child, visible without CSS): the START node (`selected_id ∈ node.start_ids`) gets a SOLID `var(--color-primary)` ring, the END node (`selected_id ∈ node.end_ids`) a DASHED one; ring radius = dot radius + 3.

#### Rows

- `commit_row/1` → `div#commit-row-<dom>-<sha>.cg-row[data-commit-graph-anim="row"][data-cg-sha][data-cg-agent-id={owner_id}]` with `style="height: 44px"` (the fixed row height the gutter aligns to) and `phx-click="select_agent"` + `phx-value-id={owner_id}` (both OMITTED when `owner_id` is nil).
- Row state classes: `cursor-pointer hover:bg-base-200/60` when owned, `bg-primary/10` when the row's owner IS the selection, `ring-1 ring-inset ring-primary/40` when the row is the SELECTED agent's start/end node, and `opacity-50` when owned by an ENDED agent.
- First line: `.cg-row-sha` (mono short sha) + either `.cg-base-label` (gettext `"base"`, for a `kind: :base` node) or `.cg-row-message` (the first line of the message, truncated), then the optional `.cg-row-marker` (gettext `"start"` / `"end"`, only for the SELECTED agent's endpoints) and the auto-right `.cg-row-meta` (`author · date`, empty for a base node).
- Second line (only when the node carries tags): AGENT chips — one `button.cg-agent-tag#commit-agent-tag-<dom>-<sha>-<start|end>-<agent_key>` per agent in `node.start_ids` (SOLID border, `start` marker) and per agent in `node.end_ids` (DASHED border, `end` marker), labelled `T<task_local_id || agent_id>` in that agent's depth hue and firing `select_agent` / `phx-value-id` — plus REF chips `span.cg-ref-tag#commit-ref-tag-<dom>-<sha>-<ref_key>` (one per `node.refs` entry, non-clickable).
- Agents that no longer exist in `agents` (odd model data) still render their chip, labelled `T<id>` in base ink.

#### Selection readout

- When `@selected_id` matches one of THIS repo's `agents`, the readout `div#cg-selection-readout-<dom>.text-primary.font-mono` renders ABOVE the list (a `hero-cursor-arrow-rays` icon + text): gettext `"Selected %{agent}"`, or `"Selected %{agent} · %{range}"` when start/end shas are known (`range` = `start_sha → end_sha`, short shas).
- Selecting also accents that agent's rows (the `bg-primary/10` / ring classes above) — selection REUSES `select_agent`; there is no new event.

### FROZEN DOM contract (the JS hook `assets/js/hooks/commit_graph.js` + CSS animation target these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">` — rendered ONCE per page, PERSISTS across node switches (the hook mounts once and is NOT re-mounted, so stable ids matter).
- Immediately inside: the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: the wrapper `div` whose id IS `repo_dom_id` VERBATIM (with `data-cg-repo-id`); inside it `#cg-list-<repo_dom_id>.cg-list.relative` → `svg#cg-gutter-<repo_dom_id>.cg-gutter` (the absolute overlay) + `.cg-rows`.
- `data-commit-graph-anim` takes EXACTLY three values: `"edge"` (`path.cg-edge`), `"node"` (`g.cg-node`), `"row"` (`div.cg-row`). The animation classes (`commit-edge-enter` / `commit-node-enter` / `commit-row-enter`) are NEVER emitted here — the JS adds them.
- Edge ids `#commit-edge-<repo_dom_id>-<from_sha>-<to_sha>`; node ids `#commit-node-<repo_dom_id>-<sha>`; row ids `#commit-row-<repo_dom_id>-<sha>`; agent chips `#commit-agent-tag-<repo_dom_id>-<sha>-<start|end>-<agent_key>`; ref chips `#commit-ref-tag-<repo_dom_id>-<sha>-<ref_key>`; readout `#cg-selection-readout-<repo_dom_id>`.
- State blocks keep their ids: `#commit-graph-error`, `#commit-graph-stale-warning`.
- No `phx-update` mode anywhere; every element carries a stable, unique DOM id (suffixed with `repo_dom_id`) so LiveView's patcher reuses nodes.

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module.
- SVG is REQUIRED for the gutter graph (commit dots, edges, selection rings); the rows, the readout and the state blocks are plain HTML.
- Semantic theme tokens only for chrome (`bg-base-*`, `text-base-content/*`, `border-base-*`, `var(--color-*)` via inline `style` for SVG fills/strokes); the ONLY raw color values are the model's depth hues (`agents[].color`) and `agent_status_svg_color/1`.
- Agent status colours MUST come from `EvoDashWeb.Helpers.agent_status_svg_color/1` — never re-implement the mappings (locked, test-pinned contract).
- Do NOT reference `EvoDashWeb.AgentsLive.CommitGraph.dot_r/0` / `ring_r/0` (removed) — the renderer owns its own radii (`@node_r` / `@base_r`) and grid → pixel mapping.
- All user-facing strings are `gettext`-wrapped with Chinese anchoring comments next to ambiguous labels (the `start`/`end` tags, the selection readout, the empty-repo note, the `base` label, the loading/empty/error states); do not run `mix gettext.extract` / `merge` / `translate` during development.
- No `try/rescue`; every read is TOTAL (`Map.get/2` + `is_map`/list filters — non-map repo/node/edge/agent entries dropped, grid values folded to `0`, odd colors/ids fall back to base ink / `""`, `safe_string/1` stringifies any term into a DOM-safe key) so malformed data degrades instead of raising.

## Notes for Agents

- Geometry constants (module attributes): `@row_h 44`, `@col_w 16`, `@gutter_pad 12`, `@node_r 6`, `@base_r 4`. Gutter width = `@gutter_pad * 2 + column_count * @col_w`; total height = `node_count * @row_h`; the `.cg-rows` container is left-padded by the gutter width so the svg and the row content never overlap.
- Data/model ownership: the ASSEMBLY module (`EvoDashWeb.AgentsLive.CommitGraph`) computes the vertical model (per-node `row`/`column`/`depth`, the edge endpoints, the `agents` list with `color`/`start_sha`/`end_sha`/`ended`); this renderer only maps the grid to pixels, paints, and implements the START/END selection marking + readout.
- States handled: `:loading` (spinning `hero-arrow-path` + `"Loading commit history…"`), `:empty` (dimmed `hero-server` + `"No commit history yet."` + a hint line), `:error` (small `text-error`/`bg-error/10` strip `#commit-graph-error` — only when there is no data), and `:repos` (last-good graph KEPT when `@error != nil`, with a subtle `text-warning` `#commit-graph-stale-warning` strip above it).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree); the call site invokes it fully-qualified with `repos={@commit_graph}`, `selected_id={@selected_agent_id}`, `loading={@commit_graph_loading}`, `error={@commit_graph_error}`, `node_key={@current_node_id || "local"}`.
- The JS hook (`assets/js/hooks/commit_graph.js`, enter animations only — no pan/zoom) and the assembly builder are sibling workstreams — re-verify them against the FROZEN contract above before assuming the graph animates.
