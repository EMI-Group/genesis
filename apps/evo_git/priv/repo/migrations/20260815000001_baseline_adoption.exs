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

  Runs transactionally (the adapter supports DDL transactions). `execute/1`
  is exactly ONE statement per call — every statement here is standalone.
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

  @impl Ecto.Migration
  def change do
    # 1. Tables (fresh DB) — exact DDL from Schema.create_tables/1.
    execute("""
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

    execute("""
      CREATE TABLE IF NOT EXISTS projects (
        path TEXT PRIMARY KEY,
        name TEXT,
        last_opened_at TEXT
      )
    """)

    # 2. Adopt a legacy `tasks` table: probe existing columns, add the
    #    missing ones as NULLABLE (SQLite refuses NOT NULL adds without a
    #    default on populated tables).
    columns = existing_task_columns()

    for {column, type} <- @legacy_columns, column not in columns do
      execute("ALTER TABLE tasks ADD COLUMN #{column} #{type}")
    end

    # 3. Indexes LAST — idx_tasks_updated_at may reference a column the
    #    ALTERs above just added.
    for ddl <- @index_ddl, do: execute(ddl)
  end

  # `PRAGMA table_info(tasks)` rows: [cid, name, type, notnull, dflt, pk].
  # No tasks table (impossible after step 1, but defensive) → [].
  defp existing_task_columns do
    case repo().query("PRAGMA table_info(tasks)", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [_cid, name | _] -> name end)
      _other -> []
    end
  end
end
