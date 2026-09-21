defmodule EvoGit.Store.BootMigrationTest do
  @moduledoc """
  Schema-ADOPTION coverage for `EvoGit.Store.Boot.start_dynamic/1` — the Ecto
  migrations that replace the raw-SQL `EvoGit.Store.Schema` repair pipeline
  (whose tests live in `store_schema_migration_test.exs`).

  Every legacy fixture is crafted with RAW xqlite (never the repo), exactly the
  way a pre-Ecto release left the file on disk: a `tasks` table in a historical
  DDL shape, NO `schema_migrations` table, optionally a seeded row. `Boot`
  then runs `Ecto.Migrator` (`all: true`), which sees version 0 and executes
  `20260815000001_baseline_adoption` against the legacy file.

  ## Pinned behaviors (per scenario)

    * fresh (nonexistent) path → the exact 20-column `tasks` table + both
      migration versions stamped in `schema_migrations`
    * a current 20-column table without `schema_migrations` → adopted; the
      seeded row is preserved BYTE-IDENTICAL (pre-boot raw SELECT == post-boot
      `TaskRowRaw` load — adoption never rewrites healthy data)
    * 15/17-column historical PREFIXES of the canonical DDL → adopted: the
      missing columns are appended as NULLABLE with their declared types, the
      final `PRAGMA table_info(tasks)` matches the fresh-DB shape exactly
      (names in canonical ORDER, types, notnull/pk flags), and the seeded data
      survives
    * **DEVIATION from the old raw-SQL pipeline (pinned actual behavior)**: the
      real 19-column v0.9.0–v0.12.5 shape — which already has `updated_at`
      (19th) and lacks only `error` — is NOT adopted. The baseline migration
      appends `error` AFTER the existing `updated_at`, so the physical order
      becomes `… branch_name, updated_at, error`, its strict order invariant
      fails, and the migration RAISES `Ecto.MigrationError`. The migration
      transaction then rolls back completely: the ALTER and the `projects`
      CREATE are undone (the table keeps its original 19 columns), the seeded
      row is untouched, and `schema_migrations` is left present but EMPTY. The
      same raise hits the shape an OLD-pipeline repair of that DB produced
      (`… branch_name, updated_at, error`), i.e. the exact v0.12.5 → v0.13.0
      upgrade path the old `Schema.migrate_schema/1` repaired in place —
      carrying the old pipeline's regression coverage forward here means
      pinning that the Ecto boot path (currently) REJECTS that shape loudly
      instead of adopting it.

  ## Scope

  SCHEMA adoption only. The sibling unit (data normalization) covers how
  `20260815000002_data_normalization` rewrites values; here every seeded value
  is already canonical (fixed-precision ISO timestamps, JSON-object `opts`,
  tagged `result`, non-null `branch_name`/`updated_at` where the column
  exists) so the data migration is a byte-level no-op and only the SCHEMA
  effects are asserted. The one unavoidable overlap: on a legacy prefix the
  appended `updated_at` starts NULL and the data migration backfills it from
  `finished_at` in the same boot — that value is pinned (`== finished_at`).

  Same infra contract as `repo_test.exs`: every `Boot.start_dynamic/1` runs
  inside `EvoGit.TestSupport.StoreBootLock.with_boot_lock/1` (concurrent
  migration compiles race), the repo is UNLINKED from the test process and
  stopped through an alive-guard `on_exit` (`Boot.stop/1` on a dead pid
  raises). For the RAISE scenarios the dynamic repo is started from a short
  launcher process (`start_dynamic/1` returns `{:ok, pid}` BEFORE migrations
  run, so on a migration failure the repo leaks, linked to its caller);
  killing the launcher tears the leaked instance down with it — a normal exit
  would NOT, links only trap abnormal exits.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TestSupport.StoreBootLock

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @migration_versions [@baseline_version, @normalization_version]

  # The canonical 20 column names in physical order — matches the baseline
  # migration's @task_columns and TaskRowRaw.__schema__(:fields).
  @canonical_columns ~w(id type status opts started_at finished_at logs result review_status usage agent_count base_sha commit_sha archive_metadata lease_expires_at model_id project_path branch_name error updated_at)

  # `PRAGMA table_info(tasks)` rows — [cid, name, type, notnull, dflt, pk] —
  # for a fresh AND for an adopted-prefix database (the appended columns land
  # at exactly these positions with these flags).
  @canonical_table_info_rows [
    [0, "id", "TEXT", 0, nil, 1],
    [1, "type", "TEXT", 0, nil, 0],
    [2, "status", "TEXT", 1, nil, 0],
    [3, "opts", "TEXT", 0, nil, 0],
    [4, "started_at", "TEXT", 0, nil, 0],
    [5, "finished_at", "TEXT", 0, nil, 0],
    [6, "logs", "TEXT", 0, nil, 0],
    [7, "result", "TEXT", 0, nil, 0],
    [8, "review_status", "TEXT", 0, nil, 0],
    [9, "usage", "TEXT", 0, nil, 0],
    [10, "agent_count", "INTEGER", 0, nil, 0],
    [11, "base_sha", "TEXT", 0, nil, 0],
    [12, "commit_sha", "TEXT", 0, nil, 0],
    [13, "archive_metadata", "TEXT", 0, nil, 0],
    [14, "lease_expires_at", "INTEGER", 0, nil, 0],
    [15, "model_id", "TEXT", 0, nil, 0],
    [16, "project_path", "TEXT", 0, nil, 0],
    [17, "branch_name", "TEXT", 0, nil, 0],
    [18, "error", "TEXT", 0, nil, 0],
    [19, "updated_at", "TEXT", 0, nil, 0]
  ]

  @task_index_names [
    "idx_tasks_status",
    "idx_tasks_finished_at",
    "idx_tasks_lease_expires_at",
    "idx_tasks_project_path",
    "idx_tasks_updated_at",
    "idx_tasks_started_at"
  ]

  @tasks_pk_autoindex "sqlite_autoindex_tasks_1"

  # ── Historical legacy DDLs (verified against the repo's tagged releases) ──

  # Current shape (v0.12.6+ fresh CREATE, == Schema.create_tables/1 / the
  # baseline migration's CREATE): a pre-Ecto DB at this shape lacks only the
  # schema_migrations bookkeeping.
  @ddl_20_col """
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
    error TEXT,
    updated_at TEXT
  )
  """

  # v0.9.0 – v0.12.5 (the "reported crash-on-upgrade" DB): `updated_at` is the
  # 19th column and `error` does not exist yet. NOT a prefix of the canonical
  # order — `error` would have to be inserted BEFORE the existing `updated_at`.
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
  # at the END (SQLite ALTERs can only append) — 20 columns, wrong order.
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

  # Intermediate prefix (16-col v0.5.2–v0.8.3 shape + project_path): through
  # `project_path`, missing branch_name/error/updated_at.
  @ddl_17_col """
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
    project_path TEXT
  )
  """

  # v0.5.0 – v0.5.1 shape: through `lease_expires_at` — missing the five
  # trailing columns model_id/project_path/branch_name/error/updated_at.
  @ddl_15_col """
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
    lease_expires_at INTEGER
  )
  """

  @projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  # A fully-canonical seeded row: all 20 columns, values in @canonical_columns
  # order — fixed-precision timestamps, JSON-object opts, tagged result,
  # non-null branch_name/updated_at — chosen so BOTH migrations are byte-level
  # no-ops on it (timestamp guard passes, result already tagged, opts already
  # an object, branch_name/updated_at non-NULL so no backfill fires).
  @byte_values [
    "r6b1-byte",
    "genesis",
    "completed",
    ~S({"mode":"new","path":"/tmp/r6b1-byte"}),
    "2024-02-02T08:00:00.111Z",
    "2024-02-02T09:00:00.222Z",
    ~S(["2024-02-02 log line"]),
    ~S({"__result_tag__":"ok","data":{"summary":"seed"}}),
    "open",
    ~S({"llm":{"total_cost":0.5}}),
    3,
    "base20",
    "commit20",
    ~S({"records":[]}),
    1_738_500_000_000,
    "kimi",
    "/tmp/r6b1-byte",
    "genesis/agent_20ab",
    ~S({"kind":"test"}),
    "2024-02-02T09:00:01.333Z"
  ]

  # ── setup ─────────────────────────────────────────────────────────────────

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_r6b1_#{System.unique_integer([:positive])}_#{inspect(self())}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp db_path(%{root: root}, tag), do: Path.join(root, "evogit_r6b1_#{tag}.sqlite")

  # Crafts a legacy DB with RAW xqlite — never the repo: `ddl` is executed
  # verbatim, `columns`/`values` seed one task row, `projects?` controls
  # whether the historical projects table exists.
  defp build_legacy_db!(path, ddl, columns \\ [], values \\ [], projects? \\ true) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, _} = XqliteNIF.query(conn, ddl, [])

    if projects? do
      {:ok, _} = XqliteNIF.query(conn, @projects_ddl, [])
    end

    if columns != [] do
      insert_task!(conn, columns, values)
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  defp insert_task!(conn, columns, values) do
    placeholders =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_col, i} -> "?#{i}" end)

    sql = "INSERT INTO tasks (#{Enum.map_join(columns, ", ", & &1)}) VALUES (#{placeholders})"
    {:ok, _} = XqliteNIF.query(conn, sql, values)
    :ok
  end

  # Boots a dynamic repo (through the BEAM-global boot lock — see
  # StoreBootLock's moduledoc), unlinks it from the test process, and stops it
  # on exit through an alive guard.
  defp start_booted_repo!(path) do
    {:ok, pid} = StoreBootLock.with_boot_lock(fn -> Boot.start_dynamic(path) end)
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  # Boots from a short-lived LAUNCHER process and reports the outcome instead
  # of raising: on a migration failure `Boot.start_dynamic/1` has already
  # started (and linked) the repo to its caller, so the repo LEAKS — killing
  # the launcher (abnormal exit propagates over the link) tears it down.
  #
  # The launcher parks until killed: a normal launcher exit would leave the
  # repo alive (links only trap abnormal exits).
  defp boot_via_launcher!(path) do
    parent = self()

    {:ok, launcher} =
      Task.start(fn ->
        outcome =
          try do
            {:ok, Boot.start_dynamic(path)}
          rescue
            exception -> {:raised, exception}
          end

        send(parent, {__MODULE__, self(), outcome})

        receive do
          :r6b1_stop -> :ok
        end
      end)

    ref = Process.monitor(launcher)

    {launcher, outcome} =
      receive do
        {__MODULE__, ^launcher, outcome} ->
          Process.demonitor(ref, [:flush])
          {launcher, outcome}

        {:DOWN, ^ref, :process, ^launcher, reason} ->
          flunk("boot launcher died before reporting: #{inspect(reason)}")
      after
        15_000 -> flunk("boot launcher timed out")
      end

    on_exit(fn ->
      if Process.alive?(launcher), do: Process.exit(launcher, :kill)
    end)

    {launcher, outcome}
  end

  defp task_table_info(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA table_info(tasks)").rows
    end)
  end

  defp column_names(pid, table) do
    RepoScope.with_repo(pid, fn ->
      result = Repo.query!("PRAGMA table_info(#{table})")
      Enum.map(result.rows, fn [_cid, name | _] -> name end)
    end)
  end

  defp migration_versions(pid) do
    RepoScope.with_repo(pid, fn ->
      result = Repo.query!("SELECT version FROM schema_migrations ORDER BY version")
      Enum.map(result.rows, &hd/1)
    end)
  end

  defp schema_migrations_count(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("SELECT COUNT(*) FROM schema_migrations").rows
    end)
  end

  defp get_task_row(pid, id) do
    RepoScope.with_repo(pid, fn -> Repo.get(TaskRowRaw, id) end)
  end

  defp query_rows(pid, sql) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql).rows end)
  end

  # Raw xqlite SELECT of the given columns (in order) for one task row — the
  # pre-boot / post-raise ground truth, independent of the repo.
  defp raw_task_columns!(path, columns, id) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    sql = "SELECT #{Enum.map_join(columns, ", ", & &1)} FROM tasks WHERE id = ?1"
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, sql, [id])
    :ok = XqliteNIF.close(conn)
    rows
  end

  defp raw_table_names!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        []
      )

    :ok = XqliteNIF.close(conn)
    Enum.map(rows, &hd/1)
  end

  # ── Scenario 1: fresh database ────────────────────────────────────────────

  describe "fresh database (nonexistent path)" do
    test "creates the 20-column tasks table and stamps exactly the two migration versions", %{
      root: root
    } do
      path = db_path(%{root: root}, :fresh)
      refute File.exists?(path)

      pid = start_booted_repo!(path)

      assert File.exists?(path)
      assert task_table_info(pid) == @canonical_table_info_rows
      assert migration_versions(pid) == @migration_versions
    end
  end

  # ── Scenario 2: current 20-column legacy adoption ─────────────────────────

  describe "20-column legacy adoption (no schema_migrations)" do
    test "adopts the table and preserves the seeded row byte-identically", %{root: root} do
      path = db_path(%{root: root}, "20col_byte")
      columns = @canonical_columns
      values = @byte_values
      build_legacy_db!(path, @ddl_20_col, columns, values)

      # Ground truth BEFORE boot: the file holds exactly the values we wrote.
      assert raw_task_columns!(path, columns, "r6b1-byte") == [values]

      pid = start_booted_repo!(path)

      # The boot stamped both migrations (the Ecto migrator saw version 0).
      assert migration_versions(pid) == @migration_versions

      # The schema was adopted untouched — the fresh-DB PRAGMA shape.
      assert task_table_info(pid) == @canonical_table_info_rows

      # BYTE-IDENTICAL data: the raw pre-boot SELECT equals the post-boot
      # TaskRowRaw load field-for-field (field order == column order).
      row = get_task_row(pid, "r6b1-byte")

      assert Map.drop(Map.from_struct(row), [:__meta__]) ==
               Map.new(Enum.zip(TaskRowRaw.__schema__(:fields), values))
    end
  end

  # ── Scenario 3: the 19-column v0.12.5 shapes — PINNED ACTUAL (raise) ──────

  describe "19-column legacy (v0.9.0-v0.12.5 shape, updated_at before error)" do
    test "boot RAISES Ecto.MigrationError (order invariant), rolls the migration back, data intact",
         %{root: root} do
      path = db_path(%{root: root}, "19col_raise")

      seed_columns =
        ~w(id type status opts started_at finished_at result agent_count base_sha commit_sha lease_expires_at branch_name updated_at)

      seed_values = [
        "r6b1-v125",
        "genesis",
        "completed",
        ~S({"mode":"new"}),
        "2024-03-03T10:00:00.111Z",
        "2024-03-03T11:00:00.222Z",
        ~S({"__result_tag__":"ok","data":{"summary":"seed"}}),
        4,
        "base19",
        "commit19",
        1_738_500_000_000,
        "genesis/agent_19ab",
        "2024-03-03T11:00:01.333Z"
      ]

      build_legacy_db!(path, @ddl_19_col, seed_columns, seed_values)

      {launcher, outcome} = boot_via_launcher!(path)

      # ACTUAL behavior (deviates from the old raw-SQL pipeline, which
      # appended `error` and moved on): the appended `error` lands AFTER the
      # pre-existing `updated_at`, the strict order invariant fails, and the
      # migration raises.
      {:raised, %Ecto.MigrationError{} = error} = outcome
      assert error.message =~ "baseline adoption failed"
      assert error.message =~ "updated_at"

      # The launcher owns the leaked dynamic repo; killing it tears it down.
      Process.exit(launcher, :kill)
      refute Process.alive?(launcher)

      # The migration transaction rolled back COMPLETELY: the DDL the
      # migration performed (the tasks ALTER + the projects CREATE) is undone —
      # only the pre-existing tables remain (plus schema_migrations, which the
      # Ecto migrator itself creates OUTSIDE the migration transaction)...
      assert raw_table_names!(path) == ["projects", "schema_migrations", "tasks"]
      assert raw_task_columns!(path, ~w(id), "r6b1-v125") == [["r6b1-v125"]]

      # ...the table kept its ORIGINAL 19-column shape (no error column)...
      {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
      {:ok, %{rows: pragma_rows}} = XqliteNIF.query(conn, "PRAGMA table_info(tasks)", [])

      pre_names = Enum.map(pragma_rows, fn [_cid, name | _] -> name end)

      assert pre_names == [
               "id",
               "type",
               "status",
               "opts",
               "started_at",
               "finished_at",
               "logs",
               "result",
               "review_status",
               "usage",
               "agent_count",
               "base_sha",
               "commit_sha",
               "archive_metadata",
               "lease_expires_at",
               "model_id",
               "project_path",
               "branch_name",
               "updated_at"
             ]

      # ...schema_migrations exists but records NOTHING (its version INSERT
      # was inside the rolled-back transaction)...
      {:ok, %{rows: versions}} =
        XqliteNIF.query(conn, "SELECT version FROM schema_migrations", [])

      assert versions == []

      # ...and the seeded row is untouched, byte-for-byte.
      assert raw_task_columns!(path, seed_columns, "r6b1-v125") == [seed_values]
      :ok = XqliteNIF.close(conn)
    end

    test "the old-pipeline-repaired 20-column variant (error appended after updated_at) raises identically",
         %{root: root} do
      path = db_path(%{root: root}, "20col_old_pipeline")

      build_legacy_db!(path, @ddl_19_col_old_pipeline, ~w(id status), [
        "r6b1-oldpipe",
        "completed"
      ])

      {launcher, outcome} = boot_via_launcher!(path)
      Process.exit(launcher, :kill)

      {:raised, %Ecto.MigrationError{} = error} = outcome
      assert error.message =~ "baseline adoption failed"

      # Same full rollback as the 19-column shape (projects CREATE undone,
      # schema_migrations itself survives, empty).
      assert raw_table_names!(path) == ["projects", "schema_migrations", "tasks"]

      assert raw_task_columns!(path, ~w(id status), "r6b1-oldpipe") == [
               ["r6b1-oldpipe", "completed"]
             ]
    end
  end

  # ── Scenario 4: 17-column legacy adoption ─────────────────────────────────

  describe "17-column legacy adoption" do
    test "appends branch_name/error/updated_at (nullable, correct types), data preserved", %{
      root: root
    } do
      path = db_path(%{root: root}, "17col")

      seed_columns =
        ~w(id type status opts started_at finished_at result agent_count base_sha commit_sha lease_expires_at model_id project_path)

      seed_values = [
        "r6b1-c17",
        "evolve",
        "running",
        ~S({"mode":"simple"}),
        "2024-04-04T08:00:00.111Z",
        "2024-04-04T09:00:00.222Z",
        ~S({"__result_tag__":"ok","data":{"summary":"seed"}}),
        2,
        "base17",
        "commit17",
        1_738_500_000_000,
        "glm",
        "/tmp/r6b1-c17"
      ]

      build_legacy_db!(path, @ddl_17_col, seed_columns, seed_values)

      pid = start_booted_repo!(path)

      # Exact fresh-DB PRAGMA shape: the three appended columns land at the
      # canonical positions, NULLABLE (notnull 0), with their declared types.
      assert task_table_info(pid) == @canonical_table_info_rows
      assert migration_versions(pid) == @migration_versions

      row = get_task_row(pid, "r6b1-c17")

      # Every seeded column survived...
      assert row.id == "r6b1-c17"
      assert row.type == "evolve"
      assert row.status == "running"
      assert row.opts == ~S({"mode":"simple"})
      assert row.started_at == "2024-04-04T08:00:00.111Z"
      assert row.finished_at == "2024-04-04T09:00:00.222Z"

      assert row.result == ~S({"__result_tag__":"ok","data":{"summary":"seed"}})

      assert row.agent_count == 2
      assert row.base_sha == "base17"
      assert row.commit_sha == "commit17"
      assert row.lease_expires_at == 1_738_500_000_000
      assert row.model_id == "glm"
      assert row.project_path == "/tmp/r6b1-c17"

      # ...the appended columns are NULLABLE adds — branch_name/error read
      # NULL (the seeded tagged result carries no branch_name to backfill)...
      assert row.branch_name == nil
      assert row.error == nil

      # ...and the appended updated_at was backfilled by the SAME boot's data
      # migration (COALESCE(finished_at, started_at, now) — pinned actual).
      assert row.updated_at == "2024-04-04T09:00:00.222Z"
    end
  end

  # ── Scenario 5: 15-column legacy adoption ─────────────────────────────────

  describe "15-column legacy adoption" do
    test "appends model_id/project_path/branch_name/error/updated_at, data preserved", %{
      root: root
    } do
      path = db_path(%{root: root}, "15col")

      seed_columns =
        ~w(id type status opts started_at finished_at result agent_count base_sha commit_sha lease_expires_at)

      seed_values = [
        "r6b1-c15",
        "reflect",
        "pending",
        ~S({"archive":true}),
        "2024-05-05T06:00:00.111Z",
        "2024-05-05T07:00:00.222Z",
        ~S({"__result_tag__":"ok","data":{"summary":"seed"}}),
        1,
        "base15",
        "commit15",
        1_738_500_000_000
      ]

      build_legacy_db!(path, @ddl_15_col, seed_columns, seed_values)

      pid = start_booted_repo!(path)

      assert task_table_info(pid) == @canonical_table_info_rows
      assert migration_versions(pid) == @migration_versions

      row = get_task_row(pid, "r6b1-c15")

      assert {row.id, row.type, row.status} == {"r6b1-c15", "reflect", "pending"}
      assert row.opts == ~S({"archive":true})

      assert {row.started_at, row.finished_at} ==
               {"2024-05-05T06:00:00.111Z", "2024-05-05T07:00:00.222Z"}

      assert row.result == ~S({"__result_tag__":"ok","data":{"summary":"seed"}})

      assert {row.agent_count, row.lease_expires_at} == {1, 1_738_500_000_000}
      assert {row.base_sha, row.commit_sha} == {"base15", "commit15"}

      # The five appended columns: four read NULL...
      assert {row.model_id, row.project_path, row.branch_name, row.error} == {nil, nil, nil, nil}

      # ...and updated_at is backfilled from finished_at by the same boot.
      assert row.updated_at == "2024-05-05T07:00:00.222Z"
    end
  end

  # ── Scenario 6: missing projects table ────────────────────────────────────

  describe "legacy DB without a projects table" do
    test "boot creates an empty projects table with the canonical 3-column shape", %{
      root: root
    } do
      path = db_path(%{root: root}, "no_projects")
      build_legacy_db!(path, @ddl_15_col, ~w(id status), ["r6b1-noproj", "completed"], false)

      pid = start_booted_repo!(path)

      assert column_names(pid, "projects") == ["path", "name", "last_opened_at"]

      assert RepoScope.with_repo(pid, fn ->
               Repo.query!("PRAGMA table_info(projects)").rows
             end) == [
               [0, "path", "TEXT", 0, nil, 1],
               [1, "name", "TEXT", 0, nil, 0],
               [2, "last_opened_at", "TEXT", 0, nil, 0]
             ]

      assert RepoScope.with_repo(pid, fn ->
               Repo.query!("SELECT COUNT(*) FROM projects").rows
             end) == [[0]]

      # tasks adoption still happened alongside the projects creation.
      assert column_names(pid, "tasks") == @canonical_columns
    end
  end

  # ── Scenario 7: indexes on an adopted legacy DB ───────────────────────────

  describe "indexes on an adopted legacy DB" do
    test "the 6 baseline idx_tasks_* indexes (plus the PK autoindex) exist", %{root: root} do
      path = db_path(%{root: root}, "indexes")
      build_legacy_db!(path, @ddl_17_col, ~w(id status), ["r6b1-idx", "completed"])

      pid = start_booted_repo!(path)

      index_names =
        query_rows(
          pid,
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'tasks' ORDER BY name"
        )
        |> Enum.map(&hd/1)

      assert index_names == Enum.sort(@task_index_names ++ [@tasks_pk_autoindex])

      # Non-unique, CREATE INDEX-origin, non-partial — the baseline DDL shape.
      rows = query_rows(pid, "PRAGMA index_list(tasks)")

      for [_seq, name, unique, origin, partial] <- rows, name in @task_index_names do
        assert {unique, origin, partial} == {0, "c", 0}
      end
    end
  end
end
