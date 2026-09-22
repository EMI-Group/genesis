defmodule EvoDashWeb.AgentsLive.CommitGraphTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.CommitGraph — the assembler behind
  the Agents page TEMPORAL (git commit history) view, a CLASSIC git graph
  (`git log --graph` style) later rendered as SVG dots + edges + agent rings.

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, repo I/O, or app-env seam is involved. Every
  fixture is a hand-crafted agent list plus a hand-crafted per-repo commit
  graph, so each assertion traces back to the lane/overlay rules documented on
  the module:

    - lane assignment (first-available-lane, merge folding, oldest-at-top),
    - dot geometry (x/y/dimensions formulas),
    - edges (child→parent `d` endpoints, same-lane vs cross-lane shapes),
    - the depth→hue overlay colors (exact hex pins),
    - agent rings on TIP commits only,
    - the two-tier dot click-target mapping (tip vs path-covering).
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.CommitGraph

  # Fixture shas: @c1 is the OLDEST of the linear chain @c1 <- @c2 <- @c3 <- @c4;
  # @s1 is a side-branch commit, @m the merge that folds it back, @b0 a commit
  # deliberately ABSENT from every fetched graph.
  @c1 "11111111"
  @c2 "22222222"
  @c3 "33333333"
  @c4 "44444444"
  @m "mmmmmmmm"
  @s1 "ssssssss"
  @b0 "b0000000"

  # Exact depth→hue pins (hue = Integer.mod(round(depth * 137.508) + 265, 360),
  # then ThemeColor.hsl_to_hex(hue, 70, 54)) — the documented formula.
  @depth0_color "#7c38dc"
  @depth1_color "#dcad38"
  @depth2_color "#38dcdc"
  @depth5_color "#384bdc"

  # ---------------------------------------------------------------------------
  # Geometry getters — the single source of truth consumed by the SVG renderer
  # ---------------------------------------------------------------------------

  describe "geometry getters" do
    test "dot_r/0 and ring_r/0 expose the documented radii" do
      assert CommitGraph.dot_r() == 4.5
      assert CommitGraph.ring_r() == 8.5
    end
  end

  # ---------------------------------------------------------------------------
  # grouping_key/1 + repo_display_name/1
  # ---------------------------------------------------------------------------

  describe "grouping_key/1" do
    test "prefers repo_root (an absolute path) over repo_id" do
      assert CommitGraph.grouping_key(%{repo_root: "/home/dev/repo", repo_id: "primary"}) ==
               "/home/dev/repo"
    end

    test "falls back to repo_id when repo_root is absent or nil" do
      assert CommitGraph.grouping_key(%{repo_id: "foreign-1"}) == "foreign-1"
      assert CommitGraph.grouping_key(%{repo_root: nil, repo_id: "primary"}) == "primary"
    end

    test "absent repo fields yield nil (a single unnamed group)" do
      assert CommitGraph.grouping_key(%{}) == nil
      assert CommitGraph.grouping_key(%{id: 1}) == nil
    end
  end

  describe "repo_display_name/1" do
    # Tests run in the default :en locale, so the msgids themselves are asserted.
    test "primary repo keys (string, atom, nil) render as the primary label" do
      assert CommitGraph.repo_display_name("primary") == "Primary Repo"
      assert CommitGraph.repo_display_name(:primary) == "Primary Repo"
      assert CommitGraph.repo_display_name(nil) == "Primary Repo"
    end

    test "an absolute Unix path renders as its basename" do
      assert CommitGraph.repo_display_name("/home/dev/my-repo") == "my-repo"
    end

    test "a Windows drive path is recognized as absolute" do
      # Forward slashes are separators on every host, so this expectation is OS-independent.
      assert CommitGraph.repo_display_name("C:/Users/dev/proj") == "proj"

      # Backslash separators only split on Windows, so derive the expectation with
      # the same host-OS `Path.basename/1` the module uses (proves the absolute
      # branch was taken rather than the "Repo: <key>" fallback).
      windows_path = "C:\\Users\\dev\\proj"
      assert CommitGraph.repo_display_name(windows_path) == Path.basename(windows_path)
    end

    test "a UNC path is recognized as absolute" do
      assert CommitGraph.repo_display_name("//server/share/proj") == "proj"
    end

    test "any other binary renders as \"Repo: <key>\"" do
      assert CommitGraph.repo_display_name("foreign-repo-1") == "Repo: foreign-repo-1"
      assert CommitGraph.repo_display_name("repo_root") == "Repo: repo_root"
    end

    test "a non-binary, non-primary key renders the unknown fallback" do
      assert CommitGraph.repo_display_name(42) == "Unknown Repo"
      assert CommitGraph.repo_display_name({:a, 1}) == "Unknown Repo"
      assert CommitGraph.repo_display_name(:other) == "Unknown Repo"
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — repo grouping and sorting
  # ---------------------------------------------------------------------------

  describe "build/2 — repo grouping and sorting" do
    test "one repo_view per distinct grouping key, each fed ONLY its own graph" do
      agents = [
        agent(1, nil, repo_root: "/a/alpha", base_commit: @c1, current_commit: @c2),
        # Same repo_root -> the same group.
        agent(2, nil, repo_root: "/a/alpha", base_commit: @c1, current_commit: @c2),
        # No repo_root -> the primary group.
        agent(3, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)
      ]

      raw_by_repo = %{
        "/a/alpha" => raw(chain([@c1, @c2])),
        "primary" => raw(chain([@c1, @c2, @c3]))
      }

      views = CommitGraph.build(raw_by_repo, agents)

      assert length(views) == 2

      alpha = repo_by_key(views, "/a/alpha")
      primary = repo_by_key(views, "primary")

      # Each view carries exactly its own graph's commits…
      assert alpha.commit_count == 2
      assert primary.commit_count == 3

      # …and exactly its own agents' rings (both alpha agents tip inside alpha).
      assert Enum.map(alpha.rings, & &1.agent_id) == [1, 2]
      assert Enum.map(primary.rings, & &1.agent_id) == [3]
    end

    test "repos are sorted by display name ascending" do
      agents = [
        agent(1, nil, repo_root: "/r/zulu"),
        agent(2, nil, repo_root: "/r/alpha"),
        agent(3, nil, repo_root: "/r/mike")
      ]

      views = CommitGraph.build(%{}, agents)

      assert Enum.map(views, & &1.repo_name) == ["alpha", "mike", "zulu"]
    end

    test "repo_dom_id is deterministic and DOM-safe" do
      agents = [agent(1, nil, repo_id: "primary")]

      first = CommitGraph.build(%{}, agents)
      second = CommitGraph.build(%{}, agents)

      assert hd(first).repo_dom_id == hd(second).repo_dom_id
      assert hd(first).repo_dom_id =~ ~r/^commit-graph-repo-[A-Za-z0-9_-]+-\d+$/
    end

    test "keys that sanitize to the same slug still get distinct DOM ids (hash suffix)" do
      with_space = CommitGraph.build(%{}, [agent(1, nil, repo_root: "/a/x y")])
      with_slash = CommitGraph.build(%{}, [agent(2, nil, repo_root: "/a/x/y")])

      assert hd(with_space).repo_dom_id != hd(with_slash).repo_dom_id
    end

    test "the view order is stable across input permutations (ties break on repo_dom_id)" do
      a = agent(1, nil, repo_root: "/one/proj")
      b = agent(2, nil, repo_root: "/two/proj")

      forward = CommitGraph.build(%{}, [a, b])
      backward = CommitGraph.build(%{}, [b, a])

      # Both keys display "proj", so the documented tie-break (repo_dom_id) decides.
      assert Enum.map(forward, & &1.repo_name) == ["proj", "proj"]
      assert Enum.map(forward, & &1.repo_dom_id) == Enum.map(backward, & &1.repo_dom_id)
      assert forward == Enum.sort_by(forward, & &1.repo_dom_id)
    end

    test "a nil or empty agents list produces no repo views" do
      assert CommitGraph.build(%{"primary" => %{}}, nil) == []
      assert CommitGraph.build(%{}, []) == []
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — geometry: dimensions + dot positions
  # ---------------------------------------------------------------------------

  describe "build/2 — geometry (dimensions and dot positions)" do
    test "dimensions follow the documented formulas" do
      # chain(@c1..@c4): 4 rows, 1 lane.
      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [
          agent(1, nil, repo_id: "primary")
        ])

      assert repo.commit_count == 4
      assert repo.lane_count == 1
      # width  = pad_left + lane_count * lane_width + right_gutter
      assert repo.width == 12 + 1 * 24 + 150
      # height = pad_top + rows * row_height + pad_bottom
      assert repo.height == 14 + 4 * 26 + 14
    end

    test "dot centers follow x(lane) / y(row) with the OLDEST commit at the top" do
      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [
          agent(1, nil, repo_id: "primary")
        ])

      # The output list is ordered TOP → BOTTOM (oldest first)…
      assert Enum.map(repo.commits, & &1.sha) == [@c1, @c2, @c3, @c4]

      # …with row 0 at the top and strictly increasing y downwards.
      assert Enum.map(repo.commits, & &1.row) == [0, 1, 2, 3]
      ys = Enum.map(repo.commits, & &1.y)
      assert ys == Enum.sort(ys) and Enum.uniq(ys) == ys

      for commit <- repo.commits do
        # x(lane) = pad_left + lane * lane_width + lane_width / 2
        assert commit.x == 12 + commit.lane * 24 + 12
        # y(row) = pad_top + row * row_height + row_height / 2
        assert commit.y == 14 + commit.row * 26 + 13
      end
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — lane assignment (classic first-available-lane)
  # ---------------------------------------------------------------------------

  describe "build/2 — lane assignment" do
    test "a linear chain occupies a single lane" do
      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [
          agent(1, nil, repo_id: "primary")
        ])

      assert repo.lane_count == 1
      assert Enum.map(repo.commits, & &1.lane) == [0, 0, 0, 0]
    end

    test "a branch forks onto its own lane (first free slot), then merges fold back" do
      # Newest-first input order (git log shape):
      #
      #   m   (parents: c3, s1)   <- a merge of the branch back into lane 0
      #   c3  (parents: c2)
      #   s1  (parents: c2)       <- the branch: 2nd parent slot
      #   c2  (parents: c1)
      #   c1  (parents: b0, absent from the fetch)
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [@b0])
      ]

      [repo] =
        CommitGraph.build(%{"primary" => raw(commits)}, [agent(1, nil, repo_id: "primary")])

      # Two lanes total (the branch never exceeds one extra lane)…
      assert repo.lane_count == 2

      # …and the oldest-first lane assignment: the merge + trunk live on lane 0,
      # the side commit on lane 1.
      assert repo.commits
             |> Enum.map(fn c -> {c.sha, c.lane} end)
             |> Map.new() == %{@c1 => 0, @c2 => 0, @s1 => 1, @c3 => 0, @m => 0}
    end

    test "two sibling branches off one parent spread onto separate lanes" do
      # Newest-first input order: c3 and c2 both grow from c1 with no merge, so
      # the FIRST parent claim keeps lane 0 (c3's walk) and the second fork
      # (c2) is appended as lane 1.
      commits = [
        commit(@c3, parents: [@c1]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      [repo] =
        CommitGraph.build(%{"primary" => raw(commits)}, [agent(1, nil, repo_id: "primary")])

      assert repo.lane_count == 2

      assert repo.commits
             |> Enum.map(fn c -> {c.sha, c.lane} end)
             |> Map.new() == %{@c1 => 0, @c2 => 1, @c3 => 0}
    end

    test "a commit whose parents are all absent from the fetch ends its lane" do
      # @c1's parent @b0 was not fetched — the root leaves its slot free, but the
      # lane index it occupied still counts (lane_count never shrinks).
      commits = [commit(@c2, parents: [@c1]), commit(@c1, parents: [@b0])]

      [repo] =
        CommitGraph.build(%{"primary" => raw(commits)}, [agent(1, nil, repo_id: "primary")])

      assert repo.lane_count == 1

      assert repo.commits |> Enum.map(fn c -> {c.sha, c.lane} end) |> Map.new() == %{
               @c1 => 0,
               @c2 => 0
             }
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — edges
  # ---------------------------------------------------------------------------

  describe "build/2 — edges" do
    test "one edge per (child, parent) pair with BOTH ends in the graph" do
      # @c1's parent @b0 is absent -> no edge for it.
      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [
          agent(1, nil, repo_id: "primary")
        ])

      # Edges are emitted top → bottom (oldest commit first).
      assert Enum.map(repo.edges, & &1.id) ==
               Enum.map([{@c2, @c1}, {@c3, @c2}, {@c4, @c3}], fn {child, parent} ->
                 "commit-edge-#{repo.repo_dom_id}-#{child}-#{parent}"
               end)
    end

    test "edges connect the real child and parent dot centers, child BELOW parent" do
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [@b0])
      ]

      [repo] =
        CommitGraph.build(%{"primary" => raw(commits)}, [agent(1, nil, repo_id: "primary")])

      positions = repo.commits |> Enum.map(fn c -> {c.sha, {c.x, c.y}} end) |> Map.new()

      for edge <- repo.edges do
        suffix = String.replace_prefix(edge.id, "commit-edge-#{repo.repo_dom_id}-", "")
        [child, parent] = String.split(suffix, "-")
        {sx, sy, ex, ey} = endpoints(edge.d)

        # The path starts exactly on the CHILD dot and ends exactly on the PARENT dot.
        assert {sx, sy} == positions[child]
        assert {ex, ey} == positions[parent]
        # The child is newer, so it renders BELOW its parent.
        assert sy > ey
      end

      # Every parent pair present in the graph got exactly one edge — @c1's
      # absent parent @b0 contributes none.
      assert length(repo.edges) == 5
    end

    test "same-lane edges are straight lines; cross-lane edges are cubic beziers" do
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [@b0])
      ]

      [repo] =
        CommitGraph.build(%{"primary" => raw(commits)}, [agent(1, nil, repo_id: "primary")])

      edges = repo.edges |> Enum.map(fn e -> {e.id, e.d} end) |> Map.new()

      # @m (lane 0) -> @c3 (lane 0): straight.
      assert edges["commit-edge-#{repo.repo_dom_id}-#{@m}-#{@c3}"] =~
               ~r/^M [0-9.]+,[0-9.]+ L [0-9.]+,[0-9.]+$/

      # @m (lane 0) -> @s1 (lane 1): cubic with the two control points.
      assert edges["commit-edge-#{repo.repo_dom_id}-#{@m}-#{@s1}"] =~
               ~r/^M [0-9.]+,[0-9.]+ C [0-9.]+,[0-9.]+ [0-9.]+,[0-9.]+ [0-9.]+,[0-9.]+$/

      # @s1 (lane 1) -> @c2 (lane 0): also a bezier.
      assert edges["commit-edge-#{repo.repo_dom_id}-#{@s1}-#{@c2}"] =~ ~r/ C /
    end

    test "a cross-lane bezier bends at the vertical midpoint between the two rows" do
      commits = [
        commit(@c3, parents: [@c1]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      [repo] =
        CommitGraph.build(%{"primary" => raw(commits)}, [agent(1, nil, repo_id: "primary")])

      # @c2 sits on lane 1; its edge back to @c1 (lane 0) is the bezier.
      [edge] = Enum.filter(repo.edges, &String.ends_with?(&1.id, "#{@c2}-#{@c1}"))

      positions = repo.commits |> Enum.map(fn c -> {c.sha, {c.x, c.y}} end) |> Map.new()
      {xc, cy} = positions[@c2]
      {xp, py} = positions[@c1]
      mid = (cy + py) / 2

      assert edge.d ==
               "M #{num(xc)},#{num(cy)} C #{num(xc)},#{num(mid)} #{num(xp)},#{num(mid)} #{num(xp)},#{num(py)}"
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — depth → hue overlay colors
  # ---------------------------------------------------------------------------

  describe "build/2 — depth → hue colors" do
    test "an agent's path dots and edges carry its EXACT depth hue" do
      # Depth 0 agent over c2..c4 (base c1 in the graph).
      a = agent(1, nil, repo_id: "primary", depth: 0, base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [a])

      assert @depth0_color == "#7c38dc"

      assert repo.commits |> Enum.map(fn c -> {c.sha, c.highlight_color} end) |> Map.new() == %{
               @c1 => nil,
               @c2 => @depth0_color,
               @c3 => @depth0_color,
               @c4 => @depth0_color
             }

      # Every edge of the covered path (incl. the oldest→base edge) is colored.
      assert repo.edges |> Enum.all?(&(&1.color == @depth0_color))
    end

    test "distinct depths map to distinct documented hues" do
      for {depth, expected} <- [
            {0, @depth0_color},
            {1, @depth1_color},
            {2, @depth2_color},
            {5, @depth5_color}
          ] do
        a = agent(1, nil, repo_id: "primary", depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        # The tip dot, the covering edge and the ring all carry the same hue.
        assert [_, tip] = repo.commits
        assert tip.highlight_color == expected
        assert hd(repo.rings).color == expected
        assert hd(repo.edges).color == expected
      end
    end

    test "a non-integer, nil or negative depth folds to the depth-0 hue" do
      for depth <- [nil, -1, 1.5, "2", :three] do
        a = agent(1, nil, repo_id: "primary", depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.rings).depth == 0
        assert hd(repo.rings).color == @depth0_color
      end
    end

    test "overlay conflicts resolve first-write-wins in ascending {depth, id} order" do
      # The shallow agent walks the WHOLE chain (its base is absent); the deep
      # agent's path is only @c2. The shallow agent is processed FIRST (depth 0),
      # so it claims @c2 before the deep agent ever sees it.
      shallow = agent(9, nil, repo_id: "primary", depth: 0, base_commit: @b0, current_commit: @c3)
      deep = agent(10, nil, repo_id: "primary", depth: 5, base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [shallow, deep])

      colors = repo.commits |> Enum.map(fn c -> {c.sha, c.highlight_color} end) |> Map.new()

      # The first writer (depth 0) owns every dot it covered…
      assert colors[@c1] == @depth0_color
      assert colors[@c2] == @depth0_color
      assert colors[@c3] == @depth0_color
      # …and nothing of the deep agent's hue leaks into the graph.
      refute @depth5_color in Map.values(colors)

      # Rings are independent of dot-color conflicts: one PER agent.
      assert Enum.map(repo.rings, & &1.color) == [@depth0_color, @depth5_color]
    end

    test "the edge into an in-graph base is covered; an absent base contributes nothing" do
      commits = chain([@c1, @c2, @c3])

      with_base =
        CommitGraph.build(
          %{"primary" => raw(commits)},
          [agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)]
        )
        |> hd()

      # base in graph: the walk collects c3, c2 — and covers c2 -> c1 as well.
      assert Enum.map(with_base.edges, & &1.color) == [@depth0_color, @depth0_color]

      no_base =
        CommitGraph.build(
          %{"primary" => raw(commits)},
          [agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: @c3)]
        )
        |> hd()

      # base absent: the walk collects c3, c2, c1 — covering BOTH edges (the
      # pair edge c3→c2 and c2→c1; there is no c1→b0 edge at all).
      assert Enum.map(no_base.edges, & &1.color) == [@depth0_color, @depth0_color]

      assert Enum.map(no_base.commits, & &1.highlight_color) == [
               @depth0_color,
               @depth0_color,
               @depth0_color
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — agent overlay: rings on TIP commits
  # ---------------------------------------------------------------------------

  describe "build/2 — rings" do
    test "an agent whose current_commit is in the graph contributes a ring there" do
      a =
        agent(1, nil,
          repo_id: "primary",
          task_local_id: 7,
          status: :waiting,
          base_commit: @c1,
          current_commit: @c3
        )

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [a])

      assert [ring] = repo.rings

      assert Map.take(ring, [:agent_id, :task_local_id, :status, :depth, :color]) == %{
               agent_id: 1,
               task_local_id: 7,
               status: :waiting,
               depth: 0,
               color: @depth0_color
             }

      # The ring sits EXACTLY on the tip commit's dot.
      tip = repo.commits |> Enum.find(&(&1.sha == @c3))
      assert {ring.x, ring.y} == {tip.x, tip.y}
    end

    test "an agent whose current_commit is absent from the graph contributes NO ring" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: "deadbeef")

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

      assert repo.rings == []
      # …and nothing it owns colors the graph either.
      assert Enum.map(repo.commits, & &1.highlight_color) == [nil, nil]
    end

    test "rings accumulate one PER AGENT, in ascending {depth, id} order" do
      # Two agents tipping at the SAME commit: two stacked rings.
      agents = [
        agent(2, nil, repo_id: "primary", depth: 1, base_commit: @c1, current_commit: @c4),
        agent(1, nil, repo_id: "primary", depth: 0, base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      assert Enum.map(repo.rings, & &1.agent_id) == [1, 2]
      assert Enum.map(repo.rings, & &1.depth) == [0, 1]
      assert Enum.map(repo.rings, & &1.color) == [@depth0_color, @depth1_color]
    end

    test "a nil or non-binary current_commit contributes no ring and never raises" do
      for current <- [nil, 42, :tip] do
        a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: current)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert repo.rings == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — dot click-target mapping (tip tier vs path tier)
  # ---------------------------------------------------------------------------

  describe "build/2 — dot click targets" do
    test "the TIP dot carries its agent with tip?: true" do
      a =
        agent(1, nil, repo_id: "primary", task_local_id: 3, base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      agents = repo.commits |> Enum.map(fn c -> {c.sha, c.agent} end) |> Map.new()

      assert %{
               id: 1,
               task_local_id: 3,
               status: :running,
               depth: 0,
               color: @depth0_color,
               tip?: true
             } =
               agents[@c3]
    end

    test "a path-covered NON-tip dot carries the covering agent with tip?: false" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      agents = repo.commits |> Enum.map(fn c -> {c.sha, c.agent} end) |> Map.new()

      assert agents[@c2].tip? == false
      assert agents[@c2].id == 1
      # The exclusive base maps to NO agent at all.
      assert agents[@c1] == nil
    end

    test "the tip tier beats the path tier regardless of {depth, id} order" do
      # The DEEP agent tips at @c2; the SHALLOW agent merely walks over @c2.
      # The shallow one is processed first, yet the tip tier must win the dot.
      shallow = agent(1, nil, repo_id: "primary", depth: 0, base_commit: @b0, current_commit: @c3)
      deep = agent(2, nil, repo_id: "primary", depth: 5, base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [shallow, deep])

      agents = repo.commits |> Enum.map(fn c -> {c.sha, c.agent} end) |> Map.new()

      assert agents[@c2].id == 2
      assert agents[@c2].tip? == true
      assert agents[@c3].id == 1
      assert agents[@c3].tip? == true
      assert agents[@c1].id == 1
      assert agents[@c1].tip? == false
    end

    test "two agents tipping at the same commit: first in {depth, id} order wins the dot" do
      agents = [
        agent(2, nil, repo_id: "primary", depth: 1, base_commit: @c1, current_commit: @c4),
        agent(1, nil, repo_id: "primary", depth: 0, base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      tip = repo.commits |> Enum.find(&(&1.sha == @c4))
      assert tip.agent.id == 1
      assert tip.agent.tip? == true
    end

    test "a commit no agent maps to carries a nil click target" do
      # The side commit of a branch is on nobody's first-parent path.
      commits = [
        commit(@c3, parents: [@c1]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      agents = repo.commits |> Enum.map(fn c -> {c.sha, c.agent} end) |> Map.new()

      assert agents[@c3].id == 1
      assert agents[@c2] == nil
      assert agents[@c1] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — commit view fields
  # ---------------------------------------------------------------------------

  describe "build/2 — commit view fields" do
    test "short_sha prefers the commit's own value and falls back to the sha prefix" do
      commits = [
        commit(@c4, short_sha: 12_345, parents: [@c3]),
        commit(@c3, short_sha: "", parents: [@c2]),
        commit(@c2, short_sha: "abcdef12", parents: [@c1])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3, c4] = repo.commits

      assert c2.short_sha == "abcdef12"
      # Blank / non-binary short_sha falls back to the first 8 characters of the sha.
      assert c3.short_sha == @c3
      assert c4.short_sha == @c4
    end

    test "the sha prefix fallback truncates to 8 characters (a short sha stays whole)" do
      commits = [commit("abc", parents: [@b0])]
      a = agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: "abc")

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert hd(repo.commits).short_sha == "abc"
    end

    test "message is the first line only; parents and refs are carried through" do
      date = ~U[2026-01-02 03:04:05Z]

      commits = [
        commit(@c3, parents: [@c2], message: "no body"),
        commit(@c2,
          parents: [@c1],
          message: "subject line\n\nbody text\nmore",
          author_name: "Ada",
          date: date
        )
      ]

      refs = %{@c3 => ["HEAD", "main"], @c4 => ["tag: v1"]}
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])
      assert [c2, c3] = repo.commits

      assert c2.message == "subject line"
      assert c2.parents == [@c1]
      # No refs entry for @c2 in the repo's refs map.
      assert c2.refs == []

      assert c3.message == "no body"
      assert c3.parents == [@c2]
      assert c3.refs == ["HEAD", "main"]
    end

    test "a nil or non-binary message renders as an empty string" do
      commits = [
        commit(@c3, parents: [@c2], message: :not_a_string),
        commit(@c2, parents: [@c1], message: nil)
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.commits, & &1.message) == ["", ""]
    end

    test "malformed or absent refs render as []" do
      commits = [commit(@c2, parents: [@c1]), commit(@c3, parents: [@c2])]
      refs = %{@c2 => "not-a-list", @c3 => []}

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])

      assert Enum.map(repo.commits, & &1.refs) == [[], []]
    end

    test "repeated parents are de-duplicated (one edge, one lane reservation)" do
      # Newest-first: @c2 lists the same parent twice.
      commits = [commit(@c2, parents: [@c1, @c1]), commit(@c1, parents: [])]
      a = agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.lane_count == 1
      assert length(repo.edges) == 1
    end

    test "struct-shaped commits are map-like and their missing parents degrade safely" do
      struct_commit = %EvoGit.Review.CommitInfo{
        sha: @c2,
        short_sha: "abcdef12",
        message: "struct subject",
        author_name: "Ada",
        date: nil
      }

      commits = [commit(@c3, parents: [@c2]), struct_commit]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, _c3] = repo.commits

      assert c2.sha == @c2
      assert c2.short_sha == "abcdef12"
      assert c2.message == "struct subject"
      # A struct carries no :parents key -> treated as a root commit.
      assert c2.parents == []
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — defensive handling
  # ---------------------------------------------------------------------------

  describe "build/2 — defensive handling" do
    test "a repo key absent from raw_by_repo yields a well-formed EMPTY graph" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{}, [a])

      assert repo.commits == []
      assert repo.edges == []
      assert repo.rings == []
      assert repo.lane_count == 0
      assert repo.commit_count == 0
      assert repo.width == 12 + 0 * 24 + 150
      assert repo.height == 14 + 0 * 26 + 14
    end

    test "a non-map raw_by_repo degrades to empty graphs" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      for bad <- ["garbage", nil, 42, [:a]] do
        [repo] = CommitGraph.build(bad, [a])
        assert repo.commits == []
        assert repo.rings == []
      end
    end

    test "a malformed repo graph or commits key degrades to an empty graph" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      bad_graphs = [
        "garbage",
        %{},
        %{commits: "nope"},
        %{commits: nil},
        # Non-map entries are filtered out of the commit list.
        %{commits: [nil, :not_a_map, "a string"]},
        # A non-list refs value degrades to "no refs" without affecting the commits.
        %{commits: %{}}
      ]

      for graph <- bad_graphs do
        [repo] = CommitGraph.build(%{"primary" => graph}, [a])
        assert repo.commits == []
        assert repo.rings == []
      end
    end

    test "a non-map refs value renders [] for every commit" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      raw = %{commits: chain([@c1, @c2]), refs: "nope"}

      [repo] = CommitGraph.build(%{"primary" => raw}, [a])

      assert Enum.map(repo.commits, & &1.refs) == [[], []]
    end

    test "commits without a usable :sha are not addressable and never raise" do
      commits = [%{message: "no sha"}, %{sha: nil}, %{sha: ""}, %{sha: 42}]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.commits == []
    end

    test "duplicate shas are de-duplicated (no duplicate DOM ids)" do
      commits = [
        commit(@c2, parents: [@c1]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.commit_count == 2
      assert Enum.map(repo.commits, & &1.sha) == [@c1, @c2]
    end

    test "an agent map missing every read key still yields a well-formed repo view" do
      [repo] = CommitGraph.build(%{}, [%{}])

      assert repo.repo_key == nil
      # A nil key renders the primary label.
      assert repo.repo_name == "Primary Repo"
      assert repo.commits == []
      assert repo.edges == []
      assert repo.rings == []
      assert repo.lane_count == 0
    end

    test "a single agent map (not a list) is accepted" do
      [repo] =
        CommitGraph.build(
          %{"primary" => raw(chain([@c1, @c2]))},
          %{id: 1, repo_id: "primary", base_commit: @c1, current_commit: @c2}
        )

      assert Enum.map(repo.rings, & &1.agent_id) == [1]
      assert repo.commit_count == 2
    end

    test "a non-binary repo key is still addressable and gets a stringified DOM id" do
      [repo] = CommitGraph.build(%{123 => %{}}, [%{id: 1, repo_id: 123}])

      assert repo.repo_key == 123
      assert repo.repo_name == "Unknown Repo"
      assert repo.repo_dom_id =~ ~r/^commit-graph-repo-123-\d+$/
    end
  end

  # --- fixtures -------------------------------------------------------------

  # An agent map carrying the keys the graph assembler reads, defaulted for the
  # ones a test does not care about.
  defp agent(id, parent_id, opts) do
    %{
      id: id,
      parent_id: parent_id,
      repo_root: Keyword.get(opts, :repo_root),
      repo_id: Keyword.get(opts, :repo_id, "primary"),
      depth: Keyword.get(opts, :depth, 0),
      task_local_id: Keyword.get(opts, :task_local_id),
      status: Keyword.get(opts, :status, :running),
      agent_module: Keyword.get(opts, :agent_module),
      model_id: Keyword.get(opts, :model_id),
      base_commit: Keyword.get(opts, :base_commit),
      current_commit: Keyword.get(opts, :current_commit)
    }
  end

  defp commit(sha, opts) do
    %{
      sha: sha,
      short_sha: Keyword.get(opts, :short_sha),
      message: Keyword.get(opts, :message),
      author_name: Keyword.get(opts, :author_name),
      date: Keyword.get(opts, :date),
      parents: Keyword.get(opts, :parents, [])
    }
  end

  # A linear chain of commits, `chain([c1, c2, c3])` modeling c1 <- c2 <- c3.
  # The assembler consumes git-log order (NEWEST FIRST), so the fixture is
  # built oldest-first for readability and reversed before it is returned.
  defp chain(shas) do
    shas
    |> Enum.with_index()
    |> Enum.map(fn {sha, index} ->
      parents = if index == 0, do: [], else: [Enum.at(shas, index - 1)]
      commit(sha, parents: parents)
    end)
    |> Enum.reverse()
  end

  # The `raw_by_repo` value for ONE repo.
  defp raw(commits, refs \\ %{}), do: %{commits: commits, refs: refs}

  defp repo_by_key(views, repo_key), do: Enum.find(views, &(&1.repo_key == repo_key))

  # --- edge-path helpers ------------------------------------------------------

  # The four coordinates of an edge `d` path: {sx, sy, ex, ey} — the point after
  # "M" (the CHILD dot) and the LAST space-separated token (the PARENT dot).
  defp endpoints(d) do
    parts = String.split(d, " ")
    {x(sx(parts)), y(sx(parts)), x(Enum.at(parts, -1)), y(Enum.at(parts, -1))}
  end

  defp sx(parts), do: Enum.at(parts, 1)

  defp x(point_bin) do
    point_bin |> String.split(",") |> hd() |> Float.parse() |> elem(0)
  end

  defp y(point_bin) do
    point_bin |> String.split(",") |> Enum.at(1) |> Float.parse() |> elem(0)
  end

  # Compact SVG number formatting — mirrors the assembler's own `num/1` so the
  # bezier assertion builds the exact expected path string.
  defp num(v) when is_float(v) do
    s = Float.to_string(v)
    if String.ends_with?(s, ".0"), do: binary_part(s, 0, byte_size(s) - 2), else: s
  end
end
