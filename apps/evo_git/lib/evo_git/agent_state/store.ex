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

  `checkpoint_batch/4` takes a FOLD of those operations (see
  `EvoGit.AgentState.Entry`) for one run and commits ALL of them in ONE
  transaction, in order — so a coalesced queue costs one commit instead of one
  per checkpoint; `checkpoint/4` is its one-operation form.

  `checkpoint/4` and `checkpoint_batch/4` return:

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
    checkpoint_batch(repo, task_id, agent_id, [entry])
  end

  @doc """
  Persists a FOLD of checkpoint operations for ONE run in ONE transaction.

  `ops` is `EvoGit.AgentState.Entry.fold/1`'s output — ordered operations, each
  `%{kind: :append | :rewrite, base_seq:, messages:, fields:}` — executed
  SEQUENTIALLY inside a single `EvoGit.Repo.transaction/1`, so the whole fold
  is one commit and one fsync.

  Answers exactly like `checkpoint/4`: `:ok` (every operation committed),
  `:resync` (one operation's `:base_seq` did not match the stored message
  count — NOTHING of the fold is written, the transaction is rolled back), or
  `{:error, reason}`. An empty fold is a no-op `:ok` that opens no transaction.
  """
  @spec checkpoint_batch(pid(), String.t(), integer(), [map()]) ::
          :ok | :resync | {:error, term()}
  def checkpoint_batch(_repo, _task_id, _agent_id, []), do: :ok

  def checkpoint_batch(repo, task_id, agent_id, ops) when is_list(ops) do
    total(repo, fn ->
      case EvoGit.Repo.transaction(fn -> do_checkpoint_batch(task_id, agent_id, ops) end) do
        {:ok, result} -> result
        {:error, :resync} -> :resync
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def checkpoint_batch(_repo, _task_id, _agent_id, _ops), do: {:error, :invalid_operations}

  defp do_checkpoint_batch(task_id, agent_id, ops) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case do_checkpoint(task_id, agent_id, op) do
        :ok ->
          {:cont, :ok}

        # A continuity gap must leave NO half-applied fold behind: roll the
        # whole transaction back and let the caller resync from one snapshot.
        :resync ->
          EvoGit.Repo.rollback(:resync)
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
      {:ok, to_record(row, messages)}
    end
  end

  # ONE row → one `%Record{}`. The roster read passes `nil` messages: it never
  # touches the chunk table.
  defp to_record(row, messages) do
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
    }
  end

  defp fetch_state(task_id, agent_id) do
    sql =
      "SELECT #{Enum.join(Record.all_columns(), ", ")} FROM #{@states} " <>
        "WHERE task_id = ? AND agent_id = ?"

    case query(sql, [task_id, agent_id]) do
      {:ok, %{columns: columns, rows: [values | _rest]}} ->
        {:ok, row_map(values, columns)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp row_map(values, columns), do: Map.new(Enum.zip(columns, values))

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

  @doc """
  Legacy completion shape: marks the run `done` with no result and no commit.

  A thin alias of `mark_done/5` (the v2 completion records both), kept so the
  call sites that only know they finished keep working.
  """
  @spec mark_completed(pid(), String.t(), integer()) :: :ok | {:error, term()}
  def mark_completed(repo, task_id, agent_id) do
    mark_done(repo, task_id, agent_id, nil, nil)
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

  @doc """
  Deletes every run (and its chunks) of MANY tasks in ONE transaction.

  The bulk shape behind `EvoGit.AgentState.delete_tasks/2`: a registry clearing
  finished tasks sends ONE writer message instead of one per task. Total
  (`:ok` on an empty list, a missing store or a store fault).
  """
  @spec delete_tasks(pid(), [String.t()]) :: :ok | {:error, term()}
  def delete_tasks(repo, task_ids) when is_list(task_ids) do
    total(repo, fn ->
      case EvoGit.Repo.transaction(fn ->
             Enum.each(task_ids, fn task_id ->
               run!("DELETE FROM #{@chunks} WHERE task_id = ?", [task_id])
               run!("DELETE FROM #{@states} WHERE task_id = ?", [task_id])
             end)
           end) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def delete_tasks(_repo, _task_ids), do: :ok

  defp delete_in_transaction(chunks_sql, chunks_params, states_sql, states_params) do
    case EvoGit.Repo.transaction(fn ->
           run!(chunks_sql, chunks_params)
           run!(states_sql, states_params)
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Pause commit / resume roster

  @doc """
  Persists (or, with `nil`, clears) one run's `pause_commit` — the git commit
  sha of the worktree checkpoint that agent made when it paused.

  A SMALL SCALAR UPDATE that touches the `pause_commit` column ALONE: the
  message chunks, `message_count`, `chunk_count` and every other scalar are
  left exactly as they were, so this can never be mistaken for a conversation
  write by `checkpoint/4`'s append/rewrite continuity rule. It runs in the
  caller's transaction-free path and is serialized with the checkpoint writes
  by the server process that calls it.

  Answers `{:error, :not_found}` when no row exists for `(task_id, agent_id)` —
  a pause marker is never the reason a run's row comes into existence (that
  would fabricate an empty conversation).
  """
  @spec put_pause_commit(pid(), String.t(), integer(), String.t() | nil) ::
          :ok | {:error, term()}
  def put_pause_commit(repo, task_id, agent_id, sha) do
    total(repo, fn ->
      sql = "UPDATE #{@states} SET pause_commit = ? WHERE task_id = ? AND agent_id = ?"

      case query(sql, [sha, task_id, agent_id]) do
        {:ok, %{num_rows: 0}} -> {:error, :not_found}
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  One run's persisted `pause_commit`, or `nil`. Total.
  """
  @spec pause_commit(pid(), String.t(), integer()) :: String.t() | nil
  def pause_commit(repo, task_id, agent_id) do
    case total(repo, fn ->
           case query(
                  "SELECT pause_commit FROM #{@states} WHERE task_id = ? AND agent_id = ? LIMIT 1",
                  [task_id, agent_id]
                ) do
             {:ok, %{rows: [[value]]}} -> value
             _other -> nil
           end
         end) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  @doc """
  Whether ANY durable run row exists for `task_id` — a cheap
  `SELECT 1 … LIMIT 1` with no decode and no chunk read. Total (`false` on a
  missing store, an error or no rows).
  """
  @spec resumable?(pid(), String.t()) :: boolean()
  def resumable?(repo, task_id) do
    total(repo, fn ->
      case query("SELECT 1 FROM #{@states} WHERE task_id = ? LIMIT 1", [task_id]) do
        {:ok, %{rows: [_first | _rest]}} -> true
        _other -> false
      end
    end) == true
  end

  @doc """
  The `agent_id`s of `task_id` whose row has `parent_id IS NULL` (its root
  agents), ascending. Total (`[]` on a missing store, an error or no rows).
  """
  @spec root_agent_ids(pid(), String.t()) :: [integer()]
  def root_agent_ids(repo, task_id) do
    case total(repo, fn ->
           case query(
                  "SELECT agent_id FROM #{@states} " <>
                    "WHERE task_id = ? AND parent_id IS NULL ORDER BY agent_id ASC",
                  [task_id]
                ) do
             {:ok, %{rows: rows}} -> Enum.map(rows, fn [agent_id] -> agent_id end)
             _other -> []
           end
         end) do
      ids when is_list(ids) -> ids
      _other -> []
    end
  end

  ## Run facts: roster, identity, completion, done children

  @doc """
  The WHOLE agent tree of one task: every `agent_states` row of `task_id`, in
  ONE `SELECT` with NO chunk read.

  Ordered `depth ASC, agent_id ASC` so a parent always precedes its children
  and siblings keep their spawn order. The records carry `messages: nil` — this
  is the tree skeleton a resume decides from (identity, parentage, spawn
  position, git anchoring, `status`, `result`), and a caller that needs one
  run's transcript calls `load/3`.

  Total: `{:error, reason}` when the read fails (a caller maps that to `[]`).
  """
  @spec roster(pid(), String.t()) :: {:ok, [Record.t()]} | {:error, term()}
  def roster(repo, task_id) do
    total(repo, fn ->
      sql =
        "SELECT #{Enum.join(Record.all_columns(), ", ")} FROM #{@states} " <>
          "WHERE task_id = ? ORDER BY depth ASC, agent_id ASC"

      case query(sql, [task_id]) do
        {:ok, %{columns: columns, rows: rows}} ->
          {:ok, Enum.map(rows, fn values -> values |> row_map(columns) |> to_record(nil) end)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  The highest `agent_id` this database has ever held, or `0` when it is empty.

  The scheduler seeds its in-memory counter from this at boot, so an id it
  hands out can never collide with a durable row a restart must restore. Total
  (`0` on a missing store, an error or a non-integer aggregate).
  """
  @spec max_agent_id(pid()) :: non_neg_integer()
  def max_agent_id(repo) do
    case total(repo, fn ->
           case query("SELECT MAX(agent_id) FROM #{@states}", []) do
             {:ok, %{rows: [[value]]}} -> value
             _other -> 0
           end
         end) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  @doc """
  Marks one run DONE in ONE `UPDATE`: `status = 'done'`, `completed_at`,
  `updated_at`, the git `current_commit` (only when a binary is supplied) and
  the JSON `result` (only when supplied).

  A `nil` `result`/`current_commit` means "nothing new to record" and leaves
  the stored value alone rather than clobbering it — that is what keeps the
  legacy `mark_completed/3` (which carries neither) from erasing facts a
  richer completion call already wrote.

  Answers `{:error, :not_found}` when no row matched: a completion never
  fabricates a row out of nothing.
  """
  @spec mark_done(pid(), String.t(), integer(), map() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def mark_done(repo, task_id, agent_id, result, current_commit) do
    total(repo, fn ->
      now = Record.now_iso8601()
      {assignments, params} = done_assignments(result, current_commit, now)

      sql =
        "UPDATE #{@states} SET #{Enum.join(assignments, ", ")} " <>
          "WHERE task_id = ? AND agent_id = ?"

      case query(sql, params ++ [task_id, agent_id]) do
        {:ok, %{num_rows: 0}} -> {:error, :not_found}
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp done_assignments(result, current_commit, now) do
    assignments = ["status = 'done'", "completed_at = ?", "updated_at = ?"]
    params = [now, now]

    {assignments, params} =
      if is_binary(current_commit) do
        {assignments ++ ["current_commit = ?"], params ++ [current_commit]}
      else
        {assignments, params}
      end

    case encode_result(result) do
      nil -> {assignments, params}
      encoded -> {assignments ++ ["result = ?"], params ++ [encoded]}
    end
  end

  # Mirrors `Record`'s `:json` encoder: a non-encodable payload is stored in its
  # inspected form so the completion itself is never lost.
  defp encode_result(nil), do: nil

  defp encode_result(result) do
    case Jason.encode(result) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(result)
    end
  end

  @doc """
  Deletes the DONE children of ONE parent's tool batch, with their chunks.

  A parent's checkpoint that clears its `pending_tool_batch` consumes exactly
  the results of the children it spawned in that turn, so their rows stop being
  needed. The batch is identified by `(parent_id, spawn_turn)` and only rows
  with `status = 'done'` are matched: a still-`running` child, a child of
  ANOTHER turn, the parent itself and every row of another task survive.

  `spawn_turn` MUST be an integer — a `nil`/garbage turn is a no-op `:ok` so a
  caller with no batch can never delete a whole generation by accident. Both
  deletes run in ONE transaction.
  """
  @spec delete_done_children(pid(), String.t(), integer() | nil, integer() | nil) ::
          :ok | {:error, term()}
  def delete_done_children(repo, task_id, parent_id, spawn_turn) do
    total(repo, fn ->
      if is_integer(spawn_turn) do
        case EvoGit.Repo.transaction(fn ->
               ids = done_child_ids(task_id, parent_id, spawn_turn)
               delete_children!(ids, task_id)
             end) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end)
  end

  defp done_child_ids(task_id, parent_id, spawn_turn) do
    sql =
      "SELECT agent_id FROM #{@states} " <>
        "WHERE parent_id = ? AND task_id = ? AND status = 'done' AND spawn_turn = ?"

    case run!(sql, [parent_id, task_id, spawn_turn]) do
      %{rows: rows} -> Enum.map(rows, fn [agent_id] -> agent_id end)
    end
  end

  # Placeholders are one per id READ FROM THE DATABASE, so the statement shape
  # never comes from caller input.
  defp delete_children!([], _task_id), do: :ok

  defp delete_children!(agent_ids, task_id) do
    placeholders = Enum.map_join(agent_ids, ", ", fn _agent_id -> "?" end)
    params = [task_id | agent_ids]

    run!("DELETE FROM #{@chunks} WHERE task_id = ? AND agent_id IN (#{placeholders})", params)

    run!(
      "DELETE FROM #{@states} WHERE task_id = ? AND agent_id IN (#{placeholders})",
      params
    )

    :ok
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
