# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: an **SVG COMMIT-CENTRIC HORIZONTAL DAG** (GitKraken-style) — commits are nodes on a grid (one COLUMN per ancestry step, time flowing LEFT → RIGHT, the repository's base/fork node sitting one column left of the oldest commit), connected by child → parent edges, with one LANE ROW per agent (row order = the model's `{depth, id}` order) whose band spans that agent's own progress range.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView` (`commit_graph_view.ex`)

Public function component `commit_graph_view/1` (`use EvoDashWeb, :html` + `use Gettext, backend: EvoDashWeb.Gettext`).
The file is ~930 lines — a single cohesive renderer (state blocks + repo/zoom/edge/node/lane/readout sub-components + geometry/paint/total-read helpers); kept whole on purpose.
It is purely presentational: NO data assembly, NO I/O, never touches the socket.
ALL graph math (grid `x`/`y`, edges, lanes) is owned by the pure assembly module `EvoDashWeb.AgentsLive.CommitGraph` (`build/2`); this renderer owns ONLY the grid → pixel mapping, the initial viewport, and the selection marking/readout.
Selection REUSES the existing `select_agent` event (`phx-value-id`) — there is no new event handler.

Attributes (all declared with `attr/3`, UNCHANGED):

- `:repos` (`:list`, **required**) — per-repo graph views from `CommitGraph.build/2` (input contract below).
- `:selected_id` (`:any`, default `nil`) — the selected agent id; marks its START/END nodes, tints its lane, renders the readout.
- `:loading` (`:boolean`, default `false`) — a fetch is in flight.
- `:error` (`:any`, default `nil`) — last fetch failed.
- `:node_key` (`:string`, default `"local"`) — the viewed node's identity; scopes the graph wrapper so a node switch resets the DOM.

#### Input contract (per repo, FROZEN)

```elixir
%{
  repo_key, repo_dom_id: String.t(), repo_name: String.t(),
  node_count, edge_count, lane_count, row_count, max_x,
  nodes: [%{sha, short_sha, message, author_name, date, refs,
            x: integer(),          # grid COLUMN (left→right ancestry); base nodes one column left of oldest commits
            y: non_neg_integer(),  # grid ROW = owning lane index
            kind: :commit | :base,
            owner_id: term() | nil,  # owning agent's id (INTEGER in practice)
            start_ids: [term()], end_ids: [term()]}],
  edges: [%{from_sha, to_sha, from: {x, y}, to: {x, y}, kind: :parent | :merge, owner_id}],
  lanes: [%{agent_id, task_local_id, status, depth, color: String.t(),  # color = depth hue
            y: non_neg_integer(),                    # = lane index (grid row)
            x_start: integer() | nil, x_end: integer() | nil, node_count: non_neg_integer(),
            start_sha: String.t() | nil, end_sha: String.t() | nil}]
}
```

`lane_count == length(lanes)` and `row_count == lane_count`; everything is a plain map (NO structs).
`max_x` is only a WIDTH HINT — the renderer derives the true content width from the nodes/lanes so a stale hint can never clip.

#### Render tree

- `commit_graph_view/1` → `#commit-graph` root (`phx-hook="CommitGraph"`, rendered ONCE per page and PERSISTS across node switches) → `#commit-graph-body-<node_key>` (`space-y-4`) → `view_state/3` dispatch.
- `view_state/3` (private clauses): `[]` + loading → `:loading`; `[]` + not loading + no error → `:empty`; `[]` + error → `:error`; otherwise `:repos`.
- The `:repos` state renders the stale-warning strip when `@error != nil`, then one `repo_section/1` per map entry (non-map entries dropped).
- `repo_section/1` → a wrapper `div` whose `id` IS `repo.repo_dom_id` VERBATIM (the builder already emits `commit-graph-repo-<slug>-<hash>` — add NO extra prefix) → repo header (the `hero-server-stack` icon in a `bg-primary` rounded chip + `text-primary-content` glyph + the name in a bold `truncate` span with `title`) → `graph_block/1`.
- `graph_block/1` → `.cg-graph` (`data-cg-repo-id={repo_dom_id}`) → `zoom_toolbar/1` → `svg.cg-svg` → a `p.cg-empty-note` note when the repo has neither nodes nor lanes.

#### The SVG DAG

- `svg#cg-svg-<repo_dom_id>.cg-svg` carries an INITIAL `viewBox` (content bounds grown by `@vpad` on every side), `width="100%"`, an intrinsic `height` (content height clamped to `[@min_h, @max_h]`), `preserveAspectRatio="xMinYMin meet"`, `role="img"`, and an `aria-label` (gettext `"Git commit history graph"`).
- Its SOLE child is `g#cg-viewport-<repo_dom_id>.cg-viewport`, holding in DOM order (= paint order): ALL edges, then ALL nodes, then ALL lane groups, then the optional selection readout.
- PAN/ZOOM mechanism (frozen): the JS hook mutates the `<svg class="cg-svg">` `viewBox` (x, y, w, h) — NOT a group transform; `fit` recomputes it from `.cg-viewport.getBBox()`. The renderer only sets the initial viewBox + height.
- `zoom_toolbar/1` → `.cg-toolbar` with `button#cg-zoom-in-<dom>` / `#cg-zoom-out-<dom>` / `#cg-zoom-fit-<dom>` (class `.cg-zoom-btn.btn.btn-ghost.btn-xs.btn-square`, `type="button"`, `data-cg-action="zoom-in" | "zoom-out" | "fit"`, `title`/`aria-label` = gettext, hero icons `hero-magnifying-glass-plus` / `hero-magnifying-glass-minus` / `hero-arrows-pointing-out`) plus an intentionally EMPTY `span#cg-zoom-readout-<dom>.cg-zoom-readout` (`aria-live="polite"` — the hook writes the current zoom level into it).

