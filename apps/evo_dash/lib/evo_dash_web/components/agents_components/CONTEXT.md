# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: a **VERTICAL, GitLens/GitKraken-style PER-AGENT-LANE agent-DAG** — ONE ROW per VISIBLE node (globally interleaved, top → bottom), where a visible node is a commit, a `:base`/`:noop` stub or ONE synthesized `:gap` row standing for a folded run, ONE LANE PER AGENT in the left gutter, CIRCULAR dots, ROUNDED cross-lane edge routing (no sharp 90° bends), DASHED `:spawn` / `:merge_back` connectors, sticky per-lane header chips and a horizontally-scrolling gutter.
The view is COLLAPSED BY DEFAULT: each lane keeps only its structural ANCHORS (the lane owner's START and END, any node named in any `start_ids`/`end_ids`, every node carrying `refs`, every stub, every unowned node), and each maximal run of hidden interior commits on ONE lane renders as one compact dashed `… N commits` row plus a hollow gutter dot, toggled per run through `toggle_commit_fold`; the repo header shows `Expand all` / `Collapse all` while `fold_count > 0`.
The list scrolls vertically INSIDE the panel: `.cg-scroll` is the ONE BOTH-axis scroller (so the lane header genuinely pins above the rows), keeping the `min(26rem, 60vh)` base cap below xl and the `min(38rem, 70vh)` cap everywhere except xl+ commits mode, where `.agents-tree-body-commits` drops it so the box fills the panel's remaining height; there is NO pan/zoom and NO viewport transform.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView.Geometry` (`commit_graph/geometry.ex`)

The PURE geometry/routing/lane-planning half of the renderer — every geometry CONSTANT and ALL coordinate math; the HEEx half only consumes the results. No HEEx, no socket, no I/O; every model read is TOTAL (non-integer grid values fold to `0`).

- Constants + accessors: `@row_h 44`, `@col_w 24` (LANE width), `@gutter_pad 12`, `@node_r 6`, `@base_r 4` (hollow stub radius — shared by `:base`, `:noop` AND the `:gap` fold marker), `@bend_r 7` (rounded-corner radius, also the same-row shelf depth), `@exit_gap 2` (clearance an agent-level connector keeps below its source dot), `@jog_clear 8` (clearance a STAGGERED jog keeps from span ends, interior row dots, and other placed jogs), `@chip_row_h 18` (one staggered lane-header chip row) — `row_h/0`, `col_w/0`, `gutter_pad/0`, `node_r/0`, `base_r/0`, `bend_r/0`, `chip_row_h/0`.
- `geom/4` — `%{col_count, gutter_w (24 + cols*24), total_h}`; `total_h` covers node rows AND edge landing rows (a geometry-only allowance: an edge whose endpoint resolves below the last node — a `to_sha: nil` shape the builder never emits); `col_count` = `max(from nodes, from agent lanes, model hint)` never below 1 (a lane with no nodes still needs its column).
- `dot_x/1` / `dot_y/1` / `positions/1` — lane/row center px (positions keyed by sha, `row` = the node's rendered index).
- `edge_kind/1` — recognizes `:merge` / `:spawn` / `:merge_back`, everything else folds to `:parent`; `agent_level?/1` — `kind in [:spawn, :merge_back]`.
- `edge_geo/2` — `%{kind, from, to, d}` with endpoint resolution NODE-first (a rendered node's position wins), falling back to the edge's own `{column, row}` (only for a `to_sha: nil` shape, which the builder never emits — defensive tolerance, not a produced landing); agent-level connectors depart BELOW the source dot (`y + node_r + exit_gap`). `d` is `nil` when the endpoints collapse (the renderer drops the edge). Always routes the CANONICAL midpoint jog — a single edge between a lane pair is pixel-identical under `edge_geo/2` and `edge_geo/3`.
- `edge_geo/3` (batch-aware) — same resolution + `%{kind, from, to, d}` shape, but CONCURRENT cross-lane edges sharing the same UNORDERED lane pair (multiple `:spawn`s from one fork; a `:spawn` overlapping its `:merge_back`) are STAGGERED so the group never collapses onto identical pixels. Grouping uses RESOLVED endpoint columns (node-first); the pair's FIRST edge (in the edge list's stable order) keeps the canonical midpoint route; every later edge walks its jog y outward from its own span midpoint in `@jog_clear` steps (below the midpoint first, then above), staying inside the from/to span (`@jog_clear` clear of both ends), `@jog_clear` clear of every interior row's dot center and of every jog the group already placed (each member's placement is REPLAYED deterministically, so every member computes the same layout no matter which one asks). A span with no room left clamps back to the canonical midpoint route. Same-lane and horizontal edges are never staggered; a non-list `edges` arg folds to the canonical route.
- `route/5` (private, `jog_y` defaults nil → midpoint) — collapsed endpoints → `nil` (the renderer drops the edge); a SAME-lane edge (`from_column == to_column`) is a straight vertical `M..L..`; a SAME-ROW cross-lane edge (`from_row == to_row`) routes a small ROUNDED SHELF (`same_row_route/3`) — down out of the source dot, across at `@bend_r * 2` BELOW the row (deterministic, never flipping), back up into the target dot — because a straight dot-to-dot line would draw a bare horizontal stub THROUGH every dot between the two lanes on that row; every other cross-lane edge is orthogonal with TWO quadratic (`Q`) quarter-turn corners of clamped radius (`< 0.5` → straight line) — a sharp `L x y L x y` double-corner is never emitted. A staggered `jog_y` is re-clamped into `[span_min + r, span_max − r]` (degenerate range → midpoint), so the rounded corners always stay well-formed.
- `lane_chips/2` — the per-lane header plan ordered by lane index: one entry per AGENT lane (from `agents[].lane`, incl. node-less lanes) plus the NEUTRAL lane 0 (`agent: nil`) only when no agent claims lane 0 AND unowned nodes exist; each chip carries `x` (the lane's dot-x anchor) and `chip_row` (`lane mod 2` — the two-row stagger).

### `EvoDashWeb.AgentsComponents.CommitGraphView.Fold` (`commit_graph/fold.ex`)

The folded-run half of the renderer: the compact dashed GAP ROW, the hollow gap GUTTER MARKER, the per-repo Expand all / Collapse all controls, and the row/tooltip helper cluster (`row_tags/1`, `node_title/1`, `meta_text/1`, `first_line/1`, `short_sha/1`, `ref_list/1`, `author/1`, `commit_date/1`, `agent_index/1`, `agent_for/2`, `agent_color/2`, `agent_color_of/1`, `agent_status/1`, `agent_ended?/1`, `agent_label/2`, `safe_string/1`, `dom_key/1`).
`commit_graph_view.ex` aliases it as `Fold` and calls it fully-qualified for every one of those helpers, keeping the renderer under the per-file size baseline.

- `gap?/1` — `%{kind: :gap}` ONLY (a gap node is never a `:base`/`:noop` stub and never gets start/end markers, agent tags or ref tags).
- `hidden_count/1` (positive integer, total read), `fold_key/1`, `expanded?/1` (`Map.get(node, :expanded) == true`), `fold_count/1` (repo-level count, absent/non-integer → `0`).
- `gap_row/1` (attrs `:dom`, `:node`) → the row; `gap_node/1` (attrs `:dom`, `:node`, `:positions`) → the gutter marker; `fold_controls/1` (attr `:dom`, `:fold_count`) → the header buttons; `row_tags/1` (attrs `:dom`, `:node`, `:agents_index`, `:start_ids`, `:end_ids`) → the agent/ref chip line.

### `EvoDashWeb.AgentsComponents.CommitGraphView` (`commit_graph_view.ex`)

Public function component `commit_graph_view/1` (`use EvoDashWeb, :html` + `use Gettext, backend: EvoDashWeb.Gettext`), aliasing its `Geometry` submodule.
The HEEx half: state blocks + repo/scroll/lane-header/list/edge/node/row sub-components + paint/lookup/total-read helpers. Purely presentational: NO data assembly, NO I/O, never touches the socket.
Selection REUSES the existing `select_agent` event (`phx-value-id`) from the rows, the agent tags AND the lane chips — there is no new event handler.

Attributes (all declared with `attr/3`, UNCHANGED):

- `:repos` (`:list`, **required**) — per-repo graph views (input contract below).
- `:selected_id` (`:any`, default `nil`) — the selected agent id; rings its START/END nodes, accents its rows, renders the readout.
- `:loading` (`:boolean`, default `false`) — a fetch is in flight.
- `:error` (`:any`, default `nil`) — last fetch failed.
- `:node_key` (`:string`, default `"local"`) — the viewed node's identity; scopes the graph wrapper so a node switch resets the DOM.

#### Input contract (per repo — the v2 per-agent-LANE model)

```elixir
%{
  repo_key, repo_dom_id: String.t(), repo_name: String.t(),
  node_count, edge_count, row_count, column_count,
  truncated: boolean(),      # OPTIONAL: true = a tip range was cut at the
                             # 100-commit limit (read TOTALLY, default false)
  nodes: [%{sha, short_sha, message, author_name, date, refs,
            row: non_neg_integer(),     # globally interleaved 0..n-1 (NOT per-agent)
            column: non_neg_integer(),  # the LANE index (one lane per agent; 0 = neutral)
            depth: non_neg_integer(),
            kind: :commit | :base | :noop | :gap,  # :noop = no-op-child stub; :gap = a folded
                                                  # run of hidden intermediate commits
            owner_id: term() | nil,     # owning agent's id (INTEGER in practice)
            start_ids: [term()], end_ids: [term()]}],
  edges: [%{from_sha, to_sha, from_column, from_row, to_column, to_row,
            kind: :parent | :merge | :spawn | :merge_back, owner_id}],
  agents: [%{agent_id, task_local_id, status, depth, color: String.t(),  # color = depth hue
             start_sha: String.t() | nil, end_sha: String.t() | nil,
             ended: boolean(),       # OPTIONAL: true = ended / recycled (retained in-session)
             lane: non_neg_integer(),  # the agent's lane index
             parent_id: term() | nil}]
}
```

- Lane 0 is the neutral "pre-task" lane, present only when unowned nodes exist; `column_count` covers all agent lanes.
- An agent lane may carry NO nodes (the agent exists — its lane still gets a header chip and a gutter column).
- Edge `:parent`/`:merge` are commit→parent (from = child), with every endpoint ALIASED to its run's gap sha when the original node folded into a gap; the agent-level `:spawn`/`:merge_back` join LANES — `:spawn` from the FORK node (parent's lane) to the child's oldest commit, `:merge_back` from the child's TIP (or `:noop` stub) to the topmost parent-owned node strictly BELOW it, else the nearest one ABOVE, else NO edge at all. The builder never emits `to_sha: nil`; the renderer's geometry still tolerates that shape defensively (the path would end at the edge's own `to_column`/`to_row`). `owner_id` on agent-level edges = the CHILD agent (stroke color).
- `truncated` is OPTIONAL (read TOTALLY — `Map.get(repo, :truncated) == true`; absent/false/nil = no strip): when `true` the dimmed `#cg-truncated-<repo_dom_id>` strip renders at the BOTTOM of that repo's list (gettext "Older commits are not shown (limit 100)", Chinese comment 更早的提交未显示——超出条数上限).
- Everything is a plain map (NO structs); `ended` is OPTIONAL (read TOTALLY — any non-`true`/missing value = live agent).

