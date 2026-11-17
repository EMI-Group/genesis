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

      assert rows(repo, "SELECT session_mode, pause_kind FROM tasks") == [["oneshot", nil]]

      assert Enum.find(
               rows(repo, "PRAGMA table_info(task_agent_archives)"),
               &(Enum.at(&1, 1) == "repo_id")
             )
             |> Enum.at(2) == "TEXT"

      assert rows(repo, "PRAGMA table_info(projects)") == []

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

    assert Jason.decode!(decoded) == %{
             "__result_tag__" => "ok",
             "data" => %{"result" => "kept report"}
           }

    assert Store.get_agent_archive(store, "kept", 17)["result"] == "existing report"
    assert Store.get_agent_archive(store, "kept", 18)["result"] == "legacy report"
    assert Store.get_agent_archive(store, "kept", 18)["repo_id"] == "foreign"
    assert Store.get_agent_archive(store, "kept", 18)["compression_count"] == 2

    refute Enum.any?(
             rows(repo, "PRAGMA table_info(tasks)"),
             &(Enum.at(&1, 1) == "archive_metadata")
           )

    snapshot = snapshot(repo)
    assert Boot.run_migrations(repo) == []
    assert snapshot(repo) == snapshot
    assert @version in Enum.map(rows(repo, "SELECT version FROM schema_migrations"), &hd/1)
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
        "CREATE TABLE vct_mounts (point TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'git', last_opened_at TEXT)"
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
