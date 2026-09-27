defmodule EvoGit.Store.CompositeIndexTest do
  @moduledoc """
  Coverage for `20260815000003_composite_indexes` — the `(equality column,
  started_at)` composite indexes that make the paginated task read
  index-served.

  Two halves, both against a REAL dynamic repo booted on a unique tmp SQLite
  file (so `async: true` is safe — `EvoGit.Store.Boot` serializes concurrent
  migration runs with its `:global` lock):

    * **PLAN** — the ACTUAL SQL of `EvoGit.Store.Operations.Tasks.safe_select_paginated_tasks/2`
      (captured from the repo's `[:evo_git, :repo, :query]` telemetry event, so
      the assertion is tied to the generated statement instead of a hand-written
      look-alike) is replayed through `EXPLAIN QUERY PLAN` and asserted to use
      the composite index with NO `USE TEMP B-TREE FOR ORDER BY`. Both statements
      of a page apply are covered (the page SELECT and the `COUNT(*)`), plus the
      unfiltered page, which must KEEP riding `idx_tasks_started_at`. A companion
      test DROPs the composite on its own throwaway database and shows the temp
      B-tree coming back — proving the plan assertions are not vacuous.
    * **CORRECTNESS** — the same rows are read back through every filter
      combination the read path supports (`status`, `project_path`, the composite
      `review_status: "pending"`, and their combinations) and asserted against
      the expected ids in `started_at DESC` order with the expected
      `total_count`, pagination included: a new index must never change WHICH
      rows a query returns.

  ## Why the two DDL-sequencing tests pin their store to ONE connection

  Each test boots its OWN dynamic repo via `start_repo!/3`, which forwards
  `opts` to `EvoGit.Store.Boot.start_dynamic/2` and therefore inherits the
  production pool size (`EvoGit.Store.Boot.default_pool_size/0`) unless the
  test says otherwise. That default is deliberately several connections, and
  SQLite keeps its schema cache PER CONNECTION: a `DROP INDEX` / `CREATE INDEX`
  issued on one pooled connection is not necessarily reflected in the cached
  schema — or the query plan built from it — of the connection the NEXT
  statement in the same test is handed. The plan-non-vacuity test and the
  migrator-idempotency/post-condition test both interleave DDL with observations
  of that DDL (a re-planned `EXPLAIN QUERY PLAN`, `PRAGMA index_info`, the real
  migrator's own post-condition check), so they boot with the explicit
  `pool_size: 1` option — the same reason and the same shape as
  `test/evo_git/store_disk_full_test.exs` (whose `PRAGMA query_only` arm is
  CONNECTION-scoped): with exactly one connection, every statement of the test —
  the DDL and every observation that follows it — is served by the same,
  coherently-cached connection. The plan/correctness assertions below keep the
  production pool shape; the multi-connection schema consistency itself is
  pinned by `test/evo_git/store/pool_size_test.exs`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Tasks
  alias EvoGit.Store.RepoScope
  alias EvoGit.TaskInfo

  @status_index "idx_tasks_status_started_at"
  @path_index "idx_tasks_project_path_started_at"

  # ── setup / helpers ──────────────────────────────────────────────────────

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_composite_idx_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # `opts` go straight to `Boot.start_dynamic/2`; the DDL-sequencing tests pass
  # `pool_size: 1` (see the moduledoc section) so their DDL and the
  # introspection/planning that observes it share ONE connection.
  defp start_repo!(%{root: root}, tag, opts \\ []) do
    {:ok, pid} = Boot.start_dynamic(Path.join(root, "evogit_composite_#{tag}.sqlite"), opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp query_rows(pid, sql, params \\ []) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql, params).rows end)
  end

  defp index_columns(pid, name) do
    pid
    |> query_rows("PRAGMA index_info(#{name})")
    |> Enum.map(fn [_seqno, _cid, column] -> column end)
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # Seeds 12 tasks spread over 3 project paths, 5 statuses and 12 distinct
  # `started_at` values (strictly DESCENDING over the list order below), with
  # `review_status`/`branch_name` set so the `review_status: "pending"` composite
  # and its exact-value sibling both have real matches.
  #
  # Newest → oldest: a1 b1 a2 c1 a3 b2 a4 b3 a5 c2 b4 a6
  defp seed_tasks!(pid) do
    specs = [
      {"a1", :completed, "/p/alpha", nil, "genesis/agent_a1"},
      {"b1", :completed, "/p/beta", :merged, "genesis/agent_b1"},
      {"a2", :completed, "/p/alpha", :merged, "genesis/agent_a2"},
      {"c1", :running, "/p/gamma", nil, nil},
      {"a3", :running, "/p/alpha", nil, nil},
      {"b2", :completed, "/p/beta", nil, nil},
      {"a4", :failed, "/p/alpha", nil, nil},
      {"b3", :completed, "/p/beta", nil, "genesis/agent_b3"},
      {"a5", :pending, "/p/alpha", nil, nil},
      {"c2", :cancelled, "/p/gamma", nil, nil},
      {"b4", :completed, "/p/beta", :merged, "genesis/agent_b4"},
      {"a6", :completed, "/p/alpha", nil, "genesis/agent_a6"}
    ]

    base = ~U[2026-03-01 12:00:00.000Z]

    specs
    |> Enum.with_index()
    |> Enum.each(fn {{id, status, path, review, branch}, i} ->
      started_at = DateTime.add(base, -i * 60, :second)

      :ok =
        Tasks.put_task(pid, %TaskInfo{
          id: id,
          type: :evolve,
          status: status,
          opts: [path: path, mode: "simple", objective: "seed #{id}"],
          started_at: started_at,
          finished_at: DateTime.add(started_at, 60, :second),
          result: {:ok, %{commit_sha: "sha-#{id}", branch_name: branch, result: "done #{id}"}},
          review_status: review,
          branch_name: branch,
          agent_count: 1,
          project_path: path
        })
    end)

    :ok
  end

  # ── PLAN assertions ──────────────────────────────────────────────────────

  # The `EXPLAIN QUERY PLAN` text of the two statements one
  # `safe_select_paginated_tasks/2` call actually runs.
  defp plan_texts(pid, opts) do
    statements = capture_statements(pid, opts)
    count = Enum.find(statements, fn {sql, _params} -> sql =~ ~r/count\(\*\)/i end)
    page = Enum.find(statements, fn {sql, _params} -> not (sql =~ ~r/count\(\*\)/i) end)

    if is_nil(page) or is_nil(count) do
      flunk("expected a page SELECT and a COUNT(*) statement, captured: #{inspect(statements)}")
    end

    %{page: plan_text(pid, page), count: plan_text(pid, count)}
  end

  defp plan_text(pid, {sql, params}) do
    pid
    |> query_rows("EXPLAIN QUERY PLAN " <> sql, params)
    |> Enum.map_join(" | ", fn row -> List.last(row) end)
  end

  # Captures the statements the operation runs off the repo's query telemetry,
  # so the plans asserted below belong to the GENERATED SQL. The handler is
  # BEAM-wide while attached, so it forwards only events emitted by THIS test
  # process (sibling `async: true` suites query their own repos concurrently).
  defp capture_statements(pid, opts) do
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
      _ = RepoScope.with_repo(pid, fn -> Tasks.safe_select_paginated_tasks(pid, opts) end)

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

  describe "paginated read plans (EXPLAIN QUERY PLAN on the generated SQL)" do
    test "status-filtered page + its COUNT use the composite, with no temp B-tree", %{root: root} do
      pid = start_repo!(%{root: root}, "plan_status")
      seed_tasks!(pid)

      %{page: page, count: count} = plan_texts(pid, filters: [status: "completed"], limit: 25)

      assert page =~ @status_index
      refute page =~ "TEMP B-TREE"
      assert count =~ @status_index
      refute count =~ "TEMP B-TREE"
    end

    test "path-filtered page uses the path composite, with no temp B-tree", %{root: root} do
      pid = start_repo!(%{root: root}, "plan_path")
      seed_tasks!(pid)

      %{page: page, count: count} =
        plan_texts(pid, filters: [project_path: "/p/alpha"], limit: 25)

      assert page =~ @path_index
      refute page =~ "TEMP B-TREE"
      refute count =~ "TEMP B-TREE"
    end

    test "the dashboard's full filter set (status + project_path + review_status:'pending') has no temp B-tree",
         %{root: root} do
      pid = start_repo!(%{root: root}, "plan_combined")
      seed_tasks!(pid)

      %{page: page, count: count} =
        plan_texts(pid,
          filters: [status: "completed", project_path: "/p/alpha", review_status: "pending"],
          limit: 25
        )

      assert page =~ "USING INDEX"
      refute page =~ "TEMP B-TREE"
      refute count =~ "TEMP B-TREE"
    end

    test "the composite review_status:'pending' predicate rides the status composite", %{
      root: root
    } do
      pid = start_repo!(%{root: root}, "plan_pending")
      seed_tasks!(pid)

      %{page: page} = plan_texts(pid, filters: [review_status: "pending"], limit: 25)

      assert page =~ @status_index
      refute page =~ "TEMP B-TREE"
    end

    test "a deep OFFSET stays index-served (the old plan sorted every matching row)", %{
      root: root
    } do
      pid = start_repo!(%{root: root}, "plan_offset")
      seed_tasks!(pid)

      %{page: page} = plan_texts(pid, filters: [status: "completed"], limit: 2, offset: 4)

      assert page =~ @status_index
      refute page =~ "TEMP B-TREE"
    end

    test "the UNFILTERED page still rides idx_tasks_started_at", %{root: root} do
      pid = start_repo!(%{root: root}, "plan_unfiltered")
      seed_tasks!(pid)

      %{page: page, count: count} = plan_texts(pid, filters: [], limit: 25)

      assert page =~ "idx_tasks_started_at"
      refute page =~ "TEMP B-TREE"
      refute count =~ "TEMP B-TREE"
    end

    test "the plan assertions are non-vacuous: without the composite the temp B-tree returns",
         %{root: root} do
      # ONE connection (see the moduledoc section): the DROP below must be
      # visible to the connection that re-plans the same SQL.
      pid = start_repo!(%{root: root}, "plan_dropped", pool_size: 1)
      seed_tasks!(pid)

      assert %{page: plan} = plan_texts(pid, filters: [status: "completed"])
      assert plan =~ @status_index
      refute plan =~ "TEMP B-TREE"

      # Same database, same rows, composite dropped — exactly the pre-migration
      # shape (baseline idx_tasks_status + USE TEMP B-TREE FOR ORDER BY).
      query_rows(pid, "DROP INDEX #{@status_index}")

      assert %{page: plan} = plan_texts(pid, filters: [status: "completed"])
      assert plan =~ "USE TEMP B-TREE FOR ORDER BY"
      assert plan =~ "USING INDEX idx_tasks_status"

      # Re-creating it restores the index-served plan.
      query_rows(pid, "CREATE INDEX #{@status_index} ON tasks(status, started_at)")

      assert %{page: plan} = plan_texts(pid, filters: [status: "completed"])
      assert plan =~ @status_index
      refute plan =~ "TEMP B-TREE"
    end
  end

  # ── the migration's DDL shape ────────────────────────────────────────────

  describe "composite index DDL" do
    test "both composites exist as plain non-unique indexes with exactly their declared columns",
         %{root: root} do
      pid = start_repo!(%{root: root}, "ddl")

      composite_rows =
        pid
        |> query_rows("PRAGMA index_list(tasks)")
        |> Enum.map(fn [_seq, name, unique, origin, partial] ->
          {name, unique, origin, partial}
        end)
        |> Enum.filter(&(elem(&1, 0) in [@status_index, @path_index]))
        |> Enum.sort()

      assert composite_rows ==
               Enum.sort([{@status_index, 0, "c", 0}, {@path_index, 0, "c", 0}])

      # Column ORDER is the whole point (equality column first, started_at
      # trailing) — `PRAGMA index_info` reports it positionally.
      assert index_columns(pid, @status_index) == ["status", "started_at"]
      assert index_columns(pid, @path_index) == ["project_path", "started_at"]
    end

    test "the migrator is idempotent, and the post-condition rejects a same-named index of another shape",
         %{root: root} do
      # ONE connection (see the moduledoc section): the migrated/planted index
      # shape and the migrator's post-condition check must be observed by the
      # connection that performed the DDL.
      pid = start_repo!(%{root: root}, "postcondition", pool_size: 1)

      # Already current: a re-run migrates nothing and re-validates nothing.
      assert Boot.run_migrations(pid) == []

      # Re-arm migration 3 (the only way to drive it again through the REAL
      # migrator/runner) and plant a same-named index over the WRONG columns —
      # the silent trap `CREATE INDEX IF NOT EXISTS` alone would paper over.
      query_rows(pid, "DELETE FROM schema_migrations WHERE version = 20260815000003")
      query_rows(pid, "DROP INDEX #{@status_index}")
      query_rows(pid, "CREATE INDEX #{@status_index} ON tasks(status, finished_at)")

      assert_raise Ecto.MigrationError, ~r/composite index idx_tasks_status_started_at/, fn ->
        Boot.run_migrations(pid)
      end

      # Restoring the declared shape lets the (still pending) migration through.
      query_rows(pid, "DROP INDEX #{@status_index}")
      query_rows(pid, "CREATE INDEX #{@status_index} ON tasks(status, started_at)")

      assert Boot.run_migrations(pid) == [20_260_815_000_003]

      assert index_columns(pid, @status_index) == ["status", "started_at"]
      assert index_columns(pid, @path_index) == ["project_path", "started_at"]
      assert Boot.run_migrations(pid) == []
    end
  end

  # ── CORRECTNESS: rows + order + total_count per filter combination ───────

  describe "safe_select_paginated_tasks/2 correctness over composite-indexed data" do
    setup %{root: root} do
      pid = start_repo!(%{root: root}, "correctness")
      seed_tasks!(pid)
      {:ok, %{pid: pid}}
    end

    test "no filters: all 12 rows, newest first, total independent of paging", %{pid: pid} do
      {rows, total} = Tasks.safe_select_paginated_tasks(pid, [])

      assert ids(rows) == ~w(a1 b1 a2 c1 a3 b2 a4 b3 a5 c2 b4 a6)
      assert total == 12

      {page, total} = Tasks.safe_select_paginated_tasks(pid, limit: 5, offset: 0)
      assert ids(page) == ~w(a1 b1 a2 c1 a3)
      assert total == 12

      {page, total} = Tasks.safe_select_paginated_tasks(pid, limit: 5, offset: 5)
      assert ids(page) == ~w(b2 a4 b3 a5 c2)
      assert total == 12

      {page, total} = Tasks.safe_select_paginated_tasks(pid, limit: 5, offset: 10)
      assert ids(page) == ~w(b4 a6)
      assert total == 12
    end

    test "status filter: only the matching status, started_at DESC", %{pid: pid} do
      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [status: "completed"])

      assert ids(rows) == ~w(a1 b1 a2 b2 b3 b4 a6)
      assert total == 7
      assert Enum.all?(rows, &(&1.status == :completed))

      {page, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [status: "completed"],
          limit: 3,
          offset: 3
        )

      assert ids(page) == ~w(b2 b3 b4)
      assert total == 7

      # The dashboard's spelling for "no status filter".
      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [status: "all"])
      assert length(rows) == 12
      assert total == 12

      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [status: "failed"])
      assert ids(rows) == ~w(a4)
      assert total == 1
    end

    test "project_path filter: only that path, started_at DESC", %{pid: pid} do
      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [project_path: "/p/alpha"])

      assert ids(rows) == ~w(a1 a2 a3 a4 a5 a6)
      assert total == 6
      assert Enum.uniq(Enum.map(rows, & &1.project_path)) == ["/p/alpha"]

      {page, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [project_path: "/p/alpha"],
          limit: 2,
          offset: 2
        )

      assert ids(page) == ~w(a3 a4)
      assert total == 6

      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [project_path: "/p/nope"])
      assert rows == []
      assert total == 0
    end

    test "status + project_path combined (AND), started_at DESC", %{pid: pid} do
      {rows, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [status: "completed", project_path: "/p/beta"]
        )

      assert ids(rows) == ~w(b1 b2 b3 b4)
      assert total == 4

      {rows, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [status: "failed", project_path: "/p/alpha"]
        )

      assert ids(rows) == ~w(a4)
      assert total == 1

      {rows, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [status: "failed", project_path: "/p/beta"]
        )

      assert rows == []
      assert total == 0
    end

    test "review_status 'pending' composite: completed + NULL review + branch present", %{
      pid: pid
    } do
      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [review_status: "pending"])

      assert ids(rows) == ~w(a1 b3 a6)
      assert total == 3

      # Combined with a status filter (the dashboard sends both).
      {rows, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [status: "completed", review_status: "pending"]
        )

      assert ids(rows) == ~w(a1 b3 a6)
      assert total == 3

      # Combined with a path filter too.
      {rows, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [project_path: "/p/alpha", review_status: "pending"]
        )

      assert ids(rows) == ~w(a1 a6)
      assert total == 2
    end

    test "review_status exact value: matches the column, started_at DESC", %{pid: pid} do
      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [review_status: "merged"])

      assert ids(rows) == ~w(b1 a2 b4)
      assert total == 3
    end

    test "the dashboard's default filter set ('all'/'') matches the unfiltered read", %{pid: pid} do
      {rows, total} =
        Tasks.safe_select_paginated_tasks(pid,
          filters: [status: "all", project_path: "all", review_status: "all", search: ""]
        )

      assert ids(rows) == ~w(a1 b1 a2 c1 a3 b2 a4 b3 a5 c2 b4 a6)
      assert total == 12
    end

    test "every row survives the composite-index round trip (full TaskInfo shape)", %{pid: pid} do
      {[newest | _rest], _total} =
        Tasks.safe_select_paginated_tasks(pid, filters: [status: "completed"])

      assert %TaskInfo{} = newest
      assert newest.id == "a1"
      assert newest.status == :completed
      assert newest.project_path == "/p/alpha"
      assert newest.branch_name == "genesis/agent_a1"
      assert newest.opts[:objective] == "seed a1"
      # The ok-result decodes back to the keys the seed stored (a nil
      # pr_url/pr_title is dropped by the canonical `ok` encoding).
      assert newest.result ==
               {:ok,
                %{
                  commit_sha: "sha-a1",
                  branch_name: "genesis/agent_a1",
                  result: "done a1"
                }}

      assert newest.started_at == ~U[2026-03-01 12:00:00.000Z]
      assert newest.finished_at == ~U[2026-03-01 12:01:00.000Z]
    end

    test "the composite path index does not reorder rows inside one started_at bucket", %{
      pid: pid
    } do
      # Two tasks on the SAME path with the SAME started_at (the tie only
      # `id`/rowid disambiguates) — an index over (project_path, started_at)
      # claims the order, so the tie must still be resolved deterministically by
      # the SQLite b-tree (rowid ascending within equal keys) rather than
      # returning arbitrary rows.
      same = ~U[2026-01-01 00:00:00.000Z]

      for id <- ~w(tie-1 tie-2 tie-3) do
        :ok =
          Tasks.put_task(pid, %TaskInfo{
            id: id,
            type: :evolve,
            status: :failed,
            opts: [path: "/p/tie", mode: "simple"],
            started_at: same,
            project_path: "/p/tie"
          })
      end

      {rows, total} = Tasks.safe_select_paginated_tasks(pid, filters: [project_path: "/p/tie"])

      assert ids(rows) |> Enum.sort() == ~w(tie-1 tie-2 tie-3)
      assert total == 3

      # Repeated reads return the identical (deterministic) order.
      {rows2, _} = Tasks.safe_select_paginated_tasks(pid, filters: [project_path: "/p/tie"])
      assert ids(rows) == ids(rows2)
    end
  end
end
