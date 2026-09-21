defmodule EvoDashWeb.AgentsLive.CommitGraphTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.CommitGraph — the temporal
  (git commit history) graph assembler for the Agents page.

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, repo I/O, or app-env seam is involved. Every
  fixture is a hand-crafted agent list plus a hand-crafted per-repo commit
  graph, so each assertion can be traced back to the lane/ownership rules
  documented on the module.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.CommitGraph

  # Four consecutive commits, oldest first (@c1 is the root of the chain).
  @c1 "11111111"
  @c2 "22222222"
  @c3 "33333333"
  @c4 "44444444"

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

  describe "build/2 — repo grouping and sorting" do
    test "one repo_view per distinct grouping key, with repo_id as the fallback" do
      agents = [
        agent(1, nil, repo_root: "/a/alpha"),
        # Same repo_root -> the same group.
        agent(2, nil, repo_root: "/a/alpha"),
        # No repo_root -> the primary group.
        agent(3, nil, repo_id: "primary")
      ]

      views = CommitGraph.build(%{}, agents)

      assert length(views) == 2
      # "Primary Repo" (uppercase P) sorts before "alpha" by name.
      assert Enum.map(views, & &1.repo_key) == ["primary", "/a/alpha"]
      assert Enum.map(views, & &1.repo_name) == ["Primary Repo", "alpha"]

      assert Enum.map(views |> repo_by_key("/a/alpha") |> Map.fetch!(:lanes), & &1.agent_id) == [
               1,
               2
             ]
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

  describe "build/2 — lane construction" do
    test "one lane per agent with a 0-based lane_index" do
      agents = [agent(1, nil, repo_id: "primary"), agent(2, 1, repo_id: "primary")]

      [repo] = CommitGraph.build(%{}, agents)

      assert [l1, l2] = repo.lanes
      assert l1.agent_id == 1
      assert l1.lane_index == 0
      assert l2.agent_id == 2
      assert l2.lane_index == 1
    end

    test "depth-first order: parents before children, children ascending by id" do
      # Deliberately shuffled input: a1 -> a2 -> a4 and a1 -> a3.
      agents = [
        agent(4, 2, repo_id: "primary", depth: 2),
        agent(3, 1, repo_id: "primary", depth: 1),
        agent(1, nil, repo_id: "primary", depth: 0),
        agent(2, 1, repo_id: "primary", depth: 1)
      ]

      [repo] = CommitGraph.build(%{}, agents)

      assert Enum.map(repo.lanes, & &1.agent_id) == [1, 2, 4, 3]
      assert Enum.map(repo.lanes, & &1.lane_index) == [0, 1, 2, 3]
      assert Enum.map(repo.lanes, & &1.depth) == [0, 1, 2, 1]
    end

    test "a lane carries the agent's metadata verbatim" do
      a =
        agent(1, nil,
          repo_id: "primary",
          depth: 3,
          status: :completed,
          agent_module: "EvoGit.Agents.Executor",
          model_id: "profile-a",
          task_local_id: "t1",
          base_commit: @c1,
          current_commit: @c2
        )

      [repo] = CommitGraph.build(%{}, [a])
      [lane] = repo.lanes

      assert lane.depth == 3
      assert lane.status == :completed
      assert lane.agent_module == "EvoGit.Agents.Executor"
      assert lane.model_id == "profile-a"
      assert lane.task_local_id == "t1"
      assert lane.base_commit == @c1
      assert lane.current_commit == @c2
      assert lane.parent_agent_id == nil
      assert lane.parent_lane_index == nil
      assert lane.connects? == false
      # No graph was fetched for the repo, so the range contributes nothing.
      assert lane.commits == []
    end

    test "a missing or nil depth defaults to 0" do
      agents = [
        %{id: 1, parent_id: nil, repo_id: "primary", depth: nil},
        %{id: 2, parent_id: nil, repo_id: "primary"}
      ]

      [repo] = CommitGraph.build(%{}, agents)

      assert Enum.map(repo.lanes, & &1.depth) == [0, 0]
    end

    test "an id-less agent is not cross-linked into another root's child list" do
      # The two id-less roots differ by task_local_id so they stay distinct values
      # (the traversal's visited set compares agents by value).
      agents = [
        %{id: nil, parent_id: nil, repo_id: "primary", task_local_id: "t-a"},
        %{id: nil, parent_id: nil, repo_id: "primary", task_local_id: "t-b"},
        agent(1, nil, repo_id: "primary"),
        agent(2, 1, repo_id: "primary")
      ]

      [repo] = CommitGraph.build(%{}, agents)

      # Roots sort by id (number < atom/nil): a1, then the two id-less agents.
      assert Enum.map(repo.lanes, & &1.agent_id) == [1, 2, nil, nil]

      assert repo.lanes
             |> Enum.reject(&(&1.agent_id == 2))
             |> Enum.all?(&(&1.parent_lane_index == nil))
    end
  end

  describe "build/2 — fork-point child lanes" do
    test "a child lane connects to its parent's lane" do
      agents = [agent(1, nil, repo_id: "primary"), agent(2, 1, repo_id: "primary")]

      [repo] = CommitGraph.build(%{}, agents)
      assert [l1, l2] = repo.lanes

      assert l1.parent_agent_id == nil
      assert l1.parent_lane_index == nil
      assert l1.connects? == false

      assert l2.parent_agent_id == 1
      assert l2.parent_lane_index == 0
      assert l2.connects? == true
    end

    test "a grandchild connects to its own parent's lane, not the root's" do
      agents = [
        agent(1, nil, repo_id: "primary"),
        agent(2, 1, repo_id: "primary"),
        agent(3, 2, repo_id: "primary")
      ]

      [repo] = CommitGraph.build(%{}, agents)
      assert [l1, l2, l3] = repo.lanes

      assert {l1.parent_lane_index, l1.connects?} == {nil, false}
      assert {l2.parent_lane_index, l2.connects?} == {0, true}
      assert l3.parent_agent_id == 2
      assert {l3.parent_lane_index, l3.connects?} == {1, true}
    end

    test "a cross-repo parent yields no lane connection" do
      agents = [
        agent(1, nil, repo_root: "/r/alpha"),
        # The parent lives in the alpha group, so this agent roots the beta group.
        agent(2, 1, repo_root: "/r/beta")
      ]

      views = CommitGraph.build(%{}, agents)

      assert [alpha_lane] = repo_by_key(views, "/r/alpha").lanes

      assert {alpha_lane.agent_id, alpha_lane.parent_lane_index, alpha_lane.connects?} ==
               {1, nil, false}

      assert [beta_lane] = repo_by_key(views, "/r/beta").lanes
      assert beta_lane.parent_agent_id == 1
      assert beta_lane.parent_lane_index == nil
      assert beta_lane.connects? == false
    end

    test "an agent whose parent id is absent from its own group is a root" do
      agents = [agent(1, 99, repo_id: "primary"), agent(2, nil, repo_id: "primary")]

      [repo] = CommitGraph.build(%{}, agents)

      assert Enum.map(repo.lanes, & &1.agent_id) == [1, 2]
      assert Enum.all?(repo.lanes, &(&1.parent_lane_index == nil))
      assert Enum.all?(repo.lanes, &(&1.connects? == false))
    end

    test "a malformed parent cycle still yields exactly one lane per agent" do
      # a1's parent is a2 and a2's parent is a1: no agent is reachable from a root.
      agents = [agent(1, 2, repo_id: "primary"), agent(2, 1, repo_id: "primary")]

      [repo] = CommitGraph.build(%{}, agents)

      assert Enum.map(repo.lanes, & &1.agent_id) == [1, 2]
      assert length(repo.lanes) == 2
    end
  end

  describe "build/2 — commit ownership (fork-point resolution)" do
    test "an agent owns the commits from its base (exclusive) to its tip" do
      commits = chain([@c1, @c2, @c3, @c4])
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      [lane] = repo.lanes

      # Oldest -> newest, with the exclusive base commit left to another lane.
      assert Enum.map(lane.commits, & &1.sha) == [@c2, @c3, @c4]
      refute Enum.any?(lane.commits, &(&1.sha == @c1))
    end

    test "has_parent_in_lane? is false exactly at the lane's fork point" do
      commits = chain([@c1, @c2, @c3, @c4])
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      [lane] = repo.lanes

      # @c2's first parent is the base @c1 (another lane's history) -> connector.
      assert Enum.map(lane.commits, & &1.has_parent_in_lane?) == [false, true, true]
      assert lane.commits |> List.last() |> Map.fetch!(:sha) == @c4
    end

    test "a child lane owns only the commits it produced" do
      commits = chain([@c1, @c2, @c3, @c4])

      agents = [
        agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2),
        agent(2, 1, repo_id: "primary", base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)
      assert [parent_lane, child_lane] = repo.lanes

      assert Enum.map(parent_lane.commits, & &1.sha) == [@c2]
      assert Enum.map(child_lane.commits, & &1.sha) == [@c3, @c4]
      # The child's oldest commit is its own fork point off the parent's tip.
      assert Enum.map(child_lane.commits, & &1.has_parent_in_lane?) == [false, true]
    end

    test "a commit reachable from two lanes is owned by exactly one lane" do
      commits = chain([@c1, @c2, @c3, @c4])

      agents = [
        agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4),
        agent(2, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)
      assert [first_lane, second_lane] = repo.lanes

      # The first lane in lane order claims the shared history.
      assert Enum.map(first_lane.commits, & &1.sha) == [@c2, @c3, @c4]
      # The second lane reaches claimed history immediately -> owns nothing.
      assert second_lane.commits == []

      shas = Enum.flat_map(repo.lanes, &Enum.map(&1.commits, fn c -> c.sha end))
      assert shas == Enum.uniq(shas)
      assert Enum.sort(shas) == [@c2, @c3, @c4]
    end

    test "a lane stopping at an earlier lane's history keeps only its own commits" do
      commits = chain([@c1, @c2, @c3, @c4])

      agents = [
        agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3),
        agent(2, 1, repo_id: "primary", base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)
      assert [lane_a, lane_b] = repo.lanes

      assert Enum.map(lane_a.commits, & &1.sha) == [@c2, @c3]
      # @c4 is new, but its parent @c3 is already claimed, so the walk stops there.
      assert Enum.map(lane_b.commits, & &1.sha) == [@c4]
      assert Enum.map(lane_b.commits, & &1.has_parent_in_lane?) == [false]
    end

    test "base_commit == current_commit yields an empty lane" do
      commits = chain([@c1, @c2])
      a = agent(1, nil, repo_id: "primary", base_commit: @c2, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert hd(repo.lanes).commits == []
    end

    test "a nil or non-binary base/current commit yields an empty lane" do
      commits = chain([@c1, @c2])

      for {base, current} <- [{nil, @c2}, {@c1, nil}, {nil, nil}, {123, @c2}, {@c1, :tip}] do
        a = agent(1, nil, repo_id: "primary", base_commit: base, current_commit: current)
        [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

        # No usable range -> the walk is skipped entirely (odd types never raise).
        assert hd(repo.lanes).commits == []
      end
    end

    test "a tip absent from the fetched graph owns nothing" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: "deadbeef")
      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

      assert hd(repo.lanes).commits == []
    end

    test "a shallow fetch stops the walk at the first missing sha" do
      # Only the tip is present; its parent was not fetched.
      commits = [commit(@c4, parents: [@c3])]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(hd(repo.lanes).commits, & &1.sha) == [@c4]
    end

    test "an in-walk parent cycle terminates and claims each sha once" do
      commits = [commit(@c2, parents: [@c4]), commit(@c4, parents: [@c2])]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(hd(repo.lanes).commits, & &1.sha) == [@c2, @c4]
    end
  end

  describe "build/2 — commit view fields" do
    test "short_sha prefers the commit's own value and falls back to the sha prefix" do
      commits = [
        commit(@c2, short_sha: "abcdef12", parents: [@c1]),
        commit(@c3, short_sha: "", parents: [@c2]),
        commit(@c4, short_sha: 12_345, parents: [@c3])
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3, c4] = hd(repo.lanes).commits

      assert c2.short_sha == "abcdef12"
      # Blank / non-binary short_sha falls back to the first 8 characters of the sha.
      assert c3.short_sha == @c3
      assert c4.short_sha == @c4
    end

    test "the sha prefix fallback truncates to 8 characters (a short sha stays whole)" do
      commits = [commit("abc", parents: ["base-00"])]
      a = agent(1, nil, repo_id: "primary", base_commit: "base-00", current_commit: "abc")

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert hd(hd(repo.lanes).commits).short_sha == "abc"
    end

    test "message, author, date, parents and refs are carried through" do
      date = ~U[2026-01-02 03:04:05Z]

      commits = [
        commit(@c2,
          parents: [@c1],
          message: "subject line\n\nbody text\nmore",
          author_name: "Ada",
          date: date
        ),
        commit(@c3, parents: [@c2], message: "no body")
      ]

      refs = %{@c3 => ["HEAD", "main"], @c4 => ["tag: v1"]}
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])
      assert [c2, c3] = hd(repo.lanes).commits

      assert c2.message == "subject line"
      assert c2.author_name == "Ada"
      assert c2.date == date
      assert c2.parents == [@c1]
      # No refs entry for @c2 in the repo's refs map.
      assert c2.refs == []

      assert c3.message == "no body"
      assert c3.author_name == nil
      assert c3.parents == [@c2]
      assert c3.refs == ["HEAD", "main"]
    end

    test "a nil or non-binary message renders as an empty string" do
      commits = [
        commit(@c2, parents: [@c1], message: nil),
        commit(@c3, parents: [@c2], message: :not_a_string)
      ]

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert Enum.map(hd(repo.lanes).commits, & &1.message) == ["", ""]
    end

    test "malformed or absent refs render as []" do
      commits = [commit(@c2, parents: [@c1]), commit(@c3, parents: [@c2])]
      refs = %{@c2 => "not-a-list", @c3 => []}

      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])

      assert Enum.map(hd(repo.lanes).commits, & &1.refs) == [[], []]
    end

    test "struct-shaped commits are map-like and their missing parents/refs degrade safely" do
      struct_commit = %EvoGit.Review.CommitInfo{
        sha: @c2,
        short_sha: "abcdef12",
        message: "struct subject",
        author_name: "Ada",
        date: nil
      }

      commits = [struct_commit, commit(@c3, parents: [@c2])]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert [c2, c3] = hd(repo.lanes).commits

      assert c2.sha == @c2
      assert c2.short_sha == "abcdef12"
      assert c2.message == "struct subject"
      # A struct carries no :parents key -> treated as a root commit.
      assert c2.parents == []
      assert c2.has_parent_in_lane? == false
      # @c3's first parent is owned by the same lane.
      assert c3.has_parent_in_lane? == true
    end
  end

  describe "build/2 — defensive handling" do
    test "a repo key absent from raw_by_repo yields lanes with empty commit lists" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{}, [a])

      assert [lane] = repo.lanes
      assert lane.agent_id == 1
      assert lane.commits == []
    end

    test "a non-map raw_by_repo degrades to empty graphs" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      for bad <- ["garbage", nil, 42, [:a]] do
        [repo] = CommitGraph.build(bad, [a])
        assert hd(repo.lanes).commits == []
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
        assert hd(repo.lanes).commits == []
      end
    end

    test "a non-map refs value renders [] for every commit" do
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      raw = %{commits: chain([@c1, @c2]), refs: "nope"}

      [repo] = CommitGraph.build(%{"primary" => raw}, [a])

      assert [commit_view] = hd(repo.lanes).commits
      assert commit_view.sha == @c2
      assert commit_view.refs == []
    end

    test "commits without a usable :sha are not addressable and never raise" do
      commits = [%{message: "no sha"}, %{sha: nil}, %{sha: ""}, %{sha: 42}]
      a = agent(1, nil, repo_id: "primary", base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert hd(repo.lanes).commits == []
    end

    test "an agent map missing every read key still yields a well-formed lane" do
      [repo] = CommitGraph.build(%{}, [%{}])

      assert repo.repo_key == nil
      # A nil key renders the primary label.
      assert repo.repo_name == "Primary Repo"
      assert [lane] = repo.lanes
      assert lane.agent_id == nil
      assert lane.lane_index == 0
      assert lane.depth == 0
      assert lane.parent_agent_id == nil
      assert lane.parent_lane_index == nil
      assert lane.connects? == false
      assert lane.status == nil
      assert lane.agent_module == nil
      assert lane.model_id == nil
      assert lane.task_local_id == nil
      assert lane.base_commit == nil
      assert lane.current_commit == nil
      assert lane.commits == []
    end

    test "a single agent map (not a list) is accepted" do
      [repo] = CommitGraph.build(%{}, %{id: 1, parent_id: nil, repo_id: "primary"})

      assert [lane] = repo.lanes
      assert lane.agent_id == 1
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

  # A linear chain of commits (oldest first): each commit's first parent is the
  # previous one, so `chain([c1, c2, c3])` models c1 <- c2 <- c3.
  defp chain(shas) do
    shas
    |> Enum.with_index()
    |> Enum.map(fn {sha, index} ->
      parents = if index == 0, do: [], else: [Enum.at(shas, index - 1)]
      commit(sha, parents: parents)
    end)
  end

  # The `raw_by_repo` value for ONE repo.
  defp raw(commits, refs \\ %{}), do: %{commits: commits, refs: refs}

  defp repo_by_key(views, repo_key), do: Enum.find(views, &(&1.repo_key == repo_key))
end
