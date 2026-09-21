defmodule EvoDashWeb.CommitGraphViewTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.AgentsComponents.CommitGraphView`.

  `commit_graph_view/1` is purely presentational: it renders the `repo_view`
  list assembled by the pure `EvoDashWeb.AgentsLive.CommitGraph.build/2` and
  fires the existing `select_agent` event. These tests render it in isolation
  with `render_component/2` (no `live/3` — matching the rest of this directory)
  and pin the frozen DOM markers consumed by the client-side `CommitGraph` hook
  / CSS animation: `#commit-graph`, `#commit-graph-body-<node_key>`,
  `#commit-graph-repo-*`, `#commit-lane-*`, `#commit-lane-commits-*` (keyed by
  stable unique child ids, no `phx-update` mode), `#commit-node-*`,
  `#commit-agent-chip-*` and `data-commit-graph-anim="lane|node|edge"`.

  The main happy-path fixture is produced by calling the REAL
  `CommitGraph.build/2` with realistic agent maps and a raw commit graph, so the
  component provably renders real builder output; a few hand-crafted
  lane/commit maps cover shapes the builder cannot easily produce (depth > 1,
  ref-less commits, a known DOM id).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsComponents.CommitGraphView
  alias EvoDashWeb.AgentsLive.CommitGraph

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
  # Lanes + commit nodes
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — lanes and commit nodes" do
    test "renders one lane per agent with a stable-id commits container and per-commit nodes" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      assert Floki.find(tree, "#commit-lane-#{dom}-a1") != []
      assert Floki.find(tree, "#commit-lane-#{dom}-a2") != []

      assert [container] = Floki.find(tree, "#commit-lane-commits-#{dom}-a1")
      assert attr(container, "phx-update") == []

      assert Floki.find(tree, "#commit-lane-commits-#{dom}-a2") != []

      assert Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1}") != []
      assert Floki.find(tree, "#commit-node-#{dom}-#{@sha_c2}") != []
      assert Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3}") != []
    end

    test "renders the repository header with its name and section id" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [section] = Floki.find(tree, "#commit-graph-repo-#{dom}")
      assert Floki.text(section) =~ "my-project"
    end

    test "a commit node shows the short sha and the first-line subject only" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [node] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1}")

      assert node |> Floki.find("code") |> Floki.text() |> String.trim() == "c1000000"
      assert Floki.text(node) =~ "Add feature X"
      # The multi-line message body is dropped — only the headline is shown.
      refute Floki.text(node) =~ "longer body line"
    end

    test "a commit with refs renders one badge per ref; a ref-less commit renders none" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [tip] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c3}")
      assert ref_chips(tip) == ["HEAD", "genesis/agent_x"]

      [plain] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1}")
      assert ref_chips(plain) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Agent chips
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — agent chips" do
    test "renders one chip per lane labelled T<task_local_id>" do
      tree = parse(render_repos(happy_repos()))

      [chip1] = Floki.find(tree, "#commit-agent-chip-a1")
      [chip2] = Floki.find(tree, "#commit-agent-chip-a2")

      assert chip_label(chip1) == "T1"
      assert chip_label(chip2) == "T2"
    end

    test "the model_id line renders only when the lane carries one" do
      tree = parse(render_repos(happy_repos()))

      [chip1] = Floki.find(tree, "#commit-agent-chip-a1")
      assert Floki.text(chip1) =~ "deepseek:deepseek-v4-flash"
      # A dedicated font-mono model line exists on the lane WITH a model id …
      assert Floki.find(chip1, ~s(div[class*="font-mono"])) != []

      # … and is absent on the lane WITHOUT one (model_id: nil).
      [chip2] = Floki.find(tree, "#commit-agent-chip-a2")
      refute Floki.text(chip2) =~ "deepseek:deepseek-v4-flash"
      assert Floki.find(chip2, ~s(div[class*="font-mono"])) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Selection
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — selection" do
    test "selected_id rings exactly the matching chip" do
      tree = parse(render_repos(happy_repos(), selected_id: "a1"))

      [chip1] = Floki.find(tree, "#commit-agent-chip-a1")
      [chip2] = Floki.find(tree, "#commit-agent-chip-a2")

      assert class_contains?(chip1, "ring-2")
      assert class_contains?(chip1, "ring-primary-standalone")
      refute class_contains?(chip2, "ring-2")

      assert ringed_chips(tree) == ["a1"]
    end

    test "a nil selected_id rings no chip" do
      tree = parse(render_repos(happy_repos(), selected_id: nil))

      assert ringed_chips(tree) == []

      [chip1] = Floki.find(tree, "#commit-agent-chip-a1")
      refute class_contains?(chip1, "ring-2")
    end

    test "a selected_id matching no lane rings nothing" do
      tree = parse(render_repos(happy_repos(), selected_id: "nope"))

      assert ringed_chips(tree) == []
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
      assert Floki.find(tree, "#commit-graph-repo-#{dom}") != []
      assert Floki.find(tree, "#commit-lane-#{dom}-a1") != []

      # … and the hard error state is NOT shown.
      assert Floki.find(tree, "#commit-graph-error") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Animation markers
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — animation markers" do
    test "lane, node and edge animation markers are all emitted" do
      tree = parse(render_repos(happy_repos()))

      assert Floki.find(tree, ~s([data-commit-graph-anim="lane"])) != []
      assert Floki.find(tree, ~s([data-commit-graph-anim="node"])) != []
      assert Floki.find(tree, ~s([data-commit-graph-anim="edge"])) != []
    end

    test "the parent connector edge renders only for a connecting lane" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # a2's parent (a1) is in the same repo group → connects? true → elbow.
      [child_lane] = Floki.find(tree, "#commit-lane-#{dom}-a2")
      assert Floki.find(child_lane, ~s([class*="rounded-bl-md"])) != []

      # a1 is a root → connects? false → no elbow.
      [root_lane] = Floki.find(tree, "#commit-lane-#{dom}-a1")
      assert Floki.find(root_lane, ~s([class*="rounded-bl-md"])) == []
    end

    test "an inter-commit edge renders before the second commit of a lane" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      # a1 owns two commits (c1 oldest, c2 newest) → an edge before c2.
      assert [edge] = Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c2}")
      assert attr(edge, "data-commit-graph-anim") == ["edge"]

      # The lane's first commit has no preceding edge.
      assert Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c1}") == []

      # a2 owns a single commit → no inter-commit edge at all.
      assert Floki.find(tree, "#commit-edge-#{dom}-#{@sha_c3}") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Click-to-select contract
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — click to select" do
    test "the commit node and the agent chip carry the select_agent click contract" do
      repos = happy_repos()
      dom = dom_id(repos)
      tree = parse(render_repos(repos))

      [node] = Floki.find(tree, "#commit-node-#{dom}-#{@sha_c1}")
      assert attr(node, "phx-click") == ["select_agent"]
      assert attr(node, "phx-value-id") == ["a1"]

      [chip] = Floki.find(tree, "#commit-agent-chip-a2")
      assert attr(chip, "phx-click") == ["select_agent"]
      assert attr(chip, "phx-value-id") == ["a2"]
    end
  end

  # ---------------------------------------------------------------------------
  # Depth indentation
  # ---------------------------------------------------------------------------

  describe "commit_graph_view/1 — depth indentation" do
    test "depth 0 renders no indent while depth 2 renders a 1.5rem indent" do
      repos = [
        repo_view(
          repo_dom_id: "commit-graph-repo-t-1",
          lanes: [
            lane(agent_id: "root", depth: 0, commits: [commit(sha: "root0000")]),
            lane(agent_id: "deep", depth: 2, commits: [commit(sha: "deep0000")])
          ]
        )
      ]

      tree = parse(render_repos(repos))

      [root_lane] = Floki.find(tree, "#commit-lane-commit-graph-repo-t-1-root")
      assert attr(root_lane, "style") == ["margin-left: 0rem"]

      [deep_lane] = Floki.find(tree, "#commit-lane-commit-graph-repo-t-1-deep")
      assert attr(deep_lane, "style") == ["margin-left: 1.5rem"]
    end

    test "depth 1 renders a 0.75rem indent" do
      repos = [
        repo_view(
          repo_dom_id: "commit-graph-repo-t-2",
          lanes: [lane(agent_id: "child", depth: 1, commits: [commit(sha: "child000")])]
        )
      ]

      tree = parse(render_repos(repos))

      [child_lane] = Floki.find(tree, "#commit-lane-commit-graph-repo-t-2-child")
      assert attr(child_lane, "style") == ["margin-left: 0.75rem"]
    end

    test "a non-integer or negative depth falls back to 0rem" do
      repos = [
        repo_view(
          repo_dom_id: "commit-graph-repo-t-3",
          lanes: [
            lane(agent_id: "nil-depth", depth: nil, commits: [commit(sha: "nil00000")]),
            lane(agent_id: "neg-depth", depth: -1, commits: [commit(sha: "neg00000")])
          ]
        )
      ]

      tree = parse(render_repos(repos))

      [nil_lane] = Floki.find(tree, "#commit-lane-commit-graph-repo-t-3-nil-depth")
      assert attr(nil_lane, "style") == ["margin-left: 0rem"]

      [neg_lane] = Floki.find(tree, "#commit-lane-commit-graph-repo-t-3-neg-depth")
      assert attr(neg_lane, "style") == ["margin-left: 0rem"]
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # The main happy-path fixture: a two-agent repo (a1 root at depth 0 owning two
  # commits, a2 its child at depth 1 owning the tip commit) assembled by the REAL
  # `CommitGraph.build/2`.
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
            sha: @sha_c1,
            message: "Add feature X\n\nlonger body line",
            author_name: "Alice",
            date: ~U[2024-01-01 10:00:00Z],
            parents: [@sha_base]
          },
          %{
            sha: @sha_c2,
            message: "Fix bug Y",
            author_name: "Bob",
            date: ~U[2024-01-02 10:00:00Z],
            parents: [@sha_c1]
          },
          %{
            sha: @sha_c3,
            message: "Refactor Z",
            author_name: "Carol",
            date: ~U[2024-01-03 10:00:00Z],
            parents: [@sha_c2]
          }
        ],
        refs: %{@sha_c3 => ["HEAD", "genesis/agent_x"]}
      }
    }

    CommitGraph.build(raw, agents)
  end

  # Hand-crafted lane/commit maps for shapes the builder does not easily produce.
  defp repo_view(overrides) do
    Map.merge(
      %{
        repo_key: "primary",
        repo_dom_id: "commit-graph-repo-primary-1",
        repo_name: "Primary Repo",
        lanes: []
      },
      Map.new(overrides)
    )
  end

  defp lane(overrides) do
    Map.merge(
      %{
        agent_id: "a1",
        lane_index: 0,
        depth: 0,
        parent_agent_id: nil,
        parent_lane_index: nil,
        connects?: false,
        task_local_id: 1,
        status: :running,
        agent_module: "EvoGit.Agents.Manager",
        model_id: nil,
        base_commit: nil,
        current_commit: nil,
        commits: []
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
        author_name: "Tester",
        date: nil,
        parents: [],
        refs: [],
        has_parent_in_lane?: false
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

  # The stable repo DOM id (a string that, from the real builder, already starts
  # with "commit-graph-repo-" — the component prefixes it again).
  defp dom_id(repos), do: repos |> hd() |> Map.fetch!(:repo_dom_id)

  defp ref_chips(node) do
    node
    |> Floki.find("span.badge.badge-outline.badge-xs")
    |> Enum.map(fn chip -> chip |> Floki.text() |> String.trim() end)
  end

  # The "T<task_local_id>" label of a chip. The span is `font-bold text-sm`;
  # the status badge also carries `font-bold`, so `text-sm` disambiguates.
  defp chip_label(chip) do
    chip
    |> Floki.find("span.font-bold.text-sm")
    |> Floki.text()
    |> String.trim()
  end

  defp ringed_chips(tree) do
    tree
    |> Floki.find(~s([id^="commit-agent-chip-"]))
    |> Enum.filter(&class_contains?(&1, "ring-2"))
    |> Enum.map(fn chip ->
      chip
      |> Floki.attribute("id")
      |> List.first()
      |> String.replace_prefix("commit-agent-chip-", "")
    end)
  end

  defp class_contains?(el, fragment) do
    el |> Floki.attribute("class") |> Enum.join(" ") |> String.contains?(fragment)
  end

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
