defmodule Mix.Tasks.Migrate.Store do
  @moduledoc """
  One-time manual migration for EXISTING EvoGit task databases (`tasks.sqlite`).

  The project has not publicly released, so there are no in-place/automatic
  migrations — `EvoGit.Store.init/1` does not auto-migrate legacy data. This
  task is the manual upgrade path for databases written by older builds.
  Fresh databases need nothing: `EvoGit.Store.Schema.create_tables/1` creates
  the full schema, and every step below is a no-op on them.

  All steps are idempotent — running the task twice is safe (and is the
  recommended way to verify a migration).

  ## Usage

      mix migrate.store [db_path]

  `db_path` is optional. Defaults to

      Path.join(Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()), "tasks.sqlite")

  ## Steps

  1. Schema: tables + indexes (`Schema.create_tables/1`)
  2. Schema: missing columns (`Schema.migrate_schema/1`, plus an `updated_at`
     column guarantee for old databases)
  3. Schema: timestamp normalization (`Schema.normalize_timestamps/1`)
  4. Result rewrite → canonical JSON (`{"__result_tag__":"string","value":...}`)
  5. Opts rewrite: legacy `[key, value]` pair arrays → JSON objects
  6. `branch_name` backfill from `result.data.branch_name`
  7. `updated_at` backfill from `finished_at` / `started_at` / now
  8. Drop DETS-era quarantine tables (`tasks_quarantine`, `projects_quarantine`)

  Steps 4 and 6 use SQLite's JSON1 functions (`json_valid` etc.). If JSON1 is
  unavailable at runtime, the task falls back to equivalent Elixir
  read-decode-rewrite loops and says so in its output. Step 5 always uses the
  Elixir loop so boolean opt values (`archive: true`) round-trip exactly
  instead of becoming SQLite integers (1/0) via `json_group_object`.
  """

  use Mix.Task

  @shortdoc "Migrate an existing task database to the current schema"

  alias EvoGit.Store.{Codec, Schema}

  @impl Mix.Task
  def run(args) do
    ensure_app_started!()

    db_path = resolve_db_path(args)
    File.mkdir_p!(Path.dirname(db_path))

    Mix.shell().info("==> Migrating task database: #{db_path}")

    {:ok, conn} = open_connection(db_path)

    try do
      json1 = json1_available?(conn)
      print_json1_status(json1)
      run_steps(conn, json1)
      print_final_schema(conn)
    after
      Xqlite.close(conn)
    end

    Mix.shell().info("Migration complete. Safe to re-run — all steps are idempotent.")
  end

  ## Setup helpers

  # Loads the :evo_git application so its application env (e.g. a configured
  # :data_dir) is available for path resolution. No-op when the app is already
  # started (e.g. under `mix test`). Precedent: bump.version.ex runs plain
  # Mix.Task code with no app loading — but this task resolves the store path
  # through the app env, so the app must at least be loaded.
  defp ensure_app_started! do
    case Application.ensure_all_started(:evo_git) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start the :evo_git application: #{inspect(reason)}")
    end
  end

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
    run_step(4, "Result rewrite → canonical JSON", fn -> step4_result_rewrite(conn, json1) end)
    run_step(5, "Opts rewrite → JSON object", fn -> step5_opts_rewrite(conn) end)
    run_step(6, "branch_name backfill", fn -> step6_branch_name_backfill(conn, json1) end)
    run_step(7, "updated_at backfill", fn -> step7_updated_at_backfill(conn) end)
    run_step(8, "Drop quarantine tables", fn -> step8_drop_quarantine(conn) end)
  end

  defp run_step(number, label, fun) do
    detail = fun.()
    Mix.shell().info("[#{number}/8] #{label} — #{detail}")
  end

  # Step 1: create missing tables + all indexes. `create_tables/1` uses
  # CREATE INDEX IF NOT EXISTS, so its index statements also run against old
  # databases — including (in the current schema) indexes on `updated_at`.
  # On an EXISTING database the `updated_at` column may not exist yet, and
  # CREATE INDEX on a missing column fails, so columns are migrated FIRST for
  # old databases (idempotent — this is exactly what step 2 would do).
  defp step1_tables_and_indexes(conn) do
    if table_exists?(conn, "tasks") do
      Schema.migrate_schema(conn)
      ensure_updated_at_column!(conn)
    end

    Schema.create_tables(conn)
    "ok (tables: tasks, projects; indexes: #{length(index_names(conn, "tasks"))})"
  end

  # Step 2: add missing columns. The `updated_at` clause lives in the current
  # `Schema.migrate_schema/1`; the explicit `ensure_updated_at_column!` is a
  # defensive fallback so this task also works against a schema that predates
  # that clause.
  defp step2_missing_columns(conn) do
    Schema.migrate_schema(conn)
    ensure_updated_at_column!(conn)
    "ok (tasks columns: #{length(Schema.existing_columns(conn, "tasks"))})"
  end

  # Step 3: fixed-precision timestamp normalization (idempotent).
  defp step3_timestamps(conn) do
    Schema.normalize_timestamps(conn)
    "ok"
  end

  # Step 4: rewrite raw/plain-string `result` rows into canonical tagged JSON:
  #   {"__result_tag__":"string","value":<original content>}
  #
  # Two SQL passes (JSON1 path):
  #   4a. rows whose value is NOT valid JSON (plain crash-fallback strings),
  #   4b. rows whose value IS valid JSON but is a scalar (a quoted string, a
  #       number, true/false) — these are also raw-string rows that happen to
  #       be well-formed JSON text.
  #
  # `json_object/3` always converts its TEXT value argument into a JSON string
  # (verified against the bundled SQLite: even well-formed JSON text like
  # `'42'` becomes `"value":"42"`), which is exactly what we want: the raw
  # string content round-trips verbatim and matches what the current codec
  # would write for the same input. Untagged JSON objects/arrays are left
  # alone — the defensive decode branch handles them.
  defp step4_result_rewrite(conn, true) do
    raw_non_json =
      execute_changes(conn, """
        UPDATE tasks SET result = json_object('__result_tag__','string','value',result)
        WHERE json_valid(result) = 0
      """)

    scalar_json =
      execute_changes(conn, """
        UPDATE tasks SET result = json_object('__result_tag__','string','value',result)
        WHERE json_valid(result) = 1
          AND json_type(result) IN ('text','integer','real','true','false')
          AND json_extract(result,'$.__result_tag__') IS NULL
      """)

    "ok (rows rewritten: #{raw_non_json + scalar_json})"
  end

  # JSON1-unavailable fallback: read → decode → rewrite in Elixir. Wraps the
  # same rows the SQL path would (skips tagged objects, untagged objects and
  # arrays, and JSON null — consistent with the SQL guards).
  defp step4_result_rewrite(conn, false) do
    {:ok, %{rows: rows}} =
      Xqlite.query(conn, "SELECT id, result FROM tasks WHERE result IS NOT NULL", [])

    count =
      Enum.reduce(rows, 0, fn [id, result], acc ->
        if needs_result_wrap?(result) do
          wrapped = Jason.encode!(%{"__result_tag__" => "string", "value" => result})

          {:ok, _} =
            Xqlite.execute(conn, "UPDATE tasks SET result = ?1 WHERE id = ?2", [wrapped, id])

          acc + 1
        else
          acc
        end
      end)

    "ok (rows rewritten via Elixir fallback: #{count})"
  end

  defp needs_result_wrap?(result) do
    case Jason.decode(result) do
      {:ok, %{"__result_tag__" => _}} -> false
      {:ok, value} when is_map(value) or is_list(value) -> false
      {:ok, nil} -> false
      _ -> true
    end
  end

  # Step 5: rewrite legacy opts — a JSON array of positional [key, value]
  # pairs — into the current JSON-object format. Done in Elixir (never SQL):
  # `json_group_object` collapses JSON booleans to SQLite integers (1/0),
  # corrupting values like `archive: true`, while the read-decode-rewrite loop
  # below is byte-identical to what the current codec writes today.
  defp step5_opts_rewrite(conn) do
    {:ok, %{rows: rows}} =
      Xqlite.query(conn, "SELECT id, opts FROM tasks WHERE opts IS NOT NULL", [])

    count =
      Enum.reduce(rows, 0, fn [id, opts], acc ->
        case Jason.decode(opts) do
          # Legacy format: a JSON array of [key, value] pair arrays. Guard that
          # every element is a 2-element list first — `Codec.decode_opts`
          # pattern-matches `[key, value]` per element and would RAISE on a
          # malformed row.
          {:ok, pairs} when is_list(pairs) ->
            if Enum.all?(pairs, &(is_list(&1) and length(&1) == 2)) do
              case Codec.decode_opts(opts) do
                nil ->
                  acc

                decoded ->
                  case Codec.encode_opts(decoded) do
                    new_opts when is_binary(new_opts) ->
                      {:ok, _} =
                        Xqlite.execute(conn, "UPDATE tasks SET opts = ?1 WHERE id = ?2", [
                          new_opts,
                          id
                        ])

                      acc + 1

                    # Codec gave up (non-serializable data) — leave the row alone.
                    _ ->
                      acc
                  end
              end
            else
              # Malformed legacy row — leave alone.
              acc
            end

          # Already an object (or undecodable) — leave alone.
          _ ->
            acc
        end
      end)

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

  defp json1_available?(conn) do
    case Xqlite.query(conn, "SELECT json_valid('{}')", []) do
      {:ok, %{rows: [[1] | _]}} -> true
      _ -> false
    end
  end

  defp print_json1_status(true) do
    Mix.shell().info("JSON1 functions: available (json_valid('{}') → 1)")
  end

  defp print_json1_status(false) do
    Mix.shell().info(
      "JSON1 functions: UNAVAILABLE — steps 4/6 use Elixir fallbacks (step 5 always uses Elixir)"
    )
  end

  defp table_exists?(conn, table) do
    {:ok, %{rows: rows}} =
      Xqlite.query(conn, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1", [
        table
      ])

    rows != []
  end

  # Idempotent guard: mirrors the `updated_at` clause of the current
  # `Schema.migrate_schema/1` so the task is self-sufficient even when run
  # against a schema that predates that clause.
  defp ensure_updated_at_column!(conn) do
    if "updated_at" not in Schema.existing_columns(conn, "tasks") do
      {:ok, _} = Xqlite.execute(conn, "ALTER TABLE tasks ADD COLUMN updated_at TEXT", [])
    end
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
