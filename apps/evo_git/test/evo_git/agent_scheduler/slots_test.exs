defmodule EvoGit.AgentScheduler.SlotsTest do
  @moduledoc """
  Tests for the pure slot-management functions in `EvoGit.AgentScheduler.Slots`.

  The Slots functions operate directly on `State` structs. For requests that
  block, a real `GenServer.from()` (`{self(), make_ref()}`) is used. When a
  pending waiter gets granted, `GenServer.reply(from, :ok)` sends `{ref, :ok}`
  to `self()`, which we assert with `assert_received`.

  Uses `async: false` to match sibling tests in this directory.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State

  defp base_state(overrides) do
    struct!(%State{max_concurrency: 2, max_tool_concurrency: 2}, overrides)
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
  end
end
