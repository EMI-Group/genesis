defmodule EvoGit.Store do
  @moduledoc """
  SQLite-backed persistent store for EvoGit tasks and recent projects.

  A THIN GenServer facade over the Ecto Operations layer: every handler
  dispatches to a pure operation module in `EvoGit.Store.Operations.*` against
  this store's OWN unnamed dynamic `EvoGit.Repo` instance. The public client
  API is the contract — names, arities, defaults, `@call_timeout`, docs, and
  return shapes are unchanged from the raw-SQL store (`lib/evo_git/task_registry.ex`
  and the `evo_dash` RPC surface call it untouched).

  ## Architecture

    * **Boot** — `init/1` starts the dynamic repo via
      `EvoGit.Store.Boot.start_dynamic/1`, which runs the Ecto migrations in
      `priv/repo/migrations/` (baseline schema adoption + data normalization:
      column adds, fixed-precision timestamp rewrites, canonical
      `result`/`opts` rewrites) BEFORE any read or write. Migrating at boot is
      idempotent — a no-op on a fresh or already-current database — so an
      existing user DB is upgraded automatically on first start; a manual
      `mix migrate.store` is never required for the app to boot.
    * **Operations** — `Operations.Tasks`, `Operations.Lightweight`,
      `Operations.Summaries`, `Operations.Projects`, `Operations.Safety` own
      the actual `EvoGit.Repo.*` + `Ecto.Query` work. Every function takes the
      repo pid FIRST and binds it with `EvoGit.Store.RepoScope.with_repo/2`,
      so it targets THIS store's dynamic instance regardless of the calling
      process. All serialization is delegated to `EvoGit.Store.Codec` (the
      single encode/decode oracle) through `EvoGit.Store.Types.*`.
    * **Facade** — this module keeps: the client API, the `handle_call`
      dispatch (one line per handler), the heavy-read offload, and the
      disk-full write choke point. No SQL lives here.

  ## Crash philosophy

  The `handle_call` callbacks have NO blanket try/rescue. If a database
  read/write fails, the GenServer crashes and the supervisor restarts it with
  a fresh repo instance. Data is safe in SQLite WAL mode
  (`journal_mode: :wal`, `synchronous: :normal`).

  Three deliberate, documented boundaries:

    * **Disk-full writes** — SQLite's disk-full error class (`SQLITE_FULL`
      13, `SQLITE_IOERR` 10, `SQLITE_READONLY` 8) is RAISED by the
      `XqliteEcto3` adapter as `%XqliteEcto3.Error{}` and converted at this
      facade's write choke point (`write_call/2`) to `{:error, :disk_full}`
      after logging an actionable warning. The GenServer survives so reads
      keep working and writes can be retried — a full disk is transient,
      unlike a corrupt DB. All OTHER errors re-raise and crash as before.
      See `EvoGit.Store.Errors` for the classifier. (`put_project` is
      protected INSIDE `Operations.Projects` — not double-wrapped here.)
    * **Heavy read offload** — the full-decode read handlers run the query
      AND the decode on a short-lived linked Task and reply via
      `GenServer.reply/2`. Every Operations function binds the dynamic repo
      through `RepoScope.with_repo/2` inside the calling process, so the
      offloaded work addresses the correct instance from the Task's own
      process. Large decoded terms are allocated and discarded on the Task's
      heap, not this GenServer's. The Task is LINKED to this process, so a
      decode raise still crashes the GenServer exactly like the old inline
      handler did. The caller's 30s `@call_timeout` still applies.
    * **Per-row safe decode** — the safe-select/summary Operations skip (and
      log) rows whose Codec decode raises instead of crashing the whole
      select; that boundary lives inside the Operations modules, not here.

  The only justified try/rescue patterns that remain in THIS module:

    * `terminate/2` — graceful repo shutdown during terminate. GenServer
      terminate/2 must never raise; a crash here could prevent clean
      supervision shutdown.
    * `write_call/2` — the disk-full write choke point described above.
  """

  use GenServer

  require Logger

  alias EvoGit.Store.Operations
  alias EvoGit.Store.Errors
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
  Returns the ids of all tasks whose status is NOT running, pending, or
  cancelling.

  Used by TaskRegistry.clear_finished_tasks to avoid decoding all tasks just
  to filter by status — the status filtering happens in SQL. `:cancelling` is
  excluded so an in-flight graceful cancel is never deleted.
  """
  def select_finished_task_ids(store \\ __MODULE__) do
    GenServer.call(store, :select_finished_task_ids, @call_timeout)
  end

  @doc """
  Returns a minimal id/status/updated_at projection for all tasks matching the
  given `statuses` (atoms; `[]` = no filter, all rows).

  This is a lightweight query — only the `id`, `status`, and `updated_at`
  columns are read, no JSON blobs are decoded. `updated_at` is returned as the
  RAW stored fixed-precision ISO string (not decoded to a DateTime). When
  `statuses` is non-empty, the status filter is pushed into SQL
  (`WHERE status IN (...)`).

  Used by the dashboard to track which tasks changed without decoding the heavy
  summary projection.
  """
  def select_task_ids(store \\ __MODULE__, statuses \\ []) do
    GenServer.call(store, {:select_task_ids, statuses}, @call_timeout)
  end

  @doc """
  Returns lightweight lease info for running/finalizing/cancelling tasks:
  `%{id, status, lease_expires_at}`. Only the `status` column is decoded (a
  lightweight atom); no heavy JSON fields (logs, result, usage,
  archive_metadata) are touched. The status filter happens in SQL
  (`WHERE status IN ('running', 'finalizing', 'cancelling')`).

  Used by TaskRegistry.lease_sweep and startup reconciliation to avoid a full
  decode of all tasks just to check status and lease validity. `:cancelling`
  is included so startup reconciliation can resolve orphaned cancelling
  tasks; the lease_sweep keeps its `:running`-only Elixir filter.
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
  archive_metadata, opts) are encoded through the appropriate `Codec.encode_*`
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
  fields. Used by TaskRegistry.append_log to avoid a full 19-column decode
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

  # Test seam: the dynamic repo instance owned by this store. Used by the
  # disk-full tests (and any test that must talk to the store's OWN database
  # connection) instead of reaching into GenServer state.
  @doc false
  def __repo_pid__(store \\ __MODULE__) do
    GenServer.call(store, :__repo_pid__, @call_timeout)
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir} = init_arg) do
    File.mkdir_p!(Path.dirname(data_dir))

    case EvoGit.Store.Boot.start_dynamic(data_dir) do
      {:ok, repo} ->
        name = Map.get(init_arg, :name)
        {:ok, %{repo: repo, name: name, data_dir: data_dir}}

      {:error, reason} ->
        # Keep the historical stop reason tuple: supervisors and existing
        # tests match on {:failed_to_open_sqlite, reason} for boot failures.
        {:stop, {:failed_to_open_sqlite, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{repo: repo} = _state) do
    # Justified try/rescue: (1) Do we expect an error here? Possibly — the
    # repo instance may already be stopping or in a bad state during
    # shutdown. (2) Is try/rescue cleanest? Yes — GenServer terminate/2 must
    # NEVER raise; a crash here could prevent clean supervision shutdown and
    # leave the process in a half-dead state.
    try do
      EvoGit.Store.Boot.stop(repo)
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
    {:reply, write_call(state, fn -> Operations.Tasks.put_task(state.repo, task) end), state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    {:reply, Operations.Tasks.get_task(state.repo, task_id), state}
  end

  @impl true
  def handle_call({:delete_task, task_id}, _from, state) do
    {:reply, write_call(state, fn -> Operations.Tasks.delete_task(state.repo, task_id) end),
     state}
  end

  # Batched deletes: the chunk loop (500 ids per WHERE id IN (...) statement,
  # one commit per chunk) lives in the Operation — partial-deletion-across-
  # chunks semantics on disk-full are preserved there.
  @impl true
  def handle_call({:delete_tasks, task_ids}, _from, state) do
    {:reply, write_call(state, fn -> Operations.Tasks.delete_tasks(state.repo, task_ids) end),
     state}
  end

  # Offloaded: the query AND the decode run on a short-lived linked Task so
  # large decoded terms are allocated and discarded on that process's heap,
  # not this GenServer's. See offload/3 for the full rationale.
  @impl true
  def handle_call(:select_all_tasks, from, state) do
    offload(from, state, fn -> Operations.Tasks.select_all_tasks(state.repo) end)
  end

  @impl true
  def handle_call(:count_tasks, _from, state) do
    {:reply, Operations.Tasks.count_tasks(state.repo), state}
  end

  # Offloaded (query + decode + reply on a linked short-lived Task): the
  # decoded task list is the largest term this store produces — it must not
  # be allocated on this GenServer's heap. The skip-and-log decode boundary
  # runs inside the Task, preserving its exact behavior.
  @impl true
  def handle_call({:safe_select_paginated_tasks, opts}, from, state) do
    offload(from, state, fn ->
      Operations.Tasks.safe_select_paginated_tasks(state.repo, opts)
    end)
  end

  @impl true
  def handle_call(:clear_tasks, _from, state) do
    {:reply, write_call(state, fn -> Operations.Tasks.clear_tasks(state.repo) end), state}
  end

  @impl true
  def handle_call(:select_task_paths, _from, state) do
    {:reply, Operations.Lightweight.select_task_paths(state.repo), state}
  end

  @impl true
  def handle_call(:select_finished_task_ids, _from, state) do
    {:reply, Operations.Lightweight.select_finished_task_ids(state.repo), state}
  end

  @impl true
  def handle_call({:select_task_ids, statuses}, _from, state) do
    {:reply, Operations.Lightweight.select_task_ids(state.repo, statuses), state}
  end

  @impl true
  def handle_call(:select_running_lease_info, _from, state) do
    {:reply, Operations.Lightweight.select_running_lease_info(state.repo), state}
  end

  # Lightweight write — the lease heartbeat must NOT bump `updated_at` (the
  # Operation owns that rule).
  @impl true
  def handle_call({:update_lease_expires_at, task_id, expires_at}, _from, state) do
    {:reply,
     write_call(state, fn ->
       Operations.Tasks.update_lease_expires_at(state.repo, task_id, expires_at)
     end), state}
  end

  # Targeted write — the Operation encodes each column through the Codec
  # (byte-identical SET clauses) and ALWAYS bumps `updated_at`.
  @impl true
  def handle_call({:update_task_columns, task_id, columns}, _from, state) do
    {:reply,
     write_call(state, fn ->
       Operations.Tasks.update_task_columns(state.repo, task_id, columns)
     end), state}
  end

  @impl true
  def handle_call({:get_task_status, task_id}, _from, state) do
    {:reply, Operations.Tasks.get_task_status(state.repo, task_id), state}
  end

  @impl true
  def handle_call({:select_task_logs, task_id}, _from, state) do
    {:reply, Operations.Tasks.select_task_logs(state.repo, task_id), state}
  end

  @impl true
  def handle_call({:select_task_update_info, task_id}, _from, state) do
    {:reply, Operations.Tasks.select_task_update_info(state.repo, task_id), state}
  end

  @impl true
  def handle_call(:select_cleanup_info, _from, state) do
    {:reply, Operations.Lightweight.select_cleanup_info(state.repo), state}
  end

  @impl true
  def handle_call({:select_cleanup_info, cutoff_iso, max_tasks}, _from, state) do
    {:reply, Operations.Lightweight.select_cleanup_info(state.repo, cutoff_iso, max_tasks), state}
  end

  # Offloaded (query + decode + reply on a linked short-lived Task): the
  # dashboard-poll hot path — the decoded summary list must not be allocated
  # on this GenServer's heap. The skip-and-log boundary runs inside the Task.
  @impl true
  def handle_call({:select_tasks_summary, statuses, since}, from, state) do
    offload(from, state, fn ->
      Operations.Summaries.select_tasks_summary(state.repo, statuses, since)
    end)
  end

  @impl true
  def handle_call({:select_tasks_summary_by_path, project_path, statuses, since}, from, state) do
    # Offloaded — same rationale as select_tasks_summary.
    offload(from, state, fn ->
      Operations.Summaries.select_tasks_summary_by_path(
        state.repo,
        project_path,
        statuses,
        since
      )
    end)
  end

  @impl true
  def handle_call({:select_tasks_changed_since, since_iso}, from, state) do
    # Offloaded — same rationale as select_tasks_summary.
    offload(from, state, fn ->
      Operations.Summaries.select_tasks_changed_since(state.repo, since_iso)
    end)
  end

  ## GenServer — Project handlers

  # Operations.Projects owns its own disk-full rescue (returns
  # {:error, :disk_full} directly) — NOT wrapped in write_call/2 here.
  @impl true
  def handle_call({:put_project, project}, _from, state) do
    {:reply, Operations.Projects.put_project(state.repo, project), state}
  end

  @impl true
  def handle_call({:get_project, path}, _from, state) do
    {:reply, Operations.Projects.get_project(state.repo, path), state}
  end

  @impl true
  def handle_call({:delete_project, path}, _from, state) do
    {:reply, write_call(state, fn -> Operations.Projects.delete_project(state.repo, path) end),
     state}
  end

  @impl true
  def handle_call(:select_all_projects, _from, state) do
    {:reply, Operations.Projects.select_all_projects(state.repo), state}
  end

  @impl true
  def handle_call(:count_projects, _from, state) do
    {:reply, Operations.Projects.count_projects(state.repo), state}
  end

  ## GenServer — Size & Safety handlers

  @impl true
  def handle_call(:size, _from, state) do
    {:reply, Operations.Safety.size(state.repo), state}
  end

  # Offloaded (query + decode + reply on a linked short-lived Task): full
  # table decode of every task row is the store's heaviest allocation — it
  # must not run on this GenServer's heap. The skip-and-log boundary runs
  # inside the Task.
  @impl true
  def handle_call(:safe_select_all_tasks, from, state) do
    offload(from, state, fn -> Operations.Safety.safe_select_all_tasks(state.repo) end)
  end

  @impl true
  def handle_call(:safe_select_all_projects, _from, state) do
    {:reply, Operations.Safety.safe_select_all_projects(state.repo), state}
  end

  ## GenServer — Test seam

  @impl true
  def handle_call(:__repo_pid__, _from, state) do
    {:reply, state.repo, state}
  end

  ## Private — Helpers

  # ── Offload helper ───────────────────────────────────────────────────
  #
  # Shared shape for every offloaded read handler: spawns a short-lived LINKED
  # Task running `fun` (the query AND the decode), replies to `from` with its
  # result, and returns {:noreply, state}. Large decoded terms are allocated
  # and discarded on the Task's heap, not this GenServer's. The Task is LINKED
  # to this process, so a decode/query raise inside `fun` crashes the
  # GenServer exactly like the old inline handler did. Every Operations
  # function binds the dynamic repo via RepoScope.with_repo/2 in the CALLING
  # process, so the offloaded work addresses this store's own repo instance
  # from inside the Task. `fun` closes over the CURRENT state (captured in
  # the handler process before the Task runs); state itself is returned
  # unchanged (offloaded handlers never mutate it). The caller's 30s
  # @call_timeout still applies (it times out if the Task is slower — same
  # as the historical slow-NFS behavior).
  defp offload(from, state, fun) do
    {:ok, _task_pid} =
      Task.start(fn ->
        GenServer.reply(from, fun.())
      end)

    {:noreply, state}
  end

  # ── Write boundary (disk-full choke point) ───────────────────────────
  #
  # Shared boundary for EVERY task/project write dispatched by this facade
  # (put_task, delete_task, delete_tasks, clear_tasks, update_lease_expires_at,
  # update_task_columns, delete_project — put_project protects itself inside
  # Operations.Projects). The XqliteEcto3 adapter RAISES %XqliteEcto3.Error{}
  # on failure; disk-full-class errors (SQLITE_FULL 13, SQLITE_IOERR 10,
  # SQLITE_READONLY 8 — see EvoGit.Store.Errors) are converted to
  # {:error, :disk_full} after logging an actionable warning: the GenServer
  # survives, reads keep working, and subsequent writes can be retried (a
  # full disk is transient). ANY OTHER error re-raises, crashing the GenServer
  # exactly like the old raw-SQL `raise MatchError` boundary did — the error
  # contract converts ONLY the disk-full class.
  defp write_call(state, fun) do
    fun.()
  rescue
    exception ->
      if Errors.disk_full_exception?(exception) do
        log_disk_full(state.data_dir, exception)
        {:error, :disk_full}
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp log_disk_full(data_dir, exception) do
    Logger.warning(
      "Store: DISK FULL — SQLite write failed for database at #{data_dir}. " <>
        "Free disk space on this volume and retry the write. " <>
        "(error: #{Exception.message(exception)})"
    )
  end
end
