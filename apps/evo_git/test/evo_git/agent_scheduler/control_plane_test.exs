defmodule EvoGit.AgentScheduler.ControlPlaneTest do
  @moduledoc """
  The scheduler CONTROL PLANE (P0 of the agent-runtime refactor): every value a
  process OTHER than the agent writes about a live agent lives in
  `:evogit_agent_inbox` (a `:bag` of `{agent_id, {seq, message}}`) and
  `:evogit_agent_control` (a `:set` of `{agent_id, cancel_requested,
  compression_count}`), never in the agent's own `:evogit_agent_summary` row.

  What these tests pin:

    * the no-read-modify-write invariant — `append_pending_user_message/2`,
      `set_cancel_requested/1`, `clear_cancel_requested/1` and
      `increment_compression_count/1` leave the raw state row TERM-IDENTICAL
      (the assertion that failed on the old whole-struct implementation);
    * a concurrent append/drain stress test where every message is delivered
      EXACTLY once and each producer's messages keep their own order (the old
      whole-struct drain lost any message appended between its read and write);
    * a cancel flag and N concurrent compression increments that both survive
      the agent's own concurrent context writes;
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
  alias EvoGit.Core.PhyloGraphNode

  @id_base 9_950_000

  # --- Fixtures -------------------------------------------------------------

  defp agent_state do
    %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"},
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

  # The RAW row, exactly as stored — no projection.
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
    test "append / set_cancel / clear_cancel / increment leave the row term-identical" do
      agent_id = put_live_agent!()
      before_row = raw_row(agent_id)

      assert :ok = Store.append_pending_user_message(agent_id, "an injected message")
      assert raw_row(agent_id) == before_row

      assert :ok = Store.set_cancel_requested(agent_id)
      assert raw_row(agent_id) == before_row

      assert :ok = Store.clear_cancel_requested(agent_id)
      assert raw_row(agent_id) == before_row

      assert :ok = Store.increment_compression_count(agent_id)
      assert raw_row(agent_id) == before_row

      # ...while the PROJECTED reads still see every live value.
      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.cancel_requested == nil
      assert state.compression_count == 1
      assert state.pending_user_messages == ["an injected message"]
    end

    test "put_agent_state resets the control fields (a projected struct is never written back)" do
      agent_id = put_live_agent!()
      assert :ok = Store.append_pending_user_message(agent_id, "queued")
      assert :ok = Store.set_cancel_requested(agent_id)

      # Writing back a PROJECTED struct (the documented hazard) must not
      # resurrect the drained message or the stale flag.
      {:ok, projected} = Store.get_agent_state(agent_id)
      :ok = Store.put_agent_state(agent_id, projected)

      assert length(:ets.lookup(:evogit_agent_inbox, agent_id)) == 1
      assert Store.cancel_requested?(agent_id)
      [{_id, raw}] = raw_row(agent_id)
      assert raw.pending_user_messages == []
      assert raw.cancel_requested == nil
      assert raw.compression_count == 0
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
    test "a cancel flag set mid-stream is still set, and the context write is not lost" do
      agent_id = put_live_agent!()
      parent = self()

      writer =
        Task.async(fn ->
          Enum.each(1..200, fn turn ->
            :ok =
              Store.batch_update_agent(agent_id,
                context: ReqLLM.Context.new([ReqLLM.Context.user("turn #{turn}")]),
                turn: turn
              )

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
      assert %ReqLLM.Context{messages: [_ | _]} = state.context

      assert :ok = Store.clear_cancel_requested(agent_id)
      refute Store.cancel_requested?(agent_id)
    end

    test "50 concurrent compression increments all land while context writes continue" do
      agent_id = put_live_agent!()

      context_tasks =
        for turn <- 1..10 do
          Task.async(fn -> Store.batch_update_agent(agent_id, turn: turn) end)
        end

      increment_tasks =
        for _ <- 1..50 do
          Task.async(fn -> :ok = Store.increment_compression_count(agent_id) end)
        end

      Enum.each(context_tasks ++ increment_tasks, &Task.await(&1, 10_000))

      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.compression_count == 50
      assert state.turn in 1..10
    end
  end

  # --- Ordering + projection ------------------------------------------------

  describe "pending message ordering and projection" do
    test "pending_messages/1 peeks in append order and drain consumes that same order" do
      agent_id = put_live_agent!()

      for i <- 1..5, do: :ok = Store.append_pending_user_message(agent_id, "m#{i}")

      assert ControlPlane.pending_messages(agent_id) == ["m1", "m2", "m3", "m4", "m5"]

      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.pending_user_messages == ["m1", "m2", "m3", "m4", "m5"]

      assert Store.drain_pending_user_messages(agent_id) == ["m1", "m2", "m3", "m4", "m5"]
      assert ControlPlane.pending_messages(agent_id) == []

      {:ok, drained_state} = Store.get_agent_state(agent_id)
      assert drained_state.pending_user_messages == []
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
      # The long-standing contract: a missing agent still crashes this helper.
      assert_raise MatchError, fn -> Store.increment_compression_count(absent) end
    end
  end

  # --- Cleanup --------------------------------------------------------------

  describe "delete_agent_state/1" do
    test "drops the inbox and the control row (no leak)" do
      agent_id = put_live_agent!()
      :ok = Store.append_pending_user_message(agent_id, "pending")
      :ok = Store.set_cancel_requested(agent_id)
      :ok = Store.increment_compression_count(agent_id)

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
