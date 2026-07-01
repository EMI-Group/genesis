#!/usr/bin/env elixir
#
# repair_db.exs — Database repair script for corrupted module atoms
#
# USAGE:
#   mix run scripts/repair_db.exs                  # auto-detect default DB
#   mix run scripts/repair_db.exs /path/to/tasks.sqlite
#   mix run scripts/repair_db.exs --dry-run        # preview without writing
#
# WHAT IT DOES:
#   This script repairs databases that were corrupted by the first version
#   of scrub_db.exs, which incorrectly converted module atoms (like
#   Calendar.ISO inside DateTime structs) into strings.
#
#   It specifically repairs:
#     - DateTime structs with calendar: "Elixir.Calendar.ISO" → Calendar.ISO
#     - NaiveDateTime structs with calendar: "Elixir.Calendar.ISO" → Calendar.ISO
#     - Time structs with calendar: "Elixir.Calendar.ISO" → Calendar.ISO
#     - Date structs with calendar: "Elixir.Calendar.ISO" → Calendar.ISO
#
# SAFETY:
#   - --dry-run mode shows what would change without writing
#   - Always backs up the database before modifying

defmodule RepairDb do
  @moduledoc false

  def run(opts) do
    db_path = resolve_db_path(opts)
    dry_run = Keyword.get(opts, :dry_run, false)

    IO.puts("=== EvoDash Database Repair Script ===")
    IO.puts("Database: #{db_path}")
    IO.puts("Mode: #{if dry_run, do: "DRY RUN (no writes)", else: "WRITE"}")
    IO.puts("")

    unless File.exists?(db_path) do
      IO.puts("ERROR: Database file not found: #{db_path}")
      System.halt(1)
    end

    # Always back up before modifying
    unless dry_run do
      backup_path = backup_database(db_path)
      IO.puts("Backup created: #{backup_path}")
      IO.puts("")
    end

    # Ensure apps are loaded so struct atoms are registered
    Application.load(:evo_dash)
    Application.load(:evo_git)

    {:ok, conn} = Xqlite.open(db_path)

    tables = ["tasks", "projects", "tasks_quarantine", "projects_quarantine"]

    stats =
      Enum.reduce(tables, %{}, fn table, acc ->
        count = repair_table(conn, table, dry_run)
        Map.put(acc, table, count)
      end)

    XqliteNIF.close(conn)

    IO.puts("")
    IO.puts("=== Summary ===")

    Enum.each(stats, fn {table, count} ->
      action = if dry_run, do: "would repair", else: "repaired"
      IO.puts("  #{table}: #{count} rows #{action}")
    end)

    total = Enum.sum(Map.values(stats))

    IO.puts("")

    if total == 0 do
      IO.puts("No corrupted module atoms found — database is clean.")
    else
      if dry_run do
        IO.puts("Run without --dry-run to apply changes.")
      else
        IO.puts("Done! Database has been repaired.")
      end
    end
  end

  defp repair_table(conn, table, dry_run) do
    case Xqlite.query(conn, "SELECT id, data FROM #{table}", []) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        IO.puts("Scanning table '#{table}' (#{length(rows)} rows)...")

        rows
        |> Enum.reduce(0, fn [id, blob], repaired_count ->
          case repair_row(id, blob, dry_run) do
            {:repaired, new_blob} ->
              unless dry_run do
                {:ok, _} =
                  Xqlite.execute(
                    conn,
                    "UPDATE #{table} SET data = ?2 WHERE id = ?1",
                    [id, new_blob]
                  )
              end

              repaired_count + 1

            :clean ->
              repaired_count
          end
        end)

      {:error, :no_such_table} ->
        IO.puts("  Table '#{table}' does not exist — skipping.")
        0

      {:error, reason} ->
        IO.puts("  WARNING: Failed to read table '#{table}': #{inspect(reason)}")
        0
    end
  end

  defp repair_row(id, blob, _dry_run) do
    term =
      try do
        :erlang.binary_to_term(blob)
      rescue
        e ->
          IO.puts("    [#{id}] Cannot decode blob: #{Exception.message(e)} — skipping")
          :decode_failed
      end

    case term do
      :decode_failed ->
        :clean

      decoded ->
        repaired = repair_module_atoms(decoded)

        if repaired != decoded do
          new_blob = :erlang.term_to_binary(repaired)

          IO.puts(
            "    [#{id}] Repaired module atoms (#{byte_size(blob)} → #{byte_size(new_blob)} bytes)"
          )

          {:repaired, new_blob}
        else
          :clean
        end
    end
  end

  # Repair strings that should be module atoms back to atoms.
  # This specifically fixes DateTime/NaiveDateTime/Time/Date structs that had
  # their calendar field converted from Calendar.ISO to "Elixir.Calendar.ISO".

  # Map-like structs: check the calendar field and repair if needed
  defp repair_module_atoms(%{__struct__: struct_name, calendar: calendar} = struct)
       when is_binary(calendar) do
    # Check if this is a string that should be a module atom
    new_calendar = maybe_string_to_module(calendar)

    if new_calendar != calendar do
      # Repair the calendar field and recursively repair other fields
      struct
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {k, repair_module_atoms(v)} end)
      |> Map.new()
      |> Map.put(:__struct__, struct_name)
      |> Map.put(:calendar, new_calendar)
    else
      # Just recursively repair other fields
      repair_map_struct(struct)
    end
  end

  # Structs without calendar field: process normally
  defp repair_module_atoms(%{__struct__: _} = struct) do
    repair_map_struct(struct)
  end

  # Regular maps: repair all values
  defp repair_module_atoms(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.map(fn {k, v} -> {repair_module_atoms(k), repair_module_atoms(v)} end)
    |> Map.new()
  end

  # Keyword lists
  defp repair_module_atoms([{key, _value} | _] = list) when is_atom(key) do
    Enum.map(list, fn {k, v} -> {k, repair_module_atoms(v)} end)
  end

  # Lists
  defp repair_module_atoms(list) when is_list(list) do
    Enum.map(list, &repair_module_atoms/1)
  end

  # Tuples
  defp repair_module_atoms(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&repair_module_atoms/1)
    |> List.to_tuple()
  end

  # Strings that might be module atoms
  defp repair_module_atoms(str) when is_binary(str) do
    case maybe_string_to_module(str) do
      ^str -> str  # No conversion needed
      module -> module  # Converted to atom
    end
  end

  # Everything else stays as-is
  defp repair_module_atoms(other), do: other

  defp repair_map_struct(struct) do
    struct
    |> Map.to_list()
    |> Enum.map(fn {k, v} -> {k, repair_module_atoms(v)} end)
    |> Map.new()
    |> Map.put(:__struct__, struct.__struct__)
  end

  # Convert a string to a module atom if it looks like one.
  # "Elixir.Calendar.ISO" -> Calendar.ISO
  # Other strings -> unchanged
  defp maybe_string_to_module(str) do
    case str do
      "Elixir.Calendar.ISO" -> Calendar.ISO
      "Elixir." <> _ ->
        # Try to convert other Elixir modules
        # This is safe because we're only converting strings that were
        # originally atoms (the bug is one-way)
        try do
          Module.concat(Elixir, String.to_existing_atom(str))
        rescue
          ArgumentError -> str
        end

      _ ->
        str
    end
  end

  defp resolve_db_path(opts) do
    case Keyword.get(opts, :db_path) do
      nil -> default_db_path()
      path -> path
    end
  end

  defp default_db_path do
    data_dir = EvoGit.Platform.data_dir()
    Path.join(data_dir, "tasks.sqlite")
  end

  defp backup_database(db_path) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    backup_path = "#{db_path}.repair_backup_#{timestamp}"
    File.cp!(db_path, backup_path)
    backup_path
  end
end

# Parse command line arguments
{opts, rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [dry_run: :boolean, db_path: :string],
    aliases: [d: :dry_run]
  )

opts =
  case rest do
    [path | _] -> Keyword.put(opts, :db_path, path)
    [] -> opts
  end

# Ensure required apps are started
Application.ensure_all_started(:evo_git)

RepairDb.run(opts)
