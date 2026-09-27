defmodule EvoGit.Repo.Migrations.CompositeIndexes do
  @moduledoc """
  Composite `(equality column, started_at)` indexes for the paginated task read.

  The paginated read (`EvoGit.Store.Operations.Tasks.safe_select_paginated_tasks/2`)
  runs `WHERE <filters> ORDER BY started_at DESC LIMIT ? OFFSET ?` over the FULL
  20-column row. The baseline indexes are single-column, so a filter on an
  indexed column (`status`, `project_path`) supplied a seek but NOT the sort
  order: SQLite fell back to

      SEARCH tasks USING INDEX idx_tasks_status (status=?)
      USE TEMP B-TREE FOR ORDER BY

  materializing every selected column of every matching row (≈25 MB of blobs on
  the live DB, where 751 of 854 rows are `completed`) before `LIMIT 25` applied.
  Measured on a copy of the live `tasks.sqlite` (854 rows / 29.7 MB):
  `status = "completed"` page = **156 ms** through Ecto (up to ~300 ms raw) vs
  0.45 ms for the same predicate projecting only `id, started_at`.

  Each index added here leads with ONE equality column the filter pins and
  trails with `started_at`, so the index itself delivers the rows in
  `ORDER BY started_at DESC` order — the seek starts exactly at the newest
  matching row, the temp B-tree disappears, and the scan early-exits after
  `LIMIT + OFFSET` rows.

  ## The set (deliberately minimal — 2 indexes)

    * `idx_tasks_status_started_at` — `(status, started_at)`. The measured
      pathological shape: the dashboard's status filter (`build_filters_from_assigns/1`
      always sends a status, "all" meaning no clause) and the status-filtered
      sidebar/page reads. On a 900-row synthetic copy this took the
      `status = 'completed'` page from 1229 µs → 372 µs, the same page at
      `OFFSET 700` from 58 ms → 3.6 ms, and the `status` + `review_status:
      "pending"` composite (which pins the literal `status = 'completed'`) from
      1184 µs → 366 µs — every one of them with no `USE TEMP B-TREE FOR ORDER BY`.
    * `idx_tasks_project_path_started_at` — `(project_path, started_at)`. The
      project filter is a real dashboard shape (`project_filter`) AND the only
      filter `TaskRegistry.list_tasks_by_path/1` uses (`limit: 5000`, i.e. the
      full path-scoped list, where the temp-B-tree sort is on every matching
      row). Same synthetic run: 742 µs → 357 µs, temp B-tree gone. This index
      also serves the combined `status + project_path` shape — for
      `WHERE status = … AND project_path = …` the planner picks it
      (`project_path=?`, the more selective equality) and reads the page in
      `started_at` order, so no third index is needed (measured 354 µs with the
      path composite vs 351 µs when a `(status, project_path, started_at)`
      index was also present — inside noise).

  ## Deliberately NOT indexed

    * `(status, project_path, started_at)` — never chosen over the two indexes
      above for any shape measured (`(status, project_path, started_at)` cannot
      serve a status-ONLY query anyway: the incomparable middle column stops the
      traversal, so it could never replace `idx_tasks_status_started_at`). Its
      only theoretical advantage is a fully index-served residual predicate for
      the combined shape, which measured identically to the path composite.
    * `type`, `review_status`, `branch_name` — unindexed today and left alone.
      No paginated query filters on `type` (the dashboard drops `:reflect` rows
      CLIENT-side). `review_status: "pending"` is the composite predicate
      `status = 'completed' AND review_status IS NULL AND branch_name IS NOT
      NULL`, which has no single equality column to lead an index with and is
      already served by `(status, started_at)` (measured above). An exact
      `review_status = <value>` filter rides `idx_tasks_started_at` (early
      exit) and is not a measured bottleneck.
    * The `:search` filter (4-column OR-LIKE) defeats every index — a full
      `SCAN tasks` is inherent to it, not fixable by an index.

  ## No ANALYZE

  No `ANALYZE` statement is added: both composites are picked by the planner
  with NO statistics at all (verified with `EXPLAIN QUERY PLAN` on this
  migration's fresh database — there is no `sqlite_stat1` in the app anywhere),
  because a leading equality constraint plus the trailing ordering column makes
  the index strictly cheaper than a full seek + sort. `ANALYZE` would instead
  cost a full index+table scan of a large user DB inside the boot-time migration
  (the live DB is 29.7 MB) and would need periodic re-running to stay useful.

  ## Conventions

  Idempotent (`CREATE INDEX IF NOT EXISTS`) and applied to a FRESH database as
  well as to ANY already-adopted one — indexes are additive DDL, so there is no
  table rebuild and no data rewrite. Statements run via `repo().query!/3`, not
  `Ecto.Migration.execute/1` (whose string commands are queued until `flush/0`
  — see the baseline migration's moduledoc), because the post-condition below
  probes `PRAGMA index_info` in body order. Defined as `up/0` (no `down/0`),
  like the sibling migrations: dropping these indexes is never desirable, and a
  rollback would silently restore the temp-B-tree plans.
  """

  use Ecto.Migration

  # `{index name, column list}` — one equality column the paginated filters pin,
  # then the ORDER BY column. The trailing `started_at` is what removes the
  # temp B-tree.
  @indexes [
    {"idx_tasks_status_started_at", "status, started_at"},
    {"idx_tasks_project_path_started_at", "project_path, started_at"}
  ]

  def up do
    for {name, columns} <- @indexes do
      sql("CREATE INDEX IF NOT EXISTS #{name} ON tasks(#{columns})")
    end

    assert_composite_indexes!()
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # Post-condition: every index exists with EXACTLY the declared columns, in
  # order. `IF NOT EXISTS` alone would silently keep a same-named index of a
  # different shape (a legacy DB carrying its own `idx_tasks_status_started_at`
  # over `(status, finished_at)`, say) and the whole read fix would be a no-op.
  defp assert_composite_indexes! do
    for {name, columns} <- @indexes do
      expected = String.split(columns, ", ")
      actual = index_columns(name)

      if actual != expected do
        raise Ecto.MigrationError,
              "composite index #{name} on tasks(#{columns}) was not applied: " <>
                "PRAGMA index_info(#{name}) returned #{inspect(actual)}"
      end
    end

    :ok
  end

  # PRAGMA index_info(<name>) rows: [seqno, cid, name]. A missing index yields NO
  # rows (never an error), so [] is the "absent" signal the check above acts on.
  defp index_columns(name) do
    case repo().query("PRAGMA index_info(#{name})", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [_seqno, _cid, column] -> column end)
      _other -> []
    end
  end
end
