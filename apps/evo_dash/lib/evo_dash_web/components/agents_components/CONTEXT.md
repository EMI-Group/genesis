# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: a **VERTICAL, GitLens/GitKraken-style PER-AGENT-LANE commit graph** — ONE ROW per commit (globally interleaved, top → bottom), ONE LANE PER AGENT in the left gutter, CIRCULAR dots, ROUNDED cross-lane edge routing (no sharp 90° bends), DASHED `:spawn` / `:merge_back` connectors, sticky per-lane header chips and a horizontally-scrolling gutter. Vertical scrolling is native: there is NO pan/zoom and NO viewport transform.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView.Geometry` (`commit_graph/geometry.ex`)

The PURE geometry/routing/lane-planning half of the renderer — every geometry CONSTANT and ALL coordinate math; the HEEx half only consumes the results. No HEEx, no socket, no I/O; every model read is TOTAL (non-integer grid values fold to `0`).

- Constants + accessors: `@row_h 44`, `@col_w 24` (LANE width), `@gutter_pad 12`, `@node_r 6`, `@base_r 4` (hollow `:base`/`:noop` stub radius), `@bend_r 7` (rounded-corner radius), `@exit_gap 2` (clearance an agent-level connector keeps below its source dot), `@chip_row_h 18` (one staggered lane-header chip row) — `row_h/0`, `col_w/0`, `gutter_pad/0`, `node_r/0`, `base_r/0`, `bend_r/0`, `chip_row_h/0`.
- `geom/4` — `%{col_count, gutter_w (24 + cols*24), total_h}`; `total_h` covers node rows AND edge landing rows (a virtual merge-back landing may sit below the last node); `col_count` = `max(from nodes, from agent lanes, model hint)` never below 1 (a lane with no nodes still needs its column).
- `dot_x/1` / `dot_y/1` / `positions/1` — lane/row center px (positions keyed by sha, `row` = the node's rendered index).
- `edge_kind/1` — recognizes `:merge` / `:spawn` / `:merge_back`, everything else folds to `:parent`; `agent_level?/1` — `kind in [:spawn, :merge_back]`.
- `edge_geo/2` — `%{kind, from, to, d}` with endpoint resolution NODE-first (a rendered node's position wins), falling back to the edge's own `{column, row}` (the NORMAL case for a virtual landing, `to_sha: nil`); agent-level connectors depart BELOW the source dot (`y + node_r + exit_gap`). `d` is `nil` when the endpoints collapse (the renderer drops the edge).
- `route/4` (private) — a SAME-lane edge (`from_column == to_column`) is a straight vertical `M..L..`; a cross-lane edge is orthogonal with TWO quadratic (`Q`) quarter-turn corners of clamped radius (`< 0.5` → straight line) — a sharp `L x y L x y` double-corner is never emitted.
- `lane_chips/2` — the per-lane header plan ordered by lane index: one entry per AGENT lane (from `agents[].lane`, incl. node-less lanes) plus the NEUTRAL lane 0 (`agent: nil`) only when no agent claims lane 0 AND unowned nodes exist; each chip carries `x` (the lane's dot-x anchor) and `chip_row` (`lane mod 2` — the two-row stagger).

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
  nodes: [%{sha, short_sha, message, author_name, date, refs,
            row: non_neg_integer(),     # globally interleaved 0..n-1 (NOT per-agent)
            column: non_neg_integer(),  # the LANE index (one lane per agent; 0 = neutral)
            depth: non_neg_integer(),
            kind: :commit | :base | :noop,   # :noop = synthesized no-op-child stub (like :base)
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
- Edge `:parent`/`:merge` are commit→parent (from = child); the agent-level `:spawn`/`:merge_back` join LANES — `:spawn` from the FORK node (parent's lane) to the child's oldest commit, `:merge_back` from the child's TIP (or `:noop` stub) back into the parent's lane; a `:merge_back` `to_sha` may be **`nil`** for a VIRTUAL landing — then `to_column`/`to_row` are authoritative and the path simply ends there. `owner_id` on agent-level edges = the CHILD agent (stroke color).
- Everything is a plain map (NO structs); `ended` is OPTIONAL (read TOTALLY — any non-`true`/missing value = live agent).

#### Render tree

- `commit_graph_view/1` → `#commit-graph` root (`phx-hook="CommitGraph"`, rendered ONCE per page and PERSISTS across node switches) → `#commit-graph-body-<node_key>` (`space-y-4`) → `view_state/3` dispatch.
- `view_state/3` (private clauses): `[]` + loading → `:loading`; `[]` + not loading + no error → `:empty`; `[]` + error → `:error`; otherwise `:repos`.
- The `:repos` state renders the stale-warning strip when `@error != nil`, then one `repo_section/1` per map entry (non-map entries dropped).
- `repo_section/1` → a wrapper `div` whose `id` IS `repo.repo_dom_id` VERBATIM (the builder already emits `commit-graph-repo-<slug>-<hash>` — add NO extra prefix) and `data-cg-repo-id` → repo header (the `hero-server-stack` icon in a `bg-primary` rounded chip + the name in a bold `truncate` span with `title`) → `commit_list/1`.
- `commit_list/1` → the optional `#cg-selection-readout-<repo_dom_id>` readout line, then the horizontal-scroll wrapper `#cg-scroll-<repo_dom_id>.cg-scroll.overflow-x-auto` hosting (top → bottom) the sticky `lane_header/1` bar and the relative list wrapper `#cg-list-<repo_dom_id>.cg-list.relative` (gutter svg + rows); a repo with NO nodes renders a `p.cg-empty-note` note inside the scroll wrapper instead.
- State blocks: `#commit-graph-error` (gettext "Could not load commit history.") and `#commit-graph-stale-warning` (gettext "Showing the last loaded commit graph — refresh failed.").

#### Lane header (sticky per-lane chips)

- `lane_header/1` → `#cg-lane-header-<dom>.cg-lane-header.sticky.top-0.z-10` (inline `width` = gutter width, `bg-base-100/95 backdrop-blur-sm`) ABOVE the gutter SVG, INSIDE the horizontal-scroll wrapper (so it scrolls in sync horizontally and sticks vertically).
- Chips are staggered over TWO 18px rows (`chip_row = lane mod 2` — even lanes on top, odd lanes below; same-row neighbours are 48px apart and never collide). One chip per lane plan entry:
  - Agent lane: `button#cg-lane-<dom>-<lane>.cg-lane-chip` — `phx-click="select_agent"` + `phx-value-id={agent_id}`, labelled `T<task_local_id>` in the agent's depth hue (border + text), a small status DOT colored via `Helpers.agent_status_svg_color/1`, a `title` of `T<n> · <status> [· terminated]`, and `opacity: 0.5` when `ended: true`. Rendered even when the lane owns NO nodes.
  - Neutral lane 0 (only when unowned nodes exist and no agent claims lane 0): NON-clickable `span#cg-lane-<dom>-0.cg-lane-chip.cg-lane-chip-neutral` labelled gettext "Pre-task" (Chinese comment: 任务开始前的"前置提交"泳道).
- Each chip is absolutely positioned at its lane's dot-x and CENTERED on it via inline `transform: translateX(-50%)` (content-sized width).

#### The gutter (geometry + paint)

- `svg#cg-gutter-<repo_dom_id>.cg-gutter.absolute.left-0.top-0.pointer-events-none` spans the whole list height; `width` = gutter width (`24 + column_count * 24`), `height` = rows × `@row_h` (extended for virtual landing rows), `viewBox` matched (so 1 SVG user unit == 1 CSS pixel 1:1), `role="img"`, `aria-label` = gettext `"Git commit history graph"`.
- Its children in DOM order (= paint order) are every `path.cg-edge`, then every `g.cg-node`. The click contract deliberately lives on the ROWS — the gutter is `pointer-events: none`.
- Grid → pixels: lane `c`'s dot center at `x = 24 + c * 24`; row `r`'s at `y = r * 44 + 22`.
- `edge_path/1` → `path.cg-edge[data-commit-graph-anim="edge"]` (a zero-length/collapsed edge is dropped via `:if`):
  - Routing (`Geometry.edge_geo/2`): a same-lane edge renders as a plain straight vertical `M x y1 L x y2` (no bends); a cross-lane edge routes orthogonally with BOTH corners rounded by quadratic `Q` quarter-turns (radius `@bend_r 7`, clamped to half the span) — the sharp `L x y L x y L x y` double-corner signature is never emitted. A `:spawn` departs BELOW its fork dot (`fork_cy + node_r + exit_gap`); a `:merge_back` mirrors that from the child tip; a virtual landing (`to_sha: nil`) simply ENDS the path at the edge's own `to_column`/`to_row` coordinates (no marker circle).
  - Stroke styles: `:parent` SOLID `stroke-width="2"`; `:merge`, `:spawn`, `:merge_back` DASHED `stroke-dasharray="4 3"` + `stroke-width="1.6"`.
  - Stroke color = the owner agent's depth hue (for agent-level kinds the CHILD agent) at `stroke-opacity 0.75` (an ENDED owner → `0.4`); an unowned edge falls back to `var(--color-base-content)` at `0.3`.
  - Edge IDS: commit→parent kinds keep `#commit-edge-<dom>-<from_sha>-<to_sha>`; the agent-level kinds use `#commit-edge-<dom>-<kind>-<owner_key>-<from_key>-<to_key>` (kind literal `spawn`/`merge_back`, sanitized terms; `to_key` = `"l<col>r<row>"` when `to_sha` is nil) — avoids nil-sha collisions.
- `node_dot/1` → `g#commit-node-<dom>-<sha>.cg-node[data-commit-graph-anim="node"][data-cg-sha][data-cg-agent-id={owner_id}]` containing a native `<title>` (stub prefix `base`/`no-op`, then message first line · short sha · author · date · refs; empties dropped) and a `circle.cg-node-dot` — a CIRCLE centred on the grid point (`cx`/`cy`, `r = @node_r 6` for commits); a `:base`/`:noop` node is a smaller HOLLOW circle (`r = @base_r 4`, `fill: none`, base-content stroke). `stroke-width="1.5"`, inline `fill`/`fill-opacity`/`stroke`.
- Node fill: a stub node is HOLLOW; a node that is its owner's END (`owner_id ∈ node.end_ids`) → `EvoDashWeb.Helpers.agent_status_svg_color(<owner status>)`; every other owned node → its owner agent's depth hue; an unowned non-stub node → muted `var(--color-base-content)` at `fill-opacity 0.55`. A node owned by an ENDED agent keeps its hue/status color but drops to `fill-opacity 0.5`.
- Selection rings (an EXTRA `circle.cg-node-ring` child, visible without CSS): the START node (`selected_id ∈ node.start_ids`) gets a SOLID `var(--color-primary)` ring, the END node (`selected_id ∈ node.end_ids`) a DASHED one (`stroke-dasharray "3 2"`); the ring's `r` = the dot's `r + 3` (commits 9, stubs 7).

#### Rows

- `commit_row/1` → `div#commit-row-<dom>-<sha>.cg-row[data-commit-graph-anim="row"][data-cg-sha][data-cg-agent-id={owner_id}]` with `style="height: 44px"` (the fixed row height the gutter aligns to) and `phx-click="select_agent"` + `phx-value-id={owner_id}` (both OMITTED when `owner_id` is nil).
- Row state classes: `cursor-pointer hover:bg-base-200/60` when owned, `bg-primary/10` when the row's owner IS the selection, `ring-1 ring-inset ring-primary/40` when the row is the SELECTED agent's start/end node, and `opacity-50` when owned by an ENDED agent.
- First line: `.cg-row-sha` (mono short sha) + either `.cg-base-label` (gettext `"base"` for `kind: :base`, gettext `"no-op"` for `kind: :noop`) or `.cg-row-message` (the first line of the message, truncated), then the optional `.cg-row-marker` (gettext `"start"` / `"end"`, only for the SELECTED agent's endpoints) and the auto-right `.cg-row-meta` (`author · date`, empty for a stub node).
- Second line (only when the node carries tags): AGENT chips — one `button.cg-agent-tag#commit-agent-tag-<dom>-<sha>-<start|end>-<agent_key>` per agent in `node.start_ids` (SOLID border, `start` marker) and per agent in `node.end_ids` (DASHED border, `end` marker), labelled `T<task_local_id || agent_id>` in that agent's depth hue and firing `select_agent` / `phx-value-id` — plus REF chips `span.cg-ref-tag#commit-ref-tag-<dom>-<sha>-<ref_key>` (one per `node.refs` entry, non-clickable).
- Agents that no longer exist in `agents` (odd model data) still render their chip, labelled `T<id>` in base ink.

#### Selection readout

- When `@selected_id` matches one of THIS repo's `agents`, the readout `div#cg-selection-readout-<dom>.text-primary.font-mono` renders ABOVE the scroll wrapper (a `hero-cursor-arrow-rays` icon + text): gettext `"Selected %{agent}"`, or `"Selected %{agent} · %{range}"` when start/end shas are known (`range` = `start_sha → end_sha`, short shas).
- Selecting also accents that agent's rows (the `bg-primary/10` / ring classes above) — selection REUSES `select_agent`; there is no new event.

### FROZEN DOM contract (the JS hook `assets/js/hooks/commit_graph.js` + CSS animation target these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">` — rendered ONCE per page, PERSISTS across node switches (the hook mounts once and is NOT re-mounted, so stable ids matter).
- Immediately inside: the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: the wrapper `div` whose id IS `repo_dom_id` VERBATIM (with `data-cg-repo-id`); inside it `#cg-scroll-<repo_dom_id>.cg-scroll` (the `overflow-x: auto` unit) → `#cg-lane-header-<repo_dom_id>.cg-lane-header` + `#cg-list-<repo_dom_id>.cg-list.relative` → `svg#cg-gutter-<repo_dom_id>.cg-gutter` (the absolute overlay) + `.cg-rows` (left-padded by the gutter width, moving with the gutter in the horizontal scroll).
- `data-commit-graph-anim` takes EXACTLY three values: `"edge"` (`path.cg-edge`, ALL kinds including `:spawn`/`:merge_back`), `"node"` (`g.cg-node`), `"row"` (`div.cg-row`). The animation classes (`commit-edge-enter` / `commit-node-enter` / `commit-row-enter`) are NEVER emitted here — the JS adds them. Lane chips carry NO animation.
- Edge ids: commit→parent `#commit-edge-<repo_dom_id>-<from_sha>-<to_sha>`; agent-level `#commit-edge-<repo_dom_id>-<kind>-<owner_key>-<from_key>-<to_key>` (`to_key` = `l<col>r<row>` for a virtual landing). Node ids `#commit-node-<repo_dom_id>-<sha>`; row ids `#commit-row-<repo_dom_id>-<sha>`; lane chips `#cg-lane-<repo_dom_id>-<lane>`; agent chips `#commit-agent-tag-<repo_dom_id>-<sha>-<start|end>-<agent_key>`; ref chips `#commit-ref-tag-<repo_dom_id>-<sha>-<ref_key>`; readout `#cg-selection-readout-<repo_dom_id>`.
- State blocks keep their ids: `#commit-graph-error`, `#commit-graph-stale-warning`.
- No `phx-update` mode anywhere; every element carries a stable, unique DOM id (suffixed with `repo_dom_id`) so LiveView's patcher reuses nodes.

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module. The renderer aliases `EvoDashWeb.AgentsComponents.CommitGraphView.Geometry` for ALL geometry/routing/lane planning.
- SVG is REQUIRED for the gutter graph (circular commit dots, rounded edges, selection rings); the rows, the lane header, the readout and the state blocks are plain HTML.
- Semantic theme tokens only for chrome (`bg-base-*`, `text-base-content/*`, `border-base-*`, `var(--color-*)` via inline `style` for SVG fills/strokes); the ONLY raw color values are the model's depth hues (`agents[].color`) and `agent_status_svg_color/1`.
- Agent status colours MUST come from `EvoDashWeb.Helpers.agent_status_svg_color/1` — never re-implement the mappings (locked, test-pinned contract). The lane chip status dot reuses the same mapping.
- Do NOT reference `EvoDashWeb.AgentsLive.CommitGraph.dot_r/0` / `ring_r/0` (removed) — the renderer owns its own radii (`@node_r` / `@base_r` via `Geometry`) and grid → pixel mapping.
- All user-facing strings are `gettext`-wrapped with Chinese anchoring comments next to ambiguous labels (the `start`/`end` tags, the selection readout, the empty-repo note, the `base`/`no-op` labels, the "Pre-task" neutral-lane chip, the loading/empty/error states); do not run `mix gettext.extract` / `merge` / `translate` during development.
- No `try/rescue`; every read is TOTAL (`Map.get/2` + `is_map`/list filters — non-map repo/node/edge/agent entries dropped, grid values folded to `0`, odd colors/ids fall back to base ink / `""`, `safe_string/1` stringifies any term into a DOM-safe key) so malformed data degrades instead of raising.
- Horizontal scrolling MUST go through the single `#cg-scroll-<dom>` wrapper (gutter + rows + lane headers scroll as ONE unit); vertical scrolling stays native (the page scrolls) — no pan/zoom, no viewBox mutation.

## Notes for Agents

- Geometry constants live in `Geometry` (`commit_graph/geometry.ex`): `@row_h 44`, `@col_w 24`, `@gutter_pad 12`, `@node_r 6`, `@base_r 4`, `@bend_r 7`, `@exit_gap 2`, `@chip_row_h 18`. Gutter width = `24 + column_count * 24`; total height = rows × 44 (extended for virtual landing rows); the `.cg-rows` container is left-padded by the gutter width so the svg and the row content never overlap — and BOTH sit inside the horizontal-scroll wrapper.
- The lane-header chip stagger (two rows, `lane mod 2`) keeps chips readable at high lane counts; a chip is centered on its lane's x via `translateX(-50%)`, so a very wide chip (a long `T<n>` label) overhangs symmetrically rather than shifting.
- Data/model ownership: the ASSEMBLY module (`EvoDashWeb.AgentsLive.CommitGraph`) computes the per-agent-lane model (per-node `row`/`column`(lane)/`depth`, the edge endpoints incl. agent-level `:spawn`/`:merge_back`, the `agents` list with `color`/`start_sha`/`end_sha`/`ended`/`lane`/`parent_id`); this renderer only maps the grid to pixels, routes/paints, and implements the START/END selection marking + readout.
- States handled: `:loading` (spinning `hero-arrow-path` + `"Loading commit history…"`), `:empty` (dimmed `hero-server` + `"No commit history yet."` + a hint line), `:error` (small `text-error`/`bg-error/10` strip `#commit-graph-error` — only when there is no data), and `:repos` (last-good graph KEPT when `@error != nil`, with a subtle `text-warning` `#commit-graph-stale-warning` strip above it).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree); the call site invokes it fully-qualified with `repos={@commit_graph}`, `selected_id={@selected_agent_id}`, `loading={@commit_graph_loading}`, `error={@commit_graph_error}`, `node_key={@current_node_id || "local"}`.
- The JS hook (`assets/js/hooks/commit_graph.js`, enter animations only — no pan/zoom) and the assembly builder are sibling workstreams — re-verify them against the FROZEN contract above before assuming the graph animates. The component tests (`test/evo_dash_web/components/commit_graph_view_test.exs`) use HAND-CRAFTED fixtures against this same contract (not builder output) while the builder wave lands.
