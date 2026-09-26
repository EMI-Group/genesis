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

    test "PARTIAL success — a failing group drops only its own data" do
      groups = [
        group("/repo/a", "task-1", ["c1"]),
        group("/repo/b", "task-2", ["c2"])
      ]

      runner =
        runner_by_repo(%{
          "/repo/a" => {:ok, %{commits: [commit("c1", ["b1"])], refs: %{"c1" => ["main"]}}},
          "/repo/b" => {:error, :git_down}
        })

      # The GOOD repo folds in and the failed one is simply ABSENT — the page
      # still renders the successful group (the failed group's lanes come from
      # the agent set, only its commits stop at the last fetch).
      assert {:ok, raw} = CommitGraphRefresh.fetch_result(groups, runner, node())

      assert Map.has_key?(raw, "/repo/a")
      refute Map.has_key?(raw, "/repo/b")

      assert raw["/repo/a"].commits |> Enum.map(& &1.sha) == ["c1"]
      assert raw["/repo/a"].refs == %{"c1" => ["main"]}
    end

    test "ALL groups failing yields one of the failures (every group failed — nothing to render)" do
      groups = [
        group("/repo/a", "task-1", ["c1"]),
        group("/repo/b", "task-2", ["c2"])
      ]

      runner =
        runner_by_repo(%{
          "/repo/a" => {:error, :git_down},
          "/repo/b" => {:error, :other}
        })

      # NOTE — observed behaviour differs from the docs: the @doc for
      # fetch_result/3 and the `failure_reason/1` comment ("oldest-first list")
      # both promise the FIRST failing group's failure, but the reduce PREPENDS
      # each failure (`[failure | failures]`) and failure_reason/1 takes the
      # head, so the LAST failing group's failure actually surfaces. Pinned as
      # observed; either error still renders the same error strip (the reason
      # is display-only), so this is a doc/comment bug, not a UX bug.
      assert {:error, {:commit_graph_repo_failed, {"/repo/b", "task-2"}, {:error, :other}}} =
               CommitGraphRefresh.fetch_result(groups, runner, node())
    end

    test "a single failing group keeps the exact former per-group error shape" do
      groups = [group("/repo/a", "task-1", ["c1"])]

      runner = runner_by_repo(%{"/repo/a" => {:error, :git_down}})

      assert {:error, {:commit_graph_repo_failed, {"/repo/a", "task-1"}, {:error, :git_down}}} =
               CommitGraphRefresh.fetch_result(groups, runner, node())
    end

    test "a malformed ok-shape reply is a per-group failure too" do
      # {:ok, %{commits: "not-a-list"}} is garbage — it must not crash the fold
      # nor be accepted as a success; only THAT group is dropped.
      groups = [
        group("/repo/a", "task-1", ["c1"]),
        group("/repo/b", "task-2", ["c2"])
      ]

      runner =
        runner_by_repo(%{
          "/repo/a" => {:ok, %{commits: "not-a-list"}},
          "/repo/b" => {:ok, %{commits: [commit("c2", ["b2"])]}}
        })

      assert {:ok, raw} = CommitGraphRefresh.fetch_result(groups, runner, node())
      refute Map.has_key?(raw, "/repo/a")
      assert Map.has_key?(raw, "/repo/b")
    end

    test "two groups sharing one repo_key UNION their commits (sha dedupe) and refs" do
      groups = [
        group("/repo/a", "task-1", ["c1"]),
        group("/repo/a", "task-2", ["c2"])
      ]

      # A per-repo_key runner hands BOTH groups the same payload — the union
      # below therefore also pins the sha dedupe (the "shared" commit arrives
      # twice) and the per-sha ref list de-dup.
      runner =
        runner_by_repo(%{
          "/repo/a" =>
            {:ok,
             %{
               commits: [commit("shared", ["b1"]), commit("c1", ["shared"])],
               refs: %{"shared" => ["main", "main"], "c1" => ["tag-1"]}
             }}
        })

      assert {:ok, %{"/repo/a" => %{commits: commits, refs: refs}}} =
               CommitGraphRefresh.fetch_result(groups, runner, node())

      # Commits de-duplicated by :sha, first occurrence kept.
      assert commits |> Enum.map(& &1.sha) == ["shared", "c1"]

      # Ref name lists unioned per sha (and de-duplicated within a list too).
      assert refs == %{"shared" => ["main"], "c1" => ["tag-1"]}
    end

    test "two groups sharing one repo_key with DISTINCT payloads union both" do
      groups = [
        group("/repo/a", "task-1", ["c1"]),
        group("/repo/a", "task-2", ["c2"])
      ]

      # Two DISTINCT payloads handed out in group order (the groups arrive
      # pre-sorted by the caller — task-1 first here).
      queue = start_supervised!({Agent, fn -> [:first, :second] end})

      runner = fn _node, _task_id, "/repo/a", _tips, _opts ->
        which = Agent.get_and_update(queue, fn [h | t] -> {h, t} end)

        case which do
          :first ->
            {:ok,
             %{
               commits: [
                 %{commit("shared", ["b1"]) | message: "subject first"},
                 commit("c1", ["shared"])
               ],
               refs: %{"shared" => ["main"], "c1" => ["tag-1"]}
             }}

          :second ->
            {:ok,
             %{
               commits: [
                 %{commit("shared", ["b1"]) | message: "subject second"},
                 commit("c2", ["shared"])
               ],
               refs: %{"shared" => ["other"], "c2" => ["tag-2"]}
             }}
        end
      end

      assert {:ok, %{"/repo/a" => %{commits: commits, refs: refs}}} =
               CommitGraphRefresh.fetch_result(groups, runner, node())

      # Both tasks' commits fold into ONE repo entry, de-duped by sha with the
      # FIRST occurrence winning (the "first" subject survives for "shared").
      assert commits |> Enum.map(& &1.sha) == ["shared", "c1", "c2"]
      assert Enum.find(commits, &(&1.sha == "shared")).message == "subject first"

      assert refs == %{
               "shared" => ["main", "other"],
               "c1" => ["tag-1"],
               "c2" => ["tag-2"]
             }
    end
  end

  describe "merge_repo_graph/4 totality" do
    test "non-map commit entries are dropped and sha dedupe keeps one" do
      merged =
        CommitGraphRefresh.merge_repo_graph(
          %{},
          "/repo/a",
          [commit("c1"), "garbage", nil, commit("c1"), 42],
          %{"c1" => ["main"]}
        )

      assert merged["/repo/a"].commits |> Enum.map(& &1.sha) == ["c1"]
      assert merged["/repo/a"].refs == %{"c1" => ["main"]}
    end

    test "sha dedupe keeps BOTH refs lists unioned across merges" do
      merged =
        %{}
        |> CommitGraphRefresh.merge_repo_graph("/repo/a", [commit("shared")], %{
          "shared" => ["main"]
        })
        |> CommitGraphRefresh.merge_repo_graph("/repo/a", [commit("shared")], %{
          "shared" => ["other", "main"]
        })

      assert merged["/repo/a"].commits |> Enum.map(& &1.sha) == ["shared"]
      assert merged["/repo/a"].refs == %{"shared" => ["main", "other"]}
    end

    test "a malformed refs payload degrades to the other side's refs" do
      merged =
        %{}
        |> CommitGraphRefresh.merge_repo_graph("/repo/a", [commit("c1")], %{"c1" => ["main"]})
        |> CommitGraphRefresh.merge_repo_graph("/repo/a", [commit("c2")], "not-a-map")

      assert merged["/repo/a"].commits |> Enum.map(& &1.sha) == ["c1", "c2"]
      # The map side wins; the garbage side contributes nothing.
      assert merged["/repo/a"].refs == %{"c1" => ["main"]}
    end

    test "a non-map acc folds from empty" do
      merged = CommitGraphRefresh.merge_repo_graph(nil, "/repo/a", [commit("c1")], %{})

      assert merged["/repo/a"].commits |> Enum.map(& &1.sha) == ["c1"]
      assert merged["/repo/a"].refs == %{}
    end

    test "an absent repo entry folds from an empty base" do
      merged =
        %{}
        |> CommitGraphRefresh.merge_repo_graph("/repo/a", [commit("c1")], %{"c1" => ["main"]})
        |> CommitGraphRefresh.merge_repo_graph("/repo/b", [commit("c2")], %{})

      assert merged["/repo/a"].commits |> Enum.map(& &1.sha) == ["c1"]
      assert merged["/repo/b"].commits |> Enum.map(& &1.sha) == ["c2"]
      assert merged["/repo/b"].refs == %{}
    end
  end

  describe "fingerprint/1" do
    test "is order-insensitive (permuted lists are equal)" do
      a = [agent(id: 1), agent(id: 2, repo_root: "/repo/b", task_id: "task-2")]
      b = Enum.reverse(a)

      assert CommitGraphRefresh.fingerprint(a) == CommitGraphRefresh.fingerprint(b)
    end

    test "falls back to repo_id when repo_root is nil" do
      with_root = agent(id: 1, repo_root: "/repo/a", repo_id: nil)
      with_id_only = agent(id: 1, repo_root: nil, repo_id: "/repo/a")

      assert CommitGraphRefresh.fingerprint([with_root]) ==
               CommitGraphRefresh.fingerprint([with_id_only])

      # …and a nil repo_root with a DIFFERENT repo_id is a different key.
      other = agent(id: 1, repo_root: nil, repo_id: "/repo/other")

      assert CommitGraphRefresh.fingerprint([with_root]) !=
               CommitGraphRefresh.fingerprint([other])
    end

    test "a changed agent SET (membership) changes the fingerprint" do
      one = CommitGraphRefresh.fingerprint([agent(id: 1)])
      two = CommitGraphRefresh.fingerprint([agent(id: 1), agent(id: 2)])

      assert two != one
    end

    test "nil and empty agent sets are equal (both empty)" do
      assert CommitGraphRefresh.fingerprint(nil) == CommitGraphRefresh.fingerprint([])
    end

    # Every field the fingerprint covers — a change in ANY of these means the
    # temporal view may have moved (the caller rebuilds + refetches). The loop
    # variables are threaded into the test via @tag (the test body cannot read
    # the comprehension's variables directly). `repo_id` carries its own base
    # override: the fingerprint reads `repo_root || repo_id`, so repo_id only
    # discriminates when repo_root is nil.
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

    for {field, value, reason, base_overrides} <- @sensitive_fields do
      @tag field: field, value: value, base_overrides: base_overrides

      test "is SENSITIVE to #{reason}", %{
        field: field,
        value: value,
        base_overrides: base_overrides
      } do
        base_agent = agent(Keyword.merge([id: 1], base_overrides))
        changed_agent = Map.put(base_agent, field, value)

        base = CommitGraphRefresh.fingerprint([base_agent])
        changed = CommitGraphRefresh.fingerprint([changed_agent])

        assert changed != base
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

    for {field, value} <- @insensitive_fields do
      @tag field: field, value: value
      test "is INSENSITIVE to #{field} (the view never reads it)", %{field: field, value: value} do
        base_agent = agent(id: 1)
        changed_agent = Map.put(base_agent, field, value)

        base = CommitGraphRefresh.fingerprint([base_agent])
        changed = CommitGraphRefresh.fingerprint([changed_agent])

        assert changed == base
      end
    end
  end
end
