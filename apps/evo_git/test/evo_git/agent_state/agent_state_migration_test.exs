defmodule EvoGit.AgentState.MigrationTest do
  @moduledoc """
  End-to-end durability of the `agent_states` marker columns a resumed run
  reads after a crash: `pending_tool_batch` (the in-flight tool-batch marker,
  version 2) and `pause_commit` (the paused worktree checkpoint sha, version 3).

  Every test starts its OWN unnamed `EvoGit.AgentState` server on its own temp
  SQLite file, so the schema comes from the REAL migration chain
  (`EvoGit.AgentState.Boot.start_dynamic/2` → `000001_create_agent_state` then
  `000002_add_pending_tool_batch` then `000003_add_pause_commit` then
  `000004_add_run_facts`). No test
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

      assert applied_versions!(pid) == [1, 2, 3, 4]

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

      assert applied_versions!(pid) == [1, 2, 3, 4]

      columns = state_columns!(pid)
      assert @pause_column in columns
      assert Enum.count(columns, fn {name, _t, _n, _p} -> name == "pause_commit" end) == 1

      # The version-2 column is still exactly as it was: the new migration
      # appends a column and touches nothing else.
      assert @column in columns
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

      # A SECOND boot over the SAME file: versions 2 and 3 are already stamped,
      # so the chain must apply nothing and the stored row must survive
      # untouched.
      second = start_store!(tmp_dir, :migration_second)

      assert applied_versions!(second) == [1, 2, 3, 4]
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pending_tool_batch")) == 1
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pause_commit")) == 1
      assert {:ok, record} = AgentState.load(@task_id, @agent_id, store: second)
      assert ToolBatch.normalize(record.fields[:pending_tool_batch]) == batch

      # Force versions 2, 3 and 4 to re-apply on the SAME database: the probe
      # guard turns each ALTER into a no-op (an unguarded re-run fails with
      # "duplicate column name") and the stored rows are left alone.
      sql!(second, "DELETE FROM schema_migrations WHERE version = ?", [2])
      sql!(second, "DELETE FROM schema_migrations WHERE version = ?", [3])
      sql!(second, "DELETE FROM schema_migrations WHERE version = ?", [4])
      assert is_list(Boot.run_migrations(AgentState.repo(second)))

      assert applied_versions!(second) == [1, 2, 3, 4]
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pending_tool_batch")) == 1
      assert Enum.count(state_columns!(second), &(elem(&1, 0) == "pause_commit")) == 1
      assert {:ok, reloaded} = AgentState.load(@task_id, @agent_id, store: second)
      assert ToolBatch.normalize(reloaded.fields[:pending_tool_batch]) == batch
    end
  end
end
