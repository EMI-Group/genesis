defmodule EvoGit.Repo.Migrations.BaselineAdoption do
  @moduledoc """
  Baseline schema adoption for the Ecto-managed task store.

  Works on a FRESH database (tables created) AND adopts ANY pre-Ecto legacy
  database. Legacy DBs were managed by the raw-SQL `EvoGit.Store.Schema`
  pipeline, which left no `schema_migrations` table — so the Ecto migrator
  (seeing version 0) runs THIS migration against them. It is therefore
  idempotent by construction:

    * tables via `CREATE TABLE IF NOT EXISTS` — exact DDL from
      `EvoGit.Store.Schema.create_tables/1` (20-column `tasks`, 3-column
      `projects`)
    * for each task column missing from a legacy table, a NULLABLE
      `ALTER TABLE tasks ADD COLUMN <col> <type>` — nullable, no default,
      because SQLite refuses NOT NULL adds without a default on populated
      tables. Matches `EvoGit.Store.Schema.migrate_schema/1` exactly
      (lease_expires_at, model_id, project_path, branch_name, error,
      updated_at) — the six columns any pre-Ecto DB may lack.
    * the 6 indexes via `CREATE INDEX IF NOT EXISTS`, exactly as in
      `Schema.create_tables/1` — AFTER the columns: `idx_tasks_updated_at`
      references a column the ALTERs above may have just added.

  ## Why every statement runs via `repo().query!/3` (not `execute/1`)

  The migration must PROBE (`PRAGMA table_info`) between statements and
  branch on the result. `Ecto.Migration.execute/1` string commands are
  QUEUED and only executed at `flush/0` — AFTER the whole migration body
  returned — so an in-body probe sees the pre-migration state and the fresh
  database path would queue ALTERs for columns the `CREATE TABLE` just
  created ("duplicate column name"). `repo().query!/3` runs on the
  migration's own connection immediately, in body order, inside the
  migration transaction — the exact sequential semantics of the raw-SQL
  pipeline this replaces. Every statement is a single SQL statement.

  Defined as `up/0` (no `down/0`): rolling back a baseline adoption would
  drop user data, so it is deliberately irreversible.
  """

  use Ecto.Migration

  # {column, ddl type} pairs a legacy `tasks` table may lack, in the same
  # order Schema.migrate_schema/1 adds them.
  @legacy_columns [
    {"lease_expires_at", "INTEGER"},
    {"model_id", "TEXT"},
    {"project_path", "TEXT"},
    {"branch_name", "TEXT"},
    {"error", "TEXT"},
    {"updated_at", "TEXT"}
  ]

  @index_ddl [
    "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_finished_at ON tasks(finished_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_lease_expires_at ON tasks(lease_expires_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_project_path ON tasks(project_path)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON tasks(updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_started_at ON tasks(started_at)"
  ]

  @task_columns ~w(id type status opts started_at finished_at logs result review_status usage agent_count base_sha commit_sha archive_metadata lease_expires_at model_id project_path branch_name error updated_at)

  def up do
    # 1. Tables (fresh DB) — exact DDL from Schema.create_tables/1.
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
      archive_metadata TEXT,
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
    #    so a fresh DB sees all 20 and adds nothing), add the missing ones
    #    as NULLABLE — SQLite refuses NOT NULL adds without a default on
    #    populated tables.
    columns = existing_task_columns()

    for {column, type} <- @legacy_columns, column not in columns do
      sql("ALTER TABLE tasks ADD COLUMN #{column} #{type}")
    end

    # 3. Indexes LAST — idx_tasks_updated_at may reference a column the
    #    ALTERs above just added.
    for ddl <- @index_ddl, do: sql(ddl)

    # Invariant: after this migration the tasks table carries exactly the
    # 20 columns in order, on fresh AND adopted databases.
    case existing_task_columns() do
      [] -> raise_missing_columns("no tasks table after baseline adoption")
      columns when columns != @task_columns -> raise_missing_columns(columns)
      _columns -> :ok
    end
  end

  ## Helpers

  defp sql(statement), do: repo().query!(statement, [], log: false)

  # PRAGMA table_info(tasks) rows: [cid, name, type, notnull, dflt, pk].
  defp existing_task_columns do
    case repo().query("PRAGMA table_info(tasks)", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [_cid, name | _] -> name end)
      _other -> []
    end
  end

  defp raise_missing_columns(columns) do
    raise Ecto.MigrationError,
          "baseline adoption failed: expected the 20 tasks columns " <>
            "#{inspect(@task_columns)}, got #{inspect(columns)}"
  end
end