#### Edges

- `edge_path/1` → `path#commit-edge-<dom>-<from_sha>-<to_sha>.cg-edge[data-commit-graph-anim="edge"]` with `d` = a horizontal cubic bezier (`M fx fy C cx fy, cx ty, tx ty`, control points at the horizontal midpoint) so same-row edges read straight and lane crossings sweep gently; a duplicate/zero-length edge is dropped.
- `:merge` edges are DASHED (`stroke-width="1.6"` + `stroke-dasharray="4 3"`); `:parent` edges are `stroke-width="2"`.
- Stroke = the CHILD owner's depth hue (lane looked up by `edge.owner_id`) at `stroke-opacity 0.75`; an unowned edge falls back to `var(--color-base-content)` at `0.3`.

#### Nodes

- `node_group/1` → `g#commit-node-<dom>-<sha>.cg-node[data-commit-graph-anim="node"][data-cg-agent-id={owner_id}][data-cg-sha={sha}]` with `phx-click="select_agent"` + `phx-value-id={owner_id}` (both OMITTED when `owner_id` is nil).
- Contains a native `<title>` (`base · ` prefix for base nodes, then message first line · short sha · author · date · refs; empties dropped) and a `circle.cg-node-dot` (`cx`/`cy`/`r` — r = 7 normal, r = 5 base) with inline `fill` / `fill-opacity` / `stroke`.
- Node fill: the owner lane's depth hue; a node that is its owner's END (`owner_id ∈ node.end_ids`) → `EvoDashWeb.Helpers.agent_status_svg_color(<owner lane status>)`; a base node (`kind: :base`) is HOLLOW (`fill:none`, base-content stroke); an unowned non-base node is muted `var(--color-base-content)` at `fill-opacity 0.55`.
- Selection markers (inline-styled, visible WITHOUT CSS): the START node (`selected_id ∈ node.start_ids`) → `circle.cg-selection-start` (solid `var(--color-primary)` ring, r = `node_r + 3.5`) + a `text.cg-selection-tag` BELOW it reading gettext `"start"`; the END node (`selected_id ∈ node.end_ids`) → `circle.cg-selection-end` (DASHED primary ring) + a `text.cg-selection-tag` ABOVE it reading gettext `"end"`.

#### Lanes

- `lane_group/1` → `g#commit-agent-row-<dom>-<agent_key>.cg-lane[data-commit-graph-anim="lane"][data-cg-agent-id={agent_id}]` with `phx-click="select_agent"` + `phx-value-id={agent_id}` (both OMITTED when `agent_id` is nil).
- Contains a native `<title>` (`T<id> · <status label>`) and, when its `x_start`/`x_end` are integers, a `rect#commit-lane-<dom>-<agent_key>.cg-lane-band` spanning that grid range (plus `@band_pad` each side) at the lane's row (`rx="6"`, `pointer-events="none"`, inline fill = lane depth hue at `fill-opacity 0.12`; selected → `0.2` + `var(--color-primary)` stroke).
- Also a `text#commit-lane-label-<dom>-<agent_key>.cg-lane-label.font-mono` showing `T<task_local_id || agent_id>` in the `@gutter` (132px) left gutter inside the plot, filled with the depth hue.
- Lane bands/labels are painted AFTER nodes (paint order) and the band is `pointer-events="none"` — a click meant for a node painted under it still reaches the node; the lane group itself selects on click.

#### Selection readout

- When `@selected_id` matches one of THIS repo's lanes, `selection_readout/1` renders `text#cg-selection-readout-<dom>.cg-selection-readout.font-mono` at `x = geom.ox`, `y = geom.top - 9`, filled `var(--color-primary)`: gettext `"Selected %{agent}"`, or `"Selected %{agent} · %{range}"` when start/end shas are known (`range` = `start_sha → end_sha`, short shas).
- The `@readout_h` top strip is reserved (via `top_offset/2`) ONLY while a selection of this repo exists, so the readout never overlaps the first lane row.
- Selecting also tints that lane's band (`commit-lane-band` selected styling) — selection REUSES `select_agent`; there is no new event.

#### Geometry (grid → pixels; renderer-owned)

