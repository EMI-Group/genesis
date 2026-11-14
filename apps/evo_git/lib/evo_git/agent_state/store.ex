defmodule EvoGit.AgentState.Store do
  @moduledoc """
  All Ecto/SQL operations for the durable agent-state database.

  No Ecto schemas exist for this database: every statement is positional
  `?`-placeholder SQL, and every COLUMN name comes from
  `EvoGit.AgentState.Record`'s constant lists — never from caller input.

  The declared column set IS the table's column set: `EvoGit.AgentState.Boot`
  runs every migration on this file BEFORE the first read or write, so the
  writer binds `Record.encode_fields/1`'s columns and the reader
  `Record.all_columns/0` directly — there is NO runtime schema probe.

  Every public function takes the target repo pid and runs inside
  `EvoGit.Store.RepoScope.with_repo/2`, so the process's dynamic-repo binding
  is always restored. Checkpoint writes for one run are transactional: the
  scalar row UPSERT and the chunk INSERT commit together.

  `checkpoint/4` returns:

    * `:ok` — persisted;
    * `:resync` — the caller's `:base_seq` did not match the stored message
      count (or the row is missing while `:base_seq > 0`): NOTHING was
      written and the caller must reload from the server;
    * `{:error, reason}` — the store failed (total, never raises).

  `load/3` is a documented TOTAL boundary: a corrupt payload, an inconsistent
  chunk/row count, a missing row and a dead store all answer an error tuple.
  """

  alias EvoGit.AgentState.Record
  alias EvoGit.Store.RepoScope

  @states "agent_states"
  @chunks "agent_state_chunks"

  ## Checkpoint

  @spec checkpoint(pid(), String.t(), integer(), map()) :: :ok | :resync | {:error, term()}
  def checkpoint(repo, task_id, agent_id, entry) do
    total(repo, fn ->
      case EvoGit.Repo.transaction(fn -> do_checkpoint(task_id, agent_id, entry) end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp do_checkpoint(task_id, agent_id, entry) do
    now = Record.now_iso8601()
    messages = Map.get(entry, :messages, [])
    fields = Map.get(entry, :fields, %{})

    case Map.get(entry, :kind) do
      :append ->
        append(task_id, agent_id, messages, fields, Map.get(entry, :base_seq), now)

      :rewrite ->
        rewrite(task_id, agent_id, messages, fields, now)
    end
  end

  defp append(task_id, agent_id, messages, fields, base_seq, now) do
    base = base_seq || 0

    case current_counts(task_id, agent_id) do
      {message_count, chunk_count} when message_count == base ->
        apply_append(task_id, agent_id, messages, fields, chunk_count, message_count, now)

      nil when base == 0 ->
        apply_append(task_id, agent_id, messages, fields, 0, 0, now)

      _other ->
        :resync
    end
  end

  defp apply_append(task_id, agent_id, messages, fields, chunk_count, message_count, now) do
    added = length(messages)

    {new_message_count, new_chunk_count} =
      if added > 0 do
        insert_chunk!(task_id, agent_id, chunk_count, messages, now)
        {message_count + added, chunk_count + 1}
      else
        {message_count, chunk_count}
      end

    upsert_state!(task_id, agent_id, fields, new_message_count, new_chunk_count, now)
    :ok
  end

  defp rewrite(task_id, agent_id, messages, fields, now) do
    run!(delete_chunks_sql(), [task_id, agent_id])

    count = length(messages)

    chunk_count =
      if count > 0 do
        insert_chunk!(task_id, agent_id, 0, messages, now)
        1
      else
        0
      end

    upsert_state!(task_id, agent_id, fields, count, chunk_count, now)
    :ok
  end

  defp current_counts(task_id, agent_id) do
    result =
      run!(
        "SELECT message_count, chunk_count FROM #{@states} WHERE task_id = ? AND agent_id = ?",
        [task_id, agent_id]
      )

    case result.rows do
      [[message_count, chunk_count]] -> {message_count, chunk_count}
      [] -> nil
    end
  end

  defp insert_chunk!(task_id, agent_id, seq, messages, now) do
    run!(
      "INSERT INTO #{@chunks} (task_id, agent_id, seq, message_count, payload, inserted_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?)",
      [task_id, agent_id, seq, length(messages), Record.encode_messages(messages), now]
    )
  end

  # The writer uses the DECLARED column set directly: `EvoGit.AgentState.Boot`
  # migrates this file before any read or write, so `Record`'s field specs ARE
  # the table's columns and there is nothing to probe or skip. A runtime
  # `PRAGMA table_info` per checkpoint would put a schema read on the hot path
  # for a state that cannot legitimately differ.
  defp upsert_state!(task_id, agent_id, fields, message_count, chunk_count, now) do
    columns = Record.encode_fields(fields)
    {sql, params} = upsert_sql(task_id, agent_id, columns, message_count, chunk_count, now)
    run!(sql, params)
  end

  # Only the SUPPLIED columns are updated on conflict, so a checkpoint never
  # clobbers an earlier value with a default. `created_at` is insert-only.
  defp upsert_sql(task_id, agent_id, columns, message_count, chunk_count, now) do
    tail_params = [message_count, chunk_count, now, now]

    if columns == [] do
      sql = """
      INSERT INTO #{@states} (task_id, agent_id, message_count, chunk_count, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(task_id, agent_id) DO UPDATE SET
        message_count = excluded.message_count,
        chunk_count = excluded.chunk_count,
        updated_at = excluded.updated_at
      """

      {sql, [task_id, agent_id | tail_params]}
    else
      names = Enum.map(columns, fn {column, _value} -> column end)
      values = Enum.map(columns, fn {_column, value} -> value end)
      placeholders = Enum.map_join(names, ", ", fn _column -> "?" end)
      updates = Enum.map_join(names, ", ", fn column -> "#{column} = excluded.#{column}" end)

      sql = """
      INSERT INTO #{@states} (task_id, agent_id, #{Enum.join(names, ", ")}, message_count, chunk_count, created_at, updated_at)
      VALUES (?, ?, #{placeholders}, ?, ?, ?, ?)
      ON CONFLICT(task_id, agent_id) DO UPDATE SET
        #{updates},
        message_count = excluded.message_count,
        chunk_count = excluded.chunk_count,
        updated_at = excluded.updated_at
      """

      {sql, [task_id, agent_id] ++ values ++ tail_params}
    end
  end

  ## Load

  @spec load(pid(), String.t(), integer()) ::
          {:ok, Record.t()} | {:error, :not_found | :corrupt_state | :store_unavailable}
  def load(repo, task_id, agent_id) do
    total(repo, fn -> do_load(task_id, agent_id) end)
  end

  defp do_load(task_id, agent_id) do
    with {:ok, row} <- fetch_state(task_id, agent_id),
         {:ok, chunks} <- fetch_chunks(task_id, agent_id),
         {:ok, messages} <- rebuild_messages(chunks),
         :ok <- validate_counts(row, chunks, messages) do
      {:ok,
       %Record{
         task_id: row["task_id"],
         agent_id: row["agent_id"],
         fields: Record.decode_fields(row),
         messages: messages,
         message_count: row["message_count"],
         chunk_count: row["chunk_count"],
         format_version: row["format_version"],
         inserted_at: Record.parse_datetime(row["created_at"]),
         updated_at: Record.parse_datetime(row["updated_at"]),
         completed_at: Record.parse_datetime(row["completed_at"])
       }}
    end
  end

  defp fetch_state(task_id, agent_id) do
    sql =
      "SELECT #{Enum.join(Record.all_columns(), ", ")} FROM #{@states} " <>
        "WHERE task_id = ? AND agent_id = ?"

    case query(sql, [task_id, agent_id]) do
      {:ok, %{columns: columns, rows: [values | _rest]}} ->
        {:ok, Map.new(Enum.zip(columns, values))}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp fetch_chunks(task_id, agent_id) do
    sql =
      "SELECT seq, message_count, payload, inserted_at FROM #{@chunks} " <>
        "WHERE task_id = ? AND agent_id = ? ORDER BY seq ASC"

    case query(sql, [task_id, agent_id]) do
      {:ok, %{columns: columns, rows: rows}} ->
        {:ok,
         Enum.map(rows, fn values ->
           row = Map.new(Enum.zip(columns, values))
           %{seq: row["seq"], message_count: row["message_count"], payload: row["payload"]}
         end)}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp rebuild_messages(chunks) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case Record.decode_messages(Map.fetch!(chunk, :payload)) do
        {:ok, messages} ->
          if length(messages) == chunk.message_count do
            {:cont, {:ok, [messages | acc]}}
          else
            {:halt, {:error, :corrupt_state}}
          end

        :error ->
          {:halt, {:error, :corrupt_state}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, reversed |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp validate_counts(row, chunks, messages) do
    stored_chunks = row["chunk_count"]
    stored_messages = row["message_count"]

    cond do
      not is_integer(stored_chunks) or not is_integer(stored_messages) ->
        {:error, :corrupt_state}

      length(chunks) != stored_chunks ->
        {:error, :corrupt_state}

      length(messages) != stored_messages ->
        {:error, :corrupt_state}

      Enum.sum(Enum.map(chunks, & &1.message_count)) != stored_messages ->
        {:error, :corrupt_state}

      true ->
        :ok
    end
  end

  ## Mark completed / delete

  @spec mark_completed(pid(), String.t(), integer()) :: :ok | {:error, term()}
  def mark_completed(repo, task_id, agent_id) do
    total(repo, fn ->
      now = Record.now_iso8601()

      case EvoGit.Repo.transaction(fn ->
             run!(
               "UPDATE #{@states} SET status = 'completed', completed_at = ?, updated_at = ? " <>
                 "WHERE task_id = ? AND agent_id = ?",
               [now, now, task_id, agent_id]
             )
           end) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec delete(pid(), String.t(), integer()) :: :ok | {:error, term()}
  def delete(repo, task_id, agent_id) do
    total(repo, fn ->
      delete_in_transaction(
        delete_chunks_sql(),
        [task_id, agent_id],
        "DELETE FROM #{@states} WHERE task_id = ? AND agent_id = ?",
        [task_id, agent_id]
      )
    end)
  end

  @spec delete_task(pid(), String.t()) :: :ok | {:error, term()}
  def delete_task(repo, task_id) do
    total(repo, fn ->
      delete_in_transaction(
        "DELETE FROM #{@chunks} WHERE task_id = ?",
        [task_id],
        "DELETE FROM #{@states} WHERE task_id = ?",
        [task_id]
      )
    end)
  end

  defp delete_chunks_sql do
    "DELETE FROM #{@chunks} WHERE task_id = ? AND agent_id = ?"
  end

  defp delete_in_transaction(chunks_sql, chunks_params, states_sql, states_params) do
    case EvoGit.Repo.transaction(fn ->
           run!(chunks_sql, chunks_params)
           run!(states_sql, states_params)
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Retention

  @doc """
  Deletes every run outside the retention window (see
  `EvoGit.AgentState.Retention.cutoffs/2`) plus its chunks.

  Returns `{:ok, deleted_count}`; total.
  """
  @spec prune(pid(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(repo, retention_days) do
    total(repo, fn ->
      %{completed_before: completed_before, stale_before: stale_before} =
        EvoGit.AgentState.Retention.cutoffs(retention_days)

      case EvoGit.Repo.transaction(fn ->
             do_prune(completed_before, stale_before)
           end) do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp do_prune(completed_before, stale_before) do
    # A recently-touched row is never pruned: both branches additionally
    # require `updated_at` inside the retention window.
    sql = """
    SELECT task_id, agent_id FROM #{@states}
    WHERE (
      (completed_at IS NOT NULL AND completed_at < ?)
      OR (completed_at IS NULL AND updated_at < ?)
    )
    AND updated_at < ?
    """

    result = run!(sql, [completed_before, stale_before, completed_before])
    keys = Enum.map(result.rows, fn [task_id, agent_id] -> {task_id, agent_id} end)

    Enum.each(keys, fn {task_id, agent_id} ->
      run!(delete_chunks_sql(), [task_id, agent_id])
      run!("DELETE FROM #{@states} WHERE task_id = ? AND agent_id = ?", [task_id, agent_id])
    end)

    length(keys)
  end

  ## SQL plumbing

  defp query(sql, params) do
    # The repo module ATOM only resolves for a NAMED instance; this store's
    # repo is UNNAMED, so the raw-SQL entry point must receive the CALLER's
    # current dynamic-repo pid (set by `RepoScope.with_repo/2`). Inside a
    # transaction the resolved adapter meta points at the same pool, so the
    # transaction's pinned connection is reused.
    Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
  end

  # Inside a transaction a failed statement must abort the whole checkpoint,
  # so the error travels through `Ecto.Repo.rollback/1` (a throw the
  # transaction turns into `{:error, reason}`).
  defp run!(sql, params) do
    case query(sql, params) do
      {:ok, result} -> result
      {:error, reason} -> EvoGit.Repo.rollback({:db_error, reason})
    end
  end

  # Justified rescue/catch: every public function here is a documented TOTAL
  # boundary (a checkpoint must never crash an agent run and a load must never
  # crash its reader). `RepoScope`/DBConnection raise or exit on a dead repo,
  # a lost connection or a malformed statement — none has a non-raising
  # variant, so the boundary is the only place to contain them.
  defp total(repo, fun) do
    RepoScope.with_repo(repo, fun)
  rescue
    _error -> {:error, :store_unavailable}
  catch
    _kind, _reason -> {:error, :store_unavailable}
  end
end
