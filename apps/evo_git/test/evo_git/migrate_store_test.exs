defmodule EvoGit.MigrateStoreTest do
  @moduledoc """
  Tests for `Mix.Tasks.Migrate.Store` — the thin `Ecto.Migrator` wrapper
  around the store boot migrations.

  The task is invoked DIRECTLY (`Mix.Tasks.Migrate.Store.run([db_path])`):
  it boots its own private UNNAMED dynamic `EvoGit.Repo` instance, runs
  `EvoGit.Store.Boot.run_migrations/1`, and stops the instance again. Every
  assertion goes through RAW xqlite connections (or `Codec.decode_*`
  round-trips) against the private temp DB, so the task's own connection
  semantics are what is exercised.

  The scenarios mirror the boot-migration suites' fixtures: a fresh
  (nonexistent) path, an already-current DB, and legacy pre-Ecto DBs (no
  `schema_migrations` table) that the task must adopt. The migrations' own
  content (adoption DDL, data rewrites) is covered by
  `store/boot_migration_test.exs` + `store/boot_normalization_test.exs` —
  this suite pins only the TASK's behavior around them.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @migration_versions [@baseline_version, @normalization_version]

  # The v0.9.0–v0.12.5 "reported crash-on-upgrade" shape: `updated_at` is the
  # 19th column and `error` does not exist yet — the canonical legacy DB a
  # real user brings to the task. No `schema_migrations` table.
  @ddl_19_col """
  CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    type TEXT,
    status TEXT NOT NULL,
    opts TEXT,
    started_at TEXT,
    finished_at TEXT,
    logs TEXT,
    result TEXT,
    review_status TEXT,
    usage TEXT,
    agent_count INTEGER,
    base_sha TEXT,
    commit_sha TEXT,
    archive_metadata TEXT,
    lease_expires_at INTEGER,
    model_id TEXT,
    project_path TEXT,
    branch_name TEXT,
    updated_at TEXT
  )
  """

  # What the OLD raw-SQL pipeline left that 19-column DB as: `error` appended
  # at the END (SQLite ALTERs can only append) — 20 columns, non-canonical
  # tail order, still no `schema_migrations` table. The exact file a user
  # copies between machines before ever booting the new release.
  @ddl_19_col_old_pipeline """
  CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    type TEXT,
    status TEXT NOT NULL,
    opts TEXT,
    started_at TEXT,
    finished_at TEXT,
    logs TEXT,
    result TEXT,
    review_status TEXT,
    usage TEXT,
    agent_count INTEGER,
    base_sha TEXT,
    commit_sha TEXT,
    archive_metadata TEXT,
    lease_expires_at INTEGER,
    model_id TEXT,
    project_path TEXT,
    branch_name TEXT,
    updated_at TEXT,
    error TEXT
  )
  """

  @projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Belt-and-suspenders: the task's DEFAULT path resolution reads the
    # :evo_git :data_dir app env, and every test here passes an explicit
    # db_path argument — but pin the guard so a future refactor that
    # accidentally exercises the default can never touch the real DB.
    assert is_binary(Application.get_env(:evo_git, :data_dir))

    {:ok, %{db_path: Path.join(tmp_dir, "tasks.sqlite")}}
  end

  ## Tests

  describe "fresh database (nonexistent path)" do
    test "applies both migrations and reports them by name", %{db_path: path} do
      refute File.exists?(path)

      output = run_task_capturing_output!(path)

      assert output =~ "Applying 2 migration(s):"
      assert output =~ "20260815000001_baseline_adoption"
      assert output =~ "20260815000002_data_normalization"
      assert output =~ "Database is now current (2 migration(s) applied)."

      # Both versions are stamped and the canonical tables exist.
      assert migration_versions(path) == @migration_versions
      assert Enum.sort(table_names(path)) == ["projects", "schema_migrations", "tasks"]
      assert "error" in columns(path)
      assert "updated_at" in columns(path)
    end
  end

  describe "already-current database" do
    test "reports no pending migrations and changes nothing", %{db_path: path} do
      run_task!(path)

      output = run_task_capturing_output!(path)

      assert output =~ "Database is already current — no pending migrations (2 applied)."
      refute output =~ "Applying"
      assert migration_versions(path) == @migration_versions
    end
  end

  describe "legacy pre-Ecto database" do
    test "adopts the 19-column table, stamps both versions, and runs the data normalization",
         %{db_path: path} do
      build_legacy_db!(path, @ddl_19_col, seed: :legacy)

      output = run_task_capturing_output!(path)
      assert output =~ "Applying 2 migration(s):"

      # Adoption: `error` appended (SQLite ALTERs append at the tail), the
      # full 20-column set, versions stamped.
      cols = columns(path)
      assert length(cols) == 20
      assert "error" in cols
      assert "updated_at" in cols
      assert migration_versions(path) == @migration_versions

      # Data normalization ran through the same migrations: the seeded
      # legacy row was rewritten to the canonical shapes (untagged string
      # result wrapped, legacy pair-array opts → JSON object).
      assert [%{opts: opts, result: result, branch_name: branch}] = task_rows(path)
      assert opts == ~s({"path":"/tmp/p"})
      assert Codec.decode_opts(opts) == [path: "/tmp/p"]
      assert result == ~s({"__result_tag__":"string","value":"boom"})
      assert Codec.decode_result(result) == "boom"
      assert branch == nil
    end

    test "adopts the old-pipeline 20-column shape (error appended after updated_at)",
         %{db_path: path} do
      build_legacy_db!(path, @ddl_19_col_old_pipeline, seed: :legacy)

      run_task!(path)

      assert migration_versions(path) == @migration_versions
      assert length(columns(path)) == 20
    end
  end

  describe "repo lifecycle" do
    test "stops its dynamic repo instance and restores the caller's repo binding", %{
      db_path: path
    } do
      run_task!(path)

      # No dynamic-repo binding leaked into the caller: the task binds its
      # private instance (migration run + status report) and always restores
      # the previous binding, so a later repo call in this process still
      # addresses the canonical instance (`get_dynamic_repo/0` falls back to
      # the repo module itself when no binding is set).
      assert EvoGit.Repo.get_dynamic_repo() == EvoGit.Repo

      # The database file is fully released — a fresh dynamic instance boots
      # against it with no interference from a leftover connection.
      {:ok, pid} = Boot.start_dynamic(path)
      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)

      assert RepoScope.with_repo(pid, fn ->
               EvoGit.Repo.query!("SELECT COUNT(*) FROM schema_migrations").rows
             end) == [[2]]
    end
  end

  ## Helpers

  # --- raw Xqlite helpers (never touch the running EvoGit.Store) ---

  defp open_conn!(path) do
    {:ok, conn} = Xqlite.open(path)
    conn
  end

  defp close_conn!(conn), do: :ok = XqliteNIF.close(conn)

  # The task prints its report via `Mix.shell().info/1`. That output is
  # intentional for the `mix migrate.store` CLI, so here we capture stdout
  # instead of polluting the test console. `with_io/1` returns
  # `{result, output}`.
  defp run_task!(path) do
    {result, _io} = with_io(fn -> Mix.Tasks.Migrate.Store.run([path]) end)
    assert result == :ok
  end

  defp run_task_capturing_output!(path) do
    {result, io} = with_io(fn -> Mix.Tasks.Migrate.Store.run([path]) end)
    assert result == :ok
    io
  end

  defp columns(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "PRAGMA table_info(tasks)", [])

    close_conn!(conn)
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  defp table_names(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT name FROM sqlite_master WHERE type = 'table'", [])

    close_conn!(conn)
    Enum.map(rows, fn [name] -> name end)
  end

  defp migration_versions(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT version FROM schema_migrations ORDER BY version", [])

    close_conn!(conn)
    Enum.map(rows, fn [version] -> version end)
  end

  defp task_rows(path) do
    conn = open_conn!(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT opts, result, branch_name FROM tasks ORDER BY id", [])

    close_conn!(conn)

    Enum.map(rows, fn [opts, result, branch_name] ->
      %{opts: opts, result: result, branch_name: branch_name}
    end)
  end

  # --- legacy DB builder ---

  # Crafts a historical DB with RAW xqlite (never the repo): `ddl` is
  # executed verbatim, the projects table is created, and `seed: :legacy`
  # inserts one row exercising the data normalization (legacy pair-array
  # opts, untagged plain-string result, variable-precision timestamp). The
  # seed columns are read back from the freshly created table via
  # `PRAGMA table_info` — no DDL text parsing.
  defp build_legacy_db!(path, ddl, opts) do
    conn = open_conn!(path)

    {:ok, _} = XqliteNIF.execute(conn, ddl, [])
    {:ok, _} = XqliteNIF.execute(conn, @projects_ddl, [])

    if opts[:seed] == :legacy do
      seed_columns =
        conn |> table_columns!("tasks") |> Enum.reject(&(&1 in ~w(id status)))

      values =
        for column <- seed_columns do
          case column do
            "type" -> "genesis"
            "opts" -> ~s([["path","/tmp/p"]])
            "started_at" -> "2024-01-01T12:00:00Z"
            "finished_at" -> "2024-01-01T13:00:00Z"
            "result" -> "boom"
            _other -> nil
          end
        end

      n = length(values)
      # Placeholders continue AFTER id (?1) and status (?2).
      placeholders = Enum.map_join(3..(n + 2), ", ", &"?#{&1}")

      sql =
        "INSERT INTO tasks (id, status, #{Enum.join(seed_columns, ", ")}) VALUES (?1, ?2, #{placeholders})"

      {:ok, _} = XqliteNIF.execute(conn, sql, ["legacy-1", "completed" | values])
    end

    close_conn!(conn)
    :ok
  end

  defp table_columns!(conn, table) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(#{table})", [])
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end
end
