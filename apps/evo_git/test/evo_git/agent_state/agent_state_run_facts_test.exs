defmodule EvoGit.AgentState.RunFactsTest do
  @moduledoc """
  The v2 run-fact surface of `EvoGit.AgentState` / `EvoGit.AgentState.Store`:
  `roster/2` (the whole agent tree of one task in ONE read), `max_agent_id/1`
  (the id sequence a restart must not collide with), `mark_done/5` (a run
  finishing with its result and commit) and `delete_done_children/4` (a parent
  consuming the done children of ONE tool batch).

  Every test starts its OWN unnamed `EvoGit.AgentState` server on a per-test
  SQLite file and addresses it through `store: pid`, so the app-global
  `EvoGit.AgentState.Server` is never touched — hence `async: true`.
  Checkpoints AND the bookkeeping writes are CASTS, so every read-backed
  assertion follows `EvoGit.AgentState.flush/1` (the read-your-writes barrier);
  there is no `Process.sleep` anywhere.

  These cases cannot pass on the pre-v2 store: the columns do not exist, there
  is no roster read at all and a finished row was spelled `completed`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentState.Store
  alias EvoGit.Store.RepoScope
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @moduletag :tmp_dir

  ## Isolation helpers

  defp start_store!(tmp_dir) do
    start_supervised!(
      {AgentState,
       database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000}
    )
  end

  defp flush!(pid), do: assert(:ok = AgentState.flush(store: pid))

  # One row with a full run-fact shape: one empty-tail checkpoint supplies
  # every scalar, exactly the way a session's turn-boundary checkpoint does.
  defp row!(pid, task_id, agent_id, fields) do
    :ok =
      AgentState.checkpoint(task_id, agent_id, %{kind: :rewrite, messages: [], fields: fields},
        store: pid
      )

    :ok = AgentState.flush(store: pid)
    :ok
  end

  defp sql!(pid, statement, params) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), statement, params)
      result
    end)
  end

  defp raw_row!(pid, task_id, agent_id, columns) do
    case sql!(
           pid,
           "SELECT #{Enum.join(columns, ", ")} FROM agent_states " <>
             "WHERE task_id = ? AND agent_id = ?",
           [task_id, agent_id]
         ).rows do
      [values] -> Map.new(Enum.zip(columns, values))
      [] -> :no_row
    end
  end

  defp chunk_count!(pid, task_id, agent_id) do
    [[count]] =
      sql!(
        pid,
        "SELECT COUNT(*) FROM agent_state_chunks WHERE task_id = ? AND agent_id = ?",
        [task_id, agent_id]
      ).rows

    count
  end

  # A row WITH a chunk, so a delete can be proven to take the chunks with it.
  defp run_with_messages!(pid, task_id, agent_id, fields) do
    message = %Message{role: :assistant, content: [ContentPart.text("#{agent_id} reply")]}

    :ok =
      AgentState.checkpoint(
        task_id,
        agent_id,
        %{kind: :rewrite, messages: [message], fields: fields},
        store: pid
      )

    :ok = AgentState.flush(store: pid)
    assert chunk_count!(pid, task_id, agent_id) == 1
    :ok
  end

  defp ids(records), do: Enum.map(records, & &1.agent_id)

  ## roster/2

  describe "roster/2" do
    test "returns the whole tree of ONE task ordered depth ASC then agent_id ASC", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)

      # Deliberately created OUT of order, with an id (4) that is SMALLER than a
      # shallower sibling's (5): only a real `depth ASC, agent_id ASC` ordering
      # produces [1, 3, 5, 4], so an unordered read cannot pass this.
      row!(pid, "task-tree", 1, %{
        depth: 0,
        parent_id: nil,
        branch: "evogit-agent-T-A",
        base_commit: "base-root",
        objective: "the task objective"
      })

      row!(pid, "task-tree", 5, %{
        depth: 1,
        parent_id: 1,
        spawn_turn: 3,
        spawn_index: 1,
        branch: "evogit-agent-T-A-2",
        base_commit: "base-five"
      })

      row!(pid, "task-tree", 3, %{
        depth: 1,
        parent_id: 1,
        spawn_turn: 3,
        spawn_index: 0,
        branch: "evogit-agent-T-A-1",
        base_commit: "base-three"
      })

      row!(pid, "task-tree", 4, %{depth: 2, parent_id: 3, spawn_turn: 1, spawn_index: 0})

      # A row of ANOTHER task must never leak into the tree.
      row!(pid, "task-other", 2, %{depth: 0, parent_id: nil})

      assert :ok =
               AgentState.mark_done(
                 "task-tree",
                 3,
                 %{"text" => "child report", "commit" => "sha-3", "repo_id" => "primary"},
                 "sha-3",
                 store: pid
               )

      flush!(pid)

      records = AgentState.roster("task-tree", store: pid)
      assert ids(records) == [1, 3, 5, 4]

      # No chunk read: the skeleton carries no transcript.
      assert Enum.all?(records, fn record -> record.messages == nil end)
      assert Enum.uniq(Enum.map(records, & &1.task_id)) == ["task-tree"]

      [_root, child, sibling, grandchild] = records

      # Identity and parentage.
      assert child.fields[:parent_id] == 1
      assert child.fields[:depth] == 1
      assert grandchild.fields[:parent_id] == 3
      assert grandchild.fields[:depth] == 2
      assert sibling.fields[:parent_id] == 1

      # The spawn position inside the parent's batch.
      assert child.fields[:spawn_turn] == 3
      assert child.fields[:spawn_index] == 0
      assert sibling.fields[:spawn_turn] == 3
      assert sibling.fields[:spawn_index] == 1

      # The git facts and the run's own scalars.
      assert child.fields[:branch] == "evogit-agent-T-A-1"
      assert sibling.fields[:branch] == "evogit-agent-T-A-2"
      assert child.fields[:base_commit] == "base-three"
      assert child.fields[:current_commit] == "sha-3"
      assert grandchild.fields[:base_commit] == nil
      assert child.fields[:anchor_ref] == nil
      assert child.fields[:agent_module] == nil
      assert child.fields[:objective] == nil

      # A finished child surfaces its status and its result, a running one does
      # not — through the accessors a resume path reads.
      assert Record.status(child) == "done"
      assert Record.status(sibling) == "running"

      assert Record.result(child) == %{
               "text" => "child report",
               "commit" => "sha-3",
               "repo_id" => "primary"
             }

      assert Record.result(sibling) == nil
      assert child.completed_at != nil
      assert sibling.completed_at == nil
    end

    test "an unknown task and a task with no rows answer []", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      assert AgentState.roster("task-empty", store: pid) == []

      row!(pid, "task-some", 1, %{depth: 0})
      assert AgentState.roster("task-empty", store: pid) == []
      assert ids(AgentState.roster("task-some", store: pid)) == [1]
    end

    test "an unavailable store answers []", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      row!(pid, "task-dead", 1, %{depth: 0})

      # A registered-name target that does not exist, then a STOPPED instance:
      # both are documented degraded shapes, not errors.
      assert AgentState.roster("task-dead", store: :evogit_no_such_agent_state) == []

      :ok = stop_supervised(AgentState)
      assert AgentState.roster("task-dead", store: pid) == []
    end
  end

  ## max_agent_id/1

  describe "max_agent_id/1" do
    test "is 0 on an empty store and the highest id once rows exist", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      assert AgentState.max_agent_id(store: pid) == 0

      # Inserted highest-first, so a "last inserted" answer cannot pass.
      row!(pid, "task-ids", 7, %{depth: 0})
      row!(pid, "task-ids", 3, %{depth: 1, parent_id: 7})
      assert AgentState.max_agent_id(store: pid) == 7

      row!(pid, "task-ids-2", 1, %{depth: 0})
      assert AgentState.max_agent_id(store: pid) == 7
    end

    test "is 0 on a degraded store", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      row!(pid, "task-ids", 5, %{depth: 0})

      assert AgentState.max_agent_id(store: :evogit_no_such_agent_state) == 0

      :ok = stop_supervised(AgentState)
      assert AgentState.max_agent_id(store: pid) == 0
    end
  end

  ## mark_done/5

  describe "mark_done/5" do
    test "stamps done + completed_at + current_commit and round-trips the result JSON", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      result = %{"text" => "all done", "commit" => "sha-final", "repo_id" => "primary"}

      row!(pid, "task-done", 2, %{depth: 0, status: "running", current_commit: "sha-old"})

      assert :ok =
               AgentState.mark_done("task-done", 2, result, "sha-final", store: pid)

      flush!(pid)

      # The COLUMN holds real JSON (a skipped write would leave NULL here).
      raw =
        raw_row!(pid, "task-done", 2, [
          "status",
          "completed_at",
          "current_commit",
          "result"
        ])

      assert raw["status"] == "done"
      assert is_binary(raw["completed_at"])
      assert raw["current_commit"] == "sha-final"
      assert Jason.decode!(raw["result"]) == result

      assert {:ok, record} = AgentState.load("task-done", 2, store: pid)
      assert Record.status(record) == "done"
      assert Record.result(record) == result
      assert record.fields[:current_commit] == "sha-final"
      assert record.completed_at != nil
      assert DateTime.compare(record.completed_at, DateTime.utc_now()) == :lt
    end

    test "a missing row is :not_found at the Store and stays :ok at the facade", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      repo = AgentState.repo(pid)

      # The facade is a CAST: total, `:ok`, no caller-visible error.
      assert :ok = AgentState.mark_done("task-absent", 9, %{"text" => "x"}, "sha", store: pid)
      flush!(pid)

      assert Store.mark_done(repo, "task-absent", 9, %{"text" => "x"}, "sha") ==
               {:error, :not_found}

      # A completion never fabricates a row.
      assert AgentState.roster("task-absent", store: pid) == []
    end

    test "a nil result/commit records nothing new instead of clearing stored facts", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      result = %{"text" => "first"}

      row!(pid, "task-keep", 1, %{depth: 0, status: "running"})
      assert :ok = AgentState.mark_done("task-keep", 1, result, "sha-keep", store: pid)
      flush!(pid)

      # A second `mark_done/5` with `nil` for both facts carries neither.
      assert :ok = AgentState.mark_done("task-keep", 1, nil, nil, store: pid)
      flush!(pid)

      assert {:ok, record} = AgentState.load("task-keep", 1, store: pid)
      assert Record.status(record) == "done"
      assert Record.result(record) == result
      assert record.fields[:current_commit] == "sha-keep"
    end
  end

  ## delete_done_children/4

  describe "delete_done_children/4" do
    test "deletes only the DONE children of the matching turn, chunks included", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      task_id = "task-batch"

      # The parent (running, no spawn position — it has no parent).
      run_with_messages!(pid, task_id, 1, %{depth: 0, parent_id: nil, status: "running"})

      # Two done children of turn 3, one done child of ANOTHER turn, one child
      # of turn 3 that is still running.
      run_with_messages!(pid, task_id, 2, %{depth: 1, parent_id: 1, spawn_turn: 3, spawn_index: 0})

      run_with_messages!(pid, task_id, 3, %{depth: 1, parent_id: 1, spawn_turn: 3, spawn_index: 1})

      run_with_messages!(pid, task_id, 4, %{depth: 1, parent_id: 1, spawn_turn: 4, spawn_index: 0})

      run_with_messages!(pid, task_id, 5, %{depth: 1, parent_id: 1, spawn_turn: 3, spawn_index: 2})

      for agent_id <- [2, 3, 4] do
        assert :ok =
                 AgentState.mark_done(task_id, agent_id, %{"text" => "r#{agent_id}"}, nil,
                   store: pid
                 )
      end

      flush!(pid)
      assert ids(AgentState.roster(task_id, store: pid)) == [1, 2, 3, 4, 5]

      assert :ok = AgentState.delete_done_children(task_id, 1, 3, store: pid)
      flush!(pid)

      # The done children of turn 3 are gone WITH their chunks; the running
      # child of turn 3, the done child of turn 4 and the parent survive.
      assert ids(AgentState.roster(task_id, store: pid)) == [1, 4, 5]
      assert chunk_count!(pid, task_id, 2) == 0
      assert chunk_count!(pid, task_id, 3) == 0
      assert chunk_count!(pid, task_id, 1) == 1
      assert chunk_count!(pid, task_id, 4) == 1
      assert chunk_count!(pid, task_id, 5) == 1
    end

    test "a nil spawn_turn deletes nothing", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task-nil-turn"

      row!(pid, task_id, 1, %{depth: 0, parent_id: nil})
      run_with_messages!(pid, task_id, 2, %{depth: 1, parent_id: 1, spawn_turn: 3})
      assert :ok = AgentState.mark_done(task_id, 2, %{"text" => "r"}, nil, store: pid)
      flush!(pid)

      assert :ok = AgentState.delete_done_children(task_id, 1, nil, store: pid)
      flush!(pid)

      # A caller with no batch can never delete a whole generation.
      assert ids(AgentState.roster(task_id, store: pid)) == [1, 2]
      assert chunk_count!(pid, task_id, 2) == 1
    end

    test "an unavailable store stays a total :ok", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      assert :ok = AgentState.delete_done_children("task-x", 1, 3, store: :no_such_store)
      :ok = stop_supervised(AgentState)
      assert :ok = AgentState.delete_done_children("task-x", 1, 3, store: pid)
    end
  end
end
