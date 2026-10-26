defmodule EvoGit.Store.ArchiveMigrationTest do
  @moduledoc """
  Coverage for `20260815000005_task_agent_archives` — the ONE step of the
  six-migration chain that both CREATES the relational per-agent archive and
  moves a legacy `tasks.archive_metadata` JSON array into it.

  ## What the migration does

    * `task_agent_archives` is created here (the ONLY create site): ONE row per
      `(task_id, agent_id)`, 23 columns, `repo_id` TEXT (a repo ID STRING, never
      an index), the composite `PRIMARY KEY (task_id, agent_id)` and the
      `task_agent_archives_task_depth_idx` roster index — both shapes re-asserted
      by `PRAGMA table_info`/`PRAGMA index_info` post-conditions;
    * the legacy fan-out is GUARDED on `PRAGMA table_info(tasks)` still
      reporting `archive_metadata`: a fresh database (or one whose archive was
      already moved) skips it entirely and ends at the create path.

  ## Fixture shape

  Each test crafts a REAL pre-migration database with RAW xqlite (never the
  repo): the pre-drop 20-column `tasks` table (the shape a pre-release build
  left behind, i.e. WITH `archive_metadata`) — or, for the fresh path, the LIVE
  19-column one — plus the `projects` table and a `schema_migrations` table
  stamped with every version of the chain EXCEPT `20260815000005`, so exactly
  that migration is pending and its effects are observable in isolation.

  Because the migration under test both creates the table and fans out, NO
  fixture pre-creates `task_agent_archives`: the archive rows appearing there
  prove the create and the fan-out ran as the same step.

  `20260815000006_prune_redundant_indexes` is stamped as applied. Its
  post-condition demands the six final `tasks` indexes, which these raw
  fixtures (built from their DDL alone) do not carry; that migration and its
  index inventory are covered by their own suites, and stamping it keeps this
  file about the archive step only.

  ## Pinned contracts

    * create path: the EXACT 23-column shape and the roster index columns, an
      EMPTY archive table, and `tasks` (rows and columns) untouched — on a
      database that never carried the legacy column the fan-out is skipped;
    * fan-out: one `task_agent_archives` row per legacy record with EVERY column
      mapped (the four JSON columns re-encoded as plain JSON, `depth`/
      `compression_count` defaulting to 0, `repo_id` copied VERBATIM as the repo
      ID string it carried — `"primary"`/`"cowboy"`, never an index), the
      duplicated `data.archive_records` stripped from `result` ONLY when present
      (a result without it stays byte-identical), `archive_metadata` NULLed, the
      column physically dropped and `updated_at` untouched. The migrated rows
      MUST also be readable through the `EvoGit.Store` facade
      (`list_task_archives/3`, `get_agent_archive/3`);
    * a corrupt archive (not JSON, or not a JSON array) is logged as a WARNING
      naming the task id and SKIPPED — the migration still completes, the other
      tasks still migrate and the column still goes;
    * idempotency: a re-run with the column already gone is a silent no-op, and
      a partial fan-out (some rows written, the column still holding the array)
      resumes through the upsert on `(task_id, agent_id)` without duplicating an
      agent.

  Never writes to the user's real data dir: every database lives under the
  per-test `System.tmp_dir!()` root.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @composite_index_version 20_260_815_000_003
  @covering_index_version 20_260_815_000_004
  @archive_version 20_260_815_000_005
  @prune_index_version 20_260_815_000_006

  # The whole shipped chain, ascending exactly as `schema_migrations` reports it.
  @migration_versions [
    @baseline_version,
    @normalization_version,
    @composite_index_version,
    @covering_index_version,
    @archive_version,
    @prune_index_version
  ]

  # The pre-release 20-column `tasks` DDL — the state a database upgraded from a
  # released build is in (it still carries the legacy `archive_metadata` column).
  @tasks_ddl """
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

  # The LIVE 19-column `tasks` DDL: a fresh install, or a database whose archive
  # was already moved (the legacy column is gone) — the fan-out's skip path.
  @live_tasks_ddl """
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
    lease_expires_at INTEGER,
    model_id TEXT,
    project_path TEXT,
    branch_name TEXT,
    error TEXT,
    updated_at TEXT
  )
  """

  @projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  @updated_at "2024-05-05T10:00:01.000Z"

  @archive_table "task_agent_archives"

  # The destination columns in table order — the exact projection the
  # assertions read back.
  @archive_projection ~w(task_id agent_id parent_id depth agent_type context_node_path objective
                         result base_commit final_commit branch_name archive_ref_start
                         archive_ref_final repo_id repo_root repo_path usage llm_settings
                         agent_settings foreign_repos compression_count started_at completed_at)

  # The archive-table columns stored as plain JSON TEXT.
  @json_columns ~w(usage llm_settings agent_settings foreign_repos)

  @archive_index "task_agent_archives_task_depth_idx"

  # `PRAGMA table_info(task_agent_archives)` rows — [cid, name, type, notnull,
  # dflt, pk] — of the table `…005` creates: TEXT `repo_id`, `task_id`/`agent_id`
  # the composite primary key, DEFAULT 0 on `depth`/`compression_count`.
  @canonical_archive_table_info [
    [0, "task_id", "TEXT", 1, nil, 1],
    [1, "agent_id", "INTEGER", 1, nil, 2],
    [2, "parent_id", "INTEGER", 0, nil, 0],
    [3, "depth", "INTEGER", 1, "0", 0],
    [4, "agent_type", "TEXT", 0, nil, 0],
    [5, "context_node_path", "TEXT", 0, nil, 0],
    [6, "objective", "TEXT", 0, nil, 0],
    [7, "result", "TEXT", 0, nil, 0],
    [8, "base_commit", "TEXT", 0, nil, 0],
    [9, "final_commit", "TEXT", 0, nil, 0],
    [10, "branch_name", "TEXT", 0, nil, 0],
    [11, "archive_ref_start", "TEXT", 0, nil, 0],
    [12, "archive_ref_final", "TEXT", 0, nil, 0],
    [13, "repo_id", "TEXT", 0, nil, 0],
    [14, "repo_root", "TEXT", 0, nil, 0],
    [15, "repo_path", "TEXT", 0, nil, 0],
    [16, "usage", "TEXT", 0, nil, 0],
    [17, "llm_settings", "TEXT", 0, nil, 0],
    [18, "agent_settings", "TEXT", 0, nil, 0],
    [19, "foreign_repos", "TEXT", 0, nil, 0],
    [20, "compression_count", "INTEGER", 1, "0", 0],
    [21, "started_at", "TEXT", 0, nil, 0],
    [22, "completed_at", "TEXT", 0, nil, 0]
  ]

  # The 19 LIVE `tasks` columns — the shape after the archive migration drops
  # `archive_metadata` (or never had it).
  @live_task_columns ~w(id type status opts started_at finished_at logs result review_status
                        usage agent_count base_sha commit_sha lease_expires_at model_id
                        project_path branch_name error updated_at)

  setup do
    # pid + wall-clock ms on top of the per-BEAM unique integer: a counter
    # alone collides with a PREVIOUS run's leftover directory.
    stamp =
      "#{System.system_time(:millisecond)}_#{:os.getpid()}_#{System.unique_integer([:positive])}"

    root = Path.join(System.tmp_dir!(), "evogit_archive_migration_#{stamp}_#{inspect(self())}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── 20260815000005_task_agent_archives ────────────────────────────────────

  describe "20260815000005_task_agent_archives" do
    test "creates the archive table and skips the fan-out when the legacy column is absent", %{
      root: root
    } do
      path = Path.join(root, "fresh_path.sqlite")

      create_db!(path, [@archive_version], tasks_ddl: @live_tasks_ddl)
      insert_rows!(path, [[id: "task-fresh", result: ~S({"__result_tag__":"ok","data":{}})]])
      before = data_snapshot!(path)

      pid = start_repo!(path)

      # The table is created with EXACTLY the declared shape (the migration's own
      # post-condition) plus the roster index — even though nothing fans out.
      assert archive_table_info(pid) == @canonical_archive_table_info
      assert archive_index_columns(pid) == ~w(task_id depth agent_id)

      # No fan-out source → no rows, and the task rows are untouched.
      assert archive_rows(pid, "task-fresh") == []
      assert data_snapshot!(path) == before

      # Nothing was dropped: this database never had `archive_metadata`.
      assert column_names(pid) == @live_task_columns
      assert migration_versions(pid) == @migration_versions
    end

    test "fans the legacy archive out into one row per agent with every field mapped", %{
      root: root
    } do
      path = Path.join(root, "fan_out.sqlite")
      create_db!(path, [@archive_version])
      fixture = seed_archives!(path)

      pid = start_repo!(path)

      rows = archive_rows(pid, "task-a")

      assert Enum.map(rows, fn [_task_id, agent_id | _rest] -> agent_id end) == [1, 2, 3]

      # The four JSON columns are PLAIN JSON text (they decode without any
      # unwrapping step in `archive_entry/2`).
      assert archive_entry(rows, 1) == %{
               "task_id" => "task-a",
               "agent_id" => 1,
               "parent_id" => nil,
               "depth" => 0,
               "agent_type" => "manager",
               "context_node_path" => ".",
               "objective" => "Build the thing",
               "result" => "final answer text",
               "base_commit" => "base1",
               "final_commit" => "final1",
               "branch_name" => "evogit-agent-T1-A1",
               "archive_ref_start" => "refs/genesis/archive/T1-A1-start",
               "archive_ref_final" => "refs/genesis/archive/T1-A1-final",
               "repo_id" => "primary",
               "repo_root" => "/tmp/repo",
               "repo_path" => "/tmp/repo",
               "usage" => fixture.usage,
               "llm_settings" => fixture.llm_settings,
               "agent_settings" => fixture.agent_settings,
               "foreign_repos" => fixture.foreign_repos,
               "compression_count" => 2,
               "started_at" => "2024-05-05T09:00:00.000Z",
               "completed_at" => "2024-05-05T10:00:00.000Z"
             }

      # A sparse record: only what it carried, everything else NULL, and the
      # `depth`/`compression_count` NOT NULL defaults.
      assert archive_entry(rows, 2) == %{
               "task_id" => "task-a",
               "agent_id" => 2,
               "parent_id" => 1,
               "depth" => 1,
               "agent_type" => nil,
               "context_node_path" => nil,
               "objective" => "Subtask",
               "result" => "sub answer",
               "base_commit" => nil,
               "final_commit" => "final2",
               "branch_name" => nil,
               "archive_ref_start" => nil,
               "archive_ref_final" => nil,
               "repo_id" => "cowboy",
               "repo_root" => nil,
               "repo_path" => nil,
               "usage" => nil,
               "llm_settings" => nil,
               "agent_settings" => nil,
               "foreign_repos" => nil,
               "compression_count" => 0,
               "started_at" => nil,
               "completed_at" => nil
             }

      # No `depth` / `compression_count` in the record at all → the columns'
      # DEFAULT 0.
      no_counters = archive_entry(rows, 3)

      assert {no_counters["depth"], no_counters["compression_count"]} == {0, 0}
      assert no_counters["parent_id"] == 1
      assert no_counters["objective"] == "Another"
      assert no_counters["result"] == nil
      # A record that carried no `repo_id` keeps SQL NULL — the column is never
      # defaulted to an index.
      assert no_counters["repo_id"] == nil

      # The second task's archive moved too (its own (task_id, agent_id) key
      # space).
      assert %{
               "task_id" => "task-b",
               "agent_id" => 7,
               "objective" => "Solo",
               "result" => "only",
               "depth" => 0
             } = archive_entry(archive_rows(pid, "task-b"), 7)

      # The migrated rows must be LOADABLE through the `EvoGit.Store` facade:
      # `repo_id` is a repo ID STRING and the column is TEXT, so nothing coerces
      # or rejects it on the way back out.
      store = start_store!(path)

      assert %{entries: roster, total: 3} = Store.list_task_archives(store, "task-a")
      # depth ASC then agent_id ASC: 1 and 3 are depth 0, 2 is depth 1.
      assert Enum.map(roster, & &1["agent_id"]) == [1, 3, 2]
      assert Enum.map(roster, & &1["repo_id"]) == ["primary", nil, "cowboy"]

      assert %{"agent_id" => 2, "repo_id" => "cowboy", "result" => "sub answer"} =
               Store.get_agent_archive(store, "task-a", 2)

      assert %{total: 1} = Store.list_task_archives(store, "task-b")

      assert migration_versions(pid) == @migration_versions
    end

    test "strips the duplicated data.archive_records from result only when present", %{
      root: root
    } do
      path = Path.join(root, "strip_result.sqlite")
      create_db!(path, [@archive_version])
      fixture = seed_archives!(path)

      before = snapshot!(path)
      before_updated_at = updated_at_map!(path)

      start_repo!(path)

      # `task-a` carried the duplicate: the key is gone, the rest of the result
      # data is preserved.
      stripped = Jason.decode!(raw!(path, "task-a", "result"))
      refute Map.has_key?(stripped["data"], "archive_records")
      assert stripped["data"]["commit_sha"] == "abc123"
      assert stripped["data"]["result"] == "short report"
      assert Map.get(stripped, "__result_tag__") == "ok"

      # `task-b` never had the key: its result is byte-identical.
      assert raw!(path, "task-b", "result") == fixture.plain_result

      # No row's updated_at moved — moving the archive is not a task mutation.
      assert updated_at_map!(path) == before_updated_at

      # Sanity: the fan-out had a source (the column really carried the array).
      refute before[{"task-a", "archive_metadata"}] == nil
    end

    test "nulls archive_metadata and physically drops the column", %{root: root} do
      path = Path.join(root, "drop_column.sqlite")
      create_db!(path, [@archive_version])
      seed_archives!(path)

      assert "archive_metadata" in column_names!(path)

      pid = start_repo!(path)

      assert column_names(pid) == @live_task_columns
      refute "archive_metadata" in column_names(pid)
    end

    test "a corrupt archive is logged and skipped without wedging the migration", %{root: root} do
      path = Path.join(root, "corrupt_archive.sqlite")
      create_db!(path, [@archive_version])
      seed_archives!(path)

      {pid, log} = with_log(fn -> start_repo!(path) end)

      assert log =~ "skipping task task-corrupt"
      assert log =~ "not a JSON array"
      assert log =~ "skipping task task-bad-json"
      assert log =~ "not valid JSON"

      assert migration_versions(pid) == @migration_versions
      refute "archive_metadata" in column_names(pid)
      assert archive_rows(pid, "task-corrupt") == []
      assert archive_rows(pid, "task-bad-json") == []

      # The healthy tasks still migrated alongside.
      assert length(archive_rows(pid, "task-a")) == 3
    end

    test "is idempotent: re-running after the column is gone is a no-op", %{root: root} do
      path = Path.join(root, "drop_idempotent.sqlite")
      create_db!(path, [@archive_version])
      seed_archives!(path)

      pid = start_repo!(path)
      before = data_snapshot!(path)
      before_archives = archive_rows(pid, "task-a")

      # A re-run of the migration body with the column already dropped must
      # converge silently: the table DDL is `IF NOT EXISTS` and the whole
      # fan-out + drop is behind the column-existence guard.
      :ok = clear_version!(pid, @archive_version)
      :ok = Boot.stop(pid)

      pid = start_repo!(path)

      assert data_snapshot!(path) == before
      assert archive_rows(pid, "task-a") == before_archives
      assert archive_table_info(pid) == @canonical_archive_table_info
      assert migration_versions(pid) == @migration_versions
    end

    test "resumes a partially-applied fan-out without duplicating an agent", %{root: root} do
      path = Path.join(root, "resume.sqlite")
      create_db!(path, [@archive_version])
      fixture = seed_archives!(path)

      pid = start_repo!(path)
      assert length(archive_rows(pid, "task-a")) == 3

      # Simulate a crash AFTER some rows were written but BEFORE the archive
      # was cleared/dropped: restore the column with the original array for
      # `task-a` and delete one of its three rows.
      :ok = sql!(pid, "ALTER TABLE tasks ADD COLUMN archive_metadata TEXT", [])

      :ok =
        sql!(pid, "UPDATE tasks SET archive_metadata = ? WHERE id = ?", [
          fixture.archive_a,
          "task-a"
        ])

      :ok =
        sql!(pid, "DELETE FROM #{@archive_table} WHERE task_id = ? AND agent_id = ?", [
          "task-a",
          2
        ])

      :ok = clear_version!(pid, @archive_version)
      :ok = Boot.stop(pid)

      pid = start_repo!(path)

      # The missing record is back, and the untouched ones were REPLACED (never
      # duplicated) — three rows, not five.
      assert Enum.map(archive_rows(pid, "task-a"), fn [_task_id, agent_id | _rest] -> agent_id end) ==
               [1, 2, 3]

      refute "archive_metadata" in column_names(pid)
      assert migration_versions(pid) == @migration_versions
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # Rows for the archive fan-out: two migratable tasks (one WITH the duplicated
  # `data.archive_records`, one without) and two undecodable archives.
  defp seed_archives!(path) do
    usage = %{
      "input_tokens" => 10,
      "output_tokens" => 5,
      "total_tokens" => 15,
      "total_cost" => 0.5
    }

    llm_settings = %{"model" => "test-model", "generation_params" => %{"temperature" => 0.2}}
    agent_settings = %{"max_turns" => 40, "max_retries" => 2}
    foreign_repos = [%{"id" => "foreign", "path" => "/tmp/foreign", "writable" => false}]

    full = %{
      "agent_id" => 1,
      "parent_id" => nil,
      "depth" => 0,
      "agent_type" => "manager",
      "context_node_path" => ".",
      "objective" => "Build the thing",
      "result" => "final answer text",
      "base_commit" => "base1",
      "final_commit" => "final1",
      "branch_name" => "evogit-agent-T1-A1",
      "archive_ref_start" => "refs/genesis/archive/T1-A1-start",
      "archive_ref_final" => "refs/genesis/archive/T1-A1-final",
      "repo_id" => "primary",
      "repo_root" => "/tmp/repo",
      "repo_path" => "/tmp/repo",
      "usage" => usage,
      "llm_settings" => llm_settings,
      "agent_settings" => agent_settings,
      "foreign_repos" => foreign_repos,
      "compression_count" => 2,
      "started_at" => "2024-05-05T09:00:00.000Z",
      "completed_at" => "2024-05-05T10:00:00.000Z"
    }

    minimal = %{
      "agent_id" => 2,
      "parent_id" => 1,
      "depth" => 1,
      "objective" => "Subtask",
      "result" => "sub answer",
      "final_commit" => "final2",
      "repo_id" => "cowboy"
    }

    # No `depth` / `compression_count` at all — the columns' DEFAULT 0 applies.
    no_counters = %{"agent_id" => 3, "parent_id" => 1, "objective" => "Another"}

    archive_a = Jason.encode!([full, minimal, no_counters])
    archive_b = Jason.encode!([%{"agent_id" => 7, "objective" => "Solo", "result" => "only"}])

    # The result data exactly as the runtime built it: the per-agent archive
    # embedded under `data.archive_records` (the duplicate of the column).
    result_a =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{
          "commit_sha" => "abc123",
          "result" => "short report",
          "branch_name" => "genesis/agent_abc123",
          "archive_records" => [full, minimal, no_counters]
        }
      })

    # Same shape, NO `archive_records` key: must stay byte-identical.
    result_b =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{"commit_sha" => "def456", "result" => "other report"}
      })

    insert_rows!(path, [
      [id: "task-a", result: result_a, archive_metadata: archive_a],
      [id: "task-b", result: result_b, archive_metadata: archive_b],
      [id: "task-corrupt", result: nil, archive_metadata: ~S({"not":"a list"})],
      [id: "task-bad-json", result: nil, archive_metadata: "not json at all"]
    ])

    %{
      archive_a: archive_a,
      archive_b: archive_b,
      plain_result: result_b,
      usage: usage,
      llm_settings: llm_settings,
      agent_settings: agent_settings,
      foreign_repos: foreign_repos
    }
  end

  # The `tasks` + `projects` tables + a `schema_migrations` stamped with every
  # version EXCEPT `pending` — so exactly the migration(s) under test are
  # pending. `:tasks_ddl` selects the fixture's `tasks` shape (the pre-release
  # 20-column one by default).
  defp create_db!(path, pending, opts \\ []) do
    tasks_ddl = Keyword.get(opts, :tasks_ddl, @tasks_ddl)

    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <- [tasks_ddl, @projects_ddl] do
      {:ok, _} = XqliteNIF.query(conn, ddl, [])
    end

    {:ok, _} =
      XqliteNIF.query(
        conn,
        "CREATE TABLE schema_migrations (version BIGINT PRIMARY KEY, inserted_at TEXT)",
        []
      )

    for version <- @migration_versions -- pending do
      {:ok, _} =
        XqliteNIF.query(
          conn,
          "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)",
          [version, "2024-05-05 00:00:00"]
        )
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  # Inserts task rows into an EXISTING fixture database. A column the fixture
  # table does not carry (the LIVE shape has no `archive_metadata`) is dropped
  # from the INSERT, so one helper serves both fixture shapes.
  defp insert_rows!(path, rows) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    defaults = [
      type: "genesis",
      status: "completed",
      opts: ~S({"mode":"new","path":"/tmp/archive-migration"}),
      started_at: "2024-05-05T09:00:00.000Z",
      finished_at: "2024-05-05T10:00:00.000Z",
      logs: "[]",
      result: nil,
      review_status: "open",
      usage: nil,
      agent_count: 1,
      base_sha: nil,
      commit_sha: nil,
      archive_metadata: nil,
      lease_expires_at: nil,
      model_id: nil,
      project_path: "/tmp/archive-migration",
      branch_name: nil,
      error: nil,
      updated_at: @updated_at
    ]

    existing = column_names!(path)

    columns =
      [:id | Keyword.keys(defaults)]
      |> Enum.filter(fn column -> Atom.to_string(column) in existing end)

    placeholders = columns |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "?#{i}" end)

    insert_sql =
      "INSERT INTO tasks (#{Enum.map_join(columns, ", ", &Atom.to_string/1)}) " <>
        "VALUES (#{placeholders})"

    for row <- rows do
      merged = Keyword.merge(defaults, row)
      values = Enum.map(columns, &Keyword.fetch!(merged, &1))
      {:ok, _} = XqliteNIF.query(conn, insert_sql, values)
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Boots a dynamic repo (running the pending migration(s)) and unlinks it:
  # the `on_exit` guard runs after the test process is gone.
  defp start_repo!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  # A uniquely-named `EvoGit.Store` over an ALREADY-MIGRATED database file — the
  # facade the dashboard/RPC layers actually call. It boots its OWN dynamic repo
  # on the same file (every migration is recorded, so nothing runs).
  defp start_store!(path) do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    name = :"archive_migration_store_#{unique}"
    {:ok, pid} = Store.start_link(data_dir: path, name: name, pool_size: 1)
    Process.unlink(pid)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000), else: :ok end)

    name
  end

  defp migration_versions(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
      |> Enum.map(&hd/1)
    end)
  end

  defp clear_version!(pid, version) do
    sql!(pid, "DELETE FROM schema_migrations WHERE version = ?", [version])
  end

  defp sql!(pid, statement, params) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!(statement, params, log: false)
      :ok
    end)
  end

  defp archive_rows(pid, task_id) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!(
        "SELECT #{Enum.join(@archive_projection, ", ")} FROM #{@archive_table} " <>
          "WHERE task_id = ? ORDER BY agent_id",
        [task_id],
        log: false
      ).rows
    end)
  end

  # ONE archive row as a STRING-KEYED map, with the JSON columns DECODED (map
  # key order can never make an assertion flaky).
  defp archive_entry(rows, agent_id) do
    row = Enum.find(rows, fn [_task_id, id | _rest] -> id == agent_id end)

    @archive_projection
    |> Enum.zip(row)
    |> Map.new()
    |> Map.new(fn {column, value} ->
      if column in @json_columns and is_binary(value) do
        {column, Jason.decode!(value)}
      else
        {column, value}
      end
    end)
  end

  # `PRAGMA table_info(task_agent_archives)` through the booted repo.
  defp archive_table_info(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA table_info(#{@archive_table})").rows
    end)
  end

  # The columns the roster index covers, via the booted repo.
  defp archive_index_columns(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA index_info(#{@archive_index})").rows
      |> Enum.map(fn [_seqno, _cid, column] -> column end)
    end)
  end

  defp column_names(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("PRAGMA table_info(tasks)").rows
      |> Enum.map(fn [_cid, name | _rest] -> name end)
    end)
  end

  # Column names read with RAW xqlite — usable BEFORE any repo is booted.
  defp column_names!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "PRAGMA table_info(tasks)", [])
    :ok = XqliteNIF.close(conn)
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end

  # Raw xqlite read of ONE column of ONE row — the ground truth on disk,
  # independent of the repo/codec.
  defp raw!(path, id, column) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: [[value]]}} =
      XqliteNIF.query(conn, "SELECT #{column} FROM tasks WHERE id = ?1", [id])

    :ok = XqliteNIF.close(conn)
    value
  end

  # Every (id, result, logs, archive_metadata) value on disk, keyed by
  # `{id, column}` — used to prove byte-identity across a boot. Requires the
  # PRE-DROP table shape.
  defp snapshot!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT id, result, logs, archive_metadata FROM tasks", [])

    :ok = XqliteNIF.close(conn)

    for [id, result, logs, archive] <- rows,
        {column, value} <- [{"result", result}, {"logs", logs}, {"archive_metadata", archive}],
        into: %{},
        do: {{id, column}, value}
  end

  # The same, for a database whose `archive_metadata` column is already gone.
  defp data_snapshot!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT id, result, logs, opts, branch_name FROM tasks", [])

    :ok = XqliteNIF.close(conn)
    Enum.sort(rows)
  end

  defp updated_at_map!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "SELECT id, updated_at FROM tasks", [])
    :ok = XqliteNIF.close(conn)
    Map.new(rows, fn [id, updated_at] -> {id, updated_at} end)
  end
end
