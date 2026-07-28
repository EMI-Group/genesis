defmodule Mix.Tasks.MigrateBackfillTaskColumns do
  @shortdoc "Backfill project_path and branch_name columns from JSON data"

  @requirements ["app.config"]

  @moduledoc """
  Manually backfills the `project_path` and `branch_name` columns in the
  tasks SQLite table from the existing `opts` and `result` JSON columns.

  This is non-destructive — it only fills rows where the target column is
  NULL. Rows already backfilled (e.g. by a prior run) are skipped.

  ## What it does

  1. Opens the tasks SQLite database directly (no app start required).
  2. Ensures both `project_path` and `branch_name` columns exist (idempotent
     `ALTER TABLE ADD COLUMN` if missing).
  3. Calls `EvoGit.Store.backfill_project_path/1` and
     `EvoGit.Store.backfill_branch_name/1`.
  4. Reports the number of rows backfilled.
  5. Closes the connection cleanly.

  ## Usage

      mix migrate_backfill_task_columns
  """

  use Mix.Task

  @table "tasks"

  @impl Mix.Task
  def run(argv) do
    # No arguments expected; ignore any extras silently to match the
    # convention of simple one-shot tasks.
    _argv = argv

    db_path = resolve_db_path()

    Mix.shell().info("Database: #{db_path}")
    Mix.shell().info("Ensuring project_path and branch_name columns exist...")

    case XqliteNIF.open(db_path) do
      {:ok, conn} ->
        # Justified try/after — resource cleanup. Ensures the SQLite connection
        # is always closed. No rescue needed because errors should propagate
        # to the caller.
        try do
          ensure_column(conn, "project_path", "TEXT")
          ensure_column(conn, "branch_name", "TEXT")

          Mix.shell().info("Running backfill_project_path...")
          EvoGit.Store.backfill_project_path(conn)

          Mix.shell().info("Running backfill_branch_name...")
          EvoGit.Store.backfill_branch_name(conn)

          Mix.shell().info("Backfill complete.")
        after
          XqliteNIF.close(conn)
        end

      {:error, reason} ->
        Mix.shell().error("Failed to open database: #{inspect(reason)}")
        {:error, :open_failed}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp resolve_db_path do
    data_dir = Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    Path.join(data_dir, "tasks.sqlite")
  end

  defp existing_columns(conn) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(#{@table})", [])

    # PRAGMA table_info returns rows of [cid, name, type, notnull, dflt_value, pk]
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  defp ensure_column(conn, name, type) do
    columns = existing_columns(conn)

    if name in columns do
      Mix.shell().info("  Column '#{name}' already exists — skipping ALTER TABLE.")
    else
      Mix.shell().info("  Adding column '#{name}'...")
      {:ok, _} = XqliteNIF.execute(conn, "ALTER TABLE #{@table} ADD COLUMN #{name} #{type}", [])
      Mix.shell().info("  Column '#{name}' added.")
    end
  end
end
