defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView` — the
  TEMPORAL (git commit history) view of the Agents page left panel.

  `commit_graph_view/1` is purely presentational: it renders the per-repo graph
  view models assembled by the pure `EvoDashWeb.AgentsLive.CommitGraph.build/2`
  as a VERTICAL, GitLen/GitKraken-style commit graph (one row per commit, top →
  bottom, plus a left gutter `<svg>` drawing the dots and child → parent edges)
  and fires the existing `select_agent` event from the rows and the agent tags.
  These tests render it in isolation with `render_component/2` (no `live/3` —
  matching the rest of this directory) and pin the frozen DOM contract consumed
  by the client-side `CommitGraph` hook / CSS animation:

    * `#commit-graph` + `phx-hook="CommitGraph"` → the node-scoped body
      `#commit-graph-body-<node_key>` → one section per repo whose id IS the
      builder's `repo_dom_id` VERBATIM (no extra prefix) with a name header;
    * `#cg-list-<repo_dom_id>` (the `relative` list wrapper) holding the
      absolute gutter `<svg.cg-gutter[viewBox]>` and the `.cg-rows` container
      left-padded by the gutter width;
    * `path.cg-edge[data-commit-graph-anim="edge"]` child → parent vertical
      beziers (a `:merge` edge dashed, a `:parent` edge solid, stroked with the
      child owner's depth hue) with a stable id;
    * `g.cg-node[data-commit-graph-anim="node"]` with `data-cg-agent-id` /
      `data-cg-sha`, an inner `<title>` tooltip and the gutter dot geometry;
    * `div.cg-row[data-commit-graph-anim="row"]` with the stable id, the fixed
      row height, the `select_agent` contract (omitted for an unowned node), the
      short sha / message / `author · date` and the second-line TAGS;
    * AGENT tags (`button.cg-agent-tag`) for `start_ids` (solid border, `start`
      marker) and `end_ids` (dashed border, `end` marker) labelled
      `T<task_local_id>` in the agent's depth hue, plus non-clickable REF tags
      (`span.cg-ref-tag`);
    * selection (`selected_id`) rings the selected agent's START (solid) / END
      (dashed) gutter dots, accents those rows and renders the
      `#cg-selection-readout-<dom>` annotation;
    * an ENDED (retained) agent (`ended: true` — terminated/recycled but kept
      in-session) renders at HALF opacity: its owned node dots `fill-opacity:
      0.5`, its owned edges `stroke-opacity: 0.4` and its rows `opacity-50`;
    * the `:loading` / `:empty` / `:error` / stale-warning states.

  The main happy-path fixture is REAL `CommitGraph.build/2` output (two agents, a
  synthesized base node and a folded side branch, so the graph carries both
  `:parent` and `:merge` edges); hand-crafted repo/node/edge/agent maps cover
  shapes the builder cannot easily produce (odd/absent geometry, a fixed
  `repo_dom_id`, unowned entries and non-map entries).

  Note: Floki's HTML parser lowercases attribute names, so the SVG's `viewBox`
  is queried as `viewbox`.
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

  # The documented golden-angle hues (see CommitGraph's depth→hue).
  @depth0_color "#7c38dc"
  @depth1_color "#dcad38"

  # The happy fixture's documented geometry constants (see CommitGraphView):
  # @row_h = 44, @col_w = 16, @gutter_pad = 12, @node_r = 6, @base_r = 4.
  # column_count = 2 → gutter width = 24 + 2*16 = 56; height = 5 * 44 = 220.
  @happy_gutter_w 56
  @happy_gutter_h 220

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
      {repo, dom, tree} = happy()

      # No doubled prefix: the builder's id already starts commit-graph-repo-.
      assert String.starts_with?(dom, "commit-graph-repo-")
      assert [section] = Floki.find(tree, "##{dom}")
      assert attr(section, "data-cg-repo-id") == [dom]

      [header, list] = element_children(section)

      # The header block carries the repo display name + the hero-server-stack chip …
      assert Floki.find(header, ~s(span[title="my-project"])) != []
      assert Floki.find(header, "span.hero-server-stack") != []
      assert Floki.text(header) =~ "my-project"
      # … and the commit list (gutter + rows) lives BELOW it.
      assert Floki.find(header, "svg.cg-gutter") == []
      assert Floki.find(list, "svg.cg-gutter") != []

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

      # Two independent gutters, each with its own rows.
      assert Floki.find(tree, "svg.cg-gutter") |> length() == 2
      assert Floki.find(tree, "#cg-gutter-#{repo.repo_dom_id}") != []
      assert Floki.find(tree, "#cg-gutter-#{other.repo_dom_id}") != []
    end
  end

  describe "commit_graph_view/1 — list + gutter geometry" do
    test "the list wrapper is relative, carries data-cg-repo-id, and hosts gutter + rows" do
      {_repo, dom, tree} = happy()

      assert [list] = Floki.find(tree, "#cg-list-#{dom}")
      assert attr(list, "class") == ["cg-list relative"]

      [gutter, rows] = element_children(list)
      assert attr(gutter, "class") == ["cg-gutter absolute left-0 top-0 pointer-events-none"]
      assert attr(rows, "class") == ["cg-rows"]
    end

    test "the gutter svg carries the derived width/height/viewBox and the aria label" do
      {repo, dom, tree} = happy()

      [gutter] = Floki.find(tree, "#cg-gutter-#{dom}")

      assert attr(gutter, "width") == [Integer.to_string(@happy_gutter_w)]
      assert attr(gutter, "height") == [Integer.to_string(@happy_gutter_h)]
      assert attr(gutter, "viewbox") == ["0 0 #{@happy_gutter_w} #{@happy_gutter_h}"]
      assert attr(gutter, "class") == ["cg-gutter absolute left-0 top-0 pointer-events-none"]
      assert attr(gutter, "role") == ["img"]
      assert attr(gutter, "aria-label") == ["Git commit history graph"]

      # height == node_count * @row_h; width == 24 + column_count * 16.
      assert @happy_gutter_h == repo.node_count * 44
      assert @happy_gutter_w == 24 + repo.column_count * 16
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

    test "a repo with no nodes renders the empty note instead of a gutter" do
      repo = repo_view(nodes: [], edges: [], agents: [])
      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      assert [note] = Floki.find(tree, ".cg-empty-note")
      assert Floki.text(note) =~ "No commit history for this repository."
      assert Floki.find(tree, "#cg-gutter-#{dom}") == []
      assert Floki.find(tree, ".cg-row") == []
    end

    test "column_count is derived from the nodes when the hint is absent/odd" do
      repo =
        repo_view(
          column_count: 0,
          nodes: [
            node_view(sha: "n0000001", column: 0, row: 0),
            node_view(sha: "n0000002", column: 2, row: 1)
          ]
        )

      tree = parse(render_repos([repo]))
      [gutter] = Floki.find(tree, "#cg-gutter-#{repo.repo_dom_id}")

      # max(column) + 1 = 3 → 24 + 3*16 = 72.
      assert attr(gutter, "width") == ["72"]
      assert attr(gutter, "height") == ["88"]
    end
  end

  describe "commit_graph_view/1 — edges" do
    test "one path.cg-edge per model edge, with a stable id and a vertical bezier d" do
      {repo, dom, tree} = happy()

      edges = Floki.find(tree, "path.cg-edge")

      assert length(edges) == length(repo.edges)
      assert Enum.all?(edges, &(attr(&1, "data-commit-graph-anim") == ["edge"]))
      assert Enum.all?(edges, &(attr(&1, "fill") == ["none"]))

      ids = Enum.map(edges, &(attr(&1, "id") |> hd()))

      expected = for e <- repo.edges, do: "commit-edge-#{dom}-#{e.from_sha}-#{e.to_sha}"

      assert ids == expected
      assert ids == Enum.uniq(ids)

      # A vertical cubic bezier: M fx fy C fx my, tx my, tx ty.
      for edge <- edges do
        assert attr(edge, "d") |> hd() =~ ~r/^M \S+ \S+ C \S+ \S+, \S+ \S+, \S+ \S+$/
      end
    end

    test "edge endpoints align exactly to the row/column dot geometry" do
      {repo, _dom, tree} = happy()

      # The c1000000 → b0000000 parent edge: both endpoints in column 0, rows 1 → 0.
      # dot_x(0) = 12 + 0 + 8 = 20; dot_y(1) = 1*44 + 22 = 66; dot_y(0) = 22.
      edge = Enum.find(repo.edges, &(&1.from_sha == @sha_c1 and &1.to_sha == @sha_base))
      selector = "path.cg-edge##{edge_selector(repo.repo_dom_id, edge)}"

      [el] = Floki.find(tree, selector)
      assert attr(el, "d") == ["M 20 66 C 20 44, 20 44, 20 22"]
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

    test "a merge edge sweeps across columns (its d crosses the gutter)" do
      {repo, dom, tree} = happy()

      merge = Enum.find(repo.edges, &(&1.kind == :merge))
      [el] = Floki.find(tree, "#{edge_selector(dom, merge)}")

      # from column 1 (x = 36) → to column 0 (x = 20).
      assert attr(el, "d") == ["M 36 198 C 36 176, 20 176, 20 154"]
    end

    test "the stroke is the child owner's depth hue; an unowned edge is muted" do
      {repo, dom, tree} = happy()

      # a2 (depth 1) owns the c3 → c2 parent edge and its merge sibling.
      for edge <- repo.edges, edge.owner_id == "a2" do
        [el] = Floki.find(tree, "#{edge_selector(dom, edge)}")

        assert attr(el, "style") == [
                 "stroke: #{@depth1_color}; stroke-opacity: 0.75"
               ]
      end

      # A parent edge owned by a1 carries a1's depth-0 hue.
      a1_edge = Enum.find(repo.edges, &(&1.owner_id == "a1" and &1.kind == :parent))
      [a1_el] = Floki.find(tree, "#{edge_selector(dom, a1_edge)}")
      assert attr(a1_el, "style") == ["stroke: #{@depth0_color}; stroke-opacity: 0.75"]

      # An edge whose owner is not one of the repo's agents stays muted base ink.
      bare =
        repo_view(
          edges: [edge_view(owner_id: "ghost")],
          nodes: [node_view(sha: "n0000001", owner_id: nil)],
          agents: [agent_map([])]
        )

      bare_tree = parse(render_repos([bare]))

      [ghost_el] =
        Floki.find(bare_tree, "#{edge_selector(bare.repo_dom_id, edge_view(owner_id: "ghost"))}")

      assert attr(ghost_el, "style") == [
               "stroke: var(--color-base-content); stroke-opacity: 0.3"
             ]
    end

    test "an edge endpoints fall back to the edge's own column/row when the node is absent" do
      repo =
        repo_view(
          edges: [
            edge_view(from_sha: "x", from_column: 1, from_row: 3, to_column: 0, to_row: 0)
          ],
          nodes: [node_view(sha: "unrelated", column: 0, row: 0)]
        )

      tree = parse(render_repos([repo]))
      [el] = Floki.find(tree, "path.cg-edge")

      # dot_x(1) = 36, dot_y(3) = 154 → dot_x(0) = 20, dot_y(0) = 22.
      assert attr(el, "d") == ["M 36 154 C 36 88, 20 88, 20 22"]
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

      # The row 1 / column 0 commit: dot at x = 20, y = 1*44+22 = 66, r = 6.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")
      assert attr(dot, "cx") == ["20"]
      assert attr(dot, "cy") == ["66"]
      assert attr(dot, "r") == ["6"]

      # The row 4 / column 1 commit: x = 12 + 16 + 8 = 36, y = 4*44+22 = 198.
      [c3_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-node-dot")
      assert attr(c3_dot, "cx") == ["36"]
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

    test "a base node is hollow and smaller, with a 'base' tooltip prefix" do
      {_repo, dom, tree} = happy()

      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_base} circle.cg-node-dot")

      assert attr(dot, "r") == ["4"]

      assert attr(dot, "style") == [
               "fill: none; fill-opacity: 1; stroke: var(--color-base-content)"
             ]

      title = node_title(tree, "commit-node-#{dom}-#{@sha_base}")
      assert title =~ "base"
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
      {repo, dom, tree} = happy()

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c1}") ==
               "Add feature X · c1000000 · Alice · 2024-01-01 10:00"

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c3}") ==
               "Refactor Z · c3000000 · Carol · 2024-01-03 10:00 · HEAD, genesis/agent_x"

      # The base node has no author/date/refs.
      assert node_title(tree, "commit-node-#{dom}-#{@sha_base}") == "base · b0000000"
      assert repo.node_count == 5
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
      assert text(Floki.find(row, ".cg-row-message")) == "Add feature X"
      assert text(Floki.find(row, ".cg-row-meta")) == "Alice · 2024-01-01 10:00"
    end

    test "a base node row shows the 'base' chip and no message" do
      {_repo, dom, tree} = happy()

      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_base}")

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
      {repo, dom, tree} = happy()

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
      [base_start] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_base}-start-a1")
      assert attr(base_start, "phx-value-id") == ["a1"]
      assert repo.node_count == 5
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

      [head] = Floki.find(tree, "#commit-ref-tag-#{dom}-#{@sha_c3}-HEAD")
      assert text(head) == "HEAD"
      assert attr(head, "title") == ["HEAD"]
      assert attr(head, "phx-click") == []

      # A slash in the ref name is folded to a dash in the id.
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-#{@sha_c3}-genesis-agent_x") != []
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
      assert Floki.text(readout) =~ "Selected T2 · c2000000 → c3000000"
    end

    test "the readout is omitted when nothing is selected or the selection is foreign" do
      {_repo, dom, tree} = happy()
      assert Floki.find(tree, "#cg-selection-readout-#{dom}") == []

      {_repo2, dom2, tree2} = happy_selected("someone-else")
      assert Floki.find(tree2, "#cg-selection-readout-#{dom2}") == []
    end

    test "the selected agent's START dot wears a SOLID ring and its END dot a DASHED ring" do
      {_repo, dom, tree} = happy_selected("a2")

      # c2000000 is a2's start → solid ring (no dasharray).
      [start_ring] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2} circle.cg-node-ring")
      assert attr(start_ring, "stroke-dasharray") == []
      assert attr(start_ring, "style") == ["fill: none; stroke: var(--color-primary)"]

      # c3000000 is a2's end → dashed ring.
      [end_ring] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-node-ring")
      assert attr(end_ring, "stroke-dasharray") == ["3 2"]

      # No other node is ringed.
      assert Floki.find(tree, "circle.cg-node-ring") |> length() == 2
    end

    test "the selected agent's start/end rows are accented and carry a start/end marker" do
      {_repo, dom, tree} = happy_selected("a2")

      [start_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c2}")
      assert attr(start_row, "class") |> hd() =~ "ring-1 ring-inset ring-primary/40"
      assert Floki.text(Floki.find(start_row, ".cg-row-marker")) =~ "start"

      [end_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c3}")
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
    test "an ended agent's nodes, edges and rows render dim" do
      {_repo, dom, tree} = happy_ended()

      # a1's owned node dots drop to half fill-opacity …
      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")

      assert attr(dot, "style") == [
               "fill: #{@depth0_color}; fill-opacity: 0.5; stroke: #{@depth0_color}"
             ]

      # … its owned edges lose stroke-opacity …
      [edge] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c1}-#{@sha_base}")
      assert attr(edge, "style") == ["stroke: #{@depth0_color}; stroke-opacity: 0.4"]

      # … and its rows dim.
      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")
      assert attr(row, "class") |> hd() =~ "opacity-50"

      # The live agent (a2) is untouched.
      [live_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-node-dot")
      assert attr(live_dot, "style") |> hd() =~ "fill-opacity: 1"

      [live_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c3}")
      refute attr(live_row, "class") |> hd() =~ "opacity-50"
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

      # Non-integer grid coordinates fold to column 0 / the rendered row index.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-42 circle.cg-node-dot")
      assert attr(dot, "cx") == ["20"]
      assert attr(dot, "cy") == ["22"]
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

  # Hand-crafted repo/node/edge/agent maps for shapes the builder does not easily
  # produce (odd/absent geometry, a fixed DOM id, unowned entries and non-map
  # entries).
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

  defp node_view(overrides) do
    Map.merge(
      %{
        sha: "deadbeef",
        short_sha: "deadbeef",
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
        ended: false
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

  # ... with a1's agent flagged `ended: true` (the exact shape the assembler
  # emits for a RETAINED / terminated in-session agent, see `CommitGraph.build/2`).
  # Only the flag is injected — the real builder output stays untouched.
  defp happy_ended do
    repos = mark_agent_ended(happy_repos(), "a1")
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
