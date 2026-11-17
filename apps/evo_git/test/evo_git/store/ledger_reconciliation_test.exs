defmodule EvoGit.Store.LedgerReconciliationTest do
  @moduledoc """
  Synthetic upgrade fixtures for 9135df985 → 6e10e18dd.

  9135df985 shipped the rewritten six-version chain, but databases may already
  carry the former ledger: 1/2/3, 5 covering indexes, 6 unpack compression,
  7 archive create, 8 archive fan-out, 9 INTEGER repo_id normalization.
  The rewrite reused those identities; Ecto therefore skips unrelated work.
  These fixtures are raw historical DDL, NOT a current StoreTemplate damaged
  after migration and never a copy of an operator's database.
  Each test owns its file and Store; no shared env, singleton or dump path.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.{Boot, RepoScope}

  @version 20_260_815_000_010
  @rewritten Enum.to_list(20_260_815_000_001..20_260_815_000_006)
  @old [
    20_260_815_000_001,
    20_260_815_000_002,
    20_260_815_000_003,
    20_260_815_000_005,
    20_260_815_000_006,
    20_260_815_000_007,
    20_260_815_000_008,
    20_260_815_000_009
  ]
  @all Enum.to_list(20_260_815_000_001..20_260_815_000_010)
  @archive_columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective
    result base_commit final_commit branch_name archive_ref_start archive_ref_final repo_id
    repo_root repo_path usage llm_settings agent_settings foreign_repos compression_count
    started_at completed_at)
  @indexes %{
    "idx_tasks_updated_at" => ~w(updated_at),
    "idx_tasks_started_at" => ~w(started_at),
    "idx_tasks_status_started_at" => ~w(status started_at),
    "idx_tasks_project_path_started_at" => ~w(project_path started_at),
    "idx_tasks_status_updated_at_id" => ~w(status updated_at id),
    "idx_tasks_finished_at_id" => ~w(finished_at id)
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ledger_reconcile_#{:os.getpid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, path: Path.join(root, "tasks.sqlite")}
  end

  for {label, ledger, repo_type, mounts} <- [
        {"9135df985 six-version schema", @rewritten, "TEXT", false},
        {"pre-rewrite eight-entry ledger", @old, "TEXT", false},
        {"colliding ledger with INTEGER archive repo_id", @old, "INTEGER", false},
        {"already stamped 1..9 with existing mounts",
         Enum.to_list(20_260_815_000_001..20_260_815_000_009), "TEXT", true}
      ] do
    test "#{label}: boot repairs skipped schema without losing data", %{path: path} do
      fixture!(path, unquote(ledger), unquote(repo_type), unquote(mounts))
      before = raw!(path, "SELECT id, opts, result, logs, updated_at FROM tasks")

      before_archive =
        raw!(path, "SELECT #{@archive_columns |> Enum.join(", ")} FROM task_agent_archives")

      store = start_store!(path)
      repo = Store.__repo_pid__(store)

      assert rows(repo, "SELECT id, opts, result, logs, updated_at FROM tasks") == before

      assert rows(repo, "SELECT #{@archive_columns |> Enum.join(", ")} FROM task_agent_archives") ==
               before_archive

      assert Store.get_task(store, "kept").id == "kept"
      assert Store.get_agent_archive(store, "kept", 17)["result"] == "existing report"

      assert rows(repo, "SELECT version FROM schema_migrations ORDER BY version") ==
               Enum.map(@all, &[&1])

      assert rows(repo, "SELECT session_mode, pause_kind FROM tasks") == [[nil, nil]]
      assert Store.get_task(store, "kept").session_mode == "oneshot"

      assert Enum.find(
               rows(repo, "PRAGMA table_info(task_agent_archives)"),
               &(Enum.at(&1, 1) == "repo_id")
             )
             |> Enum.at(2) == "TEXT"

      assert rows(repo, "SELECT path, name, last_opened_at FROM projects ORDER BY path") ==
               [["/historical/demo", "Demo", "2026-01-01T00:00:00Z"]]

      for {name, columns} <- @indexes do
        assert Enum.map(rows(repo, "PRAGMA index_info(#{name})"), &Enum.at(&1, 2)) == columns
      end

      assert Enum.map(
               rows(repo, "PRAGMA index_info(task_agent_archives_task_depth_idx)"),
               &Enum.at(&1, 2)
             ) == ~w(task_id depth agent_id)

      mounts = Store.list_vct_mounts(store)
      assert Enum.any?(mounts, &(&1["path"] == "/historical/demo"))

      if unquote(mounts) do
        assert Enum.any?(
                 mounts,
                 &(&1["point"] == "vct:///genesis-source" and &1["path"] == "/existing/source")
               )

        assert Enum.any?(
                 mounts,
                 &(&1["point"] == "vct:///projects/existing" and &1["path"] == "/existing/project")
               )
      end

      # Use the real writer (the original failure was a missing-table write
      # killing it); synchronous replace proves both read and write contracts.
      writer = Store.__writer__(store)
      assert :ok = Store.save_vct_mounts(store, mounts)
      assert Store.list_vct_mounts(store) == mounts
      assert :ok = Store.save_vct_mounts(store, [])
      assert Store.list_vct_mounts(store) == []
      assert :ok = Store.save_vct_mounts(store, mounts)
      assert Process.alive?(writer)
      assert Store.__writer__(store) == writer

      snapshot = snapshot(repo)
      assert Boot.run_migrations(repo) == []
      assert snapshot(repo) == snapshot
      stop_supervised!(store)
      restarted = start_store!(path)
      assert snapshot(Store.__repo_pid__(restarted)) == snapshot
    end
  end

  test "stamped legacy compression and archive fan-out are reconciled, not discarded", %{
    path: path
  } do
    fixture!(path, Enum.to_list(20_260_815_000_001..20_260_815_000_009), "TEXT", false)

    archive = %{
      "agent_id" => 18,
      "depth" => 1,
      "repo_id" => "foreign",
      "result" => "legacy report",
      "compression_count" => 2
    }

    result =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{"result" => "kept report", "archive_records" => [archive]}
      })

    logs = Jason.encode!(["historical log"])
    raw!(path, "ALTER TABLE tasks ADD COLUMN archive_metadata TEXT")

    raw!(
      path,
      "UPDATE tasks SET result = ?1, logs = ?2, archive_metadata = ?3 WHERE id = 'kept'",
      [pack(result), pack(logs), pack(Jason.encode!([archive]))]
    )

    store = start_store!(path)
    repo = Store.__repo_pid__(store)
    assert rows(repo, "SELECT logs, updated_at FROM tasks") == [[logs, "2026-01-02T03:04:05Z"]]
    [[decoded]] = rows(repo, "SELECT result FROM tasks")

    assert decoded == result
    assert rows(repo, "SELECT archive_metadata FROM tasks") == [[Jason.encode!([archive])]]

    assert Store.get_agent_archive(store, "kept", 17)["result"] == "existing report"
    assert Store.get_agent_archive(store, "kept", 18)["result"] == "legacy report"
    assert Store.get_agent_archive(store, "kept", 18)["repo_id"] == "foreign"
    assert Store.get_agent_archive(store, "kept", 18)["compression_count"] == 2

    assert Enum.any?(
             rows(repo, "PRAGMA table_info(tasks)"),
             &(Enum.at(&1, 1) == "archive_metadata")
           )

    snapshot = snapshot(repo)
    assert Boot.run_migrations(repo) == []
    assert snapshot(repo) == snapshot
    assert @version in Enum.map(rows(repo, "SELECT version FROM schema_migrations"), &hd/1)
  end

  test "boot preflight preserves every legacy project before pending frozen version 7", %{
    path: path
  } do
    fixture!(path, @rewritten, "TEXT", false)

    # Frozen version 7 caps mounts at 100 and drops projects. A repair which
    # runs only as version 10 is too late to recover these older rows.
    for index <- 1..105 do
      suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")

      raw!(path, "INSERT INTO projects VALUES (?1, ?2, ?3)", [
        "/historical/project-#{suffix}",
        "Historical #{suffix}",
        nil
      ])
    end

    projects = raw!(path, "SELECT path, name, last_opened_at FROM projects ORDER BY path")
    assert length(projects) == 106
    task_sql = "SELECT id, type, status, opts, result, logs, updated_at FROM tasks ORDER BY id"
    tasks = raw!(path, task_sql)
    archives = raw!(path, "SELECT * FROM task_agent_archives ORDER BY task_id, agent_id")
    store = start_store!(path)
    repo = Store.__repo_pid__(store)

    assert rows(repo, "SELECT path, name, last_opened_at FROM projects ORDER BY path") == projects

    assert rows(repo, "SELECT path, name, last_opened_at FROM vct_mounts ORDER BY path") ==
             projects

    assert rows(repo, "SELECT point, kind FROM vct_mounts ORDER BY path") ==
             Enum.map(projects, fn [path, _, _] ->
               ["vct:///projects/" <> Path.basename(path), "git"]
             end)

    assert rows(repo, "SELECT version FROM schema_migrations ORDER BY version") ==
             Enum.map(@all, &[&1])

    assert rows(repo, task_sql) == tasks

    assert rows(repo, "SELECT * FROM task_agent_archives ORDER BY task_id, agent_id") == archives
    assert length(Store.list_vct_mounts(store)) == 106
    snapshot = snapshot(repo)
    assert Boot.run_migrations(repo) == []
    assert snapshot(repo) == snapshot
    stop_supervised!(store)
    restarted = start_store!(path)
    assert snapshot(Store.__repo_pid__(restarted)) == snapshot
  end

  test "ledger 4 protects compressed archives and all 101 projects from frozen migrations", %{
    path: path
  } do
    ledger4_fixture!(path, false)
    payloads = compressed_archive!(path)

    for index <- 1..100 do
      raw!(path, "INSERT INTO projects VALUES (?1, ?2, NULL)", [
        "/historical/project-#{index}",
        "Project #{index}"
      ])
    end

    projects = raw!(path, "SELECT * FROM projects ORDER BY path")
    authoritative = raw!(path, "SELECT * FROM task_agent_archives")
    store = start_store!(path)
    repo = Store.__repo_pid__(store)

    assert rows(repo, "SELECT result, logs, archive_metadata FROM tasks") == [payloads]
    assert rows(repo, "SELECT * FROM projects ORDER BY path") == projects

    assert rows(repo, "SELECT path, name, last_opened_at FROM vct_mounts ORDER BY path") ==
             projects

    assert length(Store.list_vct_mounts(store)) == 101
    assert rows(repo, "SELECT * FROM task_agent_archives WHERE agent_id = 17") == authoritative
    assert Store.get_agent_archive(store, "kept", 18)["result"] == "legacy report"
    assert rows(repo, "SELECT updated_at FROM tasks") == [["2026-01-02T03:04:05Z"]]
    assert_reconciled!(repo)
    before = snapshot(repo)
    stop_supervised!(store)
    assert snapshot(Store.__repo_pid__(start_store!(path))) == before
  end

  test "failed frozen migration leaves durable hidden sources for a fresh boot retry", %{
    path: path
  } do
    ledger4_fixture!(path, true)
    payloads = compressed_archive!(path)
    raw!(path, "ALTER TABLE vct_mounts ADD COLUMN unexpected TEXT")
    repo = start_unmigrated_repo!(path)

    assert_raise Ecto.MigrationError, ~r/vct_mounts/, fn -> Boot.run_migrations(repo) end

    assert rows(repo, "SELECT source FROM __genesis_historical_sources ORDER BY source") ==
             [["archive_metadata"], ["projects"]]

    assert rows(repo, "SELECT result, logs, __genesis_preserved_archive_metadata FROM tasks") ==
             [Enum.map(payloads, &pack/1)]

    assert rows(repo, "SELECT * FROM __genesis_preserved_projects") ==
             [["/historical/demo", "Demo", "2026-01-01T00:00:00Z"]]

    refute @version in versions(repo)
    refute Enum.at(@all, 6) in versions(repo)
    rows(repo, "ALTER TABLE vct_mounts DROP COLUMN unexpected")
    :ok = Boot.stop(repo)
    store = start_store!(path)
    repo = Store.__repo_pid__(store)
    assert rows(repo, "SELECT result, logs, archive_metadata FROM tasks") == [payloads]
    assert Store.get_agent_archive(store, "kept", 18)["result"] == "legacy report"

    assert Enum.map(Store.list_vct_mounts(store), & &1["path"]) |> Enum.sort() ==
             Enum.sort(["/existing/source", "/existing/project", "/historical/demo"])

    assert_reconciled!(repo)
  end

  test "invalid z1 rolls repair 10 back with restored source bytes and no ledger stamp", %{
    path: path
  } do
    ledger4_fixture!(path, false)
    [result, _logs, archive] = compressed_archive!(path)
    invalid = "z1:not-base64!"
    raw!(path, "UPDATE tasks SET logs = ?1", [invalid])
    repo = start_unmigrated_repo!(path)

    # result is inflated before logs: the failure must roll that update back too.
    assert_raise Ecto.MigrationError, ~r/invalid compressed JSON in tasks.logs/, fn ->
      Boot.run_migrations(repo)
    end

    assert rows(repo, "SELECT result, logs, archive_metadata FROM tasks") ==
             [[pack(result), invalid, pack(archive)]]

    assert rows(repo, "SELECT * FROM projects") ==
             [["/historical/demo", "Demo", "2026-01-01T00:00:00Z"]]

    assert rows(repo, "SELECT agent_id, result FROM task_agent_archives") ==
             [[17, "existing report"]]

    assert versions(repo) == Enum.take(@all, 9)
    assert_no_preservation!(repo)

    assert_raise Ecto.MigrationError, ~r/invalid compressed JSON/, fn ->
      Boot.run_migrations(repo)
    end

    assert rows(repo, "SELECT result, logs, archive_metadata FROM tasks") ==
             [[pack(result), invalid, pack(archive)]]
  end

  test "reserved preservation marker collision fails closed without touching sources", %{
    path: path
  } do
    ledger4_fixture!(path, false)
    compressed_archive!(path)
    raw!(path, "CREATE TABLE __genesis_historical_sources (operator_note TEXT)")
    raw!(path, "INSERT INTO __genesis_historical_sources VALUES ('do not overwrite')")
    repo = start_unmigrated_repo!(path)
    before = snapshot_without_mounts(repo)

    assert_raise Ecto.MigrationError, ~r/unsupported preservation marker shape/, fn ->
      Boot.run_migrations(repo)
    end

    assert snapshot_without_mounts(repo) == before
    assert rows(repo, "SELECT * FROM __genesis_historical_sources") == [["do not overwrite"]]
    assert versions(repo) == Enum.take(@all, 4)
  end

  defp ledger4_fixture!(path, mounts?) do
    fixture!(path, Enum.take(@all, 4), "TEXT", mounts?)
    # Ledger 4 already shipped the covering indexes; frozen prune 6 checks them.
    for {name, columns} <- @indexes do
      raw!(path, "CREATE INDEX #{name} ON tasks(#{Enum.join(columns, ", ")})")
    end
  end

  defp compressed_archive!(path) do
    archives = [
      %{"agent_id" => 17, "result" => "stale legacy report"},
      %{"agent_id" => 18, "result" => "legacy report", "repo_id" => "foreign"}
    ]

    payloads = [
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{"result" => "kept report", "archive_records" => archives}
      }),
      Jason.encode!(["historical log"]),
      Jason.encode!(archives)
    ]

    raw!(path, "ALTER TABLE tasks ADD COLUMN archive_metadata TEXT")

    raw!(
      path,
      "UPDATE tasks SET result = ?1, logs = ?2, archive_metadata = ?3",
      Enum.map(payloads, &pack/1)
    )

    payloads
  end

  defp start_unmigrated_repo!(path) do
    {:ok, repo} =
      Repo.start_link(Keyword.merge(Repo.start_opts(), database: path, name: nil, pool_size: 1))

    Process.unlink(repo)
    on_exit(fn -> if Process.alive?(repo), do: Boot.stop(repo) end)
    repo
  end

  defp versions(repo),
    do: Enum.map(rows(repo, "SELECT version FROM schema_migrations ORDER BY version"), &hd/1)

  defp assert_reconciled!(repo) do
    assert versions(repo) == @all
    assert_no_preservation!(repo)
    before = snapshot(repo)
    assert Boot.run_migrations(repo) == []
    assert snapshot(repo) == before
  end

  defp assert_no_preservation!(repo) do
    assert rows(
             repo,
             "SELECT name FROM sqlite_master WHERE name IN ('__genesis_historical_sources', '__genesis_preserved_projects')"
           ) == []

    refute Enum.any?(
             rows(repo, "PRAGMA table_info(tasks)"),
             &(Enum.at(&1, 1) == "__genesis_preserved_archive_metadata")
           )
  end

  defp snapshot_without_mounts(repo) do
    for sql <- [
          "SELECT type, name, sql FROM sqlite_master ORDER BY type, name",
          "SELECT * FROM schema_migrations ORDER BY version",
          "SELECT * FROM tasks ORDER BY id",
          "SELECT * FROM task_agent_archives ORDER BY task_id, agent_id",
          "SELECT * FROM projects ORDER BY path"
        ],
        do: rows(repo, sql)
  end

  defp fixture!(path, ledger, repo_type, mounts?) do
    # Physical task layout at 9135df985: 19 columns, no session/pause columns.
    raw!(path, """
    CREATE TABLE tasks (id TEXT PRIMARY KEY, type TEXT, status TEXT NOT NULL, opts TEXT,
      started_at TEXT, finished_at TEXT, logs TEXT, result TEXT, review_status TEXT,
      usage TEXT, agent_count INTEGER, base_sha TEXT, commit_sha TEXT,
      lease_expires_at INTEGER, model_id TEXT, project_path TEXT, branch_name TEXT,
      error TEXT, updated_at TEXT)
    """)

    raw!(path, "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, inserted_at TEXT)")

    for version <- ledger do
      raw!(path, "INSERT INTO schema_migrations VALUES (?1, '2026-01-01 00:00:00')", [version])
    end

    raw!(path, """
    CREATE TABLE task_agent_archives (
      task_id TEXT NOT NULL, agent_id INTEGER NOT NULL, parent_id INTEGER,
      depth INTEGER NOT NULL DEFAULT 0, agent_type TEXT, context_node_path TEXT,
      objective TEXT, result TEXT, base_commit TEXT, final_commit TEXT,
      branch_name TEXT, archive_ref_start TEXT, archive_ref_final TEXT,
      repo_id #{repo_type}, repo_root TEXT, repo_path TEXT, usage TEXT, llm_settings TEXT,
      agent_settings TEXT, foreign_repos TEXT, compression_count INTEGER NOT NULL DEFAULT 0,
      started_at TEXT, completed_at TEXT, PRIMARY KEY (task_id, agent_id))
    """)

    raw!(
      path,
      "INSERT INTO tasks (id, type, status, opts, result, logs, updated_at) VALUES ('kept', 'evolve', 'completed', '{}', ?1, '[]', '2026-01-02T03:04:05Z')",
      [Jason.encode!(%{"__result_tag__" => "ok", "data" => %{"result" => "kept report"}})]
    )

    raw!(
      path,
      "INSERT INTO task_agent_archives (task_id, agent_id, repo_id, result) VALUES ('kept', 17, 'foreign', 'existing report')"
    )

    raw!(path, "CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at TEXT)")
    raw!(path, "INSERT INTO projects VALUES ('/historical/demo', 'Demo', '2026-01-01T00:00:00Z')")

    if mounts? do
      raw!(
        path,
        "CREATE TABLE vct_mounts (point TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, kind TEXT NOT NULL, last_opened_at TEXT)"
      )

      raw!(
        path,
        "INSERT INTO vct_mounts VALUES ('vct:///genesis-source', '/existing/source', 'Source', 'git', NULL)"
      )

      raw!(
        path,
        "INSERT INTO vct_mounts VALUES ('vct:///projects/existing', '/existing/project', 'Existing', 'git', NULL)"
      )
    end
  end

  defp pack(json), do: "z1:" <> Base.encode64(:zlib.compress(json))

  defp start_store!(path) do
    name = :"ledger_store_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Store, data_dir: path, name: name}, id: name))
    name
  end

  defp rows(repo, sql), do: RepoScope.with_repo(repo, fn -> Repo.query!(sql).rows end)

  defp snapshot(repo) do
    for sql <- [
          "SELECT type, name, sql FROM sqlite_master ORDER BY type, name",
          "SELECT * FROM schema_migrations ORDER BY version",
          "SELECT * FROM tasks ORDER BY id",
          "SELECT * FROM task_agent_archives ORDER BY task_id, agent_id",
          "SELECT * FROM projects ORDER BY path",
          "SELECT * FROM vct_mounts ORDER BY point"
        ],
        do: rows(repo, sql)
  end

  defp raw!(path, sql, params \\ []) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :memory, synchronous: :off)

    try do
      {:ok, %{rows: rows}} = XqliteNIF.query(conn, sql, params)
      rows
    after
      XqliteNIF.close(conn)
    end
  end
end
