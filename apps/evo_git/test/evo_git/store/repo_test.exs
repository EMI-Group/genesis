defmodule EvoGit.Store.RepoTest do
  @moduledoc """
  Infra tests for the Ecto foundations of the task store — the `EvoGit.Repo`
  configuration + the two shipped `priv/repo/migrations` migrations, exercised
  through REAL unnamed dynamic instances (`EvoGit.Store.Boot.start_dynamic/1`)
  — exactly the shape per-store instances use in production.

  Pinned contracts:

    * `start_dynamic/1` applies exactly the two shipped migration versions
    * the resulting `tasks` table has the exact 20-column shape (names, ORDER,
      DDL types, notnull/pk flags) of the baseline migration, and the physical
      column order matches `TaskRow.columns/0`
    * the 6 named `idx_tasks_*` indexes exist; `projects` carries its TEXT-PK
      autoindex
    * `Boot.run_migrations/1` is idempotent (a re-run migrates nothing)
    * committed rows survive `Boot.stop/1` → `start_dynamic/1` on the same path
    * two dynamic instances on distinct paths coexist with independent data
    * the connection PRAGMAs reflect the `EvoGit.Repo` defaults
      (`journal_mode: :wal`, `synchronous: :normal`, `busy_timeout: 30_000`)

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
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.ProjectRow
  alias EvoGit.Store.Schemas.TaskRow

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @migration_versions [@baseline_version, @normalization_version]

  # `PRAGMA table_info(tasks)` rows — [cid, name, type, notnull, dflt, pk] —
  # exactly what the baseline migration's CREATE TABLE declares, in order:
  # every column TEXT except `agent_count`/`lease_expires_at` (INTEGER), only
  # `status` NOT NULL, `id` the TEXT primary key.
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
    [13, "archive_metadata", "TEXT", 0, nil, 0],
    [14, "lease_expires_at", "INTEGER", 0, nil, 0],
    [15, "model_id", "TEXT", 0, nil, 0],
    [16, "project_path", "TEXT", 0, nil, 0],
    [17, "branch_name", "TEXT", 0, nil, 0],
    [18, "error", "TEXT", 0, nil, 0],
    [19, "updated_at", "TEXT", 0, nil, 0]
  ]

  # The 6 named indexes created by the baseline migration (CREATE INDEX IF NOT
  # EXISTS, one per queried column — the query planner's access paths).
  @task_index_names [
    "idx_tasks_status",
    "idx_tasks_finished_at",
    "idx_tasks_lease_expires_at",
    "idx_tasks_project_path",
    "idx_tasks_updated_at",
    "idx_tasks_started_at"
  ]

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
    {:ok, pid} = Boot.start_dynamic(db_path(tag))
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp db_path(tag) do
    unique = System.unique_integer([:positive, :monotonic])

    Path.join(
      System.tmp_dir!(),
      "evogit_r6a_#{tag}_#{unique}_#{inspect(self())}.sqlite"
    )
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  defp query!(pid, sql), do: RepoScope.with_repo(pid, fn -> Repo.query!(sql) end)

  defp query_rows(pid, sql), do: query!(pid, sql).rows

  defp migration_versions(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.all(Ecto.Query.from(m in "schema_migrations", select: m.version, order_by: m.version))
    end)
  end

  # ProjectRow's `last_opened_at` is a `Types.TaskTimestamp` — a %DateTime{}
  # dumps to the fixed-ms ISO wire format, so insert_all through the TYPED
  # schema is the correct write path (mirrors repo_scope_test.exs).
  defp insert_project(pid, path, name) do
    RepoScope.with_repo(pid, fn ->
      Repo.insert_all(ProjectRow, [
        [path: path, name: name, last_opened_at: ~U[2024-05-05 05:05:05.555Z]]
      ])
    end)
  end

  # ── Migrations applied ───────────────────────────────────────────────────

  describe "boot migrations" do
    test "start_dynamic/1 applies exactly the two shipped versions" do
      pid = start_repo!(:versions)

      assert migration_versions(pid) == @migration_versions
    end

    test "Ecto.Migrator.migrated_versions/1 agrees with the schema_migrations table" do
      pid = start_repo!(:migrator)

      assert RepoScope.with_repo(pid, fn ->
               Ecto.Migrator.migrated_versions(Repo)
             end) == @migration_versions
    end

    test "the database carries exactly the three expected tables" do
      pid = start_repo!(:tables)

      assert query_rows(
               pid,
               "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
             ) == [["projects"], ["schema_migrations"], ["tasks"]]
    end
  end

  # ── tasks table shape ────────────────────────────────────────────────────

  describe "tasks table shape" do
    test "PRAGMA table_info returns the exact 20 rows: names in order, types, notnull/pk flags" do
      pid = start_repo!(:shape)

      result = query!(pid, "PRAGMA table_info(tasks)")

      assert result.columns == ["cid", "name", "type", "notnull", "dflt_value", "pk"]
      assert result.num_rows == 20
      assert result.rows == @task_table_info_rows
    end

    test "physical column order matches the TaskRow schema field order" do
      pid = start_repo!(:schema_order)

      assert query_rows(pid, "PRAGMA table_info(tasks)")
             |> Enum.map(fn [_cid, name | _] -> name end) == TaskRow.columns()
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

  # ── projects table shape ─────────────────────────────────────────────────

  describe "projects table shape" do
    test "exact 3-column shape with path as the TEXT primary key" do
      pid = start_repo!(:projects)

      assert query_rows(pid, "PRAGMA table_info(projects)") == [
               [0, "path", "TEXT", 0, nil, 1],
               [1, "name", "TEXT", 0, nil, 0],
               [2, "last_opened_at", "TEXT", 0, nil, 0]
             ]
    end

    test "primary key is backed by exactly one UNIQUE autoindex" do
      pid = start_repo!(:projects_pk)

      assert query_rows(pid, "PRAGMA index_list(projects)")
             |> Enum.map(fn [_seq, name | rest] -> [name | rest] end) == [
               ["sqlite_autoindex_projects_1", 1, "pk", 0]
             ]
    end
  end

  # ── Indexes ──────────────────────────────────────────────────────────────

  describe "indexes" do
    test "the 6 named idx_tasks_* indexes exist as plain non-unique indexes" do
      pid = start_repo!(:indexes)

      rows = query_rows(pid, "PRAGMA index_list(tasks)")

      names = Enum.map(rows, fn [_seq, name | _] -> name end)
      assert MapSet.new(names) == MapSet.new(@task_index_names ++ [@tasks_pk_autoindex])

      for [_seq, name, unique, origin, partial] <- rows, name in @task_index_names do
        assert unique == 0
        assert origin == "c"
        assert partial == 0
      end
    end

    test "the tasks PK autoindex is unique with origin pk" do
      pid = start_repo!(:pk_autoindex)

      assert query_rows(pid, "PRAGMA index_list(tasks)")
             |> Enum.map(fn [_seq, name | rest] -> [name | rest] end)
             |> Enum.sort() ==
               Enum.sort([
                 ["idx_tasks_status", 0, "c", 0],
                 ["idx_tasks_finished_at", 0, "c", 0],
                 ["idx_tasks_lease_expires_at", 0, "c", 0],
                 ["idx_tasks_project_path", 0, "c", 0],
                 ["idx_tasks_updated_at", 0, "c", 0],
                 ["idx_tasks_started_at", 0, "c", 0],
                 [@tasks_pk_autoindex, 1, "pk", 0]
               ])
    end

    test "the whole index inventory matches exactly (deterministic ordering)" do
      pid = start_repo!(:inventory)

      assert query_rows(
               pid,
               "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' ORDER BY name"
             ) == [
               ["idx_tasks_finished_at", "tasks"],
               ["idx_tasks_lease_expires_at", "tasks"],
               ["idx_tasks_project_path", "tasks"],
               ["idx_tasks_started_at", "tasks"],
               ["idx_tasks_status", "tasks"],
               ["idx_tasks_updated_at", "tasks"],
               ["sqlite_autoindex_projects_1", "projects"],
               ["sqlite_autoindex_tasks_1", "tasks"]
             ]
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
      on_exit(fn -> stop_quietly(pid) end)

      assert RepoScope.with_repo(pid, fn -> Repo.aggregate(ProjectRow, :count) end) == 0
      assert insert_project(pid, "/r6a/durable", "Durable") == {1, nil}

      :ok = Boot.stop(pid)

      {:ok, pid2} = Boot.start_dynamic(path)
      Process.unlink(pid2)
      on_exit(fn -> stop_quietly(pid2) end)

      row = RepoScope.with_repo(pid2, fn -> Repo.get(ProjectRow, "/r6a/durable") end)

      assert {row.path, row.name, row.last_opened_at} ==
               {"/r6a/durable", "Durable", ~U[2024-05-05 05:05:05.555Z]}
    end
  end

  # ── Dynamic-instance coexistence ─────────────────────────────────────────

  describe "dynamic instance coexistence" do
    test "two instances on distinct paths hold independent data" do
      pid_a = start_repo!(:coexist_a)
      pid_b = start_repo!(:coexist_b)

      assert insert_project(pid_a, "/r6a/a", "A") == {1, nil}
      assert insert_project(pid_b, "/r6a/b", "B") == {1, nil}

      assert RepoScope.with_repo(pid_a, fn ->
               {Repo.aggregate(ProjectRow, :count), Repo.get(ProjectRow, "/r6a/a").name}
             end) == {1, "A"}

      assert RepoScope.with_repo(pid_b, fn ->
               {Repo.aggregate(ProjectRow, :count), Repo.get(ProjectRow, "/r6a/b").name}
             end) == {1, "B"}
    end
  end

  # ── Connection PRAGMAs ───────────────────────────────────────────────────

  describe "connection PRAGMAs" do
    # `Boot.start_dynamic/1` pins pool_size: 1 — a single connection — so the
    # per-connection pragmas below are deterministic. Values are what the
    # `EvoGit.Repo` defaults configure (repo.ex): journal_mode :wal,
    # synchronous :normal, busy_timeout 30_000.
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

      assert query_rows(pid, "PRAGMA busy_timeout") == [[30_000]]
    end
  end
end
