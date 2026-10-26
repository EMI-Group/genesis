defmodule EvoDashWeb.AgentsLive.CommitGraphRefreshTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.AgentsLive.CommitGraphRefresh` — the pure
  fetch-result folding + commit-relevance fingerprinting module for the Agents
  page's TEMPORAL (commit-history) view.

  No LiveView, no socket, no TaskSupervisor: the runners are capture-fn
  closures and everything asserted is the module's return value. The
  LiveView-level wiring (the runner seam, the partial-success apply path, the
  fingerprint gate's rebuild/refetch skip) is covered by the sibling
  `agents_live_test.exs` suite.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.CommitGraphRefresh

  # One fetched commit in the payload shape the assembler consumes.
  defp commit(sha, parents \\ []) do
    %{
      sha: sha,
      short_sha: sha,
      message: "subject #{sha}",
      parents: parents,
      author_name: "Ada",
      date: nil
    }
  end

  defp group(repo_key, task_id, live_tips) do
    %{repo_key: repo_key, task_id: task_id, live_tips: live_tips}
  end

  defp agent(overrides) do
    Map.merge(
      %{
        id: 1,
        task_local_id: nil,
        repo_id: nil,
        status: :running,
        depth: 0,
        parent_id: nil,
        usage: nil,
        total_tokens: 0,
        message_count: 0,
        objective: "test objective",
        repo_root: "/repo/a",
        current_commit: "c1",
        base_commit: "b1",
        task_id: "task-1",
        ended: false
      },
      Map.new(overrides)
    )
  end

  # A runner replying per group by repo_key. An unknown key replies an error so
  # an unexpected group fails loudly instead of silently succeeding.
  defp runner_by_repo(replies) do
    fn _node, _task_id, repo_key, _live_tips, _opts ->
      Map.get(replies, repo_key, {:error, :no_reply})
    end
  end

  defp shas(commits), do: Enum.map(commits, & &1.sha)

  describe "limit/0" do
    test "is the per-group commit limit (100) — the single source of the limit" do
      assert CommitGraphRefresh.limit() == 100
    end
  end

  describe "fetch_result/3" do
    test "calls the runner once per group with the {node, task_id, repo_key, live_tips, [limit: 100]} shape" do
      groups = [
        group("/repo/a", "task-1", ["c1", "c1b"]),
        group("/repo/b", "task-2", ["c2"])
      ]

      test_pid = self()

      runner = fn node, task_id, repo_key, live_tips, opts ->
        send(test_pid, {:runner_call, node, task_id, repo_key, live_tips, opts})
        {:ok, %{commits: [], refs: %{}}}
      end

      assert {:ok, _raw} = CommitGraphRefresh.fetch_result(groups, runner, :node@x)

      # Every call carries the passed node, ITS group's task_id / repo_key /
      # live tips (in the given group order) and the limit opt — the arity-5
      # runner contract the LiveView's spawn path relies on.
      assert_received {:runner_call, :node@x, "task-1", "/repo/a", ["c1", "c1b"], [limit: 100]}
      assert_received {:runner_call, :node@x, "task-2", "/repo/b", ["c2"], [limit: 100]}
      refute_received {:runner_call, _, _, _, _, _}
    end

    test "PARTIAL success — a failing or malformed group drops only its own data" do
      # The good repo still folds in; the failed one is simply ABSENT (its lanes
      # come from the agent set, only its commits stop at the last fetch).
      rows = [
        {"repo-b errors", "/repo/a",
         %{
           "/repo/a" => {:ok, %{commits: [commit("c1", ["b1"])], refs: %{"c1" => ["main"]}}},
           "/repo/b" => {:error, :git_down}
         }, ["c1"], %{"c1" => ["main"]}},
        # {:ok, %{commits: "not-a-list"}} is garbage: neither crashed nor accepted.
        {"repo-a reply is malformed", "/repo/b",
         %{
           "/repo/a" => {:ok, %{commits: "not-a-list"}},
           "/repo/b" => {:ok, %{commits: [commit("c2", ["b2"])]}}
         }, ["c2"], %{}}
      ]

      groups = [group("/repo/a", "task-1", ["c1"]), group("/repo/b", "task-2", ["c2"])]

      for {label, surviving, replies, expected_shas, expected_refs} <- rows do
        assert {:ok, raw} =
                 CommitGraphRefresh.fetch_result(groups, runner_by_repo(replies), node())

        assert {Map.keys(raw), shas(raw[surviving].commits), raw[surviving].refs} ==
                 {[surviving], expected_shas, expected_refs},
               label
      end
    end

    test "ALL groups failing yields the LAST failing group's failure" do
      # The reduce PREPENDS failures and failure_reason/1 takes the head, so the
      # LAST failing group's failure surfaces. A single failing group is exactly
      # that case, keeping the former per-group error shape.
      rows = [
        {[group("/repo/a", "task-1", ["c1"]), group("/repo/b", "task-2", ["c2"])],
         %{"/repo/a" => {:error, :git_down}, "/repo/b" => {:error, :other}},
         {:commit_graph_repo_failed, {"/repo/b", "task-2"}, {:error, :other}}},
        {[group("/repo/a", "task-1", ["c1"])], %{"/repo/a" => {:error, :git_down}},
         {:commit_graph_repo_failed, {"/repo/a", "task-1"}, {:error, :git_down}}}
      ]

      for {groups, replies, expected} <- rows do
        assert CommitGraphRefresh.fetch_result(groups, runner_by_repo(replies), node()) ==
                 {:error, expected}
      end
    end

    test "two groups sharing one repo_key UNION their commits and refs" do
      groups = [group("/repo/a", "task-1", ["c1"]), group("/repo/a", "task-2", ["c2"])]

      # One runner call per task with DISTINCT payloads whose "shared" commit
      # arrives twice: the union below pins the sha dedupe (first occurrence
      # wins), the within-list ref de-dup and the cross-group ref union.
      runner = fn _node, task_id, "/repo/a", _tips, _opts ->
        case task_id do
          "task-1" ->
            {:ok,
             %{
               commits: [
                 %{commit("shared", ["b1"]) | message: "subject first"},
                 commit("c1", ["shared"])
               ],
               refs: %{"shared" => ["main", "main"], "c1" => ["tag-1"]}
             }}

          "task-2" ->
            {:ok,
             %{
               commits: [
                 %{commit("shared", ["b1"]) | message: "subject second"},
                 commit("c2", ["shared"])
               ],
               refs: %{"shared" => ["other", "main"], "c2" => ["tag-2"]}
             }}
        end
      end

      assert {:ok, %{"/repo/a" => %{commits: commits, refs: refs}}} =
               CommitGraphRefresh.fetch_result(groups, runner, node())

      assert {shas(commits), Enum.find(commits, &(&1.sha == "shared")).message, refs} ==
               {["shared", "c1", "c2"], "subject first",
                %{"shared" => ["main", "other"], "c1" => ["tag-1"], "c2" => ["tag-2"]}}
    end
  end

  describe "merge_repo_graph/4 totality and union" do
    test "unions commits (sha dedupe) and refs while dropping garbage" do
      # Each row is a list of {repo_key, commits, refs} steps folded onto an acc.
      rows = [
        # Non-map commit entries are dropped; a duplicate sha keeps one.
        {"garbage commits", %{},
         [{"/repo/a", [commit("c1"), "garbage", nil, commit("c1"), 42], %{"c1" => ["main"]}}],
         %{"/repo/a" => {["c1"], %{"c1" => ["main"]}}}},
        # Ref name lists are unioned across merges (and de-duplicated).
        {"ref union", %{},
         [
           {"/repo/a", [commit("shared")], %{"shared" => ["main"]}},
           {"/repo/a", [commit("shared")], %{"shared" => ["other", "main"]}}
         ], %{"/repo/a" => {["shared"], %{"shared" => ["main", "other"]}}}},
        # A malformed refs payload degrades to the other side's refs.
        {"garbage refs", %{},
         [
           {"/repo/a", [commit("c1")], %{"c1" => ["main"]}},
           {"/repo/a", [commit("c2")], "not-a-map"}
         ], %{"/repo/a" => {["c1", "c2"], %{"c1" => ["main"]}}}},
        # A non-map acc folds from empty; an absent repo entry too, and distinct
        # repo keys stay separate.
        {"garbage acc", nil, [{"/repo/a", [commit("c1")], %{}}, {"/repo/b", [commit("c2")], %{}}],
         %{"/repo/a" => {["c1"], %{}}, "/repo/b" => {["c2"], %{}}}}
      ]

      for {label, acc, steps, expected} <- rows do
        merged =
          Enum.reduce(steps, acc, fn {key, commits, refs}, acc ->
            CommitGraphRefresh.merge_repo_graph(acc, key, commits, refs)
          end)

        assert Map.new(merged, fn {key, entry} -> {key, {shas(entry.commits), entry.refs}} end) ==
                 expected,
               label
      end
    end
  end

  describe "fingerprint/1" do
    test "is order-insensitive (a permuted list and nil/[] are all equal)" do
      a = [agent(id: 1), agent(id: 2, repo_root: "/repo/b", task_id: "task-2")]

      assert {CommitGraphRefresh.fingerprint(a) ==
                CommitGraphRefresh.fingerprint(Enum.reverse(a)),
              CommitGraphRefresh.fingerprint(nil) == CommitGraphRefresh.fingerprint([])} ==
               {true, true}
    end

    test "the grouping key falls back to repo_id when repo_root is nil" do
      with_root = agent(id: 1, repo_root: "/repo/a", repo_id: nil)
      with_id_only = agent(id: 1, repo_root: nil, repo_id: "/repo/a")
      other = agent(id: 1, repo_root: nil, repo_id: "/repo/other")

      assert {CommitGraphRefresh.fingerprint([with_root]) ==
                CommitGraphRefresh.fingerprint([with_id_only]),
              CommitGraphRefresh.fingerprint([with_root]) ==
                CommitGraphRefresh.fingerprint([other])} == {true, false}
    end

    test "a changed agent SET (membership) changes the fingerprint" do
      assert CommitGraphRefresh.fingerprint([agent(id: 1), agent(id: 2)]) !=
               CommitGraphRefresh.fingerprint([agent(id: 1)])
    end

    # Every field the fingerprint covers — a change in ANY of these means the
    # temporal view may have moved (the caller rebuilds + refetches). `repo_id`
    # only discriminates when repo_root is nil (the fingerprint reads
    # `repo_root || repo_id`), hence its base override.
    @sensitive_fields [
      {:id, 2, "the agent id (set membership)", []},
      {:repo_root, "/repo/b", "repo_root (a moved grouping key)", []},
      {:repo_id, "/repo/b", "repo_id (the fallback grouping key)",
       [repo_root: nil, repo_id: nil]},
      {:task_id, "task-9", "task_id (the task grouping)", []},
      {:base_commit, "b9", "base_commit (a moved fork point)", []},
      {:current_commit, "c9", "current_commit (a moved tip — a new commit)", []},
      {:parent_id, 7, "parent_id (lane order + agent-level edges)", []},
      {:depth, 3, "depth (lane order + colors)", []},
      {:task_local_id, 4, "task_local_id (lane order)", []},
      {:ended, true, "the ended flag (retained-agent dimming)", []}
    ]

    test "is SENSITIVE to every field the temporal view reads" do
      for {field, value, reason, base_overrides} <- @sensitive_fields do
        base_agent = agent(Keyword.merge([id: 1], base_overrides))

        assert CommitGraphRefresh.fingerprint([Map.put(base_agent, field, value)]) !=
                 CommitGraphRefresh.fingerprint([base_agent]),
               reason
      end
    end

    # Fields the temporal view NEVER reads — deliberately excluded, so a
    # status/token/usage/message-count/objective-only flush costs nothing (no
    # rebuild, no git RPC).
    @insensitive_fields [
      {:status, :waiting},
      {:total_tokens, 999_999},
      {:usage, %{input_tokens: 1}},
      {:message_count, 42},
      {:objective, "a whole new objective"}
    ]

    test "is INSENSITIVE to every field the view never reads" do
      for {field, value} <- @insensitive_fields do
        base_agent = agent(id: 1)

        assert CommitGraphRefresh.fingerprint([Map.put(base_agent, field, value)]) ==
                 CommitGraphRefresh.fingerprint([base_agent]),
               "#{field}"
      end
    end
  end
end
