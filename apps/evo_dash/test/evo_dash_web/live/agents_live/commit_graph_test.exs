defmodule EvoDashWeb.AgentsLive.CommitGraphTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.CommitGraph — the assembler behind
  the Agents page TEMPORAL (git commit history) view, rendered as a
  COMMIT-CENTRIC HORIZONTAL DAG: one NODE per commit, one EDGE per child →
  parent link present in the fetched graph, ancestry flowing left → right
  (oldest → newest), plus one horizontal LANE (band) per agent.

  These are pure data transformations over plain maps — no LiveView, socket,
  repo I/O, or app-env seam. Every fixture is hand-crafted, so each assertion
  traces back to a rule documented on the module: node synthesis (fetched
  commits + one `kind: :base` node per uncovered agent `base_commit`), the `x`
  topological rank, ownership and the first-parent progress path, the `:parent`
  / `:merge` edges, the `start_ids` / `end_ids` annotations, the lane model and
  the depth → hue colors.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.CommitGraph

  # @c1 is the OLDEST of the chain @c1 <- @c2 <- @c3 <- @c4; @s1 a side-branch
  # commit and @m the merge folding it back. @b0/@other_base are absent from
  # every fetched graph (usable as fork points), @orphan a fetched root nobody
  # walks, @cyc_a/@cyc_b a malformed mutually-parented (cyclic) pair, and
  # @p/@y1/@y2 a fork-point fixture.
  @c1 "11111111"
  @c2 "22222222"
  @c3 "33333333"
  @c4 "44444444"
  @m "mmmmmmmm"
  @s1 "ssssssss"
  @b0 "b0000000"
  @other_base "c0000000"
  @cyc_a "aaaaaaaa"
  @cyc_b "bbbbbbbb"
  @long_sha "abcdef0123456789"
  @orphan "oooooooo"
  @y1 "y1000000"
  @y2 "y2000000"
  @p "pppppppp"

  # Exact depth→hue pins: hue = Integer.mod(round(depth * 137.508) + 265, 360),
  # then ThemeColor.hsl_to_hex(hue, 70, 54) — the documented formula.
  @depth0_color "#7c38dc"
  @depth1_color "#dcad38"
  @depth2_color "#38dcdc"
  @depth3_color "#dc38ab"
  @depth5_color "#384bdc"

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

  describe "build/2 — repo grouping and sorting" do
    test "one repo_view per distinct grouping key, each fed ONLY its own graph" do
      agents = [
        agent(1, nil, repo_root: "/a/alpha", base_commit: @c1, current_commit: @c2),
        # The same repo_root groups together.
        agent(2, nil, repo_root: "/a/alpha", base_commit: @c1, current_commit: @c2),
        # No repo_root -> the primary group (repo_id defaults to "primary").
        agent(3, nil, base_commit: @c1, current_commit: @c3)
      ]

      raw_by_repo = %{
        "/a/alpha" => raw(chain([@c1, @c2])),
        "primary" => raw(chain([@c1, @c2, @c3]))
      }

      views = CommitGraph.build(raw_by_repo, agents)

      assert length(views) == 2

      alpha = repo_by_key(views, "/a/alpha")
      primary = repo_by_key(views, "primary")

      # Each view carries only its own graph's nodes…
      assert node_shas(alpha) |> Enum.sort() == [@c1, @c2]
      assert node_shas(primary) |> Enum.sort() == [@c1, @c2, @c3]

      # …and only its own agents (two lanes for alpha, one for primary).
      assert Enum.map(alpha.lanes, & &1.agent_id) == [1, 2]
      assert Enum.map(primary.lanes, & &1.agent_id) == [3]
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

    test "repo_dom_id is deterministic and DOM-safe; same-slug keys stay distinct" do
      agents = [agent(1, nil)]

      first = CommitGraph.build(%{}, agents)
      second = CommitGraph.build(%{}, agents)

      assert hd(first).repo_dom_id == hd(second).repo_dom_id
      assert hd(first).repo_dom_id =~ ~r/^commit-graph-repo-[A-Za-z0-9_-]+-\d+$/

      # Both keys sanitize to "a-x-y", but the phash2 suffix disambiguates them.
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

    test "a nil or empty agents list produces NO repo views (repos are derived from agents)" do
      assert CommitGraph.build(%{"primary" => %{}}, nil) == []
      assert CommitGraph.build(%{}, []) == []
    end
  end

  describe "build/2 — output shape and counts" do
    test "a repo_view exposes exactly its documented keys, counts and max_x" do
      a = agent(1, nil, base_commit: @b0, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert keys(repo) ==
               ~w(edge_count edges lane_count lanes max_x node_count nodes repo_dom_id repo_key repo_name row_count)a

      assert [node | _] = repo.nodes

      assert keys(node) ==
               ~w(author_name date end_ids kind message owner_id refs sha short_sha start_ids x y)a

      assert [edge | _] = repo.edges

      assert keys(edge) == ~w(from from_sha kind owner_id to to_sha)a

      assert [lane] = repo.lanes

      assert keys(lane) ==
               ~w(agent_id color depth end_sha ended node_count start_sha status task_local_id x_end x_start y)a

      # The counts agree with the lists and row_count mirrors lane_count.
      assert repo.node_count == length(repo.nodes)
      assert repo.edge_count == length(repo.edges)
      assert repo.lane_count == length(repo.lanes)
      assert repo.row_count == repo.lane_count
      # The chain's oldest real commit ranks 0, so max_x is the tip's rank.
      assert repo.max_x == repo.nodes |> Enum.map(& &1.x) |> Enum.max()
      assert repo.max_x == 2
    end
  end

  describe "build/2 — nodes" do
    test "one node per ADDRESSABLE fetched commit, de-duplicated by sha" do
      commits = [
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        # A duplicate sha is collapsed.
        commit(@c2, parents: [@c1]),
        %{message: "no sha"},
        %{sha: nil},
        %{sha: ""},
        %{sha: 42},
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, base_commit: nil, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.node_count == 3
      assert node_shas(repo) |> Enum.sort() == [@c1, @c2, @c3]
      assert Enum.all?(repo.nodes, &(&1.kind == :commit))
    end

    test "a fetched commit that equals an agent base_commit stays a NORMAL :commit node" do
      a = agent(1, nil, base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert node(repo, @c1).kind == :commit
      assert repo.node_count == 3
      assert Enum.all?(repo.nodes, &(&1.kind == :commit))
    end

    test "a covered base_commit is NOT synthesized; an uncovered one still is" do
      # Two agents in ONE repo: agent 1 forks from a sha the fetch covers, agent
      # 2 from a fork point the fetch does not — only the latter gets a node.
      covered = agent(1, nil, base_commit: @c1, current_commit: @c3)
      uncovered = agent(2, nil, base_commit: @b0, current_commit: @c3)

      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [covered, uncovered])

      # 3 fetched commits + exactly 1 synthesized base.
      assert repo.node_count == 4
      assert Enum.count(repo.nodes, &(&1.kind == :commit)) == 3
      assert Enum.count(repo.nodes, &(&1.kind == :base)) == 1

      # The covered base sha appears exactly ONCE, as a normal commit node.
      assert Enum.count(repo.nodes, &(&1.sha == @c1)) == 1
      assert node(repo, @c1).kind == :commit

      # The only synthesized base is the uncovered fork point.
      assert for(n <- repo.nodes, n.kind == :base, do: n.sha) == [@b0]
    end

    test "a distinct agent base_commit absent from the fetch is synthesized as a :base node" do
      a = agent(1, nil, base_commit: @b0, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert repo.node_count == 4

      # A base node carries no metadata of its own — only the fork shas…
      assert node(repo, @b0) == %{
               sha: @b0,
               short_sha: @b0,
               message: "",
               author_name: nil,
               date: nil,
               refs: [],
               x: -1,
               y: 0,
               kind: :base,
               owner_id: 1,
               start_ids: [1],
               end_ids: []
             }

      # …while the real commits stay untouched.
      assert node(repo, @c1).kind == :commit
      assert node(repo, @c1).x == 0
    end

    test "each distinct base gets its own node; long/garbage base shas are handled" do
      a1 = agent(1, nil, base_commit: @b0, current_commit: @c2)
      a2 = agent(2, nil, base_commit: @other_base, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a1, a2])

      base_shas = for n <- repo.nodes, n.kind == :base, do: n.sha

      assert Enum.sort(base_shas) == Enum.sort([@b0, @other_base])
      assert repo.node_count == 4

      # A base sha longer than 8 characters is sliced for its short form.
      long_base = agent(1, nil, base_commit: "1234567890", current_commit: @c2)
      [repo2] = CommitGraph.build(%{"primary" => raw([])}, [long_base])

      assert node(repo2, "1234567890").short_sha == "12345678"

      # A non-binary / blank base is not a fork point at all.
      for base <- [nil, "", 42, :base] do
        short = agent(1, nil, base_commit: base, current_commit: @c2)
        [repo3] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [short])

        assert Enum.all?(repo3.nodes, &(&1.kind == :commit))
        assert repo3.node_count == 2
      end
    end
  end

  describe "build/2 — node metadata" do
    test "short_sha prefers the commit's own value and falls back to the sha prefix" do
      commits = [
        commit(@c4, short_sha: 12_345, parents: [@c3]),
        commit(@c3, short_sha: "", parents: [@c2]),
        commit(@c2, short_sha: "abcdef12", parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert node(repo, @c2).short_sha == "abcdef12"
      # Blank / non-binary short_sha falls back to the first 8 characters of the sha.
      assert node(repo, @c3).short_sha == @c3
      assert node(repo, @c4).short_sha == @c4
      assert node(repo, @c1).short_sha == @c1

      long = agent(1, nil, base_commit: nil, current_commit: @long_sha)
      [repo2] = CommitGraph.build(%{"primary" => raw([commit(@long_sha, parents: [])])}, [long])
      assert node(repo2, @long_sha).short_sha == "abcdef01"

      # A sha shorter than 8 characters stays whole.
      short = agent(1, nil, base_commit: nil, current_commit: "abc")
      [repo3] = CommitGraph.build(%{"primary" => raw([commit("abc", parents: [])])}, [short])
      assert node(repo3, "abc").short_sha == "abc"
    end

    test "message is the first line; author_name and date are typed (or nil)" do
      date = ~U[2026-01-02 03:04:05Z]

      commits = [
        commit(@c3,
          parents: [@c2],
          message: :not_a_string,
          author_name: :not_binary,
          date: "2026"
        ),
        commit(@c2,
          parents: [@c1],
          message: "subject line\n\nbody text",
          author_name: "Ada",
          date: date
        ),
        commit(@c1, parents: [], message: nil)
      ]

      a = agent(1, nil, base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert node(repo, @c2).message == "subject line"
      assert node(repo, @c2).author_name == "Ada"
      assert node(repo, @c2).date == date
      # A non-binary message/author/date degrades to "" / nil.
      assert node(repo, @c3).message == ""
      assert node(repo, @c3).author_name == nil
      assert node(repo, @c3).date == nil
      assert node(repo, @c1).message == ""
    end

    test "refs come from raw.refs; a missing, non-map or non-list entry renders []" do
      commits = chain([@c1, @c2, @c3, @c4])
      refs = %{@c3 => ["HEAD", "main"], @c2 => "not-a-list"}
      a = agent(1, nil, base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])

      assert node(repo, @c3).refs == ["HEAD", "main"]
      assert node(repo, @c2).refs == []
      assert node(repo, @c4).refs == []

      # A non-map refs value degrades to [] everywhere.
      [repo2] = CommitGraph.build(%{"primary" => %{commits: commits, refs: "nope"}}, [a])

      assert Enum.all?(repo2.nodes, &(&1.refs == []))
    end
  end

  describe "build/2 — x (topological rank → grid column)" do
    test "x is the topological rank, NOT the fetch order of the commit list" do
      # The fetched list is deliberately scrambled; the parent links decide the order.
      scrambled = [
        commit(@c3, parents: [@c2]),
        commit(@c1, parents: []),
        commit(@c4, parents: [@c3]),
        commit(@c2, parents: [@c1])
      ]

      a = agent(1, nil, base_commit: nil, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(scrambled)}, [a])

      assert Enum.map(repo.nodes, & &1.x) == [0, 1, 2, 3]

      # The same graph in the opposite input order yields the same nodes.
      [bwd] = CommitGraph.build(%{"primary" => raw(Enum.reverse(scrambled))}, [a])
      assert bwd.nodes == repo.nodes
    end

    test "rank is 1 + MAX(fetched parent rank), not 1 + parent count" do
      # @m merges two rank-0 roots (rank 1); the @c4 chain is deeper (rank 2).
      # With a 1+COUNT rule @m would rank 3 and land right of @c4.
      commits = [
        commit(@m, parents: [@c1, @s1]),
        commit(@s1, parents: []),
        commit(@c4, parents: [@c3]),
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: []),
        commit(@c1, parents: [])
      ]

      a1 = agent(1, nil, base_commit: nil, current_commit: @m)
      a2 = agent(2, nil, base_commit: nil, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a1, a2])

      assert node(repo, @m).x == 1
      assert node(repo, @c4).x == 2
      assert node(repo, @c1).x == 0
      assert node(repo, @s1).x == 0
    end

    test "an unfetched parent contributes no rank (the commit still ranks as a root)" do
      # @c1 lists the ABSENT @b0 as a parent: it is still a rank-0 root, so both
      # roots tie. If the absent parent counted, @c1 would rank 1.
      commits = [commit(@c2, parents: []), commit(@c1, parents: [@b0])]

      a1 = agent(1, nil, base_commit: nil, current_commit: @c1)
      a2 = agent(2, nil, base_commit: nil, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a1, a2])

      assert node(repo, @c1).x == 0
      assert node(repo, @c2).x == 0
    end

    test "a synthesized base node sits ONE column left of the oldest real commit" do
      a = agent(1, nil, base_commit: @b0, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert node(repo, @c1).x == 0
      assert node(repo, @b0).x == -1
      assert Enum.min(Enum.map(repo.nodes, & &1.x)) == -1

      # With no real commit at all the lone base node still lands at -1 (max_x = -1).
      b = agent(1, nil, base_commit: @b0, current_commit: @b0)
      [repo2] = CommitGraph.build(%{"primary" => raw([])}, [b])

      assert node_shas(repo2) == [@b0]
      assert repo2.max_x == -1
    end

    test "a malformed parent CYCLE terminates deterministically" do
      # @cyc_a and @cyc_b are parents of each other — the memoized rank must break
      # the recursion instead of looping forever.
      commits = [commit(@cyc_a, parents: [@cyc_b]), commit(@cyc_b, parents: [@cyc_a])]

      a = agent(1, nil, base_commit: nil, current_commit: @cyc_a)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.node_count == 2
      assert node_shas(repo) |> Enum.sort() == [@cyc_a, @cyc_b]
      # The `visiting` set folds the back edge to rank 0, so the pair ranks 1 and 2.
      assert Enum.map(repo.nodes, & &1.x) |> Enum.sort() == [1, 2]

      # Same input -> same result (the rank memo is deterministic).
      [again] = CommitGraph.build(%{"primary" => raw(commits)}, [a])
      assert repo == again
    end
  end

  describe "build/2 — edges (child → parent)" do
    test "one :parent edge per present parent, with the nodes' grid coordinates" do
      a = agent(1, nil, base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert repo.edge_count == 2

      assert edge(repo, @c3, @c2) == %{
               from_sha: @c3,
               to_sha: @c2,
               from: {2, 0},
               to: {1, 0},
               kind: :parent,
               owner_id: 1
             }

      assert edge(repo, @c2, @c1) == %{
               from_sha: @c2,
               to_sha: @c1,
               from: {1, 0},
               to: {0, 0},
               kind: :parent,
               owner_id: 1
             }

      # Edges are sorted by {from_sha, to_sha}.
      assert Enum.map(repo.edges, &{&1.from_sha, &1.to_sha}) == [{@c2, @c1}, {@c3, @c2}]
    end

    test "a folded side branch produces :merge; the first present parent stays :parent" do
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a = agent(1, nil, base_commit: nil, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.edge_count == 5
      assert edge(repo, @m, @c3).kind == :parent
      assert edge(repo, @m, @s1).kind == :merge
      assert edge(repo, @c3, @c2).kind == :parent
      assert edge(repo, @s1, @c2).kind == :parent
      assert edge(repo, @c2, @c1).kind == :parent

      # The merge edge keeps the child's owner and the parents' coordinates.
      assert edge(repo, @m, @s1) == %{
               from_sha: @m,
               to_sha: @s1,
               from: {3, 0},
               to: {2, 0},
               kind: :merge,
               owner_id: 1
             }
    end

    test "an absent parent produces no edge, and the first PRESENT parent is :parent" do
      commits = [
        commit(@m, parents: [@b0, @c2, @s1]),
        commit(@c2, parents: []),
        commit(@s1, parents: [])
      ]

      a = agent(1, nil, base_commit: nil, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      # @b0 is neither fetched nor an agent fork point -> not a node, no edge.
      refute @b0 in node_shas(repo)
      refute Enum.any?(repo.edges, &(&1.to_sha == @b0))

      # @c2 is the first PRESENT parent -> :parent; @s1 is the folded side branch.
      assert edge(repo, @m, @c2).kind == :parent
      assert edge(repo, @m, @s1).kind == :merge
      assert repo.edge_count == 2
    end

    test "edges are de-duplicated and a base node is an edge TARGET only" do
      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      dups = [commit(@c2, parents: [@c1]), commit(@c2, parents: [@c1]), commit(@c1, parents: [])]
      [repo] = CommitGraph.build(%{"primary" => raw(dups)}, [a])

      assert repo.edge_count == 1
      assert Enum.map(repo.edges, &{&1.from_sha, &1.to_sha}) == [{@c2, @c1}]

      dup_parents = [commit(@c2, parents: [@c1, @c1]), commit(@c1, parents: [])]
      [repo2] = CommitGraph.build(%{"primary" => raw(dup_parents)}, [a])

      assert repo2.edge_count == 1

      # A synthesized base node has no parents, so it is only ever an edge target.
      b = agent(1, nil, base_commit: @b0, current_commit: @c2)
      fork = [commit(@c2, parents: [@c1]), commit(@c1, parents: [@b0])]
      [repo3] = CommitGraph.build(%{"primary" => raw(fork)}, [b])

      assert edge(repo3, @c1, @b0) == %{
               from_sha: @c1,
               to_sha: @b0,
               from: {0, 0},
               to: {-1, 0},
               kind: :parent,
               owner_id: 1
             }

      refute Enum.any?(repo3.edges, &(&1.from_sha == @b0))
    end
  end

  describe "build/2 — lanes (one row per agent)" do
    test "one lane per agent ordered by {depth, id} ascending; y is the lane index" do
      agents = [agent(2, nil, depth: 1), agent(1, nil, depth: 0), agent(3, nil, depth: 0)]

      [repo] = CommitGraph.build(%{}, agents)

      assert Enum.map(repo.lanes, & &1.agent_id) == [1, 3, 2]
      assert Enum.map(repo.lanes, & &1.y) == [0, 1, 2]
      assert Enum.map(repo.lanes, & &1.depth) == [0, 0, 1]
      assert repo.lane_count == 3
      assert repo.row_count == repo.lane_count
    end

    test "a lane exposes exactly its documented fields and values" do
      a =
        agent(1, nil,
          task_local_id: 7,
          status: :waiting,
          depth: 0,
          base_commit: @c1,
          current_commit: @c3
        )

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert [lane] = repo.lanes

      assert lane == %{
               agent_id: 1,
               task_local_id: 7,
               status: :waiting,
               depth: 0,
               color: @depth0_color,
               y: 0,
               x_start: 0,
               x_end: 2,
               node_count: 3,
               start_sha: @c1,
               end_sha: @c3,
               # A live agent (no `:ended` on its map) is never marked ended.
               ended: false
             }

      # A non-binary base/current renders nil (never the raw term).
      for {base, current} <- [{nil, nil}, {42, :tip}, {"", ""}] do
        bare = agent(1, nil, base_commit: base, current_commit: current)
        [empty] = CommitGraph.build(%{}, [bare])

        assert hd(empty.lanes).start_sha == nil
        assert hd(empty.lanes).end_sha == nil
      end
    end

    test "ended is true ONLY for an agent whose map carries :ended == true" do
      # A retained (ended) agent keeps its lane so its START/END markers survive
      # agent recycling.
      [retained] = CommitGraph.build(%{}, [agent(1, nil, ended: true)])

      assert [lane] = retained.lanes
      assert lane.ended == true

      # A live agent — key present but nil, or any non-`true` value — never is.
      for ended <- [nil, false, "yes", 1] do
        [view] = CommitGraph.build(%{}, [agent(2, nil, ended: ended)])

        assert hd(view.lanes).ended == false
      end

      # An agent map without the key at all is false too.
      [bare] = CommitGraph.build(%{}, [%{}])

      assert hd(bare.lanes).ended == false
    end

    test "x_start/x_end bound the owned nodes; a lane owning none has nil bounds" do
      agents = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c3)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

      # Both agents walk c2..c3, so the deepest lane wins every node…
      [shallow, deep] = repo.lanes

      assert deep.node_count == 3
      assert {deep.x_start, deep.x_end} == {0, 2}
      assert shallow.node_count == 0
      assert shallow.x_start == nil
      assert shallow.x_end == nil

      # …and when each lane walks its own range the bounds follow the owned rows.
      split = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @c2, current_commit: @c3)
      ]

      [repo2] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, split)

      for lane <- repo2.lanes do
        xs = for n <- repo2.nodes, n.y == lane.y, do: n.x

        assert xs != []
        assert lane.node_count == length(xs)
        assert lane.x_start == Enum.min(xs)
        assert lane.x_end == Enum.max(xs)
      end
    end

    test "an invalid depth normalizes to 0 (in the lane AND in the sort order)" do
      for depth <- [nil, -1, 1.5, "2", :three] do
        a = agent(1, nil, depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.lanes).depth == 0
      end

      agents = [agent(5, nil, depth: nil), agent(2, nil, depth: 0), agent(9, nil, depth: 3)]

      [repo] = CommitGraph.build(%{}, agents)

      assert Enum.map(repo.lanes, & &1.agent_id) == [2, 5, 9]
      assert Enum.map(repo.lanes, & &1.depth) == [0, 0, 3]
    end
  end

  describe "build/2 — node ownership" do
    test "a commit on more than one path belongs to the DEEPEST lane (ties: lowest index)" do
      agents = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c3)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

      # Agent 2 (depth 1) is the deeper lane, so it owns every shared commit.
      assert node(repo, @c3).y == 1
      assert node(repo, @c3).owner_id == 2
      assert node(repo, @c2).y == 1
      # @c1 is on no path (it is the exclusive fork point) -> it inherits @c2's lane.
      assert node(repo, @c1).y == 1

      # Equal depths tie-break on the SMALLEST lane index.
      ties = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 0, base_commit: @c1, current_commit: @c3)
      ]

      [tied] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, ties)

      assert node(tied, @c3).y == 0
      assert node(tied, @c3).owner_id == 1
    end

    test "a commit on NO path inherits the owner of its first-parent child (the deepest)" do
      # @p is the exclusive fork point of both agents, so neither walk collects it.
      commits = [commit(@y1, parents: [@p]), commit(@y2, parents: [@p]), commit(@p, parents: [])]

      shallow = agent(1, nil, depth: 0, base_commit: @p, current_commit: @y2)
      deep = agent(2, nil, depth: 1, base_commit: @p, current_commit: @y1)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [shallow, deep])

      # @p's first-parent children are owned by lanes 0 (@y2) and 1 (@y1); the deeper wins.
      assert node(repo, @p).y == 1
      assert node(repo, @p).owner_id == 2
    end

    test "an unowned commit with no owned child falls back to the FIRST lane" do
      # @orphan is a fetched root nobody points at (no first-parent child) and no
      # agent walks it, so no inheritance is available.
      commits = [
        commit(@orphan, parents: []),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      shallow = agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c2)
      deep = agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [shallow, deep])

      assert Enum.map(repo.lanes, & &1.agent_id) == [1, 2]

      assert node(repo, @orphan).y == 0
      assert node(repo, @orphan).owner_id == 1
      # @c1 is off both paths (exclusive fork point) -> it inherits @c2's deep lane.
      assert node(repo, @c1).y == 1
    end

    test "a synthesized base node belongs to the SHALLOWEST lane forked from it" do
      agents = [
        agent(1, nil, depth: 0, base_commit: @b0, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @b0, current_commit: @c3)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

      # Agent 1 (depth 0) is lane 0, so the shared fork point lands in the root lane…
      assert node(repo, @b0).kind == :base
      assert node(repo, @b0).y == 0
      assert node(repo, @b0).owner_id == 1

      # …while the real commits belong to the deeper lane.
      assert node(repo, @c3).y == 1

      [shallow, deep] = repo.lanes
      assert shallow.node_count == 1
      assert {shallow.x_start, shallow.x_end} == {-1, -1}
      assert deep.node_count == 3
    end
  end

  describe "build/2 — start_ids / end_ids" do
    test "start_ids / end_ids list the forking / tipping agents in lane order" do
      a1 = agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3)
      a2 = agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a1, a2])

      assert node(repo, @c1).start_ids == [1, 2]
      assert node(repo, @c1).end_ids == []
      assert node(repo, @c2).end_ids == [2]
      assert node(repo, @c3).end_ids == [1]
      assert node(repo, @c3).start_ids == []

      # A synthesized base node carries the start ids of the agents forked from it.
      b1 = agent(1, nil, depth: 0, base_commit: @b0, current_commit: @c2)
      b2 = agent(2, nil, depth: 1, base_commit: @b0, current_commit: @c2)

      [forked] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [b1, b2])

      assert node(forked, @b0).start_ids == [1, 2]
      assert node(forked, @b0).end_ids == []

      # A node can be a start for one agent and an end for another.
      x1 = agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3)
      x2 = agent(2, nil, depth: 1, base_commit: @c3, current_commit: @c4)

      [cross] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [x1, x2])

      assert node(cross, @c3).start_ids == [2]
      assert node(cross, @c3).end_ids == [1]
      # Agent 2 (the forking agent) tips one commit later.
      assert node(cross, @c4).end_ids == [2]
    end
  end

  describe "build/2 — progress path (first-parent walk)" do
    test "the walk follows FIRST parents only (a merge's folded parent is not walked)" do
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: []),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      # The shallow lane walks the side commit; the deep lane walks the merge's
      # first-parent line, so it must NOT collect @s1.
      shallow = agent(1, nil, depth: 0, base_commit: nil, current_commit: @s1)
      deep = agent(2, nil, depth: 1, base_commit: nil, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [shallow, deep])

      # If the merge's second parent were walked, the deeper lane would win @s1.
      assert node(repo, @s1).y == 0
      assert node(repo, @s1).owner_id == 1
      assert node(repo, @m).y == 1
      assert node(repo, @c3).y == 1
    end

    test "the walk excludes the agent's base_commit" do
      # c1 <- c2 <- c3 <- c4; the deep agent forks from c2, so its walk stops there.
      shallow = agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3)
      deep = agent(2, nil, depth: 1, base_commit: @c2, current_commit: @c3)

      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, [shallow, deep])

      # Both agents walk c3, so the deeper lane owns it.
      assert node(repo, @c3).y == 1
      # Only the shallow agent walks c2 (the deep agent's base is excluded)…
      assert node(repo, @c2).y == 0
      # …and @c1 is off every path, so it inherits from its child @c2.
      assert node(repo, @c1).y == 0
    end

    test "the walk stops at an unfetched sha, and a self-parent cannot loop" do
      commits = [
        commit(@c3, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        # @c1's parent was never fetched.
        commit(@c1, parents: [@b0])
      ]

      a = agent(1, nil, base_commit: nil, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      # The path is c3 -> c2 -> c1; @b0 is neither a node nor an edge target.
      assert node_shas(repo) |> Enum.sort() == [@c1, @c2, @c3]
      refute @b0 in node_shas(repo)
      assert repo.edge_count == 2

      [lane] = repo.lanes
      assert lane.node_count == 3
      assert {lane.x_start, lane.x_end} == {0, 2}

      # A self-parenting commit is collected once, then the seen guard stops the walk.
      selfy = agent(1, nil, base_commit: nil, current_commit: @cyc_a)

      [loop] =
        CommitGraph.build(%{"primary" => raw([commit(@cyc_a, parents: [@cyc_a])])}, [selfy])

      assert loop.node_count == 1
      # The cycle rank is 1 + rank(self), and the visiting guard resolves self to 0.
      assert node(loop, @cyc_a).x == 1
      assert hd(loop.lanes).node_count == 1
    end
  end

  describe "build/2 — depth → hue colors" do
    test "each depth maps to its EXACT documented hue; invalid depths fold to 0" do
      for {depth, expected} <- [
            {0, @depth0_color},
            {1, @depth1_color},
            {2, @depth2_color},
            {3, @depth3_color},
            {5, @depth5_color},
            # Non-integer, nil and negative depths all fold to the depth-0 hue.
            {nil, @depth0_color},
            {-1, @depth0_color},
            {1.5, @depth0_color},
            {"2", @depth0_color},
            {:three, @depth0_color}
          ] do
        a = agent(1, nil, depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.lanes).color == expected
      end
    end
  end

  describe "build/2 — determinism" do
    test "lists are sorted by their documented keys and repeat builds are identical" do
      commits = [
        commit(@m, parents: [@c3, @s1]),
        commit(@c3, parents: [@c2]),
        commit(@s1, parents: [@c2]),
        commit(@c2, parents: [@c1]),
        commit(@c1, parents: [])
      ]

      a1 = agent(1, nil, depth: 0, base_commit: @b0, current_commit: @m)
      a2 = agent(2, nil, depth: 1, base_commit: @other_base, current_commit: @s1)

      raw_by_repo = %{"primary" => raw(commits, %{@c3 => ["main"]})}
      [repo] = CommitGraph.build(raw_by_repo, [a1, a2])

      assert repo.nodes == Enum.sort_by(repo.nodes, &{&1.x, &1.y, &1.sha})
      assert repo.edges == Enum.sort_by(repo.edges, &{&1.from_sha, &1.to_sha})
      assert repo.lanes == Enum.sort_by(repo.lanes, &{&1.depth, &1.agent_id})

      # The agent input order never changes the view model.
      assert CommitGraph.build(raw_by_repo, [a2, a1]) == [repo]
    end
  end

  describe "build/2 — defensive handling" do
    test "an absent repo key (or a non-map raw_by_repo) yields a well-formed EMPTY graph" do
      # No base_commit, so there is nothing to synthesize either.
      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      for raw_by_repo <- [%{}, "garbage", nil, 42, [:a]] do
        [repo] = CommitGraph.build(raw_by_repo, [a])

        assert repo.nodes == []
        assert repo.edges == []
        assert repo.node_count == 0
        assert repo.edge_count == 0
        assert repo.max_x == 0
        assert repo.lane_count == 1
        assert repo.row_count == 1

        [lane] = repo.lanes
        assert lane.node_count == 0
        assert lane.x_start == nil
        assert lane.x_end == nil
      end

      # A base_commit is still synthesized when nothing at all was fetched.
      fork = agent(1, nil, base_commit: @b0, current_commit: @c2)
      [base_only] = CommitGraph.build(%{}, [fork])

      assert node_shas(base_only) == [@b0]
      assert node(base_only, @b0).x == -1
      assert base_only.max_x == -1
      assert base_only.edge_count == 0
    end

    test "a malformed repo graph or commit entry degrades to an empty graph" do
      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      bad_graphs = [
        "garbage",
        %{},
        %{commits: "nope"},
        %{commits: nil},
        # Non-map entries are filtered out of the commit list.
        %{commits: [nil, :not_a_map, "a string"]},
        # A commits value that is not a list degrades to none.
        %{commits: %{}},
        # Commits without a usable :sha are not addressable either.
        %{commits: [%{message: "no sha"}, %{sha: nil}, %{sha: ""}, %{sha: 42}]}
      ]

      for graph <- bad_graphs do
        [repo] = CommitGraph.build(%{"primary" => graph}, [a])

        assert repo.nodes == []
        assert repo.node_count == 0
      end
    end

    test "a single agent map is accepted; a non-binary repo key is still addressable" do
      [repo] =
        CommitGraph.build(
          %{"primary" => raw(chain([@c1, @c2]))},
          %{id: 1, repo_id: "primary", base_commit: @c1, current_commit: @c2}
        )

      assert repo.lane_count == 1
      assert hd(repo.lanes).agent_id == 1
      assert repo.node_count == 2

      [other] = CommitGraph.build(%{123 => %{}}, [%{id: 1, repo_id: 123}])

      assert other.repo_key == 123
      assert other.repo_name == "Unknown Repo"
      assert other.repo_dom_id =~ ~r/^commit-graph-repo-123-\d+$/
    end

    test "an agent map missing every read key still yields a well-formed repo view" do
      [repo] = CommitGraph.build(%{}, [%{}])

      assert repo.repo_key == nil
      # A nil key renders the primary label.
      assert repo.repo_name == "Primary Repo"
      assert repo.nodes == []
      assert repo.max_x == 0
      assert repo.lane_count == 1

      assert [lane] = repo.lanes

      assert lane == %{
               agent_id: nil,
               task_local_id: nil,
               status: nil,
               depth: 0,
               color: @depth0_color,
               y: 0,
               x_start: nil,
               x_end: nil,
               node_count: 0,
               start_sha: nil,
               end_sha: nil,
               ended: false
             }
    end

    test "struct-shaped commits are map-like and their missing parents degrade safely" do
      struct_commit = %EvoGit.Review.CommitInfo{
        sha: @c2,
        short_sha: "abcdef12",
        message: "struct subject\nbody text",
        author_name: "Ada",
        date: nil
      }

      commits = [commit(@c3, parents: [@c2]), struct_commit]
      a = agent(1, nil, base_commit: nil, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      # A struct carries no :parents key -> treated as a root commit (rank 0).
      assert [c2, c3] = repo.nodes
      assert c2.sha == @c2
      assert c2.short_sha == "abcdef12"
      assert c2.message == "struct subject"
      assert c2.author_name == "Ada"
      assert c2.x == 0
      assert c3.x == 1
    end
  end

  # --- fixtures -------------------------------------------------------------

  # An agent map carrying the keys the graph assembler reads, defaulted for the
  # ones a test does not care about (repo_id defaults to the primary group).
  defp agent(id, parent_id, opts \\ []) do
    %{
      id: id,
      parent_id: parent_id,
      repo_root: Keyword.get(opts, :repo_root),
      repo_id: Keyword.get(opts, :repo_id, "primary"),
      depth: Keyword.get(opts, :depth, 0),
      task_local_id: Keyword.get(opts, :task_local_id),
      status: Keyword.get(opts, :status, :running),
      base_commit: Keyword.get(opts, :base_commit),
      current_commit: Keyword.get(opts, :current_commit),
      ended: Keyword.get(opts, :ended)
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
  # Built oldest-first for readability and reversed before returning, because a
  # real fetch comes back in `git log` order.
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

  defp node(repo, sha), do: Enum.find(repo.nodes, &(&1.sha == sha))

  defp edge(repo, from_sha, to_sha) do
    Enum.find(repo.edges, &(&1.from_sha == from_sha and &1.to_sha == to_sha))
  end

  # The node shas in the module's documented `{x, y, sha}` order.
  defp node_shas(repo), do: Enum.map(repo.nodes, & &1.sha)

  # A view's key set, sorted (so an assertion reads as the documented key list).
  defp keys(view), do: view |> Map.keys() |> Enum.sort()
end
