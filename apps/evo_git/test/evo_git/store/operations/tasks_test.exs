defmodule EvoGit.Store.Operations.TasksTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Tasks` — the R2a task write/core Ecto
  operations.

  Each test boots its own UNNAMED dynamic repo (`EvoGit.Store.Boot.start_dynamic/1`)
  on a unique tmp SQLite file, so `async: true` is safe. The production
  `EvoGit.Store.Boot` serializes concurrent migration runs globally
  (`:global.trans`), so parallel boots are safe. Raw-column assertions go
  through the read-only `TaskRowRaw` projection (exact stored bytes, no type
  casting).
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Tasks
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo

  # ── Self-contained helpers (no shared files) ─────────────────────────────

  defp start_repo! do
    # The filename must be unique ACROSS BEAM RESTARTS too, not just within
    # this node: `System.unique_integer([:positive, :monotonic])` restarts
    # from low values on a fresh node and so do PIDs, so counter+pid alone
    # can collide with a previous run's leftover file and silently reopen
    # its stale rows. The wall-clock stamp makes cross-run collisions
    # effectively impossible.
    unique =
      "#{System.system_time(:millisecond)}_#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    path = Path.join(System.tmp_dir!(), "evogit_r2a_#{unique}.sqlite")

    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp raw_row(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      Repo.one(from(t in TaskRowRaw, where: t.id == ^task_id))
    end)
  end

  # A rich-but-cheap TaskInfo exercising every column family.
  defp full_task(id) do
    %TaskInfo{
      id: id,
      type: :evolve,
      status: :completed,
      opts: [path: "/tmp/r2a-proj", mode: "simple", objective: "fix the bug"],
      started_at: ~U[2026-06-26 07:19:44.123456Z],
      finished_at: ~U[2026-06-26 08:00:00.999999Z],
      logs: ["line 1", "line 2"],
      result:
        {:ok,
         %{
           commit_sha: "abc123def",
           branch_name: "genesis/agent_beef",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :merged,
      usage: %EvoGit.Agent.Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 10,
        cache_creation_tokens: 5
      },
      agent_count: 5,
      base_sha: "base789",
      commit_sha: "head012",
      archive_metadata: [%{"agent_id" => "a1", "path" => "/archive/a1"}],
      lease_expires_at: 1_767_225_600,
      model_id: "deepseek-chat",
      branch_name: "genesis/agent_beef"
    }
  end

  defp put!(repo, %TaskInfo{} = task) do
    :ok = Tasks.put_task(repo, task)
  end

  # ── put/get round-trip ──────────────────────────────────────────────────

  describe "put_task/get_task round-trip" do
    test "all fields survive (DateTime µs-truncated, opts/result/logs/usage intact)" do
      repo = start_repo!()
      task = full_task("rt-1")

      put!(repo, task)
      fetched = Tasks.get_task(repo, "rt-1")

      assert %TaskInfo{} = fetched
      assert fetched.id == "rt-1"
      assert fetched.type == :evolve
      assert fetched.status == :completed
      assert fetched.review_status == :merged
      assert fetched.agent_count == 5
      assert fetched.base_sha == "base789"
      assert fetched.commit_sha == "head012"
      assert fetched.lease_expires_at == 1_767_225_600
      assert fetched.model_id == "deepseek-chat"
      assert fetched.project_path == "/tmp/r2a-proj"
      assert fetched.branch_name == "genesis/agent_beef"
      assert fetched.ref == nil

      # Datetimes are stored at fixed-ms precision (Codec wire format): the
      # microsecond part does NOT survive, the millisecond part does.
      assert fetched.started_at == ~U[2026-06-26 07:19:44.123Z]
      assert fetched.finished_at == ~U[2026-06-26 08:00:00.999Z]

      assert fetched.opts[:path] == "/tmp/r2a-proj"
      assert fetched.opts[:mode] == "simple"
      assert fetched.opts[:objective] == "fix the bug"

      assert fetched.logs == ["line 1", "line 2"]

      assert {:ok, data} = fetched.result
      assert data.commit_sha == "abc123def"
      assert data.branch_name == "genesis/agent_beef"
      assert data.pr_url == nil
      assert data.result == "Agent summary"

      assert %EvoGit.Agent.Usage{} = fetched.usage
      assert fetched.usage.input_tokens == 100
      assert fetched.usage.total_cost == 0.03
      assert fetched.usage.cache_creation_tokens == 5

      assert fetched.archive_metadata == [%{"agent_id" => "a1", "path" => "/archive/a1"}]
    end

    test "a bare-minimum TaskInfo round-trips with struct defaults intact" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "rt-bare", type: :evolve, status: :pending})
      fetched = Tasks.get_task(repo, "rt-bare")

      assert fetched.status == :pending
      # logs default to [] on decode (never nil) — the LogsJson type contract.
      assert fetched.logs == []
      assert fetched.opts == nil
      assert fetched.result == nil
    end
  end

  # ── REPLACE semantics (the critical property) ───────────────────────────

  describe "put_task replace semantics" do
    test "re-putting the SAME id NULLs columns the new struct omits (INSERT OR REPLACE parity)" do
      repo = start_repo!()

      put!(repo, full_task("replace-1"))

      # Same id, everything the old row carried now nil/empty.
      :ok =
        Tasks.put_task(
          repo,
          %TaskInfo{id: "replace-1", type: :evolve, status: :running, opts: nil}
        )

      fetched = Tasks.get_task(repo, "replace-1")

      assert fetched.status == :running
      assert fetched.branch_name == nil
      assert fetched.project_path == nil
      assert fetched.result == nil
      assert fetched.logs == []
      assert fetched.finished_at == nil
      assert fetched.usage == nil
      assert fetched.archive_metadata == nil
      assert fetched.error == nil
      assert fetched.model_id == nil
      assert fetched.commit_sha == nil
      assert fetched.base_sha == nil
      assert fetched.agent_count == nil
      assert fetched.lease_expires_at == nil
      assert fetched.review_status == nil
    end

    test "two puts then get returns exactly the second task (no residue)" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "same-id", status: :completed, model_id: "m1", type: :genesis})
      put!(repo, %TaskInfo{id: "same-id", status: :failed, model_id: nil, type: :evolve})

      fetched = Tasks.get_task(repo, "same-id")

      assert fetched.status == :failed
      assert fetched.model_id == nil
      assert fetched.type == :evolve
      # Exactly ONE row for the id — replace, not append.
      assert Tasks.count_tasks(repo) == 1
    end

    test "an explicit project_path/branch_name in the struct beats the denormalization" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "explicit-cols",
          type: :evolve,
          status: :completed,
          opts: [path: "/from/opts"],
          project_path: "/explicit/path",
          result: {:ok, %{branch_name: "from/result"}},
          branch_name: "explicit-branch"
        }
      )

      fetched = Tasks.get_task(repo, "explicit-cols")
      assert fetched.project_path == "/explicit/path"
      assert fetched.branch_name == "explicit-branch"
    end
  end

  # ── Denormalizations (raw column assertions) ────────────────────────────

  describe "put_task denormalizations" do
    test "project_path is extracted from opts[:path] into the raw column" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "denorm-path",
          type: :evolve,
          status: :running,
          opts: [path: "/tmp/denorm", mode: "simple"]
        }
      )

      assert raw_row(repo, "denorm-path").project_path == "/tmp/denorm"
    end

    test "branch_name is extracted from an {:ok, %{branch_name: _}} result" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "denorm-branch",
          type: :evolve,
          status: :completed,
          result: {:ok, %{branch_name: "genesis/agent_cafe"}}
        }
      )

      assert raw_row(repo, "denorm-branch").branch_name == "genesis/agent_cafe"
    end

    test "a non-map result contributes no branch_name" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{id: "denorm-none", type: :evolve, status: :failed, result: {:error, "boom"}}
      )

      assert raw_row(repo, "denorm-none").branch_name == nil
    end

    test "updated_at is bumped on re-put and stored as a fixed-ms ISO string" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "ts-1", type: :evolve, status: :running})
      first = raw_row(repo, "ts-1").updated_at

      assert is_binary(first)
      # Fixed-millisecond precision: exactly 3 fractional digits + "Z".
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, first)
      assert {:ok, first_dt, _} = DateTime.from_iso8601(first)

      # A re-put bumps updated_at (sleep past 1ms so the stamps differ).
      Process.sleep(5)
      put!(repo, %TaskInfo{id: "ts-1", type: :evolve, status: :completed})
      second = raw_row(repo, "ts-1").updated_at

      assert {:ok, second_dt, _} = DateTime.from_iso8601(second)
      assert DateTime.compare(second_dt, first_dt) == :gt
    end
  end

  # ── get missing / validation shapes ─────────────────────────────────────

  describe "get_task/2 missing row" do
    test "returns nil for an unknown id (old handler shape)" do
      repo = start_repo!()
      assert Tasks.get_task(repo, "nope") == nil
    end
  end

  describe "put_task/2 validation errors" do
    test "returns {:error, :missing_task_id} without writing" do
      repo = start_repo!()

      assert Tasks.put_task(repo, %TaskInfo{id: nil, status: :running}) ==
               {:error, :missing_task_id}

      assert Tasks.count_tasks(repo) == 0
    end

    test "returns {:error, :missing_task_status} without writing" do
      repo = start_repo!()

      assert Tasks.put_task(repo, %TaskInfo{id: "s", status: nil}) ==
               {:error, :missing_task_status}

      assert Tasks.count_tasks(repo) == 0
    end
  end

  # ── deletes ─────────────────────────────────────────────────────────────

  describe "delete_task/2" do
    test "deletes an existing row and returns :ok" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "del-1", type: :evolve, status: :pending})

      assert Tasks.delete_task(repo, "del-1") == :ok
      assert Tasks.get_task(repo, "del-1") == nil
      assert Tasks.count_tasks(repo) == 0
    end

    test "returns :ok for a missing id (no-op delete)" do
      repo = start_repo!()
      assert Tasks.delete_task(repo, "missing") == :ok
      assert Tasks.count_tasks(repo) == 0
    end
  end

  describe "delete_tasks/2" do
    test "deletes multiple ids and returns :ok" do
      repo = start_repo!()

      for i <- 1..3, do: put!(repo, %TaskInfo{id: "multi-#{i}", type: :evolve, status: :pending})
      put!(repo, %TaskInfo{id: "keep", type: :evolve, status: :pending})

      assert Tasks.delete_tasks(repo, ["multi-1", "multi-2", "multi-3"]) == :ok
      assert Tasks.count_tasks(repo) == 1
      assert Tasks.get_task(repo, "keep") != nil
    end

    test "handles an empty id list (writes nothing)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "stay", type: :evolve, status: :pending})

      assert Tasks.delete_tasks(repo, []) == :ok
      assert Tasks.count_tasks(repo) == 1
    end

    test "501 ids are chunked (2 statements of 500+1) and all rows go" do
      repo = start_repo!()

      ids = Enum.map(1..501, &"chunk-#{&1}")
      # Minimal rows: id + status only — the leanest seed that still exercises
      # the full typed write path.
      Enum.each(ids, fn id ->
        :ok = Tasks.put_task(repo, %TaskInfo{id: id, type: :evolve, status: :pending})
      end)

      assert Tasks.count_tasks(repo) == 501

      assert Tasks.delete_tasks(repo, ids) == :ok
      assert Tasks.count_tasks(repo) == 0
    end
  end

  # ── select_all_tasks / count_tasks / clear_tasks ─────────────────────────

  describe "select_all_tasks/1" do
    test "returns every task as TaskInfo structs" do
      repo = start_repo!()
      put!(repo, full_task("all-1"))
      put!(repo, %TaskInfo{id: "all-2", type: :evolve, status: :pending})

      tasks = Tasks.select_all_tasks(repo)

      assert length(tasks) == 2
      assert Enum.all?(tasks, &is_struct(&1, TaskInfo))
      ids = tasks |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["all-1", "all-2"]

      by_id = Map.new(tasks, fn t -> {t.id, t} end)
      assert by_id["all-1"].branch_name == "genesis/agent_beef"
      assert by_id["all-2"].status == :pending
    end

    test "returns [] for an empty table" do
      repo = start_repo!()
      assert Tasks.select_all_tasks(repo) == []
    end
  end

  describe "count_tasks/1" do
    test "counts rows" do
      repo = start_repo!()
      assert Tasks.count_tasks(repo) == 0

      for i <- 1..4, do: put!(repo, %TaskInfo{id: "c-#{i}", type: :evolve, status: :pending})
      assert Tasks.count_tasks(repo) == 4
    end
  end

  describe "clear_tasks/1" do
    test "deletes every row and returns :ok" do
      repo = start_repo!()
      put!(repo, full_task("clear-1"))
      put!(repo, %TaskInfo{id: "clear-2", type: :evolve, status: :pending})

      assert Tasks.clear_tasks(repo) == :ok
      assert Tasks.count_tasks(repo) == 0
      assert Tasks.select_all_tasks(repo) == []
    end
  end

  # ── safe_select_paginated_tasks/2 ────────────────────────────────────────

  describe "safe_select_paginated_tasks/2 filters" do
    test "status filter alone matches the stored TEXT spelling" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "pg-run", type: :evolve, status: :running})
      put!(repo, %TaskInfo{id: "pg-done", type: :evolve, status: :completed})

      {tasks, total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [status: "completed"])

      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["pg-done"]
    end

    test "project_path filter alone" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "pg-a", type: :evolve, status: :pending, opts: [path: "/p/a"]})
      put!(repo, %TaskInfo{id: "pg-b", type: :evolve, status: :pending, opts: [path: "/p/b"]})

      {tasks, total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [project_path: "/p/a"])

      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["pg-a"]
      assert hd(tasks).project_path == "/p/a"
    end

    test "review_status filter: literal value matches the column" do
      repo = start_repo!()
      put!(repo, full_task("pg-rv") |> struct(review_status: :merged))
      put!(repo, %TaskInfo{id: "pg-rv-none", type: :evolve, status: :completed})

      {tasks, total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [review_status: "merged"])

      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["pg-rv"]
    end

    test "review_status 'pending' is the COMPOSITE (completed + NULL review + branch_name NOT NULL)" do
      repo = start_repo!()

      # In the composite: completed, no review_status, branch present.
      put!(
        repo,
        %TaskInfo{
          id: "pg-pend-hit",
          type: :evolve,
          status: :completed,
          branch_name: "genesis/agent_1"
        }
      )

      # Excluded: running (status not completed) — even though branch present.
      put!(
        repo,
        %TaskInfo{
          id: "pg-pend-running",
          type: :evolve,
          status: :running,
          branch_name: "genesis/agent_2"
        }
      )

      # Excluded: completed + review_status set.
      put!(
        repo,
        %TaskInfo{
          id: "pg-pend-reviewed",
          type: :evolve,
          status: :completed,
          review_status: :merged,
          branch_name: "genesis/agent_3"
        }
      )

      # Excluded: completed + no review, but NO branch_name.
      put!(repo, %TaskInfo{id: "pg-pend-nobranch", type: :evolve, status: :completed})

      {tasks, total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [review_status: "pending"])

      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["pg-pend-hit"]
    end

    test "combined filters AND together" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "pg-combo-hit",
          type: :evolve,
          status: :completed,
          opts: [path: "/combo"],
          branch_name: "genesis/agent_x"
        }
      )

      put!(
        repo,
        %TaskInfo{
          id: "pg-combo-miss",
          type: :evolve,
          status: :running,
          opts: [path: "/combo"]
        }
      )

      put!(
        repo,
        %TaskInfo{
          id: "pg-combo-other-path",
          type: :evolve,
          status: :completed,
          opts: [path: "/other"],
          branch_name: "genesis/agent_y"
        }
      )

      {tasks, total} =
        Tasks.safe_select_paginated_tasks(repo,
          filters: [status: "completed", project_path: "/combo", review_status: "pending"]
        )

      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["pg-combo-hit"]
    end

    test "search matches id, opts JSON, project_path, and result text" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "find-this-id", type: :evolve, status: :pending})

      put!(
        repo,
        %TaskInfo{
          id: "by-opts",
          type: :evolve,
          status: :pending,
          opts: [objective: "needle in objective"]
        }
      )

      put!(
        repo,
        %TaskInfo{
          id: "by-path",
          type: :evolve,
          status: :pending,
          opts: [path: "/proj/needle-dir"]
        }
      )

      put!(
        repo,
        %TaskInfo{
          id: "by-result",
          type: :evolve,
          status: :completed,
          result: {:ok, %{result: "the needle summary", branch_name: "genesis/agent_n"}}
        }
      )

      put!(repo, %TaskInfo{id: "no-hit", type: :evolve, status: :pending})

      {by_id, total} = Tasks.safe_select_paginated_tasks(repo, filters: [search: "find-this-id"])
      assert total == 1
      assert Enum.map(by_id, & &1.id) == ["find-this-id"]

      {by_opts, _} =
        Tasks.safe_select_paginated_tasks(repo, filters: [search: "needle in objective"])

      assert Enum.map(by_opts, & &1.id) == ["by-opts"]

      {by_path, _} = Tasks.safe_select_paginated_tasks(repo, filters: [search: "needle-dir"])
      assert Enum.map(by_path, & &1.id) == ["by-path"]

      {by_result, _} =
        Tasks.safe_select_paginated_tasks(repo, filters: [search: "needle summary"])

      assert Enum.map(by_result, & &1.id) == ["by-result"]

      # Empty search string = no clause at all (everything matches).
      {all, all_total} = Tasks.safe_select_paginated_tasks(repo, filters: [search: ""])
      assert all_total == 5
      assert length(all) == 5
    end

    test "search escapes % and _ — they match LITERALLY, not as wildcards" do
      repo = start_repo!()

      # Literal underscore in id: must NOT match a needle where _ sits in a
      # different position (an unescaped _ would match any char).
      put!(repo, %TaskInfo{id: "task_alpha", type: :evolve, status: :pending})
      put!(repo, %TaskInfo{id: "taskXalpha", type: :evolve, status: :pending})

      {tasks, total} = Tasks.safe_select_paginated_tasks(repo, filters: [search: "task_alpha"])
      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["task_alpha"]

      # Literal percent: an unescaped % would match "pct100Xdone" and
      # "pct100done" as well (a % wildcard eats any suffix).
      put!(repo, %TaskInfo{id: "pct100%done", type: :evolve, status: :pending})
      put!(repo, %TaskInfo{id: "pct100Xdone", type: :evolve, status: :pending})

      {pct_tasks, pct_total} = Tasks.safe_select_paginated_tasks(repo, filters: [search: "100%d"])
      assert pct_total == 1
      assert Enum.map(pct_tasks, & &1.id) == ["pct100%done"]
    end

    test "search escapes a literal backslash — it matches literally, never as the ESCAPE char" do
      repo = start_repo!()

      # A literal backslash in project_path: with the ported escape_like/1 the
      # search needle "a\\b" becomes "a\\\\b" and matches ONLY the literal
      # "a\b" path — the ESCAPE '\' clause consumes the doubled backslash. (An
      # unescaped backslash would pair with the following char and fail to
      # match anything.)
      put!(repo, %TaskInfo{id: "bs-lit", type: :evolve, status: :pending, opts: [path: "a\\b"]})
      put!(repo, %TaskInfo{id: "bs-plain", type: :evolve, status: :pending, opts: [path: "ab"]})

      {tasks, total} = Tasks.safe_select_paginated_tasks(repo, filters: [search: "a\\b"])
      assert total == 1
      assert Enum.map(tasks, & &1.id) == ["bs-lit"]
      assert hd(tasks).project_path == "a\\b"
    end

    test "ORDER BY started_at DESC (newest first)" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "old",
          type: :evolve,
          status: :completed,
          started_at: ~U[2026-01-01 00:00:00.000Z]
        }
      )

      put!(
        repo,
        %TaskInfo{
          id: "newest",
          type: :evolve,
          status: :completed,
          started_at: ~U[2026-03-01 00:00:00.000Z]
        }
      )

      put!(
        repo,
        %TaskInfo{
          id: "middle",
          type: :evolve,
          status: :completed,
          started_at: ~U[2026-02-01 00:00:00.000Z]
        }
      )

      {tasks, _total} = Tasks.safe_select_paginated_tasks(repo, [])
      assert Enum.map(tasks, & &1.id) == ["newest", "middle", "old"]
    end

    test "limit/offset paginate the result; total_count stays the FILTERED total" do
      repo = start_repo!()

      for i <- 1..5,
          do:
            put!(
              repo,
              %TaskInfo{
                id: "page-#{i}",
                type: :evolve,
                status: :running,
                started_at: ~U[2026-01-01 00:00:00.000Z] |> DateTime.add(i, :second)
              }
            )

      put!(repo, %TaskInfo{id: "other-status", type: :evolve, status: :completed})

      {page1, total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [status: "running"], limit: 2, offset: 0)

      assert total == 5
      assert Enum.map(page1, & &1.id) == ["page-5", "page-4"]

      {page2, ^total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [status: "running"], limit: 2, offset: 2)

      assert Enum.map(page2, & &1.id) == ["page-3", "page-2"]

      {page3, ^total} =
        Tasks.safe_select_paginated_tasks(repo, filters: [status: "running"], limit: 2, offset: 4)

      assert Enum.map(page3, & &1.id) == ["page-1"]
    end

    test "limit/offset clamps + defaults (nil → 50/0, invalid → 50/0)" do
      repo = start_repo!()

      for i <- 1..3,
          do: put!(repo, %TaskInfo{id: "clamp-#{i}", type: :evolve, status: :pending})

      # nil limit/offset → defaults 50/0 — all rows come back.
      {tasks, total} = Tasks.safe_select_paginated_tasks(repo, [])
      assert {length(tasks), total} == {3, 3}

      # Non-integer / non-positive limit → 50; negative offset → 0.
      {tasks2, _} = Tasks.safe_select_paginated_tasks(repo, limit: "x", offset: -7)
      assert length(tasks2) == 3

      # limit 0 → default 50 (not "nothing").
      {tasks3, _} = Tasks.safe_select_paginated_tasks(repo, limit: 0)
      assert length(tasks3) == 3
    end

    test "empty DB returns {[], 0}" do
      repo = start_repo!()
      assert Tasks.safe_select_paginated_tasks(repo, filters: [status: "running"]) == {[], 0}
    end

    test "an undecodable row is SKIPPED from the page but still COUNTED" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "good-1", type: :evolve, status: :completed})
      put!(repo, %TaskInfo{id: "good-2", type: :evolve, status: :completed})

      # Corrupt the opts JSON of one row directly (raw write — no type casting).
      RepoScope.with_repo(repo, fn ->
        Repo.update_all(
          from(t in TaskRowRaw, where: t.id == "good-2"),
          set: [opts: "not-json-object"]
        )
      end)

      {tasks, total} = Tasks.safe_select_paginated_tasks(repo, [])

      # COUNT(*) counts rows, never decodes them — the bad row is included in
      # the total but excluded from the decoded page (skip-and-log boundary).
      assert total == 2
      assert Enum.map(tasks, & &1.id) == ["good-1"]
    end
  end

  # ── update_lease_expires_at/3 ─────────────────────────────────────────────

  describe "update_lease_expires_at/3" do
    test "writes the value and does NOT bump updated_at (raw-select both)" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "lease-1", type: :evolve, status: :running, lease_expires_at: 111})
      before_row = raw_row(repo, "lease-1")
      assert before_row.lease_expires_at == 111

      # Sleep past 1ms so an updated_at bump would be detectable.
      Process.sleep(5)

      assert Tasks.update_lease_expires_at(repo, "lease-1", 999_999) == :ok

      after_row = raw_row(repo, "lease-1")
      assert after_row.lease_expires_at == 999_999
      # THE invariant: the 60s heartbeat must not mark tasks dirty.
      assert after_row.updated_at == before_row.updated_at
    end

    test "nil clears the lease; a missing id is a no-op :ok" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "lease-2", type: :evolve, status: :running, lease_expires_at: 5})

      assert Tasks.update_lease_expires_at(repo, "lease-2", nil) == :ok
      assert raw_row(repo, "lease-2").lease_expires_at == nil

      assert Tasks.update_lease_expires_at(repo, "missing", 42) == :ok
      assert Tasks.get_task(repo, "missing") == nil
    end
  end

  # ── update_task_columns/3 ────────────────────────────────────────────────

  describe "update_task_columns/3" do
    test "status ATOM is dumped to the stored TEXT spelling (type-dumping evidence)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "cols-1", type: :evolve, status: :running})

      assert Tasks.update_task_columns(repo, "cols-1", status: :completed) == :ok

      # RAW select — the exact bytes SQLite stored, no type casting.
      row = raw_row(repo, "cols-1")
      assert row.status == "completed"
      assert is_binary(row.status)
    end

    test "DateTime is dumped to the fixed-millisecond ISO string" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "cols-2", type: :evolve, status: :running})

      dt = ~U[2026-06-26 10:11:12.987654Z]

      assert Tasks.update_task_columns(repo, "cols-2", finished_at: dt) == :ok

      # µs truncated to ms — the Codec wire format (24-char ISO).
      assert raw_row(repo, "cols-2").finished_at == "2026-06-26T10:11:12.987Z"
    end

    test "result and opts JSON columns re-encode round-trip" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "cols-3", type: :evolve, status: :running})

      result = {:ok, %{commit_sha: "abc", branch_name: "genesis/agent_z", result: "sum"}}
      opts = [path: "/rt", mode: "simple", objective: "obj"]

      assert Tasks.update_task_columns(repo, "cols-3", result: result, opts: opts) == :ok

      fetched = Tasks.get_task(repo, "cols-3")
      assert {:ok, data} = fetched.result
      assert data.commit_sha == "abc"
      assert data.branch_name == "genesis/agent_z"
      # opts keys come back in the Codec's canonical JSON round-trip order.
      assert Enum.sort(fetched.opts) == Enum.sort(opts)
      assert fetched.opts[:path] == "/rt"
      assert fetched.opts[:mode] == "simple"
      assert fetched.opts[:objective] == "obj"
    end

    test "updated_at is ALWAYS bumped (even when nothing else changes)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "cols-4", type: :evolve, status: :running})
      first = raw_row(repo, "cols-4").updated_at

      Process.sleep(5)
      assert Tasks.update_task_columns(repo, "cols-4", []) == :ok

      second = raw_row(repo, "cols-4").updated_at
      assert is_binary(second)
      assert {:ok, first_dt, _} = DateTime.from_iso8601(first)
      assert {:ok, second_dt, _} = DateTime.from_iso8601(second)
      assert DateTime.compare(second_dt, first_dt) == :gt
    end

    test "nil values write SQL NULL — the nil guard fires BEFORE the per-column encoder" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "cols-nil",
          type: :evolve,
          status: :running,
          opts: [path: "/nil"],
          logs: ["first"],
          review_status: :merged
        }
      )

      # `logs: nil` must become SQL NULL — NOT Codec.encode_logs(nil)'s "[]"
      # (the default the put path applies); `review_status: nil` → NULL too,
      # never Codec.encode_atom/1 output. The encode_column_value/2 nil clause
      # is checked FIRST, for EVERY column family.
      assert Tasks.update_task_columns(repo, "cols-nil",
               logs: nil,
               review_status: nil,
               result: nil,
               opts: nil
             ) == :ok

      row = raw_row(repo, "cols-nil")
      assert is_nil(row.logs)
      assert is_nil(row.review_status)
      assert is_nil(row.result)
      assert is_nil(row.opts)
    end

    test "an unknown column raises a descriptive ArgumentError (no silent write)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "cols-5", type: :evolve, status: :running})

      assert_raise ArgumentError, ~r/unknown task column :typo/, fn ->
        Tasks.update_task_columns(repo, "cols-5", typo: "x")
      end

      # Nothing was written (updated_at NOT bumped either — the raise happens
      # before the statement).
      assert raw_row(repo, "cols-5").status == "running"
    end

    test "a missing-id update is a no-op :ok (0 rows)" do
      repo = start_repo!()
      assert Tasks.update_task_columns(repo, "missing", status: :completed) == :ok
      assert Tasks.count_tasks(repo) == 0
    end
  end

  # ── get_task_status / select_task_logs / select_task_update_info ──────────

  describe "get_task_status/2" do
    test "returns the decoded atom for an existing row" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "st-1", type: :evolve, status: :cancelling})
      assert Tasks.get_task_status(repo, "st-1") == :cancelling
    end

    test "returns nil for a missing row" do
      repo = start_repo!()
      assert Tasks.get_task_status(repo, "nope") == nil
    end
  end

  describe "select_task_logs/2" do
    test "returns the decoded list for an existing row" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "lg-1", type: :evolve, status: :running, logs: ["a", "b"]})
      assert Tasks.select_task_logs(repo, "lg-1") == ["a", "b"]
    end

    test "a NULL logs column decodes to [] (lenient Codec semantics)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "lg-2", type: :evolve, status: :running})
      assert Tasks.select_task_logs(repo, "lg-2") == []
    end

    test "returns nil for a missing row" do
      repo = start_repo!()
      assert Tasks.select_task_logs(repo, "nope") == nil
    end
  end

  describe "select_task_update_info/2" do
    test "returns the 4-key narrow map for an existing row" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "ui-1",
          type: :evolve,
          status: :running,
          opts: [path: "/ui", mode: "simple"],
          finished_at: ~U[2026-06-26 09:00:00.500Z],
          lease_expires_at: 1_767_225_600
        }
      )

      assert info = Tasks.select_task_update_info(repo, "ui-1")
      assert map_size(info) == 4
      assert info.status == :running
      # opts keys come back in the Codec's canonical JSON round-trip order.
      assert Enum.sort(info.opts) == Enum.sort(path: "/ui", mode: "simple")
      assert info.finished_at == ~U[2026-06-26 09:00:00.500Z]
      assert info.lease_expires_at == 1_767_225_600
    end

    test "nil opts/finished_at/lease come back nil (not defaults)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "ui-2", type: :evolve, status: :pending})

      assert Tasks.select_task_update_info(repo, "ui-2") == %{
               status: :pending,
               opts: nil,
               finished_at: nil,
               lease_expires_at: nil
             }
    end

    test "returns nil for a missing row" do
      repo = start_repo!()
      assert Tasks.select_task_update_info(repo, "nope") == nil
    end
  end
end
