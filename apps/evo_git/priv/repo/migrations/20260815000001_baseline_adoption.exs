defmodule EvoGit.Repo.Migrations.BaselineAdoption do
  @moduledoc """
  Baseline schema adoption for the Ecto-managed task store — the ONE
  schema-creating step of the chain.

  Works on a FRESH database (tables + the final index set created) AND adopts
  ANY pre-Ecto legacy database. Legacy DBs were managed by the raw-SQL
  `EvoGit.Store.Schema` pipeline, which left no `schema_migrations` table — so
  the Ecto migrator (seeing version 0) runs THIS migration against them. It is
  therefore idempotent by construction:

    * tables via `CREATE TABLE IF NOT EXISTS` — the FINAL `tasks` shape (19
      columns; the `archive_metadata` column the pre-release builds carried is
      GONE for good, see `20260815000005_task_agent_archives`) and the
      3-column `projects` table
    * for each task column missing from a legacy table, a NULLABLE
      `ALTER TABLE tasks ADD COLUMN <col> <type>` — nullable, no default,
      because SQLite refuses NOT NULL adds without a default on populated
      tables. Matches `EvoGit.Store.Schema.migrate_schema/1` exactly
      (lease_expires_at, model_id, project_path, branch_name, error,
      updated_at) — the six columns any pre-Ecto DB may lack.
    * the FINAL six `tasks` indexes via `CREATE INDEX IF NOT EXISTS`, AFTER the
      columns: `idx_tasks_updated_at`/`idx_tasks_status_updated_at_id`/
      `idx_tasks_project_path_started_at` reference columns the ALTERs above may
      have just added. `20260815000003` (the two `(equality, started_at)`
      composites) and `20260815000004` (the two covering indexes) re-state two
      of them each, deliberately idempotently, because they are SHIPPED and must
      keep working on their own.
    * post-condition: the `tasks` table carries EXACTLY the 19 canonical
      columns — names, types, notnull/pk flags. Physical order may be the
      canonical one (fresh creates; 15/17-column prefix adoptions) OR the
      adopted tail swap (`…, branch_name, updated_at, error`): SQLite
      `ALTER TABLE … ADD COLUMN` can only APPEND, and the real
      v0.9.0–v0.12.5 DDL already ended in `updated_at`, so the appended
      `error` lands after it — exactly the shape the old raw pipeline
      (`Schema.migrate_schema/1`) left behind. Column order is functionally
      irrelevant in SQLite (every query in this system is name-based: Ecto
      schemas, named selects).
    * a pre-Ecto legacy DB may ALSO still carry the legacy `archive_metadata`
      column (both the 19-column v0.9.0–v0.12.5 shape and the 20-column
      v0.13.8 shape have it), so after the ALTERs such a table legitimately has
      20 columns. That column is not a schema-CREATION concern of this
      migration — `20260815000005_task_agent_archives` fans it out and drops it
      — so the post-condition tolerates it: it is removed from the observed
      spec set (after asserting it is a nullable TEXT non-key column), and the
      remaining 19 columns must then match exactly.

  ## Why every statement runs via `repo().query!/3` (not `execute/1`)

  The migration must PROBE (`PRAGMA table_info`) between statements and branch
  on the result. `Ecto.Migration.execute/1` string commands are QUEUED and only
  executed at `flush/0` — AFTER the whole migration body returned — so an
  in-body probe sees the pre-migration state and the fresh database path would
  queue ALTERs for columns the `CREATE TABLE` just created ("duplicate column
  name"). `repo().query!/3` runs on the migration's own connection immediately,
  in body order, inside the migration transaction — the exact sequential
  semantics of the raw-SQL pipeline this replaces. Every statement is a single
  SQL statement.

  Defined as `up/0` (no `down/0`): rolling back a baseline adoption would drop
  user data, so it is deliberately irreversible.
  """

  use Ecto.Migration

  # {column, ddl type} pairs a legacy `tasks` table may lack, in the same order
  # Schema.migrate_schema/1 adds them.
  @legacy_columns [
    {"lease_expires_at", "INTEGER"},
    {"model_id", "TEXT"},
    {"project_path", "TEXT"},
    {"branch_name", "TEXT"},
    {"error", "TEXT"},
    {"updated_at", "TEXT"}
  ]

  # The FINAL `tasks` index set (six). Every one leads with a column a real
  # query constrains or orders by; the four single-column indexes the
  # pre-release builds also carried are exact prefixes of these and are dropped
  # by `20260815000006_prune_redundant_indexes`.
  @index_ddl [
    "CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON tasks(updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_started_at ON tasks(started_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_status_started_at ON tasks(status, started_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_project_path_started_at ON tasks(project_path, started_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_status_updated_at_id ON tasks(status, updated_at, id)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_finished_at_id ON tasks(finished_at, id)"
  ]

  @task_columns ~w(id type status opts started_at finished_at logs result review_status usage agent_count base_sha commit_sha lease_expires_at model_id project_path branch_name error updated_at)

  # The ONE non-canonical physical order a legacy ADOPTION may legally end up
  # in: the real v0.9.0–v0.12.5 table already had `updated_at` (19th) and
  # lacked `error`, so the appended `error` lands AFTER it (SQLite ALTERs can
  # only append). This is exactly the tail the old raw pipeline left behind —
  # `Schema.migrate_schema/1` upgraded this shape in place, so adopting it is
  # a hard requirement. Any OTHER order is a genuine invariant violation.
  @adopted_columns ~w(id type status opts started_at finished_at logs result review_status usage agent_count base_sha commit_sha lease_expires_at model_id project_path branch_name updated_at error)

  # The legacy column a pre-Ecto / pre-release database may still carry. Not
  # created here and not required here: it is tolerated (nullable TEXT, non-key)
  # and removed from the observed spec set before the canonical comparison.
  @archive_metadata "archive_metadata"
  @archive_metadata_spec {"archive_metadata", "TEXT", 0, 0}

  # {name, ddl type, notnull, pk} per the canonical DDL, listed in canonical
  # order (informational) — the comparison below is ORDER-INSENSITIVE (an
  # adopted table legitimately carries `error` after `updated_at`). Adopted
  # (appended) columns are NULLABLE adds (notnull 0, pk 0), matching the fresh
  # CREATE.
  @column_specs [
    {"id", "TEXT", 0, 1},
    {"type", "TEXT", 0, 0},
    {"status", "TEXT", 1, 0},
    {"opts", "TEXT", 0, 0},
    {"started_at", "TEXT", 0, 0},
    {"finished_at", "TEXT", 0, 0},
    {"logs", "TEXT", 0, 0},
    {"result", "TEXT", 0, 0},
    {"review_status", "TEXT", 0, 0},
    {"usage", "TEXT", 0, 0},
    {"agent_count", "INTEGER", 0, 0},
    {"base_sha", "TEXT", 0, 0},
    {"commit_sha", "TEXT", 0, 0},
    {"lease_expires_at", "INTEGER", 0, 0},
    {"model_id", "TEXT", 0, 0},
    {"project_path", "TEXT", 0, 0},
    {"branch_name", "TEXT", 0, 0},
    {"error", "TEXT", 0, 0},
    {"updated_at", "TEXT", 0, 0}
  ]

  def up do
    # 1. Tables (fresh DB).
    sql("""
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY,
      type TEXT,
      status TEXT NOT NULL,
      opts TEXT,
      started_at TEXT,
      finished_at TEXT,
      logs TEXT,
      result TEXT,
      review_status TEXT,
      usage TEXT,
      agent_count INTEGER,
      base_sha TEXT,
      commit_sha TEXT,
      lease_expires_at INTEGER,
      model_id TEXT,
      project_path TEXT,
      branch_name TEXT,
      error TEXT,
      updated_at TEXT
    )
    """)

    sql("""
    CREATE TABLE IF NOT EXISTS projects (
      path TEXT PRIMARY KEY,
      name TEXT,
      last_opened_at TEXT
    )
    """)

    # 2. Adopt a legacy `tasks` table: probe existing columns (post-CREATE,
    #    so a fresh DB sees all 19 and adds nothing), add the missing ones
    #    as NULLABLE — SQLite refuses NOT NULL adds without a default on
    #    populated tables.
    columns = Enum.map(task_column_specs(), &elem(&1, 0))

    for {column, type} <- @legacy_columns, column not in columns do
      sql("ALTER TABLE tasks ADD COLUMN #{column} #{type}")
    end

    # 3. Indexes LAST — several of them reference columns the ALTERs above
    #    may have just added.
    for ddl <- @index_ddl, do: sql(ddl)

    assert_tasks_shape!()
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # Invariant: after this migration the tasks table carries exactly the 19
  # canonical columns with their declared types/flags — plus, at most, the
  # tolerated legacy `archive_metadata` column. Physical order is canonical on
  # fresh (and prefix-adopted) databases, but a legacy adoption necessarily
  # appends `error` after the pre-existing `updated_at` — both tails are legal,
  # anything else is a failure.
  defp assert_tasks_shape! do
    case task_column_specs() do
      [] ->
        raise_invariant("no tasks table after baseline adoption", [])

      specs ->
        {archive, observed} =
          Enum.split_with(specs, fn {name, _type, _notnull, _pk} ->
            name == @archive_metadata
          end)

        assert_archive_metadata!(archive)
        assert_column_order!(observed)
        assert_column_specs!(observed)
    end
  end

  # PRAGMA table_info(tasks) rows: [cid, name, type, notnull, dflt, pk] —
  # kept as {name, type, notnull, pk} tuples so the post-condition can check
  # types and flags, not just names/order.
  defp task_column_specs do
    case repo().query("PRAGMA table_info(tasks)", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_cid, name, type, notnull, _dflt, pk] ->
          {name, type, notnull, pk}
        end)

      _other ->
        []
    end
  end

  # Tolerated, never created here: a legacy database may still hold the
  # pre-release archive column. It must have the shape the old DDL gave it
  # (nullable TEXT, not a key) — anything else is a hand-edited table this
  # store cannot serve.
  defp assert_archive_metadata!([]), do: :ok
  defp assert_archive_metadata!([@archive_metadata_spec]), do: :ok

  defp assert_archive_metadata!(specs) do
    raise Ecto.MigrationError,
          "baseline adoption failed: the legacy #{@archive_metadata} column must be a " <>
            "nullable TEXT non-key column, got #{inspect(specs)}"
  end

  defp assert_column_order!(specs) do
    columns = Enum.map(specs, &elem(&1, 0))

    unless columns == @task_columns or columns == @adopted_columns do
      raise_invariant(
        "expected the 19 canonical tasks columns #{inspect(@task_columns)} " <>
          "(or the adopted tail #{inspect(@adopted_columns)})",
        columns
      )
    end

    :ok
  end

  # Order-insensitive: the column ORDER is pinned above, but an adopted table
  # legitimately carries `error` after `updated_at`, so the comparison sorts
  # both sides before checking type/notnull/pk.
  defp assert_column_specs!(specs) do
    if Enum.sort(specs) == Enum.sort(@column_specs) do
      :ok
    else
      raise Ecto.MigrationError,
            "baseline adoption failed: expected the 19 tasks columns " <>
              "#{inspect(@column_specs)} (types/nullability/pk), got #{inspect(specs)}"
    end
  end

  defp raise_invariant(message, columns) do
    raise Ecto.MigrationError,
          "baseline adoption failed: #{message}, got #{inspect(columns)}"
  end
end
