defmodule EvoDash.Store do
  @moduledoc """
  SQLite-backed persistent store for EvoDash tasks and recent projects.

  A single GenServer wrapping one xqlite (SQLite) connection. Data lives in
  column-based tables with JSON encoding for complex fields — no opaque
  Erlang term BLOBs. All serialization is delegated to `EvoDash.Store.Codec`.

  Tables:
    * `tasks` — one row per `EvoDash.TaskInfo`, one column per field.
    * `projects` — one row per `EvoDash.RecentProject`.
    * `tasks_quarantine` — undecodable task rows moved here (raw JSON) for recovery.
    * `projects_quarantine` — undecodable project rows moved here for recovery.

  ## Crash philosophy

  The `handle_call`/`handle_cast`/`handle_info` callbacks have NO try/rescue
  wrappers. If a SQLite read/write fails, the GenServer crashes and the
  supervisor restarts it with a fresh connection. Data is safe in SQLite WAL
  mode (`journal_mode=WAL`, `synchronous=NORMAL`).

  The codec (`EvoDash.Store.Codec`) uses non-crashing `Jason.encode/1` + `case`
  for TOTAL encode (no try/rescue). Decode functions raise on bad data by
  design — the quarantine/recovery logic below catches those failures.

  The only justified try/rescue patterns that remain are:
    * `terminate/2` — graceful connection close during shutdown. GenServer
      terminate/2 must never raise; a crash here could prevent clean
      supervision shutdown.
    * `safe_select_all_rows`, `safe_decode_rows`, `scan_and_repair` — quarantine/data-recovery
      boundaries that deliberately catch decode failures to quarantine corrupt
      rows rather than crashing. The decoder raises by design; quarantine is the
      deliberate recovery boundary.
    * `do_integrity_check` — a diagnostic/recovery routine called during
      TaskRegistry init. It must return `{:error, _}` rather than crashing,
      because a crash here would prevent TaskRegistry from starting.
    * `quarantine_row` (INSERT/DELETE) — data-recovery boundary that must never
      destroy data; if the quarantine INSERT fails, the row is left in place.
  """

  use GenServer

  require Logger

  alias EvoDash.Store.Codec
  alias EvoDash.TaskInfo
  alias EvoDash.RecentProject

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

  ## Public API — Tasks

  @doc "Inserts or replaces a task. Validates that id (string) and status are present."
  def put_task(store \\ __MODULE__, task)

  def put_task(store, %TaskInfo{} = task) do
    GenServer.call(store, {:put_task, task})
  end

  def put_task(_store, _other) do
    {:error, :invalid_task_struct}
  end

  @doc "Reads a single task by id, returning the struct or nil."
  def get_task(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:get_task, task_id})
  end

  @doc "Deletes a single task by id."
  def delete_task(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:delete_task, task_id})
  end

  @doc "Deletes multiple tasks by id in one call. `task_ids` is a list of id strings."
  def delete_tasks(store \\ __MODULE__, task_ids) do
    GenServer.call(store, {:delete_tasks, task_ids})
  end

  @doc "Returns all tasks as a list of TaskInfo structs."
  def select_all_tasks(store \\ __MODULE__) do
    GenServer.call(store, :select_all_tasks)
  end

  @doc "Returns the number of task rows."
  def count_tasks(store \\ __MODULE__) do
    GenServer.call(store, :count_tasks)
  end

  @doc """
  Returns a paginated slice of tasks (most-recent-first) together with the
  total task count.

  `opts` is a keyword list accepting:
    * `:limit` — max number of tasks to return (positive integer; defaults
      to 50 when `nil` or invalid).
    * `:offset` — number of tasks to skip (non-negative integer; defaults
      to 0 when `nil` or invalid).

  Returns `{tasks, total_count}` where `tasks` is a list of `TaskInfo`
  structs and `total_count` is an integer (total rows in the table,
  independent of the page). Rows that fail to decode are quarantined (same
  quarantine boundary as `safe_select_all_tasks/1`).
  """
  def safe_select_paginated_tasks(store \\ __MODULE__, opts) do
    GenServer.call(store, {:safe_select_paginated_tasks, opts})
  end

  @doc "Deletes all task rows."
  def clear_tasks(store \\ __MODULE__) do
    GenServer.call(store, :clear_tasks)
  end

  ## Public API — Projects

  @doc "Inserts or replaces a project. Validates that path is present."
  def put_project(store \\ __MODULE__, project)

  def put_project(store, %RecentProject{} = project) do
    GenServer.call(store, {:put_project, project})
  end

  def put_project(_store, _other) do
    {:error, :invalid_project_struct}
  end

  @doc "Reads a single project by path, returning the struct or nil."
  def get_project(store \\ __MODULE__, path) do
    GenServer.call(store, {:get_project, path})
  end

  @doc "Deletes a single project by path."
  def delete_project(store \\ __MODULE__, path) do
    GenServer.call(store, {:delete_project, path})
  end

  @doc "Returns all projects as a list of RecentProject structs."
  def select_all_projects(store \\ __MODULE__) do
    GenServer.call(store, :select_all_projects)
  end

  @doc "Returns the number of project rows."
  def count_projects(store \\ __MODULE__) do
    GenServer.call(store, :count_projects)
  end

  ## Public API — Safety / Integrity

  @doc """
  Enumerates all tasks, quarantining (not raising on) rows that fail to decode.
  Bad rows are moved to `tasks_quarantine` and skipped from the returned list.
  """
  def safe_select_all_tasks(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all_tasks)
  end

  @doc """
  Enumerates all projects, quarantining (not raising on) rows that fail to decode.
  Bad rows are moved to `projects_quarantine` and skipped from the returned list.
  """
  def safe_select_all_projects(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all_projects)
  end

  @doc """
  Checks store integrity and repairs corruption.

  1. Runs `PRAGMA integrity_check` to verify SQLite structural health.
  2. Scans all rows in both tables, decoding each into the proper struct.
     Undecodable rows are QUARANTINED — the raw column data is serialized as
     JSON and moved to the corresponding quarantine table, then deleted from
     the live table.

  Returns:
    * `:ok` — store is healthy.
    * `{:repaired, count}` — some undecodable rows were quarantined.
    * `{:error, reason}` — SQLite-level corruption detected.
  """
  def integrity_check(store \\ __MODULE__) do
    GenServer.call(store, :integrity_check)
  end

  @doc "Returns the total number of rows across both tables."
  def size(store \\ __MODULE__) do
    GenServer.call(store, :size)
  end

  @doc """
  Attempts to recover rows from the quarantine tables back into the live tables.

  Reads all rows from `tasks_quarantine` and `projects_quarantine`, decodes
  the stored JSON column data, and tries to re-decode each row through the
  Codec. Rows that now decode successfully (e.g. after a codec bugfix) are
  INSERT OR REPLACE'd back into the live table and deleted from quarantine.
  Rows that still fail to decode are left in quarantine untouched.

  Returns `{:ok, recovered_count}` where `recovered_count` is the total number
  of rows successfully recovered across both quarantine tables.
  """
  def recover_quarantine(store \\ __MODULE__) do
    GenServer.call(store, :recover_quarantine)
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir}) do
    dir = Path.dirname(data_dir)
    File.mkdir_p!(dir)

    case Xqlite.open(data_dir, journal_mode: :wal, synchronous: :normal, cache_size: -2000) do
      {:ok, conn} ->
        create_tables(conn)
        migrate_schema(conn)

        {:ok, %{conn: conn, data_dir: data_dir}}

      {:error, reason} ->
        {:stop, {:failed_to_open_sqlite, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn} = _state) do
    # Justified try/rescue: (1) Do we expect an error here? Possibly — the
    # connection may already be closed or in a bad state during shutdown.
    # (2) Is try/rescue cleanest? Yes — GenServer terminate/2 must NEVER raise;
    # a crash here could prevent clean supervision shutdown and leave the process
    # in a half-dead state.
    try do
      XqliteNIF.close(conn)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  ## GenServer — Task handlers

  @impl true
  def handle_call({:put_task, task}, _from, state) do
    reply =
      case Codec.validate_task(task) do
        :ok ->
          # Diagnostic logging at the ULTIMATE chokepoint: every task write goes
          # through here. When writing :failed, check the previous status and log
          # if this is a NEW transition into :failed. This SELECT is ONLY performed
          # when task.status == :failed (not on every put_task) for efficiency.
          if task.status == :failed do
            log_failed_write_if_transition(state.conn, task)
          end

          # Always null the ref before persistence — it is runtime-only.
          task = %{task | ref: nil}
          values = Codec.encode_task(task)

          {:ok, _} =
            XqliteNIF.execute(
              state.conn,
              """
              INSERT OR REPLACE INTO tasks
              (id, type, status, opts, started_at, finished_at, logs,
               result, review_status, usage, agent_count, base_sha, commit_sha,
               archive_metadata, lease_expires_at, model_id)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
              """,
              values
            )

          :ok

        error ->
          error
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, task_select_sql() <> " WHERE id = ?1", [task_id]) do
        {:ok, %{rows: [row | _]}} -> Codec.decode_task(row)
        {:ok, %{rows: []}} -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:delete_task, task_id}, _from, state) do
    {:ok, _} = XqliteNIF.execute(state.conn, "DELETE FROM tasks WHERE id = ?1", [task_id])
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete_tasks, task_ids}, _from, state) do
    Enum.each(task_ids, fn task_id ->
      {:ok, _} = XqliteNIF.execute(state.conn, "DELETE FROM tasks WHERE id = ?1", [task_id])
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:select_all_tasks, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, task_select_sql(), []) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &Codec.decode_task/1)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:count_tasks, _from, state) do
    {:ok, %{rows: [[count]]}} = XqliteNIF.query(state.conn, "SELECT COUNT(*) FROM tasks", [])
    {:reply, count, state}
  end

  @impl true
  def handle_call({:safe_select_paginated_tasks, opts}, _from, state) do
    filters = Keyword.get(opts, :filters, [])
    {where_clause, where_params} = build_where(filters)
    limit = clamp_limit(Keyword.get(opts, :limit))
    offset = clamp_offset(Keyword.get(opts, :offset))

    limit_idx = length(where_params) + 1
    offset_idx = length(where_params) + 2

    select_sql =
      task_select_sql() <> where_clause <>
        " ORDER BY started_at DESC LIMIT ?" <> Integer.to_string(limit_idx) <>
        " OFFSET ?" <> Integer.to_string(offset_idx)

    select_params = where_params ++ [limit, offset]

    rows =
      case XqliteNIF.query(state.conn, select_sql, select_params) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    # Reuse the SAME quarantine-safe decode boundary as safe_select_all_rows.
    tasks = safe_decode_rows(state.conn, "tasks", rows, &Codec.decode_task/1)

    # COUNT with the SAME WHERE clause so total_count reflects filtered results.
    count_sql = "SELECT COUNT(*) FROM tasks" <> where_clause
    {:ok, %{rows: [[total_count]]}} = XqliteNIF.query(state.conn, count_sql, where_params)

    {:reply, {tasks, total_count}, state}
  end

  @impl true
  def handle_call(:clear_tasks, _from, state) do
    {:ok, _} = XqliteNIF.execute(state.conn, "DELETE FROM tasks", [])
    {:reply, :ok, state}
  end

  ## GenServer — Project handlers

  @impl true
  def handle_call({:put_project, project}, _from, state) do
    reply =
      case Codec.validate_project(project) do
        :ok ->
          values = Codec.encode_project(project)

          {:ok, _} =
            XqliteNIF.execute(
              state.conn,
              "INSERT OR REPLACE INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
              values
            )

          :ok

        error ->
          error
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_project, path}, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, project_select_sql() <> " WHERE path = ?1", [path]) do
        {:ok, %{rows: [row | _]}} -> Codec.decode_project(row)
        {:ok, %{rows: []}} -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:delete_project, path}, _from, state) do
    {:ok, _} = XqliteNIF.execute(state.conn, "DELETE FROM projects WHERE path = ?1", [path])
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:select_all_projects, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, project_select_sql(), []) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &Codec.decode_project/1)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:count_projects, _from, state) do
    {:ok, %{rows: [[count]]}} = XqliteNIF.query(state.conn, "SELECT COUNT(*) FROM projects", [])
    {:reply, count, state}
  end

  ## GenServer — Size & Safety handlers

  @impl true
  def handle_call(:size, _from, state) do
    count = count_table(state.conn, "tasks") + count_table(state.conn, "projects")
    {:reply, count, state}
  end

  @impl true
  def handle_call(:safe_select_all_tasks, _from, state) do
    reply = safe_select_all_rows(state.conn, "tasks", &Codec.decode_task/1)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:safe_select_all_projects, _from, state) do
    reply = safe_select_all_rows(state.conn, "projects", &Codec.decode_project/1)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:integrity_check, _from, state) do
    reply = do_integrity_check(state.conn)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:recover_quarantine, _from, state) do
    reply = do_recover_quarantine(state.conn)
    {:reply, reply, state}
  end

  ## Private — Schema creation

  defp create_tables(conn) do
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
          model_id TEXT
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

    :ok
  end

  ## Private — Schema migration

  # Idempotent schema migration: adds the `lease_expires_at` column to the tasks
  # table if it doesn't already exist (handles databases created before the
  # column was introduced). Safe to run on every init, including fresh DBs where
  # CREATE TABLE already includes the column.
  defp migrate_schema(conn) do
    columns = existing_columns(conn, "tasks")

    if "lease_expires_at" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN lease_expires_at INTEGER", [])
    end

    if "model_id" not in columns do
      {:ok, _} =
        XqliteNIF.execute(conn, "ALTER TABLE tasks ADD COLUMN model_id TEXT", [])
    end

    if "pid" in columns do
      # SQLite 3.35.0+ supports DROP COLUMN. Older versions don't — if this
      # fails, the column is simply left unused and ignored by the codec
      # (which no longer references it), so it's harmless.
      # Justified try/rescue: (1) Do we expect this error? Yes — older SQLite
      # versions or locked tables may reject ALTER TABLE DROP COLUMN. (2) Is
      # try/rescue cleanest? Yes — there is no non-crashing variant for ALTER
      # TABLE; the failure is benign (unused column persists).
      try do
        {:ok, _} = XqliteNIF.execute(conn, "ALTER TABLE tasks DROP COLUMN pid", [])
      rescue
        e ->
          Logger.warning(
            "Store: could not drop legacy 'pid' column (harmless, codec ignores it): " <>
              Exception.message(e)
          )
      end
    end

    :ok
  end

  defp existing_columns(conn, table) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(#{table})", [])
    # PRAGMA table_info returns rows of [cid, name, type, notnull, dflt_value, pk]
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  ## Private — SQL builders

  defp task_select_sql do
    "SELECT #{Enum.join(Codec.task_columns(), ", ")} FROM tasks"
  end

  defp project_select_sql do
    "SELECT #{Enum.join(Codec.project_columns(), ", ")} FROM projects"
  end

  defp table_columns("tasks"), do: Codec.task_columns()
  defp table_columns("projects"), do: Codec.project_columns()

  defp pk_column("tasks"), do: "id"
  defp pk_column("projects"), do: "path"

  # Reads only the status column for a task id. Returns the decoded atom status
  # or nil if the row doesn't exist. Uses the same XqliteNIF.query pattern as
  # get_task; an absent row returns {:ok, %{rows: []}} so no rescue is needed.
  # The status is decoded via Codec.decode_atom/1 for consistency with the
  # existing decode pipeline.
  defp read_task_status(conn, task_id) do
    case XqliteNIF.query(conn, "SELECT status FROM tasks WHERE id = ?1", [task_id]) do
      {:ok, %{rows: [row | _]}} -> Codec.decode_atom(hd(row))
      {:ok, %{rows: []}} -> nil
    end
  end

  # Diagnostic: logs a warning when a put_task is about to write :failed as a NEW
  # transition (previous status was not :failed). This is the ULTIMATE chokepoint
  # — it cannot be bypassed regardless of which code path triggers the write.
  # Only called when task.status == :failed (efficiency: no SELECT on every write).
  defp log_failed_write_if_transition(conn, %TaskInfo{id: task_id, result: result}) do
    prev_status = read_task_status(conn, task_id)

    if prev_status != :failed do
      {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)

      Logger.warning(
        "Store: FAILED_WRITE task_id=#{task_id} prev_status=#{inspect(prev_status)} " <>
          "result=#{inspect(result)}\n" <>
          "  stacktrace=\n#{format_store_stacktrace(trace)}"
      )
    end
  end

  defp format_store_stacktrace([]), do: "  (no stacktrace available)"

  defp format_store_stacktrace(trace) do
    Enum.map_join(trace, "\n", fn frame ->
      "    #{format_store_stacktrace_frame(frame)}"
    end)
  end

  defp format_store_stacktrace_frame({module, function, arity, location}) do
    fun =
      cond do
        is_atom(function) and is_integer(arity) -> "#{function}/#{arity}"
        is_atom(function) and is_list(arity) -> "#{function}/#{length(arity)}"
        true -> inspect(function)
      end

    loc =
      case location do
        [{file, line} | _] when is_list(file) and is_integer(line) ->
          " at #{List.to_string(file)}:#{line}"

        _ ->
          ""
      end

    "#{inspect(module)}.#{fun}#{loc}"
  end

  defp format_store_stacktrace_frame(other), do: inspect(other)

  ## Private — Count helper

  defp count_table(conn, table) do
    {:ok, %{rows: [[count]]}} = XqliteNIF.query(conn, "SELECT COUNT(*) FROM #{table}", [])
    count
  end

  ## Private — Pagination clamping helpers

  # Ensures limit is a positive integer (default 50). Non-integer or
  # non-positive values fall back to the default.
  defp clamp_limit(nil), do: 50
  defp clamp_limit(n) when is_integer(n) and n > 0, do: n
  defp clamp_limit(_), do: 50

  # Ensures offset is a non-negative integer (default 0). Non-integer or
  # negative values fall back to 0.
  defp clamp_offset(nil), do: 0
  defp clamp_offset(n) when is_integer(n) and n >= 0, do: n
  defp clamp_offset(_), do: 0

  ## Private — WHERE clause builder for filtered pagination

  # Builds a SQL WHERE clause (with leading space) and an ordered param list
  # from the filters keyword list. Returns `{"", []}` when no filters apply.
  #
  # Filters:
  #   - :status         — atom/string status or "all" (default "all")
  #   - :project_path   — path string or "all" (default "all"); matches the
  #                       `path` key embedded in the JSON opts column
  #   - :review_status  — "all", "pending", "merged", "rejected", "continued"
  #   - :search         — non-empty search string; matches id or opts JSON text
  #
  # Placeholders use incremental ?N indexing so LIMIT/OFFSET can append their
  # own placeholders after the WHERE params.
  defp build_where(filters) do
    # status filter
    {clauses, params, idx} =
      case Keyword.get(filters, :status, "all") do
        "all" ->
          {[], [], 1}

        status ->
          {["status = ?1"], [status], 2}
      end

    # project_path filter — matches the "path" key embedded in opts JSON
    {clauses, params, idx} =
      case Keyword.get(filters, :project_path, "all") do
        "all" ->
          {clauses, params, idx}

        path ->
          pattern = "%" <> "\"path\",\"#{escape_like(path)}\"" <> "%"

          {clauses ++ ["opts LIKE ?" <> Integer.to_string(idx) <> " ESCAPE '\\'"],
           params ++ [pattern], idx + 1}
      end

    # review_status filter ("pending" is a composite of completed + null review + branch)
    {clauses, params, idx} =
      case Keyword.get(filters, :review_status, "all") do
        "all" ->
          {clauses, params, idx}

        "pending" ->
          # Completed tasks with no review status whose result contains a
          # branch_name (meaning they're awaiting review).
          c1 = "status = ?" <> Integer.to_string(idx)
          c2 = "review_status IS NULL"
          c3 = "result LIKE ?" <> Integer.to_string(idx + 1)

          {clauses ++ [c1, c2, c3],
           params ++ ["completed", "%" <> "\"branch_name\"" <> "%"], idx + 2}

        rs ->
          {clauses ++ ["review_status = ?" <> Integer.to_string(idx)], params ++ [rs], idx + 1}
      end

    # search filter — matches id or the raw opts JSON text
    {clauses, params, _idx} =
      case Keyword.get(filters, :search) do
        nil ->
          {clauses, params, idx}

        "" ->
          {clauses, params, idx}

        search ->
          pat = "%#{escape_like(search)}%"
          c1 = "id LIKE ?" <> Integer.to_string(idx) <> " ESCAPE '\\'"
          c2 = "opts LIKE ?" <> Integer.to_string(idx + 1) <> " ESCAPE '\\'"
          {clauses ++ ["(#{c1} OR #{c2})"], params ++ [pat, pat], idx + 2}
      end

    case clauses do
      [] -> {"", []}
      _ -> {" WHERE " <> Enum.join(clauses, " AND "), params}
    end
  end

  # Escapes the SQL LIKE-special characters (`%`, `_`, `\`) by prefixing them
  # with a backslash. Used together with `ESCAPE '\'` on LIKE clauses so that
  # user-supplied values (e.g. project paths containing underscores) are matched
  # literally instead of being interpreted as wildcards.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  ## Private — Safe select (quarantine bad rows)

  defp safe_select_all_rows(conn, table, decoder) do
    columns = table_columns(table)
    col_list = Enum.join(columns, ", ")

    case XqliteNIF.query(conn, "SELECT #{col_list} FROM #{table}", []) do
      {:ok, %{rows: rows}} -> safe_decode_rows(conn, table, rows, decoder)
      _ -> []
    end
  end

  # Runs the per-row decode+quarantine loop over an already-fetched list of
  # rows. Shared by safe_select_all_rows/3 (full-table select) and the
  # paginated task select handler. Quarantines rows that fail decode rather
  # than crashing — the same justified try/rescue recovery boundary.
  defp safe_decode_rows(conn, table, rows, decoder) do
    columns = table_columns(table)
    pk = pk_column(table)

    Enum.flat_map(rows, fn row ->
      id = hd(row)

      # Justified try/rescue — quarantine/data-recovery boundary.
      # (1) Do we expect this? Yes — DB rows may contain corrupt or legacy
      # data that fails to decode. (2) Cleanest approach? The decoder raises
      # by design (Codec decode philosophy); quarantine is the deliberate
      # recovery boundary that moves bad rows aside rather than crashing the
      # entire select.
      try do
        [decoder.(row)]
      rescue
        e ->
          quarantine_row(conn, table, id, pk, columns, row)

          Logger.warning(
            "Store: skipping undecodable row in #{table} " <>
              "(id: #{inspect(id)}): #{Exception.message(e)}"
          )

          []
      end
    end)
  end

  ## Private — Integrity check

  defp do_integrity_check(conn) do
    # Justified try/rescue — diagnostic/recovery routine.
    # (1) Do we expect an error here? Possibly — unexpected SQLite-level
    # failures during the diagnostic scan itself. (2) Cleanest approach?
    # integrity_check is a recovery routine called during GenServer init (from
    # TaskRegistry.init/1). It must return {:error, _} rather than crashing,
    # because a crash here would prevent TaskRegistry from starting at all.
    try do
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
        case pragma_result do
          :ok ->
            corrupt =
              scan_and_repair(conn, "tasks", &Codec.decode_task/1) +
                scan_and_repair(conn, "projects", &Codec.decode_project/1)

            if corrupt > 0, do: {:repaired, corrupt}, else: :ok

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

  ## Private — Quarantine recovery

  defp do_recover_quarantine(conn) do
    tasks_recovered =
      recover_table_quarantine(conn, "tasks", Codec.task_columns(), &Codec.decode_task/1)

    projects_recovered =
      recover_table_quarantine(conn, "projects", Codec.project_columns(), &Codec.decode_project/1)

    total = tasks_recovered + projects_recovered

    if total > 0 do
      Logger.info(
        "Store: recovered #{total} rows from quarantine (#{tasks_recovered} tasks, #{projects_recovered} projects)"
      )
    end

    {:ok, total}
  end

  # Reads rows from a quarantine table, attempts to decode each via `decoder`,
  # and moves successfully decoded rows back into the live `table`. Rows that
  # still fail to decode are left in quarantine.
  defp recover_table_quarantine(conn, table, columns, decoder) do
    quarantine_table = "#{table}_quarantine"

    case XqliteNIF.query(conn, "SELECT id, data FROM #{quarantine_table}", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, 0, fn [id, data], acc ->
          case Jason.decode(data) do
            {:ok, map} when is_map(map) ->
              # Reconstruct the row list in column order from the JSON map.
              row = Enum.map(columns, &Map.get(map, &1))

              # Justified try/rescue — data-recovery boundary. The decoder raises
              # by design on bad data; rows that still fail to decode must stay
              # in quarantine rather than crashing the entire recovery sweep.
              try do
                decoder.(row)

                col_names = Enum.join(columns, ", ")

                placeholders =
                  columns
                  |> Enum.with_index(1)
                  |> Enum.map(fn {_, i} -> "?#{i}" end)
                  |> Enum.join(", ")

                {:ok, _} =
                  XqliteNIF.execute(
                    conn,
                    "INSERT OR REPLACE INTO #{table} (#{col_names}) VALUES (#{placeholders})",
                    row
                  )

                {:ok, _} =
                  XqliteNIF.execute(
                    conn,
                    "DELETE FROM #{quarantine_table} WHERE id = ?1",
                    [id]
                  )

                Logger.info(
                  "Store: recovered row from #{quarantine_table} " <>
                    "(id=#{inspect(id)}) → #{table}"
                )

                acc + 1
              rescue
                e ->
                  Logger.warning(
                    "Store: row in #{quarantine_table} (id=#{inspect(id)}) still fails decode, " <>
                      "leaving in quarantine: #{Exception.message(e)}"
                  )

                  acc
              end

            {:error, _} ->
              Logger.warning(
                "Store: failed to parse JSON data in #{quarantine_table} " <>
                  "(id=#{inspect(id)}), leaving in quarantine"
              )

              acc

            _ ->
              acc
          end
        end)

      _ ->
        0
    end
  end

  defp scan_and_repair(conn, table, decoder) do
    columns = table_columns(table)
    col_list = Enum.join(columns, ", ")
    pk = pk_column(table)

    case XqliteNIF.query(conn, "SELECT #{col_list} FROM #{table}", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, 0, fn row, acc ->
          id = hd(row)

          # Justified try/rescue — quarantine/data-recovery boundary (same as
          # safe_select_all_rows). The decoder raises by design; quarantine is
          # the deliberate recovery boundary.
          try do
            decoder.(row)
            acc
          rescue
            _ ->
              quarantine_row(conn, table, id, pk, columns, row)
              acc + 1
          end
        end)

      _ ->
        0
    end
  end

  # Moves an undecodable row into the quarantine table (INSERT raw data as JSON
  # then DELETE from the live table). If the quarantine INSERT itself fails, we
  # log an error and LEAVE THE ROW IN PLACE — never silently destroy data.
  defp quarantine_row(conn, table, id, pk, columns, row) do
    quarantine_table = "#{table}_quarantine"

    json_data =
      case columns |> Enum.zip(row) |> Map.new() |> Jason.encode() do
        {:ok, json} -> json
        {:error, _} -> nil
      end

    # Justified try/rescue — data-recovery boundary. Must never destroy data;
    # if the quarantine INSERT or DELETE fails, we log and leave the row in
    # place rather than crashing and potentially losing the row entirely.
    try do
      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "INSERT OR REPLACE INTO #{quarantine_table} (id, data) VALUES (?1, ?2)",
          [id, json_data]
        )

      {:ok, _} =
        XqliteNIF.execute(conn, "DELETE FROM #{table} WHERE #{pk} = ?1", [id])

      Logger.warning([
        "Store: quarantined undecodable row ",
        "(table=#{table}, id=#{inspect(id)}) → #{quarantine_table}. ",
        "Raw data preserved for recovery."
      ])
    rescue
      e ->
        Logger.error([
          "Store: failed to quarantine undecodable row ",
          "(table=#{table}, id=#{inspect(id)}): #{Exception.message(e)}. ",
          "Leaving row in place — data NOT destroyed."
        ])
    end
  end
end
