defmodule EvoGit.AgentState.MigrationTest do
  @moduledoc """
  End-to-end durability of the `agent_states` marker columns a resumed run
  reads after a crash: `pending_tool_batch` (the in-flight tool-batch marker,
  version 2) and `pause_commit` (the paused worktree checkpoint sha, version 3).

  Every test starts its OWN unnamed `EvoGit.AgentState` server on its own temp
  SQLite file, so the schema comes from the REAL migration chain
  (`EvoGit.AgentState.Boot.start_dynamic/2` → `000001_create_agent_state` then
  `000002_add_pending_tool_batch` then `000003_add_pause_commit` then
  `000004_add_run_facts` then `000005_agent_state_indexes`). No test
  hand-writes `CREATE TABLE`, which is what makes the assertions meaningful: if
  a later migration did not exist (or its `ALTER` were skipped), every read
  here would fail on an unknown column.

  The columns are asserted through a DIRECT `SELECT`, never only through
  `load/3`: a silently skipped column would surface as a `nil` field and could
  pass a weaker test.

  `async: true` with a parked prune timer and an explicit `store:` pid on every
  call — the app-global `EvoGit.AgentState.Server` is never touched.

  The index-only `000005_agent_state_indexes` step is covered on BOTH paths it
  ships for: a FRESH database (index names, `PRAGMA index_list` shape and the
  exact ordered columns of each index) and an UPGRADED one — a database driven
  to version 4 on a bare `EvoGit.Repo`, seeded with rows, then upgraded through
  the real `Boot.run_migrations/1`, where the two indexes must appear and every
  pre-existing row must survive untouched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ToolBatch
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Boot
  alias EvoGit.Store.RepoScope
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @moduletag :tmp_dir

  @task_id "task_pending_tool_batch"
  @agent_id 7
  @column {"pending_tool_batch", "TEXT", 0, 0}
  @pause_column {"pause_commit", "TEXT", 0, 0}

  # The two indexes `000005_agent_state_indexes` adds (the id-seed and roster
  # read paths), with the ordered columns `PRAGMA index_info/1` must report
  # back. Listed so a re-applied version 5 is proven idempotent.
  @v5_index_shapes [
    {"agent_states_agent_id_index", ["agent_id"]},
    {"agent_states_task_depth_agent_index", ["task_id", "depth", "agent_id"]}
  ]
  @v5_indexes Enum.map(@v5_index_shapes, &elem(&1, 0))

  # The rows a version-4 database already holds before the index-only step runs,
  # one with a DISTINCTIVE value in every column this fixture populates.
  @upgraded_seed [
    %{
      "task_id" => "task_upgrade_root",
      "agent_id" => 1,
      "depth" => 0,
      "parent_id" => nil,
      "objective" => "root objective",
      "branch" => "evogit-agent-upgrade",
      "status" => "done",
      "current_commit" => "aaaa1111",
      "pause_commit" => "pause-root"
    },
    %{
      "task_id" => "task_upgrade_root",
      "agent_id" => 2,
      "depth" => 1,
      "parent_id" => 1,
      "objective" => "child objective",
      "branch" => "evogit-agent-upgrade-child",
      "status" => "running",
      "current_commit" => "bbbb2222",
      "pause_commit" => nil
    },
    %{
      "task_id" => "task_upgrade_other",
      "agent_id" => 9,
      "depth" => 0,
      "parent_id" => nil,
      "objective" => "other task",
      "branch" => "evogit-agent-other",
      "status" => "done",
      "current_commit" => "cccc3333",
      "pause_commit" => "pause-other"
    }
  ]

  # The projection `upgraded_rows!/1` reads, in `ORDER BY task_id, agent_id`
  # order — derived from the seed below, so the two can never drift.
  @upgraded_projection ~w(task_id agent_id depth parent_id objective branch status
                          current_commit pause_commit)
  @upgraded_stamp "2026-08-15T00:00:00Z"

  ## Isolation / introspection helpers

  defp start_store!(tmp_dir, id) do
    start_supervised!(
      {AgentState,
       database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000},
      id: id
    )
  end

  defp checkpoint!(pid, entry) do
    :ok = AgentState.checkpoint(@task_id, @agent_id, entry, store: pid)
    :ok = AgentState.flush(store: pid)
  end

  # A bare dynamic `EvoGit.Repo` on the SAME file the agent-state server would
  # use, for the cases that must drive the migration chain THEMSELVES (bring a
  # database to one version, seed it, then apply the next version).
  defp start_bare_repo!(tmp_dir, id) do
    start_supervised!(
      Supervisor.child_spec(
        {EvoGit.Repo,
         EvoGit.Repo.start_opts() ++
           [
             database: Path.join(tmp_dir, "agent_state.sqlite"),
             name: nil,
             pool_size: 1,
             journal_mode: :wal,
             synchronous: :normal
           ]},
        id: id
      )
    )
  end

  defp sql!(pid, sql, params), do: pid |> server_repo!() |> repo_sql!(sql, params)

  defp repo_sql!(repo, sql, params) do
    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
      result
    end)
  end

  defp server_repo!(pid) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"
    repo
  end

  defp applied_versions!(pid), do: pid |> server_repo!() |> applied_versions_of!()

  defp applied_versions_of!(repo) do
    repo
    |> repo_sql!("SELECT version FROM schema_migrations ORDER BY version ASC", [])
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp state_columns!(pid), do: pid |> server_repo!() |> state_columns_of!()

  defp state_columns_of!(repo) do
    repo
    |> repo_sql!("PRAGMA table_info(agent_states)", [])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [_cid, name, type, notnull, _dflt, pk] -> {name, type, notnull, pk} end)
  end

  # Every index on `agent_states`, so "exactly once" is asserted on the real
  # catalog rather than inferred from the migration's own post-conditions.
  defp index_names!(pid), do: pid |> server_repo!() |> index_names_of!()

  defp index_names_of!(repo) do
    repo
    |> repo_sql!(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'agent_states'",
      []
    )
    |> Map.fetch!(:rows)
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp index_count!(pid, index), do: pid |> server_repo!() |> index_count_of!(index)

  defp index_count_of!(repo, index) do
    Enum.count(index_names_of!(repo), &(&1 == index))
  end

  # `PRAGMA index_list` answers `[seq, name, unique, origin, partial]` per
  # index; `PRAGMA index_info` answers `[seqno, cid, name]` in index order.
  defp index_list_of!(repo) do
    repo
    |> repo_sql!("PRAGMA index_list(agent_states)", [])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [_seq, name, unique, origin, partial] -> {name, unique, origin, partial} end)
    |> Enum.sort()
  end

  defp index_columns_of!(repo, index) do
    repo
    |> repo_sql!("PRAGMA index_info(#{index})", [])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [_seqno, _cid, name] -> name end)
  end

  defp raw_marker!(pid) do
    case sql!(
           pid,
           "SELECT pending_tool_batch FROM agent_states WHERE task_id = ? AND agent_id = ?",
           [@task_id, @agent_id]
         ).rows do
      [[value]] -> value
      [] -> :no_row
    end
  end

  defp any_message do
    %Message{role: :assistant, content: [ContentPart.text("running the batch")]}
  end

  ## Fixture: a REAL in-flight batch marker

  defp batch do
    ToolBatch.build([ReqLLM.ToolCall.new("call_1", "bash", ~s({"command":"ls"}))], 3, [])
  end

  defp json_shape(batch) do
    %{
      "turn" => batch.turn,
      "started_at" => batch.started_at,
      "calls" =>
        Enum.map(batch.calls, fn call ->
          %{
            "index" => call.index,
            "id" => call.id,
            "name" => call.name,
            "class" => Atom.to_string(call.class)
          }
        end)
    }
  end

  ## (a) The migration chain itself

  describe "migration 000002" do
    test "the real boot path adds pending_tool_batch as one nullable TEXT column", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir, :migration_shape)

      assert applied_versions!(pid) == [1, 2, 3, 4, 5]

      columns = state_columns!(pid)
      assert @column in columns

      # Exactly ONE such column: a second guarded ALTER (the shape a re-run
      # would produce if the guard were missing) cannot exist.
      assert Enum.count(columns, fn {name, _t, _n, _p} -> name == "pending_tool_batch" end) == 1

      # The pre-existing schema is untouched: the `000001` columns are all here.
      names = Enum.map(columns, &elem(&1, 0))
      assert "message_count" in names
      assert "completed_at" in names
    end
  end

  ## (a) The pause marker column

  describe "migration 000003" do
    test "the real boot path adds pause_commit as one nullable TEXT column", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir, :migration_pause_shape)

      assert applied_versions!(pid) == [1, 2, 3, 4, 5]

      columns = state_columns!(pid)
      assert @pause_column in columns
      assert Enum.count(columns, fn {name, _t, _n, _p} -> name == "pause_commit" end) == 1

      # The version-2 column is still exactly as it was: the new migration
      # appends a column and touches nothing else.
      assert @column in columns
    end
  end

  ## (a) The index-only step

  describe "migration 000005" do
    test "the real boot path adds the id-seed and roster indexes exactly once", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir, :migration_indexes)

      assert applied_versions!(pid) == [1, 2, 3, 4, 5]

      for index <- @v5_indexes do
        assert index_count!(pid, index) == 1,
               "expected index #{index} exactly once, got #{inspect(index_names!(pid))}"
      end

      # The index-only step changes no shape: both marker columns are still
      # exactly one nullable TEXT column each.
      assert Enum.count(state_columns!(pid), &(elem(&1, 0) == "pending_tool_batch")) == 1
      assert Enum.count(state_columns!(pid), &(elem(&1, 0) == "pause_commit")) == 1
    end

    test "down/0 drops both indexes and a re-run restores them", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, :migration_indexes_rollback)

      for index <- @v5_indexes, do: assert(index_count!(pid, index) == 1)

      assert :ok = run_down!(pid, 5)
      refute 5 in applied_versions!(pid)

      for index <- @v5_indexes do
        assert index_count!(pid, index) == 0,
               "index #{index} survived the rollback: #{inspect(index_names!(pid))}"
      end

      # The index-only migration owns no columns and no data: both marker
      # columns survive the rollback.
      assert Enum.count(state_columns!(pid), &(elem(&1, 0) == "pending_tool_batch")) == 1
      assert Enum.count(state_columns!(pid), &(elem(&1, 0) == "pause_commit")) == 1

      # Re-applying restores both indexes, and the chain ends at 5 again.
      assert {:ok, [5]} = Boot.run_migrations(AgentState.repo(pid))
      assert applied_versions!(pid) == [1, 2, 3, 4, 5]

      for index <- @v5_indexes, do: assert(index_count!(pid, index) == 1)
    end

    test "both indexes sit on their documented columns", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, :migration_index_columns)
      repo = server_repo!(pid)
      list = index_list_of!(repo)

      for {index, columns} <- @v5_index_shapes do
        # `{name, unique?, origin, partial?}`: a plain, non-unique,
        # non-partial index created by `CREATE INDEX` — not a constraint index.
        assert {index, 0, "c", 0} in list,
               "expected #{index} as a plain catalog index, got #{inspect(list)}"

        # The COLUMN ORDER is load-bearing: the id seed needs `agent_id` as its
        # only key and the roster read needs exactly `(task_id, depth, agent_id)`.
        assert index_columns_of!(repo, index) == columns,
               "index #{index} must be on (#{Enum.join(columns, ", ")}), " <>
                 "got #{inspect(index_columns_of!(repo, index))}"
      end

      # Purely additive: the retention (v1) and batch (v4) indexes survive.
      for index <- [
            "agent_states_status_completed_at_index",
            "agent_states_updated_at_index",
            "agent_states_task_parent_index"
          ] do
        assert {index, 0, "c", 0} in list, "expected index #{index}, got #{inspect(list)}"
      end
    end
  end

  ## (a) The same step as a real UPGRADE of an existing database

  describe "migration 000005 on an upgraded database" do
    test "a version-4 database gains both indexes on their columns and keeps its rows",
         %{tmp_dir: tmp_dir} do
      repo = start_bare_repo!(tmp_dir, :migration_upgrade_repo)

      # Exactly the file the previous release leaves behind: versions 1-4
      # stamped, version 5 pending, neither v5 index present. Driving the chain
      # directly (rather than rolling version 5 back) keeps the pre-state
      # independent of `down/0`.
      assert migrate_through!(repo, 4) == [1, 2, 3, 4]
      assert applied_versions_of!(repo) == [1, 2, 3, 4]

      for {index, _columns} <- @v5_index_shapes do
        assert index_count_of!(repo, index) == 0,
               "index #{index} must not exist before version 5"
      end

      seed_upgraded_rows!(repo)

      # The real upgrade step: `run_migrations/1` applies only what is pending.
      assert {:ok, [5]} = Boot.run_migrations(repo)
      assert applied_versions_of!(repo) == [1, 2, 3, 4, 5]

      for {index, columns} <- @v5_index_shapes do
        assert index_count_of!(repo, index) == 1,
               "expected index #{index} exactly once, got #{inspect(index_names_of!(repo))}"

        assert index_columns_of!(repo, index) == columns
      end

      # Index-only: every row the old release wrote is still there, byte for
      # byte in every column it populated.
      assert upgraded_rows!(repo) == expected_upgraded_rows()
    end
  end

  ## (a) + (b) durable marker + load/normalize round-trip

  describe "pending_tool_batch durability" do
    test "a checkpointed in-flight batch is JSON in the column and loads back through normalize/1",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, :migration_roundtrip)
      batch = batch()

      # Guard the FIXTURE: a `nil` marker would make every assertion vacuous.
      assert %{turn: 3, calls: [%{id: "call_1", name: "bash"} = call]} = batch
      assert call.class in [:subagent, :shell, :edit, :write, :read]

      checkpoint!(pid, %{
        kind: :rewrite,
        messages: [any_message()],
        fields: %{pending_tool_batch: batch}
      })

      # (a) The ROW holds non-null JSON — a skipped column reads `nil` here.
      raw = raw_marker!(pid)
      assert is_binary(raw), "expected non-nil JSON in pending_tool_batch, got #{inspect(raw)}"
      assert {:ok, decoded} = Jason.decode(raw)
      assert decoded == json_shape(batch)

      # (b) `load/3` surfaces it and `normalize/1` restores the atom-keyed shape.
      assert {:ok, record} = AgentState.load(@task_id, @agent_id, store: pid)
      stored = record.fields[:pending_tool_batch]
      assert is_map(stored)
      assert ToolBatch.normalize(stored) == batch
      assert ToolBatch.class_counts(stored) == ToolBatch.class_counts(batch)
    end
  end

  ## (c) clearing the marker

  describe "clearing" do
    test "a checkpoint with a nil marker clears the column", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, :migration_clear)

      checkpoint!(pid, %{
        kind: :rewrite,
        messages: [any_message()],
        fields: %{pending_tool_batch: batch()}
      })

      assert is_binary(raw_marker!(pid))

      checkpoint!(pid, %{
        kind: :append,
        base_seq: 1,
        messages: [],
        fields: %{pending_tool_batch: nil}
      })

      assert raw_marker!(pid) == nil
      assert {:ok, record} = AgentState.load(@task_id, @agent_id, store: pid)
      assert record.fields[:pending_tool_batch] == nil
    end
  end

  ## (d) idempotent reuse of an existing data dir

  describe "existing data dir" do
    test "a second boot over the same file keeps the column and its data, and a re-run is a no-op",
         %{tmp_dir: tmp_dir} do
      batch = batch()

      first = start_store!(tmp_dir, :migration_first)

      checkpoint!(first, %{
        kind: :rewrite,
        messages: [any_message()],
        fields: %{pending_tool_batch: batch}
      })

      assert is_binary(raw_marker!(first))
      :ok = stop_supervised(:migration_first)

      # A SECOND boot over the SAME file: every version is already stamped, so
      # the chain must apply nothing and the stored row must survive untouched.
      second = start_store!(tmp_dir, :migration_second)

      assert applied_versions!(second) == [1, 2, 3, 4, 5]
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pending_tool_batch")) == 1
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pause_commit")) == 1

      for index <- @v5_indexes do
        assert index_count!(second, index) == 1
      end

      assert {:ok, record} = AgentState.load(@task_id, @agent_id, store: second)
      assert ToolBatch.normalize(record.fields[:pending_tool_batch]) == batch

      # Force versions 2, 3, 4 AND 5 to re-apply on the SAME database: the
      # probe guard turns each ALTER into a no-op (an unguarded re-run fails
      # with "duplicate column name"), `CREATE INDEX IF NOT EXISTS` leaves the
      # existing indexes alone, and the stored rows are left untouched.
      for version <- [2, 3, 4, 5] do
        sql!(second, "DELETE FROM schema_migrations WHERE version = ?", [version])
      end

      # A re-run must report the migrated versions (only the four deleted ones
      # are pending) — never merely "some list".
      assert {:ok, reapplied} = Boot.run_migrations(AgentState.repo(second))
      assert Enum.sort(reapplied) == [2, 3, 4, 5]

      assert applied_versions!(second) == [1, 2, 3, 4, 5]
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pending_tool_batch")) == 1
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pause_commit")) == 1

      # Version 5 is idempotent too: each index still exists EXACTLY once (a
      # second, differently-named duplicate would show up as a second entry;
      # SQLite would also have refused a duplicate name).
      for index <- @v5_indexes do
        assert index_count!(second, index) == 1
      end

      assert {:ok, reloaded} = AgentState.load(@task_id, @agent_id, store: second)
      assert ToolBatch.normalize(reloaded.fields[:pending_tool_batch]) == batch
      assert reloaded.message_count == record.message_count
      assert reloaded.chunk_count == record.chunk_count
    end
  end

  ## Migration-source helper

  # The migration module is reached through `Boot.migration_source/0` (public
  # seam) so this file never names a runtime-compiled module directly. Its error
  # shape is handled explicitly: `{:error, :migration_lock_unavailable}` fed to
  # `Enum.find/2` would raise an opaque `Protocol.UndefinedError`.
  defp migration_source! do
    case Boot.migration_source() do
      {:error, reason} ->
        flunk("the agent-state migration source is unavailable: #{inspect(reason)}")

      source when is_list(source) ->
        source
    end
  end

  defp run_down!(pid, version) do
    {^version, module} = Enum.find(migration_source!(), fn {v, _m} -> v == version end)

    assert [^version] =
             RepoScope.with_repo(AgentState.repo(pid), fn ->
               Ecto.Migrator.run(EvoGit.Repo, [{version, module}], :down, all: true, log: false)
             end)

    :ok
  end

  ## Version-4 (pre-index) database helpers

  # Applies the chain UP TO `last_version`, so the next boot / `run_migrations/1`
  # is a genuine upgrade step rather than a fresh install.
  defp migrate_through!(repo, last_version) do
    source =
      migration_source!()
      |> Enum.filter(fn {version, _module} -> version <= last_version end)

    # Guard the fixture: a filtered chain must be exactly 1..last_version.
    assert Enum.map(source, &elem(&1, 0)) == Enum.to_list(1..last_version)

    RepoScope.with_repo(repo, fn ->
      Ecto.Migrator.run(EvoGit.Repo, source, :up, all: true, log: false)
    end)
  end

  defp seed_upgraded_rows!(repo) do
    for seed <- @upgraded_seed do
      row =
        Map.merge(seed, %{
          "created_at" => @upgraded_stamp,
          "updated_at" => @upgraded_stamp,
          "completed_at" => @upgraded_stamp
        })

      columns = row |> Map.keys() |> Enum.sort()
      values = Enum.map(columns, &Map.fetch!(row, &1))
      placeholders = Enum.map_join(1..length(columns), ", ", fn index -> "?#{index}" end)

      assert %{num_rows: 1} =
               repo_sql!(
                 repo,
                 "INSERT INTO agent_states (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
                 values
               )
    end
  end

  defp upgraded_rows!(repo) do
    projection = Enum.join(@upgraded_projection, ", ")

    repo
    |> repo_sql!(
      "SELECT #{projection} FROM agent_states ORDER BY task_id ASC, agent_id ASC",
      []
    )
    |> Map.fetch!(:rows)
    |> Enum.map(&List.to_tuple/1)
  end

  defp expected_upgraded_rows do
    @upgraded_seed
    |> Enum.sort_by(fn seed -> {seed["task_id"], seed["agent_id"]} end)
    |> Enum.map(fn seed ->
      @upgraded_projection
      |> Enum.map(&Map.fetch!(seed, &1))
      |> List.to_tuple()
    end)
  end
end
