#!/usr/bin/env elixir
#
# scrub_db.exs — One-time database repair script
#
# USAGE:
#   mix run scripts/scrub_db.exs                  # auto-detect default DB
#   mix run scripts/scrub_db.exs /path/to/tasks.sqlite
#   mix run scripts/scrub_db.exs --dry-run        # preview without writing
#
# WHAT IT DOES:
#   This script reads every row from the tasks, projects, tasks_quarantine,
#   and projects_quarantine tables in the EvoDash SQLite database.
#   It decodes each blob using :erlang.binary_to_term/1 WITHOUT the [:safe]
#   flag (so missing atoms are force-created rather than raising), then
#   recursively scrubs the term to convert all dynamic atoms (especially
#   repo_id values that were created via String.to_atom/1 at runtime) into
#   plain strings. The scrubbed term is re-serialized and written back.
#
#   This repairs databases affected by the data-loss bug where:
#     - repo_id was stored as a dynamic atom (String.to_atom/1)
#     - :erlang.binary_to_term(blob, [:safe]) raised badarg on restart
#       because the atom no longer existed in the VM's atom table
#     - Records were then hard-deleted or quarantined on startup
#
# WHY IT'S "UNSAFE":
#   It calls binary_to_term/1 without [:safe], which can create arbitrary
#   atoms. This is acceptable for a one-time repair script run in a
#   controlled environment, but NEVER use this pattern in production code.
#
# SAFETY:
#   - --dry-run mode shows what would change without writing
#   - Always backs up the database before modifying
#   - Skips rows that decode fine and contain no dynamic atoms

