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
  | `select_all_tasks/1`            | store.ex:570 | `[EvoGit.TaskInfo.t()]`                                               |
  | `count_tasks/1`                 | store.ex:581 | `non_neg_integer()`                                                   |
  | `clear_tasks/1`                 | store.ex:598 | `:ok`                                                                 |
  | `safe_select_paginated_tasks/2` | store.ex:587 | `{[TaskInfo.t()], total_count}` — bad rows skipped+logged, still counted |
  | `update_lease_expires_at/3`     | store.ex:697 | `:ok` — does NOT bump `updated_at`                                    |
  | `update_task_columns/3`         | store.ex:713 | `:ok` — ALWAYS bumps `updated_at`                                     |
  | `get_task_status/2`             | store.ex:730 | `atom() \| nil`                                                       |
  | `select_task_logs/2`            | store.ex:738 | `[String.t()] \| nil`                                                 |
  | `select_task_update_info/2`     | store.ex:754 | `%{status, opts, finished_at, lease_expires_at} \| nil`               |

  ## Crash philosophy (inherited from the old `EvoGit.Store` moduledoc)

  NO try/rescue in this module except the ONE justified per-row skip-and-log
  decode boundary of `safe_select_paginated_tasks/2` (a verbatim port of the
  old `decode_skipping_bad/3` safe-select boundary — DB rows may contain
  corrupt/legacy data that fails to decode; skipping is the deliberate
  recovery boundary). A failed statement RAISES out of the `EvoGit.Repo.*`
  call and surfaces to the caller, exactly like the old handler's deliberate
  bad-match crash. The disk-full conversion boundary (`{:error, :disk_full}`)
  lives in the facade unit that will wrap these operations — NOT here.

  ## put_task replace semantics

  ONE `Repo.transaction(..., mode: :immediate)` performing a `delete_all` by
  id and then an `insert_all` of a FULL 20-key row (nils explicit; struct
  fields absent from the caller's struct default to nil). Re-putting a task
  therefore NULLs every column the new struct omits — parity with the old
  `INSERT OR REPLACE`. A changeset upsert (`on_conflict: :replace_all`) would
  keep stale values in omitted columns and is deliberately NOT used.

  Denormalizations are ported verbatim from `Codec.encode_task/1`:
  `project_path` ← `opts[:path]`, `branch_name` ← the `branch_name` of an
  `{:ok, data}` result (each only when the struct field itself is nil), and
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
  alias EvoGit.Store.Queries
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo

  # Batched `DELETE ... WHERE id IN (...)` chunk size — 500 ids, safely under
  # SQLite's 999-host-parameter limit (same chunk size as the old raw-SQL
  # handler, store.ex:542). Each chunk is its own statement/commit, preserving
  # the old all-or-nothing-per-chunk partial-crash semantics.
  @delete_chunk_size 500

  ## Public API — writes

  @doc """
  Inserts or replaces a task — port of the old `{:put_task, task}` handler
  (store.ex:479).

  Validates via `Codec.validate_task/1` first; when validation fails the error
  tuple is returned and NO row is written. On success the row is replaced
  atomically (delete + full-column insert inside ONE `:immediate`
  transaction) and `:ok` is returned.
  """
  @spec put_task(pid(), TaskInfo.t()) ::
          :ok | {:error, :missing_task_id} | {:error, :missing_task_status}
  def put_task(repo, %TaskInfo{} = task) do
    RepoScope.with_repo(repo, fn ->
      case Codec.validate_task(task) do
        :ok ->
          # Replace semantics: the explicit delete + FULL 20-key insert NULLs
          # every column the new struct omits (an upsert would not). The
          # `:immediate` mode takes the write lock up front, like every other
          # write of this repo (`default_transaction_mode: :immediate`).
          {:ok, :ok} =
            Repo.transaction(
              fn ->
                # Diagnostic at the ULTIMATE write chokepoint — only run when
                # writing :failed, so no SELECT on every put (store.ex:487).
                if task.status == :failed, do: log_failed_write_if_transition(task)

                # `task.ref` is runtime-only; the old handler nulled it before
                # persistence. TaskRow has no ref field and to_task_info/1
                # always rebuilds ref: nil, so the nulling is inherent here.
                Repo.delete_all(from(t in TaskRow, where: t.id == ^task.id))
                Repo.insert_all(TaskRow, [row_for_task(task)])
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
  """
  @spec delete_task(pid(), String.t()) :: :ok
  def delete_task(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      Repo.delete_all(from(t in TaskRow, where: t.id == ^task_id))
      :ok
    end)
  end

  @doc """
  Deletes multiple tasks by id — port of the old `{:delete_tasks, task_ids}`
  handler (store.ex:539).

  The ids are batched into `WHERE id IN (...)` statements of at most 500 ids
  (under SQLite's 999-parameter limit), one committed statement per chunk.
  Returns `:ok`; an empty id list writes nothing.
  """
  @spec delete_tasks(pid(), [String.t()]) :: :ok
  def delete_tasks(repo, task_ids) do
    RepoScope.with_repo(repo, fn ->
      task_ids
      |> Enum.chunk_every(@delete_chunk_size)
      |> Enum.each(fn chunk ->
        Repo.delete_all(from(t in TaskRow, where: t.id in ^chunk))
      end)

      :ok
    end)
  end

  @doc """
  Deletes all task rows — port of the old `:clear_tasks` handler
  (store.ex:598). Returns `:ok`.
  """
  @spec clear_tasks(pid()) :: :ok
  def clear_tasks(repo) do
    RepoScope.with_repo(repo, fn ->
      Repo.delete_all(TaskRow)
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
  Returns every task as a list of `%TaskInfo{}` — port of the old
  `:select_all_tasks` handler (store.ex:570). No skip-and-log boundary here
  (that belongs to the safe-select helpers): a corrupt row raises, exactly
  like the old `Enum.map(rows, &Codec.decode_task/1)` did.
  """
  @spec select_all_tasks(pid()) :: [TaskInfo.t()]
  def select_all_tasks(repo) do
    RepoScope.with_repo(repo, fn ->
      Repo.all(TaskRow)
      |> Enum.map(&to_task_info/1)
    end)
  end

  @doc """
  Returns the number of task rows — port of the old `:count_tasks` handler
  (store.ex:581).
  """
  @spec count_tasks(pid()) :: non_neg_integer()
  def count_tasks(repo) do
    RepoScope.with_repo(repo, fn ->
      Repo.aggregate(TaskRow, :count)
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

  Rows whose decode raises are SKIPPED with a `Logger.warning` (the old
  skip-and-log safe-select boundary, `decode_skipping_bad/3`).
  """
  @spec safe_select_paginated_tasks(pid(), keyword()) :: {[TaskInfo.t()], non_neg_integer()}
  def safe_select_paginated_tasks(repo, opts) when is_list(opts) do
    RepoScope.with_repo(repo, fn ->
      filters = Keyword.get(opts, :filters, [])
      limit = Queries.clamp_limit(Keyword.get(opts, :limit))
      offset = Queries.clamp_offset(Keyword.get(opts, :offset))

      base = from(t in TaskRowRaw)

      rows =
        base
        |> where_filters(filters)
        |> order_by([t], desc: t.started_at)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> decode_tasks_skipping_bad()

      total_count =
        base
        |> where_filters(filters)
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
  Updates only the specified columns of a task — port of the old
  `{:update_task_columns, task_id, columns}` handler (store.ex:713).

  `columns` is a keyword list of `{column_atom, value}`; each value is encoded
  through `Queries.encode_column_value/2` — the EXACT per-column encoder the
  old body used (status atom → TEXT, DateTime → fixed-ms ISO, logs/result/
  opts/usage/error → JSON) — and the statement is issued through the RAW
  wire twin, whose plain field types pass the pre-encoded wire values to
  SQLite verbatim. Byte-identical SET clauses to the old raw SQL.

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
  Returns only the decoded status atom (or `nil` for a missing row) — port of
  the old `{:get_task_status, task_id}` handler (store.ex:730).

  The status column is read through the typed schema, whose
  `EvoGit.Store.Types.Status` load applies the same `Codec.decode_atom/1` the
  old `read_task_status/2` used (known atom, or `nil` on unknown values).
  """
  @spec get_task_status(pid(), String.t()) :: atom() | nil
  def get_task_status(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      Repo.one(from(t in TaskRow, select: t.status, where: t.id == ^task_id))
    end)
  end

  @doc """
  Returns only the decoded logs list (or `nil` when the row is absent) — port
  of the old `{:select_task_logs, task_id}` handler (store.ex:738).

  Reads a single column, no full-row decode. The lenient
  `Codec.decode_logs/1` semantics (nil/undecodable → `[]`) come from the
  typed schema's `EvoGit.Store.Types.LogsJson` load — same decoder the old
  handler called directly.
  """
  @spec select_task_logs(pid(), String.t()) :: [String.t()] | nil
  def select_task_logs(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      case Repo.one(from(t in TaskRow, select: t.logs, where: t.id == ^task_id)) do
        nil -> nil
        logs -> logs
      end
    end)
  end

  @doc """
  Returns the narrow `%{status, opts, finished_at, lease_expires_at}` read (or
  `nil` when the row is absent) — port of the old `{:select_task_update_info,
  task_id}` handler (store.ex:754).

  Reads exactly the 4 columns the TaskRegistry `handle_update_status/6` path
  needs (stale-guard, preservation, project_path) — no heavy JSON field
  (`logs`, `result`, `usage`, `archive_metadata`) is decoded. `status` is the
  decoded atom (nil on unknown), `opts` the decoded keyword list (nil when the
  column is NULL), `finished_at` the decoded DateTime (nil on corrupt text),
  `lease_expires_at` the raw unix-ms INTEGER.
  """
  @spec select_task_update_info(pid(), String.t()) :: %{
          status: atom() | nil,
          opts: keyword() | nil,
          finished_at: DateTime.t() | nil,
          lease_expires_at: integer() | nil
        }
  def select_task_update_info(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      case Repo.one(
             from(t in TaskRow,
               select: %{status: t.status, opts: t.opts, finished_at: t.finished_at},
               where: t.id == ^task_id
             )
           ) do
        nil ->
          nil

        %{status: status, opts: opts, finished_at: finished_at} ->
          # lease_expires_at is read through the RAW twin so it comes back as
          # the bare INTEGER the old single-statement SELECT returned (it is
          # an integer under the typed schema too, but the raw read keeps the
          # two-column projection in ONE code path — same schema the old SQL
          # read from, no type casting at all).
          lease =
            Repo.one(from(t in TaskRowRaw, select: t.lease_expires_at, where: t.id == ^task_id))

          %{status: status, opts: opts, finished_at: finished_at, lease_expires_at: lease}
      end
    end)
  end

  ## Private — pagination filters (port of Queries.build_where/1 semantics)

  # Applies the raw store's build_where/1 filter set, clause for clause:
  #
  #   * `:status` (default "all") — exact TEXT equality on the stored status
  #     string (dashboard filters pass the string spelling; "all" = no clause).
  #   * `:project_path` (default "all") — exact TEXT equality.
  #   * `:review_status` (default "all") — "pending" is the old COMPOSITE:
  #     `status = 'completed' AND review_status IS NULL AND branch_name IS NOT
  #     NULL` (completed tasks with no review whose result carried a
  #     branch_name → awaiting review); any other value is exact TEXT equality.
  #   * `:search` (nil/"" = no clause) — a 4-column OR-LIKE over id, opts,
  #     project_path, result using the old escaped pattern
  #     `%#{escape_like(search)}%` with `ESCAPE '\'`. This is the ONE
  #     `fragment` in the module — LIKE-escape cannot be expressed in
  #     Ecto.Query syntax.
  defp where_filters(query, filters) do
    query
    |> where_status_filter(Keyword.get(filters, :status, "all"))
    |> where_path_filter(Keyword.get(filters, :project_path, "all"))
    |> where_review_status_filter(Keyword.get(filters, :review_status, "all"))
    |> where_search_filter(Keyword.get(filters, :search))
  end

  defp where_status_filter(query, "all"), do: query
  defp where_status_filter(query, status), do: where(query, [t], t.status == ^status)

  defp where_path_filter(query, "all"), do: query
  defp where_path_filter(query, path), do: where(query, [t], t.project_path == ^path)

  defp where_review_status_filter(query, "all"), do: query

  defp where_review_status_filter(query, "pending") do
    # The composite "pending review" predicate — ported verbatim from the old
    # build_where/1 arm (literal 'completed' pushdown, exactly as written).
    where(
      query,
      [t],
      t.status == "completed" and is_nil(t.review_status) and
        not is_nil(t.branch_name)
    )
  end

  defp where_review_status_filter(query, review_status) do
    where(query, [t], t.review_status == ^review_status)
  end

  defp where_search_filter(query, search) when search in [nil, ""], do: query

  defp where_search_filter(query, search) do
    pat = "%#{Queries.escape_like(search)}%"

    # A single literal fragment — the 4-column OR-LIKE with the old `\` escape
    # char. The escape char must be pinned as a PARAMETER, not written as the
    # SQL literal `'\'`: the adapter doubles backslashes inside SQL string
    # literals, which SQLite then rejects ("ESCAPE expression must be a single
    # character"). The pattern itself is the other interpolated (^) value.
    where(
      query,
      [t],
      fragment(
        "(? LIKE ? ESCAPE ? OR ? LIKE ? ESCAPE ? OR ? LIKE ? ESCAPE ? OR ? LIKE ? ESCAPE ?)",
        t.id,
        ^pat,
        ^"\\",
        t.opts,
        ^pat,
        ^"\\",
        t.project_path,
        ^pat,
        ^"\\",
        t.result,
        ^pat,
        ^"\\"
      )
    )
  end

  ## Private — pagination decode (skip-and-log safe-select boundary)

  # Decodes raw rows one at a time through the Codec (the decode oracle),
  # SKIPPING (with a warning) any row that raises — a verbatim port of the old
  # decode_skipping_bad/3 boundary. Loading happens through the RAW wire twin
  # so Ecto's loader never raises before this per-row rescue can run.
  defp decode_tasks_skipping_bad(rows) do
    Enum.flat_map(rows, fn %TaskRowRaw{} = row ->
      # Justified try/rescue — safe-select boundary (mirrors the raw store's
      # store.ex:1123): DB rows may contain corrupt or legacy data that fails
      # to decode; the Codec decoders raise by design and skipping is the
      # deliberate recovery boundary.
      try do
        [decode_raw_task(row)]
      rescue
        e ->
          Logger.warning(
            "Store: skipping undecodable row in tasks (id: #{inspect(row.id)}): " <>
              Exception.message(e)
          )

          []
      end
    end)
  end

  # %TaskRowRaw{} → %TaskInfo{} via the Codec's positional-list decoder — the
  # same 19-element `Codec.task_columns/0` order (deliberately WITHOUT
  # `updated_at`, which the old SELECT over those columns never fetched
  # either). Identical to the existing get_task/to_task_info result: decode_task
  # itself applies the `status || :pending` and `ref: nil` fallbacks.
  defp decode_raw_task(%TaskRowRaw{} = row) do
    Codec.decode_task([
      row.id,
      row.type,
      row.status,
      row.opts,
      row.started_at,
      row.finished_at,
      row.logs,
      row.result,
      row.review_status,
      row.usage,
      row.agent_count,
      row.base_sha,
      row.commit_sha,
      row.archive_metadata,
      row.lease_expires_at,
      row.model_id,
      row.project_path,
      row.branch_name,
      row.error
    ])
  end

  ## Private — targeted-update SET building

  # Keyword list → the `set:` keyword Ecto expects, values pre-encoded through
  # Queries.encode_column_value/2 — the exact per-column encoder the old
  # handler body used (store.ex:713-729). The statement then goes through the
  # RAW twin, whose plain field types pass the pre-encoded wire values to
  # SQLite verbatim — byte-identical SET clauses to the old raw SQL.
  defp encode_update_set(columns) do
    Enum.map(columns, fn {column, value} ->
      validate_update_column!(column)
      {column, Queries.encode_column_value(column, value)}
    end)
  end

  # The old raw SQL interpolated the column name verbatim (no whitelist), so
  # any column of the physical table could be targeted — and a typo produced a
  # SQLite "no such column" error. Under the schemas the equivalent guard
  # raises here with the unknown name, BEFORE any statement is issued. Every
  # one of the 20 fields is addressable — the full old surface.
  defp validate_update_column!(column) do
    unless column in TaskRow.__schema__(:fields) do
      raise ArgumentError,
            "update_task_columns/3: unknown task column #{inspect(column)} " <>
              "(expected one of #{inspect(TaskRow.__schema__(:fields))})"
    end
  end

  ## Private — row building (TaskInfo → insert map)

  # The FULL 20-key insert row. Every key is EXPLICIT (nils included) so the
  # delete+insert replace NULLs columns the struct omits. Values are RUNTIME
  # values; Ecto dumps each through the schema's EvoGit.Store.Types.* field
  # type, which delegates to the Codec wire format — byte-identical to the old
  # Codec.encode_task/1 positional list.
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
      archive_metadata: task.archive_metadata,
      lease_expires_at: task.lease_expires_at,
      model_id: task.model_id,
      project_path: task.project_path || project_path_from_opts(task.opts),
      branch_name: task.branch_name || branch_name_from_result(task.result),
      error: task.error,
      updated_at: DateTime.utc_now()
    }
  end

  # Mirrors the Codec's private extract_project_path/1 (codec.ex:114-120): the
  # denormalization feeding the project_path column from opts[:path].
  defp project_path_from_opts(nil), do: nil

  defp project_path_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :path)

  # Mirrors the Codec's private extract_branch_name/1 (codec.ex:122-131): the
  # denormalization feeding the branch_name column from an {:ok, data} result.
  defp branch_name_from_result(nil), do: nil

  defp branch_name_from_result({:ok, data}) when is_map(data),
    do: Map.get(data, :branch_name)

  defp branch_name_from_result(_other), do: nil

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
      archive_metadata: row.archive_metadata,
      lease_expires_at: row.lease_expires_at,
      model_id: row.model_id,
      project_path: row.project_path,
      branch_name: row.branch_name
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
