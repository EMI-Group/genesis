defmodule EvoGit.Repo.Migrations.MoveArchivesToTable do
  @moduledoc """
  Moves the per-agent archive from the single `tasks.archive_metadata` JSON
  array into the relational `task_agent_archives` table — ONE ROW PER ARCHIVED
  AGENT — then DROPS the column.

  ## Why

  `tasks.archive_metadata` held a JSON array of every archived agent of a
  task. Reading ONE agent's archived conversation meant decoding the WHOLE
  task's archive, so the dashboard's agent-detail panel paid for every agent
  of the task on every open. The archive is now a normal relational table
  (created by `20260815000007`, which runs immediately before this one) and
  nothing in the runtime reads or writes the column any more — it is dead
  weight on every row, so it is removed from the physical schema here.

  ## Per task row with a non-empty `archive_metadata`

    1. decode the JSON array LENIENTLY (`Jason.decode/1`); a corrupt value, or
       a value that is not a list, is logged with `Logger.warning` naming the
       task id and SKIPPED — one unreadable archive never wedges an upgrade;
    2. `INSERT OR REPLACE` exactly one `task_agent_archives` row per record,
       mapping every record key onto its column (`task_id` comes from the task
       row, `agent_id` from the record; `depth`/`compression_count` default to
       0; `usage`/`llm_settings`/`agent_settings`/`foreign_repos` are re-encoded
       with `Jason.encode!` — plain JSON, no compression, no `"z1:"` prefix,
       SQL NULL for a missing value); every other column is copied VERBATIM, in
       particular `repo_id`, which is a repo ID STRING (`"primary"` or a foreign
       repo id) and therefore a TEXT column — it is never cast to an integer;
    3. strip `data.archive_records` from `result` — but ONLY when that key is
       present (it was a verbatim DUPLICATE of this column). The result JSON is
       decoded/re-encoded for that one case; a result without the key is left
       COMPLETELY untouched, byte for byte;
    4. set `archive_metadata = NULL` for the migrated task.

  `updated_at` (and every other column) is NEVER touched: moving the archive
  is not a task mutation.

  ## Then the column goes

  `ALTER TABLE tasks DROP COLUMN archive_metadata` runs at the very end, and
  only when the column still exists (`PRAGMA table_info(tasks)` probe) — SQLite
  has supported `DROP COLUMN` since 3.35, and no index or constraint references
  this column, so the operation is an O(1) schema-header edit (no table
  rebuild).

  ## Idempotent / resumable

  Every step converges on a re-run, which is what makes a PARTIAL failure safe:

    * the `INSERT OR REPLACE` upsert on the composite `(task_id, agent_id)`
      primary key can never duplicate an agent (it replaces it);
    * each task only clears its own `archive_metadata` after its records are in
      the table, and an already-NULL archive is not a candidate;
    * the `DROP COLUMN` is guarded by a column-existence probe, so a boot that
      crashed between the fan-out and the drop (or one re-running after the
      column is already gone) simply finishes;
    * a still-corrupt archive is skipped again (and logged again), leaving the
      migration converging without it.

  ## Conventions

  Statements run via `repo().query/3` + `repo().query!/3` (the sibling
  migrations' convention), NOT `Ecto.Migration.execute/1`, whose string
  commands are queued until `flush/0` — the fan-out, the NULLing, the column
  probe and the final DDL all have to observe each other in body order.
  Values are read ONE ROW AT A TIME (an archived agent's `result` can be tens
  of MiB) with `timeout: 600_000` per statement. Defined as `up/0` (no
  `down/0`): the column is gone and the data now lives in the table.
  """

  use Ecto.Migration

  require Logger

  @column "archive_metadata"
  @archive_table "task_agent_archives"

  # The destination columns, in the table's declaration order (see
  # `20260815000007_create_task_agent_archives`). `task_id` comes from the
  # task row, every other value from the record map of the same name.
  @archive_columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective
                      result base_commit final_commit branch_name archive_ref_start
                      archive_ref_final repo_id repo_root repo_path usage llm_settings
                      agent_settings foreign_repos compression_count started_at completed_at)

  @statement_timeout 600_000

  def up do
    if column_exists?(@column) do
      fan_out()
      drop_column()
    end

    :ok
  end

  ## Fan-out

  defp fan_out do
    {tasks, records, skipped} =
      task_ids_with_archive()
      |> Enum.reduce({0, 0, []}, fn task_id, {tasks, records, skipped} ->
        case migrate_task(task_id) do
          {:ok, migrated} -> {tasks + 1, records + migrated, skipped}
          :error -> {tasks, records, [task_id | skipped]}
        end
      end)

    Logger.info(
      "#{inspect(__MODULE__)}: #{tasks} task(s) moved to #{@archive_table} " <>
        "(#{records} agent record(s)); #{length(skipped)} task(s) skipped"
    )

    assert_no_archives_left!(skipped)
  end

  # ONE task at a time: fetch its result + archive, fan the archive out into
  # `task_agent_archives`, strip the duplicated archive from `result`, and only
  # then null the column. A failed step leaves the task's archive in place, so
  # a re-run picks it up again.
  defp migrate_task(task_id) do
    case fetch_task(task_id) do
      {:ok, result, archive} ->
        case decode_archive(task_id, archive) do
          {:ok, records} ->
            inserted = insert_records(task_id, records)
            maybe_strip_result(task_id, result)
            null_archive(task_id)
            {:ok, inserted}

          :error ->
            :error
        end

      :error ->
        warn(task_id, "the row could not be read back")
        :error
    end
  end

  defp insert_records(task_id, records) do
    Enum.reduce(records, 0, fn record, count ->
      case archive_values(task_id, record) do
        {:ok, values} ->
          upsert_archive(values)
          count + 1

        :error ->
          count
      end
    end)
  end

  # ONE record → the destination row values, in `@archive_columns` order.
  # A record without a usable integer `agent_id` cannot key a row, so it is
  # logged and skipped (the rest of the task's archive is still migrated).
  defp archive_values(task_id, record) when is_map(record) do
    case agent_id(record) do
      {:ok, agent_id} ->
        {:ok, build_values(task_id, agent_id, record)}

      :error ->
        warn(task_id, "an archive record has no integer agent_id — the record is skipped")
        :error
    end
  end

  defp archive_values(task_id, _record) do
    warn(task_id, "an archive entry is not a JSON object — the entry is skipped")
    :error
  end

  defp build_values(task_id, agent_id, record) do
    [
      task_id,
      agent_id,
      value(record, "parent_id"),
      integer(value(record, "depth"), 0),
      value(record, "agent_type"),
      value(record, "context_node_path"),
      value(record, "objective"),
      text(value(record, "result")),
      value(record, "base_commit"),
      value(record, "final_commit"),
      value(record, "branch_name"),
      value(record, "archive_ref_start"),
      value(record, "archive_ref_final"),
      # `repo_id` is copied VERBATIM: it is a REPO ID STRING at runtime
      # (`"primary"` or a foreign repo id — `EvoGit.AgentSpec`/`AgentState`),
      # so this column is TEXT and nothing is coerced here. A legacy record
      # that carried a number is stored as its text form by the column's TEXT
      # affinity, never converted to an integer.
      value(record, "repo_id"),
      value(record, "repo_root"),
      value(record, "repo_path"),
      # The four JSON columns of the table (`usage`, `llm_settings`,
      # `agent_settings`, `foreign_repos`) are re-encoded as PLAIN JSON.
      encode_json(value(record, "usage")),
      encode_json(value(record, "llm_settings")),
      encode_json(value(record, "agent_settings")),
      encode_json(value(record, "foreign_repos")),
      integer(value(record, "compression_count"), 0),
      value(record, "started_at"),
      value(record, "completed_at")
    ]
  end

  defp upsert_archive(values) do
    sql(
      """
      INSERT OR REPLACE INTO #{@archive_table} (#{Enum.join(@archive_columns, ", ")})
      VALUES (#{placeholders(length(@archive_columns))})
      """,
      values
    )
  end

  # `data.archive_records` was a verbatim duplicate of `archive_metadata`, so it
  # is stripped from `result` — but ONLY when the key is actually there. A
  # result without it is never re-encoded (its bytes must not move).
  defp maybe_strip_result(_task_id, nil), do: :ok

  defp maybe_strip_result(task_id, result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"data" => data} = decoded} when is_map(data) ->
        if Map.has_key?(data, "archive_records") do
          stripped = Map.put(decoded, "data", Map.delete(data, "archive_records"))
          write_result(task_id, Jason.encode!(stripped))
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  defp maybe_strip_result(_task_id, _result), do: :ok

  ## Statements

  defp task_ids_with_archive do
    """
    SELECT id FROM tasks
     WHERE #{@column} IS NOT NULL
       AND length(#{@column}) > 0
    """
    |> select_ids([])
  end

  defp fetch_task(task_id) do
    case repo().query(
           "SELECT result, #{@column} FROM tasks WHERE id = ?",
           [task_id],
           timeout: @statement_timeout,
           log: false
         ) do
      {:ok, %{rows: [[result, archive]]}} -> {:ok, result, archive}
      _other -> :error
    end
  end

  defp null_archive(task_id) do
    sql("UPDATE tasks SET #{@column} = NULL WHERE id = ?", [task_id])
  end

  defp write_result(task_id, encoded) do
    sql("UPDATE tasks SET result = ? WHERE id = ?", [encoded, task_id])
  end

  defp select_ids(statement, params) do
    case repo().query(statement, params, timeout: @statement_timeout, log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      _other -> []
    end
  end

  defp sql(statement, params) do
    repo().query!(statement, params, timeout: @statement_timeout, log: false)
  end

  defp placeholders(count) do
    Enum.map_join(1..count, ", ", fn index -> "?#{index}" end)
  end

  ## Record decoding

  # Lenient: a corrupt archive (or one that is not a JSON array) is logged and
  # the task is skipped, never raised.
  defp decode_archive(task_id, archive) when is_binary(archive) do
    case Jason.decode(archive) do
      {:ok, records} when is_list(records) ->
        {:ok, records}

      {:ok, _other} ->
        warn(task_id, "the archive is not a JSON array — the task is skipped")
        :error

      {:error, _reason} ->
        warn(task_id, "the archive is not valid JSON — the task is skipped")
        :error
    end
  end

  defp decode_archive(task_id, _archive) do
    warn(task_id, "the archive is not JSON text — the task is skipped")
    :error
  end

  # Records are STRING-KEYED JSON maps; atom keys are accepted too so a
  # hand-written or intermediate fixture still migrates. Total: an absent key
  # yields `nil`, never a raise.
  defp value(record, key) do
    case Map.fetch(record, key) do
      {:ok, value} -> value
      :error -> atom_value(record, key)
    end
  end

  defp atom_value(record, key) do
    Enum.find_value(record, fn
      {record_key, value} when is_atom(record_key) ->
        if Atom.to_string(record_key) == key, do: value

      _other ->
        nil
    end)
  end

  defp agent_id(record) do
    case value(record, "agent_id") do
      id when is_integer(id) -> {:ok, id}
      id when is_binary(id) -> to_integer(id)
      _other -> :error
    end
  end

  defp to_integer(text) do
    case Integer.parse(text) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> default
    end
  end

  defp integer(_value, default), do: default

  # A TEXT column value: strings are stored verbatim, a structured value (an
  # older record whose `result` was a JSON object) stays JSON text.
  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value), do: Jason.encode!(value)

  # Plain JSON for the four JSON columns; `nil` stays SQL NULL (never the
  # string "null"), matching `EvoGit.Store.Types.ArchiveColumns.*`.
  defp encode_json(nil), do: nil
  defp encode_json(value), do: Jason.encode!(value)

  ## Guards / post-conditions

  defp column_exists?(column) do
    case repo().query("PRAGMA table_info(tasks)", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.any?(rows, fn [_cid, name | _rest] -> name == column end)
      _other -> false
    end
  end

  defp assert_no_archives_left!(skipped) do
    {exclusion, params} = exclusion_clause(skipped)

    """
    SELECT id FROM tasks
     WHERE #{@column} IS NOT NULL
       AND length(#{@column}) > 0
     #{exclusion}
    """
    |> select_ids(params)
    |> case do
      [] ->
        :ok

      remaining ->
        raise Ecto.MigrationError,
              "move-archives-to-table did not converge: #{length(remaining)} task(s) still " <>
                "hold an #{@column} value (e.g. " <>
                "#{remaining |> Enum.take(5) |> Enum.join(", ")}); the migration's UPDATE did " <>
                "not take effect"
    end
  end

  defp drop_column do
    sql("ALTER TABLE tasks DROP COLUMN #{@column}", [])

    if column_exists?(@column) do
      raise Ecto.MigrationError,
            "#{@column} was not dropped from tasks: PRAGMA table_info still reports it"
    end

    :ok
  end

  defp exclusion_clause([]), do: {"", []}

  defp exclusion_clause(skipped) do
    placeholders = Enum.map_join(skipped, ", ", fn _id -> "?" end)
    {"AND id NOT IN (#{placeholders})", skipped}
  end

  defp warn(task_id, reason) do
    Logger.warning(
      "#{inspect(__MODULE__)}: skipping task #{task_id} — #{reason} " <>
        "(the value is left exactly as it was)"
    )
  end
end
