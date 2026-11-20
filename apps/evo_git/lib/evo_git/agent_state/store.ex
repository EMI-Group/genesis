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

  ## Set-based maintenance (bounded write locks)

  Maintenance never walks rows one at a time: the retention `prune/2`, the bulk
  `delete_tasks/2` and the roster reads all use CONSTANT-shape statements over
  at most `@prune_batch_size` keys per statement (padded by repeating a key,
  which is a no-op inside `IN`) so SQLite reuses one prepared statement instead
  of re-preparing a new SQL text per row. `prune/2` commits ONE BATCH PER
  TRANSACTION, so the `BEGIN IMMEDIATE` write lock that every agent's
  checkpoint has to queue behind is released between batches instead of being
  held for the whole sweep.

  ## Lean roster projection

  `roster/2` and `roster_many/2` select `Record.roster_columns/0` — every
  scalar column except the two heavy JSON blobs (`pending_inputs`, `usage`)
  that no roster consumer reads. `redispatch` and `objective` are part of it:
  a resume rebuilds an `%AgentSpec{}` from them. The decoded `fields` map still
  carries every atom key, with `nil` for those two.

  ## Per-turn volatile write

  `update_volatile/4` rewrites ONLY the nine mutable per-turn scalars
  (`Record.volatile_columns/0`) through one constant-shape `UPDATE`, with
  REPLACE semantics: an absent key is written as `NULL` — so it is for callers
  that hold the FULL volatile snapshot, never for a partial patch — except for
  the four `NOT NULL` columns among them, which fall back to their own table
  default (`0` / `'running'`).
  """

  alias EvoGit.AgentState.Record
  alias EvoGit.Store.RepoScope

  @states "agent_states"
  @chunks "agent_state_chunks"

  # Batch width for every set-based statement below (prune sweep, bulk delete,
  # multi-task roster read). One statement per 400 keys caps a statement at
  # 800 parameters (+3 retention cutoffs for the prune SELECT), comfortably
  # under SQLite's legacy 999-variable limit, while retiring a post-downtime
  # backlog in a few hundred statements instead of thousands.
  @prune_batch_size 400

  # CONSTANT placeholder counts, so every batch produces the SAME SQL text and
  # SQLite reuses one prepared statement instead of re-preparing per batch. A
  # short batch is padded to the full width by repeating its LAST key
  # (`pad_keys/1`): a repeated key is a no-op inside `IN`.
  @id_placeholders Enum.map_join(1..@prune_batch_size, ", ", fn _index -> "?" end)
  @pair_placeholders Enum.map_join(1..@prune_batch_size, ", ", fn _index -> "(?,?)" end)

  # A recently-touched row is never pruned: both branches additionally require
  # `updated_at` inside the retention window. The batch is BOUNDED (`LIMIT`),
  # and `prune/2` re-runs it until a short batch comes back.
  @prune_select_sql """
  SELECT task_id, agent_id FROM #{@states}
  WHERE (
    (completed_at IS NOT NULL AND completed_at < ?)
    OR (completed_at IS NULL AND updated_at < ?)
  )
  AND updated_at < ?
  LIMIT #{@prune_batch_size}
  """

  # Row-value `IN (VALUES (?,?), …)`: the chunk table's primary key is
  # `(task_id, agent_id, seq)`, so a row-value IN serves it from the index.
  # Chunks go FIRST — the states DELETE must not orphan them.
  @prune_delete_chunks_sql "DELETE FROM #{@chunks} WHERE (task_id, agent_id) IN (VALUES #{@pair_placeholders})"
  @prune_delete_states_sql "DELETE FROM #{@states} WHERE (task_id, agent_id) IN (VALUES #{@pair_placeholders})"

  @delete_chunks_by_tasks_sql "DELETE FROM #{@chunks} WHERE task_id IN (#{@id_placeholders})"
  @delete_states_by_tasks_sql "DELETE FROM #{@states} WHERE task_id IN (#{@id_placeholders})"

  @roster_sql "SELECT #{Enum.join(Record.roster_columns(), ", ")} FROM #{@states} " <>
                "WHERE task_id = ? ORDER BY depth ASC, agent_id ASC"

  @roster_many_sql "SELECT #{Enum.join(Record.roster_columns(), ", ")} FROM #{@states} " <>
                     "WHERE task_id IN (#{@id_placeholders}) " <>
                     "ORDER BY task_id ASC, depth ASC, agent_id ASC"

  # TWO constant statements, no SELECT: the chunks DELETE carries its own
  # subquery, so its `agent_id` set is read in the SAME statement that removes
  # the chunk rows (a separate SELECT would add a round trip AND a
  # variable-shape IN list: the states rows must still exist when it runs).
  @delete_done_child_chunks_sql "DELETE FROM #{@chunks} WHERE task_id = ? AND agent_id IN " <>
                                  "(SELECT agent_id FROM #{@states} WHERE task_id = ? AND parent_id = ? " <>
                                  "AND status = 'done' AND spawn_turn = ?)"

  @delete_done_children_sql "DELETE FROM #{@states} WHERE task_id = ? AND parent_id = ? " <>
                              "AND status = 'done' AND spawn_turn = ?"

  # Built from `Record.volatile_columns/0` at compile time, so the column list
  # can never come from caller input and the statement shape never varies.
  # Four volatile columns are `NOT NULL` (each with a table DEFAULT): `turn`,
  # `total_tokens`, `compression_count` and `status`. A REPLACE write would
  # hand them a `NULL` and fail the constraint, so those binds go through
  # `COALESCE` to the column's OWN default — the value the table would give a
  # fresh row, never an invented one. Every nullable column (`phase`,
  # `current_commit`, `usage`, `pending_inputs`, `pending_tool_batch`) clears
  # to `NULL`, as the replace semantics require.
  @not_null_volatile_defaults %{
    "turn" => "0",
    "total_tokens" => "0",
    "compression_count" => "0",
    "status" => "'running'"
  }

  @update_volatile_assignments Enum.map_join(
                                 Record.volatile_columns(),
                                 ", ",
                                 fn column ->
                                   case Map.get(@not_null_volatile_defaults, column) do
                                     nil -> "#{column} = ?"
                                     default -> "#{column} = COALESCE(?, #{default})"
                                   end
                                 end
                               )

  @update_volatile_sql "UPDATE #{@states} SET #{@update_volatile_assignments}, " <>
                         "updated_at = ? WHERE task_id = ? AND agent_id = ?"

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

  ## Delete
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
  finished tasks sends ONE writer message instead of one per task. Every chunk
  of at most `@prune_batch_size` task ids costs TWO constant-shape statements
  (a `task_id IN (?, …)` delete per table) instead of two statements per task
  id, and the whole set commits in one transaction.

  Total: `:ok` on an empty list (no transaction is opened), a missing store or
  a store fault; a non-list is `:ok` and does nothing.
  """
  @spec delete_tasks(pid(), [String.t()]) :: :ok | {:error, term()}
  def delete_tasks(repo, task_ids) when is_list(task_ids) do
    # Duplicates would only repeat a key inside `IN`, so they are folded away
    # before the chunking; a non-binary id could never address a row.
    task_ids = task_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    case task_ids do
      [] ->
        :ok

      _ids ->
        total(repo, fn -> do_delete_tasks(task_ids) end)
    end
  end

  def delete_tasks(_repo, _task_ids), do: :ok

  defp do_delete_tasks(task_ids) do
    case EvoGit.Repo.transaction(fn ->
           task_ids
           |> Enum.chunk_every(@prune_batch_size)
           |> Enum.each(fn chunk ->
             params = pad_keys(chunk)
             run!(@delete_chunks_by_tasks_sql, params)
             run!(@delete_states_by_tasks_sql, params)
           end)
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
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

  ## Volatile per-turn write

  @doc """
  Rewrites the MUTABLE per-turn scalars of one run in ONE constant-shape
  `UPDATE` (`Record.volatile_columns/0`: `turn`, `usage`, `total_tokens`,
  `compression_count`, `current_commit`, `phase`, `pending_inputs`,
  `pending_tool_batch`, `status`), plus `updated_at`.

  REPLACE semantics — and this is load-bearing: a key the caller OMITTED is
  written as SQL `NULL`, NOT left alone. The caller must therefore supply the
  FULL volatile snapshot on every turn (`Record.encode_volatile_fields/1`
  never skips a column). The four `NOT NULL` columns among them (`turn`,
  `total_tokens`, `compression_count`, `status`) cannot hold a `NULL`, so an
  omitted key there falls back to the column's OWN table default (`0` /
  `'running'`) instead of failing the write. The statement's column list and
  placeholder count are fixed at compile time, so it is one reused prepared
  statement rather than the variable-width upsert `checkpoint/4` builds per
  write, and no identity/run fact is ever re-encoded.

  It never INSERTS: `{:error, :not_found}` when no row matched (a run's row
  comes into existence with its start snapshot, exactly like
  `put_pause_commit/4`). Total.
  """
  @spec update_volatile(pid(), String.t(), integer(), map()) :: :ok | {:error, term()}
  def update_volatile(repo, task_id, agent_id, fields) do
    total(repo, fn ->
      values =
        fields
        |> Record.encode_volatile_fields()
        |> Enum.map(fn {_column, value} -> value end)

      now = Record.now_iso8601()

      case query(@update_volatile_sql, values ++ [now, task_id, agent_id]) do
        {:ok, %{num_rows: 0}} -> {:error, :not_found}
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
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

  The projection is LEAN (`Record.roster_columns/0`): `pending_inputs` and
  `usage` are NOT selected, because no roster consumer reads them. Both stay
  `nil` inside each record's `fields`, so every atom key is still present and
  `redispatch`/`objective` (read by
  `EvoGit.Agent.Resume.RosterBatch.build_spec/2`) are untouched.

  Total: `{:error, reason}` when the read fails (a caller maps that to `[]`).
  """
  @spec roster(pid(), String.t()) :: {:ok, [Record.t()]} | {:error, term()}
  def roster(repo, task_id) do
    total(repo, fn ->
      case query(@roster_sql, [task_id]) do
        {:ok, %{columns: columns, rows: rows}} ->
          {:ok, Enum.map(rows, fn values -> values |> row_map(columns) |> to_record(nil) end)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  The `roster/2` skeleton for MANY task ids in ONE bounded pass — one
  constant-shape `SELECT` per `@prune_batch_size` ids, ordered
  `task_id ASC, depth ASC, agent_id ASC` (the ids are sorted before chunking,
  so the concatenated answer stays globally ordered).

  The projection is the same LEAN `Record.roster_columns/0` as `roster/2`, and
  every record carries `messages: nil`. Ids are filtered to binaries and
  deduplicated first (a repeat would only repeat an `IN` key), so an empty list
  answers `{:ok, []}` without touching the database; a non-list answers
  `{:error, :invalid_task_ids}`.

  Total: `{:error, reason}` when the read fails.
  """
  @spec roster_many(pid(), [String.t()]) :: {:ok, [Record.t()]} | {:error, term()}
  def roster_many(repo, task_ids) when is_list(task_ids) do
    task_ids = task_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

    case task_ids do
      [] -> {:ok, []}
      _ids -> total(repo, fn -> do_roster_many(task_ids) end)
    end
  end

  def roster_many(_repo, _task_ids), do: {:error, :invalid_task_ids}

  defp do_roster_many(task_ids) do
    task_ids
    |> Enum.chunk_every(@prune_batch_size)
    |> Enum.reduce_while([], fn chunk, acc ->
      case query(@roster_many_sql, pad_keys(chunk)) do
        {:ok, %{columns: columns, rows: rows}} ->
          records = Enum.map(rows, fn values -> values |> row_map(columns) |> to_record(nil) end)
          {:cont, [records | acc]}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      chunks -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
    end
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
  the stored value alone rather than clobbering it.

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
  caller with no batch can never delete a whole generation by accident. A `nil`
  `parent_id` matches nothing (plain `=`), as before.

  TWO statements of CONSTANT SQL and no `SELECT`: the chunk delete carries its
  own `agent_id` subquery (so the batch is read in the same statement that
  removes its chunks — the states rows must still exist when it runs), then the
  states delete. Both run in ONE transaction.
  """
  @spec delete_done_children(pid(), String.t(), integer() | nil, integer() | nil) ::
          :ok | {:error, term()}
  def delete_done_children(repo, task_id, parent_id, spawn_turn) do
    total(repo, fn ->
      if is_integer(spawn_turn) do
        case EvoGit.Repo.transaction(fn ->
               run!(@delete_done_child_chunks_sql, [task_id, task_id, parent_id, spawn_turn])
               run!(@delete_done_children_sql, [task_id, parent_id, spawn_turn])
             end) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end)
  end

  ## Retention

  @doc """
  Deletes every run outside the retention window (see
  `EvoGit.AgentState.Retention.cutoffs/2`) plus its chunks.

  Works in BOUNDED, SET-BASED batches: one `LIMIT @prune_batch_size` select
  plus one row-value `IN (VALUES …)` delete per table, with each batch its OWN
  transaction so the `BEGIN IMMEDIATE` write lock is released between batches
  instead of being held for a whole post-downtime sweep (which is what used to
  turn a concurrent `flush/1` into `{:error, :timeout}`). The loop stops on a
  short batch, or — should a batch select rows while its states DELETE reports
  zero affected rows — immediately, so it can never spin.

  Returns `{:ok, deleted_count}`; total. A mid-loop failure answers
  `{:error, reason}` with the earlier batches already committed — the sweep is
  idempotent, so the next call simply continues where this one stopped.
  """
  @spec prune(pid(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(repo, retention_days) do
    total(repo, fn ->
      %{completed_before: completed_before, stale_before: stale_before} =
        EvoGit.AgentState.Retention.cutoffs(retention_days)

      prune_batches(completed_before, stale_before, 0)
    end)
  end

  defp prune_batches(completed_before, stale_before, deleted_so_far) do
    case EvoGit.Repo.transaction(fn -> prune_batch(completed_before, stale_before) end) do
      {:ok, {selected, deleted}} ->
        cond do
          selected < @prune_batch_size -> {:ok, deleted_so_far + deleted}
          deleted == 0 -> {:ok, deleted_so_far}
          true -> prune_batches(completed_before, stale_before, deleted_so_far + deleted)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Answers `{selected_count, deleted_count}` for ONE bounded batch.
  defp prune_batch(completed_before, stale_before) do
    result = run!(@prune_select_sql, [completed_before, stale_before, completed_before])
    keys = Enum.map(result.rows, fn [task_id, agent_id] -> {task_id, agent_id} end)

    case keys do
      [] ->
        {0, 0}

      _keys ->
        params = pair_params(keys)
        run!(@prune_delete_chunks_sql, params)
        deleted = run!(@prune_delete_states_sql, params).num_rows
        {length(keys), deleted}
    end
  end

  ## SQL plumbing

  # Pads a NON-EMPTY key list to the constant batch width by repeating its LAST
  # key: a repeated key is a no-op inside `IN`, and the constant placeholder
  # count is what lets SQLite reuse the prepared statement instead of
  # re-preparing a new SQL text for every batch length.
  defp pad_keys(keys) do
    last = List.last(keys)
    keys ++ List.duplicate(last, @prune_batch_size - length(keys))
  end

  # The flattened parameter list for a row-value `(?,?)` delete over
  # `{task_id, agent_id}` pairs, padded like `pad_keys/1`.
  defp pair_params(keys) do
    keys
    |> pad_keys()
    |> Enum.flat_map(fn {task_id, agent_id} -> [task_id, agent_id] end)
  end

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
