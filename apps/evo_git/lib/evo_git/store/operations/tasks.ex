defmodule EvoGit.Store.Operations.Tasks do
  @moduledoc """
  Ecto TASK WRITE/CORE operations for the EvoGit task store (migration wave R2a).

  Ports the task write/core handler bodies of the raw-SQL `EvoGit.Store`
  GenServer (store.ex:479-605) onto `EvoGit.Repo` + the typed
  `EvoGit.Store.Schemas.TaskRow` schema. Every public function takes the repo
  pid FIRST and binds it with `EvoGit.Store.RepoScope.with_repo/2`; every
  statement goes through `EvoGit.Repo.*` and `Ecto.Query` — no `?N` SQL
  strings. The wire format is owned by `EvoGit.Store.Types.*` (thin delegation
  to `EvoGit.Store.Codec`, the oracle), so the stored bytes are identical to
  the raw-SQL store's.

  ## Return shapes (exactly the old handlers' — zero consumer changes)

  | function             | old handler  | returns                                                               |
  |----------------------|--------------|----------------------------------------------------------------------|
  | `put_task/2`         | store.ex:479 | `:ok \| {:error, :missing_task_id} \| {:error, :missing_task_status}` |
  | `get_task/2`         | store.ex:518 | `%EvoGit.TaskInfo{} \| nil`                                           |
  | `delete_task/2`      | store.ex:531 | `:ok`                                                                 |
  | `delete_tasks/2`     | store.ex:539 | `:ok`                                                                 |
  | `select_all_tasks/1` | store.ex:570 | `[EvoGit.TaskInfo.t()]`                                               |
  | `count_tasks/1`      | store.ex:581 | `non_neg_integer()`                                                   |
  | `clear_tasks/1`      | store.ex:598 | `:ok`                                                                 |

  ## Crash philosophy (inherited from the old `EvoGit.Store` moduledoc)

  NO try/rescue in this module. A failed statement RAISES out of the
  `EvoGit.Repo.*` call and surfaces to the caller, exactly like the old
  handler's deliberate bad-match crash. The disk-full conversion boundary
  (`{:error, :disk_full}`) lives in the facade unit that will wrap these
  operations — NOT here.

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

  R2b APPENDS the pagination/update/status/log operations to this module; the
  private helpers here (`row_for_task/1`, `to_task_info/1`) are the shared
  row ↔ struct translation surface for them.
  """

  import Ecto.Query

  require Logger

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow
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