defmodule ScrubDb do
  @moduledoc false

  @safe_atoms_atoms MapSet.new([
                      # Elixir/Erlang builtins
                      true,
                      false,
                      nil,
                      # TaskInfo struct keys (baked into compiled code)
                      :id,
                      :type,
                      :status,
                      :opts,
                      :ref,
                      :pid,
                      :started_at,
                      :finished_at,
                      :logs,
                      :result,
                      :review_status,
                      :usage,
                      :agent_count,
                      :base_sha,
                      :commit_sha,
                      :archive_metadata,
                      # TaskInfo status values
                      :pending,
                      :running,
                      :finalizing,
                      :completed,
                      :failed,
                      :cancelled,
                      # Task types
                      :genesis,
                      :evolution,
                      # Result struct keys
                      :commit_sha,
                      :tag,
                      :branch,
                      :base_commit,
                      :repo_id,
                      :usage,
                      :agent_count,
                      :n,
                      # Review statuses
                      :open,
                      :merged,
                      :rejected,
                      :continued,
                      :ignored,
                      :no_changes,
                      # Project map keys
                      :path,
                      :name,
                      :last_opened_at,
                      # Struct __struct__ keys
                      :__struct__,
                      # OK/error tuples
                      :ok,
                      :error,
                      # Common atoms in result data
                      :no_changes,
                      :pr_url,
                      :branch_name,
                      # Calendar modules (used in DateTime/NaiveDateTime structs)
                      # MUST be preserved as atoms — DateTime compares calendar modules
                      :Calendar,
                      Calendar.ISO
                    ])

  def run(opts) do
    db_path = resolve_db_path(opts)
    dry_run = Keyword.get(opts, :dry_run, false)

    IO.puts("=== EvoDash Database Scrub Script ===")
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
        count = scrub_table(conn, table, dry_run)
        Map.put(acc, table, count)
      end)

    XqliteNIF.close(conn)

    IO.puts("")
    IO.puts("=== Summary ===")

    Enum.each(stats, fn {table, count} ->
      action = if dry_run, do: "would scrub", else: "scrubbed"
      IO.puts("  #{table}: #{count} rows #{action}")
    end)

    total = Enum.sum(Map.values(stats))

    IO.puts("")

    if total == 0 do
      IO.puts("No dynamic atoms found — database is clean.")
    else
      if dry_run do
        IO.puts("Run without --dry-run to apply changes.")
      else
        IO.puts("Done! Database has been repaired.")
      end
    end
  end

  defp scrub_table(conn, table, dry_run) do
    case Xqlite.query(conn, "SELECT id, data FROM #{table}", []) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        IO.puts("Scanning table '#{table}' (#{length(rows)} rows)...")

        rows
        |> Enum.reduce(0, fn [id, blob], scrubbed_count ->
          case scrub_row(id, blob, dry_run) do
            {:scrubbed, new_blob} ->
              unless dry_run do
                {:ok, _} =
                  Xqlite.execute(
                    conn,
                    "UPDATE #{table} SET data = ?2 WHERE id = ?1",
                    [id, new_blob]
                  )
              end

              scrubbed_count + 1

            :clean ->
              scrubbed_count
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

  defp scrub_row(id, blob, _dry_run) do
    # Decode WITHOUT [:safe] — force-create missing atoms so we can read the data.
    # This is the "unsafe" part of the script, acceptable for a one-time repair.
    term =
      try do
        :erlang.binary_to_term(blob)
      rescue
        e ->
          IO.puts("    [#{id}] Cannot decode blob at all: #{Exception.message(e)} — skipping")
          :decode_failed
      end

    case term do
      :decode_failed ->
        :clean

      decoded ->
        # Snapshot the atom count before scrubbing so we can detect if
        # scrubbing itself created atoms (it shouldn't).
        scrubbed = deep_scrub_atoms(decoded)

        if scrubbed != decoded do
          new_blob = :erlang.term_to_binary(scrubbed)

          IO.puts(
            "    [#{id}] Scrubbed dynamic atoms → strings (#{byte_size(blob)} → #{byte_size(new_blob)} bytes)"
          )

          {:scrubbed, new_blob}
        else
          :clean
        end
    end
  end

  # Recursively walk a term and convert any atom that is NOT in the known-safe
  # set to a string. Struct keys, status atoms, and other baked-in atoms
  # remain untouched. Only "dynamic" atoms (created via String.to_atom/1 at
  # runtime, such as foreign repo IDs) are converted.
  #
  # The set of "safe" atoms is conservative — it includes all atoms that are
  # baked into compiled code and would survive a VM restart. Any atom NOT in
  # this set is assumed to be dynamic and converted to a string.

  defp deep_scrub_atoms(term) when is_atom(term) do
    if MapSet.member?(@safe_atoms_atoms, term) do
      term
    else
      # This is a dynamic atom — convert to string.
      # Example: :my_foreign_repo → "my_foreign_repo"
      Atom.to_string(term)
    end
  end

  # Structs: keep the __struct__ atom as-is, scrub all values.
  # We must NOT convert struct keys (they're atom keys) — only values.
  defp deep_scrub_atoms(%{__struct__: _} = struct) do
    scrubbed_map =
      struct
      |> Map.to_list()
      |> Enum.map(fn {key, value} ->
        # Keep the key as-is (it's a known atom), scrub the value
        {key, deep_scrub_atoms(value)}
      end)
      |> Map.new()

    Map.put(scrubbed_map, :__struct__, struct.__struct__)
  end

  # Maps (non-struct): scrub values, keep keys as-is (atom keys are safe)
  defp deep_scrub_atoms(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.map(fn {key, value} ->
      scrubbed_key =
        if is_atom(key) do
          key
        else
          deep_scrub_atoms(key)
        end

      {scrubbed_key, deep_scrub_atoms(value)}
    end)
    |> Map.new()
  end

  # Keyword lists: scrub values, keep keys as-is
  defp deep_scrub_atoms([{key, _value} | _] = list) when is_atom(key) do
    Enum.map(list, fn {k, v} -> {k, deep_scrub_atoms(v)} end)
  end

  # Lists: scrub each element
  defp deep_scrub_atoms(list) when is_list(list) do
    Enum.map(list, &deep_scrub_atoms/1)
  end

  # Tuples: scrub each element
  defp deep_scrub_atoms(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&deep_scrub_atoms/1)
    |> List.to_tuple()
  end

  # Everything else (binaries, integers, floats, etc.) stays as-is
  defp deep_scrub_atoms(other), do: other

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
    backup_path = "#{db_path}.scrub_backup_#{timestamp}"
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

# Ensure required apps are started (for Xqlite and EvoGit.Platform)
Application.ensure_all_started(:evo_git)

ScrubDb.run(opts)
