defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView` — the
  TEMPORAL (git commit history) view of the Agents page left panel.

  `commit_graph_view/1` is purely presentational: it renders per-repo graph view
  models as a VERTICAL, GitLens-style commit graph — one row per commit
  (globally interleaved), ONE LANE PER AGENT in the left gutter, CIRCULAR dots,
  ROUNDED cross-lane routing, DASHED `:spawn` / `:merge_back` connectors, sticky
  per-lane header chips — and fires `select_agent` from the rows, the agent tags
  and the lane chips. These tests render it in isolation with
  `render_component/2` and pin the frozen DOM contract consumed by the
  client-side `CommitGraph` hook / CSS animation. All fixtures are HAND-CRAFTED
  view models (`repo_view/1`, `node_view/1`, `edge_view/1`, `agent_map/1`) and
  intentionally do NOT go through `CommitGraph.build/2` (the builder has its own
  unit suite; this file pins RENDERING only).

  Pinned surfaces: `#commit-graph` (+ hook) → `#commit-graph-body-<node_key>` →
  one section per repo whose id IS `repo_dom_id` VERBATIM (carrying the
  `cg-repo` class) → `#cg-scroll-<dom>`
  hosting the sticky `#cg-lane-header-<dom>` chips (agent buttons + the neutral
  "Pre-task" span) and the `relative` `#cg-list-<dom>` (absolute `svg.cg-gutter`
  + `.cg-rows` left-padded by the gutter width), the optional dimmed
  `#cg-truncated-<dom>` strip at its bottom; ONE `div.cg-row` / `g.cg-node` /
  `path.cg-edge` per model entry with stable ids, rounded routing and the
  kind-dependent stroke; selection rings (`circle.cg-node-ring`), row accents and
  the `#cg-selection-readout-<dom>`; ended-agent dimming; and the loading /
  empty / error / stale states plus defensive degradation of odd model shapes.

  Folded runs (the builder's synthetic `kind: :gap` node) are pinned too:
  `#commit-gap-row-<dom>-<fold_key>` (`div.cg-row.cg-gap-row`, chevron,
  `toggle_commit_fold` + `phx-value-fold-key`, the restored rows beside an
  `expanded: true` marker), the row's `data-cg-fold-key` (the RAW run key the
  client hook toggles, omitted entirely when the model carries none) beside the
  DOM-SANITIZED id slice, the `g.cg-gap-node` hollow gutter marker (no ring,
  no agent/ref tags) and the per-repo `#cg-fold-<dom>-expand-all` /
  `-collapse-all` controls gated on `fold_count > 0`.

  A shared NO-MID-AIR-EDGE invariant sweeps every geometrically consistent
  edge-bearing fixture: each `path.cg-edge` must end on a rendered dot (commit
  or gap marker) or on its documented `to_sha: nil` virtual landing.

  Note: Floki lowercases attribute names, so the SVG's `viewBox` is queried as
  `viewbox`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsComponents.CommitGraphView
  alias EvoDashWeb.AgentsComponents.CommitGraphView.Geometry

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

  # Geometry constants: @row_h 44, @col_w 24, @gutter_pad 12, @node_r 6,
  # @base_r 4, @bend_r 7, @exit_gap 2 → dot_x(lane) = 24 + 24 * lane,
  # dot_y(row) = 44 * row + 22. The happy fixture: 3 lanes, rows 0..5 plus a
  # virtual merge-back landing at lane 1 / row 6 → gutter_w 96, total_h 308.
  @dom "commit-graph-repo-happy-1"
  @happy_gutter_w 96
  @happy_gutter_h 308

  describe "commit_graph_view/1 — root markers & states" do
    test "renders the #commit-graph hook root wrapping the node-keyed body" do
      tree = parse(render_repos(happy_repos()))

      assert [root] = Floki.find(tree, "#commit-graph")
      assert attr(root, "phx-hook") == ["CommitGraph"]
      assert attr(root, "data-cg-selected-id") == []

      # Default node key.
      assert [body] = Floki.find(tree, "#commit-graph-body-local")
      assert attr(body, "class") == ["space-y-4"]

      # Repos without an error carry no stale warning.
      assert Floki.find(tree, "#commit-graph-stale-warning") == []

      # A non-default node key changes ONLY the body id — the hook root (which
      # mounts once per page) is node-independent.
      other = parse(render_repos(happy_repos(), node_key: "remote_one"))
      assert Floki.find(other, "#commit-graph-body-remote_one") != []
      assert Floki.find(other, "#commit-graph-body-local") == []
      assert Floki.find(other, "#commit-graph") != []
    end

    test "loading / empty / error / stale states" do
      loading = parse(render_repos([], loading: true))
      assert Floki.find(loading, "#commit-graph-body-local") != []
      assert Floki.text(loading) =~ "Loading commit history…"
      assert_absent(loading, ["#commit-graph-error", "#commit-graph-stale-warning"])

      empty = parse(render_repos([]))
      assert Floki.text(empty) =~ "No commit history yet."
      assert Floki.text(empty) =~ "Start a task from the dashboard to see the commit graph here."
      assert Floki.find(empty, "#commit-graph-error") == []

      errored = parse(render_repos([], error: "boom"))
      assert [err] = Floki.find(errored, "#commit-graph-error")
      assert Floki.text(err) =~ "Could not load commit history."

      # The stale warning rides ALONGSIDE cached repos; the hard error block is
      # NOT rendered once repos exist.
      stale = parse(render_repos(happy_repos(), error: "boom"))
      assert [warning] = Floki.find(stale, "#commit-graph-stale-warning")
      assert Floki.text(warning) =~ "Showing the last loaded commit graph"
      assert Floki.find(stale, ".cg-row") != []
      assert Floki.find(stale, "#commit-graph-error") == []
    end
  end

  describe "commit_graph_view/1 — repo sections" do
    test "each repo renders one verbatim-id section with its name header above its own scroll list" do
      [repo] = happy_repos()

      other =
        repo_view(
          repo_dom_id: "commit-graph-repo-foreign-2",
          repo_name: "foreign-repo",
          nodes: [
            node_view(
              sha: "f1000000",
              message: "Foreign commit",
              author_name: "Zoe",
              date: ~U[2024-01-04 10:00:00Z],
              owner_id: nil
            )
          ]
        )

      tree = parse(render_repos([repo, other]))

      # No doubled prefix: the model's id already starts commit-graph-repo-.
      assert [section] = Floki.find(tree, "##{repo.repo_dom_id}")
      assert attr(section, "data-cg-repo-id") == [repo.repo_dom_id]

      [header, list] = element_children(section)

      # The header carries the repo display name + the hero-server-stack chip;
      # the scrollable commit list lives BELOW it.
      assert_present(header, [~s(span[title="My Project"]), "span.hero-server-stack"])
      assert Floki.text(header) =~ "My Project"
      assert Floki.find(header, "svg.cg-gutter") == []
      assert Floki.find(list, "svg.cg-gutter") != []

      # Two repos → two independent sections, gutters and scroll wrappers.
      assert Floki.find(tree, "##{other.repo_dom_id}") != []
      assert Floki.text(Floki.find(tree, "##{other.repo_dom_id}")) =~ "foreign-repo"
      assert Floki.find(tree, "svg.cg-gutter") |> length() == 2

      assert_present(tree, [
        "#cg-gutter-#{repo.repo_dom_id}",
        "#cg-gutter-#{other.repo_dom_id}",
        "#cg-scroll-#{repo.repo_dom_id}",
        "#cg-scroll-#{other.repo_dom_id}"
      ])
    end
  end

  describe "commit_graph_view/1 — scroll + gutter geometry" do
    test "the scroll wrapper hosts the sticky lane header and the list; gutter + rows geometry" do
      {repo, dom, tree} = happy()

      [scroll] = Floki.find(tree, "#cg-scroll-#{dom}")
      # ONE scroll unit on BOTH axes — the `.cg-scroll` rule in app.css owns
      # `overflow: auto` + the bounded max-height that makes the lane header
      # stick; NO Tailwind overflow utility rides the element.
      assert attr(scroll, "class") == ["cg-scroll"]

      [lane_header, list] = element_children(scroll)
      assert attr(lane_header, "id") == ["cg-lane-header-#{dom}"]

      assert_attrs(list, %{
        "id" => ["cg-list-#{dom}"],
        "class" => ["cg-list relative"],
        "data-cg-repo-id" => [dom]
      })

      [gutter, rows] = element_children(list)
      assert attr(gutter, "class") == ["cg-gutter absolute left-0 top-0 pointer-events-none"]
      assert attr(rows, "class") == ["cg-rows"]

      # The gutter svg carries the DERIVED width/height/viewBox + the aria label;
      # width == 24 + column_count * 24, height covers the virtual landing row
      # (7 rows although only 6 nodes exist).
      assert_attrs(gutter, %{
        "id" => ["cg-gutter-#{dom}"],
        "width" => [Integer.to_string(@happy_gutter_w)],
        "height" => [Integer.to_string(@happy_gutter_h)],
        "viewbox" => ["0 0 #{@happy_gutter_w} #{@happy_gutter_h}"],
        "role" => ["img"],
        "aria-label" => ["Git commit history graph"]
      })

      assert attr(rows, "style") == ["padding-left: #{@happy_gutter_w}px"]

      # One .cg-row per node, in top → bottom model order, fixed height.
      row_els = Floki.find(tree, ".cg-row")
      assert length(row_els) == length(repo.nodes)

      assert Enum.map(row_els, &(attr(&1, "id") |> hd())) ==
               for(n <- repo.nodes, do: "commit-row-#{dom}-#{n.sha}")

      assert Enum.all?(row_els, &(attr(&1, "style") == ["height: 44px"]))
      assert Enum.all?(row_els, &(attr(&1, "data-commit-graph-anim") == ["row"]))
    end

    test "a node-less repo renders the empty note; a missing column_count hint is derived" do
      empty = repo_view(nodes: [], edges: [], agents: [])
      tree = parse(render_repos([empty]))

      assert [note] = Floki.find(tree, ".cg-empty-note")
      assert Floki.text(note) =~ "No commit history for this repository."

      assert_absent(tree, [
        "#cg-gutter-#{empty.repo_dom_id}",
        "#cg-lane-header-#{empty.repo_dom_id}"
      ])

      assert Floki.find(tree, ".cg-row") == []

      # column_count hint absent/odd → derived from nodes + agent lanes:
      # max(column)+1 = 3 → 24 + 3*24 = 96; height = rows × 44 = 88.
      repo =
        repo_view(
          column_count: 0,
          nodes: [
            node_view(sha: "n0000001", column: 0, row: 0),
            node_view(sha: "n0000002", column: 2, row: 1)
          ],
          agents: [agent_map(lane: 2)]
        )

      [gutter] = Floki.find(parse(render_repos([repo])), "#cg-gutter-#{repo.repo_dom_id}")
      assert attr(gutter, "width") == ["96"]
      assert attr(gutter, "height") == ["88"]
    end

    test "the truncation strip renders only for truncated: true, at the BOTTOM of the scroll wrapper" do
      # The key is OPTIONAL and read TOTALLY: absent, false and nil all render
      # nothing (only an explicit `truncated: true` draws the strip).
      for opts <- [[], [truncated: false], [truncated: nil]] do
        repo = repo_view([nodes: [node_view(sha: "n0000001", column: 0, row: 0)]] ++ opts)
        tree = parse(render_repos([repo]))
        assert_absent(tree, ["#cg-truncated-#{repo.repo_dom_id}", "div[id^='cg-truncated-']"])
        # The rows still render — the strip is the only thing gated.
        assert Floki.find(tree, ".cg-row") != []
      end

      repo = repo_view(nodes: [node_view(sha: "n0000001", column: 0, row: 0)], truncated: true)
      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      [strip] = Floki.find(tree, "#cg-truncated-#{dom}")
      assert Floki.find(strip, "span.hero-information-circle") != []
      assert text(Floki.find(strip, "span.min-w-0")) == "Older commits are not shown (limit 100)"

      # Inside the scroll wrapper, AFTER the list (the last child).
      [scroll] = Floki.find(tree, "#cg-scroll-#{dom}")
      assert Floki.find(scroll, "#cg-truncated-#{dom}") != []
      assert scroll |> element_children() |> List.last() |> attr("id") == ["cg-truncated-#{dom}"]
    end
  end

  describe "commit_graph_view/1 — lane header chips" do
    test "one chip per lane at the lane's x: neutral span + agent buttons with dots and stagger rows" do
      {_repo, dom, tree} = happy()

      [header] = Floki.find(tree, "#cg-lane-header-#{dom}")
      assert [class] = attr(header, "class")
      assert class =~ "cg-lane-header"
      assert class =~ "sticky"
      assert class =~ "top-0"
      assert attr(header, "style") == ["width: #{@happy_gutter_w}px"]

      # Lane 0 (unowned pre-task nodes exist): a NON-clickable span.
      [neutral] = Floki.find(tree, "#cg-lane-#{dom}-0")
      assert {"span", _, _} = neutral
      assert attr(neutral, "class") |> hd() =~ "cg-lane-chip-neutral"
      assert attr(neutral, "phx-click") == []
      assert text(neutral) == "Pre-task"
      assert attr(neutral, "title") == ["Pre-task"]

      # Agent lanes: clickable buttons labelled T<n> in the depth hue, anchored
      # at the lane's dot-x (48 / 72) with the shared status-dot colour.
      [chip_a1] = Floki.find(tree, "#cg-lane-#{dom}-1")
      assert {"button", _, _} = chip_a1
      assert [a1_class] = attr(chip_a1, "class")
      assert a1_class =~ "cg-lane-chip"
      refute a1_class =~ "cg-lane-chip-neutral"

      assert_attrs(chip_a1, %{
        "phx-click" => ["select_agent"],
        "phx-value-id" => ["a1"],
        "title" => ["T1 · Running"],
        "style" => [
          "position: absolute; left: 48px; transform: translateX(-50%); border-color: #{@depth0_color}; color: #{@depth0_color}; opacity: 1"
        ]
      })

      assert Floki.text(chip_a1) =~ "T1"
      assert [dot] = Floki.find(chip_a1, "span[style*='background-color']")
      assert attr(dot, "style") == ["background-color: var(--color-success)"]

      [chip_a2] = Floki.find(tree, "#cg-lane-#{dom}-2")
      assert attr(chip_a2, "phx-value-id") == ["a2"]
      assert attr(chip_a2, "style") |> hd() =~ "left: 72px"
      assert attr(chip_a2, "style") |> hd() =~ "border-color: #{@depth1_color}"
      assert Floki.text(chip_a2) =~ "T2"
      assert [dot2] = Floki.find(chip_a2, "span[style*='background-color']")
      assert attr(dot2, "style") == ["background-color: var(--color-base-content)"]

      # Exactly one chip per lane.
      assert Floki.find(tree, ".cg-lane-chip") |> length() == 3

      # Even lanes (0, 2) on chip row 0, odd lanes (1) on chip row 1 — two 18px
      # strips inside the header.
      strips = Floki.find(header, "div.absolute")
      assert length(strips) == 2

      assert Enum.sort(Enum.map(strips, &(attr(&1, "style") |> hd()))) ==
               ["top: 0px; height: 18px", "top: 18px; height: 18px"]

      [top, bottom] = Enum.sort_by(strips, &(attr(&1, "style") |> hd()))
      assert_present(top, ["#cg-lane-#{dom}-0", "#cg-lane-#{dom}-2"])
      assert Floki.find(bottom, "#cg-lane-#{dom}-1") != []
    end

    test "a claimed lane 0 gets a button; a node-less agent lane still gets its chip" do
      claimed =
        repo_view(
          nodes: [node_view(sha: "n0000001", owner_id: "hand1", column: 0, row: 0)],
          agents: [agent_map(lane: 0)]
        )

      tree = parse(render_repos([claimed]))

      # Lane 0 is claimed by the agent → a button, never a "Pre-task" span.
      assert [chip0] = Floki.find(tree, "#cg-lane-#{claimed.repo_dom_id}-0")
      assert {"button", _, _} = chip0
      assert Floki.find(tree, ".cg-lane-chip-neutral") == []
      refute Floki.text(tree) =~ "Pre-task"

      ghost =
        repo_view(
          nodes: [node_view(sha: "n0000001", column: 1, row: 0, owner_id: "a1")],
          agents: [
            agent_map(agent_id: "a1", lane: 1),
            agent_map(agent_id: "ghost9", task_local_id: 9, lane: 2)
          ]
        )

      gtree = parse(render_repos([ghost]))

      assert [chip] = Floki.find(gtree, "#cg-lane-#{ghost.repo_dom_id}-2")
      assert {"button", _, _} = chip
      assert Floki.text(chip) =~ "T9"
      assert attr(chip, "phx-value-id") == ["ghost9"]

      # The node-less lane still contributes a gutter column: lanes 0..2 → 96.
      [gutter] = Floki.find(gtree, "#cg-gutter-#{ghost.repo_dom_id}")
      assert attr(gutter, "width") == ["96"]
    end
  end

  describe "commit_graph_view/1 — edges" do
    test "one path per edge: stable ids, solid :parent vs dashed others, rounded routing, owner hue" do
      {repo, dom, tree} = happy()
      edges = Floki.find(tree, "path.cg-edge")

      assert length(edges) == length(repo.edges)
      assert Enum.all?(edges, &(attr(&1, "data-commit-graph-anim") == ["edge"]))
      assert Enum.all?(edges, &(attr(&1, "fill") == ["none"]))

      ids = Enum.map(edges, &(attr(&1, "id") |> hd()))

      expected = [
        "commit-edge-#{dom}-#{@sha_b1}-#{@sha_p1}",
        "commit-edge-#{dom}-#{@sha_c1}-#{@sha_b1}",
        "commit-edge-#{dom}-#{@sha_c1}-#{@sha_p1}",
        "commit-edge-#{dom}-#{@sha_c2}-#{@sha_c1}",
        "commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}",
        "commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6",
        "commit-edge-#{dom}-#{@sha_c4}-#{@sha_c3}"
      ]

      assert ids == expected
      assert ids == Enum.uniq(ids)

      # A same-lane edge is a plain straight vertical line (c1 → b1, lane 1,
      # rows 2 → 1: x = 48 the whole way).
      [straight] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c1}-#{@sha_b1}")
      assert attr(straight, "d") == ["M 48 110 L 48 66"]
      refute attr(straight, "d") |> hd() =~ "Q"

      # A cross-lane edge routes orthogonally with ROUNDED Q corners
      # (b1 48,66 → p1 24,22 with 7px quarter-turns at the y-midpoint 44) and is
      # a SOLID width-2 :parent edge.
      [parent_el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_b1}-#{@sha_p1}")
      assert attr(parent_el, "stroke-width") == ["2"]
      assert attr(parent_el, "stroke-dasharray") == []

      assert attr(parent_el, "d") == [
               "M 48 66 L 48 51 Q 48 44 41 44 L 31 44 Q 24 44 24 37 L 24 22"
             ]

      # NEVER the sharp double-corner (`M .. L .. L .. L ..`) signature.
      for el <- edges do
        d = attr(el, "d") |> hd()
        refute d =~ ~r/L \S+ \S+ L \S+ \S+ L \S+ \S+/, "sharp corners in: #{d}"
      end

      # :merge / :spawn / :merge_back are dashed 4 3 at width 1.6.
      for id <- [
            "commit-edge-#{dom}-#{@sha_c1}-#{@sha_p1}",
            "commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}",
            "commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6"
          ] do
        [el] = Floki.find(tree, "##{id}")
        assert_attrs(el, %{"stroke-width" => ["1.6"], "stroke-dasharray" => ["4 3"]})
      end

      # A spawn departs BELOW its fork node (c2 at y 154 → M y 162) and lands on
      # c3's center-y 198 with rounded bends (midpoint 180).
      [spawn] = Floki.find(tree, "#commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}")
      d = attr(spawn, "d") |> hd()
      assert path_start(d) == {48, 162}
      assert d == "M 48 162 L 48 173 Q 48 180 55 180 L 65 180 Q 72 180 72 187 L 72 198"

      # A merge_back to a VIRTUAL landing (to_sha nil) uses the l<col>r<row> key
      # and ends at the parent lane's coordinates; it is the SECOND member of the
      # lane pair {1, 2} (the spawn above is the first), so the batch-aware
      # router STAGGERS its jog 8px above its own span midpoint 268 — never
      # colliding with the spawn's canonical jog.
      [back] = Floki.find(tree, "#commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6")
      assert attr(back, "id") == ["commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6"]

      assert attr(back, "d") == [
               "M 72 250 L 72 253 Q 72 260 65 260 L 55 260 Q 48 260 48 267 L 48 286"
             ]

      # The stroke is the owner's depth hue (a2 depth 1); a1's own edge carries
      # the depth-0 hue.
      for id <- [
            "commit-edge-#{dom}-#{@sha_c4}-#{@sha_c3}",
            "commit-edge-#{dom}-spawn-a2-#{@sha_c2}-#{@sha_c3}",
            "commit-edge-#{dom}-merge_back-a2-#{@sha_c4}-l1r6"
          ] do
        [el] = Floki.find(tree, "##{id}")
        assert attr(el, "style") == ["stroke: #{@depth1_color}; stroke-opacity: 0.75"]
      end

      [a1_el] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c2}-#{@sha_c1}")
      assert attr(a1_el, "style") == ["stroke: #{@depth0_color}; stroke-opacity: 0.75"]
    end

    test "an edge whose owner is not one of the repo's agents stays muted" do
      [bare] = ghost_owner_edge_repos()

      [ghost] =
        Floki.find(
          parse(render_repos([bare])),
          "#commit-edge-#{bare.repo_dom_id}-x0000001-y0000001"
        )

      assert attr(ghost, "style") == ["stroke: var(--color-base-content); stroke-opacity: 0.3"]
    end

    test "an absent endpoint falls back to the edge's own column/row; a LONE pair edge keeps the canonical midpoint" do
      [repo] = absent_endpoint_repos()

      [el] = Floki.find(parse(render_repos([repo])), "path.cg-edge")

      # dot_x(1) = 48, dot_y(3) = 154 → dot_x(0) = 24, dot_y(0) = 22, rounded at
      # the y-midpoint 88 — the batch-aware router only staggers a lane pair's
      # SECOND member, so a lone edge is pixel-identical to the canonical route.
      assert attr(el, "d") == ["M 48 154 L 48 95 Q 48 88 41 88 L 31 88 Q 24 88 24 81 L 24 22"]
    end

    test "concurrent edges sharing a lane pair are STAGGERED onto distinct routes" do
      # Two agent-level connectors over the SAME unordered lane pair {0, 1}: a
      # :spawn f → x (lane 1 → lane 0) and a :merge_back y → a virtual landing
      # back on lane 1.
      [repo] = concurrent_lane_pair_repos()

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      [spawn_el] = Floki.find(tree, "#commit-edge-#{dom}-spawn-a1-f0000001-x0000001")
      [back_el] = Floki.find(tree, "#commit-edge-#{dom}-merge_back-a1-y0000001-l1r4")

      spawn_d = attr(spawn_el, "d") |> hd()
      back_d = attr(back_el, "d") |> hd()

      # Two DIFFERENT, non-empty routes — the pair never collapses onto
      # identical pixels.
      assert is_binary(spawn_d) and spawn_d != ""
      assert is_binary(back_d) and back_d != ""
      assert spawn_d != back_d

      # The group's first member keeps its own midpoint; the second walks 8px
      # (@jog_clear) outward — jog ys 48 vs 166.
      assert jog_y(spawn_d) == 48
      assert jog_y(back_d) == 166
    end

    test "an edge whose endpoints collapse is omitted" do
      [repo] = collapsed_edge_repos()

      assert Floki.find(parse(render_repos([repo])), "path.cg-edge") == []
    end
  end

  describe "commit_graph_view/1 — nodes" do
    test "one g.cg-node per node: data attrs, dot geometry/hues, stub and tooltips" do
      {repo, dom, tree} = happy()

      nodes = Floki.find(tree, "g.cg-node")
      assert length(nodes) == length(repo.nodes)
      assert Enum.all?(nodes, &(attr(&1, "data-commit-graph-anim") == ["node"]))

      assert_present(tree, for(n <- repo.nodes, do: "#commit-node-#{dom}-#{n.sha}"))

      # The row 2 / lane 1 commit: a CIRCLE centred at x 48, y 2*44+22 = 110, r 6.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1} circle.cg-node-dot")

      assert_attrs(dot, %{
        "cx" => ["48"],
        "cy" => ["110"],
        "r" => ["6"],
        "style" => ["fill: #{@depth0_color}; fill-opacity: 1; stroke: #{@depth0_color}"]
      })

      # The row 4 / lane 2 commit: cx 72, cy 198.
      [c3_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3} circle.cg-node-dot")
      assert attr(c3_dot, "cx") == ["72"]
      assert attr(c3_dot, "cy") == ["198"]

      # a1's END commit takes the shared status colour (:running → success).
      [end_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2} circle.cg-node-dot")

      assert attr(end_dot, "style") == [
               "fill: var(--color-success); fill-opacity: 1; stroke: var(--color-success)"
             ]

      # A base node is a hollow smaller circle, with a 'base' tooltip prefix.
      [base_dot] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_b1} circle.cg-node-dot")

      assert_attrs(base_dot, %{
        "cx" => ["48"],
        "cy" => ["66"],
        "r" => ["4"],
        "style" => ["fill: none; fill-opacity: 1; stroke: var(--color-base-content)"]
      })

      # Tooltips join message · sha · author · date · refs (the base stub keeps
      # its 'base' prefix and the first message line only).
      assert node_title(tree, "commit-node-#{dom}-#{@sha_b1}") == "base · #{@sha_b1}"

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c1}") ==
               "Merge pre-task history · c1000000 · Alice · 2024-01-01 10:00"

      assert node_title(tree, "commit-node-#{dom}-#{@sha_c4}") ==
               "Refactor Z · c4000000 · Dave · 2024-01-03 10:00 · HEAD, genesis/agent_x"
    end

    test "a :noop stub mirrors a base stub; an unowned node is muted" do
      noop =
        repo_view(
          nodes: [node_view(sha: "n0000001", kind: :noop, message: nil, author_name: nil)],
          agents: [agent_map([])]
        )

      tree = parse(render_repos([noop]))
      dom = noop.repo_dom_id

      [dot] = Floki.find(tree, "#commit-node-#{dom}-n0000001 circle.cg-node-dot")
      assert attr(dot, "r") == ["4"]

      assert attr(dot, "style") == [
               "fill: none; fill-opacity: 1; stroke: var(--color-base-content)"
             ]

      [row] = Floki.find(tree, ".cg-row")
      assert text(Floki.find(row, ".cg-base-label")) == "no-op"
      assert Floki.find(row, ".cg-row-message") == []
      assert node_title(tree, "commit-node-#{dom}-n0000001") == "no-op · n0000001"

      unowned =
        repo_view(nodes: [node_view(sha: "n0000001", owner_id: nil)], agents: [agent_map([])])

      [udot] =
        Floki.find(
          parse(render_repos([unowned])),
          "#commit-node-#{unowned.repo_dom_id}-n0000001 circle.cg-node-dot"
        )

      assert attr(udot, "style") == [
               "fill: var(--color-base-content); fill-opacity: 0.55; stroke: var(--color-base-content)"
             ]
    end
  end

  describe "commit_graph_view/1 — rows" do
    test "an owned row carries the click contract, sha/message/meta; a base row has the chip" do
      {_repo, dom, tree} = happy()

      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")

      assert_attrs(row, %{
        "phx-click" => ["select_agent"],
        "phx-value-id" => ["a1"],
        "data-cg-sha" => [@sha_c1],
        "data-cg-agent-id" => ["a1"]
      })

      # c1000000's raw message carries a body line — only the first line renders.
      assert text(Floki.find(row, ".cg-row-sha")) == "c1000000"
      assert text(Floki.find(row, ".cg-row-message")) == "Merge pre-task history"
      assert text(Floki.find(row, ".cg-row-meta")) == "Alice · 2024-01-01 10:00"

      [base_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_b1}")
      assert text(Floki.find(base_row, ".cg-base-label")) == "base"
      assert Floki.find(base_row, ".cg-row-message") == []
      assert Floki.find(base_row, ".cg-row-meta") == []
    end

    test "an unowned row omits the click contract but keeps a stable id" do
      repo =
        repo_view(nodes: [node_view(sha: "n0000002", owner_id: nil)], agents: [agent_map([])])

      [row] = Floki.find(parse(render_repos([repo])), ".cg-row")

      assert_attrs(row, %{
        "id" => ["commit-row-#{repo.repo_dom_id}-n0000002"],
        "phx-click" => [],
        "phx-value-id" => [],
        "data-cg-agent-id" => []
      })
    end
  end

  describe "commit_graph_view/1 — row tooltips, keyboard access, selection data" do
    test "every row carries the node tooltip; owned rows are keyboard-reachable, unowned ones are not" do
      {_repo, dom, tree} = happy()

      # The gutter svg is pointer-events: none, so the SAME node_title/1 content
      # rides the row div's native title.
      [row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")

      assert attr(row, "title") == [
               "Merge pre-task history · c1000000 · Alice · 2024-01-01 10:00"
             ]

      [row4] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c4}")

      assert attr(row4, "title") == [
               "Refactor Z · c4000000 · Dave · 2024-01-03 10:00 · HEAD, genesis/agent_x"
             ]

      [base_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_b1}")
      assert attr(base_row, "title") == ["base · #{@sha_b1}"]

      # Every row — owned or not — carries one.
      assert Floki.find(tree, ".cg-row") |> length() == length(Floki.find(tree, ".cg-row[title]"))

      assert attr(row, "role") == ["button"]
      assert attr(row, "tabindex") == ["0"]

      # The neutral pre-task row has no click contract and no button role.
      [unowned] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_p1}")
      assert_attrs(unowned, %{"phx-click" => [], "role" => [], "tabindex" => []})

      # Unselected → no readout.
      assert Floki.find(tree, "#cg-selection-readout-#{dom}") == []
    end

    test "the root carries the selection as data-cg-selected-id (stringified raw term)" do
      repos = happy_repos()

      selected = parse(render_repos(repos, selected_id: "a2"))
      assert attr(hd(Floki.find(selected, "#commit-graph")), "data-cg-selected-id") == ["a2"]

      # An integer selection stringifies exactly like the rows' data-cg-agent-id.
      int_repos = [
        repo_view(
          nodes: [node_view(sha: "n0000001", owner_id: 42)],
          agents: [agent_map(agent_id: 42, task_local_id: 5)]
        )
      ]

      int_tree = parse(render_repos(int_repos, selected_id: 42))

      [row] = Floki.find(int_tree, ".cg-row")
      assert attr(row, "data-cg-agent-id") == ["42"]
      assert attr(hd(Floki.find(int_tree, "#commit-graph")), "data-cg-selected-id") == ["42"]
    end
  end

  describe "commit_graph_view/1 — tags" do
    test "start/end chips + refs: markers, hues, tooltips and the click contract" do
      {_repo, dom, tree} = happy()

      # c2000000 is a1's END commit AND a2's START commit (a fork point).
      [start_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_c2}-start-a2")
      assert [start_class] = attr(start_chip, "class")
      assert start_class =~ "cg-agent-tag-start"
      assert start_class =~ "border-solid"

      assert_attrs(start_chip, %{
        "phx-click" => ["select_agent"],
        "phx-value-id" => ["a2"],
        "title" => ["T2 · start · Completed"],
        "style" => ["border-color: #{@depth1_color}; color: #{@depth1_color}"]
      })

      assert Floki.text(start_chip) =~ "T2"
      assert Floki.text(start_chip) =~ "start"

      [end_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_c2}-end-a1")
      assert [end_class] = attr(end_chip, "class")
      assert end_class =~ "cg-agent-tag-end"
      assert end_class =~ "border-dashed"

      assert_attrs(end_chip, %{
        "phx-value-id" => ["a1"],
        "title" => ["T1 · end · Running"],
        "style" => ["border-color: #{@depth0_color}; color: #{@depth0_color}"]
      })

      assert Floki.text(end_chip) =~ "T1"
      assert Floki.text(end_chip) =~ "end"

      # a1 forks at the base node → a start tag there.
      [base_start] = Floki.find(tree, "#commit-agent-tag-#{dom}-#{@sha_b1}-start-a1")
      assert attr(base_start, "phx-value-id") == ["a1"]

      # Refs render as non-clickable mono chips.
      assert Floki.find(tree, "span.cg-ref-tag") |> length() == 2

      [head] = Floki.find(tree, "#commit-ref-tag-#{dom}-#{@sha_c4}-HEAD")
      assert text(head) == "HEAD"
      assert attr(head, "title") == ["HEAD"]
      assert attr(head, "phx-click") == []

      # A slash in the ref name is folded to a dash in the id.
      assert Floki.find(tree, "#commit-ref-tag-#{dom}-#{@sha_c4}-genesis-agent_x") != []
    end

    test "an unknown agent id falls back to the raw id + muted colour; a tag-less node renders no tag row" do
      ghost = repo_view(nodes: [node_view(sha: "n0000001", start_ids: ["ghost"])], agents: [])
      tree = parse(render_repos([ghost]))
      dom = ghost.repo_dom_id

      [chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-n0000001-start-ghost")
      assert Floki.text(chip) =~ "Tghost"
      assert attr(chip, "phx-value-id") == ["ghost"]

      assert attr(chip, "style") == [
               "border-color: var(--color-base-content); color: var(--color-base-content)"
             ]

      bare = repo_view(nodes: [node_view(sha: "n0000001")], agents: [agent_map([])])

      [row] = Floki.find(parse(render_repos([bare])), ".cg-row")
      assert Floki.find(row, ".cg-agent-tag") == []
      assert Floki.find(row, ".cg-ref-tag") == []
    end
  end

  describe "commit_graph_view/1 — selection" do
    test "the readout names the selected agent; its start/end dots wear solid/dashed rings and its rows are accented" do
      {_repo, dom, tree} = happy_selected("a2")

      [readout] = Floki.find(tree, "#cg-selection-readout-#{dom}")
      assert Floki.text(readout) =~ "Selected T2 · c3000000 → c4000000"

      # c2000000 is a2's start (its fork point, on a1's lane) → SOLID ring at
      # (48, 154) with r = 6 + 3 = 9.
      [start_ring] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2} circle.cg-node-ring")

      assert_attrs(start_ring, %{
        "cx" => ["48"],
        "cy" => ["154"],
        "r" => ["9"],
        "stroke-dasharray" => [],
        "style" => ["fill: none; stroke: var(--color-primary)"]
      })

      # c4000000 is a2's end → DASHED ring at (72, 242). No other node is ringed.
      [end_ring] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c4} circle.cg-node-ring")

      assert_attrs(end_ring, %{
        "cx" => ["72"],
        "cy" => ["242"],
        "r" => ["9"],
        "stroke-dasharray" => ["3 2"]
      })

      assert Floki.find(tree, "circle.cg-node-ring") |> length() == 2

      [start_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c2}")
      assert attr(start_row, "class") |> hd() =~ "ring-1 ring-inset ring-primary/40"
      assert Floki.text(Floki.find(start_row, ".cg-row-marker")) =~ "start"

      # The end row is owned by the selected agent → also gets the bg accent.
      [end_row] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c4}")
      assert attr(end_row, "class") |> hd() =~ "ring-primary/40"
      assert attr(end_row, "class") |> hd() =~ "bg-primary/10"
      assert Floki.text(Floki.find(end_row, ".cg-row-marker")) =~ "end"

      # Unrelated rows carry neither accent.
      [other] = Floki.find(tree, "#commit-row-#{dom}-#{@sha_c1}")
      refute attr(other, "class") |> hd() =~ "ring-primary/40"
      assert Floki.find(other, ".cg-row-marker") == []
    end

    test "the readout is omitted for a foreign selection" do
      {_repo, dom, tree} = happy_selected("someone-else")
      assert Floki.find(tree, "#cg-selection-readout-#{dom}") == []
    end
  end

  describe "commit_graph_view/1 — ended dimming" do
    test "an ended agent dims its nodes, edges, rows and lane chip; a live/absent flag does not" do
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

      # A live agent with the OPTIONAL `ended` flag absent renders identically.
      {_repo2, dom2, live_tree} = happy()
      [flagless_dot] = Floki.find(live_tree, "#commit-node-#{dom2}-#{@sha_c1} circle.cg-node-dot")
      assert attr(flagless_dot, "style") |> hd() =~ "fill-opacity: 1"
    end
  end

  describe "commit_graph_view/1 — total / defensive degradation" do
    test "non-map entries are dropped; non-list model fields fold to empty" do
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

      folded = parse(render_repos([repo_view(nodes: :nope, edges: nil, agents: %{})]))
      assert Floki.find(folded, ".cg-empty-note") != []
      assert Floki.find(folded, ".cg-row") == []
    end

    test "odd grid values and non-binary shas/agent ids degrade to DOM-safe ids" do
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
      assert_present(tree, ["#commit-node-#{dom}-42", "#commit-row-#{dom}-z0000001"])

      # Non-integer grid coordinates fold to lane 0 / row 0 → the dot is centred
      # at (24, 22) with radius 6.
      [dot] = Floki.find(tree, "#commit-node-#{dom}-42 circle.cg-node-dot")
      assert_attrs(dot, %{"cx" => ["24"], "cy" => ["22"], "r" => ["6"]})

      # An integer agent/owner id yields a DOM-safe id fragment and phx value.
      int_repo =
        repo_view(
          nodes: [node_view(sha: "n0000001", owner_id: 42, start_ids: [42])],
          agents: [agent_map(agent_id: 42, task_local_id: 5)]
        )

      int_tree = parse(render_repos([int_repo]))
      idom = int_repo.repo_dom_id

      assert Floki.find(int_tree, "#commit-agent-tag-#{idom}-n0000001-start-42") != []

      assert Floki.find(int_tree, "#commit-row-#{idom}-n0000001") |> hd() |> attr("phx-value-id") ==
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
      assert_present(tree, [
        "#commit-ref-tag-#{dom}-n0000001-main",
        "#commit-ref-tag-#{dom}-n0000001-x",
        "#commit-ref-tag-#{dom}-n0000001-y"
      ])

      assert Floki.find(tree, "#commit-ref-tag-#{dom}-n0000001-42") == []
      assert Floki.find(tree, "span.cg-ref-tag") |> length() == 3
    end
  end

  describe "commit_graph_view/1 — folded runs (gap rows)" do
    test "a collapsed gap node renders a gap row inside the scroll wrapper — never a commit row" do
      [repo] = fold_repos()
      dom = repo.repo_dom_id
      tree = parse(render_repos([repo]))

      # INSIDE the scroll wrapper (so it scrolls with the rows it stands in for).
      [scroll] = Floki.find(tree, "#cg-scroll-#{dom}")
      [gap_row] = Floki.find(scroll, "#commit-gap-row-#{dom}-f1-a1")

      [class] = attr(gap_row, "class")
      assert class =~ "cg-row"
      assert class =~ "cg-gap-row"
      assert class =~ "border-dashed"

      assert_attrs(gap_row, %{
        "id" => ["commit-gap-row-#{dom}-f1-a1"],
        "data-commit-graph-anim" => ["row"],
        "data-cg-sha" => ["gap-f1-a1"],
        "data-cg-agent-id" => ["a1"],
        "style" => ["height: 44px"],
        "phx-click" => ["toggle_commit_fold"],
        "phx-value-fold-key" => ["f1-a1"],
        "role" => ["button"],
        "tabindex" => ["0"],
        "title" => ["12 commits"]
      })

      # A chevron (collapsed → pointing DOWN) and the muted hidden-count label.
      assert Floki.find(gap_row, "span.hero-chevron-down") != []
      assert Floki.find(gap_row, "span.hero-chevron-up") == []
      assert text(Floki.find(gap_row, ".cg-gap-label")) =~ "12 commits"

      # It is NOT a commit row: no commit-row id, no sha/meta/message cells.
      assert_absent(tree, ["#commit-row-#{dom}-gap-f1-a1"])
      assert Floki.find(gap_row, ".cg-row-sha") == []
      assert Floki.find(gap_row, ".cg-row-message") == []
      assert Floki.find(gap_row, ".cg-row-meta") == []

      # ... and it is NEVER a :base / :noop stub.
      assert Floki.find(gap_row, ".cg-base-label") == []
      refute text(gap_row) =~ "base"
      refute text(gap_row) =~ "no-op"

      # The real commit row above it renders normally, and the rows keep the
      # model's top → bottom order.
      [rows] = Floki.find(tree, ".cg-rows")

      assert Enum.map(element_children(rows), &(attr(&1, "id") |> hd())) == [
               "commit-row-#{dom}-n0000001",
               "commit-gap-row-#{dom}-f1-a1"
             ]
    end

    test "an expanded gap renders the chevron-up variant and its restored rows alongside it" do
      [repo] = fold_repos(expanded: true)
      dom = repo.repo_dom_id
      tree = parse(render_repos([repo]))

      # The SAME gap row is now the run's COLLAPSE control.
      [gap_row] = Floki.find(tree, "#commit-gap-row-#{dom}-f1-a1")
      assert Floki.find(gap_row, "span.hero-chevron-up") != []
      assert Floki.find(gap_row, "span.hero-chevron-down") == []
      assert attr(gap_row, "phx-click") == ["toggle_commit_fold"]
      assert attr(gap_row, "phx-value-fold-key") == ["f1-a1"]

      # ... and the run's commits are restored as NORMAL rows in the same repo.
      [rows] = Floki.find(tree, ".cg-rows")

      assert Enum.map(element_children(rows), &(attr(&1, "id") |> hd())) == [
               "commit-row-#{dom}-n0000001",
               "commit-gap-row-#{dom}-f1-a1",
               "commit-row-#{dom}-r0000001",
               "commit-row-#{dom}-r0000002"
             ]

      assert Floki.find(tree, "#commit-row-#{dom}-r0000001") != []
      assert Floki.find(tree, "#commit-row-#{dom}-r0000002") != []
      assert text(Floki.find(tree, "##{dom}")) =~ "Restored one"
    end

    test "the gap's gutter marker is a hollow dot with no ring, no tags and a count tooltip" do
      [repo] = fold_repos()
      dom = repo.repo_dom_id
      tree = parse(render_repos([repo]))

      [node] = Floki.find(tree, "g.cg-gap-node#commit-node-#{dom}-gap-f1-a1")

      assert_attrs(node, %{
        "class" => ["cg-node cg-gap-node"],
        "data-commit-graph-anim" => ["node"],
        "data-cg-sha" => ["gap-f1-a1"],
        "data-cg-agent-id" => ["a1"]
      })

      # A HOLLOW small circle: Geometry.base_r() (the stub radius), fill: none,
      # dashed stroke in base ink.
      [circle] = Floki.find(node, "circle.cg-node-dot")

      assert_attrs(circle, %{
        "r" => [Integer.to_string(Geometry.base_r())],
        "stroke-width" => ["1.5"],
        "stroke-dasharray" => ["2 2"],
        "style" => ["fill: none; fill-opacity: 1; stroke: var(--color-base-content)"]
      })

      # Centred on its lane / row like any other node (lane 1 → x 48).
      assert attr(circle, "cx") == ["48"]

      # No selection ring, no agent tags, no ref tags — and the tooltip is the
      # hidden count, never a base/no-op label.
      assert Floki.find(node, ".cg-node-ring") == []
      assert Floki.find(node, ".cg-agent-tag") == []
      assert Floki.find(node, ".cg-ref-tag") == []
      assert node_title(tree, "commit-node-#{dom}-gap-f1-a1") == "12 commits"
    end

    test "the hidden-count label pluralizes through ngettext (singular at 1)" do
      # The rendered label is `ngettext("%{count} commit", "%{count} commits", n)`,
      # so a ONE-commit model (never emitted by the builder — a single hidden
      # commit stays a row) still renders the singular form the translator needs.
      dom = "commit-graph-repo-plural-1"

      repos = [
        repo_view(
          repo_dom_id: dom,
          nodes: [
            node_view(
              sha: "gap-one",
              column: 0,
              row: 0,
              kind: :gap,
              fold_key: "one",
              hidden_count: 1
            ),
            node_view(
              sha: "gap-many",
              column: 0,
              row: 1,
              kind: :gap,
              fold_key: "many",
              hidden_count: 3
            )
          ],
          agents: [agent_map(agent_id: "a1", lane: 0)]
        )
      ]

      tree = parse(render_repos(repos))

      [one] = Floki.find(tree, "#commit-gap-row-#{dom}-one")
      assert attr(one, "title") == ["1 commit"]
      assert text(Floki.find(one, ".cg-gap-label")) =~ "1 commit"
      refute text(Floki.find(one, ".cg-gap-label")) =~ "1 commits"

      [many] = Floki.find(tree, "#commit-gap-row-#{dom}-many")
      assert attr(many, "title") == ["3 commits"]
      assert text(Floki.find(many, ".cg-gap-label")) =~ "3 commits"

      # The gutter tooltip shares the SAME label (and therefore the plural rule).
      assert node_title(tree, "commit-node-#{dom}-gap-one") == "1 commit"
      assert node_title(tree, "commit-node-#{dom}-gap-many") == "3 commits"
    end

    test "the gap row publishes the RAW fold_key as data-cg-fold-key while its id keeps the SANITIZED form" do
      raw = "run/1 a"
      sanitized = "run-1-a"
      # The fixture's key genuinely NEEDS sanitizing for the DOM id — otherwise
      # this test could not tell the two forms apart.
      refute raw == sanitized
      [repo] = fold_key_repos(fold_key: raw)
      dom = repo.repo_dom_id
      tree = parse(render_repos([repo]))
      # Located by the SANITIZED id slice: every char outside [A-Za-z0-9_-]
      # folds to a dash.
      [gap_row] = Floki.find(tree, "#commit-gap-row-#{dom}-#{sanitized}")

      assert_attrs(gap_row, %{
        "id" => ["commit-gap-row-#{dom}-#{sanitized}"],
        "data-cg-fold-key" => [raw],
        "phx-value-fold-key" => [raw],
        "phx-click" => ["toggle_commit_fold"]
      })

      [class] = attr(gap_row, "class")
      assert class =~ "cg-row"
      assert class =~ "cg-gap-row"

      # The point of the attribute: it is the model's RAW key, NOT the DOM form
      # the id uses (the client hook toggles the run by that exact key).
      assert attr(gap_row, "data-cg-fold-key") != [sanitized]
      assert Floki.raw_html(gap_row) =~ ~s(data-cg-fold-key="#{raw}")
    end

    test "a gap node with an absent / nil fold_key renders NO data-cg-fold-key at all" do
      for opts <- [[fold_key: :absent], [fold_key: nil]] do
        [repo] = fold_key_repos(opts)
        dom = repo.repo_dom_id
        tree = parse(render_repos([repo]))
        # The gap row itself still renders — the attribute is the only gate.
        [gap_row] = Floki.find(tree, ".cg-gap-row")
        [class] = attr(gap_row, "class")
        assert class =~ "cg-gap-row"
        # The row's id slice degenerates (empty / "nil") but the row still
        # renders — only the hook-facing attribute is gated.
        assert gap_row |> attr("id") |> hd() |> String.starts_with?("commit-gap-row-#{dom}-")
        # OMITTED, not empty: HEEx drops a nil-valued attribute, so the row
        # carries no `data-cg-fold-key` key at all (an empty value would make
        # the hook think it owns a run keyed "").
        assert attr(gap_row, "data-cg-fold-key") == []
        refute Floki.raw_html(gap_row) =~ "data-cg-fold-key"
      end
    end
  end

  describe "commit_graph_view/1 — per-repo fold controls" do
    test "fold_count > 0 renders BOTH controls; 0 / absent / odd render NEITHER" do
      [repo] = fold_repos(fold_count: 2)
      dom = repo.repo_dom_id
      tree = parse(render_repos([repo]))

      [expand] = Floki.find(tree, "#cg-fold-#{dom}-expand-all")
      [collapse] = Floki.find(tree, "#cg-fold-#{dom}-collapse-all")

      assert_attrs(expand, %{
        "type" => ["button"],
        "phx-click" => ["expand_all_commit_folds"],
        "title" => ["Expand all"]
      })

      assert_attrs(collapse, %{
        "type" => ["button"],
        "phx-click" => ["collapse_all_commit_folds"],
        "title" => ["Collapse all"]
      })

      assert text(expand) == "Expand all"
      assert text(collapse) == "Collapse all"

      # They sit in the repo HEADER row (with the icon + name), not the list.
      [section] = Floki.find(tree, "##{dom}")
      [header, _list] = element_children(section)
      assert Floki.find(header, "#cg-fold-#{dom}-expand-all") != []
      assert Floki.find(header, "#cg-fold-#{dom}-collapse-all") != []

      [scroll] = Floki.find(tree, "#cg-scroll-#{dom}")
      assert Floki.find(scroll, "button[id^='cg-fold-']") == []

      # The key is OPTIONAL and read TOTALLY.
      for opts <- [[fold_count: 0], [fold_count: :absent], [fold_count: nil], [fold_count: -3]] do
        [plain] = fold_repos(opts)
        pdom = plain.repo_dom_id
        ptree = parse(render_repos([plain]))

        assert_absent(ptree, [
          "#cg-fold-#{pdom}-expand-all",
          "#cg-fold-#{pdom}-collapse-all",
          "button[id^='cg-fold-']"
        ])

        # The gap row itself still renders — the controls are the only gate.
        assert Floki.find(ptree, "#commit-gap-row-#{pdom}-f1-a1") != []
      end
    end

    test "the repo wrapper carries cg-repo and keeps its verbatim id + data-cg-repo-id" do
      [repo] = fold_repos(fold_count: 1)
      dom = repo.repo_dom_id
      tree = parse(render_repos([repo]))

      [section] = Floki.find(tree, "##{dom}")
      [class] = attr(section, "class")

      assert class =~ "cg-repo"
      assert attr(section, "id") == [dom]
      assert attr(section, "data-cg-repo-id") == [dom]

      # No doubled prefix: the id IS the model's `repo_dom_id` verbatim.
      assert Floki.find(tree, "div[id^='commit-graph-repo-commit-graph-repo-']") == []
    end
  end

  describe "commit_graph_view/1 — no mid-air edges" do
    test "every rendered edge ends on a rendered dot or on its documented virtual landing" do
      rendered =
        Enum.reduce(edge_fixtures(), 0, fn {label, repos}, acc ->
          tree = parse(render_repos(repos))

          acc +
            Enum.reduce(repos, 0, fn repo, inner ->
              inner + assert_edges_land_on_dots(tree, Map.fetch!(repo, :repo_dom_id), label)
            end)
        end)

      assert rendered > 0, "no edge was rendered — the invariant would be vacuous"
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
    nodes =
      for {sha, col, row, extra} <- [
            {@sha_p1, 0, 0,
             message: "Pre-task commit",
             author_name: "Pam",
             date: ~U[2023-12-31 09:00:00Z],
             owner_id: nil},
            {@sha_b1, 1, 1,
             message: nil,
             author_name: nil,
             date: nil,
             kind: :base,
             owner_id: "a1",
             start_ids: ["a1"]},
            {@sha_c1, 1, 2,
             message: "Merge pre-task history\n\nbody line",
             author_name: "Alice",
             date: ~U[2024-01-01 10:00:00Z],
             owner_id: "a1"},
            {@sha_c2, 1, 3,
             message: "Fix bug Y",
             author_name: "Bob",
             date: ~U[2024-01-02 10:00:00Z],
             owner_id: "a1",
             end_ids: ["a1"],
             start_ids: ["a2"]},
            {@sha_c3, 2, 4,
             message: "Side change W",
             author_name: "Carol",
             date: ~U[2024-01-02 12:00:00Z],
             owner_id: "a2"},
            {@sha_c4, 2, 5,
             message: "Refactor Z",
             author_name: "Dave",
             date: ~U[2024-01-03 10:00:00Z],
             owner_id: "a2",
             end_ids: ["a2"],
             refs: ["HEAD", "genesis/agent_x"]}
          ] do
        node_view([sha: sha, column: col, row: row] ++ extra)
      end

    edges =
      for {from, to, fc, fr, tc, tr, kind, owner} <- [
            {@sha_b1, @sha_p1, 1, 1, 0, 0, :parent, "a1"},
            {@sha_c1, @sha_b1, 1, 2, 1, 1, :parent, "a1"},
            {@sha_c1, @sha_p1, 1, 2, 0, 0, :merge, "a1"},
            {@sha_c2, @sha_c1, 1, 3, 1, 2, :parent, "a1"},
            {@sha_c2, @sha_c3, 1, 3, 2, 4, :spawn, "a2"},
            {@sha_c4, nil, 2, 5, 1, 6, :merge_back, "a2"},
            {@sha_c4, @sha_c3, 2, 5, 2, 4, :parent, "a2"}
          ] do
        edge_view(
          from_sha: from,
          to_sha: to,
          from_column: fc,
          from_row: fr,
          to_column: tc,
          to_row: tr,
          kind: kind,
          owner_id: owner
        )
      end

    agents =
      for {id, tli, status, depth, color, [start_sha, end_sha], lane, parent} <- [
            {"a1", 1, :running, 0, @depth0_color, [@sha_b1, @sha_c2], 1, nil},
            {"a2", 2, :completed, 1, @depth1_color, [@sha_c3, @sha_c4], 2, "a1"}
          ] do
        agent_map(
          agent_id: id,
          task_local_id: tli,
          status: status,
          depth: depth,
          color: color,
          start_sha: start_sha,
          end_sha: end_sha,
          lane: lane,
          parent_id: parent
        )
      end

    [
      repo_view(
        repo_dom_id: @dom,
        repo_name: "My Project",
        column_count: 3,
        node_count: 6,
        edge_count: 7,
        row_count: 7,
        nodes: nodes,
        edges: edges,
        agents: agents
      )
    ]
  end

  # --- edge / fold fixtures --------------------------------------------------

  # A folded lane: agent a1's lane 1 carries ONE run of 12 hidden commits — the
  # synthetic `kind: :gap` node the builder emits (`sha: "gap-" <> fold_key`).
  # `expanded: true` also renders the run's commits as normal rows around it;
  # `fold_count:` is `:absent` to omitting the key entirely (the controls' gate).
  defp fold_repos(opts \\ []) do
    expanded = Keyword.get(opts, :expanded, false)
    fold_count = Keyword.get(opts, :fold_count, 1)

    gap =
      node_view(
        sha: "gap-f1-a1",
        column: 1,
        row: 1,
        kind: :gap,
        fold_key: "f1-a1",
        hidden_count: 12,
        expanded: expanded,
        owner_id: "a1",
        message: nil,
        author_name: nil
      )

    restored =
      if expanded do
        [
          node_view(sha: "r0000001", column: 1, row: 2, owner_id: "a1", message: "Restored one"),
          node_view(sha: "r0000002", column: 1, row: 3, owner_id: "a1", message: "Restored two")
        ]
      else
        []
      end

    repo =
      repo_view(
        nodes: [
          node_view(sha: "n0000001", column: 1, row: 0, owner_id: "a1", message: "Tip commit")
          | [gap | restored]
        ],
        agents: [agent_map(agent_id: "a1", lane: 1)]
      )

    [if(fold_count == :absent, do: repo, else: Map.put(repo, :fold_count, fold_count))]
  end

  # A folded lane whose run key is NOT a DOM-safe string: the row's id uses the
  # folded form while `data-cg-fold-key` must keep the raw value (the client
  # hook's toggle key). `fold_key: :absent` removes the key from the model (the
  # attribute's own gate); `fold_key: nil` sets it explicitly to nil.
  defp fold_key_repos(opts) do
    fold_key = Keyword.get(opts, :fold_key, "run/1 a")

    gap =
      node_view(
        sha: "gap-run-1-a",
        column: 1,
        row: 1,
        kind: :gap,
        fold_key: fold_key,
        hidden_count: 5,
        expanded: false,
        owner_id: "a1",
        message: nil,
        author_name: nil
      )

    gap = if opts[:fold_key] == :absent, do: Map.delete(gap, :fold_key), else: gap

    [
      repo_view(
        nodes: [
          node_view(sha: "n0000001", column: 1, row: 0, owner_id: "a1", message: "Tip commit"),
          gap
        ],
        agents: [agent_map(agent_id: "a1", lane: 1)]
      )
    ]
  end

  # An edge owned by an agent the repo does not declare.
  defp ghost_owner_edge_repos do
    [
      repo_view(
        edges: [edge_view(from_sha: "x0000001", to_sha: "y0000001", owner_id: "ghost")],
        nodes: [node_view(sha: "n0000001", owner_id: nil)]
      )
    ]
  end

  # An edge whose endpoints are absent from the nodes: both take the edge's own
  # grid pair, and its landing coincides with the one rendered dot.
  defp absent_endpoint_repos do
    [
      repo_view(
        edges: [edge_view(from_sha: "x", from_column: 1, from_row: 3, to_column: 0, to_row: 0)],
        nodes: [node_view(sha: "unrelated", column: 0, row: 0)]
      )
    ]
  end

  # Two agent-level connectors over the SAME unordered lane pair {0, 1}: a
  # :spawn f → x (lane 1 → lane 0) and a :merge_back y → a virtual landing back
  # on lane 1.
  defp concurrent_lane_pair_repos do
    [
      repo_view(
        nodes: [
          node_view(sha: "f0000001", column: 1, row: 0, owner_id: "a1"),
          node_view(sha: "x0000001", column: 0, row: 1, owner_id: nil),
          node_view(sha: "y0000001", column: 0, row: 2, owner_id: nil),
          node_view(sha: "t0000001", column: 1, row: 4, owner_id: "a1")
        ],
        edges: [
          edge_view(
            from_sha: "f0000001",
            to_sha: "x0000001",
            from_column: 1,
            from_row: 0,
            to_column: 0,
            to_row: 1,
            kind: :spawn,
            owner_id: "a1"
          ),
          edge_view(
            from_sha: "y0000001",
            to_sha: nil,
            from_column: 0,
            from_row: 2,
            to_column: 1,
            to_row: 4,
            kind: :merge_back,
            owner_id: "a1"
          )
        ],
        agents: [agent_map(agent_id: "a1", lane: 1)]
      )
    ]
  end

  # A same-row cross-lane edge: the row-1 node's parent is absent from the
  # model, so the target takes the edge's own grid pair — SAME row, other lane
  # (the rounded-shelf route, never a bare horizontal stub).
  defp same_row_edge_repos do
    [
      repo_view(
        nodes: [
          node_view(sha: "p0000001", column: 0, row: 0, owner_id: nil),
          node_view(sha: "x0000001", column: 0, row: 1, owner_id: "a1")
        ],
        edges: [
          edge_view(
            from_sha: "abs00001",
            from_column: 1,
            from_row: 1,
            to_sha: "x0000001",
            to_column: 0,
            to_row: 1,
            owner_id: "a1"
          )
        ],
        agents: [agent_map(agent_id: "a1", lane: 1)]
      )
    ]
  end

  # A folded lane carrying a parent edge that lands ON the gap marker's dot.
  defp fold_edge_repos do
    [repo] = fold_repos()

    edge =
      edge_view(
        from_sha: "n0000001",
        to_sha: "gap-f1-a1",
        from_column: 1,
        from_row: 0,
        to_column: 1,
        to_row: 1,
        owner_id: "a1"
      )

    [Map.put(repo, :edges, [edge])]
  end

  # An edge whose endpoints collapse onto each other (routed `d` is nil).
  defp collapsed_edge_repos do
    [
      repo_view(
        edges: [edge_view(from_sha: "aaaa0000", to_sha: "aaaa0000")],
        nodes: [node_view(sha: "aaaa0000", column: 0, row: 0)]
      )
    ]
  end

  # EVERY edge-bearing fixture in this file whose model is geometrically
  # consistent, for the shared no-mid-air-edge invariant. (The defensive
  # degradation fixtures deliberately dangle an endpoint at a grid cell no node
  # occupies — they pin totality, not geometry — so they are out of scope.)
  defp edge_fixtures do
    [
      {"happy", happy_repos()},
      {"ghost owner", ghost_owner_edge_repos()},
      {"absent endpoint", absent_endpoint_repos()},
      {"concurrent lane pair", concurrent_lane_pair_repos()},
      {"same-row shelf", same_row_edge_repos()},
      {"folded lane", fold_edge_repos()},
      {"collapsed endpoints", collapsed_edge_repos()}
    ]
  end

  # Hand-crafted repo/node/edge/agent maps for shapes the happy fixture does not
  # cover (odd/absent geometry, a fixed DOM id, unowned entries, non-map entries).
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

  # `short_sha` defaults to the sha's first 8 chars (the model's convention), so
  # the rendered short sha IS the fixture sha; an explicit short_sha wins.
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

  defp dom_id(repos), do: repos |> hd() |> Map.fetch!(:repo_dom_id)

  # Assert several attributes of ONE element from a name → expected-values map.
  defp assert_attrs(el, expected) do
    for {name, values} <- expected do
      assert attr(el, name) == values, "unexpected #{name}: #{inspect(attr(el, name))}"
    end
  end

  # Assert each selector matches at least one element / matches nothing.
  defp assert_present(tree, selectors) do
    for selector <- selectors, do: assert(Floki.find(tree, selector) != [], selector)
  end

  defp assert_absent(tree, selectors) do
    for selector <- selectors, do: assert(Floki.find(tree, selector) == [], selector)
  end

  defp text(el_or_els), do: el_or_els |> Floki.text() |> String.trim()

  defp attr(el, name), do: el |> Floki.attribute(name) |> Enum.map(&to_string/1)

  defp node_title(tree, id) do
    [el] = Floki.find(tree, "##{id}")
    el |> Floki.find("title") |> Floki.text()
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

  # The NO-MID-AIR-EDGE invariant, shared by every edge-bearing fixture: a
  # rendered edge must END either on a rendered dot (any commit OR gap marker's
  # `cx`/`cy`) or — for the documented `to_sha: nil` VIRTUAL landing, whose id
  # key is `l<col>r<row>` — exactly on that grid point. Returns the number of
  # edges checked (so the caller can prove the sweep was not vacuous).
  defp assert_edges_land_on_dots(tree, dom, label) do
    [gutter] = Floki.find(tree, "#cg-gutter-#{dom}")

    dots =
      gutter
      |> Floki.find("circle.cg-node-dot")
      |> MapSet.new(fn circle -> {numeral_attr(circle, "cx"), numeral_attr(circle, "cy")} end)

    gutter
    |> Floki.find("path.cg-edge")
    |> Enum.reduce(0, fn path, acc ->
      id = path |> attr("id") |> hd()
      finish = path_end(path |> attr("d") |> hd())

      case virtual_landing(id) do
        {col, row} ->
          assert finish == {Geometry.dot_x(col), Geometry.dot_y(row)},
                 "#{label}: virtual landing #{id} ends at #{inspect(finish)}"

        nil ->
          assert MapSet.member?(dots, finish),
                 "#{label}: #{id} ends MID-AIR at #{inspect(finish)} — no rendered dot there"
      end

      acc + 1
    end)
  end

  # The `l<col>r<row>` virtual-landing key of an AGENT-level edge id (`:spawn` /
  # `:merge_back`); nil for a commit → parent edge (whose id ends with a sha).
  defp virtual_landing(id) do
    agent_level? = String.contains?(id, "-spawn-") or String.contains?(id, "-merge_back-")

    with true <- agent_level?,
         [_, col, row] <- Regex.run(~r/-l(\d+)r(\d+)$/, id) do
      {String.to_integer(col), String.to_integer(row)}
    else
      _ -> nil
    end
  end

  # The numeric (x, y) a path's `d` ENDS on (its last two tokens, the final `L`
  # endpoint) — the dot the route lands on.
  defp path_end(d) do
    [x, y] = d |> String.split(" ") |> Enum.take(-2)
    {numeral(x), numeral(y)}
  end

  defp numeral(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> raise ArgumentError, "not a coordinate: #{inspect(value)}"
    end
  end

  defp numeral_attr(el, name), do: el |> attr(name) |> hd() |> numeral()

  # The numeric (x, y) of a path's `M x y` start.
  defp path_start(d) do
    [_, x, y] = Regex.run(~r/^M (\S+) (\S+)/, d)
    {String.to_integer(x), String.to_integer(y)}
  end

  # The jog y of a routed path — the y shared by its two `Q` control points (the
  # y a STAGGERED edge moves off the span midpoint).
  defp jog_y(d) do
    [q1, q2] = Regex.scan(~r/Q \S+ (\S+) /, d, capture: :all_but_first)
    [jog] = q1
    assert q2 == [jog], "expected both Q corners on the same horizontal: #{d}"
    {y, ""} = Float.parse(jog)
    y
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
end
