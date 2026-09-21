defmodule Mix.Tasks.Migrate.Store do
  @moduledoc """
  Standalone upgrade path for an EXISTING EvoGit task database (`tasks.sqlite`).

  `EvoGit.Store.init/1` auto-migrates at boot on every start, running the
  ordered idempotent pipeline `Schema.migrate_schema/1 → Schema.create_tables/1
  → Schema.normalize_timestamps/1 → Schema.canonicalize_results/1 →
  Schema.canonicalize_opts/1`. That pipeline adds missing `tasks` columns
  (including `error` and `updated_at`), normalizes legacy variable-precision
  timestamps, and rewrites non-canonical `result` / `opts` rows.

  This task is the standalone/manual path that runs those same `Schema`
  primitives without booting the application, and ADDITIONALLY backfills
  `branch_name` (from `result.data.branch_name`) and `updated_at` (from
  `finished_at` / `started_at`), and drops the DETS-era quarantine tables
  (`tasks_quarantine`, `projects_quarantine`). Those last three steps are
  task-only and never run at boot.

  The task runs standalone and does NOT start the `:evo_git` application. It
  only uses pure functions (`EvoGit.Platform.data_dir/0`, `EvoGit.Store.Schema.*`,
  `EvoGit.Store.Codec.encode_datetime/1`) and a direct Xqlite connection, so it
  works even when the application cannot boot.

  All steps are idempotent — running the task twice is safe (and is the
  recommended way to verify a database upgrade).

  ## Usage

      mix migrate.store [db_path]

  `db_path` is optional. Defaults to

      Path.join(Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()), "tasks.sqlite")

  ## Steps

  1. Schema: tables + indexes (`Schema.migrate_schema/1` then `Schema.create_tables/1`)
  2. Schema: missing columns (`Schema.migrate_schema/1`)
  3. Schema: timestamp normalization (`Schema.normalize_timestamps/1`)
  4. Result rewrite → strictly canonical (`Schema.canonicalize_results/1`):
     JSON `null` text becomes SQL NULL; every other untagged value (raw strings
     AND untagged JSON objects/arrays/scalars) is wrapped verbatim in
     `{"__result_tag__":"string","value":...}`
  5. Opts rewrite: legacy `[key, value]` pair arrays → JSON objects
     (`Schema.canonicalize_opts/1`)
  6. `branch_name` backfill from `result.data.branch_name`
  7. `updated_at` backfill from `finished_at` / `started_at` / now
  8. Drop DETS-era quarantine tables (`tasks_quarantine`, `projects_quarantine`)

  Steps 1-5 reuse the same `Schema` primitives the boot pipeline runs, so an
  already-booted database reports 0 rows changed; steps 6-8 are the task-only
  extras. Steps 4 and 6 use SQLite's JSON1 functions (`json_valid` etc.) when
  available and fall back to Elixir read-decode-rewrite loops otherwise (step
  4's fallback lives inside `Schema.canonicalize_results/1`). Step 5 always
  uses the Elixir loop so boolean opt values (`archive: true`) round-trip
  exactly instead of becoming SQLite integers (1/0) via `json_group_object`.
  """

  use Mix.Task

  @shortdoc "Migrate an existing task database to the current schema"

  alias EvoGit.Store.{Codec, Schema}

  @impl Mix.Task
  def run(args) do
    db_path = resolve_db_path(args)
    File.mkdir_p!(Path.dirname(db_path))

    Mix.shell().info("==> Migrating task database: #{db_path}")

    {:ok, conn} = open_connection(db_path)

    try do
      json1 = Schema.json1_available?(conn)
      print_json1_status(json1)
      run_steps(conn, json1)
      print_final_schema(conn)
    after
      Xqlite.close(conn)
    end

    Mix.shell().info("Migration complete. Safe to re-run — all steps are idempotent.")
  end

  ## Setup helpers

  defp resolve_db_path([]) do
    data_dir = Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
    Path.join(data_dir, "tasks.sqlite")
  end

  defp resolve_db_path([db_path | _rest]), do: db_path

  # Opens a raw SQLite connection with exactly the same pragmas as
  # `EvoGit.Store.init/1`. The Store GenServer is deliberately NOT started —
  # direct connection only.
  defp open_connection(db_path) do
    case Xqlite.open(db_path, journal_mode: :wal, synchronous: :normal, cache_size: -2000) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        Mix.raise("Failed to open SQLite database #{db_path}: #{inspect(reason)}")
    end
  end

  ## Steps

  defp run_steps(conn, json1) do
    run_step(1, "Schema: tables + indexes", fn -> step1_tables_and_indexes(conn) end)
    run_step(2, "Schema: missing columns", fn -> step2_missing_columns(conn) end)
    run_step(3, "Schema: timestamp normalization", fn -> step3_timestamps(conn) end)
    run_step(4, "Result rewrite → canonical JSON", fn -> step4_result_rewrite(conn) end)
    run_step(5, "Opts rewrite → JSON object", fn -> step5_opts_rewrite(conn) end)
    run_step(6, "branch_name backfill", fn -> step6_branch_name_backfill(conn, json1) end)
    run_step(7, "updated_at backfill", fn -> step7_updated_at_backfill(conn) end)
    run_step(8, "Drop quarantine tables", fn -> step8_drop_quarantine(conn) end)
  end

  defp run_step(number, label, fun) do
    detail = fun.()
    Mix.shell().info("[#{number}/8] #{label} — #{detail}")
  end

  # Step 1: create missing tables + all indexes. `Schema.migrate_schema/1` runs
  # FIRST (a no-op when `tasks` does not exist) so any missing columns are added
  # before `Schema.create_tables/1` — required because the current schema
  # creates an index on `updated_at`, which fails on an old table missing that
  # column. `create_tables/1` uses CREATE INDEX IF NOT EXISTS, so its index
  # statements also run against old databases.
  defp step1_tables_and_indexes(conn) do
    Schema.migrate_schema(conn)
    Schema.create_tables(conn)
    "ok (tables: tasks, projects; indexes: #{length(index_names(conn, "tasks"))})"
  end

  # Step 2: add missing columns (`Schema.migrate_schema/1` covers every column,
  # including `updated_at`).
  defp step2_missing_columns(conn) do
    Schema.migrate_schema(conn)
    "ok (tasks columns: #{length(Schema.existing_columns(conn, "tasks"))})"
  end

  # Step 3: fixed-precision timestamp normalization (idempotent).
  defp step3_timestamps(conn) do
    Schema.normalize_timestamps(conn)
    "ok"
  end

  # Step 4: rewrite every non-canonical `result` row into the strictly
  # canonical format (the codec's `decode_result/1` raises on anything else).
  # Delegates to `Schema.canonicalize_results/1`, which performs the two SQL
  # passes — JSON `null` text → SQL NULL, then every other untagged value
  # (raw strings AND untagged JSON objects/arrays/scalars) wrapped verbatim as
  # `{"__result_tag__":"string","value":<original content>}` — and falls back
  # to an equivalent Elixir read-decode-rewrite loop when JSON1 is unavailable.
  defp step4_result_rewrite(conn) do
    %{nulls: nulls, wraps: wraps} = Schema.canonicalize_results(conn)

    "ok (rows rewritten: #{nulls + wraps})"
  end

  # Step 5: rewrite legacy opts — a JSON array of positional [key, value]
  # pairs — into the current JSON-object format. Delegates to
  # `Schema.canonicalize_opts/1`, which always uses the Elixir
  # read-decode-rewrite loop (never `json_group_object`, which collapses JSON
  # booleans to SQLite integers, corrupting values like `archive: true`).
  defp step5_opts_rewrite(conn) do
    count = Schema.canonicalize_opts(conn)
    "ok (rows rewritten to JSON object: #{count})"
  end

  # Step 6: backfill branch_name from the canonical ok-result shape
  #   {"__result_tag__":"ok","data":{"branch_name": "..."}}
  defp step6_branch_name_backfill(conn, true) do
    count =
      execute_changes(conn, """
        UPDATE tasks SET branch_name = json_extract(result, '$.data.branch_name')
        WHERE branch_name IS NULL
          AND json_valid(result) = 1
          AND json_extract(result, '$.__result_tag__') = 'ok'
      """)

    "ok (rows backfilled: #{count})"
  end

  defp step6_branch_name_backfill(conn, false) do
    {:ok, %{rows: rows}} =
      Xqlite.query(
        conn,
        "SELECT id, result FROM tasks WHERE branch_name IS NULL AND result IS NOT NULL",
        []
      )

    count =
      Enum.reduce(rows, 0, fn [id, result], acc ->
        case Jason.decode(result) do
          {:ok, %{"__result_tag__" => "ok", "data" => %{"branch_name" => name}}}
          when is_binary(name) ->
            {:ok, _} =
              Xqlite.execute(conn, "UPDATE tasks SET branch_name = ?1 WHERE id = ?2", [name, id])

            acc + 1

          _ ->
            acc
        end
      end)

    "ok (rows backfilled via Elixir fallback: #{count})"
  end

  # Step 7: backfill updated_at. The column is guaranteed by step 2; here we
  # only fill NULLs, preferring the real timestamps over "now".
  defp step7_updated_at_backfill(conn) do
    now = Codec.encode_datetime(DateTime.utc_now())

    count =
      execute_changes(
        conn,
        "UPDATE tasks SET updated_at = COALESCE(finished_at, started_at, ?1) WHERE updated_at IS NULL",
        [now]
      )

    "ok (rows backfilled: #{count})"
  end

  # Step 8: drop DETS-era quarantine leftovers. No current code path creates
  # these tables — they only exist in very old databases.
  defp step8_drop_quarantine(conn) do
    execute_changes(conn, "DROP TABLE IF EXISTS tasks_quarantine")
    execute_changes(conn, "DROP TABLE IF EXISTS projects_quarantine")
    "ok"
  end

  ## Summary

  defp print_final_schema(conn) do
    task_cols = Schema.existing_columns(conn, "tasks")
    project_cols = Schema.existing_columns(conn, "projects")
    indexes = index_names(conn, "tasks")

    Mix.shell().info("""
    Final schema state:
      tasks columns (#{length(task_cols)}): #{Enum.join(task_cols, ", ")}
      projects columns (#{length(project_cols)}): #{Enum.join(project_cols, ", ")}
      tasks indexes (#{length(indexes)}): #{Enum.join(indexes, ", ")}
    """)
  end

  ## Small helpers

  defp print_json1_status(true) do
    Mix.shell().info("JSON1 functions: available (json_valid('{}') → 1)")
  end

  defp print_json1_status(false) do
    Mix.shell().info(
      "JSON1 functions: UNAVAILABLE — steps 4/6 use Elixir fallbacks (step 5 always uses Elixir)"
    )
  end

  defp index_names(conn, table) do
    {:ok, %{rows: rows}} = Xqlite.query(conn, "PRAGMA index_list(#{table})", [])
    Enum.map(rows, fn [_seq, name | _] -> name end)
  end

  defp execute_changes(conn, sql, params \\ []) do
    case Xqlite.execute(conn, sql, params) do
      {:ok, %{changes: changes}} -> changes
      {:error, reason} -> Mix.raise("SQLite error:\n  SQL: #{sql}\n  Reason: #{inspect(reason)}")
    end
  end
end
