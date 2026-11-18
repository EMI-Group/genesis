defmodule EvoGit.AgentState.CoalescingTest do
  @moduledoc """
  WRITER COALESCING and BOUNDING coverage for `EvoGit.AgentState`:

    * checkpoints still queued for ONE run are drained with a selective
      receive, folded (`EvoGit.AgentState.Entry`) and persisted as ONE
      transaction — so an N-append queue costs ONE chunk row, not N;
    * another run's queued checkpoint (and a `:sync` call) is never drained;
    * OVER the backlog cap the arriving checkpoint is DROPPED, its owner is
      notified with `{:agent_state_resync, task_id, agent_id}` (the session
      rewrites its transcript, so the loss self-heals) and exactly ONE warning
      is logged per run per failure streak;
    * a payload over the size cap is skipped WITHOUT a resync, with the same
      one-warning rule, and leaves no row behind;
    * `EvoGit.AgentState.Store.checkpoint_batch/4` commits a whole fold in one
      transaction and rolls it ALL back on a continuity gap.

  Every case uses its OWN isolated `EvoGit.AgentState` instance (unnamed, on a
  per-test SQLite file) addressed through `store: pid`, so the app-global
  writer is never touched and the caps are per-instance start options — hence
  `async: true` and no app-env mutation.
  Determinism comes from `:sys.suspend`/`:sys.resume` (the queue is exactly what
  the test cast) and from the `flush/1` reply; there is no `Process.sleep`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Store
  alias EvoGit.Store.RepoScope

  @moduletag :tmp_dir

  ## Isolation helpers (duplicated per file on purpose: no shared support module)

  defp start_store!(tmp_dir, opts \\ []) do
    start_supervised!(
      {EvoGit.AgentState,
       Keyword.merge(
         [
           database: Path.join(tmp_dir, "agent_state.sqlite"),
           name: nil,
           prune_interval: 3_600_000
         ],
         opts
       )}
    )
  end

  defp server_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {EvoGit.AgentState.Server, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp message(text),
    do: %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text(text)]}

  defp messages(texts), do: Enum.map(texts, &message/1)

  defp rewrite(texts, owner \\ nil) do
    %{kind: :rewrite, messages: messages(texts), fields: %{}, owner: owner}
  end

  defp append(base_seq, texts, owner \\ nil) do
    %{kind: :append, base_seq: base_seq, messages: messages(texts), fields: %{}, owner: owner}
  end

  defp load!(pid, task_id, agent_id) do
    assert {:ok, record} = AgentState.load(task_id, agent_id, store: pid)
    record
  end

  defp sql!(pid, sql, params) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
      result
    end)
  end

  defp chunks!(pid, task_id, agent_id) do
    sql!(
      pid,
      "SELECT seq, message_count, payload FROM agent_state_chunks " <>
        "WHERE task_id = ? AND agent_id = ? ORDER BY seq ASC",
      [task_id, agent_id]
    ).rows
  end

  defp counts!(pid, task_id, agent_id) do
    sql!(
      pid,
      "SELECT message_count, chunk_count FROM agent_states WHERE task_id = ? AND agent_id = ?",
      [task_id, agent_id]
    ).rows
  end

  # Every resync notification the writer already sent us. `flush/1` establishes
  # the ordering (the writer sends to this pid before it replies), so a plain
  # mailbox count is exact and needs no wait.
  defp resyncs(task_id, agent_id) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.count(messages, fn message -> message == {:agent_state_resync, task_id, agent_id} end)
  end

  defp count_of(log, needle), do: length(String.split(log, needle)) - 1

  defp queue_length(server) do
    {:message_queue_len, length} = Process.info(server, :message_queue_len)
    length
  end

  # Bounded poll for a cross-process condition (never a fixed sleep). Waiting
  # for an EMPTY writer mailbox is what makes a back-pressure test's drop count
  # exact: a barrier call sent while casts are still queued would itself count
  # against the cap.
  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within the budget")

      true ->
        Process.sleep(1)
        do_wait_until(fun, deadline)
    end
  end

  defp await_drained(server) do
    wait_until(fn -> queue_length(server) == 0 end, 5_000)
  end

  ## Coalescing

  describe "coalescing" do
    test "queued appends for ONE run fold into ONE transaction (one new chunk)",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      server = server_pid(pid)

      :ok = AgentState.checkpoint("task-coalesce", 1, rewrite(["m0"]), store: pid)
      :ok = AgentState.flush(store: pid)

      :ok = :sys.suspend(server)

      for index <- 1..5 do
        :ok = AgentState.checkpoint("task-coalesce", 1, append(index, ["m#{index}"]), store: pid)
      end

      :ok = :sys.resume(server)
      assert :ok = AgentState.flush(store: pid)

      assert load!(pid, "task-coalesce", 1).messages ==
               messages(["m0", "m1", "m2", "m3", "m4", "m5"])

      # Five queued appends → ONE chunk row at seq 1 (the old writer wrote N).
      assert length(chunks!(pid, "task-coalesce", 1)) == 2
      assert counts!(pid, "task-coalesce", 1) == [[6, 2]]
    end

    test "queued rewrites for ONE run collapse to the LAST one", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      server = server_pid(pid)

      :ok = :sys.suspend(server)

      for index <- 1..4 do
        :ok = AgentState.checkpoint("task-rewrite", 1, rewrite(["r#{index}"]), store: pid)
      end

      :ok = :sys.resume(server)
      assert :ok = AgentState.flush(store: pid)

      assert load!(pid, "task-rewrite", 1).messages == messages(["r4"])
      assert length(chunks!(pid, "task-rewrite", 1)) == 1
      assert counts!(pid, "task-rewrite", 1) == [[1, 1]]
    end

    test "draining is SELECTIVE: another run's queued checkpoint stays its own write",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      server = server_pid(pid)

      :ok = :sys.suspend(server)

      # Interleaved: run 1, run 2, then run 1 again (chaining onto its rewrite).
      :ok = AgentState.checkpoint("task-select", 1, rewrite(["a1"]), store: pid)
      :ok = AgentState.checkpoint("task-select", 2, rewrite(["b1"]), store: pid)
      :ok = AgentState.checkpoint("task-select", 1, append(1, ["a2"]), store: pid)

      :ok = :sys.resume(server)
      assert :ok = AgentState.flush(store: pid)

      # Run 1's two entries became ONE rewrite carrying the appended tail...
      assert load!(pid, "task-select", 1).messages == messages(["a1", "a2"])
      assert length(chunks!(pid, "task-select", 1)) == 1

      # ...and run 2's checkpoint (queued BETWEEN run 1's two) was untouched.
      assert load!(pid, "task-select", 2).messages == messages(["b1"])
      assert counts!(pid, "task-select", 2) == [[1, 1]]
    end
  end

  ## Back-pressure

  describe "back-pressure" do
    test "over the backlog cap the arriving checkpoint is dropped and its owner resynced",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, max_backlog: 1)
      server = server_pid(pid)

      log =
        capture_log([level: :warning], fn ->
          :ok = :sys.suspend(server)

          for text <- ["m1", "m2", "m3"] do
            assert :ok =
                     AgentState.checkpoint("task-drop", 1, rewrite([text], self()), store: pid)
          end

          :ok = :sys.resume(server)
          await_drained(server)
          assert :ok = AgentState.flush(store: pid)
        end)

      # The FIRST checkpoint found two more queued behind it, so it was dropped
      # (ONE resync notification for the owner) and logged ONE warning; the
      # later two still coalesced and were persisted.
      assert resyncs("task-drop", 1) == 1
      assert count_of(log, "skipping durable checkpoint") == 1
      assert load!(pid, "task-drop", 1).messages == messages(["m3"])

      # The writer survived, drained its own mailbox and is still usable.
      assert Process.alive?(server)
      assert queue_length(server) == 0
      assert :ok = AgentState.flush(store: pid)
    end

    test "a flood over the cap logs ONE warning per run and keeps the mailbox bounded",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, max_backlog: 1)
      server = server_pid(pid)

      log =
        capture_log([level: :warning], fn ->
          :ok = :sys.suspend(server)

          for index <- 1..20 do
            assert :ok =
                     AgentState.checkpoint(
                       "task-flood",
                       1,
                       rewrite(["m#{index}"], self()),
                       store: pid
                     )
          end

          :ok = :sys.resume(server)
          await_drained(server)
          assert :ok = AgentState.flush(store: pid)
        end)

      assert count_of(log, "skipping durable checkpoint") == 1
      assert resyncs("task-flood", 1) >= 1
      assert load!(pid, "task-flood", 1).messages == messages(["m20"])
      assert Process.alive?(server)
      assert queue_length(server) == 0
    end

    test "a dropped checkpoint is not drained, so the accepted tail still resyncs honestly",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, max_backlog: 1)
      server = server_pid(pid)

      capture_log([level: :warning], fn ->
        :ok = :sys.suspend(server)

        :ok = AgentState.checkpoint("task-gap", 1, rewrite(["warm"], self()), store: pid)
        # Both appends chain onto base_seq 1 — but the first is DROPPED, so the
        # folded survivor starts at 1 against a stored count of 0 → :resync.
        :ok = AgentState.checkpoint("task-gap", 1, append(1, ["a"], self()), store: pid)
        :ok = AgentState.checkpoint("task-gap", 1, append(2, ["b"], self()), store: pid)

        :ok = :sys.resume(server)
        await_drained(server)
        assert :ok = AgentState.flush(store: pid)
      end)

      # The drop notified the owner, and the fold reported the continuity gap
      # instead of appending on top of it — nothing was written.
      assert resyncs("task-gap", 1) == 2
      assert {:error, :not_found} = AgentState.load("task-gap", 1, store: pid)
    end
  end

  ## Payload cap

  describe "payload cap" do
    test "a payload over the cap is skipped with ONE warning, no row and NO resync",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, max_payload_bytes: 2_048)
      oversized = String.duplicate("x", 10_000)

      log =
        capture_log([level: :warning], fn ->
          assert :ok = AgentState.checkpoint("task-payload", 1, rewrite([oversized]), store: pid)
          assert :ok = AgentState.flush(store: pid)

          assert {:error, :not_found} = AgentState.load("task-payload", 1, store: pid)
          # NO resync: resyncing would only re-send the same oversized payload.
          refute_received {:agent_state_resync, "task-payload", 1}

          # A small checkpoint afterwards persists and closes the streak...
          assert :ok = AgentState.checkpoint("task-payload", 1, rewrite(["small"]), store: pid)
          assert :ok = AgentState.flush(store: pid)
          assert load!(pid, "task-payload", 1).messages == messages(["small"])

          # ...so the NEXT oversized one is a NEW streak: a second warning line
          # proves the per-run bookkeeping was reset by the accepted write.
          assert :ok = AgentState.checkpoint("task-payload", 1, rewrite([oversized]), store: pid)
          assert :ok = AgentState.flush(store: pid)
        end)

      assert count_of(log, "skipping durable checkpoint") == 2
      assert log =~ "payload of"
      assert load!(pid, "task-payload", 1).messages == messages(["small"])
    end

    test "the cap applies to the WHOLE fold, not to each queued entry", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir, max_payload_bytes: 3_000)
      server = server_pid(pid)
      filler = String.duplicate("y", 2_000)

      log =
        capture_log([level: :warning], fn ->
          :ok = :sys.suspend(server)

          # Each tail alone fits under the cap; their FOLD does not.
          :ok = AgentState.checkpoint("task-fold", 1, append(0, [filler <> "a"]), store: pid)
          :ok = AgentState.checkpoint("task-fold", 1, append(1, [filler <> "b"]), store: pid)

          :ok = :sys.resume(server)
          assert :ok = AgentState.flush(store: pid)
        end)

      assert count_of(log, "skipping durable checkpoint") == 1
      assert {:error, :not_found} = AgentState.load("task-fold", 1, store: pid)
    end
  end

  ## Store.checkpoint_batch/4

  describe "Store.checkpoint_batch/4" do
    test "commits a whole fold in one transaction and rolls ALL of it back on a resync",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      repo = AgentState.repo(pid)

      assert :ok =
               Store.checkpoint_batch(repo, "task-batch", 1, [
                 %{kind: :append, base_seq: 0, messages: messages(["a"]), fields: %{turn: 1}},
                 %{kind: :append, base_seq: 1, messages: messages(["b"]), fields: %{turn: 2}}
               ])

      record = load!(pid, "task-batch", 1)
      assert record.messages == messages(["a", "b"])
      assert record.fields[:turn] == 2

      # The second operation's base_seq diverges, so the FIRST one is undone too.
      assert :resync =
               Store.checkpoint_batch(repo, "task-batch", 1, [
                 %{kind: :append, base_seq: 2, messages: messages(["c"]), fields: %{turn: 3}},
                 %{kind: :append, base_seq: 99, messages: messages(["d"]), fields: %{turn: 4}}
               ])

      record = load!(pid, "task-batch", 1)
      assert record.messages == messages(["a", "b"])
      assert record.fields[:turn] == 2
      assert counts!(pid, "task-batch", 1) == [[2, 2]]

      # An empty fold is a no-op `:ok`; a non-list one is a documented error.
      assert :ok = Store.checkpoint_batch(repo, "task-batch", 1, [])
      assert {:error, :invalid_operations} = Store.checkpoint_batch(repo, "task-batch", 1, nil)
    end
  end
end
