defmodule EvoGit.Store.Quarantine do
  @moduledoc """
  Quarantine and data-recovery logic for the EvoGit SQLite store.

  Handles safe row decoding with automatic quarantine of corrupt data, integrity
  checks with row-level scan-and-repair, and recovery of previously quarantined
  rows back into live tables.

  Functions with `do_` prefix are the primary entry points called by the Store
  GenServer's `handle_call` handlers. Internal helpers (`recover_table_quarantine`,
  `scan_and_repair`, `quarantine_row`) are kept private.
  """

  require Logger

  alias EvoGit.Store.Codec

  @doc """
  Maps a table name to its ordered column list (delegates to Codec).
  """
  def table_columns("tasks"), do: Codec.task_columns()
  def table_columns("projects"), do: Codec.project_columns()

  @doc """
  Maps a table name to its primary key column name.
  """
  def pk_column("tasks"), do: "id"
  def pk_column("projects"), do: "path"

  @doc """
  Runs the per-row decode+quarantine loop over an already-fetched list of
  rows. Shared by the paginated task select handler and `scan_and_repair`.
  Quarantines rows that fail decode rather than crashing — the same justified
  try/rescue recovery boundary.
  """
  def safe_decode_rows(conn, table, rows, decoder) do
    columns = table_columns(table)
    pk = pk_column(table)

    Enum.flat_map(rows, fn row ->
      id = hd(row)

      # Justified try/rescue — quarantine/data-recovery boundary.
      # (1) Do we expect this? Yes — DB rows may contain corrupt or legacy
      # data that fails to decode. (2) Cleanest approach? The decoder raises
      # by design (Codec decode philosophy); quarantine is the deliberate
      # recovery boundary that moves bad rows aside rather than crashing the
      # entire select.
      try do
        [decoder.(row)]
      rescue
        e ->
          quarantine_row(conn, table, id, pk, columns, row)

          Logger.warning(
            "Store: skipping undecodable row in #{table} " <>
              "(id: #{inspect(id)}): #{Exception.message(e)}"
          )

          []
      end
    end)
  end

  @doc """
  Checks store integrity and repairs corruption.

  1. Runs `PRAGMA integrity_check` to verify SQLite structural health.
  2. Scans all rows in both tables, decoding each into the proper struct.
     Undecodable rows are QUARANTINED — the raw column data is serialized as
     JSON and moved to the corresponding quarantine table, then deleted from
     the live table.

  Returns:
    * `:ok` — store is healthy.
    * `{:repaired, count}` — some undecodable rows were quarantined.
    * `{:error, reason}` — SQLite-level corruption detected.
  """
  def do_integrity_check(conn) do
    # Justified try/rescue — diagnostic/recovery routine.
    # (1) Do we expect an error here? Possibly — unexpected SQLite-level
    # failures during the diagnostic scan itself. (2) Cleanest approach?
    # integrity_check is a recovery routine called during GenServer init (from
    # TaskRegistry.init/1). It must return {:error, _} rather than crashing,
    # because a crash here would prevent TaskRegistry from starting at all.
    try do
      case XqliteNIF.query(conn, "PRAGMA integrity_check", []) do
        {:ok, %{rows: [["ok"]]}} ->
          :ok

        {:ok, %{rows: rows}} ->
          reason = inspect(rows)
          Logger.error("SQLite integrity_check reports problems: #{reason}")
          {:error, reason}

        {:error, reason} ->
          Logger.error("SQLite integrity_check query failed: #{inspect(reason)}")
          {:error, reason}
      end
      |> then(fn pragma_result ->
        case pragma_result do
          :ok ->
            corrupt =
              scan_and_repair(conn, "tasks", &Codec.decode_task/1) +
                scan_and_repair(conn, "projects", &Codec.decode_project/1)

            if corrupt > 0, do: {:repaired, corrupt}, else: :ok

          other ->
            other
        end
      end)
    rescue
      error ->
        Logger.error("integrity_check failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Attempts to recover rows from the quarantine tables back into the live tables.

  Reads all rows from `tasks_quarantine` and `projects_quarantine`, decodes
  the stored JSON column data, and tries to re-decode each row through the
  Codec. Rows that now decode successfully (e.g. after a codec bugfix) are
  INSERT OR REPLACE'd back into the live table and deleted from quarantine.
  Rows that still fail to decode are left in quarantine untouched.

  Returns `{:ok, recovered_count}`.
  """
  def do_recover_quarantine(conn) do
    tasks_recovered =
      recover_table_quarantine(conn, "tasks", Codec.task_columns(), &Codec.decode_task/1)

    projects_recovered =
      recover_table_quarantine(conn, "projects", Codec.project_columns(), &Codec.decode_project/1)

    total = tasks_recovered + projects_recovered

    if total > 0 do
      Logger.info(
        "Store: recovered #{total} rows from quarantine (#{tasks_recovered} tasks, #{projects_recovered} projects)"
      )
    end

    {:ok, total}
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # Reads rows from a quarantine table, attempts to decode each via `decoder`,
  # and moves successfully decoded rows back into the live `table`. Rows that
  # still fail to decode are left in quarantine.
  defp recover_table_quarantine(conn, table, columns, decoder) do
    quarantine_table = "#{table}_quarantine"

    case XqliteNIF.query(conn, "SELECT id, data FROM #{quarantine_table}", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, 0, fn [id, data], acc ->
          case Jason.decode(data) do
            {:ok, map} when is_map(map) ->
              # Reconstruct the row list in column order from the JSON map.
              row = Enum.map(columns, &Map.get(map, &1))

              # Justified try/rescue — data-recovery boundary. The decoder raises
              # by design on bad data; rows that still fail to decode must stay
              # in quarantine rather than crashing the entire recovery sweep.
              try do
                decoder.(row)

                col_names = Enum.join(columns, ", ")

                placeholders =
                  columns
                  |> Enum.with_index(1)
                  |> Enum.map(fn {_, i} -> "?#{i}" end)
                  |> Enum.join(", ")

                {:ok, _} =
                  XqliteNIF.execute(
                    conn,
                    "INSERT OR REPLACE INTO #{table} (#{col_names}) VALUES (#{placeholders})",
                    row
                  )

                {:ok, _} =
                  XqliteNIF.execute(
                    conn,
                    "DELETE FROM #{quarantine_table} WHERE id = ?1",
                    [id]
                  )

                Logger.info(
                  "Store: recovered row from #{quarantine_table} " <>
                    "(id=#{inspect(id)}) → #{table}"
                )

                acc + 1
              rescue
                e ->
                  Logger.warning(
                    "Store: row in #{quarantine_table} (id=#{inspect(id)}) still fails decode, " <>
                      "leaving in quarantine: #{Exception.message(e)}"
                  )

                  acc
              end

            {:error, _} ->
              Logger.warning(
                "Store: failed to parse JSON data in #{quarantine_table} " <>
                  "(id=#{inspect(id)}), leaving in quarantine"
              )

              acc

            _ ->
              acc
          end
        end)

      _ ->
        0
    end
  end

  defp scan_and_repair(conn, table, decoder) do
    columns = table_columns(table)
    col_list = Enum.join(columns, ", ")
    pk = pk_column(table)

    case XqliteNIF.query(conn, "SELECT #{col_list} FROM #{table}", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, 0, fn row, acc ->
          id = hd(row)

          # Justified try/rescue — quarantine/data-recovery boundary (same as
          # safe_decode_rows). The decoder raises by design; quarantine is
          # the deliberate recovery boundary.
          try do
            decoder.(row)
            acc
          rescue
            _ ->
              quarantine_row(conn, table, id, pk, columns, row)
              acc + 1
          end
        end)

      _ ->
        0
    end
  end

  # Moves an undecodable row into the quarantine table (INSERT raw data as JSON
  # then DELETE from the live table). If the quarantine INSERT itself fails, we
  # log an error and LEAVE THE ROW IN PLACE — never silently destroy data.
  defp quarantine_row(conn, table, id, pk, columns, row) do
    quarantine_table = "#{table}_quarantine"

    json_data =
      case columns |> Enum.zip(row) |> Map.new() |> Jason.encode() do
        {:ok, json} -> json
        {:error, _} -> nil
      end

    # Justified try/rescue — data-recovery boundary. Must never destroy data;
    # if the quarantine INSERT or DELETE fails, we log and leave the row in
    # place rather than crashing and potentially losing the row entirely.
    try do
      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "INSERT OR REPLACE INTO #{quarantine_table} (id, data) VALUES (?1, ?2)",
          [id, json_data]
        )

      {:ok, _} =
        XqliteNIF.execute(conn, "DELETE FROM #{table} WHERE #{pk} = ?1", [id])

      Logger.warning([
        "Store: quarantined undecodable row ",
        "(table=#{table}, id=#{inspect(id)}) → #{quarantine_table}. ",
        "Raw data preserved for recovery."
      ])
    rescue
      e ->
        Logger.error([
          "Store: failed to quarantine undecodable row ",
          "(table=#{table}, id=#{inspect(id)}): #{Exception.message(e)}. ",
          "Leaving row in place — data NOT destroyed."
        ])
    end
  end
end
