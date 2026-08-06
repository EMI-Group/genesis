defmodule EvoGit.Store do
  @moduledoc """
  SQLite-backed persistent store for EvoGit tasks and recent projects.

  A single GenServer wrapping one xqlite (SQLite) connection. Data lives in
  column-based tables with JSON encoding for complex fields — no opaque
  Erlang term BLOBs. All serialization is delegated to `EvoGit.Store.Codec`.

  Tables:
    * `tasks` — one row per `EvoGit.TaskInfo`, one column per field.
    * `projects` — one row per `EvoGit.RecentProject`.

  ## Crash philosophy

  The `handle_call`/`handle_cast`/`handle_info` callbacks have NO try/rescue
  wrappers. If a SQLite read/write fails, the GenServer crashes and the
  supervisor restarts it with a fresh connection. Data is safe in SQLite WAL
  mode (`journal_mode=WAL`, `synchronous=NORMAL`).

  The codec (`EvoGit.Store.Codec`) uses non-crashing `Jason.encode/1` + `case`
  for TOTAL encode (no try/rescue). Decode functions raise on bad data by
  design — the safe-select helper `decode_skipping_bad/3` below is the
  deliberate recovery boundary: it catches decode failures, logs a warning,
  and SKIPS the bad row instead of crashing the whole select.

  The only justified try/rescue patterns that remain are:
    * `terminate/2` — graceful connection close during shutdown. GenServer
      terminate/2 must never raise; a crash here could prevent clean
      supervision shutdown.
    * `decode_skipping_bad/3` — safe-select boundary that deliberately catches
      decode failures to skip corrupt rows rather than crashing. The decoder
      raises by design; skipping is the deliberate recovery boundary.
  """

  use GenServer

  require Logger

  alias EvoGit.Store.{Codec, Queries, Schema}
  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

  ## Call timeout

  # SQLite I/O can be very slow when the database file lives on high-latency
  # storage (e.g. an NFS-mounted home directory on a remote server), so every
  # GenServer.call/3 to this store uses an explicit 30s timeout instead of the
  # 5s default. Keep the value tunable in one place.
  @call_timeout 30_000

  ## Summary projection

  # The 16-column SELECT projection shared by the summary handlers
  # (select_tasks_summary, select_tasks_summary_by_path, and
  # select_tasks_changed_since). `updated_at` is store-internal bookkeeping —
  # the raw fixed-precision ISO string is returned as-is (NOT decoded to a
  # DateTime). No heavy JSON fields (logs, usage, archive_metadata) are read.
  @summary_columns "id, status, review_status, result, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at"
  @summary_select_sql "SELECT #{@summary_columns} FROM tasks"

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
  independent of the page). Rows that fail to decode are SKIPPED and logged
  (same skip-and-log boundary as `safe_select_all_tasks/1`).
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
  Returns lightweight lease info for running/finalizing tasks:
  `%{id, status, lease_expires_at}`. Only the `status` column is decoded (a
  lightweight atom); no heavy JSON fields (logs, result, usage,
  archive_metadata) are touched. The status filter happens in SQL
  (`WHERE status IN ('running', 'finalizing')`).

  Used by TaskRegistry.lease_sweep and startup reconciliation to avoid a full
  decode of all tasks just to check status and lease validity.
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
  Returns the decoded logs list for a single task (or nil if the row is
  absent). Reads only the `logs` column — no heavy JSON decode of other
  fields. Used by TaskRegistry.append_log to avoid a full 18-column decode
  just to read the existing logs.
  """
  def select_task_logs(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:select_task_logs, task_id}, @call_timeout)
  end

  @doc """
  Returns narrow update info for a single task:
  `%{status: decoded atom, opts: decoded opts, finished_at: decoded datetime,
  lease_expires_at: raw integer}` (or nil if the row is absent).

  Reads only 4 columns — no heavy JSON fields (logs, result, usage,
  archive_metadata) are decoded. Used by TaskRegistry.handle_update_status to
  replace the full `task_get` read-modify-write.
  """
  def select_task_update_info(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:select_task_update_info, task_id}, @call_timeout)
  end

  @doc """
  Returns lightweight cleanup info for finished tasks: `%{id, finished_at}`.
  Only `id` (raw string) and `finished_at` (decoded DateTime or nil) are returned
  — no heavy JSON fields (logs, result, usage, archive_metadata) are decoded.
  The filter happens in SQL (`WHERE finished_at IS NOT NULL`).

  NOTE: `select_cleanup_info/3` is the SQL-pushdown variant used by cleanup —
  it performs the age/count filtering in SQL and returns plain id strings.
  """
  def select_cleanup_info(store \\ __MODULE__) do
    GenServer.call(store, :select_cleanup_info, @call_timeout)
  end

  @doc """
  SQL-pushdown variant of select_cleanup_info/1 used by cleanup. Runs TWO
  queries and returns the concatenated id lists (`q1_ids ++ q2_ids`, id
  strings; `[]` on query failure):

    * Q1 (age-expired — ALL deleted, no count trim):
      `SELECT id FROM tasks WHERE finished_at IS NOT NULL AND finished_at < ?1`
    * Q2 (over-limit — beyond the newest `max_tasks` among NON-age-expired
      finished rows):
      `SELECT id FROM tasks WHERE finished_at IS NOT NULL AND finished_at >= ?1
       ORDER BY finished_at DESC LIMIT -1 OFFSET ?2`

  This exactly preserves the cleanup semantics of `TaskRegistry.Cleanup`:
  age-expired rows are always removed regardless of count; the over-limit trim
  only applies to the remaining finished rows. `cutoff_iso` is a
  fixed-precision ISO string (string comparison works — the fixed-precision
  24-char ISO format sorts chronologically).
  """
  def select_cleanup_info(store \\ __MODULE__, cutoff_iso, max_tasks) do
    GenServer.call(store, {:select_cleanup_info, cutoff_iso, max_tasks}, @call_timeout)
  end

  @doc """
  Returns lightweight task summaries for all tasks — only columns needed for
  the dashboard sidebar listing. No heavy JSON fields (logs, usage,
  archive_metadata) are decoded. Returns a list of plain maps with an :opts key
  (decoded keyword list containing :objective and :prompt).

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses. When
  non-empty, the status filter is pushed into SQL (`WHERE status IN (...)`).

  `since` is an optional fixed-precision ISO string; when non-nil, only tasks
  whose `updated_at` is strictly newer are returned (string comparison — the
  fixed-precision 24-char ISO format sorts chronologically).
  """
  def select_tasks_summary(store \\ __MODULE__, statuses \\ [], since \\ nil) do
    GenServer.call(store, {:select_tasks_summary, statuses, since}, @call_timeout)
  end

  @doc """
  Same as select_tasks_summary/3 but filtered to a specific project_path.

  `statuses` and `since` behave as in select_tasks_summary/3.
  """
  def select_tasks_summary_by_path(
        store \\ __MODULE__,
        project_path,
        statuses \\ [],
        since \\ nil
      ) do
    GenServer.call(
      store,
      {:select_tasks_summary_by_path, project_path, statuses, since},
      @call_timeout
    )
  end

  @doc """
  Returns lightweight task summaries (same 16-key projection as
  select_tasks_summary/1, including the raw `updated_at` string) for all tasks
  whose `updated_at` is strictly newer than the given fixed-precision ISO
  string. No heavy JSON fields (logs, usage, archive_metadata) are decoded.
  Returns `[]` on query failure.
  """
  def select_tasks_changed_since(store \\ __MODULE__, since_iso) do
    GenServer.call(store, {:select_tasks_changed_since, since_iso}, @call_timeout)
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

  ## Public API — Safety

  @doc """
  Enumerates all tasks, skipping (not raising on) rows that fail to decode.
  Bad rows are logged with a warning and excluded from the returned list.
  """
  def safe_select_all_tasks(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all_tasks, @call_timeout)
  end

  @doc """
  Enumerates all projects, skipping (not raising on) rows that fail to decode.
  Bad rows are logged with a warning and excluded from the returned list.
  """
  def safe_select_all_projects(store \\ __MODULE__) do
    GenServer.call(store, :safe_select_all_projects, @call_timeout)
  end

  @doc "Returns the total number of rows across both tables."
  def size(store \\ __MODULE__) do
    GenServer.call(store, :size, @call_timeout)
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir}) do
    dir = Path.dirname(data_dir)
    File.mkdir_p!(dir)

    case Xqlite.open(data_dir, journal_mode: :wal, synchronous: :normal, cache_size: -2000) do
      {:ok, conn} ->
        # Fresh DBs get the full schema from create_tables/1. Schema upgrades for
        # existing DBs now happen via the manual `mix migrate.store` task — no
        # auto-migration (migrate_schema/normalize_timestamps) at startup.
        Schema.create_tables(conn)

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
          # 18 values from encode_task + 19th `updated_at` value (store-internal
          # bookkeeping, not part of %TaskInfo{}/Codec.task_columns).
          values = Codec.encode_task(task) ++ [Codec.encode_datetime(DateTime.utc_now())]

          {:ok, _} =
            XqliteNIF.execute(
              state.conn,
              """
              INSERT OR REPLACE INTO tasks
              (id, type, status, opts, started_at, finished_at, logs,
               result, review_status, usage, agent_count, base_sha, commit_sha,
               archive_metadata, lease_expires_at, model_id, project_path, branch_name, updated_at)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
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
    # Batch the deletes into chunked `WHERE id IN (...)` statements (chunk size
    # 500, safely under SQLite's 999-parameter limit). This changes partial-crash
    # semantics from "some deleted" to "all-or-nothing per chunk" — an improvement.
    task_ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      placeholders =
        chunk
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

      {:ok, _} =
        XqliteNIF.execute(state.conn, "DELETE FROM tasks WHERE id IN (#{placeholders})", chunk)
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
      Queries.task_select_sql() <>
        where_clause <>
        " ORDER BY started_at DESC LIMIT ?" <>
        Integer.to_string(limit_idx) <>
        " OFFSET ?" <> Integer.to_string(offset_idx)

    select_params = where_params ++ [limit, offset]

    rows =
      case XqliteNIF.query(state.conn, select_sql, select_params) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    # Skip-and-log decode boundary (same as safe_select_all_tasks).
    tasks = decode_skipping_bad(rows, &Codec.decode_task/1, "tasks")

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

  # Lightweight query: reads only id, status, lease_expires_at for
  # running/finalizing tasks (status filtering happens in SQL). The status is
  # decoded via the non-crashing Codec.decode_atom/1 (returns nil on unknown).
  @impl true
  def handle_call(:select_running_lease_info, _from, state) do
    reply =
      case XqliteNIF.query(
             state.conn,
             "SELECT id, status, lease_expires_at FROM tasks WHERE status IN ('running', 'finalizing')",
             []
           ) do
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

  # Lightweight write: updates only the specified columns for a task. Every
  # targeted update also bumps the store-internal `updated_at` column (the
  # 60s lease heartbeat uses update_lease_expires_at/3 and must NOT bump it).
  @impl true
  def handle_call({:update_task_columns, task_id, columns}, _from, state) do
    columns = [{:updated_at, DateTime.utc_now()} | columns]
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

  # Lightweight read: returns only the decoded logs list (or nil when the row
  # is absent). Reads a single column — no full-row decode.
  @impl true
  def handle_call({:select_task_logs, task_id}, _from, state) do
    reply =
      case XqliteNIF.query(state.conn, "SELECT logs FROM tasks WHERE id = ?1", [task_id]) do
        {:ok, %{rows: [row | _]}} -> Codec.decode_logs(hd(row))
        {:ok, %{rows: []}} -> nil
      end

    {:reply, reply, state}
  end

  # Lightweight read: returns %{status, opts, finished_at, lease_expires_at}
  # (or nil when the row is absent). Reads 4 columns — no heavy JSON fields
  # (logs, result, usage, archive_metadata) are decoded.
  @impl true
  def handle_call({:select_task_update_info, task_id}, _from, state) do
    reply =
      case XqliteNIF.query(
             state.conn,
             "SELECT status, opts, finished_at, lease_expires_at FROM tasks WHERE id = ?1",
             [task_id]
           ) do
        {:ok, %{rows: [row | _]}} ->
          [status, opts, finished_at, lease_expires_at] = row

          %{
            status: Codec.decode_atom(status),
            opts: Codec.decode_opts(opts),
            finished_at: Codec.decode_datetime(finished_at),
            lease_expires_at: lease_expires_at
          }

        {:ok, %{rows: []}} ->
          nil
      end

    {:reply, reply, state}
  end

  # Lightweight query: reads only id and finished_at for finished tasks
  # (WHERE finished_at IS NOT NULL). The finished_at column is decoded via the
  # non-crashing Codec.decode_datetime/1 (returns nil on bad data). No heavy
  # JSON fields are decoded.
  @impl true
  def handle_call(:select_cleanup_info, _from, state) do
    reply =
      case XqliteNIF.query(
             state.conn,
             "SELECT id, finished_at FROM tasks WHERE finished_at IS NOT NULL",
             []
           ) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, finished_at] ->
            %{id: id, finished_at: Codec.decode_datetime(finished_at)}
          end)

        _ ->
          []
      end

    {:reply, reply, state}
  end

  # SQL-pushdown cleanup query: Q1 = age-expired finished rows (ALL deleted, no
  # count trim); Q2 = finished rows beyond the newest `max_tasks` among the
  # NON-age-expired ones (`LIMIT -1 OFFSET ?2` = all rows past the newest
  # max_tasks, ordered newest-first). Returns q1_ids ++ q2_ids; [] on failure.
  @impl true
  def handle_call({:select_cleanup_info, cutoff_iso, max_tasks}, _from, state) do
    q1_ids =
      case XqliteNIF.query(
             state.conn,
             "SELECT id FROM tasks WHERE finished_at IS NOT NULL AND finished_at < ?1",
             [cutoff_iso]
           ) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
        _ -> []
      end

    q2_ids =
      case XqliteNIF.query(
             state.conn,
             "SELECT id FROM tasks WHERE finished_at IS NOT NULL AND finished_at >= ?1 ORDER BY finished_at DESC LIMIT -1 OFFSET ?2",
             [cutoff_iso, max_tasks]
           ) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
        _ -> []
      end

    {:reply, q1_ids ++ q2_ids, state}
  end

  # Lightweight query: reads the 16 summary columns (see @summary_columns) —
  # no heavy JSON fields (logs, usage, archive_metadata) are decoded. Status
  # filtering is pushed into SQL when `statuses` is non-empty; the optional
  # `since` filter is pushed into SQL as `updated_at > ?N` (string comparison).
  @impl true
  def handle_call({:select_tasks_summary, statuses, since}, _from, state) do
    {where_clause, where_params} = build_summary_where(statuses, since)

    reply =
      case XqliteNIF.query(state.conn, @summary_select_sql <> where_clause, where_params) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &decode_summary_row/1)
        _ -> []
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:select_tasks_summary_by_path, project_path, statuses, since}, _from, state) do
    # project_path uses ?1; the optional status filter appends ?2..?N, and the
    # optional since filter appends after that.
    {status_clause, status_params} = build_status_clause(statuses, 2)
    {since_clause, since_params} = build_since_clause(since, 2 + length(status_params))

    reply =
      case XqliteNIF.query(
             state.conn,
             @summary_select_sql <> " WHERE project_path = ?1" <> status_clause <> since_clause,
             [project_path] ++ status_params ++ since_params
           ) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &decode_summary_row/1)
        _ -> []
      end

    {:reply, reply, state}
  end

  # Lightweight query: same 16-column summary projection as above, filtered by
  # `updated_at > ?1` (string comparison — fixed-precision 24-char ISO format
  # sorts chronologically). No heavy JSON fields are decoded.
  @impl true
  def handle_call({:select_tasks_changed_since, since_iso}, _from, state) do
    reply =
      case XqliteNIF.query(
             state.conn,
             @summary_select_sql <> " WHERE updated_at > ?1",
             [since_iso]
           ) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &decode_summary_row/1)
        _ -> []
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
    col_list = Enum.join(Codec.task_columns(), ", ")

    rows =
      case XqliteNIF.query(state.conn, "SELECT #{col_list} FROM tasks", []) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    decoded = decode_skipping_bad(rows, &Codec.decode_task/1, "tasks")
    {:reply, decoded, state}
  end

  @impl true
  def handle_call(:safe_select_all_projects, _from, state) do
    col_list = Enum.join(Codec.project_columns(), ", ")

    rows =
      case XqliteNIF.query(state.conn, "SELECT #{col_list} FROM projects", []) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    decoded = decode_skipping_bad(rows, &Codec.decode_project/1, "projects")
    {:reply, decoded, state}
  end

  ## GenServer — Periodic memory cleanup

  ## Private — Helpers

  # Safe-select decode boundary: decodes every row, SKIPPING (and logging) rows
  # that raise instead of crashing the whole select. The decoder raises by
  # design; skipping is the deliberate recovery boundary — no data-movement
  # INSERT/DELETE is performed on bad rows.
  defp decode_skipping_bad(rows, decoder, table) do
    Enum.flat_map(rows, fn row ->
      # Justified try/rescue — safe-select boundary. (1) Do we expect this?
      # Yes — DB rows may contain corrupt or legacy data that fails to decode.
      # (2) Cleanest approach? The decoder raises by design (Codec decode
      # philosophy); skipping is the deliberate recovery boundary.
      try do
        [decoder.(row)]
      rescue
        e ->
          Logger.warning(
            "Store: skipping undecodable row in #{table} (id: #{inspect(hd(row))}): " <>
              Exception.message(e)
          )

          []
      end
    end)
  end

  # Builds a ` WHERE status IN (?1, ?2, ...)` clause (and its string-encoded
  # params) from a list of status atoms. Returns {"", []} for an empty list
  # (all statuses).
  defp build_status_where([]), do: {"", []}

  defp build_status_where(statuses) do
    placeholders =
      statuses
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

    {" WHERE status IN (#{placeholders})", Enum.map(statuses, &Atom.to_string/1)}
  end

  # Builds an ` AND status IN (?N, ...)` clause appended after an existing
  # ?1..?(N-1) filter. Returns {"", []} for an empty status list.
  defp build_status_clause([], _start_idx), do: {"", []}

  defp build_status_clause(statuses, start_idx) do
    placeholders =
      statuses
      |> Enum.with_index(start_idx)
      |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

    {" AND status IN (#{placeholders})", Enum.map(statuses, &Atom.to_string/1)}
  end

  # Composes the optional statuses + optional `since` filters into a single
  # WHERE clause for the plain summary query (no base filter):
  #   statuses=[] + since=nil  -> {"", []}
  #   statuses + since=nil     -> {" WHERE status IN (?1..?N)", S}
  #   statuses=[] + since      -> {" WHERE updated_at > ?1", [since]}
  #   statuses + since         -> {" WHERE status IN (?1..?N) AND updated_at > ?(N+1)", S ++ [since]}
  defp build_summary_where(statuses, since) do
    {status_clause, status_params} = build_status_where(statuses)

    cond do
      is_nil(since) ->
        {status_clause, status_params}

      status_params == [] ->
        {" WHERE updated_at > ?1", [since]}

      true ->
        {"#{status_clause} AND updated_at > ?#{length(status_params) + 1}",
         status_params ++ [since]}
    end
  end

  # Builds an ` AND updated_at > ?N` clause (and its param) appended after
  # existing ?1..?(N-1) filters. Returns {"", []} for a nil since (no filter).
  defp build_since_clause(nil, _start_idx), do: {"", []}

  defp build_since_clause(since, start_idx) do
    {" AND updated_at > ?" <> Integer.to_string(start_idx), [since]}
  end

  # Decodes one row of the 16-column summary projection (@summary_columns).
  # `updated_at` is store-internal bookkeeping — returned as the RAW
  # fixed-precision ISO string from the DB (NOT decoded to a DateTime).
  defp decode_summary_row([
         id,
         status,
         review_status,
         result,
         started_at,
         finished_at,
         type,
         project_path,
         opts,
         branch_name,
         model_id,
         agent_count,
         base_sha,
         commit_sha,
         lease_expires_at,
         updated_at
       ]) do
    %{
      id: id,
      status: Codec.decode_atom(status),
      review_status: Codec.decode_atom(review_status),
      result: Codec.decode_result(result),
      started_at: Codec.decode_datetime(started_at),
      finished_at: Codec.decode_datetime(finished_at),
      type: Codec.decode_atom(type),
      project_path: project_path,
      opts: Codec.decode_opts(opts),
      branch_name: branch_name,
      model_id: model_id,
      agent_count: agent_count,
      base_sha: base_sha,
      commit_sha: commit_sha,
      lease_expires_at: lease_expires_at,
      updated_at: updated_at
    }
  end

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
