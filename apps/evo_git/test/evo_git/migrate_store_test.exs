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

  One scenario is not about the migrations at all: the private instance must
  boot with the app's shared DBConnection tuning (`EvoGit.Repo.start_opts/0`)
  rather than Ecto's `@defaults`, captured through the `[:ecto, :repo, :init]`
  telemetry event because the instance is unnamed and stopped again before
  `run/1` returns.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @composite_index_version 20_260_815_000_003
  @covering_index_version 20_260_815_000_004
  @archive_table_version 20_260_815_000_005
  @prune_indexes_version 20_260_815_000_006
  # Ascending, exactly as `schema_migrations` reports it — six contiguous
  # versions, no gaps.
  @migration_versions [
    @baseline_version,
    @normalization_version,
    @composite_index_version,
    @covering_index_version,
    @archive_table_version,
    @prune_indexes_version
  ]

  @migration_count length(@migration_versions)

  # The 19 LIVE `tasks` columns AFTER `20260815000005_task_agent_archives`
  # drops the legacy `archive_metadata` column.
  @live_task_columns ~w(id type status opts started_at finished_at logs result review_status
                        usage agent_count base_sha commit_sha lease_expires_at model_id
                        project_path branch_name error updated_at)

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
    test "applies every shipped migration and reports them by name", %{db_path: path} do
      refute File.exists?(path)

      output = run_task_capturing_output!(path)

      assert output =~ "Applying #{@migration_count} migration(s):"
      assert output =~ "20260815000001_baseline_adoption"
      assert output =~ "20260815000002_data_normalization"
      assert output =~ "20260815000003_composite_indexes"
      assert output =~ "20260815000004_covering_indexes"
      assert output =~ "20260815000005_task_agent_archives"
      assert output =~ "20260815000006_prune_redundant_indexes"
      # The four retired modules (unpack compressed rows / create / move /
      # normalize the archive table) ship no version at all any more.
      refute output =~ "20260815000007"

      assert output =~ "Database is now current (#{@migration_count} migration(s) applied)."

      # Every version is stamped and the canonical tables exist (`tasks` ends at
      # its 19 live columns — the archive column is gone).
      assert migration_versions(path) == @migration_versions

      assert Enum.sort(table_names(path)) ==
               ["projects", "schema_migrations", "task_agent_archives", "tasks"]

      assert Enum.sort(columns(path)) == Enum.sort(@live_task_columns)
      assert "error" in columns(path)
      assert "updated_at" in columns(path)
    end
  end

  describe "already-current database" do
    test "reports no pending migrations and changes nothing", %{db_path: path} do
      run_task!(path)

      output = run_task_capturing_output!(path)

      assert output =~
               "Database is already current — no pending migrations (#{@migration_count} applied)."

      refute output =~ "Applying"
      assert migration_versions(path) == @migration_versions
    end
  end

  describe "legacy pre-Ecto database" do
    test "adopts the 19-column table, stamps every version, and runs the data normalization",
         %{db_path: path} do
      build_legacy_db!(path, @ddl_19_col, seed: :legacy)

      output = run_task_capturing_output!(path)
      assert output =~ "Applying #{@migration_count} migration(s):"

      # Adoption: `error` appended (SQLite ALTERs append at the tail), then the
      # archive migration drops `archive_metadata` → the 19 live columns, with
      # every version stamped.
      cols = columns(path)
      assert Enum.sort(cols) == Enum.sort(@live_task_columns)
      assert "error" in cols
      assert "updated_at" in cols
      refute "archive_metadata" in cols
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
      assert Enum.sort(columns(path)) == Enum.sort(@live_task_columns)
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
             end) == [[@migration_count]]
    end
  end

  describe "private repo instance" do
    test "boots with the app's shared DBConnection start opts", %{db_path: path} do
      opts = capture_repo_init_opts!(path, fn -> run_task!(path) end)

      # The shared runtime tuning must arrive as START OPTS: Ecto's own
      # `@defaults` (`timeout: 15_000`, ...) are passed as start opts on every
      # `start_link/1` and win over `EvoGit.Repo.defaults/0` (see the
      # `EvoGit.Repo` moduledoc), so omitting the merge here would silently
      # restore the 15 s statement budget for the migration run.
      for {key, value} <- EvoGit.Repo.start_opts() do
        assert opts[key] == value
      end

      # The per-instance keys are merged OVER that shared list.
      assert opts[:pool_size] == 1
      assert opts[:name] == nil
      assert opts[:database] == Path.expand(path)
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

  # The task's private repo instance is UNNAMED and stopped before `run/1`
  # returns, so its effective configuration is only observable while it
  # starts: `Ecto.Repo.Supervisor` emits `[:ecto, :repo, :init]` (with the
  # resolved config in `metadata.opts`) from the repo's OWN supervisor
  # process, before the adapter boots.
  #
  # The handler table is BEAM-wide and sibling `async: true` suites boot their
  # own `EvoGit.Repo` instances, so the capture filters on the repo module AND
  # this test's unique database path. The event's `opts` carry `:name` and
  # `:database` as passed by the caller, so `Path.expand/1` is applied here
  # exactly like the task does.
  defp capture_repo_init_opts!(path, fun) do
    test_pid = self()
    database = Path.expand(path)
    handler_id = {__MODULE__, :repo_init, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:ecto, :repo, :init],
      fn _event, _measurements, metadata, _config ->
        if metadata.repo == EvoGit.Repo and metadata.opts[:database] == database do
          send(test_pid, {:repo_init_opts, metadata.opts})
        end
      end,
      nil
    )

    try do
      fun.()

      receive do
        {:repo_init_opts, opts} ->
          opts
      after
        1_000 ->
          flunk(
            "expected a [:ecto, :repo, :init] event for #{inspect(EvoGit.Repo)} " <>
              "on #{database}, captured none"
          )
      end
    after
      :telemetry.detach(handler_id)
    end
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
