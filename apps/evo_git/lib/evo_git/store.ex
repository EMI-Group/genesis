defmodule EvoGit.Store do
  @moduledoc """
  SQLite-backed persistent store for EvoDash tasks and recent projects.

  A single GenServer wrapping one xqlite (SQLite) connection. Data lives in
  column-based tables with JSON encoding for complex fields — no opaque
  Erlang term BLOBs. All serialization is delegated to `EvoGit.Store.Codec`.

  Tables:
    * `tasks` — one row per `EvoGit.TaskInfo`, one column per field.
    * `projects` — one row per `EvoGit.RecentProject`.
    * `tasks_quarantine` — undecodable task rows moved here (raw JSON) for recovery.
    * `projects_quarantine` — undecodable project rows moved here for recovery.

  ## Crash philosophy

  The `handle_call`/`handle_cast`/`handle_info` callbacks have NO try/rescue
  wrappers. If a SQLite read/write fails, the GenServer crashes and the
  supervisor restarts it with a fresh connection. Data is safe in SQLite WAL
  mode (`journal_mode=WAL`, `synchronous=NORMAL`).

  The codec (`EvoGit.Store.Codec`) uses non-crashing `Jason.encode/1` + `case`
  for TOTAL encode (no try/rescue). Decode functions raise on bad data by
  design — the quarantine/recovery logic below catches those failures.

  The only justified try/rescue patterns that remain are:
    * `terminate/2` — graceful connection close during shutdown. GenServer
      terminate/2 must never raise; a crash here could prevent clean
      supervision shutdown.
    * `safe_decode_rows`, `scan_and_repair` — quarantine/data-recovery
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

  alias EvoGit.Store.{Codec, Quarantine, Queries, Schema}
  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

  ## Call timeout

  # SQLite I/O can be very slow when the database file lives on high-latency
  # storage (e.g. an NFS-mounted home directory on a remote server), so every
  # GenServer.call/3 to this store uses an explicit 30s timeout instead of the
  # 5s default. Keep the value tunable in one place.
  @call_timeout 30_000

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
    GenServer.call(store, {:put_task, task}, @call_timeout)
  end

  def put_task(_store, _other) do
    {:error, :invalid_task_struct}
  end

  @doc "Reads a single task by id, returning the struct or nil."
  def get_task(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:get_task, task_id}, @call_timeout)
  end

  @doc "Deletes a single task by id."
  def delete_task(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:delete_task, task_id}, @call_timeout)
  end

  @doc "Deletes multiple tasks by id in one call. `task_ids` is a list of id strings."
  def delete_tasks(store \\ __MODULE__, task_ids) do
    GenServer.call(store, {:delete_tasks, task_ids}, @call_timeout)
  end

  @doc "Returns all tasks as a list of TaskInfo structs."
  def select_all_tasks(store \\ __MODULE__) do
    GenServer.call(store, :select_all_tasks, @call_timeout)
  end

  @doc "Returns the number of task rows."
  def count_tasks(store \\ __MODULE__) do
    GenServer.call(store, :count_tasks, @call_timeout)
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
    GenServer.call(store, {:safe_select_paginated_tasks, opts}, @call_timeout)
  end

  @doc "Deletes all task rows."
  def clear_tasks(store \\ __MODULE__) do
    GenServer.call(store, :clear_tasks, @call_timeout)
  end

  ## Public API — Lightweight task queries

  @doc """
  Returns the distinct non-nil `project_path` values from all task rows.

  This is a lightweight query — only the `project_path` column is read, no
  JSON blobs are decoded. Used by TaskRegistry.get_unique_paths/0.
  """
  def select_task_paths(store \\ __MODULE__) do
    GenServer.call(store, :select_task_paths, @call_timeout)
  end

  @doc """
  Returns the ids of all tasks whose status is NOT running or pending.

  Used by TaskRegistry.clear_finished_tasks to avoid decoding all tasks just
  to filter by status — the status filtering happens in SQL.
  """
  def select_finished_task_ids(store \\ __MODULE__) do
    GenServer.call(store, :select_finished_task_ids, @call_timeout)
  end

  @doc """
  Returns lightweight lease info for all tasks: `%{id, status, lease_expires_at}`.
  Only the `status` column is decoded (a lightweight atom); no heavy JSON
  fields (logs, result, usage, archive_metadata) are touched.

  Used by TaskRegistry.lease_sweep to avoid a full decode of all tasks just to
  check status == :running and lease validity.
  """
  def select_running_lease_info(store \\ __MODULE__) do
    GenServer.call(store, :select_running_lease_info, @call_timeout)
  end

  @doc """
  Updates only the `lease_expires_at` column for a task, avoiding a full
  read-modify-write of the entire row.

  Returns `:ok`. Used by TaskRegistry.heartbeat to renew leases without
  decoding + re-encoding the whole task struct.
  """
  def update_lease_expires_at(store \\ __MODULE__, task_id, expires_at) do
    GenServer.call(store, {:update_lease_expires_at, task_id, expires_at}, @call_timeout)
  end

  @doc """
  Performs a targeted UPDATE of specific columns for a task, avoiding a full
  read-modify-write of the entire row.

  `columns` is a keyword list mapping column name atoms to their new values.
  Only the specified columns are updated; all others are left untouched.

  Column values that need encoding (atoms, datetimes, usage, result,
  archive_metadata, opts) are passed through the appropriate `Codec.encode_*`
  function. Scalar values (strings, integers, nil) are used directly.

  Returns `:ok`. Used by TaskRegistry for partial updates like setting
  review_status, appending logs, and status transitions.
  """
  def update_task_columns(store \\ __MODULE__, task_id, columns) when is_list(columns) do
    GenServer.call(store, {:update_task_columns, task_id, columns}, @call_timeout)
  end

  @doc """
  Returns the decoded status atom for a single task (or nil if not found).
  Reads only the `status` column — no heavy JSON decode.
  """
  def get_task_status(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:get_task_status, task_id}, @call_timeout)
  end

  @doc """
  Returns lightweight cleanup info for all tasks: `%{id, finished_at}`.
  Only `id` (raw string) and `finished_at` (decoded DateTime or nil) are returned
  — no heavy JSON fields (logs, result, usage, archive_metadata) are decoded.

  Used by `TaskRegistry.Cleanup` to avoid a full decode of all tasks just to
  check finished_at against age/count limits.
  """
  def select_cleanup_info(store \\ __MODULE__) do
    GenServer.call(store, :select_cleanup_info, @call_timeout)
  end

  @doc """
  Returns lightweight task summaries for all tasks — only columns needed for
  the dashboard sidebar listing. No heavy JSON fields (logs, usage, opts,
  archive_metadata) are decoded. Returns a list of plain maps with an :opts key
  (decoded keyword list containing :objective and :prompt).
  """
  def select_tasks_summary(store \\ __MODULE__) do
    GenServer.call(store, :select_tasks_summary, @call_timeout)
  end

  @doc """
  Same as select_tasks_summary/1 but filtered to a specific project_path.
  """
  def select_tasks_summary_by_path(store \\ __MODULE__, project_path) do
    GenServer.call(store, {:select_tasks_summary_by_path, project_path}, @call_timeout)
  end

  ## Public API — Projects

  @doc "Inserts or replaces a project. Validates that path is present."
  def put_project(store \\ __MODULE__, project)

  def put_project(store, %RecentProject{} = project) do
    GenServer.call(store, {:put_project, project}, @call_timeout)
  end

  def put_project(_store, _other) do
    {:error, :invalid_project_struct}
  end

  @doc "Reads a single project by path, returning the struct or nil."
  def get_project(store \\ __MODULE__, path) do
    GenServer.call(store, {:get_project, path}, @call_timeout)
  end

  @doc "Deletes a single project by path."
  def delete_project(store \\ __MODULE__, path) do
    GenServer.call(store, {:delete_project, path}, @call_timeout)
  end

  @doc "Returns all projects as a list of RecentProject structs."
  def select_all_projects(store \\ __MODULE__) do
    GenServer.call(store, :select_all_projects, @call_timeout)
  end

  @doc "Returns the number of project rows."
  def count_projects(store \\ __MODULE__) do
    GenServer.call(store, :count_projects, @call_timeout)
  end

  ## Public API — Safety / Integrity

  @doc """
  Enumerates all tasks, quarantining (not raising on) rows that fail to decode.
  Bad rows are moved to `tasks_quarantine` and skipped from the returned list.
  """
  def safe_select_all_tasks(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all_tasks, @call_timeout)
  end

  @doc """
  Enumerates all projects, quarantining (not raising on) rows that fail to decode.
  Bad rows are moved to `projects_quarantine` and skipped from the returned list.
  """
  def safe_select_all_projects(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all_projects, @call_timeout)
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
    GenServer.call(store, :integrity_check, @call_timeout)
  end

  @doc "Returns the total number of rows across both tables."
  def size(store \\ __MODULE__) do
    GenServer.call(store, :size, @call_timeout)
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
    GenServer.call(store, :recover_quarantine, @call_timeout)
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir}) do
    dir = Path.dirname(data_dir)
    File.mkdir_p!(dir)

    case Xqlite.open(data_dir, journal_mode: :wal, synchronous: :normal, cache_size: -2000) do
      {:ok, conn} ->
        Schema.create_tables(conn)
        Schema.migrate_schema(conn)

        # Best-effort: checkpoint any leftover WAL from a previous ungraceful shutdown
        XqliteNIF.query(conn, "PRAGMA wal_checkpoint(TRUNCATE)", [])

        state = %{conn: conn, data_dir: data_dir}
        {:ok, state}

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
      XqliteNIF.query(conn, "PRAGMA wal_checkpoint(TRUNCATE)", [])
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
               archive_metadata, lease_expires_at, model_id, project_path, branch_name)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
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
      case XqliteNIF.query(state.conn, Queries.task_select_sql() <> " WHERE id = ?1", [task_id]) do
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
      case XqliteNIF.query(state.conn, Queries.task_select_sql(), []) do
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
    {where_clause, where_params} = Queries.build_where(filters)
    limit = Queries.clamp_limit(Keyword.get(opts, :limit))
    offset = Queries.clamp_offset(Keyword.get(opts, :offset))

    limit_idx = length(where_params) + 1
    offset_idx = length(where_params) + 2

    select_sql =
      Queries.task_select_sql() <> where_clause <>
        " ORDER BY started_at DESC LIMIT ?" <> Integer.to_string(limit_idx) <>
        " OFFSET ?" <> Integer.to_string(offset_idx)

    select_params = where_params ++ [limit, offset]

    rows =
      case XqliteNIF.query(state.conn, select_sql, select_params) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    # Reuse the SAME quarantine-safe decode boundary as safe_decode_rows.
    tasks = Quarantine.safe_decode_rows(state.conn, "tasks", rows, &Codec.decode_task/1)

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

  # Lightweight query: reads only the project_path column, returning distinct
  # non-null paths. No full task decode — no JSON blobs are touched.
  @impl true
  def handle_call(:select_task_paths, _from, state) do
    reply =
      case XqliteNIF.query(
             state.conn,
             "SELECT DISTINCT project_path FROM tasks WHERE project_path IS NOT NULL",
             []
           ) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [path] -> path end)
        _ -> []
      end

    {:reply, reply, state}
  end

  # Lightweight query: status filtering in SQL, returns raw id strings.
  # No decode at all.
  @impl true
  def handle_call(:select_finished_task_ids, _from, state) do
    reply =
      case XqliteNIF.query(
             state.conn,
             "SELECT id FROM tasks WHERE status NOT IN ('running', 'pending')",
             []
           ) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
        _ -> []
      end

    {:reply, reply, state}
  end

  # Lightweight query: reads only id, status, lease_expires_at. The status is
  # decoded via the non-crashing Codec.decode_atom/1 (returns nil on unknown).
  @impl true
  def handle_call(:select_running_lease_info, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, "SELECT id, status, lease_expires_at FROM tasks", []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, status, lease_expires_at] ->
            %{id: id, status: Codec.decode_atom(status), lease_expires_at: lease_expires_at}
          end)

        _ ->
          []
      end

    {:reply, reply, state}
  end

  # Lightweight write: updates only the lease_expires_at column.
  @impl true
  def handle_call({:update_lease_expires_at, task_id, expires_at}, _from, state) do
    {:ok, _} =
      XqliteNIF.execute(
        state.conn,
        "UPDATE tasks SET lease_expires_at = ?1 WHERE id = ?2",
        [expires_at, task_id]
      )

    {:reply, :ok, state}
  end

  # Lightweight write: updates only the specified columns for a task.
  @impl true
  def handle_call({:update_task_columns, task_id, columns}, _from, state) do
    {set_clauses, values} = Queries.build_update_set(columns, 1)

    {:ok, _} =
      XqliteNIF.execute(
        state.conn,
        "UPDATE tasks SET #{set_clauses} WHERE id = ?#{length(values) + 1}",
        values ++ [task_id]
      )

    {:reply, :ok, state}
  end

  # Lightweight read: returns only the decoded status atom (or nil).
  @impl true
  def handle_call({:get_task_status, task_id}, _from, state) do
    reply = read_task_status(state.conn, task_id)
    {:reply, reply, state}
  end

  # Lightweight query: reads only id and finished_at. The finished_at column is
  # decoded via the non-crashing Codec.decode_datetime/1 (returns nil on bad
  # data). No heavy JSON fields are decoded.
  @impl true
  def handle_call(:select_cleanup_info, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, "SELECT id, finished_at FROM tasks", []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, finished_at] ->
            %{id: id, finished_at: Codec.decode_datetime(finished_at)}
          end)

        _ ->
          []
      end

    {:reply, reply, state}
  end

  # Lightweight query: reads only id, status, review_status, result, started_at,
  # finished_at, type, project_path, opts. No heavy JSON fields (logs, usage,
  # archive_metadata) are decoded.
  @impl true
  def handle_call(:select_tasks_summary, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, "SELECT id, status, review_status, result, started_at, finished_at, type, project_path, opts FROM tasks", []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, status, review_status, result, started_at, finished_at, type, project_path, opts] ->
            %{
              id: id,
              status: Codec.decode_atom(status),
              review_status: Codec.decode_atom(review_status),
              result: Codec.decode_result(result),
              started_at: Codec.decode_datetime(started_at),
              finished_at: Codec.decode_datetime(finished_at),
              type: Codec.decode_atom(type),
              project_path: project_path,
              opts: Codec.decode_opts(opts)
            }
          end)

        _ ->
          []
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:select_tasks_summary_by_path, project_path}, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, "SELECT id, status, review_status, result, started_at, finished_at, type, project_path, opts FROM tasks WHERE project_path = ?1", [project_path]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, status, review_status, result, started_at, finished_at, type, project_path, opts] ->
            %{
              id: id,
              status: Codec.decode_atom(status),
              review_status: Codec.decode_atom(review_status),
              result: Codec.decode_result(result),
              started_at: Codec.decode_datetime(started_at),
              finished_at: Codec.decode_datetime(finished_at),
              type: Codec.decode_atom(type),
              project_path: project_path,
              opts: Codec.decode_opts(opts)
            }
          end)

        _ ->
          []
      end

    {:reply, reply, state}
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
      case XqliteNIF.query(state.conn, Queries.project_select_sql() <> " WHERE path = ?1", [path]) do
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
      case XqliteNIF.query(state.conn, Queries.project_select_sql(), []) do
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
    columns = Quarantine.table_columns("tasks")
    col_list = Enum.join(columns, ", ")

    rows =
      case XqliteNIF.query(state.conn, "SELECT #{col_list} FROM tasks", []) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    decoded =
      Enum.flat_map(rows, fn row ->
        try do
          [Codec.decode_task(row)]
        rescue
          e ->
            Logger.warning(
              "Store: skipping undecodable task row (id: #{inspect(hd(row))}): #{Exception.message(e)}"
            )

            []
        end
      end)

    {:reply, decoded, state}
  end

  @impl true
  def handle_call(:safe_select_all_projects, _from, state) do
    columns = Quarantine.table_columns("projects")
    col_list = Enum.join(columns, ", ")

    rows =
      case XqliteNIF.query(state.conn, "SELECT #{col_list} FROM projects", []) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    decoded = Enum.map(rows, &Codec.decode_project/1)
    {:reply, decoded, state}
  end

  @impl true
  def handle_call(:integrity_check, _from, state) do
    reply = Quarantine.do_integrity_check(state.conn)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:recover_quarantine, _from, state) do
    reply = Quarantine.do_recover_quarantine(state.conn)
    {:reply, reply, state}
  end

  ## GenServer — Periodic memory cleanup

  ## Private — Helpers

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

end
