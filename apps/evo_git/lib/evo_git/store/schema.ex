defmodule EvoGit.Store.Schema do
  @moduledoc """
  Schema creation and migration for the EvoGit SQLite store.

  Handles table creation (tasks, projects, quarantine tables, indexes) and
  idempotent column migration (adds missing columns to existing databases).
  No GenServer, no I/O beyond the SQLite connection passed in.
  """

  @doc """
  Creates the store tables and indexes if they don't already exist.

  Tables:
    * `tasks` — one row per task, column per field.
    * `projects` — one row per project.
    * `tasks_quarantine` — undecodable task rows (raw JSON).
    * `projects_quarantine` — undecodable project rows (raw JSON).

  Indexes (idempotent — `IF NOT EXISTS`):
    * `idx_tasks_status`
    * `idx_tasks_finished_at`
    * `idx_tasks_lease_expires_at`
    * `idx_tasks_project_path`
  """
  def create_tables(conn) do
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
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
          branch_name TEXT
        )
        """,
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        CREATE TABLE IF NOT EXISTS projects (
          path TEXT PRIMARY KEY,
          name TEXT,
          last_opened_at TEXT
        )
        """,
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS tasks_quarantine (id TEXT PRIMARY KEY, data TEXT)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS projects_quarantine (id TEXT PRIMARY KEY, data TEXT)",
        []
      )

    # Indexes for common query patterns (idempotent — IF NOT EXISTS).
    {:ok, _} = XqliteNIF.execute(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)", [])
    {:ok, _} = XqliteNIF.execute(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_finished_at ON tasks(finished_at)", [])
    {:ok, _} = XqliteNIF.execute(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_lease_expires_at ON tasks(lease_expires_at)", [])
    {:ok, _} = XqliteNIF.execute(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_project_path ON tasks(project_path)", [])

    :ok
  end

  @doc """
  Idempotent schema migration: adds missing columns to the tasks table.

  Safe to run on every init, including fresh DBs where CREATE TABLE already
  includes the column. Checks `PRAGMA table_info` for each column before
  attempting `ALTER TABLE ADD COLUMN`.
  """
  def migrate_schema(conn) do
    columns = existing_columns(conn, "tasks")

    if "lease_expires_at" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN lease_expires_at INTEGER", [])
    end

    if "model_id" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN model_id TEXT", [])
    end

    if "project_path" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN project_path TEXT", [])
    end

    if "branch_name" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN branch_name TEXT", [])
    end

    :ok
  end

  @doc """
  Reads the column names from a table via `PRAGMA table_info(table)`.

  Returns a list of column name strings.
  """
  def existing_columns(conn, table) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(#{table})", [])
    # PRAGMA table_info returns rows of [cid, name, type, notnull, dflt_value, pk]
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end
end
