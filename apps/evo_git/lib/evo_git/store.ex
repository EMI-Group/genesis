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
      `EvoGit.Store.Boot.start_dynamic/2` (this store's `:pool_size` opt,
      defaulting to `EvoGit.Store.Boot.default_pool_size/0` — more than one
      connection, so reads do not all serialize on a single one), which runs
      the Ecto migrations in
      `priv/repo/migrations/` (baseline schema adoption + data normalization:
      column adds, fixed-precision timestamp rewrites, canonical
      `result`/`opts` rewrites) BEFORE any read or write. Migrating at boot is
      idempotent — a no-op on a fresh or already-current database — so an
      existing user DB is upgraded automatically on first start; a manual
      `mix migrate.store` is never required for the app to boot.
    * **Operations** — `Operations.Tasks`, `Operations.Lightweight`,
      `Operations.Summaries`, `Operations.Pages`, `Operations.Archives`,
      `Operations.Filters`, `Operations.Projects`, `Operations.Safety` own
      the actual `EvoGit.Repo.*` + `Ecto.Query` work. Every function takes the
      repo pid FIRST and binds it with `EvoGit.Store.RepoScope.with_repo/2`,
      so it targets THIS store's dynamic instance regardless of the calling
      process. All serialization is delegated to `EvoGit.Store.Codec` (the
      single encode/decode oracle) through `EvoGit.Store.Types.*` — except the
      relational per-agent archive (`task_agent_archives`), whose four JSON
      columns are plain Jason (`EvoGit.Store.Types.ArchiveColumns.*`: no
      compression, no magic prefixes).
    * **Facade** — this module keeps: the client API, the `handle_call`
      dispatch (one line per handler), the heavy-read offload, the write
      offload to the dedicated `EvoGit.Store.Writer` process, and the
      disk-full write choke point. No SQL lives here.

  ## Crash philosophy

  **No READ failure may take this GenServer down.** Every read handler runs its
  query AND its decode in a failure-isolated worker process (see `offload/5`):
  a raise, an exit, a kill, a failed worker start or a missed internal deadline
  is logged and answered with that read's documented DEGRADED value, while the
  facade keeps serving its mailbox. A WRITE fault may still crash this process
  (the supervisor then restarts it with a fresh repo instance); the only write
  exception is the disk-full class, converted at `write_call/2`. Data is safe
  in SQLite WAL mode (`journal_mode: :wal`, `synchronous: :normal`).

  ## Read degradation policy

  A failed read NEVER raises, NEVER exits and NEVER returns `{:error, ...}` —
  it returns the EMPTY VALUE OF ITS OWN SHAPE, so every caller's happy-path
  pattern match keeps working:

  | Read | Degraded value |
  |------|----------------|
  | `get_task/2`, `get_task_lite/2`, `get_task_status/2`, `select_task_update_info/2`, `get_project/2`, `get_agent_archive/3` | `nil` |
  | `select_task_paths/1`, `select_finished_task_ids/1`, `select_task_ids/2`, `select_running_lease_info/1`, `select_cleanup_info/1,3`, `select_tasks_summary/3`, `select_tasks_summary_by_path/4`, `select_tasks_changed_since/2`, `select_all_projects/1`, `safe_select_all_tasks/1`, `safe_select_all_projects/1` | `[]` |
  | `safe_select_paginated_tasks/2` | `{[], 0}` |
  | `select_tasks_page/2` | `%{rows: [], total: 0}` |
  | `list_task_archives/3` | `%{entries: [], total: 0}` |
  | `count_projects/1`, `size/1` | `0` |

  The degraded value is passed EXPLICITLY at each call site (`offload/5`'s
  `degraded_value` argument), so this table and the handlers can never drift.
  The failure is logged at `:error` with the operation name and the reason
  (exception + stacktrace, exit reason, or `:timeout`), so a degraded read is
  observable and attributable — never silent.

  Deliberate, documented boundaries:

    * **Disk-full writes** — SQLite's disk-full error class (`SQLITE_FULL`
      13, `SQLITE_IOERR` 10, `SQLITE_READONLY` 8) is RAISED by the
      `XqliteEcto3` adapter as `%XqliteEcto3.Error{}` and converted at this
      facade's write choke point (`write_call/2`) to `{:error, :disk_full}`
      after logging an actionable warning. The GenServer survives so reads
      keep working and writes can be retried — a full disk is transient,
      unlike a corrupt DB. All OTHER errors re-raise and crash as before.
      See `EvoGit.Store.Errors` for the classifier. (`put_project` is
      protected INSIDE `Operations.Projects` — not double-wrapped here.)
    * **Write offload** — every write handler forwards its operation to the
      store's dedicated `EvoGit.Store.Writer` process (`offload_write/3`) and
      returns `{:noreply, state}` RIGHT AWAY; the writer runs the operation and
      `GenServer.reply/2`s the original caller once it has committed. A slow
      write (`put_task` of a multi-megabyte row is ~137 ms; cleanup bursts
      issue hundreds of statements) therefore no longer stalls this GenServer's
      mailbox — reads, counts and the 60 s lease heartbeat keep being served.
      The writer is a single process, so writes stay strictly serialized in
      arrival order, and the reply still arrives only after the commit. It is
      LINKED to this process, so a failing statement kills the store with the
      operation's own reason exactly like the old inline raise. The disk-full
      choke point's closure is executed INSIDE the writer, so the adapter's
      raise and its `{:error, :disk_full}` conversion happen where the write
      runs. See `EvoGit.Store.Writer`.
    * **Failure-isolated read offload** — EVERY read handler runs its query AND
      its decode on a short-lived UNLINKED-but-monitored worker
      (`spawn_monitor`) and replies via `GenServer.reply/2`. Every Operations
      function binds the dynamic repo through `RepoScope.with_repo/2` inside
      the calling process, so the offloaded work addresses the correct
      instance from the worker's own process. Large decoded terms are
      allocated and discarded on the worker's heap, not this GenServer's. The
      worker is NOT linked, so a query/decode raise, an exit or a kill inside
      it arrives here as a `:DOWN` message (or as an internal-deadline
      message) and is answered with the read's degraded value — nothing from an
      offloaded read ever propagates to this process. A failure is re-raised by
      the worker body as a `:shutdown`-class exit (`run_offload/2`), so the
      runtime emits NO second OTP crash report for it: the facade's own log
      line is the ONLY trace of a degraded read. The caller's 30s
      `@call_timeout` still applies, and the internal deadline is shorter, so
      the degraded reply always beats the caller's own timeout.
    * **Per-row safe decode** — the safe-select/summary Operations skip (and
      log) rows whose Codec decode raises instead of crashing the whole
      select; that boundary lives inside the Operations modules, not here.

  The only justified try/rescue patterns that remain in THIS module:

    * `terminate/2` — graceful writer drain + repo shutdown during terminate.
      GenServer terminate/2 must never raise; a crash here could prevent clean
      supervision shutdown.
    * `write_call/2` — the disk-full write choke point described above. Its
      closure is executed by the writer process (see `offload_write/3`), which
      is where the adapter raises it.
    * `start_offload_worker/2` — converts a worker-SPAWN failure (e.g.
      `:system_limit`) into the same degraded reply a failed read produces,
      instead of crashing this GenServer.
    * `run_offload/2` — the fault-isolation boundary INSIDE the read worker: a
      query/decode failure exits the worker with a `:shutdown`-class reason
      (carrying kind/reason/stacktrace) instead of propagating an uncaught
      exception, which would add a duplicate OTP crash report on top of this
      module's own log line.
    * `handle_info({:DOWN, ...})` / `handle_info({:offload_timeout, ...})` —
      not try/rescue, but the same principle: an offloaded read's failure is
      OBSERVED and DEGRADED, never re-raised.
  """

  use GenServer

  require Logger

  alias EvoGit.Store.Operations
  alias EvoGit.Store.Errors
  alias EvoGit.Store.Writer
  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

  ## Call timeout

  # SQLite I/O can be very slow when the database file lives on high-latency
  # storage (e.g. an NFS-mounted home directory on a remote server), so every
  # GenServer.call/3 to this store uses an explicit 30s timeout instead of the
  # 5s default. Keep the value tunable in one place. The write offload does not
  # change it: a write's call still waits for that write's commit, it just no
  # longer holds up any OTHER caller while it does.
  @call_timeout 30_000

  # Internal deadline for an OFFLOADED READ, deliberately shorter than
  # `@call_timeout`: when a worker wedges (e.g. an uninterruptible NFS read)
  # the facade kills it and replies with the read's degraded value BEFORE the
  # caller's own `GenServer.call/3` would time out and exit — a slow/failing
  # read must degrade the value, never crash the caller.
  @offload_timeout 25_000

  # Bounded wait for the writer to drain in-flight writes at terminate/2.
  @writer_stop_timeout 5_000

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
    * `:pool_size` — (optional) pool size for this store's OWN dynamic repo,
      forwarded to `EvoGit.Store.Boot.start_dynamic/2`. Defaults to
      `EvoGit.Store.Boot.default_pool_size/0`, i.e. MORE than one connection:
      this store's reads then run concurrently instead of all queueing on a
      single connection (its writes stay serialized by this GenServer, so no
      write-write contention is introduced). Pass `1` to force a
      single-connection store — the disk-full tests do, because the
      `PRAGMA query_only` arm they use is CONNECTION-scoped and therefore only
      deterministic when the pool has exactly one connection.
  """
  def start_link(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    name = Keyword.get(opts, :name, __MODULE__)
    pool_size = Keyword.get(opts, :pool_size)

    GenServer.start_link(
      __MODULE__,
      %{data_dir: data_dir, name: name, pool_size: pool_size},
      name: name
    )
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

  @doc """
  LIGHTWEIGHT single-task read — the detail/review-page variant of
  `get_task/2`.

  Decodes every task column exactly like `get_task/2` (same Codec), i.e. the
  returned struct is FIELD-IDENTICAL to `get_task/2`'s. Nothing has to be
  skipped any more: the per-agent archive is NOT part of the task row, it
  lives in the relational `task_agent_archives` table
  (`list_task_archives/3` + `get_agent_archive/3`). Returns `nil` when the row
  is absent (and on a failed read — see the moduledoc's degradation table).
  """
  def get_task_lite(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:get_task_lite, task_id}, @call_timeout)
  end

  ## Public API — Per-agent archive (`task_agent_archives`)

  @doc """
  Inserts or REPLACES one archived agent's row (`task_agent_archives`).

  `entry` is a map — atom-keyed (the producer's shape) or string-keyed (the
  shape `get_agent_archive/3` returns); every field accepts both spellings.
  Missing values default (`depth` 0, `compression_count` 0, the rest `nil`).
  The write is IDEMPOTENT on `(task_id, agent_id)`: a re-put replaces, never
  duplicates. Dispatched through the WRITE offload (the dedicated
  `EvoGit.Store.Writer`), so it is serialized with every other write and its
  reply arrives only after the commit.

  Returns `:ok` (`{:error, :disk_full}` on a full disk,
  `{:error, :missing_task_id}` / `{:error, :missing_agent_id}` for an entry
  that cannot identify its row — no statement is issued for those).
  """
  def put_task_archive(store \\ __MODULE__, entry) do
    GenServer.call(store, {:put_task_archive, entry}, @call_timeout)
  end

  @doc """
  Returns one page of a task's archived agents plus (by default) that task's
  total row count: `%{entries: [entry], total: non_neg_integer | nil}`.
  Entries are STRING-KEYED maps ordered `depth ASC, agent_id ASC` (the spawn
  tree, root first). `opts`:
    * `:limit` — page size (default 100, clamped to 1..1000).
    * `:offset` — rows to skip (default 0, never negative).
    * `:include_results` — default `false`: the heavy `result` column is NOT
      selected and the `"result"` key is ABSENT from every entry; pass `true`
      to include each agent's full result text. Fetch ONE agent's result
      instead with `get_agent_archive/3`.
    * `:include_settings` — default `false`: the export-only JSON columns
      (`"llm_settings"`, `"agent_settings"`, `"foreign_repos"`) are NOT
      selected and their keys are ABSENT from every entry (absent, never
      `nil`); the CSV/JSON export passes `true`.
    * `:include_total` — default `true`: pass `false` to skip the `count(*)`
      aggregate when the caller already knows the total — `total` is then
      `nil`.

  `total` counts ALL of the task's archive rows, independent of the page.
  Degrades to `%{entries: [], total: 0}` on a failed read (see the
  moduledoc).
  """

  def list_task_archives(store \\ __MODULE__, task_id, opts \\ []) do
    GenServer.call(store, {:list_task_archives, task_id, opts}, @call_timeout)
  end

  @doc """
  Returns ONE archived agent's full entry (including `"result"`), or `nil` when
  the task has no such agent (and on a failed read — see the moduledoc).

  This is the lazy detail half of the archive API: `list_task_archives/3` pages
  the roster without results, this fetches the opened agent's conversation.
  """
  def get_agent_archive(store \\ __MODULE__, task_id, agent_id) do
    GenServer.call(store, {:get_agent_archive, task_id, agent_id}, @call_timeout)
  end

  @doc """
  Deletes every archive row of ONE task. Returns `:ok` (also when the task had
  no archive rows — a DELETE matching nothing is a successful no-op).

  Dispatched through the WRITE offload, like every other write.
  """
  def delete_task_archives(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:delete_task_archives, task_id}, @call_timeout)
  end

  @doc "Deletes a single task by id."
  def delete_task(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:delete_task, task_id}, @call_timeout)
  end

  @doc "Deletes multiple tasks by id in one call. `task_ids` is a list of id strings."
  def delete_tasks(store \\ __MODULE__, task_ids) do
    GenServer.call(store, {:delete_tasks, task_ids}, @call_timeout)
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

  @doc """
  LIGHTWEIGHT paginated task read: one page of the 16-key summary projection
  plus the filtered total, `%{rows: [summary_map], total: non_neg_integer}`.

  This is the read the dashboard's task list / any reporting surface should
  use: the heavy JSON blobs (`result`, `logs`, `usage`) are
  never selected, so a page of 25 rows costs the same whether a row carries
  1 kB or 108 MB of `result`. Rows are `ORDER BY started_at DESC` (index-served)
  and each row is the SAME 16-key map `select_tasks_summary/3` returns.

  `opts` accepts `:limit` (default 25, capped at 50), `:offset` (never
  negative; an offset past the end returns the LAST page) and the filter keys
  `:status`, `:project_path`, `:review_status`, `:search` — either nested under
  `:filters` (the `safe_select_paginated_tasks/2` shape) or at the top level.
  See `EvoGit.Store.Operations.Pages.select_tasks_page/2`.

  Degrades to `%{rows: [], total: 0}` on a failed read (see the moduledoc).
  """
  def select_tasks_page(store \\ __MODULE__, opts) do
    GenServer.call(store, {:select_tasks_page, opts}, @call_timeout)
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
  lightweight atom); no heavy JSON fields (logs, result, usage) are touched.
  The status filter happens in SQL
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

  Column values that need encoding (atoms, datetimes, usage, result, opts)
  are encoded through the appropriate `Codec.encode_*`
  function. Scalar values (strings, integers, nil) are used directly.

  Returns `:ok`. Used by TaskRegistry for partial updates like setting
  review_status, appending logs, and status transitions.
  """
  def update_task_columns(store \\ __MODULE__, task_id, columns) when is_list(columns) do
    GenServer.call(store, {:update_task_columns, task_id, columns}, @call_timeout)
  end

  @doc """
  Returns a single task's stored status WITHOUT conflating "absent" with
  "unreadable" — `nil` only when no row has this id, a known status atom when
  it decodes, and `{:unknown, raw}` when the row EXISTS but its status text is
  outside the whitelist (logged by `EvoGit.Store.Codec.decode_status/1`).
  Callers must treat `{:unknown, _}` as "the row exists" — see
  `EvoGit.TaskRegistry.Lease`, whose classifiers keep the lease heartbeat
  alive and the sweep conservative for such a row.
  Reads only the `status` column — no heavy JSON decode.
  """
  def get_task_status(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:get_task_status, task_id}, @call_timeout)
  end

  @doc """
  Returns narrow update info for a single task:
  `%{status: decoded atom, opts: decoded opts, finished_at: decoded datetime,
  lease_expires_at: raw integer}` (or nil if the row is absent).

  Reads only 4 columns — no heavy JSON fields (logs, result, usage) are
  decoded. Used by TaskRegistry.handle_update_status to
  replace the full `task_get` read-modify-write.
  """
  def select_task_update_info(store \\ __MODULE__, task_id) do
    GenServer.call(store, {:select_task_update_info, task_id}, @call_timeout)
  end

  @doc """
  Returns lightweight cleanup info for finished tasks: `%{id, finished_at}`.
  Only `id` (raw string) and `finished_at` (decoded DateTime or nil) are returned
  — no heavy JSON fields (logs, result, usage) are decoded.
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
  the dashboard sidebar listing. No heavy JSON fields (logs, usage)
  are decoded. Returns a list of plain maps with an :opts key
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
  string. No heavy JSON fields (logs, usage) are decoded.
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

  # Test seam: the dedicated writer process owned by this store. Used by the
  # write-offload tests to assert the writer's lifecycle (e.g. that a store
  # stop takes the writer down with it) instead of reaching into state.
  @doc false
  def __writer__(store \\ __MODULE__) do
    GenServer.call(store, :__writer__, @call_timeout)
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_dir: data_dir} = init_arg) do
    File.mkdir_p!(Path.dirname(data_dir))

    case EvoGit.Store.Boot.start_dynamic(data_dir, pool_size: Map.get(init_arg, :pool_size)) do
      {:ok, repo} ->
        name = Map.get(init_arg, :name)

        # The dedicated writer process owns every WRITE from here on: the
        # write handlers forward to it instead of executing SQL in this
        # GenServer (see the moduledoc's "Write offload" boundary and
        # `EvoGit.Store.Writer`). Started LINKED to this process, and
        # monitoring this process, so either side taking the other down is
        # automatic.
        {:ok, writer} = Writer.start_link(store: self())

        # `offloads` tracks the in-flight FAILURE-ISOLATED read workers
        # (monitor ref => %{pid, from, op, degraded, timer}) so their `:DOWN` /
        # deadline messages can be matched back to the caller and the degraded
        # value. See `offload/5`.
        {:ok, %{repo: repo, name: name, data_dir: data_dir, writer: writer, offloads: %{}}}

      {:error, reason} ->
        # Keep the historical stop reason tuple: supervisors and existing
        # tests match on {:failed_to_open_sqlite, reason} for boot failures.
        {:stop, {:failed_to_open_sqlite, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{repo: repo} = state) do
    # Justified try/rescue: (1) Do we expect an error here? Possibly — the
    # repo instance may already be stopping or in a bad state during
    # shutdown, and the writer drain is bounded. (2) Is try/rescue cleanest?
    # Yes — GenServer terminate/2 must NEVER raise; a crash here could prevent
    # clean supervision shutdown and leave the process in a half-dead state.
    try do
      reap_offloads(state)
      drain_writer(state)
      EvoGit.Store.Boot.stop(repo)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  ## GenServer — Task handlers

  # All write handlers below forward to the dedicated writer process and
  # return {:noreply, state} immediately — this GenServer never executes a
  # write (see offload_write/3 and `EvoGit.Store.Writer`).
  @impl true
  def handle_call({:put_task, task}, from, state) do
    offload_write(from, state, fn -> Operations.Tasks.put_task(state.repo, task) end)
  end

  # Offloaded (failure-isolated): a single-row full decode still allocates the
  # 20-column row (both JSON blobs) — it runs on the worker's heap and a decode
  # fault degrades to `nil` (the "row absent" shape) instead of killing this
  # process.
  @impl true
  def handle_call({:get_task, task_id}, from, state) do
    offload(from, state, "get_task", nil, fn ->
      Operations.Tasks.get_task(state.repo, task_id)
    end)
  end

  @impl true
  def handle_call({:delete_task, task_id}, from, state) do
    offload_write(from, state, fn -> Operations.Tasks.delete_task(state.repo, task_id) end)
  end

  # Batched deletes: the chunk loop (500 ids per WHERE id IN (...) statement,
  # one commit per chunk) lives in the Operation — partial-deletion-across-
  # chunks semantics on disk-full are preserved there.
  @impl true
  def handle_call({:delete_tasks, task_ids}, from, state) do
    offload_write(from, state, fn -> Operations.Tasks.delete_tasks(state.repo, task_ids) end)
  end

  # Offloaded (query + decode + reply on a short-lived unlinked worker): the
  # decoded task list is among the largest terms this store produces — it must
  # not be allocated on this GenServer's heap. The skip-and-log decode boundary
  # runs inside the worker, preserving its exact behavior; a fault degrades to
  # `{[], 0}` (an empty page).
  @impl true
  def handle_call({:safe_select_paginated_tasks, opts}, from, state) do
    offload(from, state, "safe_select_paginated_tasks", {[], 0}, fn ->
      Operations.Tasks.safe_select_paginated_tasks(state.repo, opts)
    end)
  end

  # Offloaded (failure-isolated): the LIGHTWEIGHT page read — summary
  # projection only, so the decoded page is small, but it still runs on the
  # worker's heap and a fault degrades to an empty page rather than killing
  # this process.
  @impl true
  def handle_call({:select_tasks_page, opts}, from, state) do
    offload(from, state, "select_tasks_page", %{rows: [], total: 0}, fn ->
      Operations.Pages.select_tasks_page(state.repo, opts)
    end)
  end

  # Offloaded (failure-isolated): the lightweight single-row detail read. Every
  # task column is decoded exactly like `get_task/2` (the per-agent archive is
  # not part of the task row); a fault degrades to `nil` (the "row absent"
  # shape).
  @impl true
  def handle_call({:get_task_lite, task_id}, from, state) do
    offload(from, state, "get_task_lite", nil, fn ->
      Operations.Pages.get_task_lite(state.repo, task_id)
    end)
  end

  # Offloaded (failure-isolated): the per-agent archive roster read. Never
  # selects `result` unless asked, so a fault degrades to an empty page rather
  # than killing this process.
  @impl true
  def handle_call({:list_task_archives, task_id, opts}, from, state) do
    offload(from, state, "list_task_archives", %{entries: [], total: 0}, fn ->
      {:ok, page} = Operations.Archives.list(state.repo, task_id, opts)
      page
    end)
  end

  # Offloaded (failure-isolated): the archive detail read for ONE agent.
  @impl true
  def handle_call({:get_agent_archive, task_id, agent_id}, from, state) do
    offload(from, state, "get_agent_archive", nil, fn ->
      {:ok, entry} = Operations.Archives.get(state.repo, task_id, agent_id)
      entry
    end)
  end

  # Write — one archived agent's row (idempotent upsert), through the writer.
  @impl true
  def handle_call({:put_task_archive, entry}, from, state) do
    offload_write(from, state, fn -> Operations.Archives.put(state.repo, entry) end)
  end

  @impl true
  def handle_call({:delete_task_archives, task_id}, from, state) do
    offload_write(from, state, fn -> Operations.Archives.delete_by_task(state.repo, task_id) end)
  end

  @impl true
  def handle_call(:clear_tasks, from, state) do
    offload_write(from, state, fn -> Operations.Tasks.clear_tasks(state.repo) end)
  end

  @impl true
  def handle_call(:select_task_paths, from, state) do
    offload(from, state, "select_task_paths", [], fn ->
      Operations.Lightweight.select_task_paths(state.repo)
    end)
  end

  @impl true
  def handle_call(:select_finished_task_ids, from, state) do
    offload(from, state, "select_finished_task_ids", [], fn ->
      Operations.Lightweight.select_finished_task_ids(state.repo)
    end)
  end

  # Offloaded (failure-isolated): an unbounded id/status scan. A fault degrades
  # to `[]` — the "no rows matched" shape — so callers see an empty result
  # rather than an exit. This is the read in the production crash chain (a
  # 26.5 s scan whose DBConnection error used to kill the store, the writer,
  # the registry and every LiveView blocked on it).
  @impl true
  def handle_call({:select_task_ids, statuses}, from, state) do
    offload(from, state, "select_task_ids", [], fn ->
      Operations.Lightweight.select_task_ids(state.repo, statuses)
    end)
  end

  @impl true
  def handle_call(:select_running_lease_info, from, state) do
    offload(from, state, "select_running_lease_info", [], fn ->
      Operations.Lightweight.select_running_lease_info(state.repo)
    end)
  end

  # Lightweight write — the lease heartbeat must NOT bump `updated_at` (the
  # Operation owns that rule). Offloaded like every other write, so the 60s
  # heartbeat never stalls the facade (and vice versa: it waits behind the
  # writes that arrived before it, exactly as it did inline).
  @impl true
  def handle_call({:update_lease_expires_at, task_id, expires_at}, from, state) do
    offload_write(from, state, fn ->
      Operations.Tasks.update_lease_expires_at(state.repo, task_id, expires_at)
    end)
  end

  # Targeted write — the Operation encodes each column through the Codec
  # (byte-identical SET clauses) and ALWAYS bumps `updated_at`.
  @impl true
  def handle_call({:update_task_columns, task_id, columns}, from, state) do
    offload_write(from, state, fn ->
      Operations.Tasks.update_task_columns(state.repo, task_id, columns)
    end)
  end

  @impl true
  def handle_call({:get_task_status, task_id}, from, state) do
    offload(from, state, "get_task_status", nil, fn ->
      Operations.Tasks.get_task_status(state.repo, task_id)
    end)
  end

  @impl true
  def handle_call({:select_task_update_info, task_id}, from, state) do
    offload(from, state, "select_task_update_info", nil, fn ->
      Operations.Tasks.select_task_update_info(state.repo, task_id)
    end)
  end

  @impl true
  def handle_call(:select_cleanup_info, from, state) do
    offload(from, state, "select_cleanup_info", [], fn ->
      Operations.Lightweight.select_cleanup_info(state.repo)
    end)
  end

  @impl true
  def handle_call({:select_cleanup_info, cutoff_iso, max_tasks}, from, state) do
    offload(from, state, "select_cleanup_info", [], fn ->
      Operations.Lightweight.select_cleanup_info(state.repo, cutoff_iso, max_tasks)
    end)
  end

  # Offloaded (query + decode + reply on a short-lived unlinked worker): the
  # dashboard-poll hot path — the decoded summary list must not be allocated on
  # this GenServer's heap, and a fault degrades to `[]` instead of killing it.
  # The skip-and-log boundary runs inside the worker.
  @impl true
  def handle_call({:select_tasks_summary, statuses, since}, from, state) do
    offload(from, state, "select_tasks_summary", [], fn ->
      Operations.Summaries.select_tasks_summary(state.repo, statuses, since)
    end)
  end

  @impl true
  def handle_call({:select_tasks_summary_by_path, project_path, statuses, since}, from, state) do
    # Offloaded — same rationale as select_tasks_summary.
    offload(from, state, "select_tasks_summary_by_path", [], fn ->
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
    offload(from, state, "select_tasks_changed_since", [], fn ->
      Operations.Summaries.select_tasks_changed_since(state.repo, since_iso)
    end)
  end

  ## GenServer — Project handlers

  # Operations.Projects owns its own disk-full rescue (returns
  # {:error, :disk_full} directly) — NOT wrapped in write_call/2 here, exactly
  # as in the old inline handler, so it goes to the writer unwrapped.
  @impl true
  def handle_call({:put_project, project}, from, state) do
    offload_raw_write(from, state, fn ->
      Operations.Projects.put_project(state.repo, project)
    end)
  end

  @impl true
  def handle_call({:get_project, path}, from, state) do
    offload(from, state, "get_project", nil, fn ->
      Operations.Projects.get_project(state.repo, path)
    end)
  end

  @impl true
  def handle_call({:delete_project, path}, from, state) do
    offload_write(from, state, fn -> Operations.Projects.delete_project(state.repo, path) end)
  end

  @impl true
  def handle_call(:select_all_projects, from, state) do
    offload(from, state, "select_all_projects", [], fn ->
      Operations.Projects.select_all_projects(state.repo)
    end)
  end

  @impl true
  def handle_call(:count_projects, from, state) do
    offload(from, state, "count_projects", 0, fn ->
      Operations.Projects.count_projects(state.repo)
    end)
  end

  ## GenServer — Size & Safety handlers

  @impl true
  def handle_call(:size, from, state) do
    offload(from, state, "size", 0, fn -> Operations.Safety.size(state.repo) end)
  end

  # Offloaded (query + decode + reply on a short-lived unlinked worker): full
  # table decode of every task row is the store's heaviest allocation — it must
  # not run on this GenServer's heap, and a fault degrades to `[]`. The
  # skip-and-log boundary runs inside the worker.
  @impl true
  def handle_call(:safe_select_all_tasks, from, state) do
    offload(from, state, "safe_select_all_tasks", [], fn ->
      Operations.Safety.safe_select_all_tasks(state.repo)
    end)
  end

  @impl true
  def handle_call(:safe_select_all_projects, from, state) do
    offload(from, state, "safe_select_all_projects", [], fn ->
      Operations.Safety.safe_select_all_projects(state.repo)
    end)
  end

  ## GenServer — Test seam

  @impl true
  def handle_call(:__repo_pid__, _from, state) do
    {:reply, state.repo, state}
  end

  @impl true
  def handle_call(:__writer__, _from, state) do
    {:reply, state.writer, state}
  end

  ## GenServer — Offloaded-read fault handlers

  # A read worker exited. `:normal` means it already replied with the real value
  # (the reply is the worker's LAST statement), so there is nothing left to do;
  # ANY other reason means it raised/exited/was killed BEFORE replying and the
  # caller gets that read's degraded value. Either way the entry is popped and
  # the deadline timer cancelled, so no stale `:DOWN` is ever left unowned.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.offloads, ref) do
      {nil, _offloads} ->
        # Already handled by the deadline (entry popped there) — ignore.
        {:noreply, state}

      {entry, offloads} ->
        Process.cancel_timer(entry.timer)
        state = %{state | offloads: offloads}

        case reason do
          :normal -> {:noreply, state}
          failure -> fail_offload(entry, failure, state)
        end
    end
  end

  # The worker blew its internal deadline: kill it (so it can never reply
  # afterwards with a stale value) and degrade the read.
  @impl true
  def handle_info({:offload_timeout, ref}, state) do
    case Map.pop(state.offloads, ref) do
      {nil, _offloads} ->
        {:noreply, state}

      {entry, offloads} ->
        if is_pid(entry.pid) and Process.alive?(entry.pid) do
          Process.exit(entry.pid, :kill)
        end

        fail_offload(entry, {:timeout, @offload_timeout}, %{state | offloads: offloads})
    end
  end

  ## Private — Helpers

  # ── Offload helper (failure-isolated read worker) ────────────────────
  #
  # Shared shape for EVERY offloaded read handler:
  #
  #     offload(from, state, op_name, degraded_value, fun)
  #
  # spawns a short-lived UNLINKED worker — `spawn_monitor/1`, NOT
  # `Task.start/1`, which would LINK it — running `fun` (the query AND the
  # decode) and replying to `from` with its result. Large decoded terms are
  # allocated and discarded on the worker's heap, not this GenServer's. Every
  # Operations function binds the dynamic repo via RepoScope.with_repo/2 in the
  # CALLING process, so the offloaded work addresses this store's own repo
  # instance from inside the worker. `fun` closes over the CURRENT state
  # (captured in the handler process before the worker runs).
  #
  # FAULT ISOLATION — nothing inside an offloaded read reaches this process:
  #
  #   * the worker's exit is observed as `{:DOWN, ref, :process, pid, reason}`.
  #     `:normal` means it already replied with the real value (the reply is
  #     the worker's last statement, so a `:normal` exit can only follow it);
  #     ANY other reason means `fun` raised/exited/was killed before replying,
  #     so the caller gets `degraded_value` and the fault is logged at :error
  #     with `op_name`. A `fun` fault arrives as the `:shutdown`-class reason
  #     `{:shutdown, {:offload_failed, kind, reason, stacktrace}}` that
  #     `run_offload/2` produces — deliberately NOT an uncaught raise, whose
  #     separate OTP crash report would log every degraded read twice.
  #   * a worker SPAWN failure is handled identically (see
  #     `start_offload_worker/2`).
  #   * a wedged worker (uninterruptible I/O) is killed at `@offload_timeout`
  #     and the caller gets `degraded_value` — always before its own
  #     `@call_timeout`.
  #
  # In-flight workers are tracked in `state.offloads` (monitor ref => entry) so
  # their `:DOWN`/deadline messages can be matched back to the caller. Entries
  # are always REMOVED when handled (and their timer cancelled), so a `:DOWN`
  # never leaks into the GenServer unowned, and the sole double-reply window is
  # a worker that replies microseconds before its own deadline fires (a stale
  # reply to an already-answered `:gen.call` ref is a benign unmatched message).
  defp offload(from, state, op_name, degraded_value, fun) do
    case start_offload_worker(from, fun) do
      {:ok, pid, ref} ->
        timer = Process.send_after(self(), {:offload_timeout, ref}, @offload_timeout)

        entry = %{
          pid: pid,
          from: from,
          op: op_name,
          degraded: degraded_value,
          timer: timer
        }

        {:noreply, %{state | offloads: Map.put(state.offloads, ref, entry)}}

      {:error, reason} ->
        Logger.error(
          "Store: could not start the read worker for #{op_name} (#{inspect(reason)}) — " <>
            "replying with the degraded value #{inspect(degraded_value)}"
        )

        GenServer.reply(from, degraded_value)

        {:noreply, state}
    end
  end

  # Spawns the unlinked worker. The only try/rescue here is the JUSTIFIED
  # worker-START guard: `spawn_monitor/1` can fail (e.g. `:system_limit`), and
  # that must degrade the ONE read instead of crashing the facade.
  defp start_offload_worker(from, fun) do
    {pid, ref} = spawn_monitor(fn -> run_offload(from, fun) end)

    {:ok, pid, ref}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The worker's OWN body — the fault-isolation boundary of an offloaded read.
  #
  # JUSTIFIED try/catch: this is the centralized boundary where a query/decode
  # failure is converted into a NON-crashing worker exit (the "no try/rescue"
  # rule's fault-isolation-boundary exception). A bare uncaught raise would also
  # be degraded correctly by `fail_offload/3` (via the `:DOWN` reason), but the
  # runtime would ALSO emit an OTP crash report for the worker — asynchronously,
  # through `:logger_proxy`, without an operation name — so every degraded read
  # was logged TWICE. Exiting with a `:shutdown`-class reason (`:shutdown` and
  # `{:shutdown, _}` are NORMAL exit classes for the error logger) suppresses
  # that report at the source while carrying the identical information to the
  # facade through the `:DOWN` message, which `format_offload_reason/1` renders
  # in full (`Exception.format(kind, reason, stacktrace)`).
  defp run_offload(from, fun) do
    GenServer.reply(from, fun.())
  catch
    kind, reason ->
      exit({:shutdown, {:offload_failed, kind, reason, __STACKTRACE__}})
  end

  # Replies with the degraded value for a failed/timed-out read, logs the fault
  # (operation name + reason), and removes the entry from state. `entry` has
  # already been popped by the caller.
  defp fail_offload(entry, reason, state) do
    Logger.error(
      "Store: read #{entry.op} failed — #{format_offload_reason(reason)} — " <>
        "replying with the degraded value #{inspect(entry.degraded)} " <>
        "(the store keeps serving its mailbox)"
    )

    GenServer.reply(entry.from, entry.degraded)

    {:noreply, state}
  end

  # Rendered reason for the log line. A worker fault arrives as the
  # `:shutdown`-class `{:shutdown, {:offload_failed, kind, reason, stacktrace}}`
  # exit its body produces (see `run_offload/2`); it is formatted EXACTLY like
  # the uncaught exception it wraps — the full exception plus stacktrace (the
  # production incident was a `DBConnection.ConnectionError`) — so the degraded
  # path loses no detail. A bare `{exception, stacktrace}` reason is kept as a
  # defensive fallback, an exit/kill reason is inspected.
  defp format_offload_reason({:shutdown, {:offload_failed, kind, reason, stacktrace}})
       when is_list(stacktrace) do
    Exception.format(kind, reason, stacktrace)
  end

  defp format_offload_reason({%{__exception__: true} = exception, stacktrace})
       when is_list(stacktrace) do
    Exception.format(:error, exception, stacktrace)
  end

  defp format_offload_reason({:timeout, timeout_ms}) do
    "internal deadline of #{timeout_ms}ms exceeded (worker killed)"
  end

  defp format_offload_reason(:killed), do: "worker killed"
  defp format_offload_reason(:normal), do: "worker exited without replying"
  defp format_offload_reason(reason), do: inspect(reason)

  # Kills any still-running read worker and cancels its deadline at shutdown, so
  # a terminating store leaves no orphaned worker behind. Never raises.
  defp reap_offloads(%{offloads: offloads}) when is_map(offloads) do
    Enum.each(offloads, fn {_ref, entry} ->
      Process.cancel_timer(entry.timer)

      if is_pid(entry.pid) and Process.alive?(entry.pid) do
        Process.exit(entry.pid, :kill)
      end
    end)
  end

  defp reap_offloads(_state), do: :ok

  # ── Write offload (dedicated writer process) ─────────────────────────
  #
  # Shared shape for EVERY offloaded write handler: hand the operation
  # closure to the store's dedicated writer process and return
  # {:noreply, state} immediately — this GenServer does NOT run the write, so
  # its mailbox stays free for reads (counts, single-row reads, the lease
  # heartbeat) while a slow write runs. The writer executes the closure and
  # `GenServer.reply/2`s the ORIGINAL caller's `from` AFTER the operation has
  # committed (read-after-write), and because BOTH the facade (one message per
  # dequeued call, in mailbox order) and the writer (one write at a time) are
  # FIFO, writes stay strictly serialized in arrival order. The closure closes
  # over the CURRENT state (captured here), and every Operations function
  # binds the dynamic repo through `RepoScope.with_repo/2` in the CALLING
  # process — the writer's — so the write addresses this store's own instance.
  # The caller's 30s @call_timeout still applies to ITS OWN write.
  #
  # A raise inside the closure is NOT rescued here: it crashes the writer and,
  # through the link, this GenServer — see `EvoGit.Store.Writer`.
  defp offload_write(from, state, fun) do
    Writer.submit(state.writer, from, fn -> write_call(state, fun) end)

    {:noreply, state}
  end

  # Offloaded write that carries its OWN disk-full protection
  # (`Operations.Projects.put_project`) — deliberately NOT wrapped in
  # `write_call/2`, exactly like the old inline handler.
  defp offload_raw_write(from, state, fun) do
    Writer.submit(state.writer, from, fun)

    {:noreply, state}
  end

  # ── Write boundary (disk-full choke point) ───────────────────────────
  #
  # Shared boundary for EVERY task/project write dispatched by this facade
  # (put_task, delete_task, delete_tasks, clear_tasks, update_lease_expires_at,
  # update_task_columns, delete_project, put_task_archive,
  # delete_task_archives — put_project protects itself inside
  # Operations.Projects). The XqliteEcto3 adapter RAISES %XqliteEcto3.Error{}
  # on failure; disk-full-class errors (SQLITE_FULL 13, SQLITE_IOERR 10,
  # SQLITE_READONLY 8 — see EvoGit.Store.Errors) are converted to
  # {:error, :disk_full} after logging an actionable warning: the write can be
  # retried (a full disk is transient) and the store survives, so reads keep
  # working. ANY OTHER error re-raises, crashing the store exactly like the old
  # raw-SQL `raise MatchError` boundary did — the error contract converts ONLY
  # the disk-full class.
  #
  # Since the write offload, this runs INSIDE the writer process (the closure
  # passed to `Writer.submit/3` is `fn -> write_call(state, fun) end`): the
  # raise it catches is the one the adapter produces where the statement
  # actually executes, and the reply it produces is the writer's reply to the
  # original caller. The `reraise` still kills the writer (and the store with
  # it) — no new rescue was introduced.
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

  # ── Writer shutdown ─────────────────────────────────────────────────
  #
  # Ask the writer to finish what it is doing and stop, BEFORE the repo
  # instance is closed underneath it (a bounded wait; terminate/2 swallows the
  # failure). The writer is UNLINKED first so that a write failing during this
  # drain cannot change THIS process's exit reason. If the drain times out the
  # writer stays alive — the monitor it holds on this process still takes it
  # down as soon as this process is gone.
  defp drain_writer(%{writer: writer}) when is_pid(writer) do
    if Process.alive?(writer) do
      Process.unlink(writer)
      GenServer.stop(writer, :normal, @writer_stop_timeout)
    end

    :ok
  end

  defp drain_writer(_state), do: :ok

  defp log_disk_full(data_dir, exception) do
    Logger.warning(
      "Store: DISK FULL — SQLite write failed for database at #{data_dir}. " <>
        "Free disk space on this volume and retry the write. " <>
        "(error: #{Exception.message(exception)})"
    )
  end
end
