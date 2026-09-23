defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView` — the
  TEMPORAL (git commit history) view of the Agents page left panel.

  `commit_graph_view/1` is purely presentational: it renders the per-repo graph
  view models assembled by the pure `EvoDashWeb.AgentsLive.CommitGraph.build/2`
  as a COMMIT-CENTRIC HORIZONTAL SVG DAG (commits are nodes on a grid, one lane
  row per agent) and fires the existing `select_agent` event from both the node
  groups and the lane groups. These tests render it in isolation with
  `render_component/2` (no `live/3` — matching the rest of this directory) and
  pin the frozen DOM contract consumed by the client-side `CommitGraph` hook /
  CSS animation:

    * `#commit-graph` + `phx-hook="CommitGraph"` → the node-scoped body
      `#commit-graph-body-<node_key>` → one section per repo whose id IS the
      builder's `repo_dom_id` VERBATIM (no extra prefix) with a name header;
    * `.cg-graph[data-cg-repo-id]` → the zoom toolbar (`data-cg-action="zoom-in|
      zoom-out|fit"` + an intentionally EMPTY `.cg-zoom-readout` the hook writes
      into) → `svg.cg-svg[viewBox]` whose SOLE child is `g.cg-viewport` holding
      edges → nodes → lanes (paint order);
    * `path.cg-edge[data-commit-graph-anim="edge"]` child → parent beziers (a
      `:merge` edge dashed, a `:parent` edge solid, stroked with the child
      owner's depth hue);
    * `g.cg-node[data-commit-graph-anim="node"]` with `data-cg-agent-id` /
      `data-cg-sha`, an inner `<title>` tooltip and the `select_agent` contract
      (omitted for an unowned node);
    * `g.cg-lane[data-commit-graph-anim="lane"]` with the stable anchor id
      `#commit-agent-row-<repo_dom_id>-<agent_id>`, an inner `<title>`, the
      `#commit-lane-<dom>-<id>` band and the `T<task_local_id>` label;
    * selection (`selected_id`) rings the selected agent's START (solid) and END
      (dashed) nodes, tints its lane band and renders the
      `#cg-selection-readout-<dom>` annotation;
    * the `:loading` / `:empty` / `:error` / stale-warning states.

  The main happy-path fixture is REAL `CommitGraph.build/2` output (two agents, a
  synthesized base node and a folded side branch, so the graph carries both
  `:parent` and `:merge` edges); hand-crafted repo/lane/node/edge maps cover
  shapes the builder cannot easily produce (odd/absent geometry, a fixed
  `repo_dom_id`, unowned entries, missing colors and non-map entries).

  Note: Floki's HTML parser lowercases attribute names, so the SVG's `viewBox` /
  `preserveAspectRatio` are queried as `viewbox` / `preserveaspectratio`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsComponents.CommitGraphView
  alias EvoDashWeb.AgentsLive.CommitGraph
  alias EvoDashWeb.Helpers

  # Realistic fixture identifiers. The raw commits carry no explicit
  # `:short_sha`, so the rendered short sha is the sha's first 8 characters.
  @repo_root "/home/user/my-project"
  @foreign_root "/home/user/foreign-repo"
  @sha_base "b0000000"
  @sha_c1 "c1000000"
  @sha_c2 "c2000000"
  @sha_side "c2b00000"
  @sha_c3 "c3000000"

  # The documented golden-angle hue for depth 0 (see CommitGraph's depth→hue).
  @depth0_color "#7c38dc"

  # The happy fixture's documented layout constants (see CommitGraphView):
  # ox = oy = @vpad = 20, gutter = 132, col_w = 150, node_r = 7, band_pad = 12,
  # band_h = 18, min_h = 140.
  @happy_view_box "0 0 779 132"
  @happy_selected_view_box "0 0 779 156"

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

  describe "commit_graph_view/1 — repo sections" do
    test "the section id IS repo_dom_id verbatim, with a repo-name header above the graph" do
      {repo, dom, tree} = happy()

      # No doubled prefix: the builder's id already starts commit-graph-repo-.
      assert String.starts_with?(dom, "commit-graph-repo-")
      assert [section] = Floki.find(tree, "##{dom}")

      [header, graph] = element_children(section)

      # The header block carries the repo display name …
      assert Floki.find(header, ~s(span[title="my-project"])) != []
      assert Floki.text(header) =~ "my-project"
      # … and the graph block (toolbar + svg) lives BELOW it.
      assert Floki.find(header, "svg.cg-svg") == []
      assert Floki.find(graph, "svg.cg-svg") != []

      # The model really is the builder's output for this repo.
      assert repo.repo_name == "my-project"
      assert length(repo.nodes) == 5
    end

    test "two repos render two independent sections" do
      [repo] = happy_repos()
      [other] = happy_two_repo_fixture()

      assert repo.repo_dom_id != other.repo_dom_id

      tree = parse(render_repos([repo, other]))

      assert Floki.find(tree, "##{repo.repo_dom_id}") != []
      assert Floki.find(tree, "##{other.repo_dom_id}") != []

      assert Floki.text(Floki.find(tree, "##{repo.repo_dom_id}")) =~ "my-project"
      assert Floki.text(Floki.find(tree, "##{other.repo_dom_id}")) =~ "foreign-repo"

      # Two independent graphs, each with its own toolbar + readout span.
      assert Floki.find(tree, "svg.cg-svg") |> length() == 2
      assert Floki.find(tree, "span.cg-zoom-readout") |> length() == 2

      assert Floki.find(tree, "#cg-svg-#{repo.repo_dom_id}") != []
      assert Floki.find(tree, "#cg-svg-#{other.repo_dom_id}") != []
    end
  end

  describe "commit_graph_view/1 — zoom toolbar" do
    test "the .cg-graph block carries data-cg-repo-id and hosts the toolbar + svg" do
      {_repo, dom, tree} = happy()

      assert [graph] = Floki.find(tree, ".cg-graph")
      assert attr(graph, "data-cg-repo-id") == [dom]

      # Toolbar ABOVE the svg (DOM order inside the block).
      assert Floki.find(graph, "div.cg-toolbar") != []
      assert Floki.find(graph, "svg.cg-svg") != []
    end

    test "the three zoom buttons carry data-cg-action and the readout is EMPTY server-side" do
      {_repo, dom, tree} = happy()

      buttons = Floki.find(tree, "button[data-cg-action]")

      assert Enum.map(buttons, &(attr(&1, "data-cg-action") |> hd())) ==
               ["zoom-in", "zoom-out", "fit"]

      assert Enum.all?(buttons, &(attr(&1, "type") == ["button"]))

      assert Floki.find(tree, "#cg-zoom-in-#{dom}") != []
      assert Floki.find(tree, "#cg-zoom-out-#{dom}") != []
      assert Floki.find(tree, "#cg-zoom-fit-#{dom}") != []

      # The client hook writes the current zoom level into this span.
      assert [readout] = Floki.find(tree, "#cg-zoom-readout-#{dom}")
      assert attr(readout, "class") == ["cg-zoom-readout text-xs text-base-content/60 font-mono"]
      assert attr(readout, "aria-live") == ["polite"]
      assert Floki.text(readout) == ""
    end
  end

  describe "commit_graph_view/1 — svg scaffold" do
    test "svg.cg-svg carries a padded viewBox, width=100% and a clamped height" do
      {_repo, dom, tree} = happy()

      assert [svg] = Floki.find(tree, "svg.cg-svg")
      assert attr(svg, "id") == ["cg-svg-#{dom}"]
      assert attr(svg, "width") == ["100%"]
      assert attr(svg, "role") == ["img"]
      assert attr(svg, "aria-label") == ["Git commit history graph"]
      assert attr(svg, "preserveaspectratio") == ["xMinYMin meet"]

      # A "0 0 W H" string. The happy graph spans the 4 columns
      # (base at x = -1 … c3 at x = 2), so W = ox*2 + gutter + 4 * col_w + node_r
      # = 40 + 132 + 600 + 7 = 779 — i.e. the content bounds PLUS the 20-unit pad.
      assert attr(svg, "viewbox") == [@happy_view_box]

      # H = 40 + 2 rows * 46 = 132, clamped up to @min_h = 140.
      assert attr(svg, "height") == ["140"]
    end

    test "the svg's SOLE child is g.cg-viewport" do
      {_repo, dom, tree} = happy()

      [svg] = Floki.find(tree, "svg.cg-svg")

      assert [viewport] = element_children(svg)
      assert attr(viewport, "class") == ["cg-viewport"]
      assert attr(viewport, "id") == ["cg-viewport-#{dom}"]
    end

    test "paint order inside the viewport is edges → nodes → lanes" do
      {repo, dom, tree} = happy()

      classes = viewport_classes(tree, dom)

      expected =
        List.duplicate("cg-edge", repo.edge_count) ++
          List.duplicate("cg-node", repo.node_count) ++
          List.duplicate("cg-lane", repo.lane_count)

      assert classes == expected
      # The fixture really exercises all three groups.
      assert repo.edge_count == 5
      assert repo.node_count == 5
      assert repo.lane_count == 2
    end
  end

  describe "commit_graph_view/1 — edges" do
    test "one path.cg-edge per model edge, with a stable id and a cubic bezier d" do
      {repo, dom, tree} = happy()

      edges = Floki.find(tree, "path.cg-edge")

      assert length(edges) == length(repo.edges)
      assert Enum.all?(edges, &(attr(&1, "data-commit-graph-anim") == ["edge"]))
      assert Enum.all?(edges, &(attr(&1, "fill") == ["none"]))

      ids = Enum.map(edges, &(attr(&1, "id") |> hd()))

      expected = for e <- repo.edges, do: "commit-edge-#{dom}-#{e.from_sha}-#{e.to_sha}"

      assert ids == expected
      assert ids == Enum.uniq(ids)

      # A horizontal cubic bezier: M fx fy C cx fy, cx ty, tx ty.
      for edge <- edges do
        assert attr(edge, "d") |> hd() =~ ~r/^M \S+ \S+ C \S+ \S+, \S+ \S+, \S+ \S+$/
      end
    end

    test "a parent edge is solid; a merge edge is dashed" do
      {repo, dom, tree} = happy()

      parent = Enum.find(repo.edges, &(&1.kind == :parent))
      merge = Enum.find(repo.edges, &(&1.kind == :merge))

      # The fixture carries a folded side branch → exactly one merge edge.
      assert merge.from_sha == @sha_c3
      assert merge.to_sha == @sha_side
      assert Enum.count(repo.edges, &(&1.kind == :merge)) == 1

      [parent_el] = Floki.find(tree, "#{edge_selector(dom, parent)}")
      assert attr(parent_el, "stroke-width") == ["2"]
      assert attr(parent_el, "stroke-dasharray") == []

      [merge_el] = Floki.find(tree, "#{edge_selector(dom, merge)}")
      assert attr(merge_el, "stroke-width") == ["1.6"]
      assert attr(merge_el, "stroke-dasharray") == ["4 3"]
    end

    test "the stroke is the child owner's depth hue; an unowned edge is muted" do
      {repo, dom, tree} = happy()

      # a2 owns the c3 → c2 parent edge and its merge sibling: a2's depth hue.
      [a2_lane] = Enum.filter(repo.lanes, &(&1.agent_id == "a2"))
      refute a2_lane.color == @depth0_color

      for edge <- repo.edges, edge.owner_id == "a2" do
        [el] = Floki.find(tree, "#{edge_selector(dom, edge)}")

        assert attr(el, "style") == [
                 "stroke: #{a2_lane.color}; stroke-opacity: 0.75"
               ]
      end

      # An edge whose owner is not one of the repo's lanes stays muted base ink.
      bare = repo_view(edges: [edge(owner_id: "ghost")], lanes: [lane([])])
      bare_tree = parse(render_repos([bare]))

      [ghost_el] =
        Floki.find(bare_tree, "#{edge_selector(bare.repo_dom_id, edge(owner_id: "ghost"))}")

      assert attr(ghost_el, "style") == [
               "stroke: var(--color-base-content); stroke-opacity: 0.3"
             ]
    end
  end

  describe "commit_graph_view/1 — nodes" do
    test "one g.cg-node per model node with data attrs + the select_agent click contract" do
      {repo, dom, tree} = happy()

      nodes = Floki.find(tree, "g.cg-node")

      assert length(nodes) == repo.node_count
      assert Enum.all?(nodes, &(attr(&1, "data-commit-graph-anim") == ["node"]))

      ids = Enum.map(nodes, &(attr(&1, "id") |> hd()))
      assert ids == Enum.map(repo.nodes, &"commit-node-#{dom}-#{&1.sha}")
      assert ids == Enum.uniq(ids)

      # Every node here has an owning agent → every node is clickable.
      assert Enum.all?(nodes, &(attr(&1, "phx-click") == ["select_agent"]))

      [c3] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3}")
      assert attr(c3, "data-cg-sha") == [@sha_c3]
      assert attr(c3, "data-cg-agent-id") == ["a2"]
      assert attr(c3, "phx-value-id") == ["a2"]

      # One click target per node + one per lane, and nothing else on the page.
      assert length(Floki.find(tree, ~s([phx-click="select_agent"]))) ==
               repo.node_count + repo.lane_count
    end

    test "the inner <title> carries the commit tooltip (base prefix, first line only, refs)" do
      {repo, dom, tree} = happy()

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c3}") ==
               "Refactor Z · c3000000 · Carol · 2024-01-03 10:00 · HEAD, genesis/agent_x"

      # Only the FIRST line of a multi-line message is shown, and a ref-less
      # commit carries no ref segment at all.
      c1_title = node_title(tree, "commit-node-#{dom}-#{@sha_c1}")
      assert c1_title == "Add feature X · c1000000 · Alice · 2024-01-01 10:00"
      refute c1_title =~ "longer body line"
      refute c1_title =~ "HEAD"

      # The synthesized fork point is prefixed `base`.
      assert node_title(tree, "commit-node-#{dom}-#{@sha_base}") == "base · b0000000"
      assert Enum.any?(repo.nodes, &(&1.kind == :base))
    end

    test "a base node is hollow with the smaller radius; a commit node is filled" do
      {repo, dom, tree} = happy()

      base? = fn sha, r ->
        [dot] = Floki.find(tree, "#commit-node-#{dom}-#{sha} circle.cg-node-dot")
        assert attr(dot, "r") == [r]
        attr(dot, "style") |> hd()
      end

      # Base/fork node: hollow, base-content stroke, r = 5.
      assert base?.(@sha_base, "5") ==
               "fill: none; fill-opacity: 1; stroke: var(--color-base-content)"

      # Real commit: r = 7, filled.
      assert base?.(@sha_c1, "7") ==
               "fill: #{@depth0_color}; fill-opacity: 1; stroke: #{@depth0_color}"

      # All five nodes carry a dot; exactly one of them is a base node.
      assert length(Floki.find(tree, "circle.cg-node-dot")) == repo.node_count
      assert Enum.count(repo.nodes, &(&1.kind == :base)) == 1
    end

    test "a base node also renders a VISIBLE short-sha label; commit nodes stay unlabeled" do
      {repo, dom, tree} = happy()

      # The synthesized base node has no message/date — its short sha must be
      # readable WITHOUT hovering (it only lived in the <title> tooltip before).
      [label] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_base} text.cg-base-label")
      assert attr(label, "id") == ["commit-base-label-#{dom}-#{@sha_base}"]
      assert attr(label, "class") == ["cg-base-label font-mono"]
      assert attr(label, "text-anchor") == ["middle"]
      assert String.trim(Floki.text(label)) == String.slice(@sha_base, 0, 8)

      # Positioned BELOW the node dot, horizontally centred on it.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_base} circle.cg-node-dot")
      assert num_attr(label, "x") == num_attr(dot, "cx")
      assert num_attr(label, "y") > num_attr(dot, "cy")

      # One label per base node — and the happy fixture has exactly one base.
      assert length(Floki.find(tree, "text.cg-base-label")) == 1

      assert length(Floki.find(tree, "text.cg-base-label")) ==
               Enum.count(repo.nodes, &(&1.kind == :base))

      # Regular commit nodes carry NO visible label (tooltip only).
      for sha <- [@sha_c1, @sha_c2, @sha_side, @sha_c3] do
        assert Floki.find(tree, "#commit-node-#{dom}-#{sha} text.cg-base-label") == []
      end
    end

    test "an owner's END node takes the shared status fill; other owned nodes the depth hue" do
      {repo, dom, tree} = happy()

      dot_style = fn sha ->
        [dot] = Floki.find(tree, "#commit-node-#{dom}-#{sha} circle.cg-node-dot")
        attr(dot, "style") |> hd()
      end

      # a1 (:running) tips at c2 → the shared status color, never a local mapping.
      running = Helpers.agent_status_svg_color(:running)
      assert running == "var(--color-success)"
      assert dot_style.(@sha_c2) == "fill: #{running}; fill-opacity: 1; stroke: #{running}"

      # a2 (:completed) tips at c3 → the shared fallback status ink.
      assert dot_style.(@sha_c3) ==
               "fill: #{Helpers.agent_status_svg_color(:completed)}; fill-opacity: 1; stroke: #{Helpers.agent_status_svg_color(:completed)}"

      # c1 / the side branch are owned by a1 but are NOT its end commit → depth hue.
      assert dot_style.(@sha_c1) =~ "fill: #{@depth0_color}"
      assert dot_style.(@sha_side) =~ "fill: #{@depth0_color}"

      # c2 is a1's end AND a2's start — the end fill wins.
      assert Enum.member?(Enum.find(repo.nodes, &(&1.sha == @sha_c2)).end_ids, "a1")
    end

    test "a node without an owner omits the click contract and the agent id" do
      repo =
        repo_view(
          nodes: [
            graph_node(owner_id: nil, sha: "u0000001", x: 0),
            graph_node(owner_id: nil, sha: "u0000002", x: -1, kind: :base)
          ]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      assert length(Floki.find(tree, "g.cg-node")) == 2

      for sha <- ["u0000001", "u0000002"] do
        [el] = Floki.find(tree, "#commit-node-#{dom}-#{sha}")
        assert attr(el, "phx-click") == []
        assert attr(el, "phx-value-id") == []
        assert attr(el, "data-cg-agent-id") == []
        assert attr(el, "data-cg-sha") == [sha]
      end

      # An unowned non-base node is muted base ink at 0.55 opacity.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-u0000001 circle.cg-node-dot")

      assert attr(dot, "style") == [
               "fill: var(--color-base-content); fill-opacity: 0.55; stroke: var(--color-base-content)"
             ]
    end
  end

  describe "commit_graph_view/1 — lanes" do
    test "one g.cg-lane per lane, in model order, with the anchor id + click contract" do
      {repo, dom, tree} = happy()

      lanes = Floki.find(tree, "g.cg-lane")

      assert length(lanes) == repo.lane_count
      assert Enum.all?(lanes, &(attr(&1, "data-commit-graph-anim") == ["lane"]))

      # Lane order follows the model's {depth, id} order.
      assert Enum.map(repo.lanes, & &1.agent_id) == ["a1", "a2"]

      assert Enum.map(lanes, &(attr(&1, "id") |> hd())) == [
               "commit-agent-row-#{dom}-a1",
               "commit-agent-row-#{dom}-a2"
             ]

      assert Enum.map(lanes, &(attr(&1, "phx-value-id") |> hd())) == ["a1", "a2"]
      assert Enum.map(lanes, &(attr(&1, "data-cg-agent-id") |> hd())) == ["a1", "a2"]
      assert Enum.all?(lanes, &(attr(&1, "phx-click") == ["select_agent"]))
    end

    test "the lane band spans x_start → x_end and never swallows a click" do
      {repo, dom, tree} = happy()

      [a1, a2] = repo.lanes

      # a1 spans columns -1 … 1: x = px(-1) - band_pad = 152 - 12 = 140,
      # w = 2 * col_w + 2 * band_pad = 324; y = py(0) - band_h / 2 = 34.
      [band1] = Floki.find(tree, "#commit-lane-#{dom}-a1")
      assert attr(band1, "class") == ["cg-lane-band"]
      assert attr(band1, "x") == ["140"]
      assert attr(band1, "y") == ["34"]
      assert attr(band1, "width") == ["324"]
      assert attr(band1, "height") == ["18"]
      assert attr(band1, "rx") == ["6"]
      assert attr(band1, "pointer-events") == ["none"]

      # a2 owns a single column: a 12-unit pad each side of one node.
      [band2] = Floki.find(tree, "#commit-lane-#{dom}-a2")
      assert attr(band2, "x") == ["590"]
      assert attr(band2, "width") == ["24"]

      # Both bands are tinted with their lane's depth hue at the resting opacity.
      assert attr(band1, "style") == [
               "fill: #{a1.color}; fill-opacity: 0.12; stroke: #{a1.color}; stroke-opacity: 0.35"
             ]

      assert attr(band2, "style") == [
               "fill: #{a2.color}; fill-opacity: 0.12; stroke: #{a2.color}; stroke-opacity: 0.35"
             ]

      # No band for a lane whose bounds are not integers — the lane group and
      # its label still render.
      bare = repo_view(lanes: [lane(x_start: "0", x_end: nil)])
      bare_tree = parse(render_repos([bare]))

      assert Floki.find(bare_tree, "rect.cg-lane-band") == []
      assert Floki.find(bare_tree, "#commit-agent-row-#{bare.repo_dom_id}-hand1") != []
      assert Floki.find(bare_tree, "#commit-lane-label-#{bare.repo_dom_id}-hand1") != []
    end

    test "the lane label reads T<task_local_id> and the group title adds the status" do
      {repo, dom, tree} = happy()

      [a1, a2] = repo.lanes

      [label1] = Floki.find(tree, "#commit-lane-label-#{dom}-a1")
      assert attr(label1, "class") == ["cg-lane-label font-mono"]
      # Drawn inside the reserved left gutter.
      assert attr(label1, "x") == ["20"]
      assert attr(label1, "style") == ["fill: #{a1.color}"]
      assert String.trim(Floki.text(label1)) == "T1"

      [label2] = Floki.find(tree, "#commit-lane-label-#{dom}-a2")
      assert String.trim(Floki.text(label2)) == "T2"

      assert lane_title(tree, "commit-agent-row-#{dom}-a1") == "T1 · Running"
      # :completed has no dedicated label clause -> capitalized atom name.
      assert lane_title(tree, "commit-agent-row-#{dom}-a2") == "T2 · Completed"

      assert a1.task_local_id == 1
      assert a2.task_local_id == 2
    end
  end

  describe "commit_graph_view/1 — animation markers" do
    test "data-commit-graph-anim takes exactly edge/node/lane; no animation classes" do
      {repo, _dom, tree} = happy()
      html = render_repos(happy_repos())

      values =
        tree
        |> Floki.find("[data-commit-graph-anim]")
        |> Enum.map(&(attr(&1, "data-commit-graph-anim") |> hd()))

      assert Enum.uniq(values) |> Enum.sort() == ["edge", "lane", "node"]

      assert Enum.count(values, &(&1 == "edge")) == repo.edge_count
      assert Enum.count(values, &(&1 == "node")) == repo.node_count
      assert Enum.count(values, &(&1 == "lane")) == repo.lane_count

      # The enter classes are added by the JS hook, never emitted server-side.
      refute html =~ "commit-node-enter"
      refute html =~ "commit-lane-enter"
      refute html =~ "commit-edge-enter"

      # No `phx-update` mode anywhere: every element carries a stable, unique DOM
      # id, so LiveView's patcher reuses nodes instead of re-creating them.
      assert Floki.find(tree, "[phx-update]") == []
    end
  end

  describe "commit_graph_view/1 — selection" do
    test "selecting a1 marks its START and END nodes, tints its band and reads out" do
      {repo, dom, tree} = happy_selected("a1")

      # a1 forks from the synthesized base node and tips at c2.
      assert Enum.find(repo.nodes, &(&1.sha == @sha_base)).start_ids == ["a1"]
      assert Enum.find(repo.nodes, &(&1.sha == @sha_c2)).end_ids == ["a1"]

      # START: a SOLID primary ring on the base node + the `start` tag BELOW it.
      [start_node] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_base}")
      assert [start_ring] = Floki.find(start_node, "circle.cg-selection-start")
      assert attr(start_ring, "stroke-dasharray") == []
      assert attr(start_ring, "r") == ["10.5"]
      assert attr(start_ring, "style") == ["fill: none; stroke: var(--color-primary)"]

      [start_tag] = Floki.find(start_node, "text.cg-selection-tag")
      assert String.trim(Floki.text(start_tag)) == "start"
      # The tag sits BELOW the node (a circle only carries `cy`).
      assert num_attr(start_tag, "y") > num_attr(start_ring, "cy")

      # END: a DASHED primary ring on c2 + the `end` tag ABOVE it.
      [end_node] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2}")
      assert [end_ring] = Floki.find(end_node, "circle.cg-selection-end")
      assert attr(end_ring, "stroke-dasharray") == ["3 2"]
      assert attr(end_ring, "r") == ["10.5"]

      [end_tag] = Floki.find(end_node, "text.cg-selection-tag")
      assert String.trim(Floki.text(end_tag)) == "end"
      assert num_attr(end_tag, "y") < num_attr(end_ring, "cy")

      # Exactly two rings on the whole graph.
      assert length(Floki.find(tree, "circle.cg-selection-start")) == 1
      assert length(Floki.find(tree, "circle.cg-selection-end")) == 1

      # The selected lane's band turns primary; the other lane's stays its hue.
      [band1] = Floki.find(tree, "#commit-lane-#{dom}-a1")
      assert attr(band1, "style") |> hd() =~ "stroke: var(--color-primary)"
      assert attr(band1, "style") |> hd() =~ "fill-opacity: 0.2"

      [band2] = Floki.find(tree, "#commit-lane-#{dom}-a2")
      refute attr(band2, "style") |> hd() =~ "var(--color-primary)"
      assert attr(band2, "style") |> hd() =~ "fill-opacity: 0.12"

      # The readout reserves the top strip and prints the short-sha range.
      assert [readout] = Floki.find(tree, "text#cg-selection-readout-#{dom}")
      assert String.trim(Floki.text(readout)) == "Selected T1 · b0000000 → c2000000"
      assert attr(readout, "style") == ["fill: var(--color-primary)"]

      # Reserving the readout strip grows the content box (still padded).
      [svg] = Floki.find(tree, "svg.cg-svg")
      assert attr(svg, "viewbox") == [@happy_selected_view_box]
    end

    test "selecting a2 marks ITS start/end nodes and readout" do
      {repo, dom, tree} = happy_selected("a2")

      # a2 forks from c2 (a1's tip) and tips at c3.
      assert [start_node] =
               Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2} circle.cg-selection-start")

      assert attr(start_node, "stroke-dasharray") == []

      assert [end_node] =
               Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-selection-end")

      assert attr(end_node, "stroke-dasharray") == ["3 2"]

      # The base node is a1's start, NOT a2's.
      assert Floki.find(tree, "#commit-node-#{dom}-#{@sha_base} circle.cg-selection-start") == []

      assert Floki.find(tree, "text.cg-selection-readout") |> Floki.text() =~
               "Selected T2 · c2000000 → c3000000"

      # Only a2's band is marked.
      [band1] = Floki.find(tree, "#commit-lane-#{dom}-a1")
      refute attr(band1, "style") |> hd() =~ "var(--color-primary)"
      [band2] = Floki.find(tree, "#commit-lane-#{dom}-a2")
      assert attr(band2, "style") |> hd() =~ "stroke: var(--color-primary)"

      assert Enum.find(repo.lanes, &(&1.agent_id == "a2")).start_sha == @sha_c2
    end

    test "a nil or non-matching selected_id renders no rings, no readout, no primary band" do
      for selected <- [nil, "nope"] do
        html = render_repos(happy_repos(), selected_id: selected)
        tree = parse(html)

        assert Floki.find(tree, "circle.cg-selection-start") == []
        assert Floki.find(tree, "circle.cg-selection-end") == []
        assert Floki.find(tree, "text.cg-selection-readout") == []
        assert Floki.find(tree, "text.cg-selection-tag") == []
        refute html =~ "var(--color-primary)"

        # Without a readout strip the content box stays at its resting height.
        [svg] = Floki.find(tree, "svg.cg-svg")
        assert attr(svg, "viewbox") == [@happy_view_box]
      end
    end

    test "the readout drops the sha range when the lane has no start/end shas" do
      repo =
        repo_view(
          nodes: [
            graph_node(
              sha: "s0000001",
              x: 0,
              owner_id: "hand1",
              start_ids: ["hand1"],
              end_ids: ["hand1"]
            )
          ],
          lanes: [lane([])]
        )

      tree = parse(render_repos([repo], selected_id: "hand1"))
      dom = repo.repo_dom_id

      assert [readout] = Floki.find(tree, "#cg-selection-readout-#{dom}")
      assert String.trim(Floki.text(readout)) == "Selected T7"
    end
  end

  describe "commit_graph_view/1 — view states" do
    test "empty repos + loading renders the loading state and nothing else" do
      html = render_repos([], loading: true)
      tree = parse(html)

      assert html =~ "Loading commit history"
      refute html =~ "No commit history yet."
      refute html =~ "Could not load commit history."
      assert Floki.find(tree, "#commit-graph-error") == []
      assert Floki.find(tree, ".cg-graph") == []

      # The body wrapper is present in every state.
      assert Floki.find(tree, "#commit-graph-body-local") != []

      # Loading WINS over a non-nil error while there are no repos.
      loading_with_error = render_repos([], loading: true, error: :boom)

      assert loading_with_error =~ "Loading commit history"
      refute loading_with_error =~ "Could not load commit history."
      refute loading_with_error =~ "No commit history yet."
    end

    test "empty repos + not loading + no error renders the empty state" do
      html = render_repos([])
      tree = parse(html)

      assert html =~ "No commit history yet."
      assert html =~ "Start a task from the dashboard to see the commit graph here."
      refute html =~ "Loading commit history"
      refute html =~ "Could not load commit history."
      assert Floki.find(tree, "#commit-graph-error") == []
      assert Floki.find(tree, ".cg-graph") == []
    end

    test "empty repos + a non-nil error renders the error state" do
      html = render_repos([], error: :boom)
      tree = parse(html)

      assert [error] = Floki.find(tree, "#commit-graph-error")
      assert Floki.text(error) =~ "Could not load commit history."

      refute html =~ "No commit history yet."
      refute html =~ "Loading commit history"
      # No cached repos → the stale warning is not used.
      assert Floki.find(tree, "#commit-graph-stale-warning") == []
    end
  end

  describe "commit_graph_view/1 — stale warning" do
    test "non-empty repos + a non-nil error render the stale warning AND the graph" do
      {repo, dom, tree} = happy_error(:boom)

      assert [warning] = Floki.find(tree, "#commit-graph-stale-warning")
      assert Floki.text(warning) =~ "refresh failed"

      # The last-good graph still renders …
      assert Floki.find(tree, "#{edge_selector(dom, hd(repo.edges))}") != []
      assert Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1}") != []
      assert Floki.find(tree, "#commit-agent-row-#{dom}-a1") != []
      assert Floki.find(tree, "#commit-lane-#{dom}-a1") != []

      # … and the hard error state is NOT shown.
      assert Floki.find(tree, "#commit-graph-error") == []
    end
  end

  describe "commit_graph_view/1 — defensive shapes" do
    test "non-map repo entries are dropped without crashing" do
      repo = repo_view(repo_name: "Kept Repo")
      tree = parse(render_repos([:junk, "nope", nil, repo]))

      assert Floki.find(tree, "##{repo.repo_dom_id}") != []
      assert length(Floki.find(tree, ".cg-graph")) == 1
    end

    test "a repo without nodes or lanes renders its header + the empty-repo note" do
      repo = %{repo_dom_id: "commit-graph-repo-bare-1", repo_name: "Bare Repo"}
      tree = parse(render_repos([repo]))

      [section] = Floki.find(tree, "#commit-graph-repo-bare-1")
      assert Floki.text(section) =~ "Bare Repo"

      # The scaffold still renders, but with an empty viewport.
      assert Floki.find(section, "svg.cg-svg") != []
      assert Floki.find(section, "g.cg-node") == []
      assert Floki.find(section, "g.cg-lane") == []
      assert Floki.find(section, "path.cg-edge") == []

      assert [note] = Floki.find(section, "p.cg-empty-note")
      assert Floki.text(note) =~ "No commit history for this repository."

      # A repo that has lanes (but no nodes) keeps the scaffold WITHOUT the note.
      with_lane = repo_view(lanes: [lane([])])
      lane_tree = parse(render_repos([with_lane]))

      assert Floki.find(lane_tree, "##{with_lane.repo_dom_id}") != []
      assert Floki.find(lane_tree, "#commit-agent-row-#{with_lane.repo_dom_id}-hand1") != []
      assert Floki.find(lane_tree, "p.cg-empty-note") == []
    end

    test "non-map node, edge and lane entries are dropped" do
      repo =
        repo_view(
          nodes: [:junk_node, "nope", graph_node(sha: "ok000000", x: :garbage)],
          edges: [
            :junk_edge,
            %{from_sha: "a", to_sha: "b"},
            edge(from: :bad, to: {0, 0}, kind: :merge)
          ],
          lanes: [:junk_lane, "nope", lane(x_start: "0", x_end: nil)]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      # Only the single map node survives (a non-integer `x` folds to column 0).
      assert length(Floki.find(tree, "g.cg-node")) == 1
      assert Floki.find(tree, "#commit-node-#{dom}-ok000000") != []

      # The map edge had a non-tuple endpoint → its `d` folds to nil → dropped.
      assert Floki.find(tree, "path.cg-edge") == []

      # Only the single map lane survives …
      assert length(Floki.find(tree, "g.cg-lane")) == 1
      assert Floki.find(tree, "#commit-agent-row-#{dom}-hand1") != []
      # … and its non-integer bounds drop the band.
      assert Floki.find(tree, "rect.cg-lane-band") == []
    end

    test "an agent without a color falls back to the base-content ink" do
      for color <- [nil, "", :garbage] do
        repo =
          repo_view(
            nodes: [graph_node(sha: "n0000001", x: 0, owner_id: "hand1")],
            edges: [edge(owner_id: "hand1")],
            lanes: [lane(color: color, x_start: 0, x_end: 0)]
          )

        tree = parse(render_repos([repo]))
        dom = repo.repo_dom_id
        ink = "var(--color-base-content)"

        [band] = Floki.find(tree, "#commit-lane-#{dom}-hand1")

        assert attr(band, "style") == [
                 "fill: #{ink}; fill-opacity: 0.12; stroke: #{ink}; stroke-opacity: 0.35"
               ]

        [label] = Floki.find(tree, "#commit-lane-label-#{dom}-hand1")
        assert attr(label, "style") == ["fill: #{ink}"]

        # The node owned by that lane inherits the fallback too.
        [dot] = Floki.find(tree, "#commit-node-#{dom}-n0000001 circle.cg-node-dot")
        assert attr(dot, "style") |> hd() =~ "fill: #{ink}"

        [path] = Floki.find(tree, "path.cg-edge")
        assert attr(path, "style") == ["stroke: #{ink}; stroke-opacity: 0.75"]
      end
    end

    test "a lane without an agent id omits the click contract but keeps a stable id" do
      repo =
        repo_view(
          nodes: [graph_node(sha: "n0000002", x: 0, owner_id: nil)],
          lanes: [lane(agent_id: nil, task_local_id: nil, x_start: 0, x_end: 0)]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      [lane_el] = Floki.find(tree, "g.cg-lane")
      assert attr(lane_el, "id") == ["commit-agent-row-#{dom}-nil"]
      assert attr(lane_el, "phx-click") == []
      assert attr(lane_el, "phx-value-id") == []
      assert attr(lane_el, "data-cg-agent-id") == []

      # The label/band keep the same id suffix, so patching stays incremental.
      assert Floki.find(tree, "#commit-lane-#{dom}-nil") != []
      assert Floki.find(tree, "#commit-lane-label-#{dom}-nil") != []
      # `T` + the stringified (missing) id.
      assert Floki.find(tree, "#commit-lane-label-#{dom}-nil") |> Floki.text() =~ "Tnil"
    end

    test "odd grid values and non-binary shas degrade without crashing" do
      repo =
        repo_view(
          nodes: [
            graph_node(sha: 42, x: :garbage, y: -3),
            graph_node(sha: "z0000001", x: "1", y: 0)
          ],
          lanes: [lane(x_start: 0, x_end: 0)]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      # A non-binary sha still gets a stable, DOM-safe element id.
      assert Floki.find(tree, "#commit-node-#{dom}-42") != []
      assert Floki.find(tree, "#commit-node-#{dom}-z0000001") != []

      # Non-integer grid coordinates fold to 0 / row 0 rather than raising.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-42 circle.cg-node-dot")
      assert attr(dot, "cx") == ["152"]
      assert attr(dot, "cy") == ["43.0"]

      # The viewBox stays a valid "0 0 W H" string.
      [svg] = Floki.find(tree, "svg.cg-svg")
      assert attr(svg, "viewbox") |> hd() =~ ~r/^0 0 \d+ \d+$/
    end
  end

  # The main happy-path fixture: a two-agent repo (a1 at depth 0 whose first-parent
  # path covers c1..c2 and TIPS at c2, a2 at depth 1 tipping at c3 over a folded
  # side branch) assembled by the REAL `CommitGraph.build/2`. It therefore carries
  # a synthesized base node, four `:parent` edges and one `:merge` edge.
  defp happy_repos do
    agents = [
      %{
        id: "a1",
        parent_id: nil,
        depth: 0,
        task_local_id: 1,
        status: :running,
        agent_module: "EvoGit.Agents.Manager",
        model_id: "deepseek:deepseek-v4-flash",
        base_commit: @sha_base,
        current_commit: @sha_c2,
        repo_root: @repo_root
      },
      %{
        id: "a2",
        parent_id: "a1",
        depth: 1,
        task_local_id: 2,
        status: :completed,
        agent_module: "EvoGit.Agents.Executor",
        model_id: nil,
        base_commit: @sha_c2,
        current_commit: @sha_c3,
        repo_root: @repo_root
      }
    ]

    raw = %{
      @repo_root => %{
        commits: [
          %{
            sha: @sha_c3,
            message: "Refactor Z",
            author_name: "Carol",
            date: ~U[2024-01-03 10:00:00Z],
            parents: [@sha_c2, @sha_side]
          },
          %{
            sha: @sha_side,
            message: "Side branch W",
            author_name: "Dave",
            date: ~U[2024-01-02 12:00:00Z],
            parents: [@sha_c1]
          },
          %{
            sha: @sha_c2,
            message: "Fix bug Y",
            author_name: "Bob",
            date: ~U[2024-01-02 10:00:00Z],
            parents: [@sha_c1]
          },
          %{
            sha: @sha_c1,
            message: "Add feature X\n\nlonger body line",
            author_name: "Alice",
            date: ~U[2024-01-01 10:00:00Z],
            parents: [@sha_base]
          }
        ],
        refs: %{@sha_c3 => ["HEAD", "genesis/agent_x"]}
      }
    }

    CommitGraph.build(raw, agents)
  end

  # A second, independent repo (a single commit + a single agent) for the
  # multi-repo rendering assertions.
  defp happy_two_repo_fixture do
    agents = [
      %{
        id: "a9",
        parent_id: nil,
        depth: 0,
        task_local_id: 9,
        status: :running,
        base_commit: nil,
        current_commit: "f1000000",
        repo_root: @foreign_root
      }
    ]

    raw = %{
      @foreign_root => %{
        commits: [
          %{sha: "f1000000", message: "Foreign commit", author_name: "Zoe", parents: []}
        ],
        refs: %{}
      }
    }

    CommitGraph.build(raw, agents)
  end

  # Hand-crafted repo/lane/node/edge maps for shapes the builder does not easily
  # produce (odd/absent geometry, a fixed DOM id, unowned entries and non-map
  # entries).
  defp repo_view(overrides) do
    Map.merge(
      %{
        repo_key: "primary",
        repo_dom_id: "commit-graph-repo-handcrafted-1",
        repo_name: "Primary Repo",
        nodes: [],
        edges: [],
        lanes: []
      },
      Map.new(overrides)
    )
  end

  defp lane(overrides) do
    Map.merge(
      %{
        agent_id: "hand1",
        task_local_id: 7,
        status: :running,
        depth: 0,
        color: "#123456",
        y: 0,
        x_start: nil,
        x_end: nil
      },
      Map.new(overrides)
    )
  end

  defp graph_node(overrides) do
    Map.merge(
      %{
        sha: "deadbeef",
        short_sha: "deadbeef",
        message: "A commit",
        author_name: "Ann",
        date: nil,
        refs: [],
        x: 0,
        y: 0,
        kind: :commit,
        owner_id: "hand1",
        start_ids: [],
        end_ids: []
      },
      Map.new(overrides)
    )
  end

  defp edge(overrides) do
    Map.merge(
      %{
        from_sha: "aaaa0000",
        to_sha: "bbbb0000",
        from: {0, 0},
        to: {-1, 0},
        kind: :parent,
        owner_id: "hand1"
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

  # The stable repo DOM id (already "commit-graph-repo-" shaped from the real
  # builder — the component adds NO prefix).
  defp dom_id(repos), do: repos |> hd() |> Map.fetch!(:repo_dom_id)

  defp edge_selector(dom, edge) do
    "#commit-edge-#{dom}-#{edge.from_sha}-#{edge.to_sha}"
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

  defp happy_selected(selected_id) do
    repos = happy_repos()
    {hd(repos), dom_id(repos), parse(render_repos(repos, selected_id: selected_id))}
  end

  defp happy_error(error) do
    repos = happy_repos()
    {hd(repos), dom_id(repos), parse(render_repos(repos, error: error))}
  end

  # The class of every element child of the repo's `g.cg-viewport`, in DOM order.
  defp viewport_classes(tree, dom) do
    [viewport] = Floki.find(tree, "#cg-viewport-#{dom}")

    viewport
    |> element_children()
    |> Enum.map(&(&1 |> Floki.attribute("class") |> List.first()))
  end

  defp node_title(tree, id) do
    [el] = Floki.find(tree, "##{id}")
    el |> Floki.find("title") |> Floki.text()
  end

  defp lane_title(tree, id) do
    [el] = Floki.find(tree, "##{id}")
    el |> Floki.find("title") |> Floki.text()
  end

  # A numeric SVG attribute (`y` / `cy`) as a float (`"67"` / `"67.0"`).
  defp num_attr(el, name) do
    case el |> attr(name) |> hd() |> Float.parse() do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
