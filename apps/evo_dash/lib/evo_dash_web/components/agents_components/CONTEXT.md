# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: a compact HORIZONTAL AGENT-SWIMLANE rendered with plain HTML/CSS (divs + flex, no SVG) — one row per agent lane, time flowing left → right, lanes stacked top → bottom by recursion depth.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView` (`commit_graph_view.ex`)

Public function component `commit_graph_view/1` (`use EvoDashWeb, :html` + `use Gettext, backend: EvoDashWeb.Gettext`).
It is purely presentational: it does NO data assembly, NO I/O and never touches the socket.
ALL column math is owned by the pure assembly module `EvoDashWeb.AgentsLive.CommitGraph` (`build/2`) — this renderer only maps each lane's `from_column`/`to_column` and each `marker.column` to track percentages and draws the DOM.
Selection REUSES the existing `select_agent` event (`phx-value-id`) — there is no new event handler.

Attributes (all declared with `attr/3`):

- `:repos` (`:list`, **required**) — repo views from `CommitGraph.build/2` (input contract below).
- `:selected_id` (`:any`, default `nil`) — the selected agent id; adds the primary ring to that lane's tip marker + a faint row tint.
- `:loading` (`:boolean`, default `false`) — a fetch is in flight.
- `:error` (`:any`, default `nil`) — last fetch failed.
- `:node_key` (`:string`, default `"local"`) — the viewed node's identity; scopes the graph wrapper so a node switch resets the DOM.

#### Input contract (repo view shape)

```elixir
%{repo_key: term(), repo_dom_id: String.t(), repo_name: String.t(),
  column_count: non_neg_integer(), commit_count: non_neg_integer(),
  columns: [%{sha:, short_sha:, message:, author_name:, date:, refs:}],   # oldest -> newest
  lanes: [%{
    agent: %{id:, task_local_id:, status:, depth:, color:},
    from_column: non_neg_integer() | nil, to_column: non_neg_integer() | nil, tip_column: non_neg_integer() | nil,
    markers: [%{column: non_neg_integer(), sha:, short_sha:, message:, author_name:, date:, refs:, tip?: boolean()}]
  }]}   # lanes ordered by {depth, id} ascending; markers ascending by :column
```

`column_count` may be `0` (then every lane has `markers: []` and nil from/to/tip). The `columns` list is part of the view model but is NOT rendered by this component.

#### Component render tree

- `commit_graph_view/1` → `#commit-graph` root → `#commit-graph-body-<node_key>` wrapper → state dispatch (`view_state/3`: loading / empty / error / repos; the `:repos` state renders the stale-warning strip above the lanes when `@error != nil` — the last-good graph is KEPT).
- `repo_section/1` → per repo: the repo header div (unchanged markup: `hero-server-stack` icon in a `bg-primary` rounded chip + `text-primary-content` glyph + the repo name in a plain bold `truncate` span with `title`) + `lane_list/1`.
- `lane_list/1` → a `space-y-0.5` stack of `lane_row/1`, one per lane (top → bottom).
- `lane_row/1` → a `flex items-center` row carrying the click binding: a FIXED-WIDTH left gutter (`w-28 shrink-0`) holding a status dot (inline `background-color: agent_status_svg_color(status)`) + `T<task_local_id || id>` (`font-mono text-xs text-base-content/80 truncate`), then a `flex-1 relative h-6 min-w-0` TIMELINE TRACK. All tracks are identical width (`flex-1` in the same row structure), so percentage positions line up across lanes and a shared commit lands in the SAME column. The row is `rounded-md px-1 py-0.5 cursor-pointer hover:bg-base-200/50`.
- Timeline track contents, all absolutely positioned inside the track: a full-width baseline rail (`h-px bg-base-300/50`, vertically centered); the LANE PROGRESS element (rendered only when `from_column`/`to_column` are integers AND `column_count > 0`); then one `lane_marker/1` per marker (DOM order = paint order, so markers sit on top of the bar).
- `lane_marker/1` → ONE `<span>` per commit: `absolute top-1/2 -translate-x-1/2 -translate-y-1/2 rounded-full`, `size-2.5` (a TIP marker `size-3`), inline `left` % + `background-color`, plus a native `title` tooltip (`message first line · short_sha · author · date`, refs appended as a comma-joined segment when present).

#### Position math (percentages of the identical-width track)

