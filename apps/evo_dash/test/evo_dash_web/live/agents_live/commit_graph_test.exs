defmodule EvoDashWeb.AgentsLive.CommitGraphTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.CommitGraph — the assembler behind
  the Agents page TEMPORAL (git commit history) view, rendered as a VERTICAL,
  commit-centric DAG: ONE VISIBLE ROW per commit, GLOBALLY interleaved across
  agents (sorted by topological layer, then date, then sha), ONE LANE PER AGENT
  in the left gutter (plus a NEUTRAL lane 0 for unowned commits when any
  exist), commit → parent edges plus the agent-level `:spawn` / `:merge_back`
  edges between the rows.

  These are pure data transformations over plain maps — no LiveView, socket,
  repo I/O, or app-env seam. Every fixture is hand-crafted, so each assertion
  traces back to a rule documented on the module: node synthesis (fetched
  commits + one `kind: :base` node per uncovered agent `base_commit` + one
  `kind: :noop` stub per no-op child), the global row order
  (`{layer, date_unix, sha}`), the per-agent lane assignment (the agent's
  index in the DFS SUBTREE-CONTIGUOUS order — pre-order from the roots,
  children visited recursively in stable `{task_local_id, agent_id}` order,
  cycle-safe with fallback roots — shifted right by one when unowned nodes
  exist), ownership and the
  first-parent progress path, the `:parent` / `:merge` / `:spawn` /
  `:merge_back` edges (incl. the drop rule and virtual landings), the
  `start_ids` / `end_ids` annotations, the vertical `agents` list (that same
  DFS order) and the depth → hue colors.
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

  # Fork fixtures: a root lane @r1 <- @r2, two parallel children @u1 <- @u2
  # (child-a) and @v1 <- @v2 (child-b); a fast-forward family
  # @p1 <- @p2 <- @k1 <- @k2 <- @p3 (the child @k1/@k2, the root continuing
  # with @p3 whose parent is the child tip); and @mv the real merge of @p2 and
  # @k2.
  @r1 "r1000000"
  @r2 "r2000000"
  @u1 "u1000000"
  @u2 "u2000000"
  @v1 "v1000000"
  @v2 "v2000000"
  @p1 "p1000000"
  @p2 "p2000000"
  @p3 "p3000000"
  @p4 "p4000000"
  @k1 "k1000000"
  @k2 "k2000000"
  @mv "mv000000"

  # Exact depth→hue pins: hue = Integer.mod(round(depth * 137.508) + 265, 360),
  # then ThemeColor.hsl_to_hex(hue, 70, 54) — the documented formula.
  @depth0_color "#7c38dc"
  @depth1_color "#dcad38"
  @depth2_color "#38dcdc"
  @depth3_color "#dc38ab"
  @depth5_color "#384bdc"

  describe "grouping_key/1" do
    test "prefers repo_root (an absolute path), then repo_id, else nil" do
      for {input, expected} <- [
            {%{repo_root: "/home/dev/repo", repo_id: "primary"}, "/home/dev/repo"},
            {%{repo_id: "foreign-1"}, "foreign-1"},
            {%{repo_root: nil, repo_id: "primary"}, "primary"},
            # Absent repo fields yield nil (a single unnamed group).
            {%{}, nil},
            {%{id: 1}, nil}
          ] do
        assert CommitGraph.grouping_key(input) == expected
      end
    end
  end

  describe "repo_display_name/1" do
    # Tests run in the default :en locale, so the msgids themselves are asserted.
    test "primary keys and path basenames, else \"Repo: <key>\" / \"Unknown Repo\"" do
      for {input, expected} <- [
            {"primary", "Primary Repo"},
            {:primary, "Primary Repo"},
            {nil, "Primary Repo"},
            {"/home/dev/my-repo", "my-repo"},
            # Forward slashes are separators on every host, so this is OS-independent.
            {"C:/Users/dev/proj", "proj"},
            {"//server/share/proj", "proj"},
            {"foreign-repo-1", "Repo: foreign-repo-1"},
            {"repo_root", "Repo: repo_root"},
            {42, "Unknown Repo"},
            {{:a, 1}, "Unknown Repo"},
            {:other, "Unknown Repo"}
          ] do
        assert CommitGraph.repo_display_name(input) == expected
      end

      # Backslash separators only split on Windows, so derive the expectation with
      # the same host-OS Path.basename/1 the module uses (proves the ABSOLUTE branch
      # was taken rather than the "Repo: <key>" fallback).
      windows_path = "C:\\Users\\dev\\proj"
      assert CommitGraph.repo_display_name(windows_path) == Path.basename(windows_path)
    end
  end

  describe "build/2 — repo grouping and sorting" do
    test "one repo_view per grouping key, each fed ONLY its own graph and agents" do
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

      # Each view carries only its own graph's nodes and only its own agents.
      assert node_shas(alpha) |> Enum.sort() == [@c1, @c2]
      assert node_shas(primary) |> Enum.sort() == [@c1, @c2, @c3]
      assert Enum.map(alpha.agents, & &1.agent_id) == [1, 2]
      assert Enum.map(primary.agents, & &1.agent_id) == [3]
    end

    test "repos are sorted by display name (ties: repo_dom_id), input order irrelevant" do
      views =
        CommitGraph.build(%{}, [
          agent(1, nil, repo_root: "/r/zulu"),
          agent(2, nil, repo_root: "/r/alpha"),
          agent(3, nil, repo_root: "/r/mike")
        ])

      assert Enum.map(views, & &1.repo_name) == ["alpha", "mike", "zulu"]

      a = agent(1, nil, repo_root: "/one/proj")
      b = agent(2, nil, repo_root: "/two/proj")

      forward = CommitGraph.build(%{}, [a, b])
      backward = CommitGraph.build(%{}, [b, a])

      # Both keys display "proj", so the documented tie-break (repo_dom_id) decides.
      assert Enum.map(forward, & &1.repo_name) == ["proj", "proj"]
      assert forward == Enum.sort_by(forward, & &1.repo_dom_id)
      assert Enum.map(forward, & &1.repo_dom_id) == Enum.map(backward, & &1.repo_dom_id)
    end

    test "repo_dom_id is deterministic and DOM-safe; same-slug keys stay distinct" do
      [first] = CommitGraph.build(%{}, [agent(1, nil)])
      [second] = CommitGraph.build(%{}, [agent(1, nil)])

      assert first.repo_dom_id == second.repo_dom_id
      assert first.repo_dom_id =~ ~r/^commit-graph-repo-[A-Za-z0-9_-]+-\d+$/

      # Both keys sanitize to "a-x-y", but the phash2 suffix disambiguates them.
      [with_space] = CommitGraph.build(%{}, [agent(1, nil, repo_root: "/a/x y")])
      [with_slash] = CommitGraph.build(%{}, [agent(2, nil, repo_root: "/a/x/y")])

      assert with_space.repo_dom_id != with_slash.repo_dom_id
    end

    test "a nil or empty agents list produces NO repo views (repos are derived from agents)" do
      assert CommitGraph.build(%{"primary" => %{}}, nil) == []
      assert CommitGraph.build(%{}, []) == []
    end
  end

  describe "build/2 — output shape and counts" do
    test "a repo_view exposes exactly its documented keys, counts and column_count" do
      a = agent(1, nil, base_commit: @b0, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      # The exact key sets also prove the retired horizontal keys (:x/:y/:from/:to/
      # :lanes/:lane_count/:max_x) are gone from every level of the view.
      assert keys(repo) ==
               ~w(agents column_count edge_count edges node_count nodes repo_dom_id repo_key repo_name row_count truncated)a

      assert [node | _] = repo.nodes

      assert keys(node) ==
               ~w(author_name column date depth end_ids kind message owner_id refs row sha short_sha start_ids)a

      assert [edge | _] = repo.edges

      assert keys(edge) ==
               ~w(from_column from_row from_sha kind owner_id to_column to_row to_sha)a

      assert [entry] = repo.agents

      assert keys(entry) ==
               ~w(agent_id color depth end_sha ended lane parent_id start_sha status task_local_id)a

      # The counts agree with the lists; row_count mirrors node_count and the
      # gutter covers the widest lane in use (one agent owns lane 0, nothing unowned).
      assert repo.node_count == length(repo.nodes)
      assert repo.edge_count == length(repo.edges)
      assert repo.row_count == repo.node_count
      assert repo.column_count == (repo.nodes |> Enum.map(& &1.column) |> Enum.max()) + 1
      assert repo.column_count == 1
      assert hd(repo.agents).lane == 0
    end

    test "the raw repo map's truncated flag surfaces on the repo_view (absent → false)" do
      a = agent(1, nil, base_commit: @b0, current_commit: @c3)
      b = agent(2, nil, repo_root: "/r/other", base_commit: @b0, current_commit: @c3)

      raw_by_repo = %{
        "primary" => %{commits: chain([@c1, @c2, @c3]), refs: %{}, truncated: true},
        "/r/other" => %{commits: chain([@c1, @c2, @c3]), refs: %{}}
      }

      views = CommitGraph.build(raw_by_repo, [a, b])

      # The flag rides along verbatim from the raw map; an absent key reads as false.
      assert repo_by_key(views, "primary").truncated == true
      assert repo_by_key(views, "/r/other").truncated == false
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
      assert Enum.all?(repo.nodes, &(&1.kind == :commit))
      # Layer order oldest → newest (c1 is the root, each child one deeper).
      assert node_shas(repo) == [@c1, @c2, @c3]
    end

    test "a base_commit covered by the fetch is NOT synthesized; an uncovered one is" do
      # Two agents in ONE repo: agent 1 forks from a sha the fetch covers, agent
      # 2 from a fork point the fetch does not — only the latter gets a node.
      covered = agent(1, nil, base_commit: @c1, current_commit: @c3)
      uncovered = agent(2, nil, base_commit: @b0, current_commit: @c3)

      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [covered, uncovered])

      # 3 fetched commits + exactly 1 synthesized base.
      assert repo.node_count == 4
      assert Enum.count(repo.nodes, &(&1.kind == :commit)) == 3
      # The covered fork sha appears exactly ONCE, as a normal :commit node.
      assert Enum.count(repo.nodes, &(&1.sha == @c1)) == 1
      assert node(repo, @c1).kind == :commit
      # The only synthesized base is the uncovered fork point.
      assert for(n <- repo.nodes, n.kind == :base, do: n.sha) == [@b0]
    end

    test "a distinct agent base_commit absent from the fetch is synthesized as a :base node" do
      # @c1 LISTS the fork as its parent, so the synthesized base anchors the
      # chain from below.
      a = agent(1, nil, base_commit: @b0, current_commit: @c2)
      commits = [commit(@c2, parents: [@c1]), commit(@c1, parents: [@b0])]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.node_count == 3
      # A base node carries no metadata of its own — only the fork shas. Its layer
      # is 0 (a parentless pseudo commit) and @c1 builds on it, so it sits on top.
      assert node(repo, @b0) == node_row(@b0, kind: :base, owner_id: 1, start_ids: [1])

      # …while the real commits stay untouched, one row below the fork point.
      assert node(repo, @c1).kind == :commit
      assert node(repo, @c1).row == 1
      assert node_shas(repo) == [@b0, @c1, @c2]
    end

    test "each distinct base gets its own node; long/garbage base shas are handled" do
      agents = [
        agent(1, nil, base_commit: @b0, current_commit: @c2),
        agent(2, nil, base_commit: @other_base, current_commit: @c2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, agents)

      assert Enum.sort(for n <- repo.nodes, n.kind == :base, do: n.sha) == [@b0, @other_base]
      assert repo.node_count == 4

      # A base sha longer than 8 characters is sliced for its short form.
      long = agent(1, nil, base_commit: "1234567890", current_commit: @c2)
      [long_repo] = CommitGraph.build(%{"primary" => raw([])}, [long])

      assert {node(long_repo, "1234567890").short_sha, node(long_repo, "1234567890").row} ==
               {"12345678", 0}

      # A non-binary / blank base is not a fork point at all.
      for base <- [nil, "", 42, :base] do
        short = agent(1, nil, base_commit: base, current_commit: @c2)
        [repo2] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [short])

        assert Enum.all?(repo2.nodes, &(&1.kind == :commit))
        assert repo2.node_count == 2
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
      assert for(sha <- [@c1, @c3, @c4], do: node(repo, sha).short_sha) == [@c1, @c3, @c4]

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

      assert {node(repo, @c2).message, node(repo, @c2).author_name, node(repo, @c2).date} ==
               {"subject line", "Ada", date}

      # A non-binary message/author/date degrades to "" / nil.
      assert {node(repo, @c3).message, node(repo, @c3).author_name, node(repo, @c3).date} ==
               {"", nil, nil}

      assert node(repo, @c1).message == ""
    end

    test "refs come from raw.refs; a missing, non-map or non-list entry renders []" do
      commits = chain([@c1, @c2, @c3, @c4])
      refs = %{@c3 => ["HEAD", "main"], @c2 => "not-a-list"}
      a = agent(1, nil, base_commit: @c1, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits, refs)}, [a])

      assert node(repo, @c3).refs == ["HEAD", "main"]
      assert {node(repo, @c2).refs, node(repo, @c4).refs} == {[], []}

      # A non-map refs value degrades to [] everywhere.
      [repo2] = CommitGraph.build(%{"primary" => %{commits: commits, refs: "nope"}}, [a])

      assert Enum.all?(repo2.nodes, &(&1.refs == []))
    end
  end

  describe "build/2 — rows (the global interleaved order)" do
    test "parallel agents INTERLEAVE by date inside a layer, not per-agent blocks" do
      # Both children's first commits share layer 2 and their second commits share
      # layer 3, so the DATES decide the order inside each layer — the rows
      # alternate between the agents' lanes instead of stacking.
      [repo] = CommitGraph.build(%{"primary" => raw(fork_commits())}, fork_agents())

      assert rows(repo) == [
               {@r1, 0, 0},
               {@r2, 1, 0},
               {@v1, 2, 2},
               {@u1, 3, 1},
               {@v2, 4, 2},
               {@u2, 5, 1}
             ]

      assert Enum.map(repo.nodes, & &1.owner_id) ==
               ["root", "root", "child-b", "child-a", "child-b", "child-a"]
    end

    test "parents sit STRICTLY above children (the layer grows along every edge)" do
      commits = graph([{@u2, [@u1]}, {@u1, [@r2]}, {@r2, [@r1]}, {@r1, []}])

      root = agent("root", nil, depth: 0, base_commit: nil, current_commit: @r2)
      child = agent("child", "root", depth: 1, base_commit: @r2, current_commit: @u2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [root, child])

      row_by_sha = Map.new(repo.nodes, &{&1.sha, &1.row})

      for node <- repo.nodes, parent_sha <- parent_shas(commits, node.sha) do
        assert Map.fetch!(row_by_sha, parent_sha) < node.row
      end

      assert node_shas(repo) == [@r1, @r2, @u1, @u2]
    end

    test "the global order follows LAYERS, not the fetch order" do
      # The fetched list is deliberately scrambled; the parent links decide the order.
      scrambled = graph([{@c3, [@c2]}, {@c1, []}, {@c4, [@c3]}, {@c2, [@c1]}])

      a = agent(1, nil, base_commit: nil, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(scrambled)}, [a])

      assert node_shas(repo) == [@c1, @c2, @c3, @c4]
      assert Enum.map(repo.nodes, & &1.row) == [0, 1, 2, 3]

      # The same graph in the opposite input order yields the same nodes.
      [bwd] = CommitGraph.build(%{"primary" => raw(Enum.reverse(scrambled))}, [a])
      assert bwd.nodes == repo.nodes
    end

    test "layer is 1 + MAX(present parent layer), not 1 + parent count" do
      # @m merges two layer-0 roots (layer 1) and @c4 builds on @m (layer 2).
      commits = graph([{@c4, [@m]}, {@m, [@c1, @s1]}, {@s1, []}, {@c1, []}])

      a = agent(1, nil, base_commit: nil, current_commit: @c4)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert {node(repo, @m).row, node(repo, @c4).row} == {2, 3}
      # The two layer-0 roots tie, broken by sha ascending.
      assert {node(repo, @c1).row, node(repo, @s1).row} == {0, 1}

      # @s1 is on nobody's path and no commit lists it as a FIRST parent, so it is
      # UNOWNED: it takes the neutral lane 0 and the agent shifts right.
      assert node(repo, @s1).owner_id == nil

      assert {node(repo, @s1).column, hd(repo.agents).lane, node(repo, @c1).column} == {0, 1, 1}
    end

    test "an unfetched parent contributes no layer (the commit still layers as a root)" do
      # @c1 lists the ABSENT @b0 as a parent: it is still a layer-0 root, so both
      # layer-0 commits tie and the sha breaks the tie.
      commits = graph([{@c2, []}, {@c1, [@b0]}])

      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert node_shas(repo) == [@c1, @c2]
    end

    test "a layer tie breaks on date first, then sha" do
      # Two unrelated roots (both layer 0): the later-dated one sits below the
      # earlier one regardless of the sha order.
      commits = [
        commit(@c2, parents: [], date: ~U[2026-01-01 09:00:00Z]),
        commit(@c1, parents: [], date: ~U[2026-01-01 10:00:00Z])
      ]

      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert node_shas(repo) == [@c2, @c1]

      # Without dates the shas decide (@c1 < @c2 as binaries).
      [repo2] = CommitGraph.build(%{"primary" => raw(graph([{@c2, []}, {@c1, []}]))}, [a])

      assert node_shas(repo2) == [@c1, @c2]
    end

    test "a malformed parent CYCLE terminates deterministically" do
      # @cyc_a and @cyc_b are parents of each other — the memoized layer walk must
      # break the recursion instead of looping forever: the `visiting` set folds the
      # back edge to layer 0, so the pair layers 1 and 2 (the older sits on top).
      commits = graph([{@cyc_a, [@cyc_b]}, {@cyc_b, [@cyc_a]}])

      a = agent(1, nil, base_commit: nil, current_commit: @cyc_a)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert {repo.node_count, node_shas(repo), Enum.map(repo.nodes, & &1.row)} ==
               {2, [@cyc_b, @cyc_a], [0, 1]}

      # Same input -> same result (the layer memo is deterministic).
      assert CommitGraph.build(%{"primary" => raw(commits)}, [a]) == [repo]
    end
  end

  describe "build/2 — lanes (one per agent)" do
    test "an agent's lane is its DFS index, not its depth; nodes sit in their lane" do
      # Two agents at very different depths own disjoint commits: their lanes are
      # simply 0 and 1 (the old depth-staircase would use columns 0 and 5).
      agents = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c2),
        agent(2, nil, depth: 5, base_commit: @c2, current_commit: @c3)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

      assert Enum.map(repo.agents, &{&1.agent_id, &1.depth, &1.lane}) == [{1, 0, 0}, {2, 5, 1}]

      assert Enum.map(repo.nodes, &{&1.sha, &1.column, &1.depth}) ==
               [{@c1, 0, 0}, {@c2, 0, 0}, {@c3, 1, 5}]

      # The gutter counts LANES, not depths: 2 lanes.
      assert repo.column_count == 2

      # Three chained agents (the DFS subtree-contiguous order: all roots here, so
      # agent_id breaks every tie) get lanes 0..2 and every node keeps its owner's lane.
      [three] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, chained_agents())

      assert Enum.map(three.agents, & &1.lane) == [0, 1, 2]

      assert Enum.map(three.nodes, &{&1.sha, &1.row, &1.column, &1.depth, &1.owner_id}) ==
               [{@c1, 0, 0, 0, 1}, {@c2, 1, 0, 0, 1}, {@c3, 2, 1, 1, 2}, {@c4, 3, 2, 2, 3}]

      assert three.column_count == 3
    end

    test "a parent's subtree occupies CONSECUTIVE lanes (two-subtree contiguity)" do
      # Two independent subtrees: a (slot 1) -> a1 (slot 3), b (slot 2) -> b1
      # (slot 4). The DFS visits the roots in stable {task_local_id, agent_id}
      # order — a, then b — and each root's children BEFORE the next root, so
      # children of different parents never interleave across the gutter.
      views =
        CommitGraph.build(%{}, [
          agent("b", nil, task_local_id: 2),
          agent("b1", "b", task_local_id: 4),
          agent("a", nil, task_local_id: 1),
          agent("a1", "a", task_local_id: 3)
        ])

      assert [repo] = views

      assert Enum.map(repo.agents, &{&1.agent_id, &1.lane}) ==
               [{"a", 0}, {"a1", 1}, {"b", 2}, {"b1", 3}]

      # Subtree a's lanes sit strictly left of subtree b's — the input order of
      # the agent list is irrelevant.
      a_lanes = for a <- repo.agents, a.agent_id in ["a", "a1"], do: a.lane
      b_lanes = for a <- repo.agents, a.agent_id in ["b", "b1"], do: a.lane

      assert Enum.max(a_lanes) < Enum.min(b_lanes)
    end

    test "a parent CYCLE cannot loop the walk; an unresolvable parent anchors a ROOT" do
      # x and y point at each other, so neither is a root and no DFS start reaches
      # them — both are appended as fallback roots in the stable {task_local_id,
      # agent_id} order (nil slots, so the ids break the tie), exactly one lane each.
      x = agent("x", "y")
      y = agent("y", "x")

      [repo] = CommitGraph.build(%{}, [y, x])

      assert Enum.map(repo.agents, &{&1.agent_id, &1.lane}) == [{"x", 0}, {"y", 1}]

      # A parent_id matching no agent of THIS repo group strands the child as its
      # own ROOT (the DFS visits it before the fallback roots append).
      [three] = CommitGraph.build(%{}, [y, agent("z", "ghost"), x])

      assert Enum.map(three.agents, &{&1.agent_id, &1.lane}) == [{"z", 0}, {"x", 1}, {"y", 2}]
    end

    test "column_count covers agent lanes that own NO node (their header chip renders)" do
      # Agents 2 and 3 own nothing (no commits, no stub — no parent agent), but
      # their lanes still count.
      agents = [agent(1, nil, current_commit: @c2), agent(2, nil), agent(3, nil)]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, agents)

      assert Enum.map(repo.agents, & &1.lane) == [0, 1, 2]
      assert Enum.map(repo.nodes, & &1.column) == [0, 0]
      assert repo.column_count == 3
    end

    test "unowned commits take the NEUTRAL lane 0 and every agent lane shifts right" do
      # @orphan is a fetched root nobody walks and no commit lists as a first
      # parent, so no agent claims it — it goes to the neutral lane while the
      # agents shift right by one.
      commits = graph([{@orphan, []}, {@c2, [@c1]}, {@c1, []}])

      shallow = agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c2)
      deep = agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c2)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [shallow, deep])

      assert {node(repo, @orphan).owner_id, node(repo, @orphan).column} == {nil, 0}
      assert {node(repo, @orphan).depth, node(repo, @orphan).row} == {0, 1}
      # The agents sit one lane right of their unshifted indexes.
      assert Enum.map(repo.agents, &{&1.agent_id, &1.lane}) == [{1, 1}, {2, 2}]
      assert {node(repo, @c1).column, node(repo, @c2).column} == {2, 2}
      # @c1 is off both paths (the exclusive fork point) -> it inherits @c2's deeper owner.
      assert node(repo, @c1).owner_id == 2
      assert repo.column_count == 3
    end

    test "column_count is 1 when the repo has no nodes" do
      [repo] = CommitGraph.build(%{}, [agent(1, nil)])

      assert repo.nodes == []
      assert repo.column_count == 1
    end
  end

  describe "build/2 — edges (commit → parent)" do
    test "one :parent edge per present parent, with the nodes' row/lane coordinates" do
      a = agent(1, nil, base_commit: @c1, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert repo.edge_count == 2
      assert edge_t(edge(repo, @c3, @c2)) == {@c3, @c2, :parent, 0, 2, 0, 1, 1}
      assert edge_t(edge(repo, @c2, @c1)) == {@c2, @c1, :parent, 0, 1, 0, 0, 1}
      # Commit edges are sorted by {from_sha, to_sha}.
      assert edge_list(repo) == [{:parent, @c2, @c1}, {:parent, @c3, @c2}]
    end

    test "a folded side branch produces :merge; the first present parent stays :parent" do
      commits = graph([{@m, [@c3, @s1]}, {@c3, [@c2]}, {@s1, [@c2]}, {@c2, [@c1]}, {@c1, []}])

      a = agent(1, nil, base_commit: nil, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      assert repo.edge_count == 5
      # The merge edge keeps the child's owner and both endpoints' row/lane. @s1 is
      # unowned (nobody walks it, no first-parent child), so it sits in the neutral
      # lane 0 while the owned nodes shift to lane 1.
      assert edge_t(edge(repo, @m, @s1)) == {@m, @s1, :merge, 1, 4, 0, 3, 1}

      # @m's first parent @c3 stays :parent, as do the folded branch's own edges.
      assert edge_list(repo) == [
               {:parent, @c2, @c1},
               {:parent, @c3, @c2},
               {:parent, @m, @c3},
               {:merge, @m, @s1},
               {:parent, @s1, @c2}
             ]

      assert node_shas(repo) == [@c1, @c2, @c3, @s1, @m]
    end

    test "an absent parent produces no edge, and the first PRESENT parent is :parent" do
      commits = graph([{@m, [@b0, @c2, @s1]}, {@c2, []}, {@s1, []}])

      a = agent(1, nil, base_commit: nil, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [a])

      # @b0 is neither fetched nor an agent fork point -> not a node, no edge.
      refute @b0 in node_shas(repo)
      refute Enum.any?(repo.edges, &(&1.to_sha == @b0))

      # @c2 is the first PRESENT parent -> :parent; @s1 is the folded side branch.
      assert repo.edge_count == 2
      assert edge_list(repo) == [{:parent, @m, @c2}, {:merge, @m, @s1}]
    end

    test "edges are de-duplicated and a base node is an edge TARGET only" do
      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      dup_commits = graph([{@c2, [@c1]}, {@c2, [@c1]}, {@c1, []}])
      [repo] = CommitGraph.build(%{"primary" => raw(dup_commits)}, [a])

      assert repo.edge_count == 1
      assert edge_list(repo) == [{:parent, @c2, @c1}]

      dup_parents = graph([{@c2, [@c1, @c1]}, {@c1, []}])
      [repo2] = CommitGraph.build(%{"primary" => raw(dup_parents)}, [a])

      assert repo2.edge_count == 1

      # A synthesized base node has no parents, so it is only ever an edge target.
      b = agent(1, nil, base_commit: @b0, current_commit: @c2)
      fork = graph([{@c2, [@c1]}, {@c1, [@b0]}])
      [repo3] = CommitGraph.build(%{"primary" => raw(fork)}, [b])

      assert edge_t(edge(repo3, @c1, @b0)) == {@c1, @b0, :parent, 0, 1, 0, 0, 1}
      refute Enum.any?(repo3.edges, &(&1.from_sha == @b0))
    end

    test "edge endpoints span the lanes of the child and the parent" do
      # Parentless agents (no :spawn replacement), so the plain :parent edges
      # survive between the lanes.
      [repo] =
        CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, chained_agents())

      assert edge_t(edge(repo, @c3, @c2)) == {@c3, @c2, :parent, 1, 2, 0, 1, 2}
      assert edge_t(edge(repo, @c4, @c3)) == {@c4, @c3, :parent, 2, 3, 1, 2, 3}
    end
  end

  describe "build/2 — agent-level edges (:spawn / :merge_back)" do
    test "a :spawn branches from the fork into the child's OLDEST path commit" do
      # Root: base nil, tip @c2. Child: forked at @c2, built @c3 <- @c4.
      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @c2),
        agent(2, 1, depth: 1, base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      assert edge_t(edge(repo, @c2, @c3)) == {@c2, @c3, :spawn, 0, 1, 1, 2, 2}

      # The child's oldest → fork :parent edge is REPLACED by the spawn (drop
      # rule: same unordered sha pair).
      refute edge(repo, @c3, @c2)

      # The remaining commit edges plus the agent-level ones.
      assert edge_list(repo) == [
               {:parent, @c2, @c1},
               {:parent, @c4, @c3},
               {:merge_back, @c4, nil},
               {:spawn, @c2, @c3}
             ]

      assert repo.edge_count == 4
    end

    test "a fast-forward continuation lands the :merge_back on the parent's next node" do
      # The root continues AFTER the child: @p3's parent is the child tip @k2 (a
      # fast-forward). The merge_back returns from @k2 onto @p3.
      commits = graph([{@p3, [@k2]}, {@k2, [@k1]}, {@k1, [@p2]}, {@p2, [@p1]}, {@p1, []}])

      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @p3),
        agent(2, 1, depth: 1, base_commit: @p2, current_commit: @k2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      assert edge_t(edge(repo, @k2, @p3)) == {@k2, @p3, :merge_back, 1, 3, 0, 4, 2}

      # The continuation → tip :parent edge yields to the merge_back…
      refute edge(repo, @p3, @k2)
      # …and the child's oldest → fork :parent edge yields to the spawn.
      refute edge(repo, @k1, @p2)

      assert edge_list(repo) == [
               {:parent, @k2, @k1},
               {:parent, @p2, @p1},
               {:merge_back, @k2, @p3},
               {:spawn, @p2, @k1}
             ]

      assert repo.edge_count == 4
    end

    test "a merge_back with nothing below in the parent lane lands on a VIRTUAL node" do
      # The root never continues below the child, so the child's return has no
      # parent-lane node to land on: to_sha is nil and the column/row fields are
      # authoritative (the parent's lane at the source's own row).
      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @c2),
        agent(2, 1, depth: 1, base_commit: @c2, current_commit: @c4)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, agents)

      assert edge_t(edge(repo, @c4, nil)) == {@c4, nil, :merge_back, 1, 3, 0, 3, 2}
    end

    test "parallel children each spawn from the shared fork and return virtually" do
      [repo] = CommitGraph.build(%{"primary" => raw(fork_commits())}, fork_agents())

      # Commit edges first ({from, to} sorted), then agent edges ({kind, owner_key,
      # from, to} sorted — merge_back before spawn).
      assert Enum.map(repo.edges, &{&1.kind, &1.from_sha, &1.to_sha, &1.owner_id}) == [
               {:parent, @r2, @r1, "root"},
               {:parent, @u2, @u1, "child-a"},
               {:parent, @v2, @v1, "child-b"},
               {:merge_back, @u2, nil, "child-a"},
               {:merge_back, @v2, nil, "child-b"},
               {:spawn, @r2, @u1, "child-a"},
               {:spawn, @r2, @v1, "child-b"}
             ]

      assert repo.edge_count == 7
    end

    test "a REAL merge keeps its dashed :merge edge and emits NO merge_back" do
      # @mv lists the child tip @k2 among its 2nd+ parents — the return is already
      # drawn by the :merge edge, so the child sources no merge_back.
      commits = graph([{@mv, [@p2, @k2]}, {@k2, [@k1]}, {@k1, [@p2]}, {@p2, [@p1]}, {@p1, []}])

      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @mv),
        agent(2, 1, depth: 1, base_commit: @p2, current_commit: @k2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      assert {edge(repo, @mv, @k2).kind, edge(repo, @mv, @p2).kind} == {:merge, :parent}
      refute Enum.any?(repo.edges, &(&1.kind == :merge_back))

      # The spawn still replaces the child's oldest → fork :parent edge.
      assert edge(repo, @p2, @k1).kind == :spawn
      refute edge(repo, @k1, @p2)

      assert edge_list(repo) == [
               {:parent, @k2, @k1},
               {:merge, @mv, @k2},
               {:parent, @mv, @p2},
               {:parent, @p2, @p1},
               {:spawn, @p2, @k1}
             ]

      assert repo.edge_count == 5
    end

    test "a no-op child gets ONE :noop stub row with spawn + merge_back onto it" do
      # The child forked at @p2 and committed nothing (current == base): a stub row
      # is synthesized just below the fork, the spawn points at it and the
      # merge_back leaves from it.
      commits = [
        commit(@p3, parents: [@p2], date: ~U[2026-01-02 10:00:00Z]),
        commit(@p2, parents: [@p1]),
        commit(@p1, parents: [])
      ]

      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @p3),
        agent(2, 1, depth: 1, base_commit: @p2, current_commit: @p2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      stub_sha = "noop-2"

      # The stub: no metadata, owned by the child, on the child's lane, at fork
      # layer + 1 (the dated commits sort below the undated stub's layer tie).
      assert node(repo, stub_sha) == %{
               sha: stub_sha,
               short_sha: stub_sha,
               message: "",
               author_name: nil,
               date: nil,
               refs: [],
               row: 2,
               column: 1,
               depth: 1,
               kind: :noop,
               owner_id: 2,
               start_ids: [],
               end_ids: [2]
             }

      assert edge_t(edge(repo, @p2, stub_sha)) == {@p2, stub_sha, :spawn, 0, 1, 1, 2, 2}

      # The root's continuation @p3 (row 3) is the topmost root-owned node below
      # the stub row — the merge_back lands on it.
      assert edge_t(edge(repo, stub_sha, @p3)) == {stub_sha, @p3, :merge_back, 1, 2, 0, 3, 2}
      assert {repo.node_count, repo.edge_count} == {4, 4}
    end

    test "a no-op child with nothing below in the parent lane lands virtually" do
      commits = graph([{@p2, [@p1]}, {@p1, []}])

      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @p2),
        agent(2, 1, depth: 1, base_commit: @p2, current_commit: @p2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      assert edge_t(edge(repo, "noop-2", nil)) == {"noop-2", nil, :merge_back, 1, 2, 0, 2, 2}
    end

    test "an UNRESOLVABLE parent id contributes NO agent-level edges and NO stub" do
      # The child's parent id matches no agent of this repo group.
      commits = graph([{@k2, [@k1]}, {@k1, [@p2]}, {@p2, [@p1]}, {@p1, []}])

      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @p2),
        agent(2, 99, depth: 1, base_commit: @p2, current_commit: @k2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      refute Enum.any?(repo.edges, &(&1.kind in [:spawn, :merge_back]))
      refute Enum.any?(repo.nodes, &(&1.kind == :noop))
      # The plain :parent edges all survive (nothing replaces them).
      assert edge(repo, @k1, @p2).kind == :parent
      assert repo.edge_count == 3
    end

    test "a parent agent in ANOTHER repo group does not resolve either" do
      # The child lives in a different repo than its parent agent: within the
      # child's group the parent id matches nobody.
      commits = graph([{@k2, [@k1]}, {@k1, [@p2]}, {@p2, [@p1]}, {@p1, []}])

      root = agent("root", nil, repo_root: "/a/root", depth: 0, current_commit: @p2)

      child =
        agent("child", "root",
          repo_root: "/b/child",
          depth: 1,
          base_commit: @p2,
          current_commit: @k2
        )

      views = CommitGraph.build(%{"/b/child" => raw(commits)}, [root, child])
      child_repo = repo_by_key(views, "/b/child")

      refute Enum.any?(child_repo.edges, &(&1.kind in [:spawn, :merge_back]))
      refute Enum.any?(child_repo.nodes, &(&1.kind == :noop))
      assert Enum.map(child_repo.agents, & &1.agent_id) == ["child"]
    end

    test "a merge_back targets the TOPMOST parent-owned node strictly below the source" do
      # The root continues TWICE below the child tip: @p3 (whose parent is the tip
      # @k2, a fast-forward) and then @p4. Both are root-owned and both sit below
      # the tip — the merge_back must land on the TOPMOST (@p3, min row).
      commits = [
        commit(@p4, parents: [@p3], date: ~U[2026-01-03 10:00:00Z]),
        commit(@p3, parents: [@k2], date: ~U[2026-01-02 10:00:00Z]),
        commit(@k2, parents: [@k1]),
        commit(@k1, parents: [@p2]),
        commit(@p2, parents: [@p1]),
        commit(@p1, parents: [])
      ]

      agents = [
        agent(1, nil, depth: 0, base_commit: nil, current_commit: @p4),
        agent(2, 1, depth: 1, base_commit: @p2, current_commit: @k2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      # Layers: @p1 0, @p2 1, @k1 2, @k2 3, @p3 4, @p4 5 — one node per layer, and
      # both continuations are the root's (the deeper child wins only @k1/@k2).
      assert Enum.map(repo.nodes, &{&1.sha, &1.row, &1.owner_id}) == [
               {@p1, 0, 1},
               {@p2, 1, 1},
               {@k1, 2, 2},
               {@k2, 3, 2},
               {@p3, 4, 1},
               {@p4, 5, 1}
             ]

      # The child tip (row 3) lands on the TOPMOST root-owned node below it.
      assert edge_t(edge(repo, @k2, @p3)) == {@k2, @p3, :merge_back, 1, 3, 0, 4, 2}
      refute edge(repo, @k2, @p4)
    end
  end

  describe "build/2 — ownership (a single owner per node)" do
    test "a commit on more than one path belongs to the DEEPEST agent (ties: smallest index)" do
      agents = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c3)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

      # Agent 2 (depth 1) is deeper, so it owns every shared commit — and every
      # node therefore sits in agent 2's lane. @c1 is on no path (the exclusive
      # fork point), so it inherits @c2's owner.
      assert Enum.map(repo.nodes, &{&1.sha, &1.owner_id, &1.column, &1.row}) ==
               [{@c1, 2, 1, 0}, {@c2, 2, 1, 1}, {@c3, 2, 1, 2}]

      assert node(repo, @c3).depth == 1

      # Equal depths tie-break on the SMALLEST agent-order index.
      ties = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 0, base_commit: @c1, current_commit: @c3)
      ]

      [tied] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, ties)

      assert {node(tied, @c3).owner_id, node(tied, @c3).column} == {1, 0}
    end

    test "a commit on NO path inherits the owner of its first-parent child (the deepest)" do
      # @p is the exclusive fork point of both agents, so neither walk collects it.
      commits = graph([{@y1, [@p]}, {@y2, [@p]}, {@p, []}])

      shallow = agent(1, nil, depth: 0, base_commit: @p, current_commit: @y2)
      deep = agent(2, nil, depth: 1, base_commit: @p, current_commit: @y1)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [shallow, deep])

      # @p's first-parent children are owned by agents 1 (@y2) and 2 (@y1); the deeper wins.
      assert {node(repo, @p).owner_id, node(repo, @p).depth, node(repo, @p).column} == {2, 1, 1}
      assert {node(repo, @y2).owner_id, node(repo, @y2).column} == {1, 0}
    end

    test "a synthesized base node belongs to the SHALLOWEST agent forked from it" do
      agents = [
        agent(1, nil, depth: 0, base_commit: @b0, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @b0, current_commit: @c3)
      ]

      commits = graph([{@c3, [@c2]}, {@c2, [@c1]}, {@c1, [@b0]}])

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, agents)

      # Agent 1 (depth 0) forks the shared base, so the base lands in its lane…
      assert {node(repo, @b0).kind, node(repo, @b0).owner_id} == {:base, 1}
      assert {node(repo, @b0).column, node(repo, @b0).depth, node(repo, @b0).row} == {0, 0, 0}

      # …while the real commits belong to the deeper agent, one lane right.
      assert {node(repo, @c3).owner_id, node(repo, @c3).column} == {2, 1}
      assert Enum.map(repo.nodes, & &1.row) == [0, 1, 2, 3]
    end
  end

  describe "build/2 — start_ids / end_ids" do
    test "start_ids / end_ids list the forking / tipping agents in agent order" do
      agents = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @c1, current_commit: @c2)
      ]

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

      assert {node(repo, @c1).start_ids, node(repo, @c1).end_ids} == {[1, 2], []}

      assert {node(repo, @c2).end_ids, node(repo, @c3).end_ids, node(repo, @c3).start_ids} ==
               {[2], [1], []}

      # A synthesized base node carries the start ids of the agents forked from it.
      forked_agents = [
        agent(1, nil, depth: 0, base_commit: @b0, current_commit: @c2),
        agent(2, nil, depth: 1, base_commit: @b0, current_commit: @c2)
      ]

      [forked] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, forked_agents)

      assert {node(forked, @b0).start_ids, node(forked, @b0).end_ids} == {[1, 2], []}

      # A node can be a start for one agent and an end for another.
      cross_agents = [
        agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3),
        agent(2, nil, depth: 1, base_commit: @c3, current_commit: @c4)
      ]

      [cross] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3, @c4]))}, cross_agents)

      assert {node(cross, @c3).start_ids, node(cross, @c3).end_ids} == {[2], [1]}
      # Agent 2 (the forking agent) tips one commit later.
      assert node(cross, @c1).start_ids == [1]
      assert node(cross, @c4).end_ids == [2]
    end
  end

  describe "build/2 — progress path (first-parent walk)" do
    test "the walk follows FIRST parents only (a merge's folded parent is not walked)" do
      commits = graph([{@m, [@c3, @s1]}, {@c3, [@c2]}, {@s1, []}, {@c2, [@c1]}, {@c1, []}])

      # The shallow agent walks the side commit; the deep agent walks the merge's
      # first-parent line, so it must NOT collect @s1.
      shallow = agent(1, nil, depth: 0, base_commit: nil, current_commit: @s1)
      deep = agent(2, nil, depth: 1, base_commit: nil, current_commit: @m)

      [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [shallow, deep])

      # If the merge's second parent were walked, the deeper agent would win @s1.
      assert {node(repo, @s1).owner_id, node(repo, @s1).column} == {1, 0}

      assert {node(repo, @m).owner_id, node(repo, @m).column, node(repo, @c3).owner_id} ==
               {2, 1, 2}
    end

    test "the walk excludes the agent's base_commit" do
      # c1 <- c2 <- c3; the deep agent forks from c2, so its walk stops there.
      shallow = agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c3)
      deep = agent(2, nil, depth: 1, base_commit: @c2, current_commit: @c3)

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [shallow, deep])

      # Both agents walk c3, so the deeper one owns it.
      assert node(repo, @c3).owner_id == 2
      # Only the shallow agent walks c2 (the deep agent's base is excluded)…
      assert {node(repo, @c2).owner_id, node(repo, @c2).column} == {1, 0}
      # …and @c1 is off every path, so it inherits from its child @c2.
      assert node(repo, @c1).owner_id == 1
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
      assert node_shas(repo) == [@c1, @c2, @c3]
      refute @b0 in node_shas(repo)
      assert repo.edge_count == 2

      # A self-parenting commit is collected once, then the seen guard stops the walk.
      [loop] =
        CommitGraph.build(%{"primary" => raw([commit(@cyc_a, parents: [@cyc_a])])}, [
          agent(1, nil, base_commit: nil, current_commit: @cyc_a)
        ])

      assert loop.node_count == 1
      assert {node(loop, @cyc_a).row, node(loop, @cyc_a).owner_id} == {0, 1}
    end
  end

  describe "build/2 — the agents list" do
    test "agents are ordered by the DFS root order ({task_local_id, agent_id} ascending)" do
      agents = [
        agent(2, nil, depth: 1, task_local_id: 5),
        agent(1, nil, depth: 0, task_local_id: 9),
        agent(3, nil, depth: 0, task_local_id: 1),
        agent(4, nil, depth: 0, task_local_id: 1)
      ]

      [repo] = CommitGraph.build(%{}, agents)

      # All four are parentless ROOTS, so the DFS visits them in stable
      # {task_local_id, agent_id} order and depth is no ordering key.
      assert Enum.map(repo.agents, &{&1.agent_id, &1.depth}) == [{3, 0}, {4, 0}, {2, 1}, {1, 0}]

      # A nil slot id sorts after every integer (Erlang term order) — deterministic.
      [nil_slot] =
        CommitGraph.build(%{}, [
          agent(1, nil, task_local_id: nil),
          agent(2, nil, task_local_id: 3)
        ])

      assert Enum.map(nil_slot.agents, & &1.agent_id) == [2, 1]
    end

    test "an agent exposes exactly its documented fields and values" do
      a =
        agent(1, nil,
          task_local_id: 7,
          status: :waiting,
          depth: 0,
          base_commit: @c1,
          current_commit: @c3
        )

      [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, [a])

      assert [entry] = repo.agents

      assert entry == %{
               agent_id: 1,
               task_local_id: 7,
               status: :waiting,
               depth: 0,
               lane: 0,
               parent_id: nil,
               color: @depth0_color,
               start_sha: @c1,
               end_sha: @c3,
               # A live agent (no `:ended` on its map) is never marked ended.
               ended: false
             }

      # A non-binary base/current renders nil (never the raw term).
      for {base, current} <- [{nil, nil}, {42, :tip}, {"", ""}] do
        [empty] =
          CommitGraph.build(%{}, [agent(1, nil, base_commit: base, current_commit: current)])

        assert {hd(empty.agents).start_sha, hd(empty.agents).end_sha} == {nil, nil}
      end
    end

    test "parent_id is threaded through RAW from the input agent map" do
      # Any term survives verbatim — resolvable or not.
      for parent_id <- [1, 99, "root", {:tuple, 1}, nil] do
        agents = [
          agent(1, nil, depth: 0, base_commit: nil, current_commit: @c2),
          agent(2, parent_id, depth: 1, base_commit: @c2, current_commit: @c3)
        ]

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2, @c3]))}, agents)

        assert Enum.find(repo.agents, &(&1.agent_id == 2)).parent_id == parent_id
      end
    end

    test "ended is true ONLY for an agent whose map carries :ended == true" do
      # A retained (ended) agent still appears so its START/END markers survive
      # agent recycling.
      [retained] = CommitGraph.build(%{}, [agent(1, nil, ended: true)])

      assert [entry] = retained.agents
      assert entry.ended == true

      # A live agent — key present but nil, or any non-`true` value — never is.
      for ended <- [nil, false, "yes", 1] do
        [view] = CommitGraph.build(%{}, [agent(2, nil, ended: ended)])

        assert hd(view.agents).ended == false
      end

      # An agent map without the key at all is false too.
      [bare] = CommitGraph.build(%{}, [%{}])

      assert hd(bare.agents).ended == false
    end
  end

  describe "build/2 — depth → hue colors" do
    test "each depth maps to its EXACT documented hue; invalid depths fold to 0" do
      for {depth, expected_color, expected_depth} <- [
            {0, @depth0_color, 0},
            {1, @depth1_color, 1},
            {2, @depth2_color, 2},
            {3, @depth3_color, 3},
            {5, @depth5_color, 5},
            # Non-integer, nil and negative depths all fold to depth 0.
            {nil, @depth0_color, 0},
            {-1, @depth0_color, 0},
            {1.5, @depth0_color, 0},
            {"2", @depth0_color, 0},
            {:three, @depth0_color, 0}
          ] do
        a = agent(1, nil, depth: depth, base_commit: @c1, current_commit: @c2)

        [repo] = CommitGraph.build(%{"primary" => raw(chain([@c1, @c2]))}, [a])

        assert hd(repo.agents).color == expected_color
        # The invalid depth also NORMALIZES to 0 in the agents list.
        assert hd(repo.agents).depth == expected_depth
      end

      # …and the normalized depth is the DFS ordering key (a nil depth sorts as 0).
      [repo] =
        CommitGraph.build(%{}, [
          agent(5, nil, depth: nil),
          agent(2, nil, depth: 0),
          agent(9, nil, depth: 3)
        ])

      assert Enum.map(repo.agents, &{&1.agent_id, &1.depth, &1.lane}) ==
               [{2, 0, 0}, {5, 0, 1}, {9, 3, 2}]
    end
  end

  describe "build/2 — determinism" do
    test "lists are sorted by their documented keys and repeat builds are identical" do
      raw_by_repo = %{"primary" => raw(fork_commits(), %{@r2 => ["main"]})}

      [repo] = CommitGraph.build(raw_by_repo, fork_agents())

      assert repo.nodes == Enum.sort_by(repo.nodes, & &1.row)
      assert Enum.map(repo.nodes, & &1.row) == Enum.to_list(0..(repo.node_count - 1))

      # Commit edges first ({from_sha, to_sha} sorted), then agent edges
      # ({kind, owner_key, from_sha, to_sha} sorted).
      {commit_edges, agent_edges} = Enum.split_with(repo.edges, &(&1.kind in [:parent, :merge]))

      assert commit_edges == Enum.sort_by(commit_edges, &{&1.from_sha, &1.to_sha})

      assert agent_edges ==
               Enum.sort_by(agent_edges, fn edge ->
                 {edge.kind, to_string(edge.owner_id), edge.from_sha, edge.to_sha}
               end)

      # The agents list is the DFS subtree-contiguous order: the root, then its
      # children in stable {task_local_id, agent_id} order (both nil-slot, so
      # agent_id breaks the tie — "child-a" before "child-b").
      assert Enum.map(repo.agents, & &1.agent_id) == ["root", "child-a", "child-b"]

      # The agent input order never changes the view model, nor does a repeat build.
      assert CommitGraph.build(raw_by_repo, Enum.reverse(fork_agents())) == [repo]
      assert CommitGraph.build(raw_by_repo, fork_agents()) == [repo]
    end

    test "odd input shapes are deterministic too (identical odd input → identical output)" do
      odd = %{"primary" => %{commits: [%{sha: @c2, parents: [42, @c1]}, %{sha: @c1}], refs: 7}}
      agents = [agent(1, nil, base_commit: @c1, current_commit: @c2), %{id: 2, garbage: :x}]

      assert CommitGraph.build(odd, agents) == CommitGraph.build(odd, agents)
    end
  end

  describe "build/2 — defensive handling" do
    test "an absent repo key (or a non-map raw_by_repo) yields a well-formed EMPTY graph" do
      # No base_commit, so there is nothing to synthesize either.
      a = agent(1, nil, base_commit: nil, current_commit: @c2)

      for raw_by_repo <- [%{}, "garbage", nil, 42, [:a]] do
        [repo] = CommitGraph.build(raw_by_repo, [a])

        assert {repo.nodes, repo.edges, repo.node_count, repo.edge_count, repo.row_count} ==
                 {[], [], 0, 0, 0}

        assert repo.column_count == 1
        assert [entry] = repo.agents
        assert entry.agent_id == 1
      end

      # A base_commit is still synthesized when nothing at all was fetched.
      [base_only] = CommitGraph.build(%{}, [agent(1, nil, base_commit: @b0, current_commit: @c2)])

      assert {node_shas(base_only), node(base_only, @b0).row, node(base_only, @b0).column} ==
               {[@b0], 0, 0}

      assert {base_only.column_count, base_only.edge_count} == {1, 0}
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

      for bad <- bad_graphs do
        [repo] = CommitGraph.build(%{"primary" => bad}, [a])

        assert {repo.nodes, repo.node_count, repo.row_count} == {[], 0, 0}
      end
    end

    test "a single agent map is accepted; a non-binary repo key is still addressable" do
      [repo] =
        CommitGraph.build(
          %{"primary" => raw(chain([@c1, @c2]))},
          %{id: 1, repo_id: "primary", base_commit: @c1, current_commit: @c2}
        )

      assert length(repo.agents) == 1
      assert hd(repo.agents).agent_id == 1
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
      assert {repo.nodes, repo.column_count} == {[], 1}
      assert [entry] = repo.agents
      assert entry == empty_agent_entry()
    end

    test "nil / non-binary base or current commits skip the agent-level edges safely" do
      commits = graph([{@c3, [@c2]}, {@c2, [@c1]}, {@c1, []}])

      root = agent(1, nil, depth: 0, base_commit: nil, current_commit: @c2)

      # A child whose base is nil/non-binary has no fork node to branch out from —
      # no :spawn, no :merge_back and no stub, whatever its commits.
      for base <- [nil, "", 42, :base] do
        child = agent(2, 1, depth: 1, base_commit: base, current_commit: @c3)

        [repo] = CommitGraph.build(%{"primary" => raw(commits)}, [root, child])

        refute Enum.any?(repo.edges, &(&1.kind in [:spawn, :merge_back]))
        refute Enum.any?(repo.nodes, &(&1.kind == :noop))
        # The plain commit edges still render.
        assert repo.edge_count == 2
      end

      # A nil current on a nil base likewise contributes nothing.
      [repo2] =
        CommitGraph.build(%{"primary" => raw(commits)}, [
          root,
          agent(2, 1, depth: 1, base_commit: nil, current_commit: nil)
        ])

      refute Enum.any?(repo2.edges, &(&1.kind in [:spawn, :merge_back]))
      refute Enum.any?(repo2.nodes, &(&1.kind == :noop))
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

      # A struct carries no :parents key -> treated as a root commit (layer 0).
      assert [c2, c3] = repo.nodes

      assert {c2.sha, c2.short_sha, c2.message, c2.author_name} ==
               {@c2, "abcdef12", "struct subject", "Ada"}

      assert {c2.row, c3.row} == {0, 1}
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

  # A compact commit list: `graph([{sha, parents}, ...])` (no metadata needed).
  defp graph(specs), do: Enum.map(specs, fn {sha, parents} -> commit(sha, parents: parents) end)

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

  # Three agents each building one link of @c1 <- @c2 <- @c3 <- @c4 (parentless,
  # so their DFS lanes are 0, 1, 2).
  defp chained_agents do
    [
      agent(1, nil, depth: 0, base_commit: @c1, current_commit: @c2),
      agent(2, nil, depth: 1, base_commit: @c2, current_commit: @c3),
      agent(3, nil, depth: 2, base_commit: @c3, current_commit: @c4)
    ]
  end

  # A node row with the assembler's documented synthesized-node defaults (no
  # metadata, layer 0, no memberships) plus the given overrides.
  defp node_row(sha, overrides) do
    base = %{sha: sha, short_sha: sha, message: "", author_name: nil, date: nil, refs: []}
    base = Map.merge(base, %{row: 0, column: 0, depth: 0, kind: :commit, owner_id: nil})
    base |> Map.merge(%{start_ids: [], end_ids: []}) |> Map.merge(Map.new(overrides))
  end

  # The documented agent-entry defaults for an agent map missing every read key.
  defp empty_agent_entry do
    %{agent_id: nil, task_local_id: nil, status: nil, depth: 0, lane: 0, parent_id: nil}
    |> Map.merge(%{color: @depth0_color, start_sha: nil, end_sha: nil, ended: false})
  end

  # Root @r1 <- @r2 with two parallel children forked at @r2: child-a builds
  # @u1 <- @u2, child-b builds @v1 <- @v2 (the dates interleave the subtrees).
  defp fork_commits do
    [
      commit(@u2, parents: [@u1], date: ~U[2026-01-02 12:00:00Z]),
      commit(@u1, parents: [@r2], date: ~U[2026-01-02 10:00:00Z]),
      commit(@v2, parents: [@v1], date: ~U[2026-01-02 09:30:00Z]),
      commit(@v1, parents: [@r2], date: ~U[2026-01-02 09:00:00Z]),
      commit(@r2, parents: [@r1], date: ~U[2026-01-01 11:00:00Z]),
      commit(@r1, parents: [], date: ~U[2026-01-01 10:00:00Z])
    ]
  end

  defp fork_agents do
    [
      agent("root", nil, depth: 0, base_commit: nil, current_commit: @r2),
      agent("child-a", "root", depth: 1, base_commit: @r2, current_commit: @u2),
      agent("child-b", "root", depth: 1, base_commit: @r2, current_commit: @v2)
    ]
  end

  defp repo_by_key(views, repo_key), do: Enum.find(views, &(&1.repo_key == repo_key))

  defp node(repo, sha), do: Enum.find(repo.nodes, &(&1.sha == sha))

  defp edge(repo, from_sha, to_sha) do
    Enum.find(repo.edges, &(&1.from_sha == from_sha and &1.to_sha == to_sha))
  end

  # A compact edge view: {from_sha, to_sha, kind, from_column, from_row, to_column,
  # to_row, owner_id}.
  defp edge_t(edge) do
    {edge.from_sha, edge.to_sha, edge.kind, edge.from_column, edge.from_row, edge.to_column,
     edge.to_row, edge.owner_id}
  end

  # The edges as {kind, from_sha, to_sha} in the module's documented sort order.
  defp edge_list(repo), do: Enum.map(repo.edges, &{&1.kind, &1.from_sha, &1.to_sha})

  # The nodes as {sha, row, column} in the module's documented row order.
  defp rows(repo), do: Enum.map(repo.nodes, &{&1.sha, &1.row, &1.column})

  # The parents a commit lists, looked up from the fixture list.
  defp parent_shas(commits, sha) do
    case Enum.find(commits, &(&1.sha == sha)) do
      %{parents: parents} when is_list(parents) -> parents
      _ -> []
    end
  end

  # The node shas in the module's documented top → bottom row order.
  defp node_shas(repo), do: Enum.map(repo.nodes, & &1.sha)

  # A view's key set, sorted (so an assertion reads as the documented key list).
  defp keys(view), do: view |> Map.keys() |> Enum.sort()
end
