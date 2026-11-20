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
  # read paths). Listed so a re-applied version 5 is proven idempotent.
  @v5_indexes ["agent_states_agent_id_index", "agent_states_task_depth_agent_index"]

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

  defp sql!(pid, sql, params) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
      result
    end)
  end

  defp applied_versions!(pid) do
    pid
    |> sql!("SELECT version FROM schema_migrations ORDER BY version ASC", [])
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp state_columns!(pid) do
    pid
    |> sql!("PRAGMA table_info(agent_states)", [])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [_cid, name, type, notnull, _dflt, pk] -> {name, type, notnull, pk} end)
  end

  # Every index on `agent_states`, so "exactly once" is asserted on the real
  # catalog rather than inferred from the migration's own post-conditions.
  defp index_names!(pid) do
    pid
    |> sql!(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'agent_states'",
      []
    )
    |> Map.fetch!(:rows)
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp index_count!(pid, index) do
    Enum.count(index_names!(pid), &(&1 == index))
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

  ## Rollback helper

  # The migration module is reached through `Boot.migration_source/0` (public
  # seam) so this file never names a runtime-compiled module directly. Its error
  # shape is handled explicitly: `{:error, :migration_lock_unavailable}` fed to
  # `Enum.find/2` would raise an opaque `Protocol.UndefinedError`.
  defp run_down!(pid, version) do
    source =
      case Boot.migration_source() do
        {:error, reason} ->
          flunk("the agent-state migration source is unavailable: #{inspect(reason)}")

        source when is_list(source) ->
          source
      end

    {^version, module} = Enum.find(source, fn {v, _m} -> v == version end)

    assert [^version] =
             RepoScope.with_repo(AgentState.repo(pid), fn ->
               Ecto.Migrator.run(EvoGit.Repo, [{version, module}], :down, all: true, log: false)
             end)

    :ok
  end
end
