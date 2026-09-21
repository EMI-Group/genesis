# AgentsComponents — Sub-Components

## Intent

Sub-component modules of the Agents page left panel, extracted from the facade `EvoDashWeb.AgentsComponents` (`../agents_components.ex`).
`CommitGraphView` is the TEMPORAL (git commit history) view: it renders the commit graph grouped by repository with ONE LANE PER AGENT, so the recursive agent-spawns-agent structure (each child lane forking off its parent's lane) is visually obvious.
It is the counterpart of the SPATIAL agent tree (`path_tree/1`), which stays on the facade.

## API Surface

### `EvoDashWeb.AgentsComponents.CommitGraphView` (`commit_graph_view.ex`)

Public function component `commit_graph_view/1` (`use EvoDashWeb, :html` + `use Gettext, backend: EvoDashWeb.Gettext`).
It is purely presentational: it does NO data assembly, NO I/O and never touches the socket.
Its input is fully-prepared display data built by the pure `EvoDashWeb.AgentsLive.CommitGraph` module (outside this subtree).
Selection REUSES the existing `select_agent` event (`phx-value-id`) — there is no new event handler.
Attributes (all declared with `attr/3`):

- `:repos` (`:list`, **required**) — repo views `%{repo_key, repo_dom_id, repo_name, lanes}`; `repo_dom_id` is a DOM-safe stable id, `lanes` is ordered depth-first (parents before children).
- `:selected_id` (`:any`, default `nil`) — the selected agent id; the matching lane's agent chip gets the tree's selection ring.
- `:loading` (`:boolean`, default `false`) — a fetch is in flight.
- `:error` (`:any`, default `nil`) — last fetch failed.
- `:node_key` (`:string`, default `"local"`) — the viewed node's identity; scopes the graph wrapper so a node switch resets the DOM.

A lane is `%{agent_id, lane_index, depth, parent_agent_id, parent_lane_index, connects?, task_local_id, status, agent_module, model_id, base_commit, current_commit, commits}`; `commits` is ordered OLDEST → NEWEST and each commit view is `%{sha, short_sha, message, author_name, date, parents, refs, has_parent_in_lane?}`.

### FROZEN DOM contract (the animation agent implements JS/CSS against these — do NOT rename or drop them)

- Root: `<div id="commit-graph" phx-hook="CommitGraph">`.
- Immediately inside the root, the node-scoped wrapper `id={"commit-graph-body-" <> @node_key}` (a node switch changes the id → LiveView replaces the whole subtree).
- Per repo: `id={"commit-graph-repo-" <> repo.repo_dom_id}`.
- Per lane wrapper: `id={"commit-lane-" <> repo.repo_dom_id <> "-" <> to_string(lane.agent_id)}` + `data-commit-graph-anim="lane"`.
- Per lane commits list: `id={"commit-lane-commits-" <> repo.repo_dom_id <> "-" <> to_string(lane.agent_id)}` with `phx-update="append"` (keyed append container; new commits land at the end).
- Each commit node: `id={"commit-node-" <> repo.repo_dom_id <> "-" <> c.sha}`, `data-commit-graph-anim="node"`, `phx-click="select_agent"`, `phx-value-id={lane.agent_id}`.
- Agent chip at the lane tip: `id={"commit-agent-chip-" <> to_string(lane.agent_id)}`, `data-commit-graph-anim="node"`, `phx-click="select_agent"`, `phx-value-id={lane.agent_id}`.
- Connector / edge elements: `data-commit-graph-anim="edge"` — the parent→child elbow (only when `lane.connects?`), the continuous lane rail, and one segment per gap between consecutive commits.
- Every child of the append container carries a unique id (`commit-edge-<repo_dom_id>-<sha>` for gap edges, `commit-node-...` for nodes) — REQUIRED by `phx-update="append"`.

## Constraints

- `use EvoDashWeb, :html` is the entrypoint — it already imports `EvoDashWeb.Helpers`; the explicit `use Gettext, backend: EvoDashWeb.Gettext` mirrors the facade module.
- Tailwind CSS 4 + DaisyUI ONLY, semantic theme tokens ONLY (no hex/named-gray/white literals) so light/dark and the configurable accent both work; follow the Adwaita token grammar in `../../CONTEXT.md` and `../CONTEXT.md` (hairlines `border-base-300`, cards `rounded-xl` max, sunken wells `bg-base-200/…`, text alpha floor ≥ `/50`, labels ≥ `/60`, never `*-content` on a translucent tint).
- Agent status colouring MUST reuse the `EvoDashWeb.Helpers` helpers `agent_status_bg/1`, `agent_status_border/1`, `agent_status_color/1`, `agent_status_icon/1`, `agent_status_label/1` — never re-implement the mappings (they are a locked, test-pinned contract).
- Selection highlight MUST match the tree's agent cards (`ring-2 ring-primary-standalone ring-offset-1 ring-offset-base-100`) plus the `hover:ring-1 hover:ring-primary-standalone/40` affordance.
- All user-facing strings are `gettext`-wrapped (Chinese anchoring comments sit next to ambiguous labels); do not run `mix gettext.extract`/`merge`/`translate` during development.
- No `try/rescue`; all reads of the prepared data are TOTAL (missing/odd shapes degrade to nothing rather than crashing).

## Notes for Agents

- `phx-update="append"` emits a LiveView deprecation warning ("please use streams instead") — it is deliberate and required by the frozen contract; do not "fix" it to streams without also updating the animation agent's assumptions.
- The component deliberately does NOT own repo-header/lane/commit geometry keys beyond `margin-left` from `lane.depth`; the rail/elbow/node visuals are Tailwind classes and the animation lives in the assets subtree.
- States handled: `:loading` (spinning `hero-arrow-path` + "Loading commit history…"), `:empty` (dimmed `hero-server` + "No commit history yet."), `:error` (small `text-error`/`bg-error/10` strip — only when there is no data), and `:repos` (last-good graph kept when `@error != nil`, with a subtle `text-warning` refresh-failed strip above it).
- Wiring into the left panel (view switcher, `selected_id`/`node_key` assigns) is owned by `agents_live.ex` / `agents_live.html.heex` (outside this subtree) and is a separate step.
