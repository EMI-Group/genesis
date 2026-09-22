defmodule EvoDashWeb.AgentsLive.CommitGraphTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.CommitGraph — the assembler behind
  the Agents page TEMPORAL (git commit history) view, rendered as a HORIZONTAL
  agent swimlane: one ROW per agent, one COLUMN per commit, oldest on the left,
  newest on the right.

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, repo I/O, or app-env seam is involved. Every
  fixture is a hand-crafted agent list plus a hand-crafted per-repo commit
  graph, so each assertion traces back to the rules documented on the module:

    - columns = the deduplicated UNION of the agents' first-parent progress
      paths, ordered OLDEST → NEWEST by the chronological key `{rank, date, sha}`,
    - `rank` = a memoized topological rank over the fetched parents,
    - lanes = one row per agent, ordered by `{depth, id}` ascending,
    - a lane's markers / `from_column` / `to_column` / `tip_column`,
    - the depth → hue colors (exact hex pins).
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.CommitGraph

  # Fixture shas: @c1 is the OLDEST of the linear chain @c1 <- @c2 <- @c3 <- @c4;
  # @s1 is a side-branch commit, @m the merge that folds it back, @b0 a commit
  # deliberately ABSENT from every fetched graph, and @cyc_a/@cyc_b a malformed
  # mutually-parented (cyclic) pair.
  @c1 "11111111"
  @c2 "22222222"
  @c3 "33333333"
  @c4 "44444444"
  @m "mmmmmmmm"
  @s1 "ssssssss"
  @b0 "b0000000"
  @cyc_a "aaaaaaaa"
  @cyc_b "bbbbbbbb"
  @long_sha "abcdef0123456789"

  # Exact depth→hue pins (hue = Integer.mod(round(depth * 137.508) + 265, 360),
  # then ThemeColor.hsl_to_hex(hue, 70, 54)) — the documented formula.
  @depth0_color "#7c38dc"
  @depth1_color "#dcad38"
  @depth2_color "#38dcdc"
  @depth3_color "#dc38ab"
  @depth5_color "#384bdc"

  # ---------------------------------------------------------------------------
  # grouping_key/1 + repo_display_name/1 (unchanged public API)
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

    test "any other binary renders as \"Repo: <key>\"; anything else is unknown" do
      assert CommitGraph.repo_display_name("foreign-repo-1") == "Repo: foreign-repo-1"
      assert CommitGraph.repo_display_name("repo_root") == "Repo: repo_root"
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

      # Each view carries exactly its own graph's columns…
      assert Enum.map(alpha.columns, & &1.sha) == [@c2]
      assert Enum.map(primary.columns, & &1.sha) == [@c2, @c3]

      # …and exactly its own agents (two lanes for alpha, one for primary).
      assert Enum.map(alpha.lanes, & &1.agent.id) == [1, 2]
      assert Enum.map(primary.lanes, & &1.agent.id) == [3]
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
  # build/2 — output shape
  # ---------------------------------------------------------------------------

  describe "build/2 — repo_view shape" do
    test "a repo_view exposes exactly the documented keys (and nested shapes)" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert repo |> Map.keys() |> Enum.sort() ==
               [
                 :column_count,
                 :columns,
                 :commit_count,
                 :lanes,
                 :repo_dom_id,
                 :repo_key,
                 :repo_name
               ]

      [column | _] = repo.columns

      assert column |> Map.keys() |> Enum.sort() ==
               [:author_name, :date, :message, :refs, :sha, :short_sha]

      [lane] = repo.lanes

      assert lane |> Map.keys() |> Enum.sort() == [
               :agent,
               :from_column,
               :markers,
               :tip_column,
               :to_column
             ]

      assert lane.agent |> Map.keys() |> Enum.sort() == [
               :color,
               :depth,
               :id,
               :status,
               :task_local_id
             ]

      [marker | _] = lane.markers

      assert marker |> Map.keys() |> Enum.sort() ==
               [:author_name, :column, :date, :message, :refs, :sha, :short_sha, :tip?]
    end

    test "each marker's :column indexes its commit in the repo's columns" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      index = repo.columns |> Enum.with_index() |> Map.new(fn {column, i} -> {column.sha, i} end)
      assert Enum.all?(hd(repo.lanes).markers, &(&1.column == index[&1.sha]))
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — columns (the horizontal time axis)
  # ---------------------------------------------------------------------------

  describe "build/2 — columns (chronological union)" do
    test "columns are the deduplicated UNION of every agent's path, oldest→newest" do
      # Agent 1 walks c2..c4 (its base c1 is excluded); agent 2 walks c3..c4.
      agents = [
        agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4),
        agent(2, nil, repo_id: "primary", base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      # The shared commits appear ONCE, ordered by ascending topological rank.
      assert Enum.map(repo.columns, & &1.sha) == [@c2, @c3, @c4]
    end

    test "column_count, commit_count and length(columns) always agree" do
      agents = [agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      assert repo.column_count == repo.commit_count
      assert repo.column_count == length(repo.columns)
      assert repo.column_count == 3
    end

    test "fetched commits no agent walked are NOT columns" do
      # @s1 is fetched but sits on nobody's first-parent path.
      commits = [
        commit(@c4, parents: [@c3]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@c2, @c3, @c4]
      refute @s1 in Enum.map(repo.columns, & &1.sha)
    end

    test "an unfetched ancestor is not a column; the walk stops there" do
      # @c1's parent @b0 is absent from the fetch, so the path ends AT @c1.
      commits = [
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [@b0])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2, @c3]
      refute @b0 in Enum.map(repo.columns, & &1.sha)
    end

    test "columns tie-break by commit date (then sha) when ranks are equal" do
      # Two in-graph ROOT commits both rank 0; the earlier date must sort first,
      # even though its sha is the lexicographically smaller one.
      commits = [
        commit(@c1, parents: [], date: ~U[2026-06-01 00:00:00Z]),
        commit(@c2, parents: [], date: ~U[2026-01-01 00:00:00Z])
      ]

      agents = [
        agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @c1),
        agent(2, nil, repo_id: "primary", base_commit: nil, current_commit: @c2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      assert Enum.map(repo.columns, & &1.sha) == [@c2, @c1]
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — topological rank ordering
  # ---------------------------------------------------------------------------

  describe "build/2 — topological rank ordering" do
    test "columns follow topological rank, NOT the fetch order of the commit list" do
      # The fetched list is deliberately scrambled; the parent links still decide
      # the oldest→newest order.
      commits = [
        commit(@c3, parents: [@c2]),
        commit(@c1, parents: []),
        commit(@c4, parents: [@c3]),
        commit(@c2, parents: [@c1])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2, @c3, @c4]
    end

    test "the column order is independent of the input commit order" do
      forward = [
        commit(@c4, parents: [@c3]),
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      backward = Enum.reverse(forward)
      a = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @c4)

      [fwd] = CommitGraph.build(%{"primary" => raw(forward)}, [a])
      [bwd] = CommitGraph.build(%{"primary" => raw(backward)}, [a])

      assert Enum.map(fwd.columns, & &1.sha) == Enum.map(bwd.columns, & &1.sha)
      assert Enum.map(fwd.columns, & &1.sha) == [@c1, @c2, @c3, @c4]
    end

    test "rank is 1 + MAX(fetched parent rank), not 1 + parent count" do
      # @m merges two rank-0 roots (rank 1); @c4's single-parent chain is deeper
      # (rank 2). With a 1+COUNT rule @m would rank 3 and land AFTER @c4.
      commits = [
        commit(@m, parents: [@c1, @s1]),
        commit(@s1, parents: []),
        commit(@c4, parents: [@c3]),
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: []),
        commit(@c1, parents: [])
      ]

      agents = [
        agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @m),
        agent(2, nil, repo_id: "primary", base_commit: nil, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      # Rank-0 roots first (by sha), then the rank-1 merge @m and @c3, then @c4.
      # With a 1+COUNT rule @m would rank 3 and sort AFTER @c4.
      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2, @c3, @m, @c4]
    end

    test "an unfetched parent contributes no rank edge" do
      # @c1 lists the ABSENT @b0 as a parent: it is still a rank-0 root and
      # sorts BEFORE @c2 by the sha tie-break. If the absent parent counted,
      # @c1 would rank 1 and land after @c2.
      commits = [
        commit(@c2, parents: []),
        commit(@c1, parents: [@b0])
      ]

      agents = [
        agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @c1),
        agent(2, nil, repo_id: "primary", base_commit: nil, current_commit: @c2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2]
    end

    test "a malformed parent CYCLE terminates with a deterministic order" do
      # @cyc_a and @cyc_b are parents of each other — the memoized rank must
      # break the recursion instead of looping forever.
      commits = [
        commit(@cyc_a, parents: [@cyc_b]),
        commit(@cyc_b, parents: [@cyc_a])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @cyc_a)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert length(repo.columns) == 2
      assert MapSet.new(Enum.map(repo.columns, & &1.sha)) == MapSet.new([@cyc_a, @cyc_b])

      # Same input -> same order (the rank memo is deterministic).
      [again] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert repo.columns == again.columns
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — progress path (first-parent walk)
  # ---------------------------------------------------------------------------

  describe "build/2 — progress path (first-parent walk)" do
    test "the walk follows FIRST parents only (a merge's second parent is skipped)" do
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      # @s1 (the merge's second parent) is not on the first-parent path.
      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2, @c3, @m]
    end

    test "the walk excludes the agent's base_commit" do
      commits = chain([@c1, @c2, @c3, @c4])
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@c2, @c3, @c4]
      refute @c1 in Enum.map(repo.columns, & &1.sha)
    end

    test "the walk stops at the first sha absent from the fetched graph" do
      # @c1's parent @b0 was never fetched -> the path ends AT @c1.
      commits = [
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [@b0])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2, @c3]
    end

    test "a self-parenting commit terminates the walk (seen guard)" do
      commits = [commit(@cyc_a, parents: [@cyc_a])]
      a = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @cyc_a)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@cyc_a]
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — lanes (the vertical agent axis)
  # ---------------------------------------------------------------------------

  describe "build/2 — lanes (order and agent fields)" do
    test "lanes are ordered by {depth, id} ascending" do
      agents = [
        agent(2, nil, repo_id: "primary", depth: 1, base_commit: @c1, current_commit: @c2),
        agent(1, nil, repo_id: "primary", depth: 0, base_commit: @c1, current_commit: @c2),
        agent(3, nil, repo_id: "primary", depth: 0, base_commit: @c1, current_commit: @c2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, agents)

      assert Enum.map(repo.lanes, & &1.agent.id) == [1, 3, 2]
      assert Enum.map(repo.lanes, & &1.agent.depth) == [0, 0, 1]
    end

    test "a lane's agent map carries id/task_local_id/status/depth/color" do
      a =
        agent(1, nil,
          repo_id: "primary",
          task_local_id: 7,
          status: :waiting,
          depth: 0,
          base_commit: @c1,
          current_commit: @c3
        )

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert [lane] = repo.lanes

      assert lane.agent == %{
               id: 1,
               task_local_id: 7,
               status: :waiting,
               depth: 0,
               color: @depth0_color
             }
    end

    test "a nil, non-integer or negative depth is normalized to 0" do
      for depth <- [nil, -1, 1.5, "2", :three] do
        a = agent(1, nil, repo_id: "primary", depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.lanes).agent.depth == 0
      end
    end

    test "an agent with an invalid depth sorts with the depth-0 lanes (by id)" do
      agents = [
        agent(5, nil, repo_id: "primary", depth: nil, base_commit: @c1, current_commit: @c2),
        agent(2, nil, repo_id: "primary", depth: 0, base_commit: @c1, current_commit: @c2),
        agent(9, nil, repo_id: "primary", depth: 3, base_commit: @c1, current_commit: @c2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, agents)

      assert Enum.map(repo.lanes, & &1.agent.id) == [2, 5, 9]
      assert Enum.map(repo.lanes, & &1.agent.depth) == [0, 0, 3]
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — lane markers, from/to/tip columns
  # ---------------------------------------------------------------------------

  describe "build/2 — markers, from/to/tip columns" do
    test "markers are the path commits that are columns, ascending by column" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [a])

      # columns are [c2, c3, c4] at indices 0, 1, 2.
      assert repo.columns |> Enum.map(& &1.sha) == [@c2, @c3, @c4]

      [lane] = repo.lanes
      assert Enum.map(lane.markers, & &1.column) == [0, 1, 2]
      assert Enum.map(lane.markers, & &1.sha) == [@c2, @c3, @c4]
    end

    test "tip?: true marks ONLY the agent's own current_commit" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [a])

      [lane] = repo.lanes
      tips = for m <- lane.markers, m.tip?, do: m.sha
      assert tips == [@c4]
      assert Enum.all?(lane.markers, &is_boolean(&1.tip?))
    end

    test "from_column/to_column bound the markers; tip_column is the current commit's column" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c2, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [a])

      [lane] = repo.lanes
      # Path is c3..c4 -> columns 0 (c3) through 1 (c4).
      assert lane.from_column == 0
      assert lane.to_column == 1
      assert lane.tip_column == 1
    end

    test "a lane whose current_commit is not in the graph has no markers and nil columns" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: "deadbeef")

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

      [lane] = repo.lanes
      assert lane.markers == []
      assert lane.from_column == nil
      assert lane.to_column == nil
      assert lane.tip_column == nil
      # The lane still exists (one row per agent), it is just empty.
      assert lane.agent.id == 1
    end

    test "two lanes sharing commits keep independent markers and tips" do
      agents = [
        agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4),
        agent(2, nil, repo_id: "primary", base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      [lane1, lane2] = repo.lanes
      # columns = [c2, c3, c4]; lane1 walks c2..c4, lane2 walks c3..c4.
      assert Enum.map(lane1.markers, & &1.sha) == [@c2, @c3, @c4]
      assert Enum.map(lane2.markers, & &1.sha) == [@c3, @c4]
      # Both tip at the SAME current commit (c4) at column 2.
      assert lane1.tip_column == 2
      assert lane2.tip_column == 2
    end

    test "a lane with no current_commit (nil or garbage) is empty and never raises" do
      for current <- [nil, 42, :tip] do
        a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: current)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        [lane] = repo.lanes
        assert lane.markers == []
        assert lane.tip_column == nil
        assert repo.columns == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — depth → hue colors
  # ---------------------------------------------------------------------------

  describe "build/2 — depth → hue colors" do
    test "each depth maps to its EXACT documented hue" do
      for {depth, expected} <- [
            {0, @depth0_color},
            {1, @depth1_color},
            {2, @depth2_color},
            {3, @depth3_color},
            {5, @depth5_color}
          ] do
        a = agent(1, nil, repo_id: "primary", depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.lanes).agent.color == expected
      end
    end

    test "a non-integer, nil or negative depth folds to the depth-0 hue" do
      for depth <- [nil, -1, 1.5, "2", :three] do
        a = agent(1, nil, repo_id: "primary", depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.lanes).agent.color == @depth0_color
      end
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — column and marker field rules
  # ---------------------------------------------------------------------------

  describe "build/2 — column and marker field rules" do
    test "short_sha prefers the commit's own value and falls back to the sha prefix" do
      commits = [
        commit(@c4, short_sha: 12_345, parents: [@c3]),
        commit(@c3, short_sha: "", parents: [@c2]),
        commit(@c2, short_sha: "abcdef12", parents: [@c1])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3, c4] = repo.columns

      assert c2.short_sha == "abcdef12"
      # Blank / non-binary short_sha falls back to the first 8 characters of the sha.
      assert c3.short_sha == @c3
      assert c4.short_sha == @c4
    end

    test "the sha prefix fallback truncates to 8 characters (a short sha stays whole)" do
      long = [commit(@long_sha, parents: []), commit(@c1, parents: [])]

      a = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: @long_sha)

      [repo] = CommitGraph.build(%{"primary" => raw(long)}, [a])

      assert hd(repo.columns).short_sha == "abcdef01"

      short = [commit("abc", parents: [])]
      b = agent(1, nil, repo_id: "primary", base_commit: nil, current_commit: "abc")

      [repo2] = CommitGraph.build(%{"primary" => raw(short)}, [b])
      assert hd(repo2.columns).short_sha == "abc"
    end

    test "message is the first line only; a nil or non-binary message renders as \"\"" do
      commits = [
        commit(@c3, parents: [@c2], message: "no body"),
        commit(@c2, parents: [@c1], message: "subject line\n\nbody text\nmore")
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3] = repo.columns
      assert c2.message == "subject line"
      assert c3.message == "no body"

      blanks = [
        commit(@c3, parents: [@c2], message: :not_a_string),
        commit(@c2, parents: [@c1], message: nil)
      ]

      [repo2] = CommitGraph.build(%{"primary" => raw(blanks)}, [a])
      assert Enum.map(repo2.columns, & &1.message) == ["", ""]
    end

    test "author_name is a binary or nil" do
      commits = [
        commit(@c3, parents: [@c2], author_name: :not_binary),
        commit(@c2, parents: [@c1], author_name: "Ada")
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3] = repo.columns
      assert c2.author_name == "Ada"
      assert c3.author_name == nil
    end

    test "date is a %DateTime{} or nil" do
      date = ~U[2026-01-02 03:04:05Z]

      commits = [
        commit(@c3, parents: [@c2], date: "2026-01-02"),
        commit(@c2, parents: [@c1], date: date)
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3] = repo.columns
      assert c2.date == date
      assert c3.date == nil
    end

    test "refs come from raw.refs; a missing or non-list entry renders []" do
      commits = [
        commit(@c4, parents: [@c3]),
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: [@c1])
      ]

      refs = %{@c3 => ["HEAD", "main"], @c2 => "not-a-list"}
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])
      assert [c2, c3, c4] = repo.columns

      assert c2.refs == []
      assert c3.refs == ["HEAD", "main"]
      assert c4.refs == []
    end

    test "markers carry the same commit metadata as columns (plus tip?)" do
      date = ~U[2026-03-04 05:06:07Z]

      commits = [
        commit(@c3, parents: [@c2], message: "subject\nbody", author_name: "Ada", date: date),
        commit(@c2, parents: [@c1])
      ]

      refs = %{@c2 => ["release"]}
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])
      assert [c2, c3] = repo.columns
      assert c3.sha == @c3

      c2_marker = Enum.find(hd(repo.lanes).markers, &(&1.sha == @c2))
      c3_marker = Enum.find(hd(repo.lanes).markers, &(&1.sha == @c3))

      assert c2_marker.short_sha == c2.short_sha
      assert c2_marker.message == c2.message
      assert c2_marker.refs == ["release"]
      assert c2_marker.tip? == false

      assert c3_marker.message == "subject"
      assert c3_marker.author_name == "Ada"
      assert c3_marker.date == date
      assert c3_marker.tip? == true
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — defensive handling
  # ---------------------------------------------------------------------------

  describe "build/2 — defensive handling" do
    test "a repo key absent from raw_by_repo yields a well-formed EMPTY graph" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{}, [a])

      assert repo.columns == []
      assert repo.column_count == 0
      assert repo.commit_count == 0
      assert length(repo.lanes) == 1
      assert hd(repo.lanes).markers == []
      assert hd(repo.lanes).from_column == nil
      assert hd(repo.lanes).to_column == nil
      assert hd(repo.lanes).tip_column == nil
    end

    test "a non-map raw_by_repo degrades to empty graphs" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      for bad <- ["garbage", nil, 42, [:a]] do
        [repo] = CommitGraph.build(bad, [a])
        assert repo.columns == []
        assert repo.column_count == 0
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
        # A commit map without a list of commits degrades to none.
        %{commits: %{}}
      ]

      for graph <- bad_graphs do
        [repo] = CommitGraph.build(%{"primary" => graph}, [a])
        assert repo.columns == []
        assert repo.column_count == 0
      end
    end

    test "a non-map refs value renders [] for every commit" do
      a = agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: @c2)

      graph = %{commits: chain([@c1, @c2]), refs: "nope"}

      [repo] = CommitGraph.build(%{"primary" => graph}, [a])

      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2]
      assert Enum.map(repo.columns, & &1.refs) == [[], []]
    end

    test "commits without a usable :sha are not addressable and never reach columns" do
      commits = [%{message: "no sha"}, %{sha: nil}, %{sha: ""}, %{sha: 42}]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.columns == []
    end

    test "duplicate shas are de-duplicated (no duplicate columns)" do
      commits = [
        commit(@c2, parents: [@c1]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @b0, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.column_count == 2
      assert Enum.map(repo.columns, & &1.sha) == [@c1, @c2]
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
      # A struct carries no :parents key -> treated as a root commit (rank 0).
      assert [c2, _c3] = repo.columns

      assert c2.sha == @c2
      assert c2.short_sha == "abcdef12"
      assert c2.message == "struct subject"
      assert c2.author_name == "Ada"
    end

    test "a single agent map (not a list) is accepted" do
      [repo] =
        CommitGraph.build(
          %{"primary" => raw(chain([@c1, @c2]))},
          %{id: 1, repo_id: "primary", base_commit: @c1, current_commit: @c2}
        )

      assert length(repo.lanes) == 1
      assert hd(repo.lanes).agent.id == 1
      assert repo.column_count == 1
    end

    test "a non-binary repo key is still addressable and gets a stringified DOM id" do
      [repo] = CommitGraph.build(%{123 => %{}}, [%{id: 1, repo_id: 123}])

      assert repo.repo_key == 123
      assert repo.repo_name == "Unknown Repo"
      assert repo.repo_dom_id =~ ~r/^commit-graph-repo-123-\d+$/
    end

    test "an agent map missing every read key still yields a well-formed repo view" do
      [repo] = CommitGraph.build(%{}, [%{}])

      assert repo.repo_key == nil
      # A nil key renders the primary label.
      assert repo.repo_name == "Primary Repo"
      assert repo.columns == []
      assert repo.column_count == 0
      assert length(repo.lanes) == 1

      [lane] = repo.lanes

      assert lane.agent == %{
               id: nil,
               task_local_id: nil,
               status: nil,
               depth: 0,
               color: @depth0_color
             }

      assert lane.markers == []
      assert lane.from_column == nil
      assert lane.to_column == nil
      assert lane.tip_column == nil
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
  # The assembler walks first-parent links, so the fixture is built oldest-first
  # for readability and reversed before it is returned (git-log order).
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
end
