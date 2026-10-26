defmodule EvoGit.Store.Operations.PagesTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Pages` — the LIGHTWEIGHT task read API
  (`select_tasks_page/2`, `get_task_lite/2`, `get_task_archive/2`) and the
  shared search-filter change it ships with.

  Pinned contracts:

    * `select_tasks_page/2` returns EXACTLY `%{rows: [summary], total: n}`; each
      row is the canonical 16-key summary projection (no `result`,
      `archive_metadata`, `logs` or `usage` key) — a multi-megabyte `result`
      row costs the same as an empty one;
    * filter parity with `Operations.Tasks.safe_select_paginated_tasks/2`: the
      same rows, in the same `started_at DESC` order, with the same total, for
      every filter (status / project_path / review_status / search /
      combinations);
    * page clamps: limit defaults to 25 and caps at 50, offset is never
      negative, and an offset past the end refetches the LAST page;
    * `get_task_lite/2` is field-identical to `Tasks.get_task/2` except
      `archive_metadata: nil` and no `:archive_records` in the result;
    * `get_task_archive/2` returns `[]` (never raises) for a missing row, a
      NULL column or an undecodable payload;
    * search now matches `id`/`opts`/`project_path`/`branch_name` and NO LONGER
      matches `result` (it is zlib-compressed above 4 kB — a full-blob scan
      with no user-visible substrings).

  Every test boots its own UNNAMED dynamic repo on a unique tmp SQLite file
  (`async: true` is safe — `EvoGit.Store.Boot` serializes migration runs with a
  `:global` lock), mirroring `operations/summaries_test.exs` +
  `operations/tasks_test.exs`.
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Pages
  alias EvoGit.Store.Operations.Tasks
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo

  @summary_keys [
    :id,
    :status,
    :review_status,
    :started_at,
    :finished_at,
    :type,
    :project_path,
    :opts,
    :branch_name,
    :model_id,
    :agent_count,
    :base_sha,
    :commit_sha,
    :lease_expires_at,
    :updated_at,
    :error
  ]

  @base_started ~U[2026-01-01 00:00:00.000Z]

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Unique-per-call database file, then an unnamed dynamic repo. The name embeds
  # the OS pid + wall-clock ms on top of the per-BEAM counter so a PREVIOUS run's
  # stale tmp file can never be adopted.
  defp start_repo!(tag) do
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_pages_#{tag}_#{System.pid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}.sqlite"
      )

    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok

      File.rm(path)
      File.rm(path <> "-wal")
      File.rm(path <> "-shm")
    end)

    pid
  end

  defp put!(repo, %TaskInfo{} = task) do
    :ok = Tasks.put_task(repo, task)
    task.id
  end

  # Inserts a task with a deterministic `started_at` (index 0 = oldest), so
  # `ORDER BY started_at DESC` yields the reverse insertion order.
  defp put_timed!(repo, id, i, overrides \\ []) do
    defaults = [
      id: id,
      type: :evolve,
      status: :completed,
      opts: [path: "/pages/proj", objective: "objective #{i}"],
      started_at: DateTime.add(@base_started, i, :second),
      finished_at: DateTime.add(@base_started, i + 1, :second),
      logs: [],
      result: {:ok, %{commit_sha: "sha-#{i}", branch_name: "genesis/agent_#{i}"}},
      agent_count: 1
    ]

    put!(repo, struct!(TaskInfo, Keyword.merge(defaults, overrides)))
  end

  defp page_ids(repo, opts) do
    %{rows: rows} = Pages.select_tasks_page(repo, opts)
    Enum.map(rows, & &1.id)
  end

  defp legacy(repo, opts) do
    Tasks.safe_select_paginated_tasks(repo, opts)
  end

  # ── Projection + totals ─────────────────────────────────────────────────

  describe "select_tasks_page/2 — return shape" do
    test "returns exactly %{rows, total} with 16-key summary rows" do
      repo = start_repo!(:shape)

      for i <- 0..2, do: put_timed!(repo, "page-#{i}", i)

      result = Pages.select_tasks_page(repo, [])

      assert Map.keys(result) |> Enum.sort() == [:rows, :total]
      assert result.total == 3
      assert length(result.rows) == 3

      for row <- result.rows do
        assert Map.keys(row) |> Enum.sort() == Enum.sort(@summary_keys)

        for absent <- [:result, :archive_metadata, :logs, :usage] do
          refute Map.has_key?(row, absent), "summary row must not carry #{inspect(absent)}"
        end
      end

      # …and the decoded values match the legacy summary projection field for
      # field (the same canonical query).
      assert Enum.at(result.rows, 0).id == "page-2"
      assert Enum.at(result.rows, 0).status == :completed
      assert Enum.at(result.rows, 0).branch_name == "genesis/agent_2"
      assert Enum.at(result.rows, 0).project_path == "/pages/proj"
      assert %DateTime{} = Enum.at(result.rows, 0).started_at
      assert is_binary(Enum.at(result.rows, 0).updated_at)
    end

    test "empty DB returns %{rows: [], total: 0}" do
      repo = start_repo!(:empty)

      assert Pages.select_tasks_page(repo, []) == %{rows: [], total: 0}
      assert Pages.select_tasks_page(repo, filters: [status: "running"]) == %{rows: [], total: 0}
      assert Pages.select_tasks_page(repo, limit: 0, offset: 999) == %{rows: [], total: 0}
    end

    test "ORDER BY started_at DESC — same ids in the same order as the legacy page" do
      repo = start_repo!(:order)

      for i <- 0..4, do: put_timed!(repo, "order-#{i}", i)

      assert page_ids(repo, limit: 10, offset: 0) ==
               ["order-4", "order-3", "order-2", "order-1", "order-0"]

      {legacy_rows, 5} = legacy(repo, limit: 10, offset: 0)
      assert Enum.map(legacy_rows, & &1.id) == page_ids(repo, limit: 10, offset: 0)

      # Slicing agrees too.
      assert page_ids(repo, limit: 2, offset: 2) == ["order-2", "order-1"]

      {legacy_page, 5} = legacy(repo, limit: 2, offset: 2)
      assert Enum.map(legacy_page, & &1.id) == page_ids(repo, limit: 2, offset: 2)
    end
  end

  # ── Filter parity with the legacy FULL-row page ─────────────────────────

  describe "select_tasks_page/2 — filter parity with safe_select_paginated_tasks/2" do
    setup do
      repo = start_repo!(:filters)

      # 6 completed + 3 failed rows across 2 project paths, mixed review
      # statuses and branch names.
      for i <- 0..5,
          do:
            put_timed!(repo, "comp-#{i}", i,
              status: :completed,
              opts: [path: "/proj/alpha", objective: "alpha task #{i}"],
              review_status: if(rem(i, 2) == 0, do: :merged, else: nil),
              branch_name: if(rem(i, 2) == 1, do: "genesis/agent_alpha_#{i}", else: nil)
            )

      for i <- 6..8,
          do:
            put_timed!(repo, "fail-#{i}", i,
              status: :failed,
              opts: [path: "/proj/beta", objective: "beta task #{i}"],
              result: nil,
              branch_name: nil
            )

      {:ok, %{repo: repo}}
    end

    @filter_sets [
      [],
      [status: "completed"],
      [status: "failed"],
      [status: "all"],
      [project_path: "/proj/alpha"],
      [project_path: "/proj/beta"],
      [review_status: "merged"],
      [review_status: "pending"],
      [search: "alpha"],
      [search: "beta task 8"],
      [search: "agent_alpha_3"],
      [search: "comp-2"],
      [status: "completed", project_path: "/proj/alpha"],
      [status: "completed", review_status: "merged", search: "alpha"]
    ]

    test "every filter set matches the legacy page (rows + total)", %{repo: repo} do
      for filters <- @filter_sets do
        %{rows: rows, total: total} = Pages.select_tasks_page(repo, filters: filters, limit: 50)
        {legacy_rows, legacy_total} = legacy(repo, filters: filters, limit: 50, offset: 0)

        assert Enum.map(rows, & &1.id) == Enum.map(legacy_rows, & &1.id),
               "row mismatch for filters #{inspect(filters)}"

        assert total == legacy_total,
               "total mismatch for filters #{inspect(filters)}"
      end
    end

    test "top-level filter keys are equivalent to the nested :filters shape", %{repo: repo} do
      nested = Pages.select_tasks_page(repo, filters: [status: "failed"], limit: 10)
      flat = Pages.select_tasks_page(repo, status: "failed", limit: 10)

      assert flat.total == nested.total
      assert flat.rows == nested.rows

      # A top-level key wins over the nested one.
      both = Pages.select_tasks_page(repo, filters: [status: "failed"], status: "completed")
      assert both.total == 6
    end

    test "offset is clamped (nil/negative/non-integer → 0)", %{repo: repo} do
      expected = page_ids(repo, limit: 3, offset: 0)

      for bad <- [nil, -7, "x"] do
        assert page_ids(repo, limit: 3, offset: bad) == expected
      end
    end

    test "an undecodable row is SKIPPED from the page but still COUNTED", %{repo: repo} do
      # Same skip-and-log boundary as the legacy page (the summary decode is
      # shared): a corrupt `opts` JSON drops the row from `rows`, while the
      # SQL-level COUNT still includes it.
      RepoScope.with_repo(repo, fn ->
        Repo.update_all(from(t in TaskRowRaw, where: t.id == "fail-6"),
          set: [opts: "not-json-object"]
        )
      end)

      %{rows: rows, total: total} = Pages.select_tasks_page(repo, filters: [status: "failed"])

      assert total == 3
      refute "fail-6" in Enum.map(rows, & &1.id)
      assert length(rows) == 2

      {legacy_rows, 3} = legacy(repo, filters: [status: "failed"], limit: 50, offset: 0)
      assert Enum.map(rows, & &1.id) == Enum.map(legacy_rows, & &1.id)
    end
  end

  # ── Page clamps ─────────────────────────────────────────────────────────

  describe "select_tasks_page/2 — limit/offset clamps" do
    setup do
      repo = start_repo!(:clamps)
      for i <- 1..60, do: put_timed!(repo, "clamp-#{i}", i)
      {:ok, %{repo: repo}}
    end

    test "no limit → default 25 rows", %{repo: repo} do
      %{rows: rows, total: 60} = Pages.select_tasks_page(repo, [])
      assert length(rows) == 25
      assert hd(rows).id == "clamp-60"
    end

    test "limit is capped at 50; smaller positive limits are honored", %{repo: repo} do
      assert %{rows: rows, total: 60} = Pages.select_tasks_page(repo, limit: 999)
      assert length(rows) == 50

      assert length(Pages.select_tasks_page(repo, limit: 50).rows) == 50
      assert length(Pages.select_tasks_page(repo, limit: 25).rows) == 25
      assert length(Pages.select_tasks_page(repo, limit: 1).rows) == 1
    end

    test "invalid/non-positive limits fall back to the default 25", %{repo: repo} do
      for bad <- [0, -5, nil, "x", 2.5] do
        assert length(Pages.select_tasks_page(repo, limit: bad).rows) == 25,
               "expected the 25-row default for limit #{inspect(bad)}"
      end
    end

    test "an offset past the end refetches the LAST page", %{repo: repo} do
      # 60 rows, limit 25 → pages at offsets 0, 25, 50. Offset 9999 clamps to the
      # LAST page (offset 50), not an empty page.
      %{rows: rows, total: 60} = Pages.select_tasks_page(repo, limit: 25, offset: 9999)
      assert length(rows) == 10
      assert Enum.map(rows, & &1.id) == page_ids(repo, limit: 25, offset: 50)

      # Offset exactly at the end is "past the end" too.
      assert page_ids(repo, limit: 25, offset: 60) == page_ids(repo, limit: 25, offset: 50)

      # …while an in-range offset is honored verbatim (no refetch): 60 rows,
      # newest first, so offset 25 starts at clamp-35.
      in_range = Pages.select_tasks_page(repo, limit: 25, offset: 25).rows
      assert length(in_range) == 25
      assert hd(in_range).id == "clamp-35"
      assert List.last(in_range).id == "clamp-11"
    end
  end

  # ── Big blobs: page rows never carry them ───────────────────────────────

  describe "heavy JSON blobs" do
    @big_bytes 5_000_000

    defp big_task(id) do
      big_text = String.duplicate("x", @big_bytes) <> "ZZRESULTONLYZZ"
      archive = [%{"role" => "user", "content" => String.duplicate("a", @big_bytes)}]

      %TaskInfo{
        id: id,
        type: :evolve,
        status: :completed,
        opts: [path: "/pages/big", objective: "heavy row"],
        started_at: @base_started,
        finished_at: DateTime.add(@base_started, 60, :second),
        logs: ["heavy"],
        result:
          {:ok,
           %{
             result: big_text,
             commit_sha: "abc123",
             branch_name: "genesis/agent_big",
             archive_records: [%{role: "assistant", content: "archived conversation"}]
           }},
        archive_metadata: archive,
        agent_count: 1,
        model_id: "big-model"
      }
    end

    test "the summary page returns the healthy row without decoding any blob" do
      repo = start_repo!(:big)
      id = put!(repo, big_task("big-row"))

      %{rows: [row], total: 1} = Pages.select_tasks_page(repo, [])

      assert Map.keys(row) |> Enum.sort() == Enum.sort(@summary_keys)
      assert row.id == id
      assert row.branch_name == "genesis/agent_big"

      # The whole served row is tiny — the 10 MB of blobs never reached it.
      assert byte_size(:erlang.term_to_binary(row)) < 10_000
    end

    test "get_task_lite/2 drops archive_metadata + :archive_records, everything else identical" do
      repo = start_repo!(:lite)
      id = put!(repo, big_task("big-lite"))

      lite = Pages.get_task_lite(repo, id)
      full = Tasks.get_task(repo, id)

      assert %TaskInfo{} = lite
      assert lite.id == id
      assert lite.archive_metadata == nil

      # Every OTHER field is decoded exactly like get_task/2.
      assert %{lite | archive_metadata: nil, result: nil} ==
               %{full | archive_metadata: nil, result: nil}

      # The archive column is genuinely there in the full read …
      assert [%{"role" => "user", "content" => content}] = full.archive_metadata
      assert byte_size(content) == @big_bytes

      # … and the result's archive_records survive only in the full read.
      assert {:ok, full_data} = full.result
      assert Map.has_key?(full_data, :archive_records)

      assert {:ok, lite_data} = lite.result
      refute Map.has_key?(lite_data, :archive_records)
      assert lite_data.commit_sha == "abc123"
      assert lite_data.branch_name == "genesis/agent_big"
      assert lite_data.result == String.duplicate("x", @big_bytes) <> "ZZRESULTONLYZZ"

      # Structurally cheaper: the archive blob no longer rides along.
      lite_bytes = byte_size(:erlang.term_to_binary(lite))
      full_bytes = byte_size(:erlang.term_to_binary(full))
      assert lite_bytes < full_bytes
      assert full_bytes - lite_bytes >= @big_bytes
    end

    test "get_task_archive/2 returns the decoded archive list, [] when absent" do
      repo = start_repo!(:archive)
      id = put!(repo, big_task("big-archive"))

      assert [%{"role" => "user", "content" => content}] = Pages.get_task_archive(repo, id)
      assert byte_size(content) == @big_bytes

      # Missing row → [].
      assert Pages.get_task_archive(repo, "no-such-task") == []

      # NULL column → [].
      put!(repo, %TaskInfo{id: "no-archive", type: :evolve, status: :completed})
      assert Pages.get_task_archive(repo, "no-archive") == []

      # Undecodable payload → [] (never raises).
      RepoScope.with_repo(repo, fn ->
        Repo.update_all(from(t in TaskRowRaw, where: t.id == "no-archive"),
          set: [archive_metadata: "not-a-json-list"]
        )
      end)

      assert Pages.get_task_archive(repo, "no-archive") == []

      # get_task_lite/2 on a missing row → nil.
      assert Pages.get_task_lite(repo, "no-such-task") == nil
    end
  end

  # ── Search behaviour change ─────────────────────────────────────────────

  describe "search filter" do
    test "branch_name is now searched" do
      repo = start_repo!(:search_branch)

      put_timed!(repo, "branch-hit", 0, branch_name: "genesis/agent_zz9q", result: nil)
      put_timed!(repo, "branch-miss", 1, branch_name: "genesis/agent_other", result: nil)

      %{rows: rows, total: 1} = Pages.select_tasks_page(repo, search: "zz9q")
      assert Enum.map(rows, & &1.id) == ["branch-hit"]

      # Parity with the legacy page (both go through the shared WHERE builder).
      {legacy_rows, 1} = legacy(repo, filters: [search: "zz9q"])
      assert Enum.map(legacy_rows, & &1.id) == ["branch-hit"]
    end

    test "id / opts / project_path keep matching" do
      repo = start_repo!(:search_other)

      put_timed!(repo, "find-me-by-id", 0)

      put_timed!(repo, "by-opts", 1,
        opts: [path: "/pages/proj", objective: "needle in objective"]
      )

      put_timed!(repo, "by-path", 2, opts: [path: "/pages/needle-dir", objective: "other"])

      assert page_ids(repo, search: "find-me-by-id") == ["find-me-by-id"]
      assert page_ids(repo, search: "needle in objective") == ["by-opts"]
      assert page_ids(repo, search: "needle-dir") == ["by-path"]

      # The escaped LIKE still treats `_`/`%` literally.
      put_timed!(repo, "task_alpha", 3)
      put_timed!(repo, "taskXalpha", 4)
      assert page_ids(repo, search: "task_alpha") == ["task_alpha"]
    end

    test "a phrase that exists ONLY inside a large result no longer matches" do
      repo = start_repo!(:search_result)

      big_text = String.duplicate("y", 5_000_000) <> " ZZONLYINRESULTZZ"

      put_timed!(repo, "result-only", 0,
        result: {:ok, %{result: big_text, commit_sha: "c1", branch_name: "genesis/agent_r1"}}
      )

      # Documented behaviour change: `result` is no longer LIKE-ed (it is zlib
      # compressed above 4 kB, and it is the heaviest column in the table).
      assert Pages.select_tasks_page(repo, search: "ZZONLYINRESULTZZ").total == 0
      assert page_ids(repo, search: "ZZONLYINRESULTZZ") == []

      # The legacy FULL-row page changed identically (one shared WHERE builder).
      assert legacy(repo, filters: [search: "ZZONLYINRESULTZZ"], limit: 50) == {[], 0}

      # The row is still findable by its branch name / id.
      assert page_ids(repo, search: "agent_r1") == ["result-only"]
      assert page_ids(repo, search: "result-only") == ["result-only"]
    end

    test "an empty/nil search applies no clause" do
      repo = start_repo!(:search_empty)
      for i <- 0..2, do: put_timed!(repo, "all-#{i}", i)

      assert Pages.select_tasks_page(repo, search: "").total == 3
      assert Pages.select_tasks_page(repo, search: nil).total == 3
    end
  end

  # ── Query plan: no blob columns, no temp B-tree ─────────────────────────

  describe "query plans" do
    test "the page SELECT reads no blob column and ORDER BY is index-served" do
      repo = start_repo!(:plan)
      for i <- 1..40, do: put_timed!(repo, "plan-#{i}", i)

      statements = capture_statements(repo, fn -> Pages.select_tasks_page(repo, limit: 10) end)

      assert length(statements) == 2,
             "expected the COUNT + page SELECT, captured: #{inspect(statements)}"

      # No statement that feeds the page references a heavy column.
      for {sql, _params} <- statements do
        for blob <- ["archive_metadata", "result", "logs", "usage"] do
          refute String.contains?(sql, blob),
                 "page SQL must not read #{blob}: #{sql}"
        end
      end

      page_statement =
        Enum.find(statements, fn {sql, _} -> String.contains?(sql, "ORDER BY") end) ||
          flunk("no ORDER BY statement captured: #{inspect(statements)}")

      plan = plan_text(repo, page_statement)

      assert plan =~ "idx_tasks_started_at",
             "expected the started_at index to serve ORDER BY, got: #{plan}"

      refute plan =~ "TEMP B-TREE",
             "ORDER BY must not sort in a temp B-tree, got: #{plan}"

      # The COUNT twin is index-served too (no sort at all).
      count_statement =
        Enum.find(statements, fn {sql, _} -> String.contains?(sql, "count(") end) ||
          flunk("no COUNT statement captured: #{inspect(statements)}")

      refute plan_text(repo, count_statement) =~ "TEMP B-TREE"
    end

    test "get_task_lite never selects the archive column, get_task does" do
      repo = start_repo!(:plan_lite)
      put_timed!(repo, "lite-plan", 0)

      lite_sqls = capture_statements(repo, fn -> Pages.get_task_lite(repo, "lite-plan") end)
      assert length(lite_sqls) == 1

      [{lite_sql, _}] = lite_sqls
      refute String.contains?(lite_sql, "archive_metadata")
      assert String.contains?(lite_sql, "result")

      [{full_sql, _}] = capture_statements(repo, fn -> Tasks.get_task(repo, "lite-plan") end)
      assert String.contains?(full_sql, "archive_metadata")
    end

    test "get_task_archive reads ONLY the archive column" do
      repo = start_repo!(:plan_archive)

      put!(repo, %TaskInfo{
        id: "arch-plan",
        type: :evolve,
        status: :completed,
        archive_metadata: [%{"role" => "user", "content" => "hi"}]
      })

      [{sql, _}] = capture_statements(repo, fn -> Pages.get_task_archive(repo, "arch-plan") end)

      assert String.contains?(sql, "archive_metadata")
      refute String.contains?(sql, "result")
      refute String.contains?(sql, "logs")
    end
  end

  # ── EXPLAIN QUERY PLAN plumbing (same shape as covering_index_test.exs) ──

  # The SELECT statements an operation actually emits, captured from the repo's
  # query telemetry so the plans asserted above belong to the GENERATED SQL.
  # The handler is BEAM-wide while attached, so it forwards only events emitted
  # by THIS test process.
  defp capture_statements(pid, fun) do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:evo_git, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid do
          send(test_pid, {:captured_sql, metadata.query, metadata.params})
        end
      end,
      nil
    )

    try do
      _ = RepoScope.with_repo(pid, fun)

      drain_statements([])
      |> Enum.filter(fn {sql, _params} ->
        sql |> String.trim_leading() |> String.upcase() |> String.starts_with?("SELECT")
      end)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:captured_sql, sql, params} -> drain_statements([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp plan_text(pid, {sql, params}) do
    pid
    |> query_rows("EXPLAIN QUERY PLAN " <> sql, params)
    |> Enum.map_join(" | ", fn row -> List.last(row) end)
  end

  defp query_rows(pid, sql, params) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql, params).rows end)
  end
end
