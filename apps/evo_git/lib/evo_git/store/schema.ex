defmodule EvoGit.Store.Schema do
  @moduledoc """
  Schema creation and migration primitives for the EvoGit SQLite store.

  Handles table creation (tasks, projects, indexes), idempotent column
  migration (adds missing columns to existing databases), and the shared
  idempotent data migrations (`normalize_timestamps/1`, `canonicalize_results/1`,
  `canonicalize_opts/1`).

  The migration functions are the single source of truth, reused by both
  `EvoGit.Store.init/1` (which runs them at boot, every time) and the
  `mix migrate.store` Mix task (which additionally runs the denormalization
  backfills and drops the DETS-era quarantine tables).
  Every function here is safe to run repeatedly and is a no-op on a fresh or
  already-migrated database.

  No GenServer, no I/O beyond the SQLite connection passed in.
  """

  @doc """
  Creates the store tables and indexes if they don't already exist.

  Tables:
    * `tasks` — one row per task, column per field. Includes the
      store-internal `updated_at` column (20th, after `error`), which is
      deliberately NOT in `Codec.task_columns/0` / `%TaskInfo{}` — it is
      written/updated via targeted `update_task_columns` calls only. `error`
      (19th) is the dedicated failed-task error JSON column — it IS part of
      `Codec.task_columns/0` / `%TaskInfo{}`.
    * `projects` — one row per project.

  Indexes (idempotent — `IF NOT EXISTS`):
    * `idx_tasks_status`
    * `idx_tasks_finished_at`
    * `idx_tasks_lease_expires_at`
    * `idx_tasks_project_path`
    * `idx_tasks_updated_at` — backs the changed-since poll query
    * `idx_tasks_started_at` — backs `safe_select_paginated_tasks`'s
      `ORDER BY started_at DESC`

  Must run AFTER `migrate_schema/1` on a legacy database: the `idx_tasks_updated_at`
  index references a column that only the migration adds.
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
          error TEXT,
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

  `EvoGit.Store.init/1` calls this at boot BEFORE `Schema.create_tables/1` —
  that ordering is required because an index created there (`idx_tasks_updated_at`)
  references a column a legacy table may not have yet. The function is a plain
  no-op when the `tasks` table does not exist (fresh database) and returns
  `:ok` either way.

  `updated_at` is deliberately NOT in `EvoGit.Store.Codec.@task_columns` — it
  is store-internal bookkeeping, so only the DDL/ALTER here knows about it.
  `error` IS in `@task_columns` (a `%TaskInfo{}` field), but old databases
  still need the ALTER to add the column before full-row SELECTs/INSERTs can
  reference it. The column order (lease_expires_at, model_id, project_path,
  branch_name, error, updated_at) is unchanged.
  """
  def migrate_schema(conn) do
    if table_exists?(conn, "tasks") do
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

      if "error" not in columns do
        {:ok, _} = XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN error TEXT", [])
      end

      if "updated_at" not in columns do
        {:ok, _} =
          XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN updated_at TEXT", [])
      end
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

  Safe to run on every init (idempotent). Returns `:ok`. `EvoGit.Store.init/1`
  invokes it at boot (after `migrate_schema/1` and `create_tables/1`), and the
  `mix migrate.store` task invokes it too.
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
  Idempotent, strictly-canonical `result` rewrite.

  `EvoGit.Store.Codec.decode_result/1` accepts only `nil` plus the four tagged
  forms (`ok`/`error`/`exit`/`string`), so rows written before the v0.9.0
  canonical codec must be rewritten before they can be read:
  a JSON literal `null` text (`json_valid(result) = 1 AND json_type(result) = 'null'`)
  becomes SQL NULL; every other non-tagged value — raw non-JSON strings AND
  untagged JSON objects/arrays/scalars — is wrapped verbatim as
  `{"__result_tag__":"string","value":<original content>}` (`json_object/3`
  always turns its TEXT value argument into a JSON string, so the raw content
  round-trips exactly). Rows already carrying a `__result_tag__` are untouched.

  When SQLite's JSON1 functions are unavailable the function falls back to an
  Elixir read → `Jason.decode` → rewrite loop reproducing those SQL semantics
  exactly (decoded `nil` → SQL NULL, a decoded `%{"__result_tag__" => _}` map →
  untouched, anything else including a decode failure → the RAW column text is
  wrapped verbatim).

  Returns `%{nulls: non_neg_integer(), wraps: non_neg_integer()}` — the two
  rewrite counts (always `%{nulls: 0, wraps: 0}` on an already-canonical DB).
  """
  def canonicalize_results(conn) do
    if json1_available?(conn) do
      nulls =
        execute_changes(conn, """
          UPDATE tasks SET result = NULL
          WHERE result IS NOT NULL
            AND json_valid(result) = 1
            AND json_type(result) = 'null'
        """)

      wraps =
        execute_changes(conn, """
          UPDATE tasks SET result = json_object('__result_tag__','string','value',result)
          WHERE result IS NOT NULL
            AND (json_valid(result) = 0
                 OR json_extract(result, '$.__result_tag__') IS NULL)
        """)

      %{nulls: nulls, wraps: wraps}
    else
      {:ok, %{rows: rows}} =
        XqliteNIF.query(conn, "SELECT id, result FROM tasks WHERE result IS NOT NULL", [])

      Enum.reduce(rows, %{nulls: 0, wraps: 0}, fn [id, result], acc ->
        case Jason.decode(result) do
          {:ok, nil} ->
            {:ok, _} =
              XqliteNIF.execute(conn, "UPDATE tasks SET result = NULL WHERE id = ?1", [id])

            %{acc | nulls: acc.nulls + 1}

          {:ok, %{"__result_tag__" => _}} ->
            acc

          _ ->
            wrapped = Jason.encode!(%{"__result_tag__" => "string", "value" => result})

            {:ok, _} =
              XqliteNIF.execute(conn, "UPDATE tasks SET result = ?1 WHERE id = ?2", [wrapped, id])

            %{acc | wraps: acc.wraps + 1}
        end
      end)
    end
  end

  @doc """
  Idempotent rewrite of legacy `opts` rows — a JSON array of positional
  `[key, value]` pair arrays — into the current JSON-object format.

  The conversion is always done in Elixir (read → `Jason.decode` → `Map.new` →
  `Jason.encode!`) and never with `json_group_object`, which collapses JSON
  boolean values like `archive: true` to SQLite integers (1/0). A decoded list
  whose every element is a 2-element list is converted (`Map.new/2` over the
  pairs, string keys preserved, JSON values round-trip losslessly); malformed
  rows (a flat list, non-pair elements) and rows that are already objects are
  left untouched.

  The scan is narrowed with a SQL guard — `WHERE opts IS NOT NULL AND NOT
  (json_valid(opts) = 1 AND json_type(opts) = 'object')` — so it is a cheap
  no-op once every row is an object; when JSON1 is unavailable all
  `opts IS NOT NULL` rows are selected and filtered in Elixir instead.

  Returns the number of rows rewritten as a `non_neg_integer()` (0 when there
  is nothing to convert).
  """
  def canonicalize_opts(conn) do
    sql =
      if json1_available?(conn) do
        """
        SELECT id, opts FROM tasks
        WHERE opts IS NOT NULL AND NOT (json_valid(opts) = 1 AND json_type(opts) = 'object')
        """
      else
        "SELECT id, opts FROM tasks WHERE opts IS NOT NULL"
      end

    {:ok, %{rows: rows}} = XqliteNIF.query(conn, sql, [])

    Enum.reduce(rows, 0, fn [id, opts], acc ->
      case Jason.decode(opts) do
        # Legacy format: a JSON array of [key, value] pair arrays. Guard that
        # every element is a 2-element list first — a malformed row is left
        # alone.
        {:ok, pairs} when is_list(pairs) ->
          if Enum.all?(pairs, &(is_list(&1) and length(&1) == 2)) do
            new_opts =
              pairs
              |> Map.new(fn [k, v] -> {k, v} end)
              |> Jason.encode!()

            {:ok, _} =
              XqliteNIF.execute(conn, "UPDATE tasks SET opts = ?1 WHERE id = ?2", [new_opts, id])

            acc + 1
          else
            acc
          end

        # Already an object (or undecodable) — leave alone.
        _ ->
          acc
      end
    end)
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

  @doc """
  Returns `true` when `table` exists in the connection's database.

  Queries `sqlite_master` for a `type = 'table'` entry with the given name.
  """
  def table_exists?(conn, table) do
    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1", [
        table
      ])

    rows != []
  end

  @doc """
  Returns `true` when SQLite's JSON1 functions are available.

  Probes with `SELECT json_valid('{}')`, which returns `1` when JSON1 is
  compiled in and errors otherwise.
  """
  def json1_available?(conn) do
    case XqliteNIF.query(conn, "SELECT json_valid('{}')", []) do
      {:ok, %{rows: [[1] | _]}} -> true
      _ -> false
    end
  end

  # Runs a write statement and returns the number of affected rows.
  # Follows the module's crash-on-error style: a non-`:ok` NIF result raises a
  # MatchError.
  defp execute_changes(conn, sql, params \\ []) do
    {:ok, changes} = XqliteNIF.execute(conn, sql, params)
    changes
  end
end
