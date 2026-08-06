defmodule EvoGit.Store.Schema do
  @moduledoc """
  Schema creation and migration for the EvoGit SQLite store.

  Handles table creation (tasks, projects, indexes) and idempotent column
  migration (adds missing columns to existing databases). Also provides
  `normalize_timestamps/1`, a one-time data migration that rewrites existing
  rows to the fixed-precision timestamp format.
  No GenServer, no I/O beyond the SQLite connection passed in.
  """

  @doc """
  Creates the store tables and indexes if they don't already exist.

  Tables:
    * `tasks` — one row per task, column per field. Includes the
      store-internal `updated_at` column (19th, after `branch_name`), which is
      deliberately NOT in `Codec.task_columns/0` / `%TaskInfo{}` — it is
      written/updated via targeted `update_task_columns` calls only.
    * `projects` — one row per project.

  Indexes (idempotent — `IF NOT EXISTS`):
    * `idx_tasks_status`
    * `idx_tasks_finished_at`
    * `idx_tasks_lease_expires_at`
    * `idx_tasks_project_path`
    * `idx_tasks_updated_at` — backs the changed-since poll query
    * `idx_tasks_started_at` — backs `safe_select_paginated_tasks`'s
      `ORDER BY started_at DESC`
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
          branch_name TEXT,
          updated_at TEXT
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

    # Indexes for common query patterns (idempotent — IF NOT EXISTS).
    {:ok, _} =
      XqliteNIF.execute(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)", [])

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_tasks_finished_at ON tasks(finished_at)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_tasks_lease_expires_at ON tasks(lease_expires_at)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_tasks_project_path ON tasks(project_path)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON tasks(updated_at)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_tasks_started_at ON tasks(started_at)",
        []
      )

    :ok
  end

  @doc """
  Idempotent schema migration: adds missing columns to the tasks table.

  Safe to run on every init, including fresh DBs where CREATE TABLE already
  includes the column. Checks `PRAGMA table_info` for each column before
  attempting `ALTER TABLE ADD COLUMN`.

  Since `EvoGit.Store.init/1` no longer auto-migrates, this is the upgrade
  path for OLD databases: the `mix migrate.store` Mix task invokes this
  function to bring an existing DB up to the current schema (including the
  `updated_at` column). `updated_at` is deliberately NOT in
  `EvoGit.Store.Codec.@task_columns` — it is store-internal bookkeeping, so
  only the DDL/ALTER here knows about it.
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

    if "updated_at" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN updated_at TEXT", [])
    end

    :ok
  end

  @doc """
  Idempotent, SQL-only, one-time data migration that normalizes existing
  timestamp rows to the fixed-precision format emitted by
  `EvoGit.Store.Codec.encode_datetime/1` (`%Y-%m-%dT%H:%M:%S.SSSZ`,
  exactly 3 fractional digits, e.g. `2024-01-01T12:00:00.123Z`).

  Older rows were written by `DateTime.to_iso8601/1` with `:auto` precision,
  which emits variable fractional digits (`"…00Z"` for whole seconds vs
  `"…00.123456Z"` with microseconds). That mixed-precision format breaks
  lexicographic ordering of the TEXT timestamps in SQLite (e.g.
  `ORDER BY started_at DESC` mis-sorts), so this migration rewrites all
  parseable rows into the constant 24-char sortable form.

  Semantics of the guards (each UPDATE is a separate statement):

    * `started_at NOT GLOB '*.[0-9][0-9][0-9]Z'` — the GLOB pattern matches
      values already ending in exactly 3 fractional digits + `Z` (the fixed
      format), making the migration a no-op after the first run. `%f` emits
      `SS.SSS` (exactly 3 digits), so an already-normalized value round-trips
      unchanged and never matches the "needs fixing" predicate.
    * `julianday(...) IS NOT NULL` — protects unparseable rows (NULL result
      from `julianday/1`) from being overwritten with NULL; such rows are
      skipped and left as-is.

  Safe to run on every init (idempotent). Returns `:ok`. A caller in
  `EvoGit.Store.init/1` invokes it after `migrate_schema/1`.
  """
  def normalize_timestamps(conn) do
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        UPDATE tasks SET started_at = strftime('%Y-%m-%dT%H:%M:%fZ', started_at)
        WHERE started_at IS NOT NULL AND started_at NOT GLOB '*.[0-9][0-9][0-9]Z' AND julianday(started_at) IS NOT NULL
        """,
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        UPDATE tasks SET finished_at = strftime('%Y-%m-%dT%H:%M:%fZ', finished_at)
        WHERE finished_at IS NOT NULL AND finished_at NOT GLOB '*.[0-9][0-9][0-9]Z' AND julianday(finished_at) IS NOT NULL
        """,
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        UPDATE projects SET last_opened_at = strftime('%Y-%m-%dT%H:%M:%fZ', last_opened_at)
        WHERE last_opened_at IS NOT NULL AND last_opened_at NOT GLOB '*.[0-9][0-9][0-9]Z' AND julianday(last_opened_at) IS NOT NULL
        """,
        []
      )

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
