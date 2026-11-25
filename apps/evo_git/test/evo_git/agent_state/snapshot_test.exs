defmodule EvoGit.AgentState.SnapshotTest do
  @moduledoc """
  The shared DURABLE read model of one task's agent tree
  (`EvoGit.AgentState.Snapshot` + its `EvoGit.AgentState.snapshot/2` facade).

  Every test starts its OWN unnamed `EvoGit.AgentState` server on its own temp
  SQLite file and addresses it explicitly through the `store:` option, so the
  app-global writer is never touched — hence `async: true`. Rows are written
  through the real `checkpoint/4` path (a CAST) and every read is preceded by
  `flush/1`, so there is no `Process.sleep` anywhere.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentState.Snapshot

  @moduletag :tmp_dir

  ## Isolation helpers

  defp start_store!(tmp_dir) do
    start_supervised!(
      {AgentState,
       database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000}
    )
  end

  # One durable row with the run facts a snapshot projection needs. Fields are
  # written through the real checkpoint path, so the projection is exercised
  # against what a session really persists (JSON columns decode STRING-keyed).
  defp row!(pid, task_id, agent_id, fields) do
    fields = Map.merge(%{status: "running"}, fields)

    :ok =
      AgentState.checkpoint(task_id, agent_id, %{kind: :rewrite, messages: [], fields: fields},
        store: pid
      )

    :ok = AgentState.flush(store: pid)
    :ok
  end

  defp batch(turn, classes) do
    %{
      turn: turn,
      started_at: "2026-01-01T00:00:00Z",
      calls:
        classes
        |> Enum.with_index()
        |> Enum.map(fn {class, index} ->
          %{index: index, id: "call_#{index}", name: "tool_#{index}", class: class}
        end)
    }
  end

  ## The tree

  describe "read/2 — root + roster" do
    test "splits the roster into the ROOT record and every agent", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_snapshot_tree"

      row!(pid, task_id, 1, %{depth: 0, parent_id: nil})
      row!(pid, task_id, 2, %{depth: 1, parent_id: 1, spawn_turn: 1, spawn_index: 0})
      row!(pid, task_id, 3, %{depth: 1, parent_id: 1, spawn_turn: 1, spawn_index: 1})
      row!(pid, task_id, 4, %{depth: 2, parent_id: 2, spawn_turn: 2, spawn_index: 0})

      assert {:ok, snapshot} = Snapshot.read(task_id, store: pid)

      assert snapshot.task_id == task_id
      assert snapshot.root.agent_id == 1
      assert snapshot.root.fields[:parent_id] == nil
      # The roster keeps the store's own ordering (`depth ASC, agent_id ASC`).
      assert Enum.map(snapshot.agents, & &1.agent_id) == [1, 2, 3, 4]
      assert Snapshot.agent_ids(snapshot) == [1, 2, 3, 4]

      # The facade delegates to the same read.
      assert {:ok, %Snapshot{root: %Record{agent_id: 1}}} =
               AgentState.snapshot(task_id, store: pid)
    end

    test "an empty roster is {:error, :empty}", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      assert {:error, :empty} = Snapshot.read("task_snapshot_missing", store: pid)
      assert {:error, :empty} = Snapshot.read(nil, store: pid)
    end

    test "rows without a NIL-parent record are {:error, :no_root}", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_snapshot_no_root"

      row!(pid, task_id, 11, %{depth: 1, parent_id: 10})
      row!(pid, task_id, 12, %{depth: 2, parent_id: 11})

      assert {:error, :no_root} = Snapshot.read(task_id, store: pid)
    end

    test "an absent store is {:error, :unavailable}, never :empty", %{tmp_dir: _tmp_dir} do
      # A pid that owns no agent-state repo: `EvoGit.AgentState.repo/1` answers
      # nil, which must be reported as "cannot tell" rather than "no rows".
      assert {:error, :unavailable} = Snapshot.read("task_snapshot_unavailable", store: self())
    end
  end

  ## live/1

  describe "live/1" do
    test "keeps only the rows a run has not settled", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_snapshot_live"

      row!(pid, task_id, 1, %{depth: 0, parent_id: nil, status: "running"})
      row!(pid, task_id, 2, %{depth: 1, parent_id: 1, status: "running"})
      row!(pid, task_id, 3, %{depth: 1, parent_id: 1, status: "done"})
      # No status published yet is NOT running.
      row!(pid, task_id, 4, %{depth: 1, parent_id: 1, status: nil})

      assert {:ok, snapshot} = Snapshot.read(task_id, store: pid)
      assert Enum.map(Snapshot.live(snapshot), & &1.agent_id) == [1, 2]
      assert Snapshot.running_count(snapshot) == 2

      assert Snapshot.live(:not_a_snapshot) == []
      assert Snapshot.running_count(:not_a_snapshot) == 0
    end
  end

  ## build/2 + root?/1 — the PURE constructors

  describe "build/2" do
    test "splits an ALREADY-READ roster with no store access", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_snapshot_build"

      row!(pid, task_id, 1, %{depth: 0, parent_id: nil})
      row!(pid, task_id, 2, %{depth: 1, parent_id: 1})
      records = AgentState.roster(task_id, store: pid)

      assert {:ok, snapshot} = Snapshot.build(task_id, records)
      assert snapshot.task_id == task_id
      assert snapshot.root.agent_id == 1
      assert Snapshot.agent_ids(snapshot) == [1, 2]

      # A bounded caller's roster (the registry path) and the direct read agree
      # byte-for-byte on the value they produce.
      assert {:ok, ^snapshot} = Snapshot.read(task_id, store: pid)
    end

    test "an empty or rootless roster answers the documented error, never a crash",
         %{tmp_dir: _tmp_dir} do
      assert {:error, :empty} = Snapshot.build("task_snapshot_build_empty", [])
      assert {:error, :empty} = Snapshot.build(nil, [])
      assert {:error, :empty} = Snapshot.build("task_snapshot_build_junk", :not_a_list)

      child = %Record{task_id: "task_snapshot_build_child", agent_id: 2, fields: %{parent_id: 1}}
      assert {:error, :no_root} = Snapshot.build("task_snapshot_build_child", [child])
    end
  end

  describe "root?/1" do
    test "only a NIL-parent record is a root, and it is total over any input" do
      assert Snapshot.root?(%Record{task_id: "t", agent_id: 1, fields: %{parent_id: nil}})
      assert Snapshot.root?(%Record{task_id: "t", agent_id: 1, fields: %{}})
      refute Snapshot.root?(%Record{task_id: "t", agent_id: 2, fields: %{parent_id: 1}})
      refute Snapshot.root?(:not_a_record)
      refute Snapshot.root?(nil)
    end
  end

  ## children/3

  describe "children/3" do
    test "selects ONE parent's ONE batch, ordered by spawn_index", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_snapshot_children"

      row!(pid, task_id, 1, %{depth: 0, parent_id: nil})
      # Batch of turn 5 — deliberately inserted OUT of spawn_index order.
      row!(pid, task_id, 2, %{depth: 1, parent_id: 1, spawn_turn: 5, spawn_index: 1})
      row!(pid, task_id, 3, %{depth: 1, parent_id: 1, spawn_turn: 5, spawn_index: 0})
      row!(pid, task_id, 4, %{depth: 1, parent_id: 1, spawn_turn: 5})
      # Earlier turn, other parent: never returned.
      row!(pid, task_id, 5, %{depth: 1, parent_id: 1, spawn_turn: 4, spawn_index: 0})
      row!(pid, task_id, 6, %{depth: 2, parent_id: 2, spawn_turn: 5, spawn_index: 0})

      assert {:ok, snapshot} = Snapshot.read(task_id, store: pid)

      children = Snapshot.children(snapshot, 1, 5)
      # Integer indices first (ascending), then the index-less row.
      assert Enum.map(children, & &1.agent_id) == [3, 2, 4]

      assert Snapshot.children(snapshot, 2, 5) |> Enum.map(& &1.agent_id) == [6]
      assert Snapshot.children(snapshot, 1, 999) == []
      assert Snapshot.children(snapshot, nil, 5) == []
      assert Snapshot.children(:not_a_snapshot, 1, 5) == []
    end
  end

  ## position/1

  describe "position/1" do
    test "no marker is a turn boundary", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      row!(pid, "task_snapshot_pos", 1, %{depth: 0, parent_id: nil})

      assert {:ok, snapshot} = Snapshot.read("task_snapshot_pos", store: pid)
      assert Snapshot.position(snapshot.root) == :turn_boundary
      assert Snapshot.position(:not_a_record) == :turn_boundary
    end

    test "a pure subagent marker is a wait on children", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      row!(pid, "task_snapshot_pos_sub", 1, %{
        depth: 0,
        parent_id: nil,
        pending_tool_batch: batch(7, ["subagent", "subagent"])
      })

      assert {:ok, snapshot} = Snapshot.read("task_snapshot_pos_sub", store: pid)
      assert Snapshot.position(snapshot.root) == {:awaiting_children, 7}
    end

    test "a mixed marker is a batch, by the FIXED class order", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_snapshot_pos_batch"

      row!(pid, task_id, 1, %{
        depth: 0,
        parent_id: nil,
        pending_tool_batch: batch(3, ["read", "subagent", "shell"])
      })

      # A non-subagent call present in ANY position is a batch, and the class is
      # chosen by severity (`:shell` before `:read`), never by call order.
      assert {:ok, snapshot} = Snapshot.read(task_id, store: pid)
      assert Snapshot.position(snapshot.root) == {:batch, :shell}

      row!(pid, task_id, 2, %{
        depth: 1,
        parent_id: 1,
        pending_tool_batch: batch(4, ["edit"])
      })

      row!(pid, task_id, 3, %{
        depth: 1,
        parent_id: 1,
        pending_tool_batch: batch(5, ["read"])
      })

      assert {:ok, snapshot} = Snapshot.read(task_id, store: pid)
      records = Map.new(snapshot.agents, &{&1.agent_id, &1})

      assert Snapshot.position(records[2]) == {:batch, :edit}
      assert Snapshot.position(records[3]) == {:batch, :read}
    end
  end
end
