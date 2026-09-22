# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: a CLASSIC git graph (`git log --graph` style) rendered as one SVG per repository — commit dots on lanes, bezier edges, ref chips and agent rings in the right gutter.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView` (`commit_graph_view.ex`)

Public function component `commit_graph_view/1` (`use EvoDashWeb, :html` + `use Gettext, backend: EvoDashWeb.Gettext`).
It is purely presentational: it does NO data assembly, NO I/O and never touches the socket.
ALL geometry is owned by the pure assembly module `EvoDashWeb.AgentsLive.CommitGraph` (outside this subtree) — it computes every dot `(x, y)`, every edge `d` path, the SVG `width`/`height`, and exposes the radii as public zero-arity functions `CommitGraph.dot_r/0` / `CommitGraph.ring_r/0` (the single source of truth; the renderer calls them, never hardcodes radii).
Selection REUSES the existing `select_agent` event (`phx-value-id`) — there is no new event handler.

Attributes (all declared with `attr/3`):

- `:repos` (`:list`, **required**) — repo views from `CommitGraph.build/2` (input contract below).
- `:selected_id` (`:any`, default `nil`) — the selected agent id; drives halo circles + dot prominence.
- `:loading` (`:boolean`, default `false`) — a fetch is in flight.
- `:error` (`:any`, default `nil`) — last fetch failed.
- `:node_key` (`:string`, default `"local"`) — the viewed node's identity; scopes the graph wrapper so a node switch resets the DOM.

#### Input contract (repo view shape)

```elixir
%{repo_key:, repo_dom_id:, repo_name:, width: float, height: float, lane_count:, commit_count:,
  commits: [  # ordered TOP→BOTTOM (oldest first)
    %{sha:, short_sha:, message:, parents:, lane:, row:, x: float, y: float, refs: [String],
      highlight_color: String|nil,   # depth-hue hex when on an agent's progress path
      agent: nil | %{id:, task_local_id:, status:, depth:, color:, tip?: boolean}}],
  edges: [%{id: "commit-edge-<repo_dom_id>-<child>-<parent>", d: "M...C...", color: String|nil}],
  rings: [%{agent_id:, task_local_id:, status:, depth:, color:, x:, y:}]}
```

#### Component render tree

