defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView` —
  the HORIZONTAL AGENT-SWIMLANE (plain HTML/CSS, no SVG) TEMPORAL view of the
  Agents page left panel.

  `commit_graph_view/1` is purely presentational: it renders the per-repo
  swimlane view models assembled by the pure `EvoDashWeb.AgentsLive.CommitGraph.build/2`
  and fires the existing `select_agent` event from the lane ROW. These tests
  render it in isolation with `render_component/2` (no `live/3` — matching the
  rest of this directory) and pin the frozen DOM contract consumed by the
  client-side `CommitGraph` hook / CSS animation:

    * `#commit-graph` + `phx-hook="CommitGraph"` and the node-scoped body
      `#commit-graph-body-<node_key>`;
    * one section per repo whose id IS the builder's `repo_dom_id` verbatim
      (the builder already emits a `commit-graph-repo-<slug>-<hash>` id — the
      component adds NO prefix) with a repo-name header above the rows;
    * one row per agent lane, `#commit-agent-row-<repo_dom_id>-<agent_id>`,
      carrying the `select_agent` click contract, a status-dot gutter and the
      `T<task_local_id || id>` label;
    * the lane progress bar `#commit-lane-<repo_dom_id>-<agent_id>` with
      `data-commit-graph-anim="lane"`, spanning `from_column` → `to_column`;
    * one marker per commit per lane,
      `#commit-marker-<repo_dom_id>-<agent_id>-<sha>` with
      `data-commit-graph-anim="node"`, positioned by PERCENTAGE of the track.

  The main happy-path fixture is produced by calling the REAL
  `CommitGraph.build/2` with realistic agent maps and a raw commit graph, so
  the component provably renders real builder output; hand-crafted
  repo/lane/marker maps cover shapes the builder cannot easily produce
  (odd/absent geometry, a fixed `repo_dom_id`, empty lanes/markers, and
  non-map entries).
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
  @sha_c3 "c3000000"

  # The documented golden-angle hue for depth 0 (see CommitGraph's depth→hue).
  @depth0_color "#7c38dc"

  # ---------------------------------------------------------------------------
  # Root markers
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — root markers" do
    test "renders the #commit-graph hook root wrapping the node-keyed body" do
      tree = parse(render_repos(happy_repos()))

      assert [root] = Floki.find(tree, "#commit-graph")
      assert attr(root, "phx-hook") == ["CommitGraph"]

      # Default node key.
      assert [body] = Floki.find(tree, "#commit-graph-body-local")
      assert attr(body, "class") != []
    end

    test "a non-default node_key changes only the body id" do
      tree = parse(render_repos(happy_repos(), node_key: "remote_one"))

      assert Floki.find(tree, "#commit-graph-body-remote_one") != []
      assert Floki.find(tree, "#commit-graph-body-local") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Repo sections — id IS repo_dom_id, header above the lane rows
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — repo sections" do
    test "the section id IS repo_dom_id verbatim, with a repo-name header above the rows" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # No doubled prefix: the builder's id already starts commit-graph-repo-.
      assert String.starts_with?(dom, "commit-graph-repo-")

      [section] = Floki.find(tree, "##{dom}")

      [header, row_list] =
        section |> Floki.children() |> Enum.filter(&match?({"div", _, _}, &1))

      # The header block carries the repo display name …
      assert Floki.find(header, ~s(span[title="my-project"])) != []
      assert Floki.text(header) =~ "my-project"
      # … and the rows live in the block BELOW it.
      assert Floki.find(header, ~s([id^="commit-agent-row-"])) == []
      assert Floki.find(row_list, ~s([id^="commit-agent-row-"])) != []
    end

    test "there is no SVG scaffold anywhere (plain HTML divs + spans)" do
      html = render_repos(happy_repos())
      tree = parse(html)

      refute html =~ "<svg"
      assert Floki.find(tree, "svg") == []
      assert Floki.find(tree, "circle") == []
      assert Floki.find(tree, "path") == []
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
    end
  end

  # ---------------------------------------------------------------------------
  # Agent rows (the swimlanes)
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — agent rows" do
    test "renders one row per agent, ordered by recursion depth" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      assert [row1] = Floki.find(tree, "#commit-agent-row-#{dom}-a1")
      assert [row2] = Floki.find(tree, "#commit-agent-row-#{dom}-a2")
      assert row1 != row2

      # Rows are stacked top → bottom in lane order, and the lanes are ordered
      # by {depth, id} — one row per agent, no more, no fewer.
      row_ids =
        tree
        |> Floki.find(~s(##{dom} [id^="commit-agent-row-"]))
        |> Enum.map(&(&1 |> attr("id") |> hd()))

      assert row_ids == [
               "commit-agent-row-#{dom}-a1",
               "commit-agent-row-#{dom}-a2"
             ]

      assert Enum.map(repo.lanes, & &1.agent.depth) == [0, 1]
      assert length(repo.lanes) == 2
    end

    test "each row's gutter carries the status dot and the T<task_local_id> label" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [row] = Floki.find(tree, "#commit-agent-row-#{dom}-a1")
      [gutter | _] = row |> Floki.children() |> Enum.filter(&match?({"div", _, _}, &1))

      [dot, label] = Floki.find(gutter, "span")

      assert attr(dot, "class") |> hd() =~ "rounded-full"

      assert attr(dot, "style") == [
               "background-color: #{Helpers.agent_status_svg_color(:running)}"
             ]

      assert String.trim(Floki.text(label)) == "T1"
      assert attr(label, "title") == ["T1"]
      assert attr(label, "class") |> hd() =~ "font-mono"
    end

    test "a row's title is the T-label plus the human status label" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [row1] = Floki.find(tree, "#commit-agent-row-#{dom}-a1")
      [row2] = Floki.find(tree, "#commit-agent-row-#{dom}-a2")

      assert attr(row1, "title") == ["T1 · Running"]
      # :completed has no dedicated label clause -> capitalized atom name.
      assert attr(row2, "title") == ["T2 · Completed"]
    end

    test "the row is the single select_agent click target per lane" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      [row1] = Floki.find(tree, "#commit-agent-row-#{dom}-a1")
      [row2] = Floki.find(tree, "#commit-agent-row-#{dom}-a2")

      assert attr(row1, "phx-click") == ["select_agent"]
      assert attr(row1, "phx-value-id") == ["a1"]
      assert attr(row1, "class") |> hd() =~ "cursor-pointer"

      assert attr(row2, "phx-click") == ["select_agent"]
      assert attr(row2, "phx-value-id") == ["a2"]

      # Exactly one click handler per lane: the markers/lane bar do NOT carry a
      # handler of their own (their clicks bubble up to the row).
      assert length(Floki.find(tree, ~s([phx-click="select_agent"]))) == length(repo.lanes)
    end
  end

  # ---------------------------------------------------------------------------
  # Lane progress bars
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — lane progress bars" do
    test "renders one bar per lane, spanning base → current by percentage" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      [a1, a2] = repo.lanes

      # a1 covers columns 0..1 (c1 → c2 tip), a2 covers column 2 (c3 tip).
      assert a1.from_column == 0
      assert a1.to_column == 1
      assert a1.tip_column == 1
      assert a2.from_column == 2
      assert a2.to_column == 2
      assert a2.tip_column == 2
      assert repo.column_count == 3

      [lane1] = Floki.find(tree, "#commit-lane-#{dom}-a1")
      assert attr(lane1, "data-commit-graph-anim") == ["lane"]
      assert attr(lane1, "class") |> hd() =~ "absolute"
      assert attr(lane1, "class") |> hd() =~ "rounded-full"

      # left = from/3*100 ; width = (to-from+1)/3*100, compacted by pct/1.
      assert attr(lane1, "style") == [
               "left: 0%; width: 66.667%; background-color: #{a1.agent.color}"
             ]

      [lane2] = Floki.find(tree, "#commit-lane-#{dom}-a2")

      assert attr(lane2, "style") == [
               "left: 66.667%; width: 33.333%; background-color: #{a2.agent.color}"
             ]
    end

    test "the bar is tinted with the agent's depth hue" do
      repos = happy_repos()
      dom = dom_id(repos)
      [repo] = repos
      [a1, a2] = repo.lanes

      # depth 0 is the documented golden-angle first step.
      assert a1.agent.color == @depth0_color
      assert a2.agent.depth == 1

      tree = parse(render_repos(repos))

      [lane1] = Floki.find(tree, "#commit-lane-#{dom}-a1")
      assert attr(lane1, "style") |> hd() =~ "background-color: #{@depth0_color}"

      # depth 1 differs from depth 0 — lanes are colour-distinguished.
      assert a2.agent.color != a1.agent.color
      [lane2] = Floki.find(tree, "#commit-lane-#{dom}-a2")
      assert attr(lane2, "style") |> hd() =~ "background-color: #{a2.agent.color}"
    end

    test "the bar is omitted without a positive column count or integer bounds" do
      # No columns at all → no bar (and no markers), but the row still renders.
      repo = repo_view(column_count: 0, lanes: [lane(from_column: 0, to_column: 0)])
      tree = parse(render_repos([repo]))

      assert Floki.find(tree, "#commit-lane-#{repo.repo_dom_id}-hand1") == []
      assert Floki.find(tree, "#commit-agent-row-#{repo.repo_dom_id}-hand1") != []

      # Positive count but non-integer bounds → still no bar.
      repo = repo_view(column_count: 3, lanes: [lane(from_column: "0", to_column: nil)])
      tree = parse(render_repos([repo]))

      assert Floki.find(tree, "#commit-lane-#{repo.repo_dom_id}-hand1") == []
      assert Floki.find(tree, "#commit-agent-row-#{repo.repo_dom_id}-hand1") != []
    end
  end

  # ---------------------------------------------------------------------------
  # Commit markers
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — commit markers" do
    test "renders exactly one marker per commit per lane" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      ids =
        tree
        |> Floki.find(~s([id^="commit-marker-"]))
        |> Enum.map(&(&1 |> attr("id") |> hd()))

      expected =
        for lane <- repo.lanes, marker <- lane.markers do
          "commit-marker-#{dom}-#{lane.agent.id}-#{marker.sha}"
        end

      assert Enum.sort(ids) == Enum.sort(expected)
      assert length(ids) == 3
      # No duplicates, and DOM order matches `lanes` × `markers`.
      assert ids == Enum.uniq(ids)
      assert ids == expected

      # a1's path is c1 → c2 (tip); a2's is c3 (tip).
      assert Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c1}") != []
      assert Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c2}") != []
      assert Floki.find(tree, "#commit-marker-#{dom}-a2-#{@sha_c3}") != []
    end

    test "markers are positioned at the CENTER of their column, by percentage" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      for el <- Floki.find(tree, ~s([id^="commit-marker-"])) do
        assert attr(el, "data-commit-graph-anim") == ["node"]
        assert attr(el, "class") |> hd() =~ "absolute"
        assert attr(el, "class") |> hd() =~ "rounded-full"
      end

      # (column + 0.5) / 3 * 100 → c1 col 0, c2 col 1, c3 col 2.
      assert style_of(tree, "commit-marker-#{dom}-a1-#{@sha_c1}") =~ "left: 16.667%"
      assert style_of(tree, "commit-marker-#{dom}-a1-#{@sha_c2}") =~ "left: 50%"
      assert style_of(tree, "commit-marker-#{dom}-a2-#{@sha_c3}") =~ "left: 83.333%"
    end

    test "a TIP marker is status-colored and size-3; a non-tip marker uses the depth hue at size-2.5" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # a1 tips at c2: status-coloured + the larger dot.
      [tip] = Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c2}")
      assert attr(tip, "class") |> hd() =~ "size-3"
      refute attr(tip, "class") |> hd() =~ "size-2.5"

      assert attr(tip, "style") == [
               "left: 50%; background-color: #{Helpers.agent_status_svg_color(:running)}"
             ]

      # c1 is on a1's path but is NOT the tip: depth hue + the smaller dot.
      [non_tip] = Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c1}")
      assert attr(non_tip, "class") |> hd() =~ "size-2.5"
      refute attr(non_tip, "class") |> hd() =~ "size-3"

      assert attr(non_tip, "style") |> hd() =~ "background-color: #{@depth0_color}"

      # a2 (:completed) tips at c3 — the shared fallback status ink.
      [tip2] = Floki.find(tree, "#commit-marker-#{dom}-a2-#{@sha_c3}")

      assert attr(tip2, "style") == [
               "left: 83.333%; background-color: #{Helpers.agent_status_svg_color(:completed)}"
             ]
    end

    test "a marker tooltip carries the headline, short sha, author, date and refs" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      title = title_of(tree, "commit-marker-#{dom}-a2-#{@sha_c3}")

      assert title =~ "Refactor Z"
      assert title =~ @sha_c3
      assert title =~ "Carol"
      assert title =~ "2024-01-03 10:00"
      # The refs of that commit ride along as one comma-joined segment.
      assert title =~ "HEAD"
      assert title =~ "genesis/agent_x"

      # Only the FIRST line of a multi-line message is shown, and a ref-less
      # commit carries no ref segment at all.
      plain_title = title_of(tree, "commit-marker-#{dom}-a1-#{@sha_c1}")

      assert plain_title =~ "Add feature X"
      refute plain_title =~ "longer body line"
      refute plain_title =~ "HEAD"
    end
  end

  # ---------------------------------------------------------------------------
  # Percentage layout — no SVG, no scroll
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — percentage layout" do
    test "every positioned element is placed with a percentage of the track" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      positioned = positioned_elements(tree)

      # 3 markers (2 lanes' marker count: a1 has 2, a2 has 1) + 2 lane bars.
      assert length(positioned) == 5

      for el <- positioned do
        style = el |> attr("style") |> hd()
        assert style =~ ~r/left: \d+(\.\d+)?%/
        refute style =~ "px"
      end

      # The status dot's style is a colour, not a position — no percentage.
      [row] = Floki.find(tree, "#commit-agent-row-#{dom}-a1")
      [dot | _] = Floki.find(row, "span")
      refute attr(dot, "style") |> hd() =~ "%"
    end

    test "there is no fixed pixel width and no SVG scaffold" do
      html = render_repos(happy_repos())

      refute html =~ "min-width"
      refute html =~ "<svg"
      refute html =~ "viewBox"
      refute html =~ "viewbox"
      refute html =~ "preserveAspectRatio"
    end
  end

  # ---------------------------------------------------------------------------
  # Selection — a style change on the SAME elements
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — selection styling" do
    test "selecting an agent tints its row and rings its TIP marker" do
      repos = happy_repos()
      dom = dom_id(repos)

      before_tree = parse(render_repos(repos))
      tree = parse(render_repos(repos, selected_id: "a1"))

      # The selected lane's row is tinted; the other row is not.
      [row1] = Floki.find(tree, "#commit-agent-row-#{dom}-a1")
      assert attr(row1, "class") |> hd() =~ "bg-primary/5"

      [row2] = Floki.find(tree, "#commit-agent-row-#{dom}-a2")
      refute attr(row2, "class") |> hd() =~ "bg-primary/5"

      # The selected agent's TIP marker grows a primary ring …
      [tip] = Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c2}")
      assert attr(tip, "class") |> hd() =~ "ring-2"
      assert attr(tip, "class") |> hd() =~ "ring-primary-standalone"

      # … while its non-tip marker (same agent) does not, and neither does the
      # unselected agent's tip.
      [non_tip] = Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c1}")
      refute attr(non_tip, "class") |> hd() =~ "ring-2"

      [tip2] = Floki.find(tree, "#commit-marker-#{dom}-a2-#{@sha_c3}")
      refute attr(tip2, "class") |> hd() =~ "ring-2"

      # Selection never stacks an extra element: the node counts are identical.
      assert length(Floki.find(tree, ~s([id^="commit-marker-"]))) ==
               length(Floki.find(before_tree, ~s([id^="commit-marker-"])))

      assert length(Floki.find(tree, ~s([id^="commit-agent-row-"]))) ==
               length(Floki.find(before_tree, ~s([id^="commit-agent-row-"])))
    end

    test "a nil or non-matching selected_id renders no tint and no ring" do
      for selected <- [nil, "nope"] do
        html = render_repos(happy_repos(), selected_id: selected)

        refute html =~ "bg-primary/5"
        refute html =~ "ring-primary-standalone"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # View states — loading / empty / error
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — view states" do
    test "empty repos + loading renders the loading state and nothing else" do
      html = render_repos([], loading: true)
      tree = parse(html)

      assert html =~ "Loading commit history"
      refute html =~ "No commit history yet."
      refute html =~ "Could not load commit history."
      assert Floki.find(tree, "#commit-graph-error") == []

      # The body wrapper is present in every state.
      assert Floki.find(tree, "#commit-graph-body-local") != []
    end

    test "loading wins over a non-nil error while there are no repos" do
      html = render_repos([], loading: true, error: :boom)

      assert html =~ "Loading commit history"
      refute html =~ "Could not load commit history."
      refute html =~ "No commit history yet."
    end

    test "empty repos + not loading + no error renders the empty state" do
      html = render_repos([])
      tree = parse(html)

      assert html =~ "No commit history yet."
      assert html =~ "Start a task from the dashboard to see the commit graph here."
      refute html =~ "Loading commit history"
      refute html =~ "Could not load commit history."
      assert Floki.find(tree, "#commit-graph-error") == []
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

  # ---------------------------------------------------------------------------
  # Stale warning (repos cached, refresh failed)
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — stale warning" do
    test "non-empty repos + a non-nil error render the stale warning AND the repos" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos, error: :boom))

      assert [warning] = Floki.find(tree, "#commit-graph-stale-warning")
      assert Floki.text(warning) =~ "refresh failed"

      # The cached swimlanes still render …
      assert Floki.find(tree, ~s(##{dom} [id^="commit-agent-row-"])) != []
      assert Floki.find(tree, "#commit-marker-#{dom}-a1-#{@sha_c1}") != []
      assert Floki.find(tree, "#commit-lane-#{dom}-a1") != []

      # … and the hard error state is NOT shown.
      assert Floki.find(tree, "#commit-graph-error") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Animation markers
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — animation markers" do
    test "node + lane animation markers are emitted; there is no edge marker" do
      repos = happy_repos()
      tree = parse(render_repos(repos))
      [repo] = repos

      node_markers = Floki.find(tree, ~s([data-commit-graph-anim="node"]))
      lane_markers = Floki.find(tree, ~s([data-commit-graph-anim="lane"]))

      # One node per commit per lane, one lane bar per lane.
      assert length(node_markers) == 3
      assert length(lane_markers) == length(repo.lanes)

      # The redesign dropped the edge elements entirely.
      assert Floki.find(tree, ~s([data-commit-graph-anim="edge"])) == []
    end

    test "no phx-update mode anywhere (incremental patching rides stable ids)" do
      tree = parse(render_repos(happy_repos()))

      assert Floki.find(tree, "[phx-update]") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive shapes
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — defensive shapes" do
    test "a repo missing column_count/lanes/markers still renders its header" do
      repo = %{repo_dom_id: "commit-graph-repo-bare-1", repo_name: "Bare Repo"}
      tree = parse(render_repos([repo]))

      [section] = Floki.find(tree, "#commit-graph-repo-bare-1")
      assert Floki.text(section) =~ "Bare Repo"
      assert Floki.find(section, ~s([id^="commit-agent-row-"])) == []
      assert Floki.find(section, ~s([id^="commit-marker-"])) == []

      # A repo with columns but an empty lanes list renders the header only.
      repo = repo_view(column_count: 4, commit_count: 4, lanes: [])
      tree = parse(render_repos([repo]))

      assert Floki.find(tree, "##{repo.repo_dom_id}") != []
      assert Floki.find(tree, ~s([id^="commit-agent-row-"])) == []
    end

    test "non-map lane and marker entries are dropped without crashing" do
      repo =
        repo_view(
          column_count: 2,
          lanes: [
            :junk_lane,
            "nope",
            lane(
              agent: "not a map",
              markers: [:junk_marker, "nope", marker(column: 1, sha: "ok000000")]
            )
          ]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      # Only the single map lane survives (with an empty-agent gutter) …
      assert length(Floki.find(tree, ~s([id^="commit-agent-row-"]))) == 1

      # … and only the single map marker survives.
      [marker_el] = Floki.find(tree, "#commit-marker-#{dom}--ok000000")
      assert attr(marker_el, "data-commit-graph-anim") == ["node"]
      # column 1 of 2 → 75%; no agent → the fallback ink.
      assert attr(marker_el, "style") == [
               "left: 75%; background-color: var(--color-base-content)"
             ]

      # The lane has no integer bounds → no progress bar for it.
      assert Floki.find(tree, "#commit-lane-#{dom}-") == []
    end

    test "an agent without a color falls back to the base-content ink" do
      for color <- [nil, "", :garbage] do
        repo =
          repo_view(
            column_count: 1,
            lanes: [
              lane(
                agent: agent(color: color),
                from_column: 0,
                to_column: 0,
                markers: [marker(column: 0, tip?: false)]
              )
            ]
          )

        tree = parse(render_repos([repo]))
        dom = repo.repo_dom_id

        [lane_bar] = Floki.find(tree, "#commit-lane-#{dom}-hand1")

        assert attr(lane_bar, "style") == [
                 "left: 0%; width: 100%; background-color: var(--color-base-content)"
               ]

        [marker_el] = Floki.find(tree, "#commit-marker-#{dom}-hand1-deadbeef")

        assert attr(marker_el, "style") == [
                 "left: 50%; background-color: var(--color-base-content)"
               ]
      end
    end

    test "odd column values degrade without crashing" do
      # A non-integer column_count disables the lane bar and the marker layout.
      repo =
        repo_view(
          column_count: "3",
          lanes: [
            lane(
              from_column: 0,
              to_column: 1,
              markers: [marker(column: :garbage, sha: "odd00000")]
            )
          ]
        )

      tree = parse(render_repos([repo]))
      dom = repo.repo_dom_id

      assert Floki.find(tree, "#commit-lane-#{dom}-hand1") == []

      [marker_el] = Floki.find(tree, "#commit-marker-#{dom}-hand1-odd00000")
      # The marker still renders (left degrades to 0) with the depth hue.
      assert attr(marker_el, "style") == ["left: 0%; background-color: #123456"]
      assert Floki.find(tree, "#commit-agent-row-#{dom}-hand1") != []

      # An a-sha marker with a non-binary sha still gets a stable DOM id.
      repo = repo_view(column_count: 2, lanes: [lane(markers: [marker(sha: 42)])])
      tree = parse(render_repos([repo]))

      assert Floki.find(tree, "#commit-marker-#{repo.repo_dom_id}-hand1-42") != []
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # The main happy-path fixture: a two-agent repo (a1 at depth 0 whose path
  # covers c1..c2 and TIPS at c2, a2 at depth 1 tipping at c3) assembled by the
  # REAL `CommitGraph.build/2`.
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
            parents: [@sha_c2]
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

  # Hand-crafted repo/lane/marker/agent maps for shapes the builder does not
  # easily produce (odd geometry, a fixed DOM id, empty lanes/markers and a
  # non-map entry).
  defp repo_view(overrides) do
    Map.merge(
      %{
        repo_key: "primary",
        repo_dom_id: "commit-graph-repo-handcrafted-1",
        repo_name: "Primary Repo",
        column_count: 0,
        commit_count: 0,
        columns: [],
        lanes: []
      },
      Map.new(overrides)
    )
  end

  defp lane(overrides) do
    Map.merge(
      %{
        agent: agent([]),
        from_column: nil,
        to_column: nil,
        tip_column: nil,
        markers: []
      },
      Map.new(overrides)
    )
  end

  defp agent(overrides) do
    Map.merge(
      %{id: "hand1", task_local_id: 7, status: :running, depth: 0, color: "#123456"},
      Map.new(overrides)
    )
  end

  defp marker(overrides) do
    Map.merge(
      %{
        column: 0,
        sha: "deadbeef",
        short_sha: "deadbeef",
        message: "A commit",
        author_name: "Ann",
        date: nil,
        refs: [],
        tip?: false
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

  # Every percentage-positioned element (lane bars + commit markers).
  defp positioned_elements(tree) do
    Floki.find(tree, ~s([id^="commit-lane-"])) ++
      Floki.find(tree, ~s([id^="commit-marker-"]))
  end

  defp style_of(tree, id) do
    [el] = Floki.find(tree, "##{id}")
    el |> attr("style") |> hd()
  end

  defp title_of(tree, id) do
    [el] = Floki.find(tree, "##{id}")
    el |> attr("title") |> hd()
  end

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
