defmodule EvoGit.Store.Operations.Tasks do
  @moduledoc """
  Ecto TASK operations for the EvoGit task store (migration waves R2a
  write/core + R2b pagination/targeted updates/narrow reads).

  Ports the task handler bodies of the raw-SQL `EvoGit.Store` GenServer onto
  `EvoGit.Repo` + the typed `EvoGit.Store.Schemas.TaskRow` schema. Every public
  function takes the repo pid FIRST and binds it with
  `EvoGit.Store.RepoScope.with_repo/2`; every statement goes through
  `EvoGit.Repo.*` and `Ecto.Query` — no `?N` SQL strings. The wire format is
  owned by `EvoGit.Store.Types.*` (thin delegation to `EvoGit.Store.Codec`,
  the oracle), so the stored bytes are identical to the raw-SQL store's.

  ## Return shapes (exactly the old handlers' — zero consumer changes)

  | function                        | old handler  | returns                                                               |
  |---------------------------------|--------------|----------------------------------------------------------------------|
  | `put_task/2`                    | store.ex:479 | `:ok \| {:error, :missing_task_id} \| {:error, :missing_task_status}` |
  | `get_task/2`                    | store.ex:518 | `%EvoGit.TaskInfo{} \| nil`                                           |
  | `delete_task/2`                 | store.ex:531 | `:ok`                                                                 |
  | `delete_tasks/2`                | store.ex:539 | `:ok`                                                                 |
  | `select_all_tasks/1`            | —            | REMOVED (dead code: zero callers)                                     |
  | `count_tasks/1`                 | —            | REMOVED (dead code: zero callers)                                     |
  | `clear_tasks/1`                 | store.ex:598 | `:ok`                                                                 |
  | `safe_select_paginated_tasks/2` | store.ex:587 | `{[TaskInfo.t()], total_count}` — bad rows skipped+logged, still counted |
  | `update_lease_expires_at/3`     | store.ex:697 | `:ok` — does NOT bump `updated_at`                                    |
  | `renew_leases/3`                | —            | `:ok` — ONE batched UPDATE; does NOT bump `updated_at`                |
  | `update_task_columns/3`         | store.ex:713 | `:ok` — ALWAYS bumps `updated_at`                                     |
  | `get_task_status/2`             | store.ex:730 | `atom() \| {:unknown, raw} \| nil`                                    |
  | `select_task_statuses/2`        | —            | `%{id => atom() \| {:unknown, raw}}` — PRESENT rows only              |
  | `select_tasks_restart_info/2`   | —            | `[%{id, status, type, opts, pause_kind, project_path}]` — bad rows skipped |
  | `select_task_logs/2`            | —            | REMOVED (dead code: nothing writes logs)                              |
  | `select_task_update_info/2`     | store.ex:754 | `%{status, opts, finished_at, lease_expires_at, project_path} \| nil` |

  ## Crash philosophy (inherited from the old `EvoGit.Store` moduledoc)

  NO try/rescue in this module. The ONE justified per-row skip-and-log decode
  boundary of `safe_select_paginated_tasks/2` lives in
  `EvoGit.Store.Operations.Decoding.decode_skipping_bad/4` (DB rows may
  contain corrupt/legacy data that fails to decode; skipping is the
  deliberate recovery boundary). A failed statement RAISES out of the
  `EvoGit.Repo.*` call and surfaces to the caller, exactly like the old
  handler's deliberate bad-match crash. The disk-full conversion boundary
  (`{:error, :disk_full}`) lives in the facade unit that will wrap these
  operations — NOT here.

  ## put_task replace semantics

  ONE `Repo.transaction(..., mode: :immediate)` performing ONE

      Repo.insert_all(TaskRow, [row], on_conflict: :replace_all, conflict_target: :id)

  over a COMPLETE row (`row_for_task/1` always supplies ALL columns — nils
  explicit; struct fields absent from the caller's struct default to nil).
  `:replace_all` on a complete row is semantically identical to the old
  `INSERT OR REPLACE`: re-putting a task NULLs every column the new struct
  omits. The single statement replaces the old `delete_all` + `insert_all`
  pair, so a put maintains its index entries in ONE pass over the six
  `tasks` indexes instead of two.

  ## delete cascade transactions

  `delete_task/2`, `delete_tasks/2` and `clear_tasks/1` each run the task
  `delete_all` AND the explicit `task_agent_archives` cascade delete inside
  ONE `Repo.transaction(..., mode: :immediate)`, so a crash or disk-full
  between the two statements can never orphan archive payloads (there is no
  foreign key to enforce the pair).

  Denormalizations are the Codec's OWN rules, called instead of copied:
  `project_path` ← `Codec.extract_project_path/1` (`opts[:path]`),
  `branch_name` ← `Codec.extract_branch_name/1` (the `branch_name` of an
  `{:ok, data}` result) — each only when the struct field itself is nil — and
  `updated_at` ← `DateTime.utc_now()` in the Codec's fixed-millisecond ISO
  wire format — `TaskTimestampRaw.dump/1` performs the same
  `DateTime.truncate(:millisecond)` + `DateTime.to_iso8601/1` the old handler
  did via `Codec.encode_task/1 ++ [Codec.encode_datetime(DateTime.utc_now())]`.

  ## Growth

  R2b APPENDS the pagination/targeted-update/narrow-read operations to this
  module; the private helpers here (`row_for_task/1`, `to_task_info/1`) are
  the shared row ↔ struct translation surface for them.
  """

  import Ecto.Query

  require Logger

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Archives
  alias EvoGit.Store.Operations.Decoding
  alias EvoGit.Store.Operations.Filters
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo

  # Batched `DELETE ... WHERE id IN (...)` chunk size — 500 ids, safely under
  # SQLite's 999-host-parameter limit (same chunk size as the old raw-SQL
  # handler, store.ex:542). Every chunk AND the archive cascade commit
  # together in ONE `:immediate` transaction (see `delete_tasks/2`), so an
  # interrupted multi-id delete is all-or-nothing.
  @delete_chunk_size 500

  ## Public API — writes

  @doc """
  Inserts or replaces a task — port of the old `{:put_task, task}` handler
  (store.ex:479).

  Validates via `Codec.validate_task/1` first; when validation fails the error
  tuple is returned and NO row is written. On success the row is replaced
  atomically with ONE `on_conflict: :replace_all` insert inside a
  `:immediate` transaction (`row_for_task/1` supplies ALL columns, so
  `replace_all` is semantically identical to the old `INSERT OR REPLACE`) and
  `:ok` is returned.
  """
  @spec put_task(pid(), TaskInfo.t()) ::
          :ok | {:error, :missing_task_id} | {:error, :missing_task_status}
  def put_task(repo, %TaskInfo{} = task) do
    RepoScope.with_repo(repo, fn ->
      case Codec.validate_task(task) do
        :ok ->
          # `:immediate` takes the write lock up front, like every other write
          # of this repo (`default_transaction_mode: :immediate`).
          {:ok, :ok} =
            Repo.transaction(
              fn ->
                # Diagnostic at the ULTIMATE write chokepoint — only run when
                # writing :failed, and BEFORE the write so it observes the
                # PRE-write stored status (store.ex:487).
                if task.status == :failed, do: log_failed_write_if_transition(task)

                # `task.ref` is runtime-only; the old handler nulled it before
                # persistence. TaskRow has no ref field and to_task_info/1
                # always rebuilds ref: nil, so the nulling is inherent here.
                Repo.insert_all(TaskRow, [row_for_task(task)],
                  on_conflict: :replace_all,
                  conflict_target: :id
                )

                :ok
              end,
              mode: :immediate
            )

          :ok

        error ->
          error
      end
    end)
  end

  @doc """
  Deletes a single task by id — port of the old `{:delete_task, task_id}`
  handler (store.ex:531).

  Returns `:ok` whether or not the row existed (a DELETE of a missing id is a
  successful no-op statement, same as the old raw SQL).

  The task's per-agent archive rows (`task_agent_archives`) are deleted in the
  SAME `:immediate` transaction (`Archives.delete_by_task/2`), so the two
  statements can never be split by a crash or disk-full. The cascade is
  EXPLICIT — there is no foreign key — so a deleted task never leaks its
  archived conversations.
  """
  @spec delete_task(pid(), String.t()) :: :ok
  def delete_task(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      {:ok, :ok} =
        Repo.transaction(
          fn ->
            Repo.delete_all(from(t in TaskRow, where: t.id == ^task_id))
            Archives.delete_by_task(repo, task_id)
            :ok
          end,
          mode: :immediate
        )

      :ok
    end)
  end

  @doc """
  Deletes multiple tasks by id — port of the old `{:delete_tasks, task_ids}`
  handler (store.ex:539).

  The ids are batched into `WHERE id IN (...)` statements of at most 500 ids
  (under SQLite's 999-parameter limit). The WHOLE chunk loop and the archive
  cascade commit TOGETHER in ONE `:immediate` transaction — this deliberately
  replaces the old per-chunk commit semantics, so an interrupted multi-id
  delete can never leave a deleted task's archive behind. Returns `:ok`; an
  empty id list writes nothing.

  The named tasks' per-agent archive rows (`task_agent_archives`) are deleted
  too, chunked the same way (`Archives.delete_by_tasks/2`). The cascade is
  EXPLICIT — there is no foreign key.
  """
  @spec delete_tasks(pid(), [String.t()]) :: :ok
  def delete_tasks(repo, task_ids) do
    RepoScope.with_repo(repo, fn ->
      {:ok, :ok} =
        Repo.transaction(
          fn ->
            task_ids
            |> Enum.chunk_every(@delete_chunk_size)
            |> Enum.each(fn chunk ->
              Repo.delete_all(from(t in TaskRow, where: t.id in ^chunk))
            end)

            Archives.delete_by_tasks(repo, task_ids)

            :ok
          end,
          mode: :immediate
        )

      :ok
    end)
  end

  @doc """
  Deletes all task rows — port of the old `:clear_tasks` handler
  (store.ex:598). Returns `:ok`.

  EVERY per-agent archive row (`task_agent_archives`) is deleted in the SAME
  `:immediate` transaction (`Archives.delete_all/1`), so a cleared store
  holds no orphaned archive payloads and an interrupted clear rolls back
  whole. The cascade is EXPLICIT — there is no foreign key.
  """
  @spec clear_tasks(pid()) :: :ok
  def clear_tasks(repo) do
    RepoScope.with_repo(repo, fn ->
      {:ok, :ok} =
        Repo.transaction(
          fn ->
            Repo.delete_all(TaskRow)
            Archives.delete_all(repo)
            :ok
          end,
          mode: :immediate
        )

      :ok
    end)
  end

  ## Public API — reads

  @doc """
  Reads a single task by id — port of the old `{:get_task, task_id}` handler
  (store.ex:518).

  Returns the `%TaskInfo{}` (always with `ref: nil` — ref is runtime-only and
  never persisted) or `nil` when no row matches. A corrupt row raises out of
  the typed schema's loader, exactly like the old `Codec.decode_task/1` did.
  """
  @spec get_task(pid(), String.t()) :: TaskInfo.t() | nil
  def get_task(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      case Repo.one(from(t in TaskRow, where: t.id == ^task_id)) do
        nil -> nil
        row -> to_task_info(row)
      end
    end)
  end

  @doc """
  Paginated + filtered task select — port of the old
  `{:safe_select_paginated_tasks, opts}` handler (store.ex:587 +
  do_safe_select_paginated_tasks, store.ex:1000).

  `opts` keys: `:filters` (keyword — `status`, `project_path`,
  `review_status`, `search`), `:limit`, `:offset`. Returns
  `{tasks, total_count}` where `tasks` is ONE page of `%TaskInfo{}` (ORDER BY
  `started_at DESC`, LIMIT/OFFSET applied with the old `clamp_limit`/
  `clamp_offset` clamps + defaults 50/0) and `total_count` counts ALL rows
  matching the SAME filters — regardless of pagination or decodability
  (`COUNT(*)` counts rows, never decodes them, so a skipped bad row is still
  counted, exactly like the old raw SQL).

  Rows whose decode raises are SKIPPED with a `Logger.warning` (the shared
  `EvoGit.Store.Operations.Decoding` skip-and-log boundary, applied through
  `Codec.decode_raw_row/1`).

  The `ORDER BY started_at DESC` + `LIMIT`/`OFFSET` page is index-served for
  every supported filter: `idx_tasks_started_at` when no filter column is
  pinned, else the composite `(status, started_at)` /
  `(project_path, started_at)` indexes from
  `priv/repo/migrations/20260815000003_composite_indexes.exs` — the WHERE
  clauses below are written to keep those leading equality columns exactly as
  the indexes declare them (see that migration's moduledoc for the measured
  plans and for the filters that deliberately have no index).
  """
  @spec safe_select_paginated_tasks(pid(), keyword()) :: {[TaskInfo.t()], non_neg_integer()}
  def safe_select_paginated_tasks(repo, opts) when is_list(opts) do
    RepoScope.with_repo(repo, fn ->
      filters = Keyword.get(opts, :filters, [])
      limit = Filters.clamp_limit(Keyword.get(opts, :limit))
      offset = Filters.clamp_offset(Keyword.get(opts, :offset))

      base = from(t in TaskRowRaw)

      rows =
        base
        |> Filters.where_filters(filters)
        |> order_by([t], desc: t.started_at)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> Decoding.decode_skipping_bad("tasks", & &1.id, &Codec.decode_raw_row/1)

      total_count =
        base
        |> Filters.where_filters(filters)
        |> Repo.aggregate(:count)

      {rows, total_count}
    end)
  end

  @doc """
  Updates only the `lease_expires_at` column — port of the old
  `{:update_lease_expires_at, task_id, expires_at}` handler (store.ex:697).

  Deliberately does NOT bump `updated_at` — the 60s lease heartbeat must not
  mark tasks dirty. Returns `:ok` whether or not the row existed (an UPDATE of
  a missing id is a successful no-op statement, same as the old raw SQL).
  """
  @spec update_lease_expires_at(pid(), String.t(), integer() | nil) :: :ok
  def update_lease_expires_at(repo, task_id, expires_at) do
    RepoScope.with_repo(repo, fn ->
      Repo.update_all(
        from(t in TaskRow, where: t.id == ^task_id),
        set: [lease_expires_at: expires_at]
      )

      :ok
    end)
  end

  @doc """
  Renews the lease of SEVERAL tasks in ONE statement — the batched form of
  `update_lease_expires_at/3` for the registry's heartbeat tick.

  Deliberately does NOT bump `updated_at`, exactly like
  `update_lease_expires_at/3`: the 60 s heartbeat must never mark tasks dirty
  (nor touch an index row the dashboard's changed-since reads depend on).
  An empty id list is a NO-OP returning `:ok` — an empty `WHERE id IN ()` is
  never emitted. Like `update_lease_expires_at/3` an UPDATE of a missing id is
  a successful no-op statement, so the return value says nothing about which
  rows still existed.
  """
  @spec renew_leases(pid(), [String.t()], integer()) :: :ok
  def renew_leases(repo, task_ids, expires_at) when is_list(task_ids) do
    RepoScope.with_repo(repo, fn ->
      case task_ids do
        [] ->
          :ok

        ids ->
          Repo.update_all(
            from(t in TaskRow, where: t.id in ^ids),
            set: [lease_expires_at: expires_at]
          )

          :ok
      end
    end)
  end

  @doc """
  Updates only the specified columns of a task — port of the old
  `{:update_task_columns, task_id, columns}` handler (store.ex:713).

  `columns` is a keyword list of `{column_atom, value}`; each value is encoded
  through the private `encode_column_value/2` (the retired
  `EvoGit.Store.Queries.encode_column_value/2`, ported verbatim) — the EXACT
  per-column encoder the old body used (status atom → TEXT, DateTime →
  fixed-ms ISO, logs/result/opts/usage/error → JSON) — and the statement is
  issued through the RAW wire twin, whose plain field types pass the
  pre-encoded wire values to SQLite verbatim. Byte-identical SET clauses to
  the old raw SQL.

  WHY the raw twin and not the typed schema: Ecto's `update_all` can pin only
  SCALAR values into `set:` — pinning a keyword list (`opts:` is a keyword
  list by contract) is rejected ("keyword lists are only allowed at the top
  level of ..."). Pre-encoding through the Codec is the one path that covers
  every column of the old surface uniformly.

  EVERY call auto-prepends `{:updated_at, DateTime.utc_now()}` (store-internal
  bookkeeping) — use `update_lease_expires_at/3` for the one write that must
  not bump it. The old body had NO column whitelist: an arbitrary column name
  built `SET <col> = ?` verbatim. Under the typed schema only real fields can
  be addressed — an unknown column raises a descriptive `ArgumentError` at
  SET-build time, surfacing the caller bug exactly like the old raw SQL
  produced a SQLite error.
  """
  @spec update_task_columns(pid(), String.t(), keyword()) :: :ok
  def update_task_columns(repo, task_id, columns) when is_list(columns) do
    RepoScope.with_repo(repo, fn ->
      set =
        [{:updated_at, DateTime.utc_now()} | columns]
        |> encode_update_set()

      Repo.update_all(from(t in TaskRowRaw, where: t.id == ^task_id), set: set)

      :ok
    end)
  end

  @doc """
  Returns the task's stored status without ever collapsing "cannot decode" into
  "row absent":

    * `nil` — NO row with this id exists (the only "absent" answer),
    * a known status atom (`EvoGit.Store.Codec.known_statuses/0`),
    * `{:unknown, raw}` — the row EXISTS but its status text is outside the
      whitelist (or the cell is not text); the offending value is logged by
      `EvoGit.Store.Codec.decode_status/1`.

  The read selects `{id, status}` from the RAW wire twin (no typed-schema
  `load`, which maps an unrecognized value to `nil`), so liveness callers — the
  lease heartbeat above all — can never mistake a live row for a leaked one.
  `EvoGit.TaskRegistry.Lease` classifies the three shapes.
  """
  @spec get_task_status(pid(), String.t()) :: atom() | {:unknown, term()} | nil
  def get_task_status(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      case Repo.one(from(t in TaskRowRaw, select: {t.id, t.status}, where: t.id == ^task_id)) do
        # No row at all — the one genuinely "absent" answer.
        nil -> nil
        # A present row whose status cell is NULL is "exists, unreadable" —
        # never absent.
        {_id, raw} -> Codec.decode_status(raw) || {:unknown, raw}
      end
    end)
  end

  @doc """
  Returns the stored status of SEVERAL tasks in ONE statement — the batched
  form of `get_task_status/2` for the registry's lease sweep.

  The result is a MAP keyed by id holding the rows that EXIST:

    * a known status atom (`EvoGit.Store.Codec.known_statuses/0`),
    * `{:unknown, raw}` — the row exists but its status text is outside the
      whitelist (or the cell is not text), logged by
      `EvoGit.Store.Codec.decode_status/1`.

  An ABSENT id is simply not a key (callers read `Map.get(map, id, nil)`), so
  the three states "present known / present unreadable / absent" stay
  distinguishable — the same reason the single-row read uses the RAW wire twin
  instead of a typed load (which collapses an unrecognized status to `nil`).
  An empty id list is a NO-OP returning `%{}` (never `WHERE id IN ()`).
  """
  @spec select_task_statuses(pid(), [String.t()]) ::
          %{optional(String.t()) => atom() | {:unknown, term()}}
  def select_task_statuses(repo, ids) when is_list(ids) do
    RepoScope.with_repo(repo, fn ->
      case ids do
        [] ->
          %{}

        ids ->
          from(t in TaskRowRaw, select: {t.id, t.status}, where: t.id in ^ids)
          |> Repo.all()
          |> Map.new(fn {id, raw} -> {id, Codec.decode_status(raw) || {:unknown, raw}} end)
      end
    end)
  end

  @doc """
  Returns the narrow restart-classification projection for SEVERAL tasks in ONE
  statement: `%{id, status, type, opts, pause_kind, project_path}` per PRESENT
  row (in no particular order; absent ids contribute nothing).

  `status`/`type`/`pause_kind` decode through the same Codec decoders the typed
  schema's `Types.*` loaders use (`Codec.decode_atom/1` for the two atom-TEXT
  columns, `Codec.decode_pause_kind/1` for the pause fact), so an unrecognized
  value decodes to `nil` with the Codec's warning; `opts` decodes through
  `Codec.decode_opts/1` (nil when the column is NULL). Only these FIVE columns
  are read — no `result`/`logs`/`usage` blob, and no full-row decode.

  Rows are read through the RAW wire twin and decoded per row inside the shared
  skip-and-log boundary (`Decoding.decode_skipping_bad/4`): ONE corrupt `opts`
  cell is skipped with a warning instead of failing the whole batch. An empty
  id list is a NO-OP returning `[]`.
  """
  @spec select_tasks_restart_info(pid(), [String.t()]) :: [
          %{
            id: String.t(),
            status: atom() | nil,
            type: atom() | nil,
            opts: keyword() | nil,
            pause_kind: :clean | :dirty | nil,
            project_path: String.t() | nil
          }
        ]
  def select_tasks_restart_info(repo, ids) when is_list(ids) do
    RepoScope.with_repo(repo, fn ->
      case ids do
        [] ->
          []

        ids ->
          from(t in TaskRowRaw,
            select: %{
              id: t.id,
              status: t.status,
              type: t.type,
              opts: t.opts,
              pause_kind: t.pause_kind,
              project_path: t.project_path
            },
            where: t.id in ^ids
          )
          |> Repo.all()
          |> Decoding.decode_skipping_bad("tasks", & &1.id, &restart_info/1)
      end
    end)
  end

  @doc """
  Returns the narrow `%{status, opts, finished_at, lease_expires_at,
  project_path}` read (or `nil` when the row is absent) — port of the old
  `{:select_task_update_info, task_id}` handler (store.ex:754).

  Reads exactly the 5 columns the TaskRegistry `handle_update_status/6` path
  needs (stale-guard, preservation, project path) — no heavy JSON field
  (`logs`, `result`, `usage`) is decoded. `status` is the decoded atom (nil on
  unknown), `opts` the decoded keyword list (nil when the column is NULL),
  `finished_at` the decoded DateTime (nil on corrupt text),
  `lease_expires_at` the raw unix-ms INTEGER (`Types.UnixMs` loads the bare
  integer) and `project_path` the plain maintained scalar column.

  ONE typed query projects all five columns — the returned map carries EXACTLY
  `:status`, `:opts`, `:finished_at`, `:lease_expires_at` and
  `:project_path`, which `EvoGit.TaskRegistry` pattern-matches and its callers
  depend on. `:opts` stays in the projection (callers still read
  `opts[:path]`), while `:project_path` is the denormalized scalar that
  `row_for_task/1` backfills from `opts[:path]` on every write — so a
  status-transition caller can take the path without decoding `opts` at all.
  """
  @spec select_task_update_info(pid(), String.t()) ::
          %{
            status: atom() | nil,
            opts: keyword() | nil,
            finished_at: DateTime.t() | nil,
            lease_expires_at: integer() | nil,
            project_path: String.t() | nil
          }
          | nil
  def select_task_update_info(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      Repo.one(
        from(t in TaskRow,
          select: %{
            status: t.status,
            opts: t.opts,
            finished_at: t.finished_at,
            lease_expires_at: t.lease_expires_at,
            project_path: t.project_path
          },
          where: t.id == ^task_id
        )
      )
    end)
  end

  ## Private — narrow projections

  # ONE raw restart-classification row → the atom-keyed map callers consume.
  # The three atom-TEXT columns go through the SAME Codec decoders their
  # `Types.*` schema loaders delegate to (`AtomColumn.load` IS
  # `Codec.decode_atom/1`), and `opts` through `Codec.decode_opts/1` — the
  # strict decoder that RAISES on corrupt JSON, which is exactly the raise the
  # caller's `Decoding.decode_skipping_bad/4` boundary turns into a skip.
  defp restart_info(row) do
    %{
      id: row.id,
      status: Codec.decode_atom(row.status),
      type: Codec.decode_atom(row.type),
      opts: Codec.decode_opts(row.opts),
      pause_kind: Codec.decode_pause_kind(row.pause_kind),
      project_path: row.project_path
    }
  end

  ## Private — targeted-update SET building

  # Keyword list → the `set:` keyword Ecto expects, values pre-encoded through
  # encode_column_value/2 below — the exact per-column encoder the old raw-SQL
  # handler used (store.ex:713-729, formerly Queries.encode_column_value/2).
  # The statement then goes through the RAW twin, whose plain field types pass
  # the pre-encoded wire values to SQLite verbatim — byte-identical SET clauses
  # to the old raw SQL.
  defp encode_update_set(columns) do
    Enum.map(columns, fn {column, value} ->
      validate_update_column!(column)
      {column, encode_column_value(column, value)}
    end)
  end

  # The old raw SQL interpolated the column name verbatim (no whitelist), so
  # any column of the physical table could be targeted — and a typo produced a
  # SQLite "no such column" error. Under the schemas the equivalent guard
  # raises here with the unknown name, BEFORE any statement is issued. Every
  # one of the 19 fields is addressable — the full old surface.
  defp validate_update_column!(column) do
    unless column in TaskRow.__schema__(:fields) do
      raise ArgumentError,
            "update_task_columns/3: unknown task column #{inspect(column)} " <>
              "(expected one of #{inspect(TaskRow.__schema__(:fields))})"
    end
  end

  # The per-column wire encoder for targeted updates — a verbatim port of the
  # retired `EvoGit.Store.Queries.encode_column_value/2`, which delegated each
  # column family to the matching `Codec.encode_*/1`. The nil clause fires
  # FIRST (deliberate: e.g. a nil `:logs` stays SQL NULL, never
  # `Codec.encode_logs(nil)`'s "[]"); scalars pass through untouched.
  defp encode_column_value(_col, nil), do: nil

  defp encode_column_value(:status, value), do: Codec.encode_atom(value)
  defp encode_column_value(:type, value), do: Codec.encode_atom(value)
  defp encode_column_value(:review_status, value), do: Codec.encode_atom(value)
  defp encode_column_value(:started_at, value), do: Codec.encode_datetime(value)
  defp encode_column_value(:finished_at, value), do: Codec.encode_datetime(value)
  defp encode_column_value(:updated_at, value), do: Codec.encode_datetime(value)
  defp encode_column_value(:logs, value), do: Codec.encode_logs(value)
  defp encode_column_value(:result, value), do: Codec.encode_result(value)
  defp encode_column_value(:error, value), do: Codec.encode_error(value)
  defp encode_column_value(:usage, value), do: Codec.encode_usage(value)
  defp encode_column_value(:opts, value), do: Codec.encode_opts(value)
  defp encode_column_value(:session_mode, value), do: Codec.encode_session_mode(value)
  defp encode_column_value(:pause_kind, value), do: Codec.encode_pause_kind(value)
  defp encode_column_value(_col, value), do: value

  ## Private — row building (TaskInfo → insert map)

  # The FULL 20-key insert row. Every key is EXPLICIT (nils included), which is
  # exactly what lets `put_task/2` use `on_conflict: :replace_all` — the
  # replace NULLs every column the struct omits, like the old INSERT OR
  # REPLACE. Values are RUNTIME values; Ecto dumps each through the schema's
  # EvoGit.Store.Types.* field type, which delegates to the Codec wire format —
  # byte-identical to the old Codec.encode_task/1 positional list.
  defp row_for_task(%TaskInfo{} = task) do
    %{
      id: task.id,
      type: task.type,
      status: task.status,
      opts: task.opts,
      started_at: task.started_at,
      finished_at: task.finished_at,
      logs: task.logs,
      result: task.result,
      review_status: task.review_status,
      usage: task.usage,
      agent_count: task.agent_count,
      base_sha: task.base_sha,
      commit_sha: task.commit_sha,
      lease_expires_at: task.lease_expires_at,
      model_id: task.model_id,
      project_path: task.project_path || Codec.extract_project_path(task.opts),
      branch_name: task.branch_name || Codec.extract_branch_name(task.result),
      error: task.error,
      session_mode: Codec.task_session_mode(task),
      pause_kind: Codec.encode_pause_kind(task.pause_kind),
      updated_at: DateTime.utc_now()
    }
  end

  ## Private — row reading (TaskRow → TaskInfo)

  # The typed TaskRow already loads every column through the same Codec
  # decode the old Codec.decode_task/1 used (atoms, DateTimes, JSON columns);
  # this is the plain struct-to-struct translation. `status || :pending` and
  # `ref: nil` mirror decode_task's own fallbacks.
  defp to_task_info(%TaskRow{} = row) do
    %TaskInfo{
      id: row.id,
      type: row.type,
      status: row.status || :pending,
      opts: row.opts,
      ref: nil,
      started_at: row.started_at,
      finished_at: row.finished_at,
      logs: row.logs,
      result: row.result,
      error: row.error,
      review_status: row.review_status,
      usage: row.usage,
      agent_count: row.agent_count,
      base_sha: row.base_sha,
      commit_sha: row.commit_sha,
      lease_expires_at: row.lease_expires_at,
      model_id: row.model_id,
      project_path: row.project_path,
      branch_name: row.branch_name,
      session_mode: row.session_mode || Codec.default_session_mode(),
      pause_kind: row.pause_kind
    }
  end

  ## Private — failed-write diagnostic (ported from store.ex:1275-1317)

  # Logs a warning when a put_task is about to write :failed as a NEW
  # transition (previous stored status was not :failed). Runs INSIDE the put
  # transaction, before the replace-delete, so it observes the pre-write
  # status exactly like the old pre-INSERT SELECT did. The status is read
  # through the typed schema, whose Types.Status load applies the same
  # Codec.decode_atom/1 the old read_task_status/2 used.
  defp log_failed_write_if_transition(%TaskInfo{id: task_id, result: result}) do
    prev_status = Repo.one(from(t in TaskRow, select: t.status, where: t.id == ^task_id))

    if prev_status != :failed do
      {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)

      Logger.warning(
        "Store: FAILED_WRITE task_id=#{task_id} prev_status=#{inspect(prev_status)} " <>
          "result=#{inspect(result)}\n" <>
          "  stacktrace=\n#{format_stacktrace(trace)}"
      )
    end
  end

  defp format_stacktrace([]), do: "  (no stacktrace available)"

  defp format_stacktrace(trace) do
    Enum.map_join(trace, "\n", fn frame ->
      "    #{format_stacktrace_frame(frame)}"
    end)
  end

  defp format_stacktrace_frame({module, function, arity, location}) do
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

  defp format_stacktrace_frame(other), do: inspect(other)
end
