defmodule EvoGit.AgentState.QueriesTest do
  @moduledoc """
  The BULK + per-turn QUERY/WRITE arms of `EvoGit.AgentState` that its own
  author only exercised ad hoc:

    * `roster_many/2` — the multi-task LEAN roster (`Store.roster_many/2`);
    * `update_volatile/4` — the constant-shape per-turn REPLACE write and its
      `COALESCE` fallbacks for the four `NOT NULL` volatile columns;
    * `delete_tasks/2` CHUNKING — more task ids than `Store`'s internal batch
      width, so the delete spans several statements in one transaction;
    * `delete_done_children/4` — the `(task_id, parent_id, spawn_turn,
      status = 'done')` selectivity, including a second parent and a second
      task.

  Every test starts its OWN unnamed `EvoGit.AgentState` server on a per-test
  SQLite file and addresses it through `store: pid`, so the app-global
  `EvoGit.AgentState.Server` is never touched — hence `async: true`.
  Checkpoints AND the bookkeeping writes are CASTS, so every read/SQL
  assertion follows `EvoGit.AgentState.flush/1` (the read-your-writes
  barrier); there is no `Process.sleep` anywhere.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentState.Store
  alias EvoGit.Store.RepoScope
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @moduletag :tmp_dir

  # `EvoGit.AgentState.Store`'s `@prune_batch_size` is 400, so this id list
  # spans TWO (in fact three) constant-shape statements per table — the whole
  # point of the chunking arm. The assertions hold for any larger width too.
  @chunk_spanning_task_count 450

  # The writer DROPS a checkpoint that arrives while its mailbox is over its
  # backlog cap (200), so bulk fixtures are cast in bounded batches with one
  # flush between them (never one unbounded burst).
  @bulk_batch_size 40

  ## Isolation helpers (duplicated per file on purpose: no shared support module)

  defp start_store!(tmp_dir) do
    start_supervised!(
      {AgentState,
       database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000}
    )
  end

  defp checkpoint!(pid, task_id, agent_id, entry) do
    :ok = AgentState.checkpoint(task_id, agent_id, entry, store: pid)
    :ok = AgentState.flush(store: pid)
    :ok
  end

  # One row with the given scalars and NO conversation (the cheapest shape a
  # start snapshot leaves behind).
  defp row!(pid, task_id, agent_id, fields) do
    checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: [], fields: fields})
  end

  # A row WITH exactly one chunk, so a delete can be proven to take its chunks.
  defp run_with_messages!(pid, task_id, agent_id, fields) do
    message = %Message{role: :assistant, content: [ContentPart.text("#{agent_id} reply")]}

    checkpoint!(pid, task_id, agent_id, %{kind: :rewrite, messages: [message], fields: fields})

    assert chunk_count!(pid, task_id, agent_id) == 1
    :ok
  end

  # Many conversational-empty rows, cast in bounded batches.
  defp bulk_rows!(pid, rows) do
    rows
    |> Enum.chunk_every(@bulk_batch_size)
    |> Enum.each(fn batch ->
      Enum.each(batch, fn {task_id, agent_id, fields} ->
        :ok =
          AgentState.checkpoint(
            task_id,
            agent_id,
            %{kind: :rewrite, messages: [], fields: fields},
            store: pid
          )
      end)

      flush!(pid)
    end)
  end

  defp flush!(pid), do: assert(:ok = AgentState.flush(store: pid))

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

  defp count_rows!(pid, task_id) do
    [[count]] = sql!(pid, "SELECT COUNT(*) FROM agent_states WHERE task_id = ?", [task_id]).rows
    count
  end

  defp count_all!(pid, table) do
    [[count]] = sql!(pid, "SELECT COUNT(*) FROM #{table}", []).rows
    count
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

  defp ids(records), do: Enum.map(records, & &1.agent_id)

  defp task_and_ids(records), do: Enum.map(records, &{&1.task_id, &1.agent_id})

  # Zero-padded task ids, so the expected string ordering is also the numeric
  # one and a chunk boundary can be addressed by index.
  defp bulk_task_ids(prefix, count) do
    for index <- 1..count do
      "#{prefix}-#{index |> Integer.to_string() |> String.pad_leading(4, "0")}"
    end
  end

  ## roster_many/2

  describe "roster_many/2" do
    test "returns MANY tasks' skeleton trees ordered task_id, depth, agent_id ASC", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)

      # Created deliberately out of order, and with a child id (3) SMALLER than
      # its parent's (5): only the documented
      # `task_id ASC, depth ASC, agent_id ASC` ordering yields the expectation.
      bulk_rows!(pid, [
        {"task-zeta", 2, %{depth: 1, parent_id: 1}},
        {"task-alpha", 3, %{depth: 2, parent_id: 5}},
        {"task-zeta", 1, %{depth: 0, parent_id: nil}},
        {"task-alpha", 5, %{depth: 0, parent_id: nil}},
        {"task-zeta", 10, %{depth: 1, parent_id: 1}},
        # A task that is NOT in the requested list must never leak in.
        {"task-omega", 1, %{depth: 0, parent_id: nil}}
      ])

      records = AgentState.roster_many(["task-zeta", "task-alpha"], store: pid)

      assert task_and_ids(records) == [
               {"task-alpha", 5},
               {"task-alpha", 3},
               {"task-zeta", 1},
               {"task-zeta", 2},
               {"task-zeta", 10}
             ]

      # The bulk read is the SAME LEAN skeleton as `roster/2`: no transcript.
      assert Enum.all?(records, fn record -> record.messages == nil end)
      assert Enum.all?(records, fn record -> is_struct(record, Record) end)
    end

    test "carries the LEAN projection: usage/pending_inputs are nil, the rest is present", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)

      # The columns hold REAL data (proven below through `load/3`), so a nil in
      # the roster record is the projection omitting it — never an empty column.
      run_with_messages!(pid, "task-lean", 1, %{
        depth: 0,
        parent_id: nil,
        objective: "the task objective",
        branch: "evogit-agent-T-A",
        base_commit: "base-root",
        current_commit: "sha-1",
        usage: %{"total_tokens" => 42},
        pending_inputs: [%{"text" => "queued mid-run"}]
      })

      assert :ok =
               AgentState.mark_done("task-lean", 1, %{"text" => "report"}, "sha-1", store: pid)

      flush!(pid)

      [record] = AgentState.roster_many(["task-lean"], store: pid)

      assert record.messages == nil
      assert record.fields[:usage] == nil
      assert record.fields[:pending_inputs] == nil
      # …while everything a resume reads is still there.
      assert record.fields[:objective] == "the task objective"
      assert record.fields[:branch] == "evogit-agent-T-A"
      assert record.fields[:base_commit] == "base-root"
      assert record.fields[:current_commit] == "sha-1"
      assert Record.status(record) == "done"
      assert Record.result(record) == %{"text" => "report"}

      # The same row through `load/3` DOES carry both omitted values.
      assert {:ok, loaded} = AgentState.load("task-lean", 1, store: pid)
      assert loaded.fields[:usage] == %{"total_tokens" => 42}
      assert loaded.fields[:pending_inputs] == [%{"text" => "queued mid-run"}]
      assert [_message] = loaded.messages
    end

    test "filters non-binary ids and folds duplicates away", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      bulk_rows!(pid, [
        {"task-dup", 1, %{depth: 0}},
        {"task-dup", 2, %{depth: 1, parent_id: 1}}
      ])

      records =
        AgentState.roster_many(
          ["task-dup", "task-dup", 42, :an_atom, nil, "task-absent"],
          store: pid
        )

      # A repeated id addresses the same row once; a non-binary id addresses
      # nothing at all.
      assert ids(records) == [1, 2]
      assert Enum.uniq(Enum.map(records, & &1.task_id)) == ["task-dup"]
    end

    test "an empty list reads nothing, a non-list answers [], and so does a dead store", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      row!(pid, "task-present", 1, %{depth: 0})

      # Total at the facade for both a non-list and an empty list.
      assert AgentState.roster_many([], store: pid) == []
      assert AgentState.roster_many("task-present", store: pid) == []
      assert AgentState.roster_many(nil, store: pid) == []
      # …and the store keeps its own stricter, documented contract.
      assert Store.roster_many(AgentState.repo(pid), "task-present") ==
               {:error, :invalid_task_ids}

      # Degraded targets: an unregistered name, then a stopped instance.
      assert AgentState.roster_many(["task-present"], store: :evogit_no_such_agent_state) == []

      :ok = stop_supervised(AgentState)
      assert AgentState.roster_many(["task-present"], store: pid) == []
    end

    test "one read covers more ids than a single chunk of the batch width", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      task_ids = bulk_task_ids("task-many", @chunk_spanning_task_count)
      bulk_rows!(pid, Enum.map(task_ids, fn task_id -> {task_id, 1, %{depth: 0}} end))

      records = AgentState.roster_many(task_ids, store: pid)

      # Every chunk's records are present — and the concatenation of the chunks
      # is still GLOBALLY ordered, not ordered per chunk.
      assert length(records) == @chunk_spanning_task_count
      assert Enum.map(records, & &1.task_id) == Enum.sort(task_ids)
    end
  end

  ## update_volatile/4

  describe "update_volatile/4" do
    @volatile_columns [
      "turn",
      "total_tokens",
      "compression_count",
      "status",
      "phase",
      "current_commit",
      "usage",
      "pending_inputs",
      "pending_tool_batch"
    ]

    test "REPLACEs the volatile blob instead of deep-merging it", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task-volatile"
      repo = AgentState.repo(pid)

      row!(pid, task_id, 1, %{depth: 0, parent_id: nil})

      # A FULL volatile snapshot: every one of the nine columns gets a value.
      assert :ok =
               Store.update_volatile(repo, task_id, 1, %{
                 turn: 3,
                 total_tokens: 50,
                 compression_count: 2,
                 status: "done",
                 phase: "llm",
                 current_commit: "sha-3",
                 usage: %{"total_tokens" => 50},
                 pending_inputs: [%{"text" => "queued"}],
                 pending_tool_batch: %{"calls" => 1}
               })

      full = raw_row!(pid, task_id, 1, @volatile_columns)
      assert full["turn"] == 3
      assert full["total_tokens"] == 50
      assert full["compression_count"] == 2
      assert full["status"] == "done"
      assert full["phase"] == "llm"
      assert full["current_commit"] == "sha-3"
      assert Jason.decode!(full["usage"]) == %{"total_tokens" => 50}
      assert Jason.decode!(full["pending_inputs"]) == [%{"text" => "queued"}]
      assert is_binary(full["pending_tool_batch"])

      # A PARTIAL second write: the omitted nullable columns are CLEARED, not
      # merged, so no value from the first snapshot can survive.
      assert :ok = Store.update_volatile(repo, task_id, 1, %{turn: 4, total_tokens: 60})

      partial = raw_row!(pid, task_id, 1, @volatile_columns)
      assert partial["turn"] == 4
      assert partial["total_tokens"] == 60
      # The four NOT NULL columns omitted here fall back to their OWN defaults
      # (`compression_count` 2 → 0, `status` 'done' → 'running') instead of
      # failing the constraint.
      assert partial["compression_count"] == 0
      assert partial["status"] == "running"
      # The nullable ones clear to NULL — this is REPLACE, not a patch.
      assert partial["phase"] == nil
      assert partial["current_commit"] == nil
      assert partial["usage"] == nil
      assert partial["pending_inputs"] == nil
      assert partial["pending_tool_batch"] == nil

      # The decoded record agrees with the raw columns.
      assert {:ok, record} = AgentState.load(task_id, 1, store: pid)
      assert record.fields[:turn] == 4
      assert record.fields[:total_tokens] == 60
      assert record.fields[:compression_count] == 0
      assert record.fields[:status] == "running"
      assert record.fields[:phase] == nil
      assert record.fields[:current_commit] == nil
      assert record.fields[:usage] == nil
      assert record.fields[:pending_inputs] == nil
    end

    test "an EXPLICIT nil also falls back to the NOT NULL defaults", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task-volatile-nil"
      repo = AgentState.repo(pid)

      row!(pid, task_id, 1, %{
        depth: 0,
        turn: 9,
        total_tokens: 999,
        compression_count: 7,
        status: "done"
      })

      assert :ok =
               Store.update_volatile(repo, task_id, 1, %{
                 turn: nil,
                 total_tokens: nil,
                 compression_count: nil,
                 status: nil,
                 phase: "waiting"
               })

      raw = raw_row!(pid, task_id, 1, @volatile_columns)
      # `nil` is COALESCEd to the table default, never handed to the NOT NULL
      # constraint.
      assert raw["turn"] == 0
      assert raw["total_tokens"] == 0
      assert raw["compression_count"] == 0
      assert raw["status"] == "running"
      # A nullable column supplied alongside them is written normally.
      assert raw["phase"] == "waiting"
    end

    test "leaves every identity/run fact, pause_commit and result untouched", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task-volatile-facts"
      repo = AgentState.repo(pid)

      row!(pid, task_id, 1, %{
        depth: 0,
        parent_id: nil,
        objective: "the task objective",
        branch: "evogit-agent-T-F",
        base_commit: "base-root",
        anchor_ref: "refs/genesis/agent-state/T/1",
        spawn_turn: 2,
        spawn_index: 0
      })

      assert :ok = AgentState.put_pause_commit(task_id, 1, "pause-sha", store: pid)

      assert :ok =
               AgentState.mark_done(task_id, 1, %{"text" => "report"}, "sha-done", store: pid)

      flush!(pid)

      # TWO volatile rewrites, one full and one partial.
      assert :ok = Store.update_volatile(repo, task_id, 1, %{turn: 1, status: "running"})
      assert :ok = Store.update_volatile(repo, task_id, 1, %{turn: 2})

      assert {:ok, record} = AgentState.load(task_id, 1, store: pid)

      # Not in `Record.volatile_columns/0`, so no volatile write may touch them.
      assert record.fields[:objective] == "the task objective"
      assert record.fields[:branch] == "evogit-agent-T-F"
      assert record.fields[:base_commit] == "base-root"
      assert record.fields[:anchor_ref] == "refs/genesis/agent-state/T/1"
      assert record.fields[:spawn_turn] == 2
      assert record.fields[:spawn_index] == 0
      assert record.fields[:depth] == 0
      assert record.fields[:parent_id] == nil
      assert record.fields[:pause_commit] == "pause-sha"
      assert Record.result(record) == %{"text" => "report"}
    end

    test "never INSERTS: an unknown agent or task is {:error, :not_found}", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      repo = AgentState.repo(pid)
      row!(pid, "task-known", 1, %{depth: 0})

      # Unknown agent of a known task, and an unknown task.
      assert Store.update_volatile(repo, "task-known", 99, %{turn: 1}) == {:error, :not_found}

      assert Store.update_volatile(repo, "task-absent", 1, %{turn: 1}) == {:error, :not_found}

      # A run's row comes into existence with its START snapshot, never here.
      assert count_rows!(pid, "task-absent") == 0
      assert count_rows!(pid, "task-known") == 1

      # The facade is a total CAST: `:ok` even for a missing row, a degraded
      # target and a dead server.
      assert :ok = AgentState.update_volatile("task-absent", 1, %{turn: 1}, store: pid)
      assert :ok = AgentState.update_volatile("task-known", 1, %{turn: 1}, store: :no_such_store)
      flush!(pid)
      assert count_rows!(pid, "task-absent") == 0

      :ok = stop_supervised(AgentState)
      assert :ok = AgentState.update_volatile("task-known", 1, %{turn: 2}, store: pid)
    end
  end

  ## delete_tasks/2 chunking

  describe "delete_tasks/2 chunking" do
    test "a list longer than the batch width deletes every listed task's rows and chunks", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)

      task_ids = bulk_task_ids("task-bulk", @chunk_spanning_task_count)
      first = List.first(task_ids)
      last = List.last(task_ids)

      # The first and last ids sort into DIFFERENT chunks, so running them with
      # a chunk each proves BOTH chunk-bound statements remove chunk rows.
      run_with_messages!(pid, first, 1, %{depth: 0})
      run_with_messages!(pid, last, 1, %{depth: 0})

      task_ids
      |> Enum.slice(1..(length(task_ids) - 2))
      |> then(fn middle -> bulk_rows!(pid, Enum.map(middle, &{&1, 1, %{depth: 0}})) end)

      # One task outside the list, with a run of its own, must survive.
      run_with_messages!(pid, "task-keep", 1, %{depth: 0})

      assert count_all!(pid, "agent_states") == @chunk_spanning_task_count + 1
      assert count_all!(pid, "agent_state_chunks") == 3

      assert :ok = AgentState.delete_tasks(task_ids, store: pid)
      flush!(pid)

      # Chunk 1's task and the last chunk's task are both fully gone.
      assert count_rows!(pid, first) == 0
      assert count_rows!(pid, last) == 0
      assert chunk_count!(pid, first, 1) == 0
      assert chunk_count!(pid, last, 1) == 0
      # One statement boundary is not a cut-off: the ids either side of it went
      # too (here: the 400th and 401st ids, the first chunk's last and the
      # second chunk's first).
      for task_id <- Enum.slice(task_ids, 399..400) do
        assert count_rows!(pid, task_id) == 0
      end

      # The whole-table check IS the completeness proof.
      assert count_all!(pid, "agent_states") == 1
      assert count_all!(pid, "agent_state_chunks") == 1
      assert {:ok, %Record{}} = AgentState.load("task-keep", 1, store: pid)
      assert chunk_count!(pid, "task-keep", 1) == 1
    end

    test "an empty list, a non-list and non-binary ids are all no-ops", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      row!(pid, "task-a", 1, %{depth: 0})
      row!(pid, "task-b", 1, %{depth: 0})

      # Empty list: no transaction is opened, nothing is deleted.
      assert :ok = AgentState.delete_tasks([], store: pid)
      # Non-list: the facade and the store both ignore it.
      assert :ok = AgentState.delete_tasks(:not_a_list, store: pid)
      assert :ok = Store.delete_tasks(AgentState.repo(pid), :not_a_list)
      flush!(pid)
      assert count_rows!(pid, "task-a") == 1
      assert count_rows!(pid, "task-b") == 1

      # Non-binary ids are dropped before the chunking; a duplicate id only
      # repeats an `IN` key, so the real id still deletes exactly once.
      assert :ok = AgentState.delete_tasks(["task-a", "task-a", 42, :b, nil], store: pid)
      flush!(pid)
      assert count_rows!(pid, "task-a") == 0
      assert count_rows!(pid, "task-b") == 1

      # Total for a degraded target and after the server stops.
      assert :ok = AgentState.delete_tasks(["task-b"], store: :no_such_store)
      :ok = stop_supervised(AgentState)
      assert :ok = AgentState.delete_tasks(["task-b"], store: pid)
    end
  end

  ## delete_done_children/4 selectivity

  describe "delete_done_children/4" do
    test "spares a running child, another spawn_turn, another parent and another task", %{
      tmp_dir: tmp_dir
    } do
      pid = start_store!(tmp_dir)
      task_id = "task-batch"

      # Two parents, both running.
      run_with_messages!(pid, task_id, 1, %{depth: 0, parent_id: nil, status: "running"})
      run_with_messages!(pid, task_id, 6, %{depth: 0, parent_id: nil, status: "running"})

      # The ONE row this batch delete should claim: done, parent 1, turn 3.
      run_with_messages!(pid, task_id, 2, %{depth: 1, parent_id: 1, spawn_turn: 3, spawn_index: 0})

      # Every neighbouring shape must survive: a still-running child of the SAME
      # batch, a done child of ANOTHER turn of the same parent, and a done child
      # of ANOTHER parent in the same turn.
      run_with_messages!(pid, task_id, 3, %{depth: 1, parent_id: 1, spawn_turn: 3, spawn_index: 1})

      run_with_messages!(pid, task_id, 4, %{depth: 1, parent_id: 1, spawn_turn: 4, spawn_index: 0})

      run_with_messages!(pid, task_id, 5, %{depth: 1, parent_id: 6, spawn_turn: 3, spawn_index: 0})

      # The SAME key in ANOTHER task: only `(task_id, …)` decides the batch.
      run_with_messages!(pid, "task-batch-other", 2, %{
        depth: 1,
        parent_id: 1,
        spawn_turn: 3,
        spawn_index: 0
      })

      # Done: the two parents' batch children except the deliberately running
      # one, plus the identically keyed row of the other task.
      for {other_task, agent_id} <- [
            {task_id, 2},
            {task_id, 4},
            {task_id, 5},
            {"task-batch-other", 2}
          ] do
        assert :ok =
                 AgentState.mark_done(other_task, agent_id, %{"text" => "r#{agent_id}"}, nil,
                   store: pid
                 )
      end

      flush!(pid)
      # `depth ASC, agent_id ASC`: the two roots, then the four children.
      assert ids(AgentState.roster(task_id, store: pid)) == [1, 6, 2, 3, 4, 5]

      assert :ok = AgentState.delete_done_children(task_id, 1, 3, store: pid)
      flush!(pid)

      # Only the done child of (parent 1, turn 3) is gone — with its chunks.
      assert ids(AgentState.roster(task_id, store: pid)) == [1, 6, 3, 4, 5]
      assert chunk_count!(pid, task_id, 2) == 0
      assert chunk_count!(pid, task_id, 1) == 1
      assert chunk_count!(pid, task_id, 3) == 1
      assert chunk_count!(pid, task_id, 4) == 1
      assert chunk_count!(pid, task_id, 5) == 1

      # The identically keyed row of the other task was never in this batch.
      assert ids(AgentState.roster("task-batch-other", store: pid)) == [2]
      assert chunk_count!(pid, "task-batch-other", 2) == 1

      # A non-integer spawn_turn is a no-op `:ok` (never a whole generation).
      assert :ok = AgentState.delete_done_children(task_id, 1, "3", store: pid)
      flush!(pid)
      assert ids(AgentState.roster(task_id, store: pid)) == [1, 6, 3, 4, 5]
    end
  end
end
