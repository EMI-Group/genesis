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

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @default_model "default"
  @fast_model "fast"

  # --- State builders ---

  defp base_state(overrides) do
    profiles = [
      %{id: @default_model, model: "provider:default", concurrency: 2},
      %{id: @fast_model, model: "provider:fast", concurrency: 1}
    ]

    state = State.from_model_profiles(profiles, max_tool_concurrency: 2)
    struct!(state, overrides)
  end

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

  defp put_agent_state(agent_id, model_id) do
    state = %AgentState{
      context_node: context_node(),
      llm_model: "test:model",
      model_id: model_id,
      max_retries: 15,
      max_depth: 8
    }

    :ets.insert(:evogit_agent_state, {agent_id, state})
    :ok
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_sched_meta)
    create_ets_if_missing(:evogit_agent_state)
    :ets.delete_all_objects(:evogit_sched_meta)
    :ets.delete_all_objects(:evogit_agent_state)
    on_exit(fn -> :ets.delete_all_objects(:evogit_sched_meta) end)
    :ok
  end

  # --- LLM slots ---

  describe "LLM slots" do
    test "grants LLM slot when available" do
      from = {self(), make_ref()}
      state = base_state([])
      put_agent_state(1, @default_model)

      assert {:reply, :ok, new_state, []} = Slots.handle_request_llm_slot(1, from, state)
      assert MapSet.member?(State.holders_for(new_state, @default_model), 1)
    end

    test "blocks LLM slot request when full" do
      from = {self(), make_ref()}
      put_agent_state(3, @default_model)

      # Both default slots occupied (concurrency: 2)
      state =
        base_state(llm_holders: %{@default_model => MapSet.new([1, 2])})

      assert {:noreply, new_state, [{3, :blocked}]} =
               Slots.handle_request_llm_slot(3, from, state)

      # Agent 3 is NOT added to holders
      refute MapSet.member?(State.holders_for(new_state, @default_model), 3)

      # Agent 3 is queued as a waiter
      assert :queue.to_list(State.waiting_for(new_state, @default_model)) == [{3, from, nil}]
    end

    test "releasing LLM slot grants pending waiter" do
      ref = make_ref()
      from = {self(), ref}
      put_meta(2, 0)
      put_agent_state(1, @default_model)
      put_agent_state(2, @default_model)

      # Agent 1 holds the only slot; agent 2 is waiting
      state =
        base_state(
          llm_holders: %{@default_model => MapSet.new([1])},
          llm_waiting: %{@default_model => :queue.from_list([{2, from, nil}])}
        )

      assert {:reply, :ok, new_state, status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 2 now holds the slot, agent 1 released
      assert MapSet.member?(State.holders_for(new_state, @default_model), 2)
      refute MapSet.member?(State.holders_for(new_state, @default_model), 1)

      # Status update reflects the newly-running agent
      assert status_updates == [{2, :running}]

      # The granted waiter's from received :ok via GenServer.reply
      assert_received {^ref, :ok}
    end
  end

  # --- Per-model pool isolation ---

  describe "per-model pool isolation" do
    test "two models each get their own slots" do
      from_default = {self(), make_ref()}
      from_fast = {self(), make_ref()}

      put_agent_state(1, @default_model)
      put_agent_state(2, @fast_model)

      state = base_state([])

      # Default model has concurrency 2, fast model has concurrency 1
      assert {:reply, :ok, state, []} = Slots.handle_request_llm_slot(1, from_default, state)
      assert {:reply, :ok, state, []} = Slots.handle_request_llm_slot(2, from_fast, state)

      # Both got slots independently
      assert MapSet.member?(State.holders_for(state, @default_model), 1)
      assert MapSet.member?(State.holders_for(state, @fast_model), 2)
    end

    test "default model being full does not block fast model" do
      from_default = {self(), make_ref()}
      from_fast = {self(), make_ref()}

      put_agent_state(3, @default_model)
      put_agent_state(4, @fast_model)

      # Default model pool is full (concurrency: 2)
      state =
        base_state(llm_holders: %{@default_model => MapSet.new([1, 2])})

      # Agent 3 on default model should be blocked
      assert {:noreply, state, [{3, :blocked}]} =
               Slots.handle_request_llm_slot(3, from_default, state)

      # Agent 4 on fast model should still get a slot (independent pool)
      assert {:reply, :ok, state, []} = Slots.handle_request_llm_slot(4, from_fast, state)

      assert MapSet.member?(State.holders_for(state, @fast_model), 4)
      refute MapSet.member?(State.holders_for(state, @default_model), 3)
    end
  end

  # --- Per-model backoff ---

  describe "per-model backoff" do
    test "rate-limit on default model does not block fast model" do
      ref_fast = make_ref()
      from_fast = {self(), ref_fast}

      put_agent_state(1, @default_model)
      put_agent_state(2, @fast_model)
      put_agent_state(99, @fast_model)
      put_meta(2, 0)

      # Agent 2 (fast model) is waiting for a slot
      state =
        base_state(
          llm_holders: %{@fast_model => MapSet.new([99])},
          llm_waiting: %{@fast_model => :queue.from_list([{2, from_fast, nil}])}
        )

      # Agent 1 (default model) reports a rate-limit error
      assert {:reply, :ok, new_state, []} =
               Slots.handle_report_llm_error(1, :rate_limit, state)

      # Only default model has backoff; fast model does not
      assert State.backoff_for(new_state, @default_model) != nil
      assert State.backoff_for(new_state, @fast_model) == nil

      # Now release the fast model slot — agent 2 should be granted immediately
      # because the fast model has no backoff.
      assert {:reply, :ok, granted_state, [{2, :running}]} =
               Slots.handle_release_llm_slot(99, new_state)

      assert MapSet.member?(State.holders_for(granted_state, @fast_model), 2)
      assert_received {^ref_fast, :ok}
    end

    test "report_llm_error sets backoff only on the agent's model pool" do
      put_agent_state(1, @default_model)
      state = base_state([])

      assert {:reply, :ok, new_state, []} =
               Slots.handle_report_llm_error(1, :rate_limit, state)

      assert State.backoff_for(new_state, @default_model) != nil
      assert State.backoff_for(new_state, @fast_model) == nil
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
      put_agent_state(1, @default_model)
      put_agent_state(3, @default_model)
      put_agent_state(4, @default_model)

      # max_concurrency: 1 — override for this test.
      # Agent 1 holds it; agent 3 was last granted at t=5000, agent 4 never granted.
      state =
        base_state(
          model_concurrency: %{@default_model => 1, @fast_model => 1},
          llm_holders: %{@default_model => MapSet.new([1])},
          llm_waiting: %{
            @default_model => :queue.from_list([{3, from3, nil}, {4, from4, nil}])
          },
          llm_last_granted: %{@default_model => %{3 => 5000}}
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 3 (more recent) should get the slot first
      assert MapSet.member?(State.holders_for(new_state, @default_model), 3)
      refute MapSet.member?(State.holders_for(new_state, @default_model), 4)

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
      put_agent_state(1, @default_model)
      put_agent_state(3, @default_model)
      put_agent_state(4, @default_model)

      state =
        base_state(
          model_concurrency: %{@default_model => 1, @fast_model => 1},
          llm_holders: %{@default_model => MapSet.new([1])},
          llm_waiting: %{
            @default_model => :queue.from_list([{3, from3, nil}, {4, from4, nil}])
          }
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 4 (depth 0, lower) should get the slot first
      assert MapSet.member?(State.holders_for(new_state, @default_model), 4)
      refute MapSet.member?(State.holders_for(new_state, @default_model), 3)

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
      put_agent_state(1, @default_model)
      put_agent_state(3, @default_model)
      put_agent_state(4, @default_model)

      state =
        base_state(
          model_concurrency: %{@default_model => 1, @fast_model => 1},
          llm_holders: %{@default_model => MapSet.new([1])},
          llm_waiting: %{
            @default_model => :queue.from_list([{3, from_a, nil}, {4, from_b, nil}])
          },
          llm_last_granted: %{@default_model => %{3 => 9000}}
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      assert MapSet.member?(State.holders_for(new_state, @default_model), 3)
      refute MapSet.member?(State.holders_for(new_state, @default_model), 4)

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
      put_agent_state(1, @default_model)
      put_agent_state(3, @default_model)
      put_agent_state(4, @default_model)

      far_future = System.monotonic_time(:millisecond) + 60_000

      state =
        base_state(
          model_concurrency: %{@default_model => 1, @fast_model => 1},
          llm_holders: %{@default_model => MapSet.new([1])},
          llm_waiting: %{
            @default_model => :queue.from_list([{3, from3, far_future}, {4, from4, nil}])
          },
          llm_last_granted: %{@default_model => %{3 => 5000}}
        )

      assert {:reply, :ok, new_state, _status_updates} =
               Slots.handle_release_llm_slot(1, state)

      # Agent 4 should get the slot (agent 3 is in backoff)
      assert MapSet.member?(State.holders_for(new_state, @default_model), 4)
      refute MapSet.member?(State.holders_for(new_state, @default_model), 3)

      assert_received {^ref4, :ok}
      refute_received {^ref3, :ok}

      # Agent 3 should still be waiting
      assert {3, from3, far_future} in :queue.to_list(
               State.waiting_for(new_state, @default_model)
             )
    end

    test "all in backoff: no slots granted, queue preserved" do
      ref3 = make_ref()
      from3 = {self(), ref3}
      ref4 = make_ref()
      from4 = {self(), ref4}

      put_meta(3, 0)
      put_meta(4, 0)
      put_agent_state(1, @default_model)

      far_future = System.monotonic_time(:millisecond) + 60_000

      state =
        base_state(
          model_concurrency: %{@default_model => 1, @fast_model => 1},
          llm_holders: %{@default_model => MapSet.new([1])},
          llm_waiting: %{
            @default_model => :queue.from_list([{3, from3, far_future}, {4, from4, far_future}])
          }
        )

      assert {:reply, :ok, new_state, []} =
               Slots.handle_release_llm_slot(1, state)

      # No slots granted
      refute MapSet.member?(State.holders_for(new_state, @default_model), 3)
      refute MapSet.member?(State.holders_for(new_state, @default_model), 4)

      # No replies sent
      refute_received {^ref3, :ok}
      refute_received {^ref4, :ok}

      # Both still in queue
      waiting = :queue.to_list(State.waiting_for(new_state, @default_model))
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
      put_agent_state(1, @default_model)
      put_agent_state(2, @default_model)

      # Agent 1 holds BOTH an LLM and a tool slot; agent 2 is waiting on both
      state =
        base_state(
          llm_holders: %{@default_model => MapSet.new([1])},
          tool_holders: MapSet.new([1]),
          llm_waiting: %{@default_model => :queue.from_list([{2, llm_from, nil}])},
          tool_waiting: :queue.from_list([{2, tool_from}])
        )

      assert {new_state, status_updates} = Slots.release_agent_slots(state, 1)

      # Agent 1 removed from both holder sets
      refute MapSet.member?(State.holders_for(new_state, @default_model), 1)
      refute MapSet.member?(new_state.tool_holders, 1)

      # Agent 2 added to both holder sets
      assert MapSet.member?(State.holders_for(new_state, @default_model), 2)
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
      put_agent_state(1, @default_model)
      put_agent_state(2, @default_model)

      # Agent 1 has a recorded llm_last_granted timestamp
      state =
        base_state(
          llm_holders: %{@default_model => MapSet.new([1])},
          tool_holders: MapSet.new([1]),
          llm_waiting: %{@default_model => :queue.from_list([{2, llm_from, nil}])},
          tool_waiting: :queue.from_list([{2, tool_from}]),
          llm_last_granted: %{@default_model => %{1 => 5000, 2 => 3000}}
        )

      assert {new_state, _status_updates} = Slots.release_agent_slots(state, 1)

      # Agent 1's entry should be removed from llm_last_granted
      refute Map.has_key?(State.last_granted_for(new_state, @default_model), 1)

      # Agent 2's entry should still be present (it was granted, so updated)
      assert Map.has_key?(State.last_granted_for(new_state, @default_model), 2)
    end

    test "releases slots from the correct model pool on agent death" do
      put_agent_state(1, @default_model)
      put_agent_state(2, @fast_model)

      state =
        base_state(
          llm_holders: %{
            @default_model => MapSet.new([1]),
            @fast_model => MapSet.new([2])
          }
        )

      {new_state, _} = Slots.release_agent_slots(state, 1)

      # Agent 1 removed from default pool
      refute MapSet.member?(State.holders_for(new_state, @default_model), 1)
      # Agent 2 untouched in fast pool
      assert MapSet.member?(State.holders_for(new_state, @fast_model), 2)
    end
  end

  # --- Model ID resolution ---

  describe "resolve_model_id/2" do
    test "returns the agent's model_id from ETS" do
      put_agent_state(1, @fast_model)
      state = base_state([])

      assert Slots.resolve_model_id(1, state) == @fast_model
    end

    test "falls back to default when agent has no model_id" do
      # Agent with no model_id in ETS (simulated by missing entry)
      state = base_state([])

      assert Slots.resolve_model_id(999, state) == @default_model
    end
  end
end
