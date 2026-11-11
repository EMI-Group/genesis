defmodule EvoGit.AgentScheduler.ControlPlaneTest do
  @moduledoc """
  The scheduler CONTROL PLANE: every value a process OTHER than the agent writes
  about a live agent lives in `:evogit_agent_inbox` (a `:bag` of
  `{agent_id, {seq, message}}`) and `:evogit_agent_control` (a `:set` of the
  2-tuple `{agent_id, cancel_requested}`), never in the agent's own
  `:evogit_agent_summary` row.

  `%EvoGit.AgentScheduler.AgentState{}` is a SUMMARY-only read model with ONE
  runtime writer — the owning `EvoGit.Agent.Session`, through
  `EvoGit.AgentScheduler.Store.put_agent_state/2`. It carries no conversation
  and no cross-process control state at all, so there is nothing to reset and no
  control field to project.

  What these tests pin:

    * the no-read-modify-write invariant — `append_pending_user_message/2`,
      `set_cancel_requested/1` and `clear_cancel_requested/1` leave the raw state
      row TERM-IDENTICAL (the assertion that failed on the old whole-struct
      implementation);
    * a concurrent append/drain stress test where every message is delivered
      EXACTLY once and each producer's messages keep their own order (the old
      whole-struct drain lost any message appended between its read and write);
    * `put_agent_state/2` — the remaining writer — storing the summary row
      VERBATIM (no reset/merge of control state, which no longer exists on the
      struct) and never disturbing the control plane;
    * the STATE-OWNED `compression_count` persisting across ordinary summary
      writes;
    * a cancel flag and N concurrent control-plane writes that both survive the
      agent's own concurrent summary writes;
    * the pending-message ordering contract;
    * `delete_agent_state/1` removing both control rows (no leak).

  `async: true`: the tables are app-global and shared with every concurrently
  running module, so each test uses its own agent id from this file's
  `9_950_000+` range, never wipes a table, and deletes exactly its own rows.
  The `"agents"` PubSub topic is shared too, but nothing here asserts on it.
  """
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  @id_base 9_950_000

  # --- Fixtures -------------------------------------------------------------

  defp agent_state do
    %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      current_commit: "abc",
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    }
  end

  defp unique_agent_id, do: @id_base + System.unique_integer([:positive])

  # Registers a live agent row (the control plane refuses writes for an agent
  # that is gone — that "the agent must be live" contract is preserved) and
  # schedules the deletion of every row this test created.
  defp put_live_agent! do
    agent_id = unique_agent_id()
    :ok = Store.put_agent_state(agent_id, agent_state())
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
    agent_id
  end

  # The RAW row, exactly as stored — the summary row IS the whole read model.
  defp raw_row(agent_id) do
    :ets.lookup(:evogit_agent_summary, agent_id)
  end

  setup do
    create_ets_if_missing(:evogit_agent_summary, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_sched_meta, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_agent_inbox, [:bag, :named_table, :public])
    create_ets_if_missing(:evogit_agent_control, [:named_table, :public, :set])
    :ok
  end

  defp create_ets_if_missing(name, opts) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
    end
  end

  # --- The no-read-modify-write invariant -----------------------------------

  describe "the agent's state row is never rewritten by a cross-process write" do
    test "append / set_cancel / clear_cancel leave the row term-identical" do
      agent_id = put_live_agent!()
      before_row = raw_row(agent_id)

      assert :ok = Store.append_pending_user_message(agent_id, "an injected message")
      assert raw_row(agent_id) == before_row
      assert ControlPlane.pending_messages(agent_id) == ["an injected message"]

      assert :ok = Store.set_cancel_requested(agent_id)
      assert raw_row(agent_id) == before_row
      assert Store.cancel_requested?(agent_id)

      assert :ok = Store.clear_cancel_requested(agent_id)
      assert raw_row(agent_id) == before_row
      refute Store.cancel_requested?(agent_id)

      # The summary row has no control fields to project in the first place.
      [{_id, raw}] = raw_row(agent_id)
      refute Map.has_key?(raw, :pending_user_messages)
      refute Map.has_key?(raw, :cancel_requested)
    end

    test "put_agent_state/2 stores the row verbatim and never disturbs the control plane" do
      agent_id = put_live_agent!()
      assert :ok = Store.append_pending_user_message(agent_id, "queued")
      assert :ok = Store.set_cancel_requested(agent_id)

      # The session's own summary write: every field it supplies lands as-is
      # (there is no reset/merge of control state — the struct has none).
      written = %{
        agent_state()
        | turn: 7,
          message_count: 3,
          compression_count: 2,
          status: :running
      }

      :ok = Store.put_agent_state(agent_id, written)

      [{_id, raw}] = raw_row(agent_id)
      assert raw == written
      assert raw.turn == 7
      assert raw.message_count == 3
      assert raw.compression_count == 2
      assert raw.status == :running

      # …and the agent's own write never resurrects/drains the inbox or the flag.
      assert ControlPlane.pending_messages(agent_id) == ["queued"]
      assert Store.cancel_requested?(agent_id)
    end

    test "the state-owned compression_count persists across ordinary summary writes" do
      agent_id = put_live_agent!()

      :ok = Store.put_agent_state(agent_id, %{agent_state() | compression_count: 2})

      [{_id, raw}] = raw_row(agent_id)
      assert raw.compression_count == 2
      {:ok, row} = Store.get_agent_state(agent_id)
      assert row.compression_count == 2

      # A later ordinary write by the same owner keeps the counter: there is no
      # separate control-plane counter and no projection that could override it.
      :ok = Store.put_agent_state(agent_id, %{agent_state() | compression_count: 2, turn: 5})

      {:ok, row_after} = Store.get_agent_state(agent_id)
      assert row_after.compression_count == 2
      assert row_after.turn == 5
    end
  end

  # --- Concurrent append + drain --------------------------------------------

  describe "concurrent appends and drains" do
    test "every appended message is drained exactly once, in its own producer's order" do
      agent_id = put_live_agent!()
      writers = 6
      per_writer = 25
      total = writers * per_writer

      drainer =
        Task.async(fn ->
          drain_until(agent_id, total, System.monotonic_time(:millisecond) + 10_000, [])
        end)

      # The old whole-struct implementation (read the row, append, write the
      # whole struct back) loses every message that lands inside another
      # process's read-modify-write window — this is exactly that race.
      writer_tasks =
        for writer <- 1..writers do
          Task.async(fn ->
            for i <- 1..per_writer do
              :ok = Store.append_pending_user_message(agent_id, "w#{writer}-#{i}")
            end
          end)
        end

      Enum.each(writer_tasks, &Task.await(&1, 10_000))
      drained = Task.await(drainer, 15_000)

      assert length(drained) == total,
             "expected #{total} drained messages, got #{length(drained)}"

      assert drained |> Enum.frequencies() |> Map.values() |> Enum.all?(&(&1 == 1)),
             "no message may be delivered twice"

      for writer <- 1..writers do
        assert Enum.filter(drained, &String.starts_with?(&1, "w#{writer}-")) ==
                 Enum.map(1..per_writer, &"w#{writer}-#{&1}"),
               "writer #{writer}'s messages must arrive in its own append order"
      end

      assert Store.drain_pending_user_messages(agent_id) == []
    end
  end

  # --- Control flags under the agent's own writes ---------------------------

  describe "the control row survives the agent's concurrent state writes" do
    test "a cancel flag set mid-stream is still set, and the summary write is not lost" do
      agent_id = put_live_agent!()
      parent = self()

      writer =
        Task.async(fn ->
          Enum.each(1..200, fn turn ->
            :ok =
              Store.put_agent_state(agent_id, %{agent_state() | turn: turn, message_count: turn})

            if turn == 1, do: send(parent, {:first_write, self()})
          end)
        end)

      # Event-driven: set the flag only once the agent's own write path is
      # already running, so the two really are concurrent.
      assert_receive {:first_write, _pid}, 5_000
      :ok = Store.set_cancel_requested(agent_id)
      assert :ok = Task.await(writer, 10_000)

      assert Store.cancel_requested?(agent_id)

      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.turn == 200
      assert state.message_count == 200

      assert :ok = Store.clear_cancel_requested(agent_id)
      refute Store.cancel_requested?(agent_id)
    end

    test "50 concurrent control-plane writes all land while summary writes continue" do
      agent_id = put_live_agent!()

      state_tasks =
        for turn <- 1..10 do
          Task.async(fn -> Store.put_agent_state(agent_id, %{agent_state() | turn: turn}) end)
        end

      append_tasks =
        for i <- 1..50 do
          Task.async(fn -> :ok = Store.append_pending_user_message(agent_id, "m#{i}") end)
        end

      Enum.each(state_tasks ++ append_tasks, &Task.await(&1, 10_000))

      # Not one of the 50 concurrent control writes was lost to a summary write.
      pending = ControlPlane.pending_messages(agent_id)
      assert length(pending) == 50
      assert MapSet.new(pending) == MapSet.new(Enum.map(1..50, &"m#{&1}"))

      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.turn in 1..10
    end
  end

  # --- Ordering + summary shape ---------------------------------------------

  describe "pending message ordering" do
    test "pending_messages/1 peeks in append order and drain consumes that same order" do
      agent_id = put_live_agent!()

      for i <- 1..5, do: :ok = Store.append_pending_user_message(agent_id, "m#{i}")

      assert ControlPlane.pending_messages(agent_id) == ["m1", "m2", "m3", "m4", "m5"]

      # The summary row never carries the queue: it is a control-plane value.
      {:ok, state} = Store.get_agent_state(agent_id)
      refute Map.has_key?(state, :pending_user_messages)

      assert Store.drain_pending_user_messages(agent_id) == ["m1", "m2", "m3", "m4", "m5"]
      assert ControlPlane.pending_messages(agent_id) == []
      assert Store.drain_pending_user_messages(agent_id) == []
    end
  end

  # --- Totality (missing agent / missing table) -----------------------------

  describe "the control plane is total" do
    test "a missing agent answers the documented empty/error values" do
      absent = unique_agent_id()

      assert Store.get_agent_state(absent) == :error
      assert Store.drain_pending_user_messages(absent) == []
      refute Store.cancel_requested?(absent)
      assert {:error, :not_found} = Store.append_pending_user_message(absent, "nobody home")
      assert {:error, :not_found} = Store.set_cancel_requested(absent)
      assert {:error, :not_found} = Store.clear_cancel_requested(absent)

      # …and the transport module itself is equally total.
      assert ControlPlane.pending_messages(absent) == []
      assert ControlPlane.drain_messages(absent) == []
      assert {:error, :not_found} = ControlPlane.append_message(absent, "nobody home")
      assert {:error, :not_found} = ControlPlane.set_cancel(absent, true)
      refute ControlPlane.cancel_requested?(absent)
    end
  end

  # --- Cleanup --------------------------------------------------------------

  describe "delete_agent_state/1" do
    test "drops the inbox and the control row (no leak)" do
      agent_id = put_live_agent!()
      :ok = Store.append_pending_user_message(agent_id, "pending")
      :ok = Store.set_cancel_requested(agent_id)

      assert [_ | _] = :ets.lookup(:evogit_agent_inbox, agent_id)
      assert [_] = :ets.lookup(:evogit_agent_control, agent_id)

      assert :ok = Store.delete_agent_state(agent_id)

      assert :ets.lookup(:evogit_agent_inbox, agent_id) == []
      assert :ets.lookup(:evogit_agent_control, agent_id) == []
      assert Store.get_agent_state(agent_id) == :error
      refute Store.cancel_requested?(agent_id)
      assert Store.drain_pending_user_messages(agent_id) == []
    end
  end

  # --- Helpers --------------------------------------------------------------

  # Drains until `target` messages have been collected or the deadline passes —
  # a bounded poll (no fixed sleep), so a lossy implementation FAILS on the
  # count assertion instead of hanging.
  defp drain_until(agent_id, target, deadline, acc) do
    case Store.drain_pending_user_messages(agent_id) do
      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          acc
        else
          Process.sleep(1)
          drain_until(agent_id, target, deadline, acc)
        end

      drained ->
        acc = acc ++ drained

        if length(acc) >= target do
          acc
        else
          drain_until(agent_id, target, deadline, acc)
        end
    end
  end
end