- Layout constants: `@col_w 150`, `@row_h 46`, `@gutter 132`, `@node_r 7`, `@base_r 5`, `@band_h 18`, `@vpad 20`, `@readout_h 24`, `@min_w 320`, `@min_h 140`, `@max_h 640`, `@band_pad 12`.
- `px(x) = ox + gutter + column(x) * col_w`; `py(y) = oy + top + row(y) * row_h + row_h / 2`; `column/1` / `row/1` fold any non-integer/negative value to `0`.
- `content_w = max(@min_w, ox * 2 + gutter + max_column * col_w + node_r)`; `content_h = oy * 2 + top + row_count * row_h`; `viewBox = "0 0 <content_w> <content_h>"`; the `height` attr = `content_h` clamped to `[@min_h, @max_h]`.
- SVG numbers go through the private `n/1` (`210.0` → `"210"`, `33.33` → `"33.33"`).

### FROZEN DOM contract (the JS hook `assets/js/hooks/commit_graph.js` + CSS animation target these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">` — rendered ONCE per page, PERSISTS across node switches (the hook mounts once and is NOT re-mounted, so stable ids matter).
- Immediately inside: the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: the wrapper `div` whose id IS `repo_dom_id` VERBATIM; inside it `.cg-graph[data-cg-repo-id]` → `.cg-toolbar` (zoom buttons) → `svg.cg-svg[viewBox][width="100%"][height]` → `g.cg-viewport`.
- `data-commit-graph-anim` takes EXACTLY three values: `"edge"` (`path.cg-edge`), `"node"` (`g.cg-node`), `"lane"` (`g.cg-lane`). The animation classes (`commit-node-enter` / `commit-lane-enter`) are NEVER emitted here — the JS adds them.
- `g.cg-node` carries `data-cg-agent-id` + `data-cg-sha` + `phx-click="select_agent"` / `phx-value-id` (omitted when `owner_id` is nil).
- `g.cg-lane` carries `data-cg-agent-id` + `phx-click="select_agent"` / `phx-value-id` (omitted when `agent_id` is nil) AND the stable anchor id `#commit-agent-row-<repo_dom_id>-<agent_key>`.
- Zoom buttons carry `data-cg-action="zoom-in" | "zoom-out" | "fit"`; the sibling `.cg-zoom-readout` span is intentionally EMPTY (the hook writes into it).
- State blocks keep their ids: `#commit-graph-error`, `#commit-graph-stale-warning`.
- No `phx-update` mode anywhere; every element carries a stable, unique DOM id (suffixed with `repo_dom_id`) so LiveView's patcher (morphdom) reuses nodes.

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module.
- SVG is REQUIRED for the graph (commit nodes, edges, lane bands, selection markers); only the zoom toolbar and the state blocks stay plain HTML.
- Semantic theme tokens only for chrome (`bg-base-*`, `text-base-content/*`, `border-base-*`, `var(--color-*)` via inline `style` for SVG fills/strokes); the ONLY raw color values are the model's depth hues (`lane.color`) and `agent_status_svg_color/1`.
- Agent status colours MUST come from `EvoDashWeb.Helpers.agent_status_svg_color/1` — never re-implement the mappings (locked, test-pinned contract).
- Do NOT reference `EvoDashWeb.AgentsLive.CommitGraph.dot_r/0` / `ring_r/0` (removed) — the renderer owns its own radii (`@node_r` / `@base_r`) and grid → pixel mapping.
- All user-facing strings are `gettext`-wrapped with Chinese anchoring comments next to ambiguous labels (zoom buttons, the `start`/`end` tags, the selection readout, the empty-repo note, the `base` tooltip prefix); do not run `mix gettext.extract` / `merge` / `translate` during development.
- No `try/rescue`; every read is TOTAL (`Map.get/2` + `is_map`/list filters — non-map repo/node/edge/lane entries dropped, grid values folded to `0`, odd colors/ids fall back to base ink / `""`, `safe_string/1` stringifies any term into a DOM-safe key) so malformed data degrades instead of raising.

## Notes for Agents

- Data/model ownership: the ASSEMBLY module (`EvoDashWeb.AgentsLive.CommitGraph`) computes the DAG model (grid `x`/`y`, edges, per-lane `x_start`/`x_end` + `start_sha`/`end_sha` + `color`); this renderer only maps the grid to pixels, computes the initial viewBox/height, paints, and implements the START/END selection marking + readout.
- States handled: `:loading` (spinning `hero-arrow-path` + `"Loading commit history…"`), `:empty` (dimmed `hero-server` + `"No commit history yet."` + a hint line), `:error` (small `text-error`/`bg-error/10` strip `#commit-graph-error` — only when there is no data), and `:repos` (last-good graph KEPT when `@error != nil`, with a subtle `text-warning` `#commit-graph-stale-warning` strip above it).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree); the call site invokes it fully-qualified with `repos={@commit_graph}`, `selected_id={@selected_agent_id}`, `loading={@commit_graph_loading}`, `error={@commit_graph_error}`, `node_key={@current_node_id || "local"}`.
- The JS hook (`assets/js/hooks/commit_graph.js`) and the assembly builder are sibling workstreams — re-verify them against the FROZEN contract above before assuming the graph animates or pans.
