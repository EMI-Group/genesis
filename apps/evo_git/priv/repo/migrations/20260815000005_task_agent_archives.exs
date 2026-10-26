defmodule EvoGit.Repo.Migrations.TaskAgentArchives do
  @moduledoc """
  Creates `task_agent_archives` — ONE relational ROW per (task, agent) — and
  moves any pre-existing archive into it.

  The per-agent archive used to be a single JSON array inside
  `tasks.archive_metadata` (and, before the dedup, a duplicate
  `archive_records` key inside `tasks.result`). Reading ONE agent's archived
  conversation therefore meant decoding the WHOLE task's archive, and the
  dashboard's agent-detail panel paid for every agent of the task on every
  open. This migration gives each archived agent its own row, so the archive
  becomes a normal relational read: page the roster without the `result` blob,
  fetch one agent's `result` on demand, delete by task.

  ## 1. The table (the ONLY create site)

  | column               | type    | notes |
  |----------------------|---------|-------|
  | `task_id`            | TEXT    | NOT NULL, PK part 1 |
  | `agent_id`           | INTEGER | NOT NULL, PK part 2 |
  | `parent_id`          | INTEGER | spawn tree parent (agent id), NULL for the root agent |
  | `depth`              | INTEGER | NOT NULL DEFAULT 0 — spawn depth (root = 0) |
  | `agent_type`         | TEXT    | agent type key (manager/executor/...) |
  | `context_node_path`  | TEXT    | node the agent was scoped to |
  | `objective`          | TEXT    | the agent's objective |
  | `result`             | TEXT    | the agent's final response — the HEAVY column, paged separately |
  | `base_commit`        | TEXT    | commit the agent started from |
  | `final_commit`       | TEXT    | commit the agent ended on |
  | `branch_name`        | TEXT    | branch the agent worked on |
  | `archive_ref_start`  | TEXT    | archive start ref |
  | `archive_ref_final`  | TEXT    | archive final ref |
  | `repo_id`            | TEXT    | repo ID string — `"primary"` or a foreign repo id |
  | `repo_root`          | TEXT    | absolute repo root |
  | `repo_path`          | TEXT    | repo-relative path |
  | `usage`              | TEXT    | plain JSON object (token/cost accounting) |
  | `llm_settings`       | TEXT    | plain JSON object |
  | `agent_settings`     | TEXT    | plain JSON object |
  | `foreign_repos`      | TEXT    | plain JSON array of objects |
  | `compression_count`  | INTEGER | NOT NULL DEFAULT 0 |
  | `started_at`         | TEXT    | ISO-8601 TEXT, stored as-is |
  | `completed_at`       | TEXT    | ISO-8601 TEXT, stored as-is |

  The composite `PRIMARY KEY (task_id, agent_id)` is what makes a write
  idempotent: a re-put of the same pair REPLACES the row
  (`INSERT … ON CONFLICT (task_id, agent_id) DO UPDATE` / the equivalent
  `INSERT OR REPLACE`), so a re-run or a crash-recovered write can never
  duplicate an agent.

  Timestamps stay ISO-8601 **TEXT** and the four JSON columns stay plain JSON
  **TEXT** — no Ecto field types, no compression, exactly like every other
  column in this store (the wire format is owned by
  `EvoGit.Store.Types.ArchiveColumns.*`, not by the migration).

  ## 2. The index

  `task_agent_archives_task_depth_idx` on `(task_id, depth, agent_id)` serves
  the one read shape the dashboard uses — the per-task roster,
  `WHERE task_id = ? ORDER BY depth ASC, agent_id ASC LIMIT/OFFSET` — as an
  index-served seek + ordered scan, with `id`-only projections (`agent_id`,
  `depth`) answered from the index. The `task_id` prefix also serves the
  `DELETE … WHERE task_id = ?` cascade. No other index is added: `agent_id`
  lookups always carry the `task_id` (the pair IS the primary key, whose
  b-tree already covers the full-row fetch).

  ## 3. The legacy fan-out (guarded)

  Only when `PRAGMA table_info(tasks)` still reports `archive_metadata` (a
  pre-release build's shape; a fresh or already-fanned-out database no-ops in
  O(1)), each task row with a non-empty archive is moved over:

    1. decode the JSON array LENIENTLY (`Jason.decode/1`); a corrupt value, or
       a value that is not a list, is logged with `Logger.warning` naming the
       task id and SKIPPED — one unreadable archive never wedges an upgrade,
       and the skipped payload is DUMPED before the column goes (below);
    2. `INSERT OR REPLACE` exactly one `task_agent_archives` row per record,
       mapping every record key onto its column (`task_id` comes from the task
       row, `agent_id` from the record; `depth`/`compression_count` default to
       0; `usage`/`llm_settings`/`agent_settings`/`foreign_repos` are re-encoded
       with `Jason.encode!` — plain JSON, no compression, SQL NULL for a missing
       value); every other column is copied VERBATIM, in particular `repo_id`,
       which is a repo ID STRING (`"primary"` or a foreign repo id) and
       therefore a TEXT column — it is never cast to an integer;
    3. strip `data.archive_records` from `result` — but ONLY when that key is
       present (it was a verbatim DUPLICATE of this column). The result JSON is
       decoded/re-encoded for that one case; a result without the key is left
       COMPLETELY untouched, byte for byte;
    4. set `archive_metadata = NULL` for the migrated task.

  `updated_at` (and every other column) is NEVER touched: moving the archive
  is not a task mutation.

  ## 3a. Undecodable archives are dumped, never dropped

  Dropping the column destroys every payload it holds, so a task whose archive
  cannot be decoded is preserved FIRST, in
  `<EvoGit.Platform.data_dir()>/migration_dumps/archive_metadata_skipped_20260815000005.json`
  — one plain JSON object mapping `task_id` to that task's RAW
  `archive_metadata` text (the value exactly as it sat in the row).
  The migration version is part of the file name, so this dump can never
  clobber one written by another version.
  The absolute path is logged at `:warning`, and the file is written BEFORE
  the column is dropped, so the operator always has a recoverable copy.
  A clean upgrade (every archive decodable, or no legacy column at all) writes
  NOTHING: no dump file, no `migration_dumps/` directory, no extra I/O.
  If the dump cannot be written the migration RAISES (boot-fatal) instead of
  dropping the payloads — losing archive data silently is the one outcome this
  migration refuses.

  Then the column goes: `ALTER TABLE tasks DROP COLUMN archive_metadata` runs
  at the very end, and only when the column still exists — SQLite has supported
  `DROP COLUMN` since 3.35, no index or constraint references this column, so
  the operation is an O(1) schema-header edit (no table rebuild).

  ## Idempotent / resumable

  Every step converges on a re-run, which is what makes a PARTIAL failure safe:

    * the table/index DDL is `IF NOT EXISTS`, and the shape post-conditions
      raise on a same-named object of a different shape;
    * the `INSERT OR REPLACE` upsert on the composite `(task_id, agent_id)`
      primary key can never duplicate an agent (it replaces it);
    * each task only clears its own `archive_metadata` after its records are in
      the table, and an already-NULL archive is not a candidate;
    * the fan-out and the `DROP COLUMN` are guarded by a column-existence probe,
      so a boot that crashed between them (or one re-running after the column
      is already gone) simply finishes;
    * a still-corrupt archive is skipped again (and logged again), leaving the
      migration converging without it — its payload is re-dumped to the SAME
      file (idempotent: the dump is rebuilt from the current rows).

  ## Conventions

  Statements run via `repo().query/3` + `repo().query!/3` (the sibling
  migrations' convention), NOT `Ecto.Migration.execute/1`, whose string
  commands are queued until `flush/0` — the DDL, the shape probes, the
  fan-out's per-row reads/writes, the NULLing, the column probe and the final
  `DROP` all have to observe each other in body order. Payload-moving values
  are read ONE ROW AT A TIME (an archived agent's `result` can be tens of MiB)
  with `timeout: 600_000` per statement. Defined as `up/0` (no `down/0`):
  dropping the table would drop user archive data and the column is gone.

  A database created by a PRE-RELEASE build that declared `repo_id` INTEGER is
  not rebuilt here — that variant never shipped; delete the database instead.
  """

  use Ecto.Migration

  require Logger

  # The physical column order — FIRST the two primary-key columns, then the
  # roster columns, then the heavy `result` blob, then the refs/repo/JSON
  # columns, and the timestamps LAST. Kept as data so the post-condition below
  # can assert the exact shape that was created.
  @table_ddl """
  CREATE TABLE IF NOT EXISTS task_agent_archives (
    task_id TEXT NOT NULL,
    agent_id INTEGER NOT NULL,
    parent_id INTEGER,
    depth INTEGER NOT NULL DEFAULT 0,
    agent_type TEXT,
    context_node_path TEXT,
    objective TEXT,
    result TEXT,
    base_commit TEXT,
    final_commit TEXT,
    branch_name TEXT,
    archive_ref_start TEXT,
    archive_ref_final TEXT,
    repo_id TEXT,
    repo_root TEXT,
    repo_path TEXT,
    usage TEXT,
    llm_settings TEXT,
    agent_settings TEXT,
    foreign_repos TEXT,
    compression_count INTEGER NOT NULL DEFAULT 0,
    started_at TEXT,
    completed_at TEXT,
    PRIMARY KEY (task_id, agent_id)
  )
  """

  @columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective result
              base_commit final_commit branch_name archive_ref_start archive_ref_final repo_id
              repo_root repo_path usage llm_settings agent_settings foreign_repos
              compression_count started_at completed_at)

  @index_name "task_agent_archives_task_depth_idx"
  @index_columns ~w(task_id depth agent_id)

  # The legacy column this migration consumes and removes.
  @legacy_column "archive_metadata"

  # Where the undecodable payloads of `@legacy_column` are preserved before the
  # column is dropped: `<data_dir>/migration_dumps/<this name>`. The migration
  # version is part of the file name so a later version's dump can never
  # clobber this one.
  @dump_dir "migration_dumps"
  @dump_file "archive_metadata_skipped_20260815000005.json"

  # The heavy `result` blob is read/written row by row; a user database can
  # hold thousands of multi-MiB rows.
  @statement_timeout 600_000

  def up do
    sql(@table_ddl)

    sql(
      "CREATE INDEX IF NOT EXISTS #{@index_name} ON task_agent_archives(task_id, depth, agent_id)"
    )

    assert_table_shape!()
    assert_index_shape!()

    if column_exists?(@legacy_column) do
      fan_out()
      drop_legacy_column()
    end

    :ok
  end

  ## Legacy fan-out

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
      "#{inspect(__MODULE__)}: #{tasks} task(s) moved to task_agent_archives " <>
        "(#{records} agent record(s)); #{length(skipped)} task(s) skipped"
    )

    # An undecodable archive is DATA, not noise: preserve its raw payload
    # BEFORE the column is dropped, so nothing is lost with only a log line as
    # a trace. A clean fan-out writes nothing at all.
    dump_skipped(skipped)

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

  ## Skipped-payload dump

  # `<data_dir>/migration_dumps/archive_metadata_skipped_20260815000005.json` —
  # a plain JSON object mapping `task_id` to the RAW `@legacy_column` text.
  #
  # STRICT no-op when nothing was skipped (the path every fresh database and
  # every clean upgrade takes): no file, no directory, no I/O.
  # A dump that cannot be written RAISES — the migration transaction then rolls
  # back and the column survives, which is the whole point.
  defp dump_skipped([]), do: :ok

  defp dump_skipped(skipped) do
    payloads = skipped_payloads(skipped)

    if map_size(payloads) == 0, do: :ok, else: write_dump(payloads)
  end

  # The raw payloads of the skipped tasks, read in ONE statement (the fan-out
  # above only kept the ids). A read error RAISES rather than dumping less than
  # it promised: the column must not go while a payload is unaccounted for.
  defp skipped_payloads(task_ids) do
    placeholders = Enum.map_join(task_ids, ", ", fn _id -> "?" end)

    statement =
      "SELECT id, #{@legacy_column} FROM tasks " <>
        "WHERE id IN (#{placeholders}) AND #{@legacy_column} IS NOT NULL"

    case repo().query(statement, task_ids, timeout: @statement_timeout, log: false) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [task_id, raw] -> {task_id, raw} end)
      {:error, reason} -> raise_dump_error("<read back the skipped payloads>", reason)
    end
  end

  defp write_dump(payloads) do
    dir = Path.join(EvoGit.Platform.data_dir(), @dump_dir)
    path = Path.join(dir, @dump_file)

    case File.mkdir_p(dir) do
      :ok ->
        case File.write(path, Jason.encode!(payloads, pretty: true)) do
          :ok ->
            Logger.warning(
              "#{inspect(__MODULE__)}: #{map_size(payloads)} undecodable " <>
                "#{@legacy_column} payload(s) saved to #{path} before the column is dropped"
            )

            :ok

          {:error, reason} ->
            raise_dump_error(path, reason)
        end

      {:error, reason} ->
        raise_dump_error(path, reason)
    end
  end

  defp raise_dump_error(target, reason) do
    raise Ecto.MigrationError,
          "task-agent-archives could not write the skipped-#{@legacy_column} dump " <>
            "(#{target}: #{inspect(reason)}); #{@legacy_column} is NOT dropped, because " <>
            "those payloads would otherwise be lost — fix the data dir and retry"
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

  # ONE record → the destination row values, in `@columns` order.
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
      INSERT OR REPLACE INTO task_agent_archives (#{Enum.join(@columns, ", ")})
      VALUES (#{placeholders(length(@columns))})
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
     WHERE #{@legacy_column} IS NOT NULL
       AND length(#{@legacy_column}) > 0
    """
    |> select_ids([])
  end

  defp fetch_task(task_id) do
    case repo().query(
           "SELECT result, #{@legacy_column} FROM tasks WHERE id = ?",
           [task_id],
           timeout: @statement_timeout,
           log: false
         ) do
      {:ok, %{rows: [[result, archive]]}} -> {:ok, result, archive}
      _other -> :error
    end
  end

  defp null_archive(task_id) do
    sql("UPDATE tasks SET #{@legacy_column} = NULL WHERE id = ?", [task_id])
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

  defp sql(statement, params \\ []) do
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

  # Post-condition: the table carries EXACTLY the declared columns in the
  # declared order. `IF NOT EXISTS` alone would silently keep a same-named
  # table of a different shape, and every read/write through the schema would
  # then fail at runtime instead of here.
  defp assert_table_shape! do
    actual = table_columns()

    if actual != @columns do
      raise Ecto.MigrationError,
            "task_agent_archives was not created with the expected columns: " <>
              "PRAGMA table_info returned #{inspect(actual)}"
    end

    :ok
  end

  # PRAGMA table_info(<table>) rows: [cid, name, type, notnull, dflt, pk]. A
  # missing table yields NO rows (never an error), so [] is the "absent" signal.
  defp table_columns do
    case repo().query("PRAGMA table_info(task_agent_archives)", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [_cid, name, _type, _notnull, _dflt, _pk] -> name end)

      _other ->
        []
    end
  end

  defp assert_index_shape! do
    actual = index_columns()

    if actual != @index_columns do
      raise Ecto.MigrationError,
            "index #{@index_name} on task_agent_archives(#{Enum.join(@index_columns, ", ")}) " <>
              "was not applied: PRAGMA index_info returned #{inspect(actual)}"
    end

    :ok
  end

  # PRAGMA index_info(<name>) rows: [seqno, cid, name].
  defp index_columns do
    case repo().query("PRAGMA index_info(#{@index_name})", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [_seqno, _cid, column] -> column end)
      _other -> []
    end
  end

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
     WHERE #{@legacy_column} IS NOT NULL
       AND length(#{@legacy_column}) > 0
     #{exclusion}
    """
    |> select_ids(params)
    |> case do
      [] ->
        :ok

      remaining ->
        raise Ecto.MigrationError,
              "task-agent-archives did not converge: #{length(remaining)} task(s) still " <>
                "hold an #{@legacy_column} value (e.g. " <>
                "#{remaining |> Enum.take(5) |> Enum.join(", ")}); the migration's UPDATE did " <>
                "not take effect"
    end
  end

  defp drop_legacy_column do
    sql("ALTER TABLE tasks DROP COLUMN #{@legacy_column}")

    if column_exists?(@legacy_column) do
      raise Ecto.MigrationError,
            "#{@legacy_column} was not dropped from tasks: PRAGMA table_info still reports it"
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
        "(the value is not migrated into task_agent_archives)"
    )
  end
end
