defmodule EvoDash.RecentProject do
  @moduledoc "A recently opened project entry."
  defstruct [:path, :name, :last_opened_at]
  @type t :: %__MODULE__{path: String.t(), name: String.t(), last_opened_at: DateTime.t() | nil}
end

defmodule EvoDash.TaskStore do
  @moduledoc """
  SQLite-backed persistent store for EvoDash tasks and recent projects.

  A single GenServer wrapping one xqlite (SQLite) connection. Data lives in
  column-based tables with JSON encoding for complex fields — no opaque
  Erlang term BLOBs.

  Tables:
    * `tasks` — one row per `EvoDash.TaskRegistry.TaskInfo`, one column per field.
    * `projects` — one row per `EvoDash.RecentProject`.
    * `tasks_quarantine` — undecodable task rows moved here (raw JSON) for recovery.
    * `projects_quarantine` — undecodable project rows moved here for recovery.

  ## Encoding strategy

    * Scalar fields → native SQLite types (TEXT / INTEGER).
    * DateTime → ISO8601 string.
    * Atoms (type, status, review_status) → stored as strings, restored via
      `String.to_existing_atom/1` (never creates new atoms).
    * Complex fields (opts, logs, result, usage, archive_metadata) → JSON via Jason.
    * pid → string via `:erlang.pid_to_list/1`.
  """

  use GenServer

  require Logger

  alias EvoDash.TaskRegistry.TaskInfo

  @task_columns ~w(id type status opts pid started_at finished_at logs result review_status usage agent_count base_sha commit_sha archive_metadata)
  @project_columns ~w(path name last_opened_at)

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    :cached_tokens,
    :cache_creation_tokens
  ]

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
  def put_task(store \\ __MODULE__, %TaskInfo{} = task) do
    GenServer.call(store, {:put_task, task})
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

  @doc "Deletes all task rows."
  def clear_tasks(store \\ __MODULE__) do
    GenServer.call(store, :clear_tasks)
  end

  ## Public API — Projects

  @doc "Inserts or replaces a project. Validates that path is present."
  def put_project(store \\ __MODULE__, %EvoDash.RecentProject{} = project) do
    GenServer.call(store, {:put_project, project})
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

  @doc "Safely reads a task, returning nil on any error."
  def safe_get_task(store \\ __MODULE__, task_id) do
    try do
      get_task(store, task_id)
    rescue
      _ -> nil
    end
  end

  @doc "Safely reads a project, returning nil on any error."
  def safe_get_project(store \\ __MODULE__, path) do
    try do
      get_project(store, path)
    rescue
      _ -> nil
    end
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

  @doc "Returns the store size, rescuing any error to 0."
  def safe_size(store \\ __MODULE__) do
    try do
      size(store)
    rescue
      _ -> 0
    end
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir}) do
    dir = Path.dirname(data_dir)
    File.mkdir_p!(dir)

    case Xqlite.open(data_dir, journal_mode: :wal, synchronous: :normal) do
      {:ok, conn} ->
        # Detect and migrate from old blob-based schema before creating tables.
        maybe_migrate_old_schema(conn)
        create_tables(conn)

        {:ok, %{conn: conn, data_dir: data_dir}}

      {:error, reason} ->
        {:stop, {:failed_to_open_sqlite, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn} = _state) do
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
      case validate_task(task) do
        :ok ->
          # Always null the ref before persistence — it is runtime-only.
          task = %{task | ref: nil}
          values = encode_task(task)

          {:ok, _} =
            XqliteNIF.execute(
              state.conn,
              """
              INSERT OR REPLACE INTO tasks
              (id, type, status, opts, pid, started_at, finished_at, logs,
               result, review_status, usage, agent_count, base_sha, commit_sha,
               archive_metadata)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
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
        {:ok, %{rows: [row | _]}} -> decode_task(row)
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
        {:ok, %{rows: rows}} -> Enum.map(rows, &decode_task/1)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:count_tasks, _from, state) do
    {:ok, %{rows: [[count]]}} = XqliteNIF.query(state.conn, "SELECT COUNT(*) FROM tasks", [])
    {:reply, count, state}
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
      case validate_project(project) do
        :ok ->
          values = encode_project(project)

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
        {:ok, %{rows: [row | _]}} -> decode_project(row)
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
        {:ok, %{rows: rows}} -> Enum.map(rows, &decode_project/1)
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
    reply = safe_select_all_rows(state.conn, "tasks", &decode_task/1)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:safe_select_all_projects, _from, state) do
    reply = safe_select_all_rows(state.conn, "projects", &decode_project/1)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:integrity_check, _from, state) do
    reply = do_integrity_check(state.conn)
    {:reply, reply, state}
  end

  ## Private — Schema creation & migration

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
          pid TEXT,
          started_at TEXT,
          finished_at TEXT,
          logs TEXT,
          result TEXT,
          review_status TEXT,
          usage TEXT,
          agent_count INTEGER,
          base_sha TEXT,
          commit_sha TEXT,
          archive_metadata TEXT
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

  # Detects the old blob-based schema (tables with a `data` column instead of
  # proper typed columns) and drops both tables so they can be recreated with
  # the new column-based schema. Old data is lost — this is acceptable in early
  # development.
  defp maybe_migrate_old_schema(conn) do
    try do
      old_tasks = has_data_column?(conn, "tasks")
      old_projects = has_data_column?(conn, "projects")

      if old_tasks or old_projects do
        Logger.info(
          "TaskStore: detected old blob-based schema, recreating tables with " <>
            "column-based schema (old data will be lost)"
        )

        {:ok, _} = XqliteNIF.execute(conn, "DROP TABLE IF EXISTS tasks", [])
        {:ok, _} = XqliteNIF.execute(conn, "DROP TABLE IF EXISTS projects", [])
        {:ok, _} = XqliteNIF.execute(conn, "DROP TABLE IF EXISTS tasks_quarantine", [])
        {:ok, _} = XqliteNIF.execute(conn, "DROP TABLE IF EXISTS projects_quarantine", [])
      end
    rescue
      e ->
        Logger.error("TaskStore: old schema migration check failed: #{Exception.message(e)}")
    end
  end

  defp has_data_column?(conn, table) do
    case XqliteNIF.query(conn, "PRAGMA table_info(#{table})", []) do
      {:ok, %{rows: rows}} when rows != [] ->
        Enum.any?(rows, fn
          [_cid, "data" | _] -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  ## Private — SQL builders

  defp task_select_sql do
    "SELECT #{Enum.join(@task_columns, ", ")} FROM tasks"
  end

  defp project_select_sql do
    "SELECT #{Enum.join(@project_columns, ", ")} FROM projects"
  end

  defp table_columns("tasks"), do: @task_columns
  defp table_columns("projects"), do: @project_columns

  defp pk_column("tasks"), do: "id"
  defp pk_column("projects"), do: "path"

  ## Private — Validation

  defp validate_task(%TaskInfo{id: id, status: status})
       when is_binary(id) and not is_nil(status),
       do: :ok

  defp validate_task(%TaskInfo{id: nil}), do: {:error, :missing_task_id}
  defp validate_task(%TaskInfo{status: nil}), do: {:error, :missing_task_status}
  defp validate_task(%TaskInfo{}), do: {:error, :missing_task_id}

  defp validate_project(%EvoDash.RecentProject{path: path}) when is_binary(path), do: :ok
  defp validate_project(%EvoDash.RecentProject{path: nil}), do: {:error, :missing_project_path}
  defp validate_project(%EvoDash.RecentProject{}), do: {:error, :missing_project_path}

  ## Private — Count helper

  defp count_table(conn, table) do
    {:ok, %{rows: [[count]]}} = XqliteNIF.query(conn, "SELECT COUNT(*) FROM #{table}", [])
    count
  end

  ## Private — Encoding (struct → column values)

  defp encode_task(%TaskInfo{} = task) do
    [
      task.id,
      encode_atom(task.type),
      Atom.to_string(task.status),
      encode_opts(task.opts),
      encode_pid(task.pid),
      encode_datetime(task.started_at),
      encode_datetime(task.finished_at),
      encode_logs(task.logs),
      encode_result(task.result),
      encode_atom(task.review_status),
      encode_usage(task.usage),
      task.agent_count,
      task.base_sha,
      task.commit_sha,
      encode_archive(task.archive_metadata)
    ]
  end

  defp encode_project(%EvoDash.RecentProject{} = project) do
    [
      project.path,
      project.name,
      encode_datetime(project.last_opened_at)
    ]
  end

  ## Private — Decoding (column values → struct)

  defp decode_task(row) do
    [
      id,
      type,
      status,
      opts,
      pid,
      started_at,
      finished_at,
      logs,
      result,
      review_status,
      usage,
      agent_count,
      base_sha,
      commit_sha,
      archive_metadata
    ] = row

    %TaskInfo{
      id: id,
      type: decode_atom(type),
      status: decode_atom(status) || :pending,
      opts: decode_opts(opts),
      ref: nil,
      pid: decode_pid(pid),
      started_at: decode_datetime(started_at),
      finished_at: decode_datetime(finished_at),
      logs: decode_logs(logs),
      result: decode_result(result),
      review_status: decode_atom(review_status),
      usage: decode_usage(usage),
      agent_count: agent_count,
      base_sha: base_sha,
      commit_sha: commit_sha,
      archive_metadata: decode_archive(archive_metadata)
    }
  end

  defp decode_project([path, name, last_opened_at]) do
    %EvoDash.RecentProject{
      path: path,
      name: name,
      last_opened_at: decode_datetime(last_opened_at)
    }
  end

  ## Private — Field encoders/decoders

  # --- Atoms ---
  defp encode_atom(nil), do: nil
  defp encode_atom(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp decode_atom(nil), do: nil

  defp decode_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> str
    end
  end

  # --- DateTime ---
  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_datetime(nil), do: nil

  defp decode_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # --- opts (keyword list) ---
  # Encode as a JSON array of [key_string, value] pairs to preserve keyword
  # list semantics. If Jason can't serialize the values (tuples, pids, etc.),
  # fall back to encoding just the essential keys (path, mode, prompt,
  # objective), or nil.
  defp encode_opts(nil), do: nil

  defp encode_opts(opts) when is_list(opts) do
    pairs =
      Enum.map(opts, fn
        {key, value} when is_atom(key) -> [Atom.to_string(key), value]
        {key, value} -> [to_string(key), value]
      end)

    try do
      Jason.encode!(pairs)
    rescue
      e ->
        Logger.warning(
          "TaskStore: failed to encode opts fully, trying essential keys: " <>
            "#{Exception.message(e)}"
        )

        try do
          essential =
            opts
            |> Keyword.take([:path, :mode, :prompt, :objective])
            |> Enum.map(fn {key, value} -> [Atom.to_string(key), value] end)

          Jason.encode!(essential)
        rescue
          e2 ->
            Logger.warning(
              "TaskStore: failed to encode essential opts, storing nil: " <>
                "#{Exception.message(e2)}"
            )

            nil
        end
    end
  end

  defp decode_opts(nil), do: nil

  defp decode_opts(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, pairs} when is_list(pairs) ->
        Enum.map(pairs, fn [key_str, value] ->
          {safe_string_to_atom(key_str), value}
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # --- logs (list of strings) ---
  defp encode_logs(nil), do: Jason.encode!([])

  defp encode_logs(logs) when is_list(logs) do
    try do
      Jason.encode!(logs)
    rescue
      _ -> Jason.encode!([])
    end
  end

  defp decode_logs(nil), do: []

  defp decode_logs(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, logs} when is_list(logs) -> logs
      _ -> []
    end
  end

  # --- result (arbitrary term) ---
  # Best-effort JSON encoding. If Jason can't encode the term (tuples, pids,
  # deeply nested atoms), store nil and log a warning. Result is informational.
  defp encode_result(nil), do: nil

  defp encode_result(result) do
    try do
      Jason.encode!(result)
    rescue
      e ->
        Logger.warning("TaskStore: failed to encode result, storing nil: #{Exception.message(e)}")

        nil
    end
  end

  defp decode_result(nil), do: nil

  defp decode_result(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  # --- usage (EvoGit.Agent.Usage struct) ---
  defp encode_usage(nil), do: nil

  defp encode_usage(%EvoGit.Agent.Usage{} = usage) do
    try do
      Jason.encode!(Map.from_struct(usage))
    rescue
      e ->
        Logger.warning("TaskStore: failed to encode usage: #{Exception.message(e)}")
        nil
    end
  end

  defp decode_usage(nil), do: nil

  defp decode_usage(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) ->
        atom_map =
          Enum.reduce(@usage_fields, %{}, fn field, acc ->
            value = Map.get(map, Atom.to_string(field)) || Map.get(map, field)
            Map.put(acc, field, value)
          end)

        struct(EvoGit.Agent.Usage, atom_map)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # --- archive_metadata (list of maps) ---
  defp encode_archive(nil), do: nil

  defp encode_archive(archive) when is_list(archive) do
    try do
      Jason.encode!(archive)
    rescue
      e ->
        Logger.warning("TaskStore: failed to encode archive_metadata: #{Exception.message(e)}")

        nil
    end
  end

  defp decode_archive(nil), do: nil

  defp decode_archive(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, value} when is_list(value) -> value
      _ -> nil
    end
  end

  # --- pid ---
  defp encode_pid(nil), do: nil

  defp encode_pid(pid) when is_pid(pid) do
    pid |> :erlang.pid_to_list() |> List.to_string()
  end

  defp decode_pid(nil), do: nil

  defp decode_pid(str) when is_binary(str) do
    try do
      str |> String.to_charlist() |> :erlang.list_to_pid()
    rescue
      _ -> nil
    end
  end

  # --- shared atom helper ---
  defp safe_string_to_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> str
    end
  end

  ## Private — Safe select (quarantine bad rows)

  defp safe_select_all_rows(conn, table, decoder) do
    columns = table_columns(table)
    col_list = Enum.join(columns, ", ")
    pk = pk_column(table)

    case XqliteNIF.query(conn, "SELECT #{col_list} FROM #{table}", []) do
      {:ok, %{rows: rows}} ->
        Enum.flat_map(rows, fn row ->
          id = hd(row)

          try do
            [decoder.(row)]
          rescue
            e ->
              quarantine_row(conn, table, id, pk, columns, row)

              Logger.warning(
                "TaskStore: skipping undecodable row in #{table} " <>
                  "(id: #{inspect(id)}): #{Exception.message(e)}"
              )

              []
          end
        end)

      _ ->
        []
    end
  end

  ## Private — Integrity check

  defp do_integrity_check(conn) do
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
              scan_and_repair(conn, "tasks", &decode_task/1) +
                scan_and_repair(conn, "projects", &decode_project/1)

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

  defp scan_and_repair(conn, table, decoder) do
    columns = table_columns(table)
    col_list = Enum.join(columns, ", ")
    pk = pk_column(table)

    case XqliteNIF.query(conn, "SELECT #{col_list} FROM #{table}", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, 0, fn row, acc ->
          id = hd(row)

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
      try do
        columns
        |> Enum.zip(row)
        |> Map.new()
        |> Jason.encode!()
      rescue
        _ -> nil
      end

    try do
      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "INSERT OR REPLACE INTO #{quarantine_table} (id, data) VALUES (?1, ?2)",
          [id, json_data]
        )

      {:ok, _} =
        XqliteNIF.execute(conn, "DELETE FROM #{table} WHERE #{pk} = ?1", [id])

      Logger.warning(
        "TaskStore: quarantined undecodable row " <>
          "(table=#{table}, id=#{inspect(id)}) → #{quarantine_table}. " <>
          "Raw data preserved for recovery."
      )
    rescue
      e ->
        Logger.error(
          "TaskStore: failed to quarantine undecodable row " <>
            "(table=#{table}, id=#{inspect(id)}): #{Exception.message(e)}. " <>
            "Leaving row in place — data NOT destroyed."
        )
    end
  end
end
