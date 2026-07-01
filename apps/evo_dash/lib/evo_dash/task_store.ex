defmodule EvoDash.TaskStore do
  @moduledoc """
  SQLite-backed persistent store for EvoDash tasks and recent projects.

  A single GenServer wrapping one xqlite (SQLite) connection (started under
  supervision before `EvoDash.TaskRegistry`) holds both data sets under
  namespaced keys:

    * `{:task, task_id}`  → `%EvoDash.TaskRegistry.TaskInfo{}`
    * `{:project, path}`  → `%{path:, name:, last_opened_at:}`

  Internally the data lives in two SQLite tables — `tasks` (keyed by task id)
  and `projects` (keyed by project path) — with values stored as
  `:erlang.term_to_binary/1` BLOBs.

  This module also provides crash-safe read/recovery helpers that survive
  corrupt (un-deserializable) entries in the underlying SQLite database.
  """

  use GenServer

  require Logger

  ## Child spec & start

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts the SQLite store GenServer.

  ## Options

    * `:data_dir` — (required) filesystem path for the SQLite database FILE.
    * `:name` — (optional) registration name, defaults to `__MODULE__`.
  """
  def start_link(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, %{data_dir: data_dir, name: name}, name: name)
  end

  ## Public key-value API

  @doc """
  Reads a key, returning the stored value or `nil` if not found.

  `key` is a tuple: `{:task, id}` or `{:project, path}`.
  """
  def get(store \\ __MODULE__, key) do
    GenServer.call(store, {:get, key})
  end

  @doc """
  Writes a key/value pair. `key` is `{:task, id}` or `{:project, path}`.
  The value is serialized via `:erlang.term_to_binary/1` and stored as a BLOB.
  Returns `:ok`.
  """
  def put(store \\ __MODULE__, key, value) do
    GenServer.call(store, {:put, key, value})
  end

  @doc """
  Deletes a single key. Returns `:ok`.
  """
  def delete(store \\ __MODULE__, key) do
    GenServer.call(store, {:delete, key})
  end

  @doc """
  Deletes multiple keys in one call. `keys` is a list of tuples.
  Returns `:ok`.
  """
  def delete_multi(store \\ __MODULE__, keys) do
    GenServer.call(store, {:delete_multi, keys})
  end

  @doc """
  Returns all entries from both tables as a list of `{{:task, id}, value}` and
  `{{:project, path}, value}` tuples. Each BLOB is decoded via
  `:erlang.binary_to_term/1`.
  """
  def select_all(store \\ __MODULE__) do
    GenServer.call(store, :select_all)
  end

  @doc """
  Returns the total number of rows across both tables.
  """
  def size(store \\ __MODULE__) do
    GenServer.call(store, :size)
  end

  @doc """
  Deletes all rows from both tables. Returns `:ok`.
  Used by `integrity_check/1` during a rebuild.
  """
  def clear(store \\ __MODULE__) do
    GenServer.call(store, :clear)
  end

  ## Crash-safe helpers

  @doc """
  Safely reads a key, returning `nil` on any error (including corrupt blobs).
  """
  def safe_get(store \\ __MODULE__, key) do
    try do
      get(store, key)
    rescue
      _ -> nil
    end
  end

  @doc """
  Enumerates all entries, skipping rows whose blobs fail to decode.
  Never raises. Returns a list of `{key, value}` tuples.
  """
  def safe_select_all(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all)
  end

  @doc """
  Returns the store size, rescuing any error to `0`.
  """
  def safe_size(store \\ __MODULE__) do
    try do
      size(store)
    rescue
      _ -> 0
    end
  end

  @doc """
  Checks store integrity and repairs corruption.

  1. Runs `PRAGMA integrity_check` to verify SQLite structural health.
  2. Scans all rows in both tables, decoding each blob.
     * Undecodable **`tasks`** rows are hard-deleted (lower-value, auto-expiring).
     * Undecodable **`projects`** rows are **QUARANTINED** — the raw blob is
       moved to the `projects_quarantine` table (preserved for recovery), never
       destroyed, since a lost project path silently erases a recently-opened
       project.

  Returns:
    * `:ok` — store is healthy.
    * `{:repaired, lost_count}` — some undecodable rows were removed/quarantined.
    * `{:error, reason}` — SQLite-level corruption detected.
  """
  def integrity_check(store \\ __MODULE__) do
    GenServer.call(store, :integrity_check)
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir}) do
    dir = Path.dirname(data_dir)
    File.mkdir_p!(dir)

    case Xqlite.open(data_dir) do
      {:ok, conn} ->
        create_tables(conn)

        {:ok, %{conn: conn, data_dir: data_dir}}

      {:error, reason} ->
        {:stop, {:failed_to_open_sqlite, reason}}
    end
  end

  defp create_tables(conn) do
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, data BLOB)",
        []
      )

    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, data BLOB)",
        []
      )

    # Quarantine table: when integrity_check finds an undecodable `projects`
    # row, the raw blob is moved here (INSERT then DELETE) instead of being
    # hard-deleted. This preserves the data for later recovery/diagnosis.
    # `projects` is small (≤10 rows) and high-value (a recently-opened project
    # path), so destroying it on a transient decode failure would silently
    # erase a user's project. Tasks remain hard-deletable (lower-value,
    # auto-expiring).
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS projects_quarantine (id TEXT PRIMARY KEY, data BLOB)",
        []
      )

    # Quarantine table for tasks (mirrors projects_quarantine). When
    # integrity_check finds an undecodable `tasks` row, the raw blob is moved
    # here (INSERT then DELETE) instead of being hard-deleted. This preserves
    # the data for later recovery/diagnosis. Both tables are now quarantined
    # for defense-in-depth.
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS tasks_quarantine (id TEXT PRIMARY KEY, data BLOB)",
        []
      )

    # Idempotent schema repair: some existing databases have the `projects`
    # table created with a `path` primary-key column (from commit 0989e6f9)
    # instead of `id`. Since `CREATE TABLE IF NOT EXISTS` is a no-op on an
    # existing table, the wrong schema persists forever — every read/write
    # referencing column `id` fails. Detect and rebuild.
    repair_projects_table(conn)

    :ok
  end

  # Idempotent schema repair for the `projects` table.
  #
  # Historical bug (commit 0989e6f9): the `projects` table was created with a
  # `path` column as the primary key instead of `id`. All SQL in this module
  # references column `id`, so a stale-schema table causes every read/write to
  # fail. This detects the old schema (via PRAGMA table_info) and rebuilds the
  # table with the correct column name, preserving all data BLOBs.
  #
  # Wrapped in try/rescue so a migration hiccup NEVER blocks startup.
  defp repair_projects_table(conn) do
    try do
      pk_column = projects_pk_column(conn)

      if pk_column && pk_column != "id" do
        # Stale schema detected — rebuild with the correct column name.
        old_column = pk_column

        # 1. Read all existing rows using the OLD column name.
        {:ok, %{rows: rows}} =
          XqliteNIF.query(conn, "SELECT #{old_column}, data FROM projects", [])

        # 2. Drop and recreate with the correct schema.
        {:ok, _} = XqliteNIF.execute(conn, "DROP TABLE projects", [])

        {:ok, _} =
          XqliteNIF.execute(
            conn,
            "CREATE TABLE projects (id TEXT PRIMARY KEY, data BLOB)",
            []
          )

        # 3. Re-insert rows, mapping old_column value → id column.
        for [id_value, blob] <- rows do
          {:ok, _} =
            XqliteNIF.execute(
              conn,
              "INSERT INTO projects (id, data) VALUES (?1, ?2)",
              [id_value, blob]
            )
        end

        Logger.warning(
          "TaskStore: repaired projects table schema (column " <>
            "'#{old_column}' → 'id'), migrated #{length(rows)} row(s)."
        )
      end
    rescue
      error ->
        Logger.error(
          "TaskStore: projects table schema repair failed: " <>
            "#{Exception.message(error)}"
        )
    end
  end

  # Returns the primary-key column name for the `projects` table, or nil if
  # the table has no primary key or the query fails.
  defp projects_pk_column(conn) do
    case XqliteNIF.query(conn, "PRAGMA table_info(projects)", []) do
      {:ok, %{rows: rows}} ->
        # Each row: [cid, name, type, notnull, dflt_value, pk]
        # pk is 0 for non-PK columns, a positive integer for PK columns.
        Enum.find_value(rows, fn
          [_cid, name, _type, _notnull, _dflt, pk]
          when is_integer(pk) and pk > 0 ->
            name

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {table, value_key} = resolve_key(key)
    reply = do_get(state.conn, table, value_key)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    {table, value_key} = resolve_key(key)
    blob = :erlang.term_to_binary(value)

    {:ok, _} =
      XqliteNIF.execute(
        state.conn,
        "INSERT OR REPLACE INTO #{table} (id, data) VALUES (?1, ?2)",
        [value_key, blob]
      )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    {table, value_key} = resolve_key(key)

    {:ok, _} =
      XqliteNIF.execute(
        state.conn,
        "DELETE FROM #{table} WHERE id = ?1",
        [value_key]
      )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete_multi, keys}, _from, state) do
    for key <- keys do
      {table, value_key} = resolve_key(key)

      {:ok, _} =
        XqliteNIF.execute(
          state.conn,
          "DELETE FROM #{table} WHERE id = ?1",
          [value_key]
        )
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:select_all, _from, state) do
    tasks = read_all_table(state.conn, "tasks", :task)
    projects = read_all_table(state.conn, "projects", :project)
    {:reply, tasks ++ projects, state}
  end

  @impl true
  def handle_call(:size, _from, state) do
    count = count_table(state.conn, "tasks") + count_table(state.conn, "projects")
    {:reply, count, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:ok, _} = XqliteNIF.execute(state.conn, "DELETE FROM tasks", [])
    {:ok, _} = XqliteNIF.execute(state.conn, "DELETE FROM projects", [])
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:safe_select_all, _from, state) do
    tasks = safe_read_all_table(state.conn, "tasks", :task)
    projects = safe_read_all_table(state.conn, "projects", :project)
    {:reply, tasks ++ projects, state}
  end

  @impl true
  def handle_call(:integrity_check, _from, state) do
    result = do_integrity_check(state.conn)
    {:reply, result, state}
  end

  ## Private helpers — key resolution

  # Maps the public tuple key convention to {table, value_key}.
  defp resolve_key({:task, id}), do: {"tasks", id}
  defp resolve_key({:project, path}), do: {"projects", path}

  ## Private helpers — read/write

  defp do_get(conn, table, value_key) do
    case XqliteNIF.query(conn, "SELECT data FROM #{table} WHERE id = ?1", [value_key]) do
      {:ok, %{rows: [[blob | _] | _]}} ->
        :erlang.binary_to_term(blob, [:safe])

      {:ok, %{rows: []}} ->
        nil

      {:ok, %{rows: rows}} when is_list(rows) ->
        # Fallback for unexpected row shapes
        case List.first(rows) do
          [blob] -> :erlang.binary_to_term(blob, [:safe])
          _ -> nil
        end
    end
  end

  defp count_table(conn, table) do
    {:ok, %{rows: [[count]]}} = XqliteNIF.query(conn, "SELECT COUNT(*) FROM #{table}", [])
    count
  end

  defp read_all_table(conn, table, ns) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "SELECT id, data FROM #{table}", [])

    Enum.map(rows, fn [id, blob] ->
      {{ns, id}, :erlang.binary_to_term(blob, [:safe])}
    end)
  end

  defp safe_read_all_table(conn, table, ns) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "SELECT id, data FROM #{table}", [])

    Enum.flat_map(rows, fn [id, blob] ->
      try do
        [{{ns, id}, :erlang.binary_to_term(blob, [:safe])}]
      rescue
        e ->
          # Skip rows whose blob fails to decode — don't let one bad row
          # poison the entire read.
          Logger.warning("Skipping undecodable row in table #{table} (id: #{inspect(id)}): #{Exception.message(e)}")
          []
      end
    end)
  end

  ## Private helpers — integrity check

  defp do_integrity_check(conn) do
    try do
      # 1. SQLite structural integrity check via PRAGMA
      case XqliteNIF.query(conn, "PRAGMA integrity_check", []) do
        {:ok, %{rows: [["ok"]]}} ->
          :ok

        {:ok, %{rows: rows}} ->
          reason = inspect(rows)
          Logger.error("SQLite integrity_check reports problems: #{reason}")
          {:error, reason}

        {:error, reason} ->
          Logger.error("SQLite integrity_check query failed: #{inspect(reason)}")
          {:error, reason}
      end
      |> then(fn pragma_result ->
        # 2. Scan all rows for undecodable blobs regardless of PRAGMA result,
        #    but only salvage/repair if the PRAGMA was healthy.
        case pragma_result do
          :ok ->
            corrupt = scan_and_repair_corrupt_rows(conn)
            if corrupt > 0 do
              {:repaired, corrupt}
            else
              :ok
            end

          other ->
            other
        end
      end)
    rescue
      error ->
        Logger.error("integrity_check failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # Scans both tables for rows whose blobs fail to decode. BOTH tasks and
  # projects are QUARANTINED for defense-in-depth — the raw blob is preserved
  # in `<table>_quarantine` for recovery/diagnosis rather than being
  # hard-deleted. Returns the total count of removed-from-live-table rows.
  defp scan_and_repair_corrupt_rows(conn) do
    scan_table_for_corrupt(conn, "tasks", :quarantine) +
      scan_table_for_corrupt(conn, "projects", :quarantine)
  end

  # `mode` is :delete (hard-delete the row) or :quarantine (move the raw blob
  # into `<table>_quarantine`, preserving it). Quarantine failures are logged
  # but the row is left in place rather than destroyed.
  defp scan_table_for_corrupt(conn, table, mode) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "SELECT id, data FROM #{table}", [])

    Enum.reduce(rows, 0, fn [id, blob], acc ->
      case try_decode(blob) do
        :ok ->
          acc

        :error ->
          case mode do
            :delete ->
              {:ok, _} =
                XqliteNIF.execute(conn, "DELETE FROM #{table} WHERE id = ?1", [id])

            :quarantine ->
              quarantine_corrupt_row(conn, table, id, blob)
          end

          acc + 1
      end
    end)
  end

  # Moves an undecodable row into the quarantine table (INSERT raw blob then
  # DELETE from the live table). If the quarantine INSERT itself fails, we log
  # an error and LEAVE THE ROW IN PLACE — never silently destroy data. The raw
  # blob is stored as-is (it can't be decoded, but is recoverable for later
  # diagnosis).
  defp quarantine_corrupt_row(conn, table, id, blob) do
    quarantine_table = "#{table}_quarantine"

    insert_result =
      try do
        XqliteNIF.execute(
          conn,
          "INSERT OR REPLACE INTO #{quarantine_table} (id, data) VALUES (?1, ?2)",
          [id, blob]
        )
      rescue
        error ->
          Logger.error(
            "TaskStore integrity check: failed to quarantine undecodable row " <>
              "(table=#{table}, id=#{inspect(id)}): #{Exception.message(error)}. " <>
              "Leaving row in place — data NOT destroyed."
          )

          :error
      end

    case insert_result do
      {:ok, _} ->
        # Quarantine succeeded — now safe to remove from the live table.
        {:ok, _} =
          XqliteNIF.execute(conn, "DELETE FROM #{table} WHERE id = ?1", [id])

        Logger.warning(
          "TaskStore integrity check: quarantined undecodable row " <>
            "(table=#{table}, id=#{inspect(id)}) → #{quarantine_table}. " <>
            "Raw blob preserved for recovery."
        )

      :error ->
        :ok
    end
  end

  defp try_decode(blob) do
    :erlang.binary_to_term(blob, [:safe])
    :ok
  rescue
    _ -> :error
  end
end
