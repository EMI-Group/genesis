defmodule EvoGit.Repo.Migrations.RepairHistoricalIdentities do
  @moduledoc """
  Reconciles physical schema after historical versions 5..9 changed meaning.
  Never edits the migration ledger or treats a stamped version as proof of DDL.
  All work runs in the migrator's transaction; malformed data or unknown shapes
  abort with the original database intact. Legacy archive/project sources are
  retained, including records which cannot be represented by today's schema.
  """
  use Ecto.Migration

  @archives "task_agent_archives"
  @scratch "task_agent_archives_identity_repair"
  @columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective result
    base_commit final_commit branch_name archive_ref_start archive_ref_final repo_id
    repo_root repo_path usage llm_settings agent_settings foreign_repos compression_count
    started_at completed_at)
  @integers ~w(agent_id parent_id depth compression_count)
  @json ~w(usage llm_settings agent_settings foreign_repos)

  def up do
    if info("tasks") == [], do: fail!("tasks table is missing")
    for column <- ~w(session_mode pause_kind), do: ensure_task_column!(column)
    unpack_tasks!()
    ensure_archives!()
    fan_out!()
    ensure_mounts!()

    ensure_index!("idx_tasks_updated_at", "tasks", ~w(updated_at))
    ensure_index!("idx_tasks_started_at", "tasks", ~w(started_at))
    # These frozen implementations only create/probe indexes, never task data.
    EvoGit.Repo.Migrations.CompositeIndexes.up()
    EvoGit.Repo.Migrations.CoveringIndexes.up()
    EvoGit.Repo.Migrations.PruneRedundantIndexes.up()
    :ok
  end

  defp ensure_task_column!(column) do
    unless Enum.any?(info("tasks"), &(Enum.at(&1, 1) == column)) do
      sql("ALTER TABLE tasks ADD COLUMN #{column} TEXT")
    end

    case Enum.find(info("tasks"), &(Enum.at(&1, 1) == column)) do
      [_, ^column, "TEXT", 0, nil, 0] -> :ok
      shape -> fail!("tasks.#{column} has unsupported shape #{inspect(shape)}")
    end
  end

  defp unpack_tasks! do
    names = Enum.map(info("tasks"), &Enum.at(&1, 1))

    for column <- ~w(result logs archive_metadata), column in names do
      for [id] <- sql("SELECT id FROM tasks WHERE substr(#{column}, 1, 3) = 'z1:'").rows do
        [[raw]] = sql("SELECT #{column} FROM tasks WHERE id = ?", [id]).rows
        plain = inflate!(raw, "tasks.#{column} for #{inspect(id)}")
        sql("UPDATE tasks SET #{column} = ? WHERE id = ?", [plain, id])
      end
    end
  end

  defp inflate!("z1:" <> encoded, location) do
    with {:ok, compressed} <- Base.decode64(encoded),
         {:ok, plain} <- uncompress(compressed),
         {:ok, _} <- Jason.decode(plain) do
      plain
    else
      _ -> fail!("invalid compressed JSON in #{location}; repair that value and retry")
    end
  end

  defp uncompress(binary) do
    {:ok, :zlib.uncompress(binary)}
  rescue
    ErlangError -> :error
  end

  defp archive_ddl(table) do
    fields =
      Enum.map_join(@columns, ", ", fn column ->
        type = if column in @integers, do: "INTEGER", else: "TEXT"

        suffix =
          cond do
            column in ~w(task_id agent_id) -> " NOT NULL"
            column in ~w(depth compression_count) -> " NOT NULL DEFAULT 0"
            true -> ""
          end

        "#{column} #{type}#{suffix}"
      end)

    "CREATE TABLE #{table} (#{fields}, PRIMARY KEY (task_id, agent_id))"
  end

  defp ensure_archives! do
    case info(@archives) do
      [] ->
        sql(archive_ddl(@archives))

      rows ->
        if Enum.map(rows, &Enum.at(&1, 1)) != @columns,
          do: fail!("unsupported archive columns; no archive table was replaced")

        case Enum.find(rows, &(Enum.at(&1, 1) == "repo_id")) do
          [_, _, "TEXT" | _] -> :ok
          [_, _, "INTEGER" | _] -> rebuild_archives!()
          _ -> fail!("unsupported archive repo_id type")
        end
    end

    ensure_index!("task_agent_archives_task_depth_idx", @archives, ~w(task_id depth agent_id))
  end

  defp rebuild_archives! do
    if info(@scratch) != [], do: fail!("#{@scratch} already exists; inspect it before retrying")
    # Preserve user indexes and triggers, rather than silently losing them in a rebuild.
    objects =
      sql(
        "SELECT sql FROM sqlite_master WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL",
        [@archives]
      ).rows

    sql(archive_ddl(@scratch))

    expected = info(@scratch)

    observed =
      Enum.map(info(@archives), fn
        [cid, "repo_id", "INTEGER", required, default, pk] ->
          [cid, "repo_id", "TEXT", required, default, pk]

        row ->
          row
      end)

    unless observed == expected, do: fail!("unsupported archive column constraints")

    [[ddl]] =
      sql("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [@archives]).rows

    if Regex.match?(~r/\b(CHECK|REFERENCES|UNIQUE|COLLATE|GENERATED)\b/i, ddl),
      do: fail!("archive table has custom constraints; refusing a lossy rebuild")

    # Dropping a referenced table could invoke ON DELETE actions even inside a
    # transaction; reject that unsupported shape before executing the drop.
    for [table] <- sql("SELECT name FROM sqlite_master WHERE type = 'table'").rows do
      quoted = String.replace(table, "\"", "\"\"")

      if Enum.any?(
           sql("PRAGMA foreign_key_list(\"#{quoted}\")").rows,
           &(Enum.at(&1, 2) == @archives)
         ),
         do: fail!("#{table} references archives; refusing a cascading rebuild")
    end

    columns = Enum.join(@columns, ", ")

    source =
      Enum.map_join(@columns, ", ", fn
        "repo_id" -> "CAST(repo_id AS TEXT)"
        column -> column
      end)

    sql("INSERT INTO #{@scratch} (#{columns}) SELECT #{source} FROM #{@archives}")
    [[count]] = sql("SELECT count(*) FROM #{@archives}").rows

    unless sql("SELECT count(*) FROM #{@scratch}").rows == [[count]],
      do: fail!("archive copy count mismatch")

    sql("DROP TABLE #{@archives}")
    sql("ALTER TABLE #{@scratch} RENAME TO #{@archives}")
    for [ddl] <- objects, do: sql(ddl)
  end

  defp fan_out! do
    if Enum.any?(info("tasks"), &(Enum.at(&1, 1) == "archive_metadata")) do
      for [id] <-
            sql(
              "SELECT id FROM tasks WHERE archive_metadata IS NOT NULL AND length(archive_metadata) > 0"
            ).rows do
        [[raw]] = sql("SELECT archive_metadata FROM tasks WHERE id = ?", [id]).rows

        records =
          case Jason.decode(raw) do
            {:ok, records} when is_list(records) ->
              records

            _ ->
              fail!(
                "invalid archive_metadata for #{inspect(id)}; source retained, repair and retry"
              )
          end

        for record <- records, do: insert_archive!(id, record)
      end
    end
  end

  defp insert_archive!(id, record) when is_map(record) do
    agent_id = integer!(record["agent_id"], "agent_id", id)

    values =
      Enum.map(@columns, fn
        "task_id" ->
          id

        "agent_id" ->
          agent_id

        column when column in @json ->
          encode(record[column])

        column when column in ~w(depth compression_count) ->
          integer!(record[column] || 0, column, id)

        "result" ->
          text(record["result"])

        column ->
          record[column]
      end)

    placeholders = Enum.map_join(@columns, ", ", fn _ -> "?" end)
    # A pre-existing relational row is authoritative; the entire original
    # legacy payload remains available, even when its version differs.
    sql(
      "INSERT INTO #{@archives} (#{Enum.join(@columns, ", ")}) VALUES (#{placeholders}) ON CONFLICT(task_id, agent_id) DO NOTHING",
      values
    )
  end

  defp insert_archive!(id, _), do: fail!("non-object archive entry for #{inspect(id)}")

  defp integer!(value, _column, _id) when is_integer(value), do: value

  defp integer!(value, column, id) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> fail!("invalid #{column} in archive for #{inspect(id)}")
    end
  end

  defp integer!(_, column, id), do: fail!("invalid #{column} in archive for #{inspect(id)}")
  defp encode(nil), do: nil
  defp encode(value), do: Jason.encode!(value)
  defp text(value) when is_binary(value) or is_nil(value), do: value
  defp text(value), do: Jason.encode!(value)

  defp ensure_mounts! do
    # Frozen VCT creation is safe only without legacy projects: its fan-out
    # caps/deletes rows. Keep that source intact and import without eviction.
    if info("projects") == [] do
      EvoGit.Repo.Migrations.VctMounts.up()
    else
      sql(
        "CREATE TABLE IF NOT EXISTS vct_mounts (point TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, kind TEXT NOT NULL, last_opened_at TEXT)"
      )

      assert_mount_shape!()

      rows =
        sql(
          "SELECT path, name, last_opened_at FROM projects ORDER BY last_opened_at DESC, path ASC"
        ).rows

      for [path, name, opened] <- rows do
        unless is_binary(path) and absolute?(path),
          do: fail!("legacy project has an invalid path; projects retained, repair and retry")

        case sql("SELECT point FROM vct_mounts WHERE path = ?", [path]).rows do
          [] ->
            basename =
              path |> String.replace("\\", "/") |> String.trim_trailing("/") |> Path.basename()

            segment = basename |> String.replace(~r/[\x00-\x1F\x7F]/, "") |> String.trim()
            segment = if segment in ["", ".", ".."], do: "project", else: segment
            point = unique_point("vct:///projects/" <> segment)
            name = if is_binary(name) and String.trim(name) != "", do: name, else: basename
            sql("INSERT INTO vct_mounts VALUES (?, ?, ?, 'git', ?)", [point, path, name, opened])

          [_] ->
            :ok
        end
      end
    end

    assert_mount_shape!()
  end

  defp assert_mount_shape! do
    expected = [
      {"point", "TEXT", 1, 1},
      {"path", "TEXT", 1, 0},
      {"name", "TEXT", 1, 0},
      {"kind", "TEXT", 1, 0},
      {"last_opened_at", "TEXT", 0, 0}
    ]

    actual =
      Enum.map(info("vct_mounts"), fn [_, name, type, required, _, pk] ->
        {name, type, required, pk}
      end)

    unless actual == expected, do: fail!("unsupported vct_mounts shape")
  end

  defp absolute?("/" <> _), do: true
  defp absolute?("\\\\" <> _), do: true

  defp absolute?(<<drive, ?:, sep, _::binary>>) when drive in ?A..?Z or drive in ?a..?z,
    do: sep in [?/, ?\\]

  defp absolute?(_), do: false

  defp unique_point(base, counter \\ 1) do
    candidate = if counter == 1, do: base, else: base <> "-#{counter}"

    case sql("SELECT point FROM vct_mounts WHERE point = ?", [candidate]).rows do
      [] -> candidate
      [_] -> unique_point(base, counter + 1)
    end
  end

  defp ensure_index!(name, table, columns) do
    sql("CREATE INDEX IF NOT EXISTS #{name} ON #{table}(#{Enum.join(columns, ", ")})")
    actual = Enum.map(sql("PRAGMA index_info(#{name})").rows, &Enum.at(&1, 2))
    unless actual == columns, do: fail!("unsupported index #{name}")
  end

  defp info(table), do: sql("PRAGMA table_info(#{table})").rows

  defp sql(statement, params \\ []),
    do: repo().query!(statement, params, timeout: 600_000, log: false)

  defp fail!(message), do: raise(Ecto.MigrationError, "historical identity repair: " <> message)
end