- `commit_graph_view/1` → `#commit-graph` root → `#commit-graph-body-<node_key>` wrapper → state dispatch (`view_state/3`: loading / empty / error / repos; the `:repos` state renders a stale-warning strip above the graph when `@error != nil` — the last-good graph is KEPT).
- `repo_section/1` → per repo: the repo header (normal flex div ABOVE the SVG, unchanged markup: `hero-server-stack` icon + repo name) + `commit_graph_svg/1`.
- `commit_graph_svg/1` → `<div class="overflow-auto max-h-[32rem]">` wrapper (vertical bound for tall graphs + horizontal scroll for narrow panels) → one `<svg viewBox="0 0 <w> <h>" width="100%" preserveAspectRatio="xMinYMin meet" role="img" style="min-width: <w>px">` drawn in three layers, bottom → top: `graph_edge/1` paths → `commit_dot/1` groups → `agent_ring/1` groups.
- `graph_edge/1` — `<path d fill="none" stroke-linecap="round">`; uncolored edges stroke `var(--color-base-content)` with `stroke-opacity="0.35"` and `stroke-width` 1.75; agent-colored edges (edge.color hex) get `stroke-width` 2.25 at full opacity via inline `style="stroke: <hex>"`.
- `commit_dot/1` — a `<g>` per commit holding: native SVG `<title>` tooltip (`message first line · short_sha · author · date`, total reads); an optional selection-halo `<circle r=ring_r+3.5 stroke=var(--color-primary) opacity 0.9>`; THE DOT `<circle r=CommitGraph.dot_r()>` (fill = `highlight_color` hex inline, else `var(--color-base-content)` with `fill-opacity="0.55"`; selection or highlight → full opacity; selected dot gains `stroke: var(--color-primary)`; class `transition-[fill,stroke] duration-300 motion-reduce:transition-none`); right-gutter ref chips; the agent tip marker. NO boxes, NO per-node sha/subject text.
- `agent_ring/1` — a `<g>` per agent tip: `<title>` (`T<id> · <status label>`), a subtle same-color glow band (`r=ring_r+2`, `stroke-width 4`, `stroke-opacity 0.15`), an optional selection halo (same shape as the dot's), and THE RING `<circle r=CommitGraph.ring_r() fill="none" stroke-width="2">` with `style={"stroke: #{EvoDashWeb.Helpers.agent_status_svg_color(ring.status)}"}` — the shared SVG status-color helper in `EvoDashWeb.Helpers` is the ONLY status→color mapping (never re-implement).

#### Gutter decorations (right of the lane area)

- **Ref chips** — rendered only when the repo has at least one ref anywhere (`repo_has_refs?/1` skips them wholesale otherwise). Per commit, refs (deduped, total reads) stack left→right from `gutter_x = repo.width - 146`: a `<rect rx=4 fill=var(--color-base-200) stroke=var(--color-base-300)>` sized from the estimated char width (`String.length(ref) * 4.6 + 8`, height 12) plus a mono `<text font-size="8" fill=var(--color-base-content)>`.
- **Tip marker** — when a dot's `agent.tip?` is true, a minimal `<text>` right of the dot: `"T" <> to_string(task_local_id || id)`, font-size 8, mono, opacity 0.7; positioned after any ref chips on that commit, else at `dot.x + ring_r + 4`. NEVER a box/card.

#### Click / selection contract

- Each dot's `<circle>` carries `phx-click="select_agent"` + `phx-value-id={commit.agent.id}` ONLY when `commit.agent != nil` (plus `cursor-pointer` in its class list); agent-less dots render no click binding at all.
- Each ring's main `<circle>` is always clickable (`phx-value-id={ring.agent_id}`).
- Selection (`agent.id == selected_id` / `ring.agent_id == selected_id`) renders the extra faint primary halo and bumps the dot's fill opacity to 1.

### FROZEN DOM contract (the animation agent implements JS/CSS against these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">`.
- Immediately inside the root, the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: the wrapper div's id IS `repo_dom_id` VERBATIM — the builder's `repo_dom_id` ALREADY carries the `commit-graph-repo-` prefix (`commit-graph-repo-<slug>-<hash>`), so the renderer adds NO prefix (prefixing would double it). The repo header is a plain div ABOVE the SVG inside this wrapper.
- Each commit dot GROUP: `id={"commit-dot-" <> repo.repo_dom_id <> "-" <> commit.sha}` + `data-commit-graph-anim="node"`. The id/marker live on the `<g>`; the click binding lives on the inner circle.
- Each edge path: `id={edge.id}` (already `"commit-edge-<repo_dom_id>-<child>-<parent>"` shaped, built by the assembly) + `data-commit-graph-anim="edge"`.
- Each agent ring GROUP: `id={"commit-ring-" <> repo.repo_dom_id <> "-" <> to_string(ring.agent_id)}` + `data-commit-graph-anim="node"`.
- State blocks keep their ids: `#commit-graph-error`, `#commit-graph-stale-warning`.
- No `phx-update` mode anywhere; incremental patching rides morphdom's stable-unique-id matching.

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it already imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module.
- Tailwind CSS 4 + DaisyUI classes for the wrappers/states ONLY, semantic theme tokens ONLY — inside the SVG all colors are inline `style="..."` consuming CSS vars (`var(--color-base-content)` etc.); the ONLY raw hex values are the `highlight_color`/`edge.color`/agent-depth hues that arrive from the DATA (they are data, not literals).
- Agent status colours MUST come from `EvoDashWeb.Helpers.agent_status_svg_color/1` — never re-implement the mappings (locked, test-pinned contract; SVG sibling of the `agent_status_*` Tailwind-class family).
- Radii MUST come from `EvoDashWeb.AgentsLive.CommitGraph.dot_r/0` / `ring_r/0` — single source of truth, never hardcoded here.
- All user-facing strings are `gettext`-wrapped (Chinese anchoring comments next to ambiguous labels); do not run `mix gettext.extract`/`merge`/`translate` during development.
- No `try/rescue`; every read of the prepared data is TOTAL (`Map.get/2` with pattern-matched normalization — nil coordinates fold to `0` via `num/1` before arithmetic) so odd shapes degrade instead of crashing.

## Visual / geometry notes (for redesign work)

- **Radii (from the assembly, `CommitGraph.dot_r/0` = 4.5, `ring_r/0` = 8.5)** drive every marker size; the renderer never hardcodes them. Per commit, up to FIVE stacked circles can render (bottom→top): the dot (`r` 4.5) inside its `<g>`; the dot's selection halo (`r = ring_r + 3.5` = 12.0 — notably much larger than the dot it encircles, since it is ring-radius based); then, drawn in a SEPARATE `<g>` on top when the commit is an agent tip, the ring glow band (`r = ring_r + 2` = 10.5), the ring's selection halo (`r = ring_r + 3.5` = 12.0) and the ring itself (`r` 8.5). Dots and rings are separate sibling groups at the same `(x, y)`.
- **Graph natural size**: `width = 12 + lane_count*24 + 150`, `height = 14 + rows*26 + 14` (assembly constants). A narrow left panel therefore horizontal-scrolls (SVG `min-width` = natural width) rather than squashing lanes; tall graphs vertical-scroll inside the wrapper's `max-h-[32rem]` (512px).
- **Ref-chip overflow is possible**: chips start at `gutter_x = repo.width - 146` and stack left→right with a per-chip width estimated from char count (`len*4.6 + 8`). A long branch/ref name (or several chips) can push a chip past the viewBox right edge — the SVG clips it (no scrollbar for SVG content outside the viewBox). The assembly reserves a 150px gutter, the renderer keeps a 4px inner margin (146).

## Notes for Agents

- Geometry ownership is split: the ASSEMBLY module computes positions/paths/dimensions; this renderer only draws them (plus the gutter-chip layout, which is presentation-only geometry derived from `repo.width`).
- `fmt/1` compacts whole floats for the viewBox/min-width interpolations (`210.0` → `"210"`); circle `cx/cy` keep the raw float (harmless). The assembly has its own `num/1` for edge paths.
- States handled: `:loading` (spinning `hero-arrow-path` + "Loading commit history…"), `:empty` (dimmed `hero-server` + "No commit history yet."), `:error` (small `text-error`/`bg-error/10` strip — only when there is no data), and `:repos` (last-good graph kept when `@error != nil`, with a subtle `text-warning` refresh-failed strip above it).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree).
- `test/evo_dash_web/components/commit_graph_view_test.exs` asserts the PREVIOUS box-lane markup and is expected to FAIL until rewritten for the SVG design (the rewrite is a separate task; do not "fix" the component back).
