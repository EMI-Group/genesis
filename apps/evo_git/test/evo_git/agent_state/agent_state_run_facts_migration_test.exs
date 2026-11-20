defmodule EvoGit.AgentState.RunFactsMigrationTest do
  @moduledoc """
  Migration `000004_add_run_facts` on the REAL migration chain: the seven v2
  run-fact columns, the `(task_id, parent_id)` roster index, the
  `completed → done` status normalization and a rollback that removes ONLY what
  the migration added — plus the index families `000005_agent_state_indexes`
  adds (`MAX(agent_id)` id-seed and `ORDER BY depth, agent_id` roster reads).

  Every test starts its own unnamed `EvoGit.AgentState` server on its own temp
  SQLite file, so the schema comes from
  `EvoGit.AgentState.Boot.start_dynamic/2` → `000001_create_agent_state`,
  `000002_add_pending_tool_batch`, `000003_add_pause_commit`,
  `000004_add_run_facts`, then the index-only
  `000005_agent_state_indexes`. No test hand-writes the v2 schema; the chain is
  asserted END TO END as `@versions` (`1..5`), so a boot that quietly stopped
  one version short cannot pass.

  The UPGRADE case is the important one: it builds a version-3 database by hand
  (raw `Xqlite`, exactly the file an earlier release left on disk, stamped in
  `schema_migrations` as versions 1-3) holding a row with
  `status = 'completed'` and a distinctive value in every pre-existing column,
  then lets the real boot path upgrade it. That is what makes the assertions
  meaningful — a skipped `ALTER` would surface as an unknown column and a
  skipped normalization as a surviving `'completed'`.

  `async: true` with an explicit `store:` server pid; the app-global
  `EvoGit.AgentState.Server` is never touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Boot
  alias EvoGit.Store.RepoScope

  @moduletag :tmp_dir

  @versions [1, 2, 3, 4, 5]
  @retention_indexes ["agent_states_status_completed_at_index", "agent_states_updated_at_index"]
  @roster_index "agent_states_task_parent_index"

  # The two indexes `000005_agent_state_indexes` adds: the `MAX(agent_id)` seed
  # and the `roster/2` `ORDER BY depth, agent_id` read paths.
  @v5_indexes ["agent_states_agent_id_index", "agent_states_task_depth_agent_index"]

  # Every index family a booted (or upgraded) database must carry.
  @all_indexes @retention_indexes ++ [@roster_index] ++ @v5_indexes

  @run_fact_columns [
    {"spawn_turn", "INTEGER", 0, 0},
    {"spawn_index", "INTEGER", 0, 0},
    {"branch", "TEXT", 0, 0},
    {"base_commit", "TEXT", 0, 0},
    {"anchor_ref", "TEXT", 0, 0},
    {"redispatch", "TEXT", 0, 0},
    {"result", "TEXT", 0, 0}
  ]

  @run_fact_names Enum.map(@run_fact_columns, &elem(&1, 0))

  ## Fixtures: the version-3 file an earlier release left on disk

  # `000001_create_agent_state`'s table PLUS the two columns versions 2 and 3
  # appended. Written by hand on purpose: the point is the shape a PREVIOUS
  # release has on disk, not what the current modules would build.
  @v3_states_ddl """
  CREATE TABLE agent_states (
    task_id TEXT NOT NULL,
    agent_id INTEGER NOT NULL,
    agent_module TEXT,
    depth INTEGER NOT NULL DEFAULT 0,
    parent_id INTEGER,
    node_path TEXT,
    repo_id TEXT,
    repo_less INTEGER NOT NULL DEFAULT 0,
    repo_root TEXT,
    custom_agent_id TEXT,
    mode TEXT,
    archive INTEGER NOT NULL DEFAULT 0,
    objective TEXT,
    model_spec TEXT,
    provider_profile_id TEXT,
    model_id TEXT,
    model_id_locked INTEGER NOT NULL DEFAULT 0,
    prompt_cache_key TEXT,
    llm_model TEXT,
    llm_context_window INTEGER,
    turn INTEGER NOT NULL DEFAULT 0,
    usage TEXT,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    compression_count INTEGER NOT NULL DEFAULT 0,
    current_commit TEXT,
    phase TEXT,
    pending_inputs TEXT,
    format_version INTEGER NOT NULL DEFAULT 1,
    message_count INTEGER NOT NULL DEFAULT 0,
    chunk_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'running',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    pending_tool_batch TEXT,
    pause_commit TEXT,
    PRIMARY KEY (task_id, agent_id)
  )
  """

  @v3_chunks_ddl """
  CREATE TABLE agent_state_chunks (
    task_id TEXT NOT NULL,
    agent_id INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    message_count INTEGER NOT NULL,
    payload BLOB NOT NULL,
    inserted_at TEXT NOT NULL,
    PRIMARY KEY (task_id, agent_id, seq)
  )
  """

  @schema_migrations_ddl """
  CREATE TABLE "schema_migrations" ("version" INTEGER PRIMARY KEY, "inserted_at" TEXT)
  """

  @stamped_at "2026-08-15 00:00:00"
  @task_id "task_run_facts_upgrade"
  @agent_id 3

  # Every pre-existing column this fixture populates, with a DISTINCTIVE value:
  # after the upgrade the same column must still hold the same value.
  @v3_row [
    {"task_id", @task_id},
    {"agent_id", @agent_id},
    {"agent_module", "EvoGit.Agents.Investigator"},
    {"depth", 1},
    {"parent_id", 1},
    {"node_path", "./lib"},
    {"repo_id", "primary"},
    {"repo_less", 0},
    {"repo_root", "/tmp/legacy-repo"},
    {"custom_agent_id", "custom_legacy"},
    {"mode", "evolve"},
    {"archive", 1},
    {"objective", "legacy objective"},
    {"model_spec", ~s({"provider_profile_id":"acct","model":"m"})},
    {"provider_profile_id", "acct"},
    {"model_id", "acct"},
    {"model_id_locked", 1},
    {"prompt_cache_key", "cache-key-legacy"},
    {"llm_model", "openai:gpt-x"},
    {"llm_context_window", 200_000},
    {"turn", 4},
    {"usage", ~s({"total_tokens":42})},
    {"total_tokens", 42},
    {"compression_count", 2},
    {"current_commit", "abc123"},
    {"phase", "running"},
    {"pending_inputs", "[]"},
    {"format_version", 1},
    {"message_count", 0},
    {"chunk_count", 0},
    {"status", "completed"},
    {"created_at", "2026-08-15T00:00:00Z"},
    {"updated_at", "2026-08-15T00:00:01Z"},
    {"completed_at", "2026-08-15T00:00:02Z"},
    {"pending_tool_batch", nil},
    {"pause_commit", "pause123"}
  ]

  ## Isolation / introspection helpers

  defp start_store!(tmp_dir, id) do
    start_supervised!(
      {AgentState,
       database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000},
      id: id
    )
  end

  defp sql!(pid, statement, params) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), statement, params)
      result
    end)
  end

  defp rows!(pid, statement, params \\ []) do
    pid |> sql!(statement, params) |> Map.fetch!(:rows)
  end

  defp applied_versions!(pid) do
    pid
    |> rows!("SELECT version FROM schema_migrations ORDER BY version ASC")
    |> List.flatten()
  end

  defp state_columns!(pid) do
    pid
    |> rows!("PRAGMA table_info(agent_states)")
    |> Enum.map(fn [_cid, name, type, notnull, _dflt, pk] -> {name, type, notnull, pk} end)
  end

  defp index_names!(pid) do
    pid
    |> rows!("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'agent_states'")
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp state_row!(pid) do
    %{columns: columns, rows: [values | _rest]} =
      pid |> sql!("SELECT * FROM agent_states WHERE task_id = ?", [@task_id])

    Map.new(Enum.zip(columns, values))
  end

  defp column_count(columns, name), do: Enum.count(columns, &(elem(&1, 0) == name))

  ## Raw fixture writing (no app code, no repo)

  defp build_v3_database!(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <- [@v3_states_ddl, @v3_chunks_ddl, @schema_migrations_ddl] do
      exec!(conn, ddl)
    end

    exec!(
      conn,
      "CREATE INDEX IF NOT EXISTS agent_states_status_completed_at_index " <>
        "ON agent_states (status, completed_at)"
    )

    exec!(
      conn,
      "CREATE INDEX IF NOT EXISTS agent_states_updated_at_index ON agent_states (updated_at)"
    )

    for version <- [1, 2, 3] do
      exec!(conn, "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
        version,
        @stamped_at
      ])
    end

    insert_row!(conn, @v3_row)
    :ok = XqliteNIF.close(conn)
    :ok
  end

  # Numbered placeholders, one per column, built from the fixture list — the
  # statement shape never depends on a hand-counted `?` run.
  defp insert_row!(conn, columns_and_values) do
    {columns, values} = Enum.unzip(columns_and_values)

    placeholders =
      Enum.map_join(1..length(columns), ", ", fn index -> "?#{index}" end)

    exec!(
      conn,
      "INSERT INTO agent_states (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
      values
    )
  end

  defp exec!(conn, statement, params \\ []),
    do: {:ok, _result} = XqliteNIF.query(conn, statement, params)

  ## (a) A fresh database

  test "a fresh boot ends with all seven run-fact columns and every index family", %{
    tmp_dir: tmp_dir
  } do
    pid = start_store!(tmp_dir, :run_facts_fresh)

    assert applied_versions!(pid) == @versions

    columns = state_columns!(pid)

    for shape <- @run_fact_columns do
      assert shape in columns
      assert column_count(columns, elem(shape, 0)) == 1
    end

    # The migration is purely additive: the version-1..3 columns are all here.
    names = Enum.map(columns, &elem(&1, 0))

    for name <- ~w(message_count chunk_count completed_at pending_tool_batch pause_commit) do
      assert name in names
    end

    indexes = index_names!(pid)

    for name <- @all_indexes do
      assert name in indexes, "expected index #{name}, got #{inspect(indexes)}"
    end
  end

  ## (b) A version-3 database an earlier release left behind

  test "a version-3 database upgrades in place: completed becomes done, every value intact", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "agent_state.sqlite")
    build_v3_database!(path)

    pid = start_store!(tmp_dir, :run_facts_upgrade)

    assert applied_versions!(pid) == @versions

    columns = state_columns!(pid)
    for shape <- @run_fact_columns, do: assert(shape in columns)

    row = state_row!(pid)
    assert row["status"] == "done", "the legacy 'completed' status must normalize to 'done'"

    # Every pre-existing column still holds exactly what the old release wrote,
    # INCLUDING the run-fact columns the migration never touches.
    for {column, value} <- @v3_row, column != "status" do
      assert Map.get(row, column) == value,
             "column #{column} changed: #{inspect(Map.get(row, column))} != #{inspect(value)}"
    end

    # NULL is the truth for the seven new facts on a legacy row.
    for name <- @run_fact_names, do: assert(Map.get(row, name) == nil)

    indexes = index_names!(pid)
    for name <- @all_indexes, do: assert(name in indexes)
  end

  ## (c) Re-running up/0

  test "re-running up/0 is a no-op: the columns, the index and the data stay as they are", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "agent_state.sqlite")
    build_v3_database!(path)

    pid = start_store!(tmp_dir, :run_facts_rerun)
    assert applied_versions!(pid) == @versions

    # Force version 4 to re-apply on the SAME database. An unguarded re-run
    # fails with "duplicate column name" / "index already exists".
    sql!(pid, "DELETE FROM schema_migrations WHERE version = ?", [4])
    assert {:ok, [4]} = Boot.run_migrations(AgentState.repo(pid))

    assert applied_versions!(pid) == @versions

    columns = state_columns!(pid)
    for name <- @run_fact_names, do: assert(column_count(columns, name) == 1)

    indexes = index_names!(pid)
    assert Enum.count(indexes, &(&1 == @roster_index)) == 1
    for name <- @retention_indexes, do: assert(name in indexes)

    row = state_row!(pid)
    assert row["status"] == "done"
    assert row["objective"] == "legacy objective"
    assert row["pause_commit"] == "pause123"
  end

  ## (d) Rollback

  test "down/0 removes only what the migration added and a re-run restores it", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "agent_state.sqlite")
    build_v3_database!(path)

    pid = start_store!(tmp_dir, :run_facts_rollback)
    assert applied_versions!(pid) == @versions

    # The v2 facts of a live run, then the rollback.
    sql!(
      pid,
      "UPDATE agent_states SET spawn_turn = ?, spawn_index = ?, branch = ?, " <>
        "base_commit = ?, anchor_ref = ?, redispatch = ?, result = ? WHERE task_id = ?",
      [
        3,
        1,
        "evogit-agent-t-a",
        "base-sha",
        "refs/genesis/agent-state/t/3",
        ~s({"a":1}),
        ~s({"text":"done"}),
        @task_id
      ]
    )

    assert :ok = run_down!(pid)
    refute 4 in applied_versions!(pid)

    columns = state_columns!(pid)
    for name <- @run_fact_names, do: assert(column_count(columns, name) == 0)

    indexes = index_names!(pid)
    refute @roster_index in indexes
    for name <- @retention_indexes, do: assert(name in indexes)

    # The ROWS were not the migration's to remove: everything a v3 database had
    # is still there, its `done` status included (a status value is data).
    row = state_row!(pid)
    assert row["status"] == "done"
    assert row["objective"] == "legacy objective"
    assert row["current_commit"] == "abc123"

    # Re-applying the migration restores the facts' columns, empty for that row.
    assert {:ok, [4]} = Boot.run_migrations(AgentState.repo(pid))
    assert applied_versions!(pid) == @versions

    columns = state_columns!(pid)
    for shape <- @run_fact_columns, do: assert(shape in columns)
    assert @roster_index in index_names!(pid)
    assert state_row!(pid)["spawn_turn"] == nil
  end

  # The migration module is reached through `Boot.migration_source/0` (public
  # seam) so this file never names a runtime-compiled module directly.
  #
  # `migration_source/0` answers `{:error, :migration_lock_unavailable}` when
  # the source is not memoized yet AND the migration lock could not be taken, so
  # the error shape is handled explicitly here — feeding it to `Enum.find/2`
  # would crash with an opaque `Protocol.UndefinedError`.
  defp run_down!(pid) do
    source =
      case Boot.migration_source() do
        {:error, reason} ->
          flunk("the agent-state migration source is unavailable: #{inspect(reason)}")

        source when is_list(source) ->
          source
      end

    {4, module} = Enum.find(source, fn {version, _m} -> version == 4 end)

    assert [4] =
             RepoScope.with_repo(AgentState.repo(pid), fn ->
               Ecto.Migrator.run(EvoGit.Repo, [{4, module}], :down, all: true, log: false)
             end)

    :ok
  end
end
