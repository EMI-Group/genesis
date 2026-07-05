defmodule Mix.Tasks.MigrateTaskPids do
  @shortdoc "Migrate tasks table: drop legacy pid column (dry-run by default)"

  @requirements ["app.config"]

  @moduledoc """
  One-time database migration: drops the legacy `pid` column from the
  EvoDash `tasks` SQLite table.

  ## Modes

  This task runs in **dry-run mode by default**. In dry-run mode it:

  1. Copies the real database file (and any `-wal` / `-shm` sidecar files)
     to a temporary location.
  2. Opens a *separate* connection to the copy.
  3. Runs the full migration against the copy (check for `pid` column,
     count non-null rows, `ALTER TABLE ... DROP COLUMN pid`).
  4. Validates the copy's schema after migration.
  5. Reports what *would* happen, then deletes the temporary copy.

  The real database is **never touched** in dry-run mode.

  To apply the migration against the real database, pass `--apply`.
  This is destructive and should only be run after a successful dry-run.

  ## Usage

      # Dry-run (default) — safe, validates against a copy
      mix migrate_task_pids

      # Apply — modifies the REAL database
      mix migrate_task_pids --apply
  """

  use Mix.Task

  @table "tasks"
  @column "pid"

  @impl Mix.Task
  def run(argv) do
    # We do NOT call Application.ensure_all_started(:evo_dash) here because
    # that would start the full EvoDash supervision tree (Store, TaskRegistry,
    # Endpoint), which is unnecessary and could interfere with a live system.
    # The @requirements ["app.config"] above ensures Application config is
    # loaded. XqliteNIF is a NIF module that loads on first reference — no
    # app start needed.
    {opts, _remaining, _invalid} =
      OptionParser.parse(argv, switches: [apply: :boolean])

    apply? = opts[:apply] || false
    db_path = resolve_db_path()

    if apply? do
      Mix.shell().error(
        "\n⚠️  APPLY MODE — this will modify the REAL database at:\n" <>
          "    #{db_path}\n" <>
          "    The legacy '#{@column}' column will be permanently dropped.\n"
      )

      unless Mix.shell().yes?("Proceed with the real migration?") do
        Mix.shell().info("Aborted.")
        :ok
      else
        run_migration(db_path, label: "REAL DATABASE")
      end
    else
      run_dry_run(db_path)
    end
  end

  # --------------------------------------------------------------------------
  # Dry-run orchestration
  # --------------------------------------------------------------------------

  defp run_dry_run(source_db_path) do
    Mix.shell().info("\n🔍 DRY-RUN MODE — the real database will NOT be modified.\n")

    unless File.exists?(source_db_path) do
      Mix.shell().error(
        "Source database not found: #{source_db_path}\n" <>
          "Nothing to migrate (the database may not have been created yet)."
      )

      :ok
    else
      # Copy the DB to a temp location, including -wal / -shm sidecars.
      tmp_path = make_temp_copy(source_db_path)

      try do
        Mix.shell().info("📋 Source DB : #{source_db_path}")
        Mix.shell().info("📋 Temp copy : #{tmp_path}")
        run_migration(tmp_path, label: "TEMP COPY (dry-run)")
      after
        cleanup_temp_copy(tmp_path)
        Mix.shell().info("\n🧹 Cleaned up temp copy.")
      end
    end
  end

  # Copies `source` to a unique temp path. Also copies `-wal` and `-shm`
  # sidecar files if they exist (WAL mode produces these alongside the
  # main database file; they may contain uncommitted/checkpointed data).
  defp make_temp_copy(source) do
    suffix = :erlang.unique_integer([:positive]) |> Integer.to_string()
    tmp_path = Path.join(System.tmp_dir!(), "migrate_pid_dryrun_#{suffix}.sqlite")

    File.cp!(source, tmp_path)

    # Copy WAL and SHM sidecar files if present.
    for ext <- ["-wal", "-shm"] do
      sidecar = source <> ext

      if File.exists?(sidecar) do
        File.cp!(sidecar, tmp_path <> ext)
      end
    end

    tmp_path
  end

  defp cleanup_temp_copy(tmp_path) do
    File.rm(tmp_path)

    for ext <- ["-wal", "-shm"] do
      File.rm(tmp_path <> ext)
    end

    :ok
  end

  # --------------------------------------------------------------------------
  # Core migration logic (shared by dry-run and apply)
  # --------------------------------------------------------------------------

  # Runs the migration against the database at `db_path`.
  # `label` is used in log output to distinguish "TEMP COPY" vs "REAL DATABASE".
  defp run_migration(db_path, opts) do
    label = Keyword.fetch!(opts, :label)

    case XqliteNIF.open(db_path) do
      {:ok, conn} ->
        try do
          do_migration(conn, label)
        after
          XqliteNIF.close(conn)
        end

      {:error, reason} ->
        Mix.shell().error("[#{label}] Failed to open database: #{inspect(reason)}")
        {:error, :open_failed}
    end
  end

  defp do_migration(conn, label) do
    columns = existing_columns(conn)

    if @column in columns do
      Mix.shell().info("[#{label}] Column '#{@column}' found in '#{@table}' table.")

      # Count rows with a non-null pid value (for reporting).
      non_null_count = count_non_null_pid(conn)

      Mix.shell().info("[#{label}] Rows with non-null '#{@column}' value: #{non_null_count}")

      # Execute the DROP COLUMN.
      case XqliteNIF.execute(conn, "ALTER TABLE #{@table} DROP COLUMN #{@column}", []) do
        {:ok, _} ->
          Mix.shell().info("[#{label}] ✅ ALTER TABLE ... DROP COLUMN #{@column} succeeded.")

          # Validate: confirm the column is actually gone.
          case validate_column_dropped(conn) do
            :ok ->
              Mix.shell().info("[#{label}] ✅ Validation passed: '#{@column}' column is gone.")
              print_summary(label, true, non_null_count, :ok)
              :ok

            {:error, _} = err ->
              Mix.shell().error(
                "[#{label}] ❌ Validation FAILED: '#{@column}' column still present!"
              )

              print_summary(label, true, non_null_count, err)
              err
          end

        {:error, reason} ->
          Mix.shell().error("[#{label}] ❌ ALTER TABLE DROP COLUMN failed: #{inspect(reason)}")

          print_summary(label, true, non_null_count, {:error, :drop_failed})
          {:error, {:drop_failed, reason}}
      end
    else
      Mix.shell().info(
        "[#{label}] Column '#{@column}' not found — already migrated, nothing to do."
      )

      print_summary(label, false, 0, :ok)
      :ok
    end
  end

  # --------------------------------------------------------------------------
  # SQLite query helpers
  # --------------------------------------------------------------------------

  defp existing_columns(conn) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(#{@table})", [])

    # PRAGMA table_info returns rows of [cid, name, type, notnull, dflt_value, pk]
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  defp count_non_null_pid(conn) do
    case XqliteNIF.query(conn, "SELECT COUNT(*) FROM #{@table} WHERE #{@column} IS NOT NULL", []) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp validate_column_dropped(conn) do
    columns = existing_columns(conn)

    if @column in columns do
      {:error, :column_still_present}
    else
      :ok
    end
  end

  # --------------------------------------------------------------------------
  # Reporting
  # --------------------------------------------------------------------------

  defp print_summary(label, column_found, non_null_count, validation) do
    Mix.shell().info("""

    ────────────────────────────────────────────────
    Migration Summary [#{label}]
    ────────────────────────────────────────────────
    Column '#{@column}' found     : #{column_found}
    Rows with non-null '#{@column}': #{non_null_count}
    DROP COLUMN result            : #{format_drop_result(validation)}
    Post-migration validation     : #{format_validation(validation)}
    ────────────────────────────────────────────────
    """)
  end

  defp format_drop_result(:ok), do: "success"
  defp format_drop_result({:error, _}), do: "FAILED"

  defp format_validation(:ok), do: "PASSED ✅"
  defp format_validation({:error, reason}), do: "FAILED ❌ (#{inspect(reason)})"

  # --------------------------------------------------------------------------
  # Database path resolution
  # --------------------------------------------------------------------------

  # Resolves the path to the EvoDash tasks SQLite database.
  # Mirrors the logic in EvoDash.Application.start/2:
  #   data_dir = Application.get_env(:evo_dash, :data_dir, EvoGit.Platform.data_dir())
  #   Store is started with data_dir: Path.join(data_dir, "tasks.sqlite")
  defp resolve_db_path do
    data_dir = Application.get_env(:evo_dash, :data_dir, EvoGit.Platform.data_dir())
    Path.join(data_dir, "tasks.sqlite")
  end
end
