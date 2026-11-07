defmodule EvoGit.AgentScheduler.ToolPauseRegressionTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.{Slots, State}

  # In-process state handlers only: no live scheduler, global config changes or
  # ETS writes. Unique ids also keep any scheduler ETS lookups test-local.
  setup do
    first = 2_000_000_000 + System.unique_integer([:positive, :monotonic]) * 10
    %{state: %State{max_tool_concurrency: 1}, holder: first, waiter: first + 1}
  end

  defp grant_tool(state, id) do
    assert {:reply, :ok, state, []} =
             Slots.handle_request_tool_slot(id, {self(), make_ref()}, state)

    state
  end

  defp enqueue_tool(state, id) do
    from = {self(), make_ref()}
    assert {:noreply, state, [{^id, :blocked}]} = Slots.handle_request_tool_slot(id, from, state)
    {state, from}
  end

  defp assert_tool_resumed_once(state, holders, waiter, {_, ref}) do
    assert {state, [{^waiter, :running}]} =
             Slots.grant_pending_on_resume(%{state | paused: false})

    assert_received {^ref, :ok}
    assert state.tool_holders == MapSet.new(holders)
    assert :queue.is_empty(state.tool_waiting)
    assert Slots.grant_pending_on_resume(state) == {state, []}
    refute_received {^ref, _}
  end

  test "tool release during global pause frees the holder without granting the waiter", %{
    state: state,
    holder: holder,
    waiter: waiter
  } do
    state = grant_tool(state, holder)
    {state, {_, ref} = from} = enqueue_tool(state, waiter)
    queued = state.tool_waiting

    assert {state, []} = Slots.handle_release_tool_slot(holder, %{state | paused: true})
    assert state.paused
    assert state.tool_holders == MapSet.new()
    assert state.tool_waiting == queued
    assert :queue.to_list(state.tool_waiting) == [{waiter, from}]
    refute_received {^ref, _}

    assert_tool_resumed_once(state, [waiter], waiter, from)
  end

  test "increasing tool capacity while globally paused preserves holders and the queue", %{
    state: state,
    holder: holder,
    waiter: waiter
  } do
    state = grant_tool(state, holder)
    {state, {_, ref} = from} = enqueue_tool(state, waiter)
    queued = state.tool_waiting

    assert {:reply, :ok, state} =
             State.do_update_config([max_tool_concurrency: 2], %{state | paused: true})

    assert state.paused
    assert state.max_tool_concurrency == 2
    assert state.tool_holders == MapSet.new([holder])
    assert state.tool_waiting == queued
    assert :queue.to_list(state.tool_waiting) == [{waiter, from}]
    refute_received {^ref, _}

    assert_tool_resumed_once(state, [holder, waiter], waiter, from)
  end

  test "death cleanup during global pause frees both pools but grants survivors only on resume",
       %{
         state: state,
         holder: holder,
         waiter: tool_waiter
       } do
    pool = "pause-cleanup"
    llm_waiter = tool_waiter + 1
    llm_ref = make_ref()
    llm_from = {self(), llm_ref}

    state = grant_tool(state, holder)
    {state, {_, tool_ref} = tool_from} = enqueue_tool(state, tool_waiter)

    state = %{
      state
      | paused: true,
        model_concurrency: %{pool => 1},
        llm_holders: %{pool => MapSet.new([holder])},
        llm_last_granted: %{pool => %{holder => 123}},
        llm_waiting: %{pool => :queue.from_list([{llm_waiter, llm_from, nil}])}
    }

    tool_queue = state.tool_waiting
    llm_queue = State.waiting_for(state, pool)
    assert {state, []} = Slots.release_agent_slots(state, holder)
    assert state.paused
    assert state.tool_holders == MapSet.new()
    assert State.holders_for(state, pool) == MapSet.new()
    assert State.last_granted_for(state, pool) == %{}
    assert state.tool_waiting == tool_queue
    assert State.waiting_for(state, pool) == llm_queue
    assert :queue.to_list(state.tool_waiting) == [{tool_waiter, tool_from}]
    assert :queue.to_list(llm_queue) == [{llm_waiter, llm_from, nil}]
    refute_received {^tool_ref, _}
    refute_received {^llm_ref, _}

    assert {state, [{^llm_waiter, :running}, {^tool_waiter, :running}]} =
             Slots.grant_pending_on_resume(%{state | paused: false})

    assert_received {^llm_ref, :ok}
    assert_received {^tool_ref, :ok}
    assert state.tool_holders == MapSet.new([tool_waiter])
    assert State.holders_for(state, pool) == MapSet.new([llm_waiter])
    assert Map.has_key?(State.last_granted_for(state, pool), llm_waiter)
    refute Map.has_key?(State.last_granted_for(state, pool), holder)
    assert :queue.is_empty(state.tool_waiting)
    assert :queue.is_empty(State.waiting_for(state, pool))
    assert Slots.grant_pending_on_resume(state) == {state, []}
    refute_received {^tool_ref, _}
    refute_received {^llm_ref, _}
  end
end
