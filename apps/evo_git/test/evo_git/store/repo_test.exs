defmodule EvoGit.Store.RepoTest do
  @moduledoc """
  Infra tests for the Ecto foundations of the task store — the `EvoGit.Repo`
  configuration + the shipped `priv/repo/migrations` migrations, exercised
  through REAL unnamed dynamic instances (`EvoGit.Store.Boot.start_dynamic/1`)
  — exactly the shape per-store instances use in production.

  Pinned contracts:

    * `start_dynamic/1` applies exactly the eight shipped migration versions
    * the resulting `tasks` table has the exact 20-column shape (names, ORDER,
      DDL types, notnull/pk flags) — declared in ONE step by the baseline
      migration, which never creates the retired `archive_metadata` column (only
      an adopted legacy database can still carry it, and
      `20260815000005_task_agent_archives` consumes it) — and the physical
      column order matches `TaskRow.columns/0`
    * the six named `idx_tasks_*` indexes exist (two plain single-column
      indexes + the two composite `(equality column, started_at)` indexes + the
      two covering `(equality column, ordering column, id)` indexes) and the
      four redundant single-column indexes `20260815000006_prune_redundant_indexes`
      drops are GONE; `task_agent_archives`
      carries its `(task_id, depth, agent_id)` index and its composite
      `(task_id, agent_id)` PK autoindex; `vct_mounts` carries its TEXT-PK
      autoindex plus the UNIQUE-path autoindex
    * `Boot.run_migrations/1` is idempotent (a re-run migrates nothing)
    * committed rows survive `Boot.stop/1` → `start_dynamic/1` on the same path
    * two dynamic instances on distinct paths coexist with independent data
    * the connection PRAGMAs reflect the `EvoGit.Repo` defaults
      (`journal_mode: :wal`, `synchronous: :normal`, `busy_timeout: 30_000`);
      the busy wait is asserted through `Xqlite.get_busy_timeout/1` on the
      connection handle, because `PRAGMA busy_timeout` read in SQL answers `0`
      on every connection

  Raw introspection runs through `Repo.query!/3` inside `RepoScope.with_repo/2`;
  every result is the `Ecto.Adapters.SQL.Result` shape —
  `%{columns: [...], rows: [[...] | ...], num_rows: pos_integer(), changes: integer()}`
  — with PRAGMA rows decoded to plain SQL values (integers stay integers, NULL
  becomes nil, journal_mode is the string `"wal"`).

  `PRAGMA index_list/1` row order is reverse-creation order (unstable API), so
  index assertions are membership-based; deterministic ordering comes from
  `sqlite_master ... ORDER BY name`.
  """

  use ExUnit.Case, async: true

  require Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.VctMountRow
  alias EvoGit.Store.Schemas.TaskAgentArchiveRow
  alias EvoGit.Store.Schemas.TaskRow

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @composite_index_version 20_260_815_000_003
  @covering_index_version 20_260_815_000_004
  @archive_table_version 20_260_815_000_005
  @prune_indexes_version 20_260_815_000_006
  @vct_mounts_version 20_260_815_000_007
  @session_mode_version 20_260_815_000_008
  # Ascending, exactly as `schema_migrations` reports it: the ONE schema-creating
  # baseline, the data normalization, the two shipped index migrations (the
  # `(equality, started_at)` composites, then the covering pair), the merged
  # archive-table migration (legacy fan-out + `archive_metadata` drop, both
  # skipped on a fresh database), the redundant-index prune, the VCT mount table
  # (which also retires any legacy `projects` table), and finally the
  # probe-guarded `tasks.session_mode` adoption (a no-op on a fresh database,
  # whose baseline CREATE TABLE already declares the column).
  @migration_versions [
    @baseline_version,
    @normalization_version,
    @composite_index_version,
    @covering_index_version,
    @archive_table_version,
    @prune_indexes_version,
    @vct_mounts_version,
    @session_mode_version
  ]

  # `tasks` columns RETIRED from the live table: the per-agent archive moved to
  # its own relational table, so the baseline CREATE TABLE no longer declares
  # `archive_metadata` AT ALL — `20260815000005_task_agent_archives` only drops
  # it from a legacy database that still carries it. No
  # `Codec`/`TaskRow`/read/write path touches it, and it must never come back.
  @retired_task_columns ["archive_metadata"]

  # `PRAGMA table_info(tasks)` rows — [cid, name, type, notnull, dflt, pk] —
  # the FINAL physical shape: the baseline migration's CREATE TABLE declares
  # exactly these 20 columns in this order (a fresh database never sees the
  # retired `archive_metadata` column, so `cid` is a contiguous 0..19). Every
  # column TEXT except `agent_count`/`lease_expires_at` (INTEGER), only `status`
  # NOT NULL, `id` the TEXT primary key.
  @task_table_info_rows [
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
    [13, "lease_expires_at", "INTEGER", 0, nil, 0],
    [14, "model_id", "TEXT", 0, nil, 0],
    [15, "project_path", "TEXT", 0, nil, 0],
    [16, "branch_name", "TEXT", 0, nil, 0],
    [17, "error", "TEXT", 0, nil, 0],
    [18, "session_mode", "TEXT", 0, nil, 0],
    [19, "updated_at", "TEXT", 0, nil, 0]
  ]

  # The two plain single-column indexes the baseline migration creates that
  # survive the chain (`CREATE INDEX IF NOT EXISTS`, one per queried ordering
  # column — the query planner's access paths).
  @single_column_index_names [
    "idx_tasks_updated_at",
    "idx_tasks_started_at"
  ]

  # The composite `(equality column, started_at)` indexes added by
  # `20260815000003_composite_indexes` — the paginated read's ORDER BY carriers.
  @composite_index_names [
    "idx_tasks_status_started_at",
    "idx_tasks_project_path_started_at"
  ]

  # The two COVERING indexes added by `20260815000004_covering_indexes` — the
  # id-oriented task reads answer from the index with NO table access.
  @covering_index_names [
    "idx_tasks_status_updated_at_id",
    "idx_tasks_finished_at_id"
  ]

  # The FINAL `tasks` index set — exactly six named indexes.
  @all_task_index_names @single_column_index_names ++
                          @composite_index_names ++
                          @covering_index_names

  # The redundant single-column indexes
  # `20260815000006_prune_redundant_indexes` drops: each one is an exact PREFIX
  # of a final composite/covering index (or has no query at all), so it can
  # never win a plan. They must be absent from the booted schema.
  @redundant_index_names [
    "idx_tasks_status",
    "idx_tasks_finished_at",
    "idx_tasks_project_path",
    "idx_tasks_lease_expires_at"
  ]

  # The per-agent archive created by `20260815000005_task_agent_archives`:
  # the roster index (`WHERE task_id = ? ORDER BY depth, agent_id`) and the
  # implicit UNIQUE autoindex backing the composite `(task_id, agent_id)` PK.
  @archive_table "task_agent_archives"
  @archive_index_name "task_agent_archives_task_depth_idx"
  @archive_pk_autoindex "sqlite_autoindex_task_agent_archives_1"

  # SQLite's implicit UNIQUE backing index for the tasks TEXT PK.
  @tasks_pk_autoindex "sqlite_autoindex_tasks_1"

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Starts an unnamed dynamic repo on a UNIQUE tmp database file (per test
  # process, per call — `async: true` safe) and stops it on test exit.
  # Migration compilation inside `Boot.start_dynamic/1` is serialized by the
  # production `:global` lock (see `EvoGit.Store.Boot`).
  #
  # The repo is UNLINKED: `Boot.start_dynamic/1` links it to this test process
  # and `on_exit/1` callbacks run after that process is gone, so the link's
  # exit signal must not own the shutdown. `stop_quietly/1` (not `Boot.stop/1`)
  # is used for cleanup because tests that stop their instance manually inside
  # the test body would otherwise hit "no process" on `Supervisor.stop/3`.
  defp start_repo!(tag) do
    path = db_path(tag)
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)

    on_exit(fn ->
      stop_quietly(pid)
      remove_db(path)
    end)

    pid
  end

  defp db_path(tag) do
    # The name embeds the OS pid + wall-clock ms on top of the per-BEAM unique
    # integer + test pid: `System.unique_integer/1` restarts in every BEAM and
    # test pids are deterministic across runs, so without those a PREVIOUS
    # test run's stale tmp file gets silently adopted.
    unique = System.unique_integer([:positive, :monotonic])

    Path.join(
      System.tmp_dir!(),
      "evogit_r6a_#{tag}_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
        "#{unique}_#{inspect(self())}.sqlite"
    )
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  # Removes the tmp database AND its WAL sidecars (`File.rm/1` is a no-op for a
  # path that is already gone) so a run leaves nothing behind in the tmpdir —
  # a leftover `-wal` still holds the committed rows.
  defp remove_db(path) do
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
  end

  defp query!(pid, sql), do: RepoScope.with_repo(pid, fn -> Repo.query!(sql) end)

  defp query_rows(pid, sql), do: query!(pid, sql).rows

  defp migration_versions(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.all(Ecto.Query.from(m in "schema_migrations", select: m.version, order_by: m.version))
    end)
  end

  # VctMountRow's `last_opened_at` is a `Types.TaskTimestamp` — a %DateTime{}
  # dumps to the fixed-ms ISO wire format, so insert_all through the TYPED
  # schema is the correct write path (mirrors repo_scope_test.exs). Every column
  # is supplied explicitly: `insert_all` bypasses the schema's `kind` default,
  # and the column is NOT NULL.
  defp insert_mount(pid, point, path, name) do
    RepoScope.with_repo(pid, fn ->
      Repo.insert_all(VctMountRow, [
        [
          point: point,
          path: path,
          name: name,
          kind: "git",
          last_opened_at: ~U[2024-05-05 05:05:05.555Z]
        ]
      ])
    end)
  end

  # ── Migrations applied ───────────────────────────────────────────────────

  describe "boot migrations" do
    test "start_dynamic/1 applies exactly the shipped versions" do
      pid = start_repo!(:versions)

      assert migration_versions(pid) == @migration_versions
    end

    test "Ecto.Migrator.migrated_versions/1 agrees with the schema_migrations table" do
      pid = start_repo!(:migrator)

      assert RepoScope.with_repo(pid, fn ->
               Ecto.Migrator.migrated_versions(Repo)
             end) == @migration_versions
    end

    test "the database carries exactly the four expected tables" do
      pid = start_repo!(:tables)

      # `sqlite_stat%` is excluded: the boot path now runs a best-effort
      # `PRAGMA optimize`, which may create SQLite's own statistics tables
      # (see `EvoGit.Store.Boot.start_dynamic/2`).
      assert query_rows(
               pid,
               "SELECT name FROM sqlite_master WHERE type = 'table' " <>
                 "AND name NOT LIKE 'sqlite_stat%' ORDER BY name"
             ) == [["schema_migrations"], [@archive_table], ["tasks"], ["vct_mounts"]]
    end
  end

  # ── tasks table shape ────────────────────────────────────────────────────

  describe "tasks table shape" do
    test "PRAGMA table_info returns the exact 20 rows: names in order, types, notnull/pk flags" do
      pid = start_repo!(:shape)

      result = query!(pid, "PRAGMA table_info(tasks)")

      assert result.columns == ["cid", "name", "type", "notnull", "dflt_value", "pk"]

      rows = result.rows
      assert length(rows) == 20

      assert Enum.map(rows, fn [_cid | rest] -> rest end) ==
               Enum.map(@task_table_info_rows, fn [_cid | rest] -> rest end)
    end

    test "physical column order matches the TaskRow schema field order" do
      pid = start_repo!(:schema_order)

      assert query_rows(pid, "PRAGMA table_info(tasks)")
             |> Enum.map(fn [_cid, name | _] -> name end) == TaskRow.columns()
    end

    test "the retired archive column is never created and has no schema field behind it" do
      pid = start_repo!(:retired_column)

      live_columns =
        Enum.map(query_rows(pid, "PRAGMA table_info(tasks)"), fn [_cid, name | _] ->
          name
        end)

      for retired <- @retired_task_columns do
        refute retired in live_columns
        refute retired in TaskRow.columns()
        refute retired in Codec.task_columns()
      end
    end

    test "only status is NOT NULL and only id is the primary key" do
      pid = start_repo!(:flags)

      # notnull/pk are the PRAGMA's integer 0/1 flags, not booleans.
      for [_cid, name, _type, notnull, _dflt, pk] <- query_rows(pid, "PRAGMA table_info(tasks)") do
        assert {notnull, pk} ==
                 {if(name == "status", do: 1, else: 0), if(name == "id", do: 1, else: 0)}
      end
    end
  end

  # ── vct_mounts table shape ───────────────────────────────────────────────

  describe "vct_mounts table shape" do
    test "exact 5-column shape with point as the TEXT primary key" do
      pid = start_repo!(:vct_mounts)

      assert query_rows(pid, "PRAGMA table_info(vct_mounts)") == [
               [0, "point", "TEXT", 1, nil, 1],
               [1, "path", "TEXT", 1, nil, 0],
               [2, "name", "TEXT", 1, nil, 0],
               [3, "kind", "TEXT", 1, nil, 0],
               [4, "last_opened_at", "TEXT", 0, nil, 0]
             ]
    end

    test "point PK and UNIQUE path are each backed by an autoindex" do
      pid = start_repo!(:vct_mounts_pk)

      assert query_rows(pid, "PRAGMA index_list(vct_mounts)")
             |> Enum.map(fn [_seq, name | rest] -> [name | rest] end)
             |> Enum.sort() == [
               ["sqlite_autoindex_vct_mounts_1", 1, "pk", 0],
               ["sqlite_autoindex_vct_mounts_2", 1, "u", 0]
             ]
    end
  end

  # ── task_agent_archives table shape ──────────────────────────────────────

  describe "task_agent_archives table shape" do
    test "exact 23-column shape, matching the schema field order" do
      pid = start_repo!(:archive_shape)

      rows = query_rows(pid, "PRAGMA table_info(#{@archive_table})")

      assert Enum.map(rows, fn [_cid, name | _] -> name end) == TaskAgentArchiveRow.columns()

      # Only the two PK columns and the two NOT NULL DEFAULT 0 counters are
      # NOT NULL; the PK flags are 1/2 in declaration order (SQLite numbers a
      # COMPOSITE primary key).
      assert for([_cid, name, _type, notnull, _dflt, pk] <- rows, notnull == 1, do: {name, pk}) ==
               [{"task_id", 1}, {"agent_id", 2}, {"depth", 0}, {"compression_count", 0}]
    end

    test "the roster index is a plain non-unique index on (task_id, depth, agent_id)" do
      pid = start_repo!(:archive_index)

      rows = query_rows(pid, "PRAGMA index_list(#{@archive_table})")
      names = Enum.map(rows, fn [_seq, name | _] -> name end)

      assert MapSet.new(names) == MapSet.new([@archive_index_name, @archive_pk_autoindex])

      for [_seq, name, unique, origin, partial] <- rows, name == @archive_index_name do
        assert unique == 0
        assert origin == "c"
        assert partial == 0
      end

      assert query_rows(pid, "PRAGMA index_info(#{@archive_index_name})")
             |> Enum.map(fn [_seqno, _cid, column] -> column end) == [
               "task_id",
               "depth",
               "agent_id"
             ]
    end
  end

  # ── Indexes ──────────────────────────────────────────────────────────────

  describe "indexes" do
    test "exactly the six final idx_tasks_* indexes exist as plain non-unique indexes" do
      pid = start_repo!(:indexes)

      rows = query_rows(pid, "PRAGMA index_list(tasks)")

      names = Enum.map(rows, fn [_seq, name | _] -> name end)
      assert MapSet.new(names) == MapSet.new(@all_task_index_names ++ [@tasks_pk_autoindex])

      for [_seq, name, unique, origin, partial] <- rows, name in @all_task_index_names do
        assert unique == 0
        assert origin == "c"
        assert partial == 0
      end
    end

    test "the four redundant single-column indexes the prune migration drops are gone" do
      pid = start_repo!(:pruned_indexes)

      names =
        pid
        |> query_rows("PRAGMA index_list(tasks)")
        |> Enum.map(fn [_seq, name | _] -> name end)

      # Guard the assertion's own meaning: three of the four are exact PREFIXES
      # of a surviving composite/covering index (which is why they can never win
      # a plan) and the fourth (`lease_expires_at`) is not queried at all.
      prefixed =
        Enum.filter(@redundant_index_names, fn name ->
          Enum.any?(@all_task_index_names, &String.starts_with?(&1, name <> "_"))
        end)

      assert prefixed == ~w(idx_tasks_status idx_tasks_finished_at idx_tasks_project_path)
      assert "idx_tasks_lease_expires_at" in @redundant_index_names

      for redundant <- @redundant_index_names do
        refute redundant in names
      end
    end

    test "the tasks PK autoindex is unique with origin pk" do
      pid = start_repo!(:pk_autoindex)

      assert query_rows(pid, "PRAGMA index_list(tasks)")
             |> Enum.map(fn [_seq, name | rest] -> [name | rest] end)
             |> Enum.sort() ==
               Enum.sort(
                 Enum.map(@all_task_index_names, &[&1, 0, "c", 0]) ++
                   [[@tasks_pk_autoindex, 1, "pk", 0]]
               )
    end

    test "the whole index inventory matches exactly (deterministic ordering)" do
      pid = start_repo!(:inventory)

      assert query_rows(
               pid,
               "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' ORDER BY name"
             ) ==
               Enum.sort(
                 Enum.map(@all_task_index_names, &[&1, "tasks"]) ++
                   [
                     [@archive_index_name, @archive_table],
                     [@archive_pk_autoindex, @archive_table],
                     ["sqlite_autoindex_tasks_1", "tasks"],
                     ["sqlite_autoindex_vct_mounts_1", "vct_mounts"],
                     ["sqlite_autoindex_vct_mounts_2", "vct_mounts"]
                   ]
               )
    end
  end

  # ── Idempotency ──────────────────────────────────────────────────────────

  describe "run_migrations/1 idempotency" do
    test "a re-run against a current database migrates nothing" do
      pid = start_repo!(:idempotent)

      assert Boot.run_migrations(pid) == []
      assert migration_versions(pid) == @migration_versions
    end

    test "repeated re-runs stay no-ops and never raise" do
      pid = start_repo!(:idempotent_repeat)

      assert Boot.run_migrations(pid) == []
      assert Boot.run_migrations(pid) == []
      assert migration_versions(pid) == @migration_versions
    end

    test "a re-run leaves the table/index inventory untouched" do
      pid = start_repo!(:idempotent_inventory)

      before =
        query_rows(pid, "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")

      assert Boot.run_migrations(pid) == []

      after_ =
        query_rows(pid, "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")

      assert before == after_
    end
  end

  # ── Durability across stop/start ─────────────────────────────────────────

  describe "durability" do
    test "a committed row survives Boot.stop/1 then start_dynamic/1 on the same path" do
      path = db_path("durability")

      {:ok, pid} = Boot.start_dynamic(path)
      Process.unlink(pid)

      on_exit(fn ->
        stop_quietly(pid)
        remove_db(path)
      end)

      assert RepoScope.with_repo(pid, fn -> Repo.aggregate(VctMountRow, :count) end) == 0
      assert insert_mount(pid, "vct:///projects/durable", "/r6a/durable", "Durable") == {1, nil}

      :ok = Boot.stop(pid)

      {:ok, pid2} = Boot.start_dynamic(path)
      Process.unlink(pid2)
      on_exit(fn -> stop_quietly(pid2) end)

      row = RepoScope.with_repo(pid2, fn -> Repo.get(VctMountRow, "vct:///projects/durable") end)

      assert {row.path, row.name, row.last_opened_at} ==
               {"/r6a/durable", "Durable", ~U[2024-05-05 05:05:05.555Z]}
    end
  end

  # ── Dynamic-instance coexistence ─────────────────────────────────────────

  describe "dynamic instance coexistence" do
    test "two instances on distinct paths hold independent data" do
      pid_a = start_repo!(:coexist_a)
      pid_b = start_repo!(:coexist_b)

      assert insert_mount(pid_a, "vct:///projects/a", "/r6a/a", "A") == {1, nil}
      assert insert_mount(pid_b, "vct:///projects/b", "/r6a/b", "B") == {1, nil}

      assert RepoScope.with_repo(pid_a, fn ->
               {Repo.aggregate(VctMountRow, :count),
                Repo.get(VctMountRow, "vct:///projects/a").name}
             end) == {1, "A"}

      assert RepoScope.with_repo(pid_b, fn ->
               {Repo.aggregate(VctMountRow, :count),
                Repo.get(VctMountRow, "vct:///projects/b").name}
             end) == {1, "B"}
    end
  end

  # ── Connection PRAGMAs ───────────────────────────────────────────────────

  describe "connection PRAGMAs" do
    # `Boot.start_dynamic/1` pins pool_size: 1 — a single connection — so the
    # per-connection pragmas below are deterministic. Values are what the
    # `EvoGit.Repo` defaults configure (repo.ex): journal_mode :wal,
    # synchronous :normal, busy_timeout 30_000. The busy wait lives in the
    # connection's busy slot, so it is read through `Xqlite.get_busy_timeout/1`
    # on the handle — a `PRAGMA busy_timeout` query answers `0`.
    test "journal_mode is wal (database-persistent)" do
      pid = start_repo!(:pragma_journal)

      assert query_rows(pid, "PRAGMA journal_mode") == [["wal"]]
    end

    test "synchronous is 1 — SQLite's numeric level for NORMAL" do
      pid = start_repo!(:pragma_sync)

      assert query_rows(pid, "PRAGMA synchronous") == [[1]]
    end

    test "busy_timeout is 30000 ms" do
      pid = start_repo!(:pragma_busy)

      # A statement that meets another connection's lock waits this long, in
      # the CALLING process; SQLite answers the SQL read-back with `0`.
      assert query_rows(pid, "PRAGMA busy_timeout") == [[0]]
      assert busy_timeout(pid) == 30_000
    end
  end

  # The busy wait the connection keeps, read through the adapter's sanctioned
  # raw-connection checkout: `PRAGMA busy_timeout` read as SQL reports `0`,
  # while `Xqlite.get_busy_timeout/1` answers the wait itself.
  defp busy_timeout(pid) do
    {:ok, ms} = XqliteEcto3.with_xqlite(pid, fn conn -> Xqlite.get_busy_timeout(conn) end)

    ms
  end
end
