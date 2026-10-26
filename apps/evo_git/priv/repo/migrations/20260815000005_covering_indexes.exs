defmodule EvoGit.Repo.Migrations.CoveringIndexes do
  @moduledoc """
  Covering indexes for the id-oriented task reads — the incident query first.

  ## ORDERING: this migration MUST run AFTER `20260815000004_compress_oversized_rows`

  Both indexes are b-trees over scalar columns, so building them looks like
  pure index work — but SQLite builds an index by WALKING the table, and on a
  DB whose rows still carry their pre-compression multi-MB
  `result`/`archive_metadata` blobs that walk has to crawl the blob overflow
  chains to reach the `updated_at`/`id` values stored behind them. Measured on
  a 442 MiB live copy (one row with a 103 MiB result + 103 MiB
  archive_metadata): `CREATE INDEX idx_tasks_status_updated_at_id` took
  **26 181 ms** as the first migration on the raw file and **15 ms** when it
  runs after the compression/dedup rewrite (`20260815000004`). Building the
  indexes first therefore makes the first boot after an upgrade pay that
  ~26 s in the index build (it merely relocates: on a COLD page cache the
  rewrite pays the same cold page reads — see `20260815000004`'s "Measured
  first boot" table).

  Do NOT renumber this migration below the compression rewrite (or insert a
  new index migration between them). Any future index migration belongs at a
  version ABOVE this one.

  ## The incident

  `EvoGit.Store.select_task_ids([:completed, :failed, :cancelled])` (the
  dashboard task-list projection, `EvoGit.Store.Operations.Lightweight.select_task_ids/2`)
  once took **26.5 s** on the live `tasks.sqlite` (442 MB, 953 rows) and blew
  the DBConnection call deadline, killing the Store. The generated SQL is
  small — captured from the repo's `[:evo_git, :repo, :query]` telemetry:

      SELECT t0."id", t0."status", t0."updated_at"
        FROM "tasks" AS t0
       WHERE (t0."status" IN (?1,?2,?3))

  The existing composite `idx_tasks_status_started_at` (see
  `20260815000003_composite_indexes`) DOES seek these rows — it just does not
  CARRY `updated_at`, so every matching row needed a table lookup, and
  `updated_at`/`error` are the physically LAST columns of the 20-column row —
  behind the multi-MB `logs`/`opts`/`result` blob overflow chains. The seek was
  cheap; the per-row row-fetch crawled through the blob pages.

  ## The set (deliberately minimal — 2 indexes)

    * `idx_tasks_status_updated_at_id` — `(status, updated_at, id)`. Makes
      `select_task_ids/2` FULLY COVERING: `status` leads (one seek per `IN`
      value), and both projected columns (`updated_at`, `id`) ride in the index
      entry, so SQLite answers the statement from the index alone — no table
      access, no blob pages, no row decode. On a 3 000-row synthetic copy
      (20 kB `logs` blobs per row, i.e. real overflow chains) the statement went
      from **≈20–28 ms** to **≈1.2 ms**, and the plan from

          SEARCH t0 USING INDEX idx_tasks_status_started_at (status=?)
          (74 000 table/row fetches for the projected columns)

      to

          SEARCH t0 USING COVERING INDEX idx_tasks_status_updated_at_id (status=?)

      The same index also covers the other id-only status reads:
      `select_task_ids/2` with NO status filter (`[]`, a full projection) goes
      from `SCAN t0` to `SCAN t0 USING COVERING INDEX
      idx_tasks_status_updated_at_id`, and `select_finished_task_ids/1`
      (`status NOT IN ('running','pending','cancelling')` — unseekable, but a
      covering index scan still avoids every table page) goes from `SCAN t0` to
      the same `SCAN t0 USING COVERING INDEX`. The paginated read keeps its own
      `(equality, started_at)` composites untouched: this index is useless for
      `ORDER BY started_at`, so the planner keeps using those.

    * `idx_tasks_finished_at_id` — `(finished_at, id)`. Serves the cleanup
      reads (`EvoGit.Store.Operations.Lightweight.select_cleanup_info/1,3`),
      which project `id` (and `finished_at`) over EVERY finished row:

        - `select_cleanup_info/1`
          (`SELECT id, finished_at … WHERE finished_at IS NOT NULL`) went from
          `SCAN t0` — a full table walk over the blob-carrying rows — to
          `SEARCH t0 USING COVERING INDEX idx_tasks_finished_at_id (finished_at>?)`.
        - `select_cleanup_info/3` Q1 (age cutoff) went from
          `SEARCH t0 USING INDEX idx_tasks_finished_at (finished_at<?)` plus one
          table lookup per expired row to the same seek `USING COVERING INDEX`,
          and Q2 (the count trim, `ORDER BY finished_at DESC LIMIT -1 OFFSET n`)
          from `SEARCH … USING INDEX idx_tasks_finished_at (finished_at>?)` plus a
          table lookup for EVERY row it walks — including the `OFFSET`-skipped
          ones — to a fully index-served `ORDER BY finished_at DESC` (the b-tree
          already delivers the order, so no temp B-tree either).

  ## Deliberately NOT added

    * `(status, lease_expires_at, id)` for `select_running_lease_info/1`
      (`SELECT id, status, lease_expires_at … WHERE status IN ('running',
      'finalizing','cancelling')`). It would turn today's
      `SEARCH t0 USING INDEX idx_tasks_status_started_at (status=?)` + one
      per-row table lookup into a covering seek — but that query only matches
      the LIVE tasks on a real database (a handful of rows; the 3 000-row
      synthetic copy reaches it only because it seeds every status). The
      measured difference was run-to-run noise, so it does not justify a third
      index on every `put_task`.
    * `(status, id)` for `select_finished_task_ids/1` — redundant:
      `idx_tasks_status_updated_at_id` already carries `status` + `id` and the
      planner picks it for that statement (verified with `EXPLAIN QUERY PLAN`).
    * Anything for `select_task_paths/0`
      (`SELECT DISTINCT project_path … WHERE project_path IS NOT NULL`) — the
      baseline `idx_tasks_project_path` is already a single-column covering
      index; the plan is `SCAN t0 USING COVERING INDEX idx_tasks_project_path`
      before and after this migration.
    * `updated_at` alone — the baseline `idx_tasks_updated_at` already serves
      the `updated_at > ?` range read of `Operations.Summaries`.

  ## Write cost

  Both indexes carry only scalar columns (`TEXT` id/status/timestamp, never a
  blob column), so a write updates them without touching any overflow chain.
  Measured on 1 000 single-row inserts into the migrated table: 56–75 ms with
  these two indexes and 56–75 ms without them — inside run-to-run noise.

  ## No ANALYZE

  No `ANALYZE` statement is added (same reasoning as
  `20260815000003_composite_indexes`): both indexes are picked by the planner
  with NO statistics at all — there is no `sqlite_stat1` anywhere in this
  application — because a leading equality/range constraint makes the index
  strictly cheaper than a seek plus row fetch. `ANALYZE` would instead cost a
  full index+table scan of a large user DB inside the boot-time migration and
  would need periodic re-running to stay useful.

  ## Conventions

  Idempotent (`CREATE INDEX IF NOT EXISTS`) and applied to a FRESH database as
  well as to ANY already-adopted one — indexes are additive DDL, so there is no
  table rebuild and no data rewrite. Statements run via `repo().query!/3`, not
  `Ecto.Migration.execute/1` (whose string commands are queued until `flush/0`
  — see the baseline migration's moduledoc), because the post-condition below
  probes `PRAGMA index_info` in body order. Defined as `up/0` (no `down/0`),
  like the sibling migrations: dropping these indexes would silently restore
  the table-fetch plans above.
  """

  use Ecto.Migration

  # `{index name, column list}` — leading `status` (IN-seekable) + the projected
  # `updated_at`/`id`, and `finished_at` (range/order column) + the projected
  # `id`. The trailing `id` is what makes each index covering for its statement.
  @indexes [
    {"idx_tasks_status_updated_at_id", "status, updated_at, id"},
    {"idx_tasks_finished_at_id", "finished_at, id"}
  ]

  def up do
    for {name, columns} <- @indexes do
      sql("CREATE INDEX IF NOT EXISTS #{name} ON tasks(#{columns})")
    end

    assert_covering_indexes!()
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # Post-condition: every index exists with EXACTLY the declared columns, in
  # order. `IF NOT EXISTS` alone would silently keep a same-named index of a
  # different shape (a legacy DB carrying its own
  # `idx_tasks_status_updated_at_id` over `(status, started_at)`, say) and the
  # whole read fix would be a no-op.
  defp assert_covering_indexes! do
    for {name, columns} <- @indexes do
      expected = String.split(columns, ", ")
      actual = index_columns(name)

      if actual != expected do
        raise Ecto.MigrationError,
              "covering index #{name} on tasks(#{columns}) was not applied: " <>
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
