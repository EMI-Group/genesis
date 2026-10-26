defmodule EvoGit.Store.Operations.Archives do
  @moduledoc """
  Ecto operations for the RELATIONAL per-agent archive
  (`task_agent_archives`).

  One row per `(task_id, agent_id)` — the archived agent's identity, spawn
  position, commits/refs, repo, settings and final `result`. The row-per-agent
  shape replaces the old single `tasks.archive_metadata` JSON array so a
  reader can:

    * page the task's agent roster WITHOUT the `result` blob
      (`list/3` with `include_results: false` — the column is never selected),
    * fetch ONE agent's full row on demand (`get/3`),
    * delete a task's archive explicitly (`delete_by_task/2`), and
    * let the task-delete cascade clear its rows (`delete_by_tasks/2`,
      `delete_all/1`).

  ## Conventions (shared with the sibling Operations modules)

  Every public function takes the repo pid FIRST and runs its whole body
  inside `EvoGit.Store.RepoScope.with_repo/2`; every statement goes through
  `EvoGit.Repo.*` + `Ecto.Query` against
  `EvoGit.Store.Schemas.TaskAgentArchiveRow`. There is NO try/rescue: a
  failing statement raises out of `EvoGit.Repo.*` and the facade turns a read
  failure into the read's documented degraded value (`offload/5`) and a write
  failure into `{:error, :disk_full}` or a crash (`write_call/2`).

  ## Entry maps are STRING-KEYED

  `list/3` and `get/3` return entry maps with STRING keys — the same shape the
  dashboard/RPC layers carry (native BEAM terms, so no re-encoding) and the
  same shape the producer writes back. The row → entry translation lives in
  ONE place (`entry_from_row/2` below); `put/2` accepts BOTH key spellings
  (atom-keyed producer maps and string-keyed maps straight out of `get/3`), so
  a read-modify-write round trip needs no reshaping.

  `"started_at"`/`"completed_at"` come back as the stored ISO-8601 STRINGS
  (never re-parsed); `"usage"`/`"llm_settings"`/`"agent_settings"` are plain
  maps and `"foreign_repos"` a plain list (see
  `EvoGit.Store.Types.ArchiveColumns`). `"repo_id"` is a repo ID STRING —
  `"primary"` or a foreign repo id — and round-trips as one (see
  `normalize_repo_id/1`).

  ## Write semantics

  `put/2` is an IDEMPOTENT upsert on the composite primary key
  (`ON CONFLICT (task_id, agent_id) DO UPDATE`) — re-putting an agent's
  archive REPLACES its row and never duplicates it, and every column is
  written from the supplied entry (missing values default: `depth` 0,
  `compression_count` 0, everything else NULL — a re-put therefore NULLs the
  columns the entry omits, matching the `INSERT OR REPLACE` semantics the
  composite key is there for).
  """

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskAgentArchiveRow

  # Page-size contract for the roster read: 100 rows by default, never fewer
  # than 1 and never more than 1000 (a whole task's agent tree is bounded by
  # the scheduler's max depth/width, so 1000 is a hard safety cap, not a paging
  # policy).
  @default_limit 100
  @max_limit 1000

  # Keep alive only ONE kind of detail on the roster read: the `result` column
  # is the heavy one, so it is opt-in.
  @default_include_results false

  # `DELETE ... WHERE task_id IN (...)` chunk size — 500 ids, safely under
  # SQLite's 999-host-parameter limit (same chunk size as
  # `Operations.Tasks.delete_tasks/2`).
  @delete_chunk_size 500

  # The table's physical columns in declaration order — the ONE field list used
  # by the write (full-row upsert), by the read projections (minus `result` when
  # results are not requested) and by the row → entry translation.
  @fields [
    :task_id,
    :agent_id,
    :parent_id,
    :depth,
    :agent_type,
    :context_node_path,
    :objective,
    :result,
    :base_commit,
    :final_commit,
    :branch_name,
    :archive_ref_start,
    :archive_ref_final,
    :repo_id,
    :repo_root,
    :repo_path,
    :usage,
    :llm_settings,
    :agent_settings,
    :foreign_repos,
    :compression_count,
    :started_at,
    :completed_at
  ]

  ## Public API — writes

  @doc """
  Inserts or REPLACES one archived agent — `:ok` on success.

  `entry` may be atom-keyed (the producer's shape) or string-keyed (the shape
  `get/3` returns); both spellings are accepted for every field. Missing keys
  default (`depth` 0, `compression_count` 0, the rest NULL). The composite
  primary key makes the write idempotent: the same `(task_id, agent_id)` pair
  is replaced, never duplicated.

  Returns `{:error, :missing_task_id}` / `{:error, :missing_agent_id}` for an
  entry that cannot identify its row (no statement is issued),
  `{:error, :invalid_repo_id}` for a `repo_id` that is neither a string nor an
  integer, and `{:error, :invalid_entry}` for a non-map.
  """
  @spec put(pid(), map()) :: :ok | {:error, atom()}
  def put(repo, entry) when is_map(entry) do
    with :ok <- validate_entry(entry) do
      RepoScope.with_repo(repo, fn ->
        Repo.insert_all(
          TaskAgentArchiveRow,
          [row_from_entry(entry)],
          on_conflict: :replace_all,
          conflict_target: [:task_id, :agent_id]
        )

        :ok
      end)
    end
  end

  def put(_repo, _entry), do: {:error, :invalid_entry}

  @doc """
  Deletes every archive row of ONE task — `:ok` (a delete of a task with no
  archive rows is a successful no-op statement).

  This is the explicit per-task delete behind
  `EvoGit.Store.delete_task_archives/2` and the per-id half of the task-delete
  cascade.
  """
  @spec delete_by_task(pid(), String.t()) :: :ok
  def delete_by_task(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      Repo.delete_all(from(r in TaskAgentArchiveRow, where: r.task_id == ^task_id))
      :ok
    end)
  end

  @doc """
  Deletes the archive rows of MULTIPLE tasks — `:ok`.

  Ids are batched into `WHERE task_id IN (...)` statements of at most 500 ids
  (under SQLite's 999-parameter limit), one committed statement per chunk —
  the batch half of the task-delete cascade (`delete_tasks/2`).
  """
  @spec delete_by_tasks(pid(), [String.t()]) :: :ok
  def delete_by_tasks(repo, task_ids) when is_list(task_ids) do
    RepoScope.with_repo(repo, fn ->
      task_ids
      |> Enum.chunk_every(@delete_chunk_size)
      |> Enum.each(fn chunk ->
        Repo.delete_all(from(r in TaskAgentArchiveRow, where: r.task_id in ^chunk))
      end)

      :ok
    end)
  end

  @doc """
  Deletes EVERY archive row — `:ok`. Backs the `clear_tasks/1` cascade, which
  wipes the whole store.
  """
  @spec delete_all(pid()) :: :ok
  def delete_all(repo) do
    RepoScope.with_repo(repo, fn ->
      Repo.delete_all(TaskAgentArchiveRow)
      :ok
    end)
  end

  ## Public API — reads

  @doc """
  Returns one page of a task's archived agents plus the task's TOTAL row
  count: `{:ok, %{entries: [entry], total: non_neg_integer}}`.

  Entries are ordered `depth ASC, agent_id ASC` (the spawn tree, root first).
  `opts`:

    * `:limit` — page size, default #{@default_limit}, clamped to 1..#{@max_limit}.
    * `:offset` — rows to skip, default 0, never negative.
    * `:include_results` — default `false`. When false the `result` column is
      NOT SELECTED, so the `"result"` key is ABSENT from every entry (not
      `nil`, not `""`); when true each entry carries it.

  `total` is `SELECT count(*)` over the SAME task — independent of
  `:limit`/`:offset`, so a caller can page without a second count query.
  """
  @spec list(pid(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], total: non_neg_integer()}}
  def list(repo, task_id, opts \\ []) when is_list(opts) do
    RepoScope.with_repo(repo, fn ->
      limit = clamp_limit(Keyword.get(opts, :limit))
      offset = clamp_offset(Keyword.get(opts, :offset))
      include_results = Keyword.get(opts, :include_results, @default_include_results) == true

      fields = if include_results, do: @fields, else: List.delete(@fields, :result)

      total =
        Repo.aggregate(from(r in TaskAgentArchiveRow, where: r.task_id == ^task_id), :count)

      entries =
        TaskAgentArchiveRow
        |> where([r], r.task_id == ^task_id)
        |> order_by([r], asc: r.depth, asc: r.agent_id)
        |> limit(^limit)
        |> offset(^offset)
        |> select([r], map(r, ^fields))
        |> Repo.all()
        |> Enum.map(&entry_from_row(&1, fields))

      {:ok, %{entries: entries, total: total}}
    end)
  end

  @doc """
  Returns ONE archived agent's full entry (including `"result"`), or
  `{:ok, nil}` when the task has no such agent.

  Backs the dashboard's lazy detail read: the roster page comes from `list/3`
  without results, the opened agent's conversation from here.
  """
  @spec get(pid(), String.t(), integer()) :: {:ok, map() | nil}
  def get(repo, task_id, agent_id) do
    RepoScope.with_repo(repo, fn ->
      TaskAgentArchiveRow
      |> where([r], r.task_id == ^task_id and r.agent_id == ^agent_id)
      |> select([r], map(r, ^@fields))
      |> Repo.one()
      |> case do
        nil -> {:ok, nil}
        row -> {:ok, entry_from_row(row, @fields)}
      end
    end)
  end

  ## Private — write helpers

  # Entry validation: the composite key must identify a row. A missing/empty
  # task id or a non-integer agent id would otherwise surface as an opaque
  # SQLite NOT NULL/PK violation inside the writer.
  defp validate_entry(entry) do
    cond do
      fetch(entry, :task_id) in [nil, ""] -> {:error, :missing_task_id}
      not is_integer(fetch(entry, :agent_id)) -> {:error, :missing_agent_id}
      not valid_repo_id?(fetch(entry, :repo_id)) -> {:error, :invalid_repo_id}
      true -> :ok
    end
  end

  # The FULL row for the upsert: every field present (so a re-put NULLs what
  # the entry omits — `INSERT OR REPLACE` parity) with the two NOT NULL
  # columns defaulting to 0.
  defp row_from_entry(entry) do
    row = Map.new(@fields, fn field -> {field, fetch(entry, field)} end)

    %{
      row
      | depth: row.depth || 0,
        compression_count: row.compression_count || 0,
        repo_id: normalize_repo_id(row.repo_id)
    }
  end

  # `repo_id` is a REPO ID STRING at runtime (`"primary"` or a foreign repo id —
  # `EvoGit.AgentSpec`/`AgentState`), so the column is TEXT and a string is
  # stored unchanged and read back unchanged. An integer-shaped input (an older
  # hand-written fixture's `0`) is STORED AS ITS DECIMAL TEXT rather than
  # rejected, so the column's on-disk format stays uniformly TEXT; anything
  # else is rejected up front by `validate_entry/1` instead of surfacing as an
  # opaque Ecto cast error inside the writer.
  defp normalize_repo_id(value) when is_binary(value), do: value
  defp normalize_repo_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_repo_id(nil), do: nil

  defp valid_repo_id?(value), do: is_nil(value) or is_binary(value) or is_integer(value)

  # Accepts BOTH key spellings: an atom key wins when the map has it (even with
  # a `nil` value), else the string spelling is used. This is what makes a
  # string-keyed `get/3` entry writable without reshaping.
  defp fetch(entry, field) do
    case Map.fetch(entry, field) do
      {:ok, value} -> value
      :error -> Map.get(entry, Atom.to_string(field))
    end
  end

  ## Private — read helpers

  # THE row → entry translation (used by list/3 and get/3). Entries are
  # STRING-KEYED and carry exactly the SELECTED fields, so a roster entry
  # simply has no "result" key. JSON columns arrive already decoded by
  # `EvoGit.Store.Types.ArchiveColumns.*`; timestamps arrive as the stored
  # ISO-8601 strings untouched.
  defp entry_from_row(row, fields) do
    Map.new(fields, fn field -> {Atom.to_string(field), Map.get(row, field)} end)
  end

  defp clamp_limit(nil), do: @default_limit

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  defp clamp_limit(_other), do: @default_limit

  defp clamp_offset(offset) when is_integer(offset) and offset > 0, do: offset

  defp clamp_offset(_other), do: 0
end
