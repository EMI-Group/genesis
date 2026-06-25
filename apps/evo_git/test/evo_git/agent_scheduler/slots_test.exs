defmodule EvoGit.AgentScheduler.SlotsTest do
  @moduledoc """
  Tests for the pure slot-management functions in `EvoGit.AgentScheduler.Slots`.

  The Slots functions operate directly on `State` structs. For requests that
  block, a real `GenServer.from()` (`{self(), make_ref()}`) is used. When a
  pending waiter gets granted, `GenServer.reply(from, :ok)` sends `{ref, :ok}`
  to `self()`, which we assert with `assert_received`.

  Uses `async: false` to match sibling tests in this directory, and because
  tests manipulate the global named `:evogit_sched_meta` ETS table (required
  for depth lookups in priority-based LLM slot selection).
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  defp base_state(overrides) do
    struct!(%State{max_concurrency: 2, max_tool_concurrency: 2}, overrides)
  end

  # --- Shared fixtures ---

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp phylo_node do
    %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"}
  end

  defp agent_spec do
    %AgentSpec{
      context_node: context_node(),
      phylo_node: phylo_node(),
      agent_module: __MODULE__,
      objective: "test"
    }
  end

  # --- ETS helpers ---

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  defp put_meta(agent_id, depth) do
    meta = %SchedMeta{id: agent_id, depth: depth, spec: agent_spec()}
    :ets.insert(:evogit_sched_meta, {agent_id, meta})
    :ok
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_sched_meta)
    :ets.delete_all_objects(:evogit_sched_meta)
    on_exit(fn -> :ets.delete_all_objects(:evogit_sched_meta) end)
    :ok
  end

  # --- LLM slots ---

  describe "LLM slots" do
    test "grants LLM slot when available" do
      from = {self(), make_ref()}
      state = base_state([])

      assert {:reply, :ok, new_state, []} = Slots.handle_request_llm_slot(1, from, state)
      assert MapSet.member?(new_state.llm_holders, 1)
    end

    test "blocks LLM slot request when full" do
      from = {self(), make_ref()}
      # Both slots occupied (max_concurrency: 2)
      state = base_state(llm_holders: MapSet.new([1, 2]))

      assert {:noreply, new_state, [{3, :blocked}]} =
               Slots.handle_request_llm_slot(3, from, state)

      # Agent 3 is NOT added to holders
      refute MapSet.member?(new_state.llm_holders, 3)

      # Agent 3 is queued as a waiter
      assert :queue.to_list(new_state.llm_waiting) == [{3, from, nil}]
    end

    test "releasing LLM slot grants pending waiter" do
      ref = make_ref()
      from = {self(), ref}
      put_meta(2, 0)

      # Agent 1 holds the only slot; agent 2 is waiting
      state =
        base_state(
          llm_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{2, from, nil}])
        )

      assert {:reply, :ok, new_state, status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 2 now holds the slot, agent 1 released
      assert MapSet.member?(new_state.llm_holders, 2)
      refute MapSet.member?(new_state.llm_holders, 1)

      # Status update reflects the newly-running agent
      assert status_updates == [{2, :running}]

      # The granted waiter's from received :ok via GenServer.reply
      assert_received {^ref, :ok}
    end
  end

  # --- LLM priority-based selection ---

  describe "LLM priority selection" do
    @describetag :priority

    test "recency priority: most recently granted agent gets slot first" do
      ref3 = make_ref()
      from3 = {self(), ref3}
      ref4 = make_ref()
      from4 = {self(), ref4}

      put_meta(3, 0)
      put_meta(4, 0)

      # max_concurrency: 1 — only one slot exists.
      # Agent 1 holds it; agent 3 was last granted at t=5000, agent 4 never granted.
      state =
        base_state(
          max_concurrency: 1,
          llm_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{3, from3, nil}, {4, from4, nil}]),
          llm_last_granted: %{3 => 5000}
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 3 (more recent) should get the slot first
      assert MapSet.member?(new_state.llm_holders, 3)
      refute MapSet.member?(new_state.llm_holders, 4)

      # Agent 3's from received :ok
      assert_received {^ref3, :ok}
      refute_received {^ref4, :ok}
    end

    test "depth tie-breaker: lower depth wins when recency is equal" do
      ref3 = make_ref()
      from3 = {self(), ref3}
      ref4 = make_ref()
      from4 = {self(), ref4}

      put_meta(3, 2)
      put_meta(4, 0)

      # max_concurrency: 1 — only one slot. Agent 1 holds it;
      # both waiters have no llm_last_granted (recency tie).
      state =
        base_state(
          max_concurrency: 1,
          llm_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{3, from3, nil}, {4, from4, nil}])
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 4 (depth 0, lower) should get the slot first
      assert MapSet.member?(new_state.llm_holders, 4)
      refute MapSet.member?(new_state.llm_holders, 3)

      assert_received {^ref4, :ok}
      refute_received {^ref3, :ok}
    end

    test "combined: recency beats depth" do
      ref_a = make_ref()
      from_a = {self(), ref_a}
      ref_b = make_ref()
      from_b = {self(), ref_b}

      put_meta(3, 3)
      put_meta(4, 0)

      # max_concurrency: 1 — only one slot.
      # Agent 3 (depth 3) was recently granted; agent 4 (depth 0) never granted.
      # Recency is primary, so agent 3 should win despite higher depth.
      state =
        base_state(
          max_concurrency: 1,
          llm_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{3, from_a, nil}, {4, from_b, nil}]),
          llm_last_granted: %{3 => 9000}
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      assert MapSet.member?(new_state.llm_holders, 3)
      refute MapSet.member?(new_state.llm_holders, 4)

      assert_received {^ref_a, :ok}
      refute_received {^ref_b, :ok}
    end

    test "backoff still respected: agent in backoff is skipped" do
      ref3 = make_ref()
      from3 = {self(), ref3}
      ref4 = make_ref()
      from4 = {self(), ref4}

      put_meta(3, 0)
      put_meta(4, 0)

      # max_concurrency: 1 — only one slot.
      # Agent 3 is more recent but in backoff (far future).
      # Agent 4 is never-run and eligible. Agent 4 should get the slot.
      far_future = System.monotonic_time(:millisecond) + 60_000

      state =
        base_state(
          max_concurrency: 1,
          llm_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{3, from3, far_future}, {4, from4, nil}]),
          llm_last_granted: %{3 => 5000}
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 4 should get the slot (agent 3 is in backoff)
      assert MapSet.member?(new_state.llm_holders, 4)
      refute MapSet.member?(new_state.llm_holders, 3)

      assert_received {^ref4, :ok}
      refute_received {^ref3, :ok}

      # Agent 3 should still be waiting
      assert {3, from3, far_future} in :queue.to_list(new_state.llm_waiting)
    end

    test "all in backoff: no slots granted, queue preserved" do
      ref3 = make_ref()
      from3 = {self(), ref3}
      ref4 = make_ref()
      from4 = {self(), ref4}

      put_meta(3, 0)
      put_meta(4, 0)

      far_future = System.monotonic_time(:millisecond) + 60_000

      state =
        base_state(
          max_concurrency: 1,
          llm_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{3, from3, far_future}, {4, from4, far_future}])
        )

      assert {:reply, :ok, new_state, []} =
               Slots.handle_release_llm_slot(1, state)

      # No slots granted
      refute MapSet.member?(new_state.llm_holders, 3)
      refute MapSet.member?(new_state.llm_holders, 4)

      # No replies sent
      refute_received {^ref3, :ok}
      refute_received {^ref4, :ok}

      # Both still in queue
      waiting = :queue.to_list(new_state.llm_waiting)
      assert {3, from3, far_future} in waiting
      assert {4, from4, far_future} in waiting
    end
  end

  # --- Tool slots ---

  describe "Tool slots" do
    test "grants tool slot when available" do
      from = {self(), make_ref()}
      state = base_state([])

      assert {:reply, :ok, new_state, []} = Slots.handle_request_tool_slot(1, from, state)
      assert MapSet.member?(new_state.tool_holders, 1)
    end

    test "blocks tool slot request when full" do
      from = {self(), make_ref()}
      # Both tool slots occupied (max_tool_concurrency: 2)
      state = base_state(tool_holders: MapSet.new([1, 2]))

      assert {:noreply, new_state, [{3, :blocked}]} =
               Slots.handle_request_tool_slot(3, from, state)

      # Agent 3 is NOT added to holders
      refute MapSet.member?(new_state.tool_holders, 3)

      # Tool waiting queue entries are 2-tuples (no backoff field)
      assert :queue.to_list(new_state.tool_waiting) == [{3, from}]
    end

    test "releasing tool slot grants pending waiter" do
      ref = make_ref()
      from = {self(), ref}

      # Agent 1 holds the only tool slot; agent 2 is waiting
      state =
        base_state(
          tool_holders: MapSet.new([1]),
          tool_waiting: :queue.from_list([{2, from}])
        )

      assert {:reply, :ok, new_state, status_updates} =
               Slots.handle_release_tool_slot(1, state)

      # Agent 2 now holds the slot, agent 1 released
      assert MapSet.member?(new_state.tool_holders, 2)
      refute MapSet.member?(new_state.tool_holders, 1)

      # Status update reflects the newly-running agent
      assert status_updates == [{2, :running}]

      # The granted waiter's from received :ok via GenServer.reply
      assert_received {^ref, :ok}
    end
  end

  # --- Combined LLM + tool cleanup ---

  describe "release_agent_slots/2" do
    test "frees both LLM and tool slots and grants pending waiters" do
      llm_ref = make_ref()
      llm_from = {self(), llm_ref}
      tool_ref = make_ref()
      tool_from = {self(), tool_ref}

      put_meta(2, 0)

      # Agent 1 holds BOTH an LLM and a tool slot; agent 2 is waiting on both
      state =
        base_state(
          llm_holders: MapSet.new([1]),
          tool_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{2, llm_from, nil}]),
          tool_waiting: :queue.from_list([{2, tool_from}])
        )

      assert {new_state, status_updates} = Slots.release_agent_slots(state, 1)

      # Agent 1 removed from both holder sets
      refute MapSet.member?(new_state.llm_holders, 1)
      refute MapSet.member?(new_state.tool_holders, 1)

      # Agent 2 added to both holder sets
      assert MapSet.member?(new_state.llm_holders, 2)
      assert MapSet.member?(new_state.tool_holders, 2)

      # Agent 2 reported as running (once per slot type)
      assert {2, :running} in status_updates

      # Both granted waiters received :ok via GenServer.reply
      assert_received {^llm_ref, :ok}
      assert_received {^tool_ref, :ok}
    end

    test "cleans up llm_last_granted on agent death" do
      llm_ref = make_ref()
      llm_from = {self(), llm_ref}
      tool_ref = make_ref()
      tool_from = {self(), tool_ref}

      put_meta(2, 0)

      # Agent 1 has a recorded llm_last_granted timestamp
      state =
        base_state(
          llm_holders: MapSet.new([1]),
          tool_holders: MapSet.new([1]),
          llm_waiting: :queue.from_list([{2, llm_from, nil}]),
          tool_waiting: :queue.from_list([{2, tool_from}]),
          llm_last_granted: %{1 => 5000, 2 => 3000}
        )

      assert {new_state, _status_updates} = Slots.release_agent_slots(state, 1)

      # Agent 1's entry should be removed from llm_last_granted
      refute Map.has_key?(new_state.llm_last_granted, 1)

      # Agent 2's entry should still be present (it was granted, so updated)
      assert Map.has_key?(new_state.llm_last_granted, 2)
    end
  end
end
