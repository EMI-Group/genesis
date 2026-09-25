defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView` — the
  TEMPORAL (git commit history) view of the Agents page left panel.

  `commit_graph_view/1` is purely presentational: it renders the per-repo graph
  view models (the v2 per-agent-LANE contract) as a VERTICAL, GitLens/GitKraken-
  style commit graph — one row per commit (globally interleaved), ONE LANE PER
  AGENT in the left gutter, CIRCULAR dots, ROUNDED cross-lane edge routing,
  DASHED `:spawn` / `:merge_back` connectors, sticky per-lane header chips and a
  horizontally-scrolling gutter — and fires the existing `select_agent` event
  from the rows, the agent tags and the lane chips.

  These tests render it in isolation with `render_component/2` (no `live/3` —
  matching the rest of this directory) and pin the frozen DOM contract consumed
  by the client-side `CommitGraph` hook / CSS animation. All fixtures are
  HAND-CRAFTED view models (`repo_view/1`, `node_view/1`, `edge_view/1`,
  `agent_map/1`); they intentionally do NOT go through the real
  `CommitGraph.build/2` (the builder is rewritten in parallel against the same
  contract — end-to-end coverage lands with the later integration wave).

  Pinned surfaces:

    * `#commit-graph` + `phx-hook="CommitGraph"` → the node-scoped body
      `#commit-graph-body-<node_key>` → one section per repo whose id IS the
      model's `repo_dom_id` VERBATIM (no extra prefix) with a name header;
    * `#cg-scroll-<dom>` — the `overflow-x` wrapper hosting (top → bottom) the
      sticky lane-header bar and the `relative` list wrapper `#cg-list-<dom>`
      holding the absolute gutter `<svg.cg-gutter[viewBox]>` and the `.cg-rows`
      container left-padded by the gutter width;
    * LANE HEADER chips: ONE per agent lane (`#cg-lane-<dom>-<lane>`,
      `button.cg-lane-chip`, `T<task_local_id>` in the agent's hue + status dot,
      the `select_agent` contract, dimmed when ended — including a lane with NO
      nodes) plus the NON-clickable neutral lane-0 `span` ("Pre-task") only when
      unowned nodes exist;
    * `path.cg-edge[data-commit-graph-anim="edge"]` — ROUNDED routing (same-lane
      straight vertical; cross-lane with `Q` quarter-turns, NEVER the sharp
      `L x y L x y L x y` double-corner), `:parent` solid width 2 vs
      `:merge`/`:spawn`/`:merge_back` dashed `4 3` width 1.6; commit → parent
      ids `#commit-edge-<dom>-<from>-<to>` vs the agent-level scheme
      `#commit-edge-<dom>-<kind>-<owner>-<from>-<to>` with `l<col>r<row>` for a
      VIRTUAL merge-back landing (`to_sha: nil`);
    * `g.cg-node[data-commit-graph-anim="node"]` with `data-cg-agent-id` /
      `data-cg-sha`, an inner `<title>` tooltip and the CIRCULAR dot geometry
      (`circle.cg-node-dot` r 6; a `:base`/`:noop` stub hollow r 4);
    * `div.cg-row[data-commit-graph-anim="row"]` with the stable id, the fixed
      row height, the `select_agent` contract (omitted for an unowned node), the
      short sha / message / `author · date` and the second-line TAGS
      (`button.cg-agent-tag` start/end chips, non-clickable `span.cg-ref-tag`);
    * selection (`selected_id`): SOLID start ring / DASHED end ring
      (`circle.cg-node-ring`), row accents + markers, the
      `#cg-selection-readout-<dom>` annotation;
    * an ENDED (retained) agent renders DIM: node dots `fill-opacity: 0.5`,
      edges `stroke-opacity: 0.4`, rows `opacity-50`, lane chip `opacity: 0.5`;
    * the `:loading` / `:empty` / `:error` / stale-warning states and the total /
      defensive degradation of odd model shapes.

  Note: Floki's HTML parser lowercases attribute names, so the SVG's `viewBox`
  is queried as `viewbox`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsComponents.CommitGraphView
  alias EvoDashWeb.Helpers

  # Fixture shas (8 chars so the rendered short sha IS the sha).
  @sha_p1 "p1000000"
  @sha_b1 "b1000000"
  @sha_c1 "c1000000"
  @sha_c2 "c2000000"
  @sha_c3 "c3000000"
  @sha_c4 "c4000000"

  # The documented depth hues.
  @depth0_color "#7c38dc"
  @depth1_color "#dcad38"

  # The renderer's documented geometry constants: @row_h = 44, @col_w = 24,
  # @gutter_pad = 12, @node_r = 6, @base_r = 4, @bend_r = 7, @exit_gap = 2.
  # dot_x(lane) = 24 + lane * 24 → lanes 0/1/2 sit at x 24/48/72.
  # dot_y(row) = row * 44 + 22.
  #
  # The happy fixture: 3 lanes (0 = neutral pre-task, 1 = agent a1, 2 = agent
  # a2), 6 nodes on rows 0..5, a virtual merge-back landing at lane 1 / row 6.
  # gutter_w = 24 + 3 * 24 = 96; total_h = 7 * 44 = 308.
  @dom "commit-graph-repo-happy-1"
  @happy_gutter_w 96
  @happy_gutter_h 308

  describe "commit_graph_view/1 — root markers" do
    test "renders the #commit-graph hook root wrapping the node-keyed body" do
      tree = parse(render_repos(happy_repos()))

      assert [root] = Floki.find(tree, "#commit-graph")
      assert attr(root, "phx-hook") == ["CommitGraph"]

      # Default node key.
      assert [body] = Floki.find(tree, "#commit-graph-body-local")
      assert attr(body, "class") == ["space-y-4"]

      # A non-default node key changes ONLY the body id — the hook root (which
      # mounts once per page) is node-independent.
      other = parse(render_repos(happy_repos(), node_key: "remote_one"))

      assert Floki.find(other, "#commit-graph-body-remote_one") != []
      assert Floki.find(other, "#commit-graph-body-local") == []
      assert Floki.find(other, "#commit-graph") != []
    end
  end

  describe "commit_graph_view/1 — states" do
    test "loading state shows the spinner copy and no error block" do
      tree = parse(render_repos([], loading: true))

      assert Floki.find(tree, "#commit-graph-body-local") != []
      assert Floki.text(tree) =~ "Loading commit history…"
      assert Floki.find(tree, "#commit-graph-error") == []
      assert Floki.find(tree, "#commit-graph-stale-warning") == []
    end

    test "empty state renders when there are no repos" do
      tree = parse(render_repos([]))

      assert Floki.text(tree) =~ "No commit history yet."
      assert Floki.text(tree) =~ "Start a task from the dashboard to see the commit graph here."
      assert Floki.find(tree, "#commit-graph-error") == []
    end

    test "error state renders #commit-graph-error when there are no repos and an error" do
      tree = parse(render_repos([], error: "boom"))

      assert [err] = Floki.find(tree, "#commit-graph-error")
      assert Floki.text(err) =~ "Could not load commit history."
    end

    test "stale warning renders alongside repos when an error is present" do
      tree = parse(render_repos(happy_repos(), error: "boom"))

      assert [warning] = Floki.find(tree, "#commit-graph-stale-warning")
      assert Floki.text(warning) =~ "Showing the last loaded commit graph"
      assert Floki.find(tree, ".cg-row") != []
      # The hard error block is NOT rendered once repos exist.
      assert Floki.find(tree, "#commit-graph-error") == []
    end

    test "no stale warning when repos render without an error" do
      tree = parse(render_repos(happy_repos()))
      assert Floki.find(tree, "#commit-graph-stale-warning") == []
    end
  end

  describe "commit_graph_view/1 — repo sections" do
    test "the section id IS repo_dom_id verbatim, with a repo-name header above the list" do
      {repo, _dom, tree} = happy()

      # No doubled prefix: the model's id already starts commit-graph-repo-.
      assert String.starts_with?(repo.repo_dom_id, "commit-graph-repo-")
      assert [section] = Floki.find(tree, "##{repo.repo_dom_id}")
      assert attr(section, "data-cg-repo-id") == [repo.repo_dom_id]

      [header, list] = element_children(section)

      # The header block carries the repo display name + the hero-server-stack chip …
      assert Floki.find(header, ~s(span[title="My Project"])) != []
      assert Floki.find(header, "span.hero-server-stack") != []
      assert Floki.text(header) =~ "My Project"
      # … and the scrollable commit list lives BELOW it.
      assert Floki.find(header, "svg.cg-gutter") == []
      assert Floki.find(list, "svg.cg-gutter") != []

      assert length(repo.nodes) == 6
    end

    test "two repos render two independent sections" do
      [repo] = happy_repos()
      [other] = happy_two_repo_fixture()

      assert repo.repo_dom_id != other.repo_dom_id

      tree = parse(render_repos([repo, other]))

      assert Floki.find(tree, "##{repo.repo_dom_id}") != []
      assert Floki.find(tree, "##{other.repo_dom_id}") != []

      assert Floki.text(Floki.find(tree, "##{repo.repo_dom_id}")) =~ "My Project"
      assert Floki.text(Floki.find(tree, "##{other.repo_dom_id}")) =~ "foreign-repo"

      # Two independent gutters + scroll wrappers, each with its own rows.
      assert Floki.find(tree, "svg.cg-gutter") |> length() == 2
      assert Floki.find(tree, "#cg-gutter-#{repo.repo_dom_id}") != []
      assert Floki.find(tree, "#cg-gutter-#{other.repo_dom_id}") != []
      assert Floki.find(tree, "#cg-scroll-#{repo.repo_dom_id}") != []
      assert Floki.find(tree, "#cg-scroll-#{other.repo_dom_id}") != []
    end
  end

  describe "commit_graph_view/1 — horizontal scroll + gutter geometry" do
    test "the scroll wrapper hosts the sticky lane header and the list, in order" do
      {_repo, dom, tree} = happy()

      [scroll] = Floki.find(tree, "#cg-scroll-#{dom}")

      # overflow-x scrolling as ONE unit (gutter + rows + lane headers).
      assert attr(scroll, "class") |> hd() =~ "cg-scroll"
      assert attr(scroll, "class") |> hd() =~ "overflow-x-auto"

      [lane_header, list] = element_children(scroll)
      assert attr(lane_header, "id") == ["cg-lane-header-#{dom}"]
      assert attr(list, "id") == ["cg-list-#{dom}"]
    end

    test "the list wrapper is relative, carries data-cg-repo-id, and hosts gutter + rows" do
      {_repo, dom, tree} = happy()

      assert [list] = Floki.find(tree, "#cg-list-#{dom}")
      assert attr(list, "class") == ["cg-list relative"]
      assert attr(list, "data-cg-repo-id") == [dom]

      [gutter, rows] = element_children(list)
      assert attr(gutter, "class") == ["cg-gutter absolute left-0 top-0 pointer-events-none"]
      assert attr(rows, "class") == ["cg-rows"]
    end

    test "the gutter svg carries the derived width/height/viewBox and the aria label" do
      {_repo, dom, tree} = happy()

      [gutter] = Floki.find(tree, "#cg-gutter-#{dom}")

      assert attr(gutter, "width") == [Integer.to_string(@happy_gutter_w)]
      assert attr(gutter, "height") == [Integer.to_string(@happy_gutter_h)]
      assert attr(gutter, "viewbox") == ["0 0 #{@happy_gutter_w} #{@happy_gutter_h}"]
      assert attr(gutter, "class") == ["cg-gutter absolute left-0 top-0 pointer-events-none"]
      assert attr(gutter, "role") == ["img"]
      assert attr(gutter, "aria-label") == ["Git commit history graph"]

      # width == 24 + column_count * 24; height covers the virtual landing row
      # (7 rows although only 6 nodes exist).
      assert @happy_gutter_w == 24 + 3 * 24
      assert @happy_gutter_h == 7 * 44
    end

    test "the rows container is left-padded by the gutter width" do
      {_repo, dom, tree} = happy()

      [rows] = Floki.find(tree, "#cg-list-#{dom} .cg-rows")
      assert attr(rows, "style") == ["padding-left: #{@happy_gutter_w}px"]
    end

    test "one .cg-row per node, in top → bottom model order" do
      {repo, dom, tree} = happy()

      rows = Floki.find(tree, ".cg-row")

      assert length(rows) == length(repo.nodes)

      assert Enum.map(rows, &(attr(&1, "id") |> hd())) ==
               for(n <- repo.nodes, do: "commit-row-#{dom}-#{n.sha}")

      # Every row is exactly the fixed height.
      assert Enum.all?(rows, &(attr(&1, "style") == ["height: 44px"]))
      assert Enum.all?(rows, &(attr(&1, "data-commit-graph-anim") == ["row"]))
    end

    test "a repo with no nodes renders the empty note instead of a gutter or lane header" do
      repo = repo_view(nodes: [], edges: [], agents: [])
      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      assert [note] = Floki.find(tree, ".cg-empty-note")
      assert Floki.text(note) =~ "No commit history for this repository."
      assert Floki.find(tree, "#cg-gutter-#{dom}") == []
      assert Floki.find(tree, "#cg-lane-header-#{dom}") == []
      assert Floki.find(tree, ".cg-row") == []
    end

    test "column_count is derived from the nodes and agent lanes when the hint is absent/odd" do
      repo =
        repo_view(
          column_count: 0,
          nodes: [
            node_view(sha: "n0000001", column: 0, row: 0),
            node_view(sha: "n0000002", column: 2, row: 1)
          ],
          agents: [agent_map(lane: 2)]
        )

      tree = parse(render_repos([repo]))
      [gutter] = Floki.find(tree, "#cg-gutter-#{repo.repo_dom_id}")

      # max(node column)+1 = 3 → 24 + 3*24 = 96.
      assert attr(gutter, "width") == ["96"]
      assert attr(gutter, "height") == ["88"]
    end
  end

  describe "commit_graph_view/1 — lane header chips" do
    test "one chip per lane: neutral span + one button per agent, at the lane's x" do
      {_repo, dom, tree} = happy()

      [header] = Floki.find(tree, "#cg-lane-header-#{dom}")

      # Sticky above the SVG, inside the horizontal-scroll container.
      assert attr(header, "class") |> hd() =~ "cg-lane-header"
      assert attr(header, "class") |> hd() =~ "sticky"
      assert attr(header, "class") |> hd() =~ "top-0"
      assert attr(header, "style") == ["width: #{@happy_gutter_w}px"]

      # The neutral lane 0 (unowned pre-task nodes exist): a NON-clickable span.
      [neutral] = Floki.find(tree, "#cg-lane-#{dom}-0")
      assert {"span", _, _} = neutral
      assert attr(neutral, "class") |> hd() =~ "cg-lane-chip-neutral"
      assert attr(neutral, "phx-click") == []
      assert text(neutral) == "Pre-task"
      assert attr(neutral, "title") == ["Pre-task"]

      # Agent lanes: clickable buttons labelled T<task_local_id> in the depth
      # hue, anchored at the lane's dot-x (48 / 72).
      [chip_a1] = Floki.find(tree, "#cg-lane-#{dom}-1")
      assert {"button", _, _} = chip_a1
      assert attr(chip_a1, "class") |> hd() =~ "cg-lane-chip"
      refute attr(chip_a1, "class") |> hd() =~ "cg-lane-chip-neutral"
      assert attr(chip_a1, "phx-click") == ["select_agent"]
      assert attr(chip_a1, "phx-value-id") == ["a1"]

      assert attr(chip_a1, "style") == [
               "position: absolute; left: 48px; transform: translateX(-50%); border-color: #{@depth0_color}; color: #{@depth0_color}; opacity: 1"
             ]

      assert Floki.text(chip_a1) =~ "T1"
      assert attr(chip_a1, "title") == ["T1 · Running"]

      [chip_a2] = Floki.find(tree, "#cg-lane-#{dom}-2")
      assert attr(chip_a2, "phx-value-id") == ["a2"]
      assert attr(chip_a2, "style") |> hd() =~ "left: 72px"
      assert attr(chip_a2, "style") |> hd() =~ "border-color: #{@depth1_color}"
      assert Floki.text(chip_a2) =~ "T2"

      # Exactly one chip per lane.
      assert Floki.find(tree, ".cg-lane-chip") |> length() == 3
    end

    test "the agent chip's status dot reuses the shared status svg colour" do
      {_repo, dom, tree} = happy()

      # a1 is :running → success; a2 is :completed → muted base ink.
      assert Helpers.agent_status_svg_color(:running) == "var(--color-success)"
      assert Helpers.agent_status_svg_color(:completed) == "var(--color-base-content)"

      [chip_a1] = Floki.find(tree, "#cg-lane-#{dom}-1")
      assert [dot] = Floki.find(chip_a1, "span[style*='background-color']")
      assert attr(dot, "style") == ["background-color: var(--color-success)"]

      [chip_a2] = Floki.find(tree, "#cg-lane-#{dom}-2")
      assert [dot2] = Floki.find(chip_a2, "span[style*='background-color']")
      assert attr(dot2, "style") == ["background-color: var(--color-base-content)"]
    end

    test "the neutral chip is absent when no unowned nodes exist / lane 0 is claimed" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", owner_id: "hand1", column: 0, row: 0)],
          agents: [agent_map(lane: 0)]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      # Lane 0 is claimed by the agent → a button, never a "Pre-task" span.
      assert [chip0] = Floki.find(tree, "#cg-lane-#{dom}-0")
      assert {"button", _, _} = chip0
      assert Floki.find(tree, ".cg-lane-chip-neutral") == []
      refute Floki.text(tree) =~ "Pre-task"
    end

    test "an agent lane with NO nodes still gets its chip (and widens the gutter)" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", column: 1, row: 0, owner_id: "a1")],
          edges: [],
          agents: [
            agent_map(agent_id: "a1", lane: 1),
            agent_map(agent_id: "ghost9", task_local_id: 9, lane: 2)
          ]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      assert [chip] = Floki.find(tree, "#cg-lane-#{dom}-2")
      assert {"button", _, _} = chip
      assert Floki.text(chip) =~ "T9"
      assert attr(chip, "phx-value-id") == ["ghost9"]

      # The node-less lane still contributes a gutter column: lanes 0..2 → 96.
      [gutter] = Floki.find(tree, "#cg-gutter-#{dom}")
      assert attr(gutter, "width") == ["96"]
    end

    test "chips stagger over two header rows so adjacent lanes never collide" do
      {_repo, dom, tree} = happy()

      [header] = Floki.find(tree, "#cg-lane-header-#{dom}")

      # Even lanes (0, 2) on chip row 0, odd lanes (1) on chip row 1 — two
      # 18px strips inside the header.
      strips = Floki.find(header, "div.absolute")
      assert length(strips) == 2

      assert Enum.sort(Enum.map(strips, &(attr(&1, "style") |> hd()))) ==
               Enum.sort(["top: 0px; height: 18px", "top: 18px; height: 18px"])

      # Lane 0 (even) sits in the top strip; lane 1 (odd) in the bottom one.
      [top, bottom] = Enum.sort_by(strips, &(attr(&1, "style") |> hd()))
      assert Floki.find(top, "#cg-lane-#{dom}-0") != []
      assert Floki.find(top, "#cg-lane-#{dom}-2") != []
      assert Floki.find(bottom, "#cg-lane-#{dom}-1") != []
    end
  end

  describe "commit_graph_view/1 — edges" do
    test "one path.cg-edge per model edge, with a stable, kind-dependent id" do
      {repo, dom, tree} = happy()

      edges = Floki.find(tree, "path.cg-edge")

      assert length(edges) == length(repo.edges)
      assert Enum.all?(edges, &(attr(&1, "data-commit-graph-anim") == ["edge"]))
      assert Enum.all?(edges, &(attr(&1, "fill") == ["none"]))

      ids = Enum.map(edges, &(attr(&1, "id") |> hd()))

      expected = for e <- repo.edges, do: edge_id(dom, e)
      assert ids == expected
      assert ids == Enum.uniq(ids)
    end

    test "a same-lane edge is a plain straight vertical line with no bend" do
      {_repo, dom, tree} = happy()

      # c1 → b1, both on lane 1, rows 2 → 1: x = 48 the whole way.
      [el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c1}-#{@sha_b1}")

      assert attr(el, "d") == ["M 48 110 L 48 66"]
      refute attr(el, "d") |> hd() =~ "Q"
    end

    test "a cross-lane edge routes orthogonally with ROUNDED Q corners" do
      {_repo, dom, tree} = happy()

      # b1 (lane 1, row 1) → p1 (lane 0, row 0): 48,66 → 24,22 with 7px
      # quarter-turns at the y-midpoint 44.
      [el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_b1}-#{@sha_p1}")

      assert attr(el, "d") == ["M 48 66 L 48 51 Q 48 44 41 44 L 31 44 Q 24 44 24 37 L 24 22"]
    end

    test "NO edge ever carries the sharp double-corner orthogonal signature" do
      {_repo, _dom, tree} = happy()

      # The legacy 4-point route `M .. L .. L .. L ..` had two sharp 90°
      # corners (three consecutive L commands); the rounded router emits at
      # most isolated `L` segments separated by `Q` turns.
      for el <- Floki.find(tree, "path.cg-edge") do
        d = attr(el, "d") |> hd()
        refute d =~ ~r/L \S+ \S+ L \S+ \S+ L \S+ \S+/, "sharp corners in: #{d}"
      end
    end

    test "a parent edge is solid width 2; merge / spawn / merge_back are dashed 4 3" do
      {_repo, dom, tree} = happy()

      [parent_el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_b1}-#{@sha_p1}")
      assert attr(parent_el, "stroke-width") == ["2"]
      assert attr(parent_el, "stroke-dasharray") == []

      [merge_el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c1}-#{@sha_p1}")
      assert attr(merge_el, "stroke-width") == ["1.6"]
      assert attr(merge_el, "stroke-dasharray") == ["4 3"]

      [spawn_el] = Floki.find(tree, "#commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}")
      assert attr(spawn_el, "stroke-width") == ["1.6"]
      assert attr(spawn_el, "stroke-dasharray") == ["4 3"]

      [back_el] = Floki.find(tree, "#commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6")
      assert attr(back_el, "stroke-width") == ["1.6"]
      assert attr(back_el, "stroke-dasharray") == ["4 3"]
    end

    test "a spawn edge departs BELOW its fork node and lands on the child lane" do
      {_repo, dom, tree} = happy()

      [el] = Floki.find(tree, "#commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}")
      d = attr(el, "d") |> hd()

      # The fork node c2 sits at (48, 154); the connector's M y is
      # 154 + node_r(6) + exit_gap(2) = 162 — below the dot's center-y.
      {mx, my} = path_start(d)
      assert {mx, my} == {48, 162}
      assert my > 154

      # It crosses into lane 2 (x 72) and lands on c3's center-y 198 with
      # rounded bends (fy=162, ty=198 → midpoint 180).
      assert d == "M 48 162 L 48 173 Q 48 180 55 180 L 65 180 Q 72 180 72 187 L 72 198"
    end

    test "a merge_back edge to a VIRTUAL landing renders from to_column/to_row" do
      {_repo, dom, tree} = happy()

      # to_sha is nil → the id carries the "l<col>r<row>" landing key and the
      # path ends at the parent lane's coordinates (48, 286), departing below
      # the child tip c4 (72, 242 → start y 250).
      [el] = Floki.find(tree, "#commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6")

      assert attr(el, "d") == [
               "M 72 250 L 72 261 Q 72 268 65 268 L 55 268 Q 48 268 48 275 L 48 286"
             ]

      assert attr(el, "id") == ["commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6"]
    end

    test "the stroke is the owner's depth hue; an unowned edge is muted" do
      {repo, dom, tree} = happy()

      # a2 (depth 1) owns its lane's parent edge AND the agent-level connectors.
      for edge <- repo.edges, edge.owner_id == "a2" do
        [el] = Floki.find(tree, "##{edge_id(dom, edge)}")
        assert attr(el, "style") == ["stroke: #{@depth1_color}; stroke-opacity: 0.75"]
      end

      # A parent edge owned by a1 carries a1's depth-0 hue.
      [a1_el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c2}-#{@sha_c1}")
      assert attr(a1_el, "style") == ["stroke: #{@depth0_color}; stroke-opacity: 0.75"]

      # An edge whose owner is not one of the repo's agents stays muted base ink.
      bare =
        repo_view(
          edges: [edge_view(from_sha: "x0000001", to_sha: "y0000001", owner_id: "ghost")],
          nodes: [node_view(sha: "n0000001", owner_id: nil)]
        )

      bare_tree = parse(render_repos([bare]))

      [ghost_el] = Floki.find(bare_tree, "#commit-edge-#{bare.repo_dom_id}-x0000001-y0000001")

      assert attr(ghost_el, "style") == [
               "stroke: var(--color-base-content); stroke-opacity: 0.3"
             ]
    end

    test "an edge endpoint falls back to the edge's own column/row when the node is absent" do
      repo =
        repo_view(
          edges: [
            edge_view(from_sha: "x", from_column: 1, from_row: 3, to_column: 0, to_row: 0)
          ],
          nodes: [node_view(sha: "unrelated", column: 0, row: 0)]
        )

      tree = parse(render_repos([repo]))
      [el] = Floki.find(tree, "path.cg-edge")

      # dot_x(1) = 48, dot_y(3) = 154 → dot_x(0) = 24, dot_y(0) = 22, rounded
      # at the y-midpoint 88.
      assert attr(el, "d") == ["M 48 154 L 48 95 Q 48 88 41 88 L 31 88 Q 24 88 24 81 L 24 22"]
    end

    test "an edge whose endpoints collapse is omitted" do
      repo =
        repo_view(
          edges: [edge_view(from_sha: "aaaa0000", to_sha: "aaaa0000")],
          nodes: [node_view(sha: "aaaa0000", column: 0, row: 0)]
        )

      tree = parse(render_repos([repo]))
      assert Floki.find(tree, "path.cg-edge") == []
    end
  end

  describe "commit_graph_view/1 — nodes" do
    test "one g.cg-node per node, carrying data attrs, a tooltip and the dot geometry" do
      {repo, dom, tree} = happy()

      nodes = Floki.find(tree, "g.cg-node")

      assert length(nodes) == length(repo.nodes)
      assert Enum.all?(nodes, &(attr(&1, "data-commit-graph-anim") == ["node"]))

      for node <- repo.nodes do
        assert Floki.find(tree, "#commit-node-#{dom}-#{node.sha}") != []
      end

      # The row 2 / lane 1 commit: a CIRCLE centred at x = 48, y = 2*44+22 =
      # 110, radius 6.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")
      assert attr(dot, "cx") == ["48"]
      assert attr(dot, "cy") == ["110"]
      assert attr(dot, "r") == ["6"]

      # The row 4 / lane 2 commit: cx = 72, cy = 198.
      [c3_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-node-dot")
      assert attr(c3_dot, "cx") == ["72"]
      assert attr(c3_dot, "cy") == ["198"]
    end

    test "an owned node is filled with its owner's depth hue" do
      {_repo, dom, tree} = happy()

      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")

      assert attr(dot, "style") == [
               "fill: #{@depth0_color}; fill-opacity: 1; stroke: #{@depth0_color}"
             ]
    end

    test "an owner's END commit takes the shared status colour" do
      {_repo, dom, tree} = happy()

      # c2000000 is a1's end commit; a1 is :running → the shared status colour.
      assert Helpers.agent_status_svg_color(:running) == "var(--color-success)"

      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2} circle.cg-node-dot")

      assert attr(dot, "style") == [
               "fill: var(--color-success); fill-opacity: 1; stroke: var(--color-success)"
             ]
    end

    test "a base node is a hollow smaller circle, with a 'base' tooltip prefix" do
      {_repo, dom, tree} = happy()

      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_b1} circle.cg-node-dot")

      assert attr(dot, "cx") == ["48"]
      assert attr(dot, "cy") == ["66"]
      assert attr(dot, "r") == ["4"]

      assert attr(dot, "style") == [
               "fill: none; fill-opacity: 1; stroke: var(--color-base-content)"
             ]

      title = node_title(tree, "commit-node-#{dom}-#{@sha_b1}")
      assert title =~ "base"
    end

    test "a noop stub renders exactly like a base stub, labelled 'no-op'" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", kind: :noop, message: nil, author_name: nil)],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      [dot] = Floki.find(tree, "#commit-node-#{dom}-n0000001 circle.cg-node-dot")
      assert attr(dot, "r") == ["4"]

      assert attr(dot, "style") == [
               "fill: none; fill-opacity: 1; stroke: var(--color-base-content)"
             ]

      [row] = Floki.find(tree, ".cg-row")
      assert text(Floki.find(row, ".cg-base-label")) == "no-op"
      assert Floki.find(row, ".cg-row-message") == []

      assert node_title(tree, "commit-node-#{dom}-n0000001") == "no-op · n0000001"
    end

    test "an unowned node is muted base ink at reduced opacity" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", owner_id: nil)],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([repo]))
      [dot] = Floki.find(tree, "#commit-node-#{repo.repo_dom_id}-n0000001 circle.cg-node-dot")

      assert attr(dot, "style") == [
               "fill: var(--color-base-content); fill-opacity: 0.55; stroke: var(--color-base-content)"
             ]
    end

    test "the node tooltip joins message · sha · author · date · refs" do
      {_repo, dom, tree} = happy()

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c1}") ==
               "Merge pre-task history · c1000000 · Alice · 2024-01-01 10:00"

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c4}") ==
               "Refactor Z · c4000000 · Dave · 2024-01-03 10:00 · HEAD, genesis/agent_x"

      # The base node has no author/date/refs.
      assert node_title(tree, "commit-node-#{dom}-#{@sha_b1}") == "base · b1000000"
    end
  end

  describe "commit_graph_view/1 — rows" do
    test "a row carries the select_agent contract for an owned node" do
      {_repo, dom, tree} = happy()

      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")

      assert attr(row, "phx-click") == ["select_agent"]
      assert attr(row, "phx-value-id") == ["a1"]
      assert attr(row, "data-cg-sha") == [@sha_c1]
      assert attr(row, "data-cg-agent-id") == ["a1"]
    end

    test "a row shows the short sha, the first message line and 'author · date'" do
      {_repo, dom, tree} = happy()

      # c1000000's raw message carries a body line — only the first line renders.
      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")

      assert text(Floki.find(row, ".cg-row-sha")) == "c1000000"
      assert text(Floki.find(row, ".cg-row-message")) == "Merge pre-task history"
      assert text(Floki.find(row, ".cg-row-meta")) == "Alice · 2024-01-01 10:00"
    end

    test "a base node row shows the 'base' chip and no message" do
      {_repo, dom, tree} = happy()

      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_b1}")

      assert text(Floki.find(row, ".cg-base-label")) == "base"
      assert Floki.find(row, ".cg-row-message") == []
      assert Floki.find(row, ".cg-row-meta") == []
    end

    test "an unowned row omits the click contract but keeps a stable id" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000002", owner_id: nil)],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([repo]))
      [row] = Floki.find(tree, ".cg-row")

      assert attr(row, "id") == ["commit-row-#{repo.repo_dom_id}-n0000002"]
      assert attr(row, "phx-click") == []
      assert attr(row, "phx-value-id") == []
      assert attr(row, "data-cg-agent-id") == []
    end
  end

  describe "commit_graph_view/1 — tags" do
    test "start_ids render solid 'start' chips and end_ids dashed 'end' chips" do
      {_repo, dom, tree} = happy()

      # c2000000 is a1's END commit AND a2's START commit (a fork point).
      [start_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_c2}-start-a2")
      assert attr(start_chip, "class") |> hd() =~ "cg-agent-tag-start"
      assert attr(start_chip, "class") |> hd() =~ "border-solid"
      assert attr(start_chip, "phx-click") == ["select_agent"]
      assert attr(start_chip, "phx-value-id") == ["a2"]

      assert attr(start_chip, "style") == [
               "border-color: #{@depth1_color}; color: #{@depth1_color}"
             ]

      assert Floki.text(start_chip) =~ "T2"
      assert Floki.text(start_chip) =~ "start"

      [end_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_c2}-end-a1")
      assert attr(end_chip, "class") |> hd() =~ "cg-agent-tag-end"
      assert attr(end_chip, "class") |> hd() =~ "border-dashed"
      assert attr(end_chip, "phx-value-id") == ["a1"]

      assert attr(end_chip, "style") == [
               "border-color: #{@depth0_color}; color: #{@depth0_color}"
             ]

      assert Floki.text(end_chip) =~ "T1"
      assert Floki.text(end_chip) =~ "end"

      # a1 forks at the base node → a start tag there.
      [base_start] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_b1}-start-a1")
      assert attr(base_start, "phx-value-id") == ["a1"]
    end

    test "an agent tag tooltip joins label · marker · status" do
      {_repo, dom, tree} = happy()

      [start_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_c2}-start-a2")
      assert attr(start_chip, "title") == ["T2 · start · Completed"]

      [end_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_c2}-end-a1")
      assert attr(end_chip, "title") == ["T1 · end · Running"]
    end

    test "refs render as non-clickable mono chips" do
      {_repo, dom, tree} = happy()

      refs = Floki.find(tree, "span.cg-ref-tag")
      assert length(refs) == 2

      [head] = Floki.find(tree, "#commit-ref-tag-#{dom}-#{@sha_c4}-HEAD")
      assert text(head) == "HEAD"
      assert attr(head, "title") == ["HEAD"]
      assert attr(head, "phx-click") == []

      # A slash in the ref name is folded to a dash in the id.
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-#{@sha_c4}-genesis-agent_x") != []
    end

    test "an agent tag for an unknown agent id falls back to the raw id + muted colour" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", start_ids: ["ghost"])],
          agents: []
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      [chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-n0000001-start-ghost")
      assert Floki.text(chip) =~ "Tghost"

      assert attr(chip, "style") == [
               "border-color: var(--color-base-content); color: var(--color-base-content)"
             ]

      assert attr(chip, "phx-value-id") == ["ghost"]
    end

    test "a node with no start/end/ref tags renders no tag row" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001")],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([repo]))
      [row] = Floki.find(tree, ".cg-row")

      assert Floki.find(row, ".cg-agent-tag") == []
      assert Floki.find(row, ".cg-ref-tag") == []
    end
  end

  describe "commit_graph_view/1 — selection" do
    test "the readout names the selected agent with its start → end short shas" do
      {_repo, dom, tree} = happy_selected("a2")

      [readout] = Floki.find(tree, "#cg-selection-readout-#{dom}")
      assert Floki.text(readout) =~ "Selected T2 · c3000000 → c4000000"
    end

    test "the readout is omitted when nothing is selected or the selection is foreign" do
      {_repo, dom, tree} = happy()
      assert Floki.find(tree, "#cg-selection-readout-#{dom}") == []

      {_repo2, dom2, tree2} = happy_selected("someone-else")
      assert Floki.find(tree2, "#cg-selection-readout-#{dom2}") == []
    end

    test "the selected agent's START dot wears a SOLID ring and its END dot a DASHED ring" do
      {_repo, dom, tree} = happy_selected("a2")

      # c2000000 is a2's start (its fork point, on a1's lane) → solid ring at
      # (48, 154) with r = 6 + 3 = 9.
      [start_ring] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2} circle.cg-node-ring")
      assert attr(start_ring, "cx") == ["48"]
      assert attr(start_ring, "cy") == ["154"]
      assert attr(start_ring, "r") == ["9"]
      assert attr(start_ring, "stroke-dasharray") == []
      assert attr(start_ring, "style") == ["fill: none; stroke: var(--color-primary)"]

      # c4000000 is a2's end → dashed ring at (72, 242).
      [end_ring] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c4} circle.cg-node-ring")
      assert attr(end_ring, "cx") == ["72"]
      assert attr(end_ring, "cy") == ["242"]
      assert attr(end_ring, "r") == ["9"]
      assert attr(end_ring, "stroke-dasharray") == ["3 2"]

      # No other node is ringed.
      assert Floki.find(tree, "circle.cg-node-ring") |> length() == 2
    end

    test "the selected agent's start/end rows are accented and carry a start/end marker" do
      {_repo, dom, tree} = happy_selected("a2")

      [start_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c2}")
      assert attr(start_row, "class") |> hd() =~ "ring-1 ring-inset ring-primary/40"
      assert Floki.text(Floki.find(start_row, ".cg-row-marker")) =~ "start"

      [end_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c4}")
      assert attr(end_row, "class") |> hd() =~ "ring-primary/40"
      assert Floki.text(Floki.find(end_row, ".cg-row-marker")) =~ "end"
      # The end row is owned by the selected agent → also gets the bg accent.
      assert attr(end_row, "class") |> hd() =~ "bg-primary/10"

      # Unrelated rows carry neither accent.
      [other] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")
      refute attr(other, "class") |> hd() =~ "ring-primary/40"
      assert Floki.find(other, ".cg-row-marker") == []
    end
  end

  describe "commit_graph_view/1 — ended dimming" do
    test "an ended agent's nodes, edges, rows and lane chip render dim" do
      {_repo, dom, tree} = happy_ended()

      # a2's owned node dots drop to half fill-opacity …
      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-node-dot")

      assert attr(dot, "style") == [
               "fill: #{@depth1_color}; fill-opacity: 0.5; stroke: #{@depth1_color}"
             ]

      # … its owned edges lose stroke-opacity (agent-level connectors included) …
      [edge] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c4}-#{@sha_c3}")
      assert attr(edge, "style") == ["stroke: #{@depth1_color}; stroke-opacity: 0.4"]

      [spawn] = Floki.find(tree, "#commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}")
      assert attr(spawn, "style") |> hd() =~ "stroke-opacity: 0.4"

      # … its rows dim …
      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c3}")
      assert attr(row, "class") |> hd() =~ "opacity-50"

      # … and its lane chip dims too.
      [chip] = Floki.find(tree, "#cg-lane-#{dom}-2")
      assert attr(chip, "style") |> hd() =~ "opacity: 0.5"
      assert attr(chip, "title") == ["T2 · Completed · terminated"]

      # The live agent (a1) is untouched.
      [live_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")
      assert attr(live_dot, "style") |> hd() =~ "fill-opacity: 1"

      [live_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")
      refute attr(live_row, "class") |> hd() =~ "opacity-50"

      [live_chip] = Floki.find(tree, "#cg-lane-#{dom}-1")
      assert attr(live_chip, "style") |> hd() =~ "opacity: 1"
    end

    test "an agent without the OPTIONAL ended flag renders identically to ended: false" do
      {_repo, dom, tree} = happy()

      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")
      assert attr(dot, "style") |> hd() =~ "fill-opacity: 1"
    end
  end

  describe "commit_graph_view/1 — total / defensive degradation" do
    test "non-map repo entries are dropped; odd repo-level fields fold" do
      repo =
        repo_view(
          nodes: ["not-a-map", node_view(sha: "n0000001")],
          edges: [
            nil,
            edge_view(from_sha: "n0000001", to_sha: "n0000002", to_column: 1, to_row: 2)
          ],
          agents: [:nope, agent_map([])]
        )

      tree = parse(render_repos([repo, "junk", 42]))

      assert Floki.find(tree, "svg.cg-gutter") != []
      assert Floki.find(tree, ".cg-row") |> length() == 1
      assert Floki.find(tree, "path.cg-edge") |> length() == 1
    end

    test "non-list nodes/edges/agents fold to empty" do
      tree = parse(render_repos([repo_view(nodes: :nope, edges: nil, agents: %{})]))

      assert Floki.find(tree, ".cg-empty-note") != []
      assert Floki.find(tree, ".cg-row") == []
    end

    test "odd grid values and non-binary shas degrade without crashing" do
      repo =
        repo_view(
          nodes: [
            node_view(sha: 42, column: :garbage, row: nil),
            node_view(sha: "z0000001", column: "1", row: 3)
          ],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      # A non-binary sha still gets a stable, DOM-safe element id.
      assert Floki.find(tree, "#commit-node-#{dom}-42") != []
      assert Floki.find(tree, "#commit-row-#{dom}-z0000001") != []

      # Non-integer grid coordinates fold to lane 0 / row 0 → the dot circle is
      # centred at (24, 22) with radius 6.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-42 circle.cg-node-dot")
      assert attr(dot, "cx") == ["24"]
      assert attr(dot, "cy") == ["22"]
      assert attr(dot, "r") == ["6"]
    end

    test "an integer agent/owner id yields a DOM-safe id fragment" do
      repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", owner_id: 42, start_ids: [42])],
          agents: [agent_map(agent_id: 42, task_local_id: 5)]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      assert Floki.find(tree, "#commit-row-#{dom}-n0000001") != []
      assert Floki.find(tree, "#commit-agent-tag-#{dom}-n0000001-start-42") != []

      assert Floki.find(tree, "#commit-row-#{dom}-n0000001") |> hd() |> attr("phx-value-id") ==
               ["42"]
    end

    test "refs of odd shapes are read totally" do
      repo =
        repo_view(
          nodes: [
            node_view(sha: "n0000001", refs: ["main", 42, %{name: "x"}, %{"name" => "y"}, "main"])
          ],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      # String refs are de-duped; a map-name form is read from atom OR string
      # keys; a non-string/atom term is dropped (never raises).
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-n0000001-main") != []
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-n0000001-x") != []
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-n0000001-y") != []
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-n0000001-42") == []
      assert Floki.find(tree, "span.cg-ref-tag") |> length() == 3
    end
  end

  # --- fixtures --------------------------------------------------------------
  #
  # ALL fixtures are hand-crafted against the v2 per-agent-lane model contract
  # (NOT derived from `CommitGraph.build/2` — see the module doc).

  # The main happy-path fixture: 3 lanes —
  #   lane 0 = neutral "pre-task" (the unowned p1),
  #   lane 1 = agent a1 (depth 0, :running; base stub b1 → c1 → c2 tip; c1 is a
  #            merge commit folding in p1),
  #   lane 2 = agent a2 (depth 1, :completed; spawned at c2, commits c3 → c4,
  #            merged back into lane 1 at a VIRTUAL landing below c2).
  # Rows are globally interleaved 0..5; the merge-back landing adds row 6.
  defp happy_repos do
    [
      repo_view(
        repo_dom_id: @dom,
        repo_name: "My Project",
        column_count: 3,
        node_count: 6,
        edge_count: 7,
        row_count: 7,
        nodes: [
          node_view(
            sha: @sha_p1,
            message: "Pre-task commit",
            author_name: "Pam",
            date: ~U[2023-12-31 09:00:00Z],
            column: 0,
            row: 0,
            owner_id: nil
          ),
          node_view(
            sha: @sha_b1,
            message: nil,
            author_name: nil,
            date: nil,
            column: 1,
            row: 1,
            kind: :base,
            owner_id: "a1",
            start_ids: ["a1"]
          ),
          node_view(
            sha: @sha_c1,
            message: "Merge pre-task history\n\nbody line",
            author_name: "Alice",
            date: ~U[2024-01-01 10:00:00Z],
            column: 1,
            row: 2,
            owner_id: "a1"
          ),
          node_view(
            sha: @sha_c2,
            message: "Fix bug Y",
            author_name: "Bob",
            date: ~U[2024-01-02 10:00:00Z],
            column: 1,
            row: 3,
            owner_id: "a1",
            end_ids: ["a1"],
            start_ids: ["a2"]
          ),
          node_view(
            sha: @sha_c3,
            message: "Side change W",
            author_name: "Carol",
            date: ~U[2024-01-02 12:00:00Z],
            column: 2,
            row: 4,
            owner_id: "a2"
          ),
          node_view(
            sha: @sha_c4,
            message: "Refactor Z",
            author_name: "Dave",
            date: ~U[2024-01-03 10:00:00Z],
            column: 2,
            row: 5,
            owner_id: "a2",
            end_ids: ["a2"],
            refs: ["HEAD", "genesis/agent_x"]
          )
        ],
        edges: [
          edge_view(
            from_sha: @sha_b1,
            to_sha: @sha_p1,
            from_column: 1,
            from_row: 1,
            to_column: 0,
            to_row: 0,
            kind: :parent,
            owner_id: "a1"
          ),
          edge_view(
            from_sha: @sha_c1,
            to_sha: @sha_b1,
            from_column: 1,
            from_row: 2,
            to_column: 1,
            to_row: 1,
            kind: :parent,
            owner_id: "a1"
          ),
          edge_view(
            from_sha: @sha_c1,
            to_sha: @sha_p1,
            from_column: 1,
            from_row: 2,
            to_column: 0,
            to_row: 0,
            kind: :merge,
            owner_id: "a1"
          ),
          edge_view(
            from_sha: @sha_c2,
            to_sha: @sha_c1,
            from_column: 1,
            from_row: 3,
            to_column: 1,
            to_row: 2,
            kind: :parent,
            owner_id: "a1"
          ),
          edge_view(
            from_sha: @sha_c2,
            to_sha: @sha_c3,
            from_column: 1,
            from_row: 3,
            to_column: 2,
            to_row: 4,
            kind: :spawn,
            owner_id: "a2"
          ),
          edge_view(
            from_sha: @sha_c4,
            to_sha: nil,
            from_column: 2,
            from_row: 5,
            to_column: 1,
            to_row: 6,
            kind: :merge_back,
            owner_id: "a2"
          ),
          edge_view(
            from_sha: @sha_c4,
            to_sha: @sha_c3,
            from_column: 2,
            from_row: 5,
            to_column: 2,
            to_row: 4,
            kind: :parent,
            owner_id: "a2"
          )
        ],
        agents: [
          agent_map(
            agent_id: "a1",
            task_local_id: 1,
            status: :running,
            depth: 0,
            color: @depth0_color,
            start_sha: @sha_b1,
            end_sha: @sha_c2,
            lane: 1,
            parent_id: nil
          ),
          agent_map(
            agent_id: "a2",
            task_local_id: 2,
            status: :completed,
            depth: 1,
            color: @depth1_color,
            start_sha: @sha_c3,
            end_sha: @sha_c4,
            lane: 2,
            parent_id: "a1"
          )
        ]
      )
    ]
  end

  # A second, independent repo (a single unowned commit on the neutral lane)
  # for the multi-repo rendering assertions.
  defp happy_two_repo_fixture do
    [
      repo_view(
        repo_dom_id: "commit-graph-repo-foreign-2",
        repo_name: "foreign-repo",
        column_count: 1,
        node_count: 1,
        row_count: 1,
        edge_count: 0,
        nodes: [
          node_view(
            sha: "f1000000",
            message: "Foreign commit",
            author_name: "Zoe",
            date: ~U[2024-01-04 10:00:00Z],
            column: 0,
            row: 0,
            owner_id: nil
          )
        ],
        edges: [],
        agents: []
      )
    ]
  end

  # Hand-crafted repo/node/edge/agent maps for shapes the happy fixture does
  # not cover (odd/absent geometry, a fixed DOM id, unowned entries and
  # non-map entries).
  defp repo_view(overrides) do
    Map.merge(
      %{
        repo_key: "primary",
        repo_dom_id: "commit-graph-repo-handcrafted-1",
        repo_name: "Primary Repo",
        node_count: 0,
        edge_count: 0,
        row_count: 0,
        column_count: 1,
        nodes: [],
        edges: [],
        agents: []
      },
      Map.new(overrides)
    )
  end

  # `short_sha` defaults to the sha's first 8 chars (the model's convention),
  # so the rendered short sha IS the fixture sha; an explicit short_sha wins.
  defp node_view(overrides) do
    merged =
      Map.merge(
        %{
          sha: "deadbeef",
          short_sha: nil,
          message: "A commit",
          author_name: "Ann",
          date: nil,
          refs: [],
          row: 0,
          column: 0,
          depth: 0,
          kind: :commit,
          owner_id: "hand1",
          start_ids: [],
          end_ids: []
        },
        Map.new(overrides)
      )

    case merged do
      %{short_sha: ss} when is_binary(ss) and ss != "" -> merged
      %{short_sha: nil} -> %{merged | short_sha: String.slice(to_string(merged.sha), 0, 8)}
    end
  end

  defp edge_view(overrides) do
    Map.merge(
      %{
        from_sha: "aaaa0000",
        to_sha: "bbbb0000",
        from_column: 0,
        from_row: 1,
        to_column: 0,
        to_row: 0,
        kind: :parent,
        owner_id: "hand1"
      },
      Map.new(overrides)
    )
  end

  defp agent_map(overrides) do
    Map.merge(
      %{
        agent_id: "hand1",
        task_local_id: 7,
        status: :running,
        depth: 0,
        color: "#123456",
        start_sha: nil,
        end_sha: nil,
        ended: false,
        lane: 0,
        parent_id: nil
      },
      Map.new(overrides)
    )
  end

  # --- render + Floki helpers (file-local by convention) ---

  defp render_repos(repos, opts \\ []) do
    render_component(&CommitGraphView.commit_graph_view/1,
      repos: repos,
      selected_id: Keyword.get(opts, :selected_id),
      loading: Keyword.get(opts, :loading, false),
      error: Keyword.get(opts, :error),
      node_key: Keyword.get(opts, :node_key, "local")
    )
  end

  defp parse(html), do: Floki.parse_document!(html)

  # The stable repo DOM id.
  defp dom_id(repos), do: repos |> hd() |> Map.fetch!(:repo_dom_id)

  # The edge's DOM id: commit → parent kinds keep `<from>-<to>`; the
  # agent-level kinds carry `<kind>-<owner>-<from>-<to>` with the
  # `l<col>r<row>` landing key for a virtual merge-back.
  defp edge_id(dom, edge) do
    case edge.kind do
      kind when kind in [:spawn, :merge_back] ->
        to_key =
          case edge.to_sha do
            nil -> "l#{edge.to_column}r#{edge.to_row}"
            sha -> sha
          end

        "commit-edge-#{dom}-#{kind}-#{edge.owner_id}-#{edge.from_sha}-#{to_key}"

      _kind ->
        "commit-edge-#{dom}-#{edge.from_sha}-#{edge.to_sha}"
    end
  end

  # The numeric (x, y) of a path's `M x y` start.
  defp path_start(d) do
    [_, x, y] = Regex.run(~r/^M (\S+) (\S+)/, d)
    {String.to_integer(x), String.to_integer(y)}
  end

  # Every element node among a parent's children (whitespace text nodes dropped).
  defp element_children(el) do
    el
    |> Floki.children()
    |> Enum.filter(fn
      {tag, _attrs, _kids} when is_binary(tag) -> true
      _ -> false
    end)
  end

  # The happy fixture repo, its DOM id and its parsed render — the three things
  # almost every assertion in this file needs.
  defp happy do
    repos = happy_repos()
    {hd(repos), dom_id(repos), parse(render_repos(repos))}
  end

  # ... with a2 flagged `ended: true` (a RETAINED / terminated in-session agent).
  defp happy_ended do
    repos = mark_agent_ended(happy_repos(), "a2")
    {hd(repos), dom_id(repos), parse(render_repos(repos))}
  end

  defp mark_agent_ended(repos, agent_id) do
    Enum.map(repos, fn repo ->
      Map.update!(repo, :agents, fn agents ->
        Enum.map(agents, fn agent ->
          if Map.get(agent, :agent_id) == agent_id, do: Map.put(agent, :ended, true), else: agent
        end)
      end)
    end)
  end

  defp happy_selected(selected_id) do
    repos = happy_repos()
    {hd(repos), dom_id(repos), parse(render_repos(repos, selected_id: selected_id))}
  end

  defp node_title(tree, id) do
    [el] = Floki.find(tree, "##{id}")
    el |> Floki.find("title") |> Floki.text()
  end

  # `Floki.text/1` preserves the template's surrounding whitespace, so exact
  # leaf-text comparisons go through this trimmed variant.
  defp text(el_or_els), do: el_or_els |> Floki.text() |> String.trim()

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end
end