- Lane bar: `left = from_column / column_count * 100`, `width = (to_column - from_column + 1) / column_count * 100` (min one column).
- Marker: `left = (marker.column + 0.5) / column_count * 100` (the column CENTER).
- Both go through the private `pct/1` (3-decimal round, trims a whole value's `.0` → `"50"`, `"33.333"`); a non-positive/non-integer column count falls back to `"0"`.
- The lane row also exposes a `title` (`T<id> · <status label>`).

#### Colour sources

- A non-tip marker's fill AND the lane bar's fill = the agent's depth hue (`agent.color`, a data-driven hex; missing/blank → `var(--color-base-content)`).
- A TIP marker (`marker.tip?`) fill = `EvoDashWeb.Helpers.agent_status_svg_color(agent.status)` — the shared status→SVG-color helper is the ONLY status→color mapping (never re-implement).
- The gutter status dot uses the same `agent_status_svg_color/1` via inline `background-color`.
- Selection is a STYLE CHANGE on the existing elements: `ring-2 ring-primary-standalone` on that lane's TIP marker (no tip marker → no ring added anywhere) plus `bg-primary/5` on the lane row. No halo circles, no extra stacked elements.

#### Click / selection contract

- `phx-click="select_agent"` + `phx-value-id={agent.id}` live on the ROW div (plus `cursor-pointer`), so clicking the row, the lane bar or any marker selects the agent (child clicks bubble up).
- No other element carries a click binding.

### FROZEN DOM contract (the animation agent implements JS/CSS against these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">`.
- Immediately inside the root, the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: the section div's id IS `repo_dom_id` VERBATIM — the builder's `repo_dom_id` ALREADY carries the `commit-graph-repo-` prefix (`commit-graph-repo-<slug>-<hash>`), so the renderer adds NO prefix (prefixing would double it). The repo header is a plain div ABOVE the lanes inside this wrapper.
- `data-commit-graph-anim` has EXACTLY two values:
  - `"node"` — ONE marker element per commit PER LANE: `id={"commit-marker-" <> repo_dom_id <> "-" <> to_string(agent.id) <> "-" <> marker.sha}`.
  - `"lane"` — the agent's single horizontal progress element: `id={"commit-lane-" <> repo_dom_id <> "-" <> to_string(agent.id)}`.
  - There is NO `"edge"` value. The renderer does NOT emit the animation classes (`commit-node-enter` / `commit-lane-enter`) — the JS adds them.
- Extra stable id (morphdom anchor, not part of the animation contract): the lane row `id={"commit-agent-row-" <> repo_dom_id <> "-" <> to_string(agent.id)}`.
- State blocks keep their ids: `#commit-graph-error`, `#commit-graph-stale-warning`.
- No `phx-update` mode anywhere; incremental patching rides morphdom's stable-unique-id matching.

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it already imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module.
- HTML/CSS only — NO SVG anywhere in this module. Semantic theme tokens only (`bg-base-*`, `text-base-content/*`, `border-base-*`, `bg-primary/5`, `text-primary-standalone`, `ring-primary-standalone`); NO raw hex/gray/slate/white literals. The ONLY raw color values are the data-driven depth hues + the status CSS-vars that arrive from the view model / `agent_status_svg_color/1`.
- Agent status colours MUST come from `EvoDashWeb.Helpers.agent_status_svg_color/1` — never re-implement the mappings (locked, test-pinned contract).
- Do NOT reference `EvoDashWeb.AgentsLive.CommitGraph.dot_r/0` / `ring_r/0` (removed with the SVG design) and do not hardcode marker radii math — the assembly owns all column math.
- All user-facing strings are `gettext`-wrapped (Chinese anchoring comments next to ambiguous labels); do not run `mix gettext.extract`/`merge`/`translate` during development.
- No `try/rescue`; every read of the prepared data is TOTAL (`Map.get/2` + pattern-matched normalization — non-map repo/lane/agent/marker entries are dropped, the column count folds to `0` when non-positive/non-integer, odd percentages fall back to `"0"`) so odd shapes degrade instead of crashing.

## Visual notes

- Compact swimlane, NOT an oversized plot: each row is a 24px (`h-6`) track; the panel body scrolls vertically, so no max-height/overflow wrapper is added here.
- NEVER clip horizontally: the percentage layout always fits 100% of the track width (no min-width, no horizontal scroll).
- Layer widths: gutter 7rem (`w-28`) + `gap-2` + `flex-1` track; markers are 10px (`size-2.5`) / 12px (`size-3`, tip).
- Paint order inside the track is DOM order (rail → lane bar → markers).

## Notes for Agents

- Data/model ownership: the ASSEMBLY module (`EvoDashWeb.AgentsLive.CommitGraph`) computes the swimlane model (lane order by `{depth, id}`, `from/to/tip_column`, per-marker `column` / `tip?`); this renderer only maps columns to track percentages and draws the DOM.
- States handled: `:loading` (spinning `hero-arrow-path` + "Loading commit history…"), `:empty` (dimmed `hero-server` + "No commit history yet."), `:error` (small `text-error`/`bg-error/10` strip — only when there is no data), and `:repos` (last-good lanes kept when `@error != nil`, with a subtle `text-warning` refresh-failed strip above them).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree).