#### Render tree

- `commit_graph_view/1` → `#commit-graph` root (`phx-hook="CommitGraph"`, rendered ONCE per page and PERSISTS across node switches) → `#commit-graph-body-<node_key>` (`space-y-4`) → `view_state/3` dispatch.
- `view_state/3` (private clauses): `[]` + loading → `:loading`; `[]` + not loading + no error → `:empty`; `[]` + error → `:error`; otherwise `:repos`.
- The `:repos` state renders the stale-warning strip when `@error != nil`, then one `repo_section/1` per map entry (non-map entries dropped).
- `repo_section/1` → a wrapper `div` whose `id` IS `repo.repo_dom_id` VERBATIM (the builder already emits `commit-graph-repo-<slug>-<hash>` — add NO extra prefix) and `data-cg-repo-id` → repo header (the `hero-server-stack` icon in a non-shrinking `size-7 bg-primary` rounded chip + the name in a `text-sm font-semibold truncate` span with `title`) → `commit_list/1`.
- `commit_list/1` → the optional `#cg-selection-readout-<repo_dom_id>` readout line, then the scroll wrapper `#cg-scroll-<repo_dom_id>.cg-scroll` (the `.cg-scroll` rule in app.css owns `overflow: auto` on BOTH axes; its height cap — `min(26rem, 60vh)` on mobile, `min(38rem, 70vh)` at xl+ — still applies below xl and outside commits mode, while `.agents-tree-body-commits .cg-scroll` drops it at xl+ (`flex: 1 1 auto; min-height: 0; max-height: none`) to fill the panel's remaining height) hosting (top → bottom) the sticky `lane_header/1` bar and the relative list wrapper `#cg-list-<repo_dom_id>.cg-list.relative` (gutter svg + rows), then — when the repo model flags `truncated: true` — the dimmed truncation strip `#cg-truncated-<repo_dom_id>` (a `hero-information-circle` icon + gettext "Older commits are not shown (limit 100)") at the BOTTOM of the list, INSIDE the scroll wrapper, after the rows; a repo with NO nodes renders a `p.cg-empty-note` note inside the scroll wrapper instead (never both).
- State blocks: `#commit-graph-error` (gettext "Could not load commit history.") and `#commit-graph-stale-warning` (gettext "Showing the last loaded commit graph — refresh failed.").

#### Lane header (sticky per-lane chips)

- `lane_header/1` → `#cg-lane-header-<dom>.cg-lane-header.sticky.top-0.z-10` (inline `width` = gutter width, `bg-base-100/95 backdrop-blur-sm`) ABOVE the gutter SVG, INSIDE the scroll wrapper (so it scrolls in sync horizontally) — and it GENUINELY STICKS: `.cg-scroll` is a real BOTH-axis scroller (capped below xl and outside commits mode, panel-filling at xl+ in commits mode), so the sticky resolves against IT and the chips pin above the rows while the list scrolls.
- Chips are staggered over TWO 18px rows (`chip_row = lane mod 2` — even lanes on top, odd lanes below; same-row neighbours are 48px apart and never collide). One chip per lane plan entry:
  - Agent lane: `button#cg-lane-<dom>-<lane>.cg-lane-chip` — `phx-click="select_agent"` + `phx-value-id={agent_id}`, labelled `T<task_local_id>` in the agent's depth hue (border + text), a small status DOT colored via `Helpers.agent_status_svg_color/1`, a `title` of `T<n> · <status> [· terminated]`, and `opacity: 0.5` when `ended: true`. Rendered even when the lane owns NO nodes.
  - Neutral lane 0 (only when unowned nodes exist and no agent claims lane 0): NON-clickable `span#cg-lane-<dom>-0.cg-lane-chip.cg-lane-chip-neutral` labelled gettext "Pre-task" (Chinese comment: 任务开始前的"前置提交"泳道).
- Each chip is absolutely positioned at its lane's dot-x and CENTERED on it via inline `transform: translateX(-50%)` (content-sized width).

#### The gutter (geometry + paint)

- `svg#cg-gutter-<repo_dom_id>.cg-gutter.absolute.left-0.top-0.pointer-events-none` spans the whole list height; `width` = gutter width (`24 + column_count * 24`), `height` = rows × `@row_h` (extended for an edge endpoint resolved below the last node — a defensive shape the builder never emits), `viewBox` matched (so 1 SVG user unit == 1 CSS pixel 1:1), `role="img"`, `aria-label` = gettext `"Git commit history graph"`.
- Its children in DOM order (= paint order) are every `path.cg-edge`, then every `g.cg-node`. The click contract deliberately lives on the ROWS — the svg itself is `pointer-events: none`, but each node's inner `circle.cg-node-dot` RE-ENABLES pointer events (`.cg-node-dot` rule in app.css): the gutter never overlaps row content, so row clicks stay authoritative, while the dot is hoverable (the row ↔ dot sync) and its native `<title>` tooltip becomes reachable.
- Grid → pixels: lane `c`'s dot center at `x = 24 + c * 24`; row `r`'s at `y = r * 44 + 22`.
- `edge_path/1` → `path.cg-edge[data-commit-graph-anim="edge"]` (a zero-length/collapsed edge is dropped via `:if`):
  - Routing (the BATCH-AWARE `Geometry.edge_geo/3`, fed the repo's FULL edge list): a same-lane edge renders as a plain straight vertical `M x y1 L x y2` (no bends); a cross-lane edge routes orthogonally with BOTH corners rounded by quadratic `Q` quarter-turns (radius `@bend_r 7`, clamped to half the span) — the sharp `L x y L x y L x y` double-corner signature is never emitted. Concurrent cross-lane edges sharing the same UNORDERED lane pair are STAGGERED off the shared midpoint jog (deterministic from the edge list's stable order; the pair's FIRST edge — and therefore a LONE edge — stays pixel-identical to the canonical `edge_geo/2` route). A `:spawn` departs BELOW its fork dot (`fork_cy + node_r + exit_gap`); a `:merge_back` mirrors that from the child tip; a `to_sha: nil` endpoint (a shape the builder never emits) is tolerated by simply ENDING the path at the edge's own `to_column`/`to_row` coordinates (no marker circle). A same-row cross-lane pair (`fy == ty`, `fx != tx`) routes a rounded SHELF below the row with quadratic corners — never a bare `M fx fy L tx fy` horizontal stub.
  - Stroke styles: `:parent` SOLID `stroke-width="2"`; `:merge`, `:spawn`, `:merge_back` DASHED `stroke-dasharray="4 3"` + `stroke-width="1.6"`.
  - Stroke color = the owner agent's depth hue (for agent-level kinds the CHILD agent) at `stroke-opacity 0.75` (an ENDED owner → `0.4`); an unowned edge falls back to `var(--color-base-content)` at `0.3`.
  - Edge IDS: commit→parent kinds keep `#commit-edge-<dom>-<from_sha>-<to_sha>`; the agent-level kinds use `#commit-edge-<dom>-<kind>-<owner_key>-<from_key>-<to_key>` (kind literal `spawn`/`merge_back`, sanitized terms; `to_key` = `"l<col>r<row>"` when `to_sha` is nil) — avoids nil-sha collisions.
- `node_dot/1` → `g#commit-node-<dom>-<sha>.cg-node[data-commit-graph-anim="node"][data-cg-sha][data-cg-agent-id={owner_id}]` containing a native `<title>` (stub prefix `base`/`no-op`, then message first line · short sha · author · date · refs; empties dropped) and a `circle.cg-node-dot` — a CIRCLE centred on the grid point (`cx`/`cy`, `r = @node_r 6` for commits); a `:base`/`:noop` node is a smaller HOLLOW circle (`r = @base_r 4`, `fill: none`, base-content stroke). `stroke-width="1.5"`, inline `fill`/`fill-opacity`/`stroke`.
- Node fill: a stub node is HOLLOW; a node that is its owner's END (`owner_id ∈ node.end_ids`) → `EvoDashWeb.Helpers.agent_status_svg_color(<owner status>)`; every other owned node → its owner agent's depth hue; an unowned non-stub node → muted `var(--color-base-content)` at `fill-opacity 0.55`. A node owned by an ENDED agent keeps its hue/status color but drops to `fill-opacity 0.5`.
- Selection rings (an EXTRA `circle.cg-node-ring` child, visible without CSS): the START node (`selected_id ∈ node.start_ids`) gets a SOLID `var(--color-primary)` ring, the END node (`selected_id ∈ node.end_ids`) a DASHED one (`stroke-dasharray "3 2"`); the ring's `r` = the dot's `r + 3` (commits 9, stubs 7).

#### Rows

- `commit_row/1` → `div#commit-row-<dom>-<sha>.cg-row[data-commit-graph-anim="row"][data-cg-sha][data-cg-agent-id={owner_id}]` with `style="height: 44px"` (the fixed row height the gutter aligns to), a native `title` (the SAME `node_title/1` content the gutter node's `<title>` carries — the svg tooltip is unreachable under `pointer-events: none`) and — for OWNED nodes — the `select_agent` click contract (`phx-click` + `phx-value-id={owner_id}`) plus `role="button"` + `tabindex="0"` (Enter / Space activation via the `CommitGraph` hook, pushing the SAME event; all four omitted when `owner_id` is nil).
- Row state classes: `cursor-pointer hover:bg-base-200/60` when owned, `bg-primary/10` when the row's owner IS the selection, `ring-1 ring-inset ring-primary/40` when the row is the SELECTED agent's start/end node, and `opacity-50` when owned by an ENDED agent. The hook additionally toggles `cg-hovered` on a row / its gutter dot when either is hovered (see "Interaction layer" below).
- First line: `.cg-row-sha` (mono short sha) + either `.cg-base-label` (gettext `"base"` for `kind: :base`, gettext `"no-op"` for `kind: :noop`) or `.cg-row-message` (the first line of the message, truncated), then the optional `.cg-row-marker` (gettext `"start"` / `"end"`, only for the SELECTED agent's endpoints) and the auto-right `.cg-row-meta` (`author · date`, empty for a stub node).
- Second line (only when the node carries tags): AGENT chips — one `button.cg-agent-tag#commit-agent-tag-<dom>-<sha>-<start|end>-<agent_key>` per agent in `node.start_ids` (SOLID border, `start` marker) and per agent in `node.end_ids` (DASHED border, `end` marker), labelled `T<task_local_id || agent_id>` in that agent's depth hue and firing `select_agent` / `phx-value-id` — plus REF chips `span.cg-ref-tag#commit-ref-tag-<dom>-<sha>-<ref_key>` (one per `node.refs` entry, non-clickable).
- Agents that no longer exist in `agents` (odd model data) still render their chip, labelled `T<id>` in base ink.

#### Selection readout

- When `@selected_id` matches one of THIS repo's `agents`, the readout `div#cg-selection-readout-<dom>.text-primary-standalone.font-mono` renders ABOVE the scroll wrapper (a `hero-cursor-arrow-rays` icon + text): gettext `"Selected %{agent}"`, or `"Selected %{agent} · %{range}"` when start/end shas are known (`range` = `start_sha → end_sha`, short shas).
- Selecting also accents that agent's rows (the `bg-primary/10` / ring classes above) — selection REUSES `select_agent`; there is no new event.

### FROZEN DOM contract (the JS hook `assets/js/hooks/commit_graph.js` + CSS animation target these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">` — rendered ONCE per page, PERSISTS across node switches (the hook mounts once and is NOT re-mounted, so stable ids matter). ADDITIVE (v2 of the contract): the root also carries `data-cg-selected-id` — the raw `@selected_id` term, stringified by LiveView EXACTLY like the rows' `data-cg-agent-id` (so the hook can string-compare them); it drives the hook's scroll-to-selection.
- Immediately inside: the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: the wrapper `div` whose id IS `repo_dom_id` VERBATIM (with `data-cg-repo-id`); inside it `#cg-scroll-<repo_dom_id>.cg-scroll` (the ONE BOTH-axis scroller — `overflow: auto` and both the capped and the panel-filling `max-height` variants live in the `.cg-scroll` rules in app.css, NOT in Tailwind classes on the element) → `#cg-lane-header-<repo_dom_id>.cg-lane-header` + `#cg-list-<repo_dom_id>.cg-list.relative` → `svg#cg-gutter-<repo_dom_id>.cg-gutter` (the absolute overlay) + `.cg-rows` (left-padded by the gutter width, moving with the gutter in the horizontal scroll).
- `data-commit-graph-anim` takes EXACTLY three values: `"edge"` (`path.cg-edge`, ALL kinds including `:spawn`/`:merge_back`), `"node"` (`g.cg-node`), `"row"` (`div.cg-row`). The animation classes (`commit-edge-enter` / `commit-node-enter` / `commit-row-enter`) are NEVER emitted here — the JS adds them. Lane chips carry NO animation.
- Edge ids: commit→parent `#commit-edge-<repo_dom_id>-<from_sha>-<to_sha>`; agent-level `#commit-edge-<repo_dom_id>-<kind>-<owner_key>-<from_key>-<to_key>` (`to_key` = `l<col>r<row>` for a `to_sha: nil` endpoint the builder never emits). Node ids `#commit-node-<repo_dom_id>-<sha>`; row ids `#commit-row-<repo_dom_id>-<sha>`; lane chips `#cg-lane-<repo_dom_id>-<lane>`; agent chips `#commit-agent-tag-<repo_dom_id>-<sha>-<start|end>-<agent_key>`; ref chips `#commit-ref-tag-<repo_dom_id>-<sha>-<ref_key>`; readout `#cg-selection-readout-<repo_dom_id>`.
- State blocks keep their ids: `#commit-graph-error`, `#commit-graph-stale-warning`.
- ADDITIVE: the optional truncation strip `#cg-truncated-<repo_dom_id>` (rendered only when the repo model flags `truncated: true`) sits at the BOTTOM of that repo's list, INSIDE the `#cg-scroll-<repo_dom_id>` wrapper, after the rows.
- ADDITIVE (folded runs): the repo wrapper additionally carries the class `cg-repo` (id stays `repo_dom_id` verbatim, `data-cg-repo-id` unchanged).
  A `kind: :gap` node renders BOTH halves inside `#cg-scroll-<repo_dom_id>`: the row `div#commit-gap-row-<repo_dom_id>-<fold_key_sanitized>.cg-row.cg-gap-row` (`data-commit-graph-anim="row"`, `data-cg-sha`, `data-cg-agent-id`, `data-cg-fold-key` = the RAW `fold_key` model string, omitted when the model has no binary key so the hook's delegated Enter/Space activation can toggle that run instead of selecting the agent, inline `height` = `Geometry.row_h()`, `phx-click="toggle_commit_fold"`, `phx-value-fold-key`, `role="button"`, `tabindex="0"`) and the gutter marker `g#commit-node-<repo_dom_id>-<gap sha>.cg-node.cg-gap-node` (`data-commit-graph-anim="node"`, a small HOLLOW dashed dot at `Geometry.base_r()`, a `<title>` of the hidden count, no selection ring, no tags).
  The row shows a chevron (`hero-chevron-down` collapsed / `hero-chevron-up` expanded) and a dashed-border muted `gettext("%{count} commits")` label; the fold key is the per-run identity, so an expanded run keeps its gap row as its own collapse control.
  Per-repo controls render in the repo HEADER row only when `Fold.fold_count(repo) > 0`: `button#cg-fold-<repo_dom_id>-expand-all` (`phx-click="expand_all_commit_folds"`, gettext "Expand all") and `button#cg-fold-<repo_dom_id>-collapse-all` (`phx-click="collapse_all_commit_folds"`, gettext "Collapse all"), `btn btn-ghost btn-xs`, semantic tokens only.
  The `CommitGraph` hook's existing Enter/Space activation pushes `select_agent` from the gap row's `data-cg-agent-id` — accepted, no new JS.
- No `phx-update` mode anywhere; every element carries a stable, unique DOM id (suffixed with `repo_dom_id`) so LiveView's patcher reuses nodes.

#### Interaction layer (hook-owned classes — additive, documented)

The `CommitGraph` hook (see `assets/js/hooks/commit_graph.js`) owns three behaviours on top of the enter animations; all are pure client-side (no new server events — keyboard activation pushes the SAME `select_agent`):

- **Row ↔ dot hover sync** — delegated `mouseover`/`mouseout` on the root, keyed by `data-cg-sha` (rows AND nodes carry it); toggles `cg-hovered` on the matching `.cg-row` div and `g.cg-node`. Styled by app.css: `.cg-row.cg-hovered` mirrors the Tailwind `hover:bg-base-200/60` tint; `.cg-node.cg-hovered .cg-node-dot` scales up (colour-free — the renderer's depth hues stay untouched). Only `circle.cg-node-dot` is pointer-active in the gutter.
- **Keyboard activation** — owned rows render `role="button" tabindex="0"`; the hook's delegated `keydown` pushes `select_agent` with the row's `data-cg-agent-id` on Enter / Space (Space prevented, so it does not scroll; a nested interactive child owns its own keys).
- **Scroll-to-selection** — `updated()` compares the root's `data-cg-selected-id` against the last-seen id; on an actual CHANGE it scrolls the selected agent's TOPMOST row into view inside its `.cg-scroll` (clear of the sticky lane header) and reveals its lane dot horizontally when the gutter is clipped. User scrolling is never fought (only real changes scroll).

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module. The renderer aliases `EvoDashWeb.AgentsComponents.CommitGraphView.Geometry` for ALL geometry/routing/lane planning.
- SVG is REQUIRED for the gutter graph (circular commit dots, rounded edges, selection rings); the rows, the lane header, the readout and the state blocks are plain HTML.
- Semantic theme tokens only for chrome (`bg-base-*`, `text-base-content/*`, `border-base-*`, `var(--color-*)` via inline `style` for SVG fills/strokes); the ONLY raw color values are the model's depth hues (`agents[].color`) and `agent_status_svg_color/1`.
- Agent status colours MUST come from `EvoDashWeb.Helpers.agent_status_svg_color/1` — never re-implement the mappings (locked, test-pinned contract). The lane chip status dot reuses the same mapping.
- Do NOT reference `EvoDashWeb.AgentsLive.CommitGraph.dot_r/0` / `ring_r/0` (removed) — the renderer owns its own radii (`@node_r` / `@base_r` via `Geometry`) and grid → pixel mapping.
- All user-facing strings are `gettext`-wrapped with Chinese anchoring comments next to ambiguous labels (the `start`/`end` tags, the selection readout, the empty-repo note, the `base`/`no-op` labels, the "Pre-task" neutral-lane chip, the loading/empty/error states); do not run `mix gettext.extract` / `merge` / `translate` during development.
- No `try/rescue`; every read is TOTAL (`Map.get/2` + `is_map`/list filters — non-map repo/node/edge/agent entries dropped, grid values folded to `0`, odd colors/ids fall back to base ink / `""`, `safe_string/1` stringifies any term into a DOM-safe key) so malformed data degrades instead of raising.
- Horizontal scrolling MUST go through the single `#cg-scroll-<dom>` wrapper (gutter + rows + lane headers scroll as ONE unit); VERTICAL scrolling lives in the SAME wrapper, which is the ONE vertical scroller the lane header's `sticky top-0` resolves against (a real scroller, never the page). Its height caps — `min(26rem, 60vh)` mobile, `min(38rem, 70vh)` at xl+ — still apply below xl and outside commits mode; at xl+ in commits mode `.agents-tree-body-commits .cg-scroll` is `flex: 1 1 auto; min-height: 0; max-height: none`, filling the panel's remaining height through the flex chain card body → `#commit-graph` → `#commit-graph-body-<node_key>` → `.cg-repo` (each link a flex column with `min-height: 0`). Do NOT reintroduce a Tailwind `overflow-*` utility on the `#cg-scroll-<dom>` element (the axis pair is the rule's job; a lone `overflow-x-auto` is exactly the shape that made the stick inert). No pan/zoom, no viewBox mutation.

## Known Issues — CommitGraphView (temporal view)

- **Lane sprawl at high agent counts**: `column_count` counts every agent lane even when it owns no nodes, and `@col_w` is fixed 24px — with ~15+ lanes the gutter (24 + 24·n px) exceeds the left panel and the row text scrolls out of view together with the gutter.

## Notes for Agents

- Geometry constants live in `Geometry` (`commit_graph/geometry.ex`): `@row_h 44`, `@col_w 24`, `@gutter_pad 12`, `@node_r 6`, `@base_r 4`, `@bend_r 7`, `@exit_gap 2`, `@chip_row_h 18`. Gutter width = `24 + column_count * 24`; total height = rows × 44 (extended for an edge endpoint resolved below the last node — a defensive shape the builder never emits); the `.cg-rows` container is left-padded by the gutter width so the svg and the row content never overlap — and BOTH sit inside the horizontal-scroll wrapper.
- The lane-header chip stagger (two rows, `lane mod 2`) keeps chips readable at high lane counts; a chip is centered on its lane's x via `translateX(-50%)`, so a very wide chip (a long `T<n>` label) overhangs symmetrically rather than shifting.
- Data/model ownership: the ASSEMBLY module (`EvoDashWeb.AgentsLive.CommitGraph`) computes the per-agent-lane model (per-node `row`/`column`(lane)/`depth`, the edge endpoints incl. agent-level `:spawn`/`:merge_back`, the `agents` list with `color`/`start_sha`/`end_sha`/`ended`/`lane`/`parent_id`); this renderer only maps the grid to pixels, routes/paints, and implements the START/END selection marking + readout.
- States handled: `:loading` (spinning `hero-arrow-path` + `"Loading commit history…"`), `:empty` (dimmed `hero-server` + `"No commit history yet."` + a hint line), `:error` (small `text-error`/`bg-error/10` strip `#commit-graph-error` — only when there is no data), and `:repos` (last-good graph KEPT when `@error != nil`, with a subtle `text-warning` `#commit-graph-stale-warning` strip above it).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree); the call site invokes it fully-qualified with `repos={@commit_graph}`, `selected_id={@selected_agent_id}`, `loading={@commit_graph_loading}`, `error={@commit_graph_error}`, `node_key={@current_node_id || "local"}`.
- The JS hook (`assets/js/hooks/commit_graph.js` — enter animations + the interaction layer above: hover sync, keyboard activation, scroll-to-selection; no pan/zoom) and the assembly builder are sibling workstreams — re-verify them against the FROZEN contract above before assuming the graph animates. The component tests (`test/evo_dash_web/components/commit_graph_view_test.exs`) use HAND-CRAFTED fixtures against this same contract (not builder output) while the builder wave lands.
- Folded runs are split across the two modules: `Fold` owns `gap_row/1` / `gap_node/1` / `fold_controls/1` plus the row/tooltip helper cluster (called as `Fold.<fun>` from `commit_graph_view.ex`), while `Geometry` owns every constant, grid→pixel mapping and edge route. A gap node flows through `positions/1` like any other node (it carries `column`/`row`), so `Geometry.endpoint/3`'s node-first resolution handles gap-aliased edge endpoints with NO special case.
- Gap rows are dispatched BEFORE the normal row/node paths (`Fold.gap?(node)` → `gap_node` in the gutter, `gap_row` in the rows), so the `#commit-row-<dom>-<sha>` / `#commit-node-<dom>-<sha>` ids never double-render for a `:gap` node — the gap keeps its own `#commit-gap-row-<dom>-<fold_key>` row while its gutter marker reuses the `#commit-node-<dom>-<sha>` id with a `cg-gap-node` class.
- New user-facing strings stay msgids for the release-time extraction pass — keep verbatim: `"%{count} commits"` (gap row label), `"Expand all"`, `"Collapse all"`, `"%{count} hidden commits"` (gap marker tooltip).

## Render cost (per render)

`commit_graph_view/1` re-executes on every render, so `commit_list/1` recomputes `Geometry.positions` / `geom` / `lane_chips` per render and each `<.edge_path>` calls `Geometry.edge_geo/3` (a scan of the full edge list — quadratic in edges, bounded by the builder's 100-commit cap).
`lane_header/1` re-filters its chips per stagger row.
`Fold` helpers (`gap?/1`, `fold_count/1`, `agent_index/1`) re-run per render but are O(nodes) / O(agents) lookups; `Fold.row_tags/1` and `Fold.node_title/1` build their strings per node per render — bounded by the same 100-commit cap.

## Narrow-width (mobile) — agent-tree indent

`path_tree/1`'s per-level agents-row wrapper carries `pl-7 xl:pl-0`.
Below `xl` the row stacks (`flex-col`), and the 28px indent (folder icon `size-5` + `gap-2`) puts the first agent box and every wrapped line exactly at that level's directory-text left edge, clear of the children trunk (`absolute left-2.5`).
Do NOT remove the indent — wrapped boxes overlap the trunk on mobile; `xl:pl-0` keeps the desktop two-column layout byte-identical.
