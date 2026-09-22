defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView` —
  the SVG (classic git-graph) TEMPORAL view of the Agents page left panel.

  `commit_graph_view/1` is purely presentational: it renders the `repo_view`
  list assembled by the pure `EvoDashWeb.AgentsLive.CommitGraph.build/2` and
  fires the existing `select_agent` event. These tests render it in isolation
  with `render_component/2` (no `live/3` — matching the rest of this
  directory) and pin the frozen SVG DOM contract consumed by the client-side
  `CommitGraph` hook / CSS animation: `#commit-graph`, `#commit-graph-body-<node_key>`,
  per-repo sections whose id IS the builder's `repo_dom_id`, commit dot groups
  `#commit-dot-<repo_dom_id>-<sha>` + `data-commit-graph-anim="node"`, edge
  paths `#commit-edge-...` + `data-commit-graph-anim="edge"`, agent ring groups
  `#commit-ring-<repo_dom_id>-<agent_id>`, and the right-gutter ref chips.

  The main happy-path fixture is produced by calling the REAL
  `CommitGraph.build/2` with realistic agent maps and a raw commit graph, so
  the component provably renders real builder output; a few hand-crafted
  repo/commit/ring maps cover shapes the builder cannot easily produce
  (odd/absent geometry, a known DOM id, an agent-less dot).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsComponents.CommitGraphView
  alias EvoDashWeb.AgentsLive.CommitGraph
  alias EvoDashWeb.Helpers

  # Realistic fixture identifiers. The raw commits carry no explicit
  # `:short_sha`, so the rendered short sha is the sha's first 8 characters.
  @repo_root "/home/user/my-project"
  @sha_base "b0000000"
  @sha_c1 "c1000000"
  @sha_c2 "c2000000"
  @sha_c3 "c3000000"

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
  # SVG structure — viewBox / per-repo sections / repo header
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — SVG structure" do
    test "renders one svg per repo with a viewBox sized from the repo dimensions" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      assert [svg] = Floki.find(tree, "##{dom} svg")

      # Floki lowercases attribute names for matching: "viewBox" -> "viewbox".
      # width = 12 + 1 lane * 24 + 150 gutter = 186; height = 14 + 3 rows * 26 + 14 = 106.
      assert attr(svg, "viewbox") == ["0 0 186 106"]
      assert attr(svg, "preserveaspectratio") == ["xMinYMin meet"]
      assert attr(svg, "role") == ["img"]
      assert attr(svg, "style") == ["min-width: 186px"]
    end

    test "the per-repo section id IS repo_dom_id verbatim, with a header above the svg" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [section] = Floki.find(tree, "##{dom}")
      # No doubled prefix: the builder's id already starts commit-graph-repo-.
      assert String.starts_with?(dom, "commit-graph-repo-")

      assert Floki.find(section, "svg") != []
      assert Floki.text(section) =~ "my-project"

      # Two repos -> two sections, each with exactly one svg.
      [other | _] = happy_two_repo_fixture()
      tree = parse(render_repos([hd(repos), other]))

      assert Floki.find(tree, "##{dom} svg") |> length() == 1
      assert Floki.find(tree, "##{other.repo_dom_id} svg") |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Commit dots
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — commit dots" do
    test "renders one dot group per commit, positioned at the builder's x/y" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      # One group per commit, oldest-first DOM order (LiveView appends at the bottom).
      assert Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c1}") != []
      assert Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c2}") != []
      assert Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c3}") != []

      groups =
        for sha <- [@sha_c1, @sha_c2, @sha_c3] do
          [g] = Floki.find(tree, "#commit-dot-#{dom}-#{sha}")
          g
        end

      # The svg child order matches the commits list order (top → bottom).
      svg_children_ids =
        tree
        |> Floki.find("##{dom} svg > g")
        |> Enum.map(fn g -> attr(g, "id") |> hd() end)

      expected =
        Enum.map(repo.commits, &"commit-dot-#{dom}-#{Map.get(&1, :sha)}")

      dot_ids = Enum.filter(svg_children_ids, &String.starts_with?(&1, "commit-dot-"))
      assert dot_ids == expected

      for {group, commit} <- Enum.zip(groups, repo.commits) do
        assert attr(group, "data-commit-graph-anim") == ["node"]

        [circle] = Floki.find(group, "circle")

        assert attr(circle, "cx") == [float_str(commit.x)]
        assert attr(circle, "cy") == [float_str(commit.y)]
        assert attr(circle, "r") == [float_str(CommitGraph.dot_r())]
      end
    end

    test "a native <title> tooltip carries subject + short sha (first line only)" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [c1] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c1}")

      title = c1 |> Floki.find("title") |> Floki.text()
      assert title =~ "Add feature X"
      assert title =~ @sha_c1
      # The multi-line message body is dropped — only the headline is shown.
      refute title =~ "longer body line"
    end

    test "an agent-covered dot is filled with its depth hue; a bare dot uses the muted ink" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # @sha_c2 is on agent a1's path (depth 0 -> the documented #7c38dc).
      [c2] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c2}")
      [c2_circle] = Floki.find(c2, "circle")
      assert attr(c2_circle, "style") == ["fill: #7c38dc"]
      assert attr(c2_circle, "fill-opacity") == ["1.0"]

      # A dot no agent covers (built below) renders the muted base ink at 0.55.
      bare = [bare_repo_view()]
      bare_dom = hd(bare).repo_dom_id
      tree = parse(render_repos(bare))

      [bare_dot] = Floki.find(tree, "#commit-dot-#{bare_dom}-bare00000")
      [bare_circle] = Floki.find(bare_dot, "circle")
      assert attr(bare_circle, "style") == ["fill: var(--color-base-content)"]
      assert attr(bare_circle, "fill-opacity") == ["0.55"]
    end

    test "an agent-less dot renders NO click binding at all" do
      repos = [bare_repo_view()]
      dom = hd(repos).repo_dom_id
      tree = parse(render_repos(repos))

      [dot] = Floki.find(tree, "#commit-dot-#{dom}-bare00000")
      [circle] = Floki.find(dot, "circle")
      assert attr(circle, "phx-click") == []
      assert attr(circle, "phx-value-id") == []
      refute attr(circle, "class") |> Enum.join(" ") =~ "cursor-pointer"
    end
  end

  # ---------------------------------------------------------------------------
  # Edges
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — edges" do
    test "renders one path per edge with the builder's d, id and animation marker" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      paths = Floki.find(tree, "##{dom} path")
      assert length(paths) == length(repo.edges)

      for {path, edge} <- Enum.zip(paths, repo.edges) do
        assert attr(path, "id") == [edge.id]
        assert attr(path, "d") == [edge.d]
        assert attr(path, "data-commit-graph-anim") == ["edge"]
        assert attr(path, "fill") == ["none"]
      end
    end

    test "an agent-covered edge carries its depth-hue stroke; a bare edge is muted + dimmed" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # a1 covers c2 -> c1 (depth 0 hue, full opacity, heavier stroke).
      [covered] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c2}-#{@sha_c1}")
      assert attr(covered, "style") == ["stroke: #7c38dc"]
      assert attr(covered, "stroke-width") == ["2.25"]
      assert attr(covered, "stroke-opacity") == []

      # The edge into the absent base (@sha_base) never renders.
      assert Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c1}-#{@sha_base}") == []

      # A bare repo's edge uses the muted ink at reduced opacity.
      bare = [bare_repo_view()]
      bare_dom = hd(bare).repo_dom_id
      tree = parse(render_repos(bare))

      [bare_edge] = Floki.find(tree, "#commit-edge-#{bare_dom}-bare00000-bare11111")
      assert attr(bare_edge, "style") == ["stroke: var(--color-base-content)"]
      assert attr(bare_edge, "stroke-width") == ["1.75"]
      assert attr(bare_edge, "stroke-opacity") == ["0.35"]
    end
  end

  # ---------------------------------------------------------------------------
  # Agent rings
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — agent rings" do
    test "renders one ring group per agent TIP, stroked with the shared status color" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [ring1] = Floki.find(tree, "#commit-ring-#{dom}-a1")
      [ring2] = Floki.find(tree, "#commit-ring-#{dom}-a2")

      assert attr(ring1, "data-commit-graph-anim") == ["node"]
      assert attr(ring2, "data-commit-graph-anim") == ["node"]

      # The main ring circle: r = ring_r, stroke = agent_status_svg_color(status).
      [a1_ring] = Floki.find(ring1, "circle[stroke-width=\"2\"]")
      assert attr(a1_ring, "r") == [float_str(CommitGraph.ring_r())]
      assert attr(a1_ring, "fill") == ["none"]
      assert attr(a1_ring, "style") == ["stroke: #{Helpers.agent_status_svg_color(:running)}"]

      # a2 is :completed — the fallback status color (base ink).
      [a2_ring] = Floki.find(ring2, "circle[stroke-width=\"2\"]")
      assert attr(a2_ring, "style") == ["stroke: #{Helpers.agent_status_svg_color(:completed)}"]

      # The glow band behind each ring carries the SAME status color.
      [glow1] = Floki.find(ring1, "circle[stroke-width=\"4\"]")
      assert attr(glow1, "stroke-opacity") == ["0.15"]
      assert attr(glow1, "style") == ["stroke: #{Helpers.agent_status_svg_color(:running)}"]
    end

    test "a ring sits exactly on its agent's tip dot center" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))
      [repo] = repos

      a1 = repo.rings |> Enum.find(&(&1.agent_id == "a1"))
      a2 = repo.rings |> Enum.find(&(&1.agent_id == "a2"))

      [ring1] = Floki.find(tree, "#commit-ring-#{dom}-a1")
      [ring2] = Floki.find(tree, "#commit-ring-#{dom}-a2")

      for {group, ring} <- [{ring1, a1}, {ring2, a2}] do
        [main] = Floki.find(group, "circle[stroke-width=\"2\"]")
        assert attr(main, "cx") == [float_str(ring.x)]
        assert attr(main, "cy") == [float_str(ring.y)]
      end
    end

    test "a ring carries a T<id> + status <title> tooltip" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [ring1] = Floki.find(tree, "#commit-ring-#{dom}-a1")
      assert ring1 |> Floki.find("title") |> Floki.text() =~ "T1"
    end

    test "every ring circle is clickable with select_agent + the agent id" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      for {id, agent_id} <- [{"a1", "a1"}, {"a2", "a2"}] do
        [ring] = Floki.find(tree, "#commit-ring-#{dom}-#{id}")
        [main] = Floki.find(ring, "circle[stroke-width=\"2\"]")

        assert attr(main, "phx-click") == ["select_agent"]
        assert attr(main, "phx-value-id") == [agent_id]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ref chips (right gutter)
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — ref chips" do
    test "a commit with refs renders one mono chip per ref in the right gutter" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [tip] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c3}")

      chips =
        tip
        |> Floki.find("text")
        |> Enum.map(&Floki.text/1)
        |> Enum.map(&String.trim/1)

      assert "HEAD" in chips
      assert "genesis/agent_x" in chips

      # The chip backgrounds are rects right of the lane area (width 186 ->
      # gutter starts at 186 - 146 = 40).
      rects = tip |> Floki.find("rect")

      for rect <- rects do
        x = attr(rect, "x") |> hd() |> String.to_float()
        assert x >= 40.0
      end
    end

    test "a ref-less commit renders no chips; a repo with no refs at all renders none either" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [plain] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c1}")
      assert Floki.find(plain, "rect") == []

      bare = [bare_repo_view()]
      bare_dom = hd(bare).repo_dom_id
      tree = parse(render_repos(bare))
      assert Floki.find(tree, "##{bare_dom} rect") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Agent tip markers
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — agent tip markers" do
    test "a TIP dot renders a T<task_local_id> text marker right of the dot" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # a1 tips at @sha_c2, a2 at @sha_c3.
      [c2] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c2}")
      [c3] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c3}")

      texts = fn group ->
        group |> Floki.find("text") |> Enum.map(&String.trim(Floki.text(&1)))
      end

      assert "T1" in texts.(c2)
      assert "T2" in texts.(c3)

      # A non-tip covered dot (@sha_c1 is on a1's path but not the tip) has none.
      [c1] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c1}")
      refute "T1" in texts.(c1)
      assert Floki.find(c1, "text") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Click-to-select contract
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — click to select" do
    test "agent-mapped dots carry the select_agent click contract with the mapped agent id" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # Tip dot of a2 selects a2; a PATH-covered dot of a1 (non-tip) also selects a1.
      [c3] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c3}")
      [c3_circle] = Floki.find(c3, "circle")
      assert attr(c3_circle, "phx-click") == ["select_agent"]
      assert attr(c3_circle, "phx-value-id") == ["a2"]
      assert attr(c3_circle, "class") |> Enum.join(" ") =~ "cursor-pointer"

      [c1] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c1}")
      [c1_circle] = Floki.find(c1, "circle")
      assert attr(c1_circle, "phx-click") == ["select_agent"]
      assert attr(c1_circle, "phx-value-id") == ["a1"]
    end
  end

  # ---------------------------------------------------------------------------
  # Selection halos
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — selection" do
    test "selected_id adds a primary halo ring on the agent's dots AND its ring" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos, selected_id: "a1"))

      # The selected agent's covered dot grows the primary halo circle…
      [c2] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c2}")
      halos = c2 |> Floki.find("circle[stroke-width=\"1.5\"][fill=\"none\"]")
      assert halos != []
      assert attr(hd(halos), "style") == ["stroke: var(--color-primary)"]

      # …and the selected dot's own fill is promoted to full opacity with a
      # primary stroke outline.
      [dot] = Floki.find(c2, "circle[fill-opacity]")
      assert attr(dot, "fill-opacity") == ["1.0"]
      assert attr(dot, "style") == ["fill: #7c38dc; stroke: var(--color-primary)"]

      # The ring of a1 gains the same halo shape.
      [ring] = Floki.find(tree, "#commit-ring-#{dom}-a1")
      ring_halos = Floki.find(ring, "circle[stroke-width=\"1.5\"][fill=\"none\"]")
      assert ring_halos != []

      # An UNselected agent's dot/ring has no halo.
      [c3] = Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c3}")
      assert Floki.find(c3, "circle[stroke-width=\"1.5\"][fill=\"none\"]") == []

      [ring2] = Floki.find(tree, "#commit-ring-#{dom}-a2")
      assert Floki.find(ring2, "circle[stroke-width=\"1.5\"][fill=\"none\"]") == []
    end

    test "a nil or non-matching selected_id renders no halos anywhere" do
      for selected <- [nil, "nope"] do
        tree = parse(render_repos(happy_repos(), selected_id: selected))

        assert Floki.find(tree, "circle[stroke-width=\"1.5\"][fill=\"none\"]") == []
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

      # The cached repos still render …
      assert Floki.find(tree, "##{dom}") != []
      assert Floki.find(tree, "#commit-dot-#{dom}-#{@sha_c1}") != []

      # … and the hard error state is NOT shown.
      assert Floki.find(tree, "#commit-graph-error") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Animation markers
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — animation markers" do
    test "node and edge animation markers are emitted for dots, rings and edges" do
      tree = parse(render_repos(happy_repos()))

      assert Floki.find(tree, ~s([data-commit-graph-anim="node"])) != []
      assert Floki.find(tree, ~s([data-commit-graph-anim="edge"])) != []
      # The redesign has no lane elements anymore.
      assert Floki.find(tree, ~s([data-commit-graph-anim="lane"])) == []
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
    test "a repo with absent dimensions still renders (0-sized viewBox via the dim fallback)" do
      repo = repo_view(width: nil, height: :garbage, commits: [commit(sha: "odd00000")])
      tree = parse(render_repos([repo]))

      [svg] = Floki.find(tree, "##{repo.repo_dom_id} svg")
      assert attr(svg, "viewbox") == ["0 0 0 0"]
      assert Floki.find(tree, "#commit-dot-#{repo.repo_dom_id}-odd00000") != []
    end

    test "odd coordinate shapes degrade to 0 without crashing" do
      repo =
        repo_view(
          commits: [commit(sha: "bad000000", x: nil, y: :garbage, highlight_color: 42)],
          edges: [edge(id: "e1", d: nil, color: :blue)],
          rings: [ring(agent_id: "r1", x: "x", y: nil, status: :running)]
        )

      tree = parse(render_repos([repo]))

      assert [dot] = Floki.find(tree, "#commit-dot-#{repo.repo_dom_id}-bad000000")
      [circle] = Floki.find(dot, "circle")
      assert attr(circle, "cx") == []
      assert attr(circle, "style") == ["fill: var(--color-base-content)"]
    end

    test "an empty commits list renders an empty svg (no dots, no edges, no rings)" do
      repo = repo_view([])
      tree = parse(render_repos([repo]))

      assert Floki.find(tree, "##{repo.repo_dom_id} g") == []
      assert Floki.find(tree, "##{repo.repo_dom_id} path") == []
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

  # A second, independent repo (a single commit, no agents mapping into it) for
  # the multi-repo rendering assertions.
  defp happy_two_repo_fixture do
    agents = [%{id: "a9", parent_id: nil, depth: 0, task_local_id: 9, status: :running}]

    raw = %{
      "foreign-1" => %{
        commits: [
          %{sha: "f1000000", message: "Foreign commit", author_name: "Zoe", parents: []}
        ],
        refs: %{}
      }
    }

    CommitGraph.build(raw, agents)
  end

  # A repo view with commits but NO agent overlay at all: bare dots + bare
  # edges (the muted ink at reduced opacity). Built by the real builder from a
  # graph and an agent whose commits are absent from the fetch.
  defp bare_repo_view do
    raw = %{
      "primary" => %{
        commits: [
          %{sha: "bare00000", message: "Bare tip", author_name: "Ann", parents: ["bare11111"]},
          %{sha: "bare11111", message: "Bare root", author_name: "Ann", parents: []}
        ],
        refs: %{}
      }
    }

    # The agent tips outside the fetched graph: no ring, no coverage, no agent map.
    CommitGraph.build(raw, [%{id: "ghost", depth: 0, repo_id: "primary", current_commit: "zzz"}])
    |> hd()
  end

  # Hand-crafted repo/commit/edge/ring maps for shapes the builder does not
  # easily produce (odd geometry, a known DOM id, an agent-less dot).
  defp repo_view(overrides) do
    Map.merge(
      %{
        repo_key: "primary",
        repo_dom_id: "commit-graph-repo-handcrafted-1",
        repo_name: "Primary Repo",
        width: 100.0,
        height: 50.0,
        lane_count: 1,
        commit_count: 0,
        commits: [],
        edges: [],
        rings: []
      },
      Map.new(overrides)
    )
  end

  defp commit(overrides) do
    Map.merge(
      %{
        sha: "deadbeef",
        short_sha: "deadbeef",
        message: "A commit",
        parents: [],
        lane: 0,
        row: 0,
        x: 24.0,
        y: 27.0,
        refs: [],
        highlight_color: nil,
        agent: nil
      },
      Map.new(overrides)
    )
  end

  defp edge(overrides) do
    Map.merge(%{id: "commit-edge-x", d: "M 0,0 L 1,1", color: nil}, Map.new(overrides))
  end

  defp ring(overrides) do
    Map.merge(
      %{
        agent_id: "a1",
        task_local_id: 1,
        status: :running,
        depth: 0,
        color: "#7c38dc",
        x: 24.0,
        y: 27.0
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

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Circle coordinates render through HEEx number interpolation: a float keeps
  # its ".0" (24.0 -> "24.0").
  defp float_str(v) when is_float(v), do: Float.to_string(v)
  defp float_str(v) when is_integer(v), do: Integer.to_string(v) <> ".0"

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
