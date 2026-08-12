defmodule EvoGit.AgentScheduler.StateTest do
  @moduledoc """
  Regression tests for `EvoGit.AgentScheduler.State` slot-pool management
  (fix commits 661bb61e + d1d404ac):

  - B1 deadlock: `do_update_config/2` with `:model_profiles` must preserve
    LIVE pools (holders, waiting queues with their GenServer `from` refs,
    backoff, last-granted). The old code rebuilt the pool maps from the new
    profiles only, dropping queued waiters' `from` refs (permanent hang) and
    forgetting live holders (over-grant).
  - `all_model_ids/1` must return the UNION of `model_concurrency` + live
    pool map keys so stale/unknown-model pools are swept by the slot
    machinery.
  - `apply_default_llm_concurrency_override/2` must set the default AND floor
    every per-model concurrency entry (Fix E — CLI `-c` / dashboard default
    concurrency overrides now take effect immediately for all live pools).

  Pure-function style, matching the sibling `slots_test.exs`: real
  `GenServer.from` tuples `{self(), make_ref()}` and `assert_received` for
  grant replies. `async: false` because the global named ETS tables are
  shared.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @default_model "default"

  # --- Helpers (mirror slots_test.exs conventions) ---

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

  defp profile(id, concurrency) do
    %{id: id, model: "provider:#{id}", concurrency: concurrency}
  end

  # A state with a single "default" profile (concurrency 2) whose pool is
  # FULL (holders 1, 2).
  defp full_default_state do
    State.from_model_profiles([profile("default", 2)])
    |> State.update_holders(@default_model, MapSet.new([1, 2]))
  end

  defp queue_default_waiter(state, agent_id, from) do
    waiting = State.waiting_for(state, @default_model)
    State.update_waiting(state, @default_model, :queue.in({agent_id, from, nil}, waiting))
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_sched_meta)
    create_ets_if_missing(:evogit_agent_state)
    :ets.delete_all_objects(:evogit_sched_meta)
    :ets.delete_all_objects(:evogit_agent_state)
    on_exit(fn -> :ets.delete_all_objects(:evogit_sched_meta) end)

    # `do_update_config/2` ends with an unconditional
    # `Phoenix.PubSub.broadcast(EvoGit.PubSub, ...)`. Under `mix test` the
    # :evo_git app is started, so EvoGit.PubSub is already running. If the app
    # is not running (e.g. `mix test --no-start`), start a bare
    # Phoenix.PubSub so the broadcast doesn't raise.
    if Process.whereis(EvoGit.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: EvoGit.PubSub})
    end

    :ok
  end

  # --- do_update_config/2: model_profiles updates preserve live pools ---

  describe "do_update_config/2 — model_profiles updates preserve live pools" do
    test "queued waiter is granted when profile concurrency is raised (B1 deadlock regression)" do
      ref = make_ref()
      from = {self(), ref}
      put_meta(3, 0)
      put_agent_state(3, @default_model)

      state = full_default_state()
      assert {:noreply, state2, [{3, :blocked}]} = Slots.handle_request_llm_slot(3, from, state)

      # Pre-fix: the :model_profiles branch rebuilt the pool maps from the new
      # profiles only, dropping agent 3's queued `from` — a permanent hang.
      assert {:reply, :ok, final} =
               State.do_update_config([model_profiles: [profile("default", 3)]], state2)

      # Capacity raised 2 -> 3: the trailing grant_pending_on_resume grants 3.
      assert MapSet.member?(State.holders_for(final, @default_model), 3)
      assert :queue.to_list(State.waiting_for(final, @default_model)) == []
      assert_received {^ref, :ok}
    end

    test "queued waiter survives a concurrency-unchanged profile re-save" do
      ref = make_ref()
      from = {self(), ref}
      put_meta(3, 0)
      put_agent_state(3, @default_model)

      state = full_default_state()
      assert {:noreply, state2, [{3, :blocked}]} = Slots.handle_request_llm_slot(3, from, state)

      # Same profiles re-saved (e.g. dashboard save): no capacity change, so
      # the waiter must remain queued with its `from` intact — not dropped.
      assert {:reply, :ok, survived} =
               State.do_update_config([model_profiles: [profile("default", 2)]], state2)

      assert {3, from, nil} in :queue.to_list(State.waiting_for(survived, @default_model))
      refute MapSet.member?(State.holders_for(survived, @default_model), 3)
      refute_received {^ref, :ok}

      # The preserved `from` is still functional: a later grant reaches it.
      freed = %{survived | llm_holders: %{@default_model => MapSet.new([1])}}
      {granted, _} = Slots.grant_pending_on_resume(freed)
      assert MapSet.member?(State.holders_for(granted, @default_model), 3)
      assert_received {^ref, :ok}
    end

    test "live pools of a dropped profile survive the update; its waiter is granted" do
      ref4 = make_ref()
      from4 = {self(), ref4}
      ref6 = make_ref()
      from6 = {self(), ref6}
      future_backoff = System.monotonic_time(:millisecond) + 60_000

      profiles = [profile("default", 2)]

      state =
        State.from_model_profiles(profiles)
        |> State.update_holders(@default_model, MapSet.new([1, 2]))
        |> queue_default_waiter(4, from4)
        |> State.update_holders("old-model", MapSet.new([5]))
        |> State.update_waiting("old-model", :queue.from_list([{6, from6, nil}]))
        |> State.update_backoff("old-model", future_backoff)

      # New profiles DROP "old-model" — its live entries must not be wiped.
      assert {:reply, :ok, new_state} = State.do_update_config([model_profiles: profiles], state)

      # "old-model" is no longer a configured profile...
      refute Map.has_key?(new_state.model_concurrency, "old-model")

      # ...but its live pool entries are preserved: holder stays counted
      # (over-grant prevention), backoff stays set, waiting key stays present.
      assert MapSet.member?(State.holders_for(new_state, "old-model"), 5)
      assert State.backoff_for(new_state, "old-model") == future_backoff
      assert Map.has_key?(new_state.llm_waiting, "old-model")

      # The old-model waiter is granted by the trailing grant_pending_on_resume
      # (capacity = fallback default 2, holders {5} size 1 < 2).
      assert MapSet.member?(State.holders_for(new_state, "old-model"), 6)
      assert_received {^ref6, :ok}

      # The "default" waiter stays queued (capacity unchanged at 2, still full).
      assert {4, from4, nil} in :queue.to_list(State.waiting_for(new_state, @default_model))
      refute_received {^ref4, :ok}
    end
  end

  # --- all_model_ids/1: union of pool map keys ---

  describe "all_model_ids/1 — union of pool map keys" do
    test "includes ids present only in llm_holders/llm_waiting/llm_backoff_until" do
      future = System.monotonic_time(:millisecond) + 60_000

      state = %State{
        model_concurrency: %{"mc" => 1},
        llm_holders: %{"ghost" => MapSet.new([9])},
        llm_waiting: %{"wq" => :queue.from_list([{1, {self(), make_ref()}, nil}])},
        llm_backoff_until: %{"bo" => future}
      }

      # Each id exists in exactly one map; all must be returned even though
      # model_concurrency has none of them (stale pools must stay sweepable).
      assert Enum.sort(State.all_model_ids(state)) == ["bo", "ghost", "mc", "wq"]
    end
  end

  # --- apply_default_llm_concurrency_override/2: floor semantics (Fix E) ---

  describe "apply_default_llm_concurrency_override/2 — floor semantics (Fix E)" do
    test "floors every model_concurrency entry to the new default" do
      state = %State{model_concurrency: %{"default" => 2, "fast" => 7}}

      raised = State.apply_default_llm_concurrency_override(state, 5)
      assert raised.default_llm_max_concurrency == 5
      assert raised.model_concurrency == %{"default" => 5, "fast" => 7}

      raised_more = State.apply_default_llm_concurrency_override(state, 10)
      assert raised_more.default_llm_max_concurrency == 10
      assert raised_more.model_concurrency == %{"default" => 10, "fast" => 10}
    end

    test "never lowers explicit profile concurrencies" do
      state = %State{model_concurrency: %{"default" => 2, "fast" => 7}}

      lowered = State.apply_default_llm_concurrency_override(state, 1)
      assert lowered.default_llm_max_concurrency == 1
      assert lowered.model_concurrency == %{"default" => 2, "fast" => 7}
    end
  end

  # --- do_update_config/2: live default_llm_max_concurrency override (Fix E) ---

  describe "do_update_config/2 — default_llm_max_concurrency override (Fix E)" do
    test "raises capacity of a live pool and grants its queued waiter (with profiles)" do
      ref = make_ref()
      from = {self(), ref}
      put_meta(3, 0)
      put_agent_state(3, @default_model)

      state = full_default_state()
      assert {:noreply, state2, [{3, :blocked}]} = Slots.handle_request_llm_slot(3, from, state)

      # The default override FLOORS every model_concurrency entry, so the
      # "default" pool's capacity jumps from 2 to 5 and the waiter is granted.
      assert {:reply, :ok, final} =
               State.do_update_config([default_llm_max_concurrency: 5], state2)

      assert final.default_llm_max_concurrency == 5
      assert final.model_concurrency[@default_model] == 5
      assert MapSet.member?(State.holders_for(final, @default_model), 3)
      assert_received {^ref, :ok}
    end

    test "grants queued waiter when only the fallback default exists (no profiles)" do
      ref = make_ref()
      from = {self(), ref}
      put_meta(3, 0)

      state =
        State.from_model_profiles([], default_llm_max_concurrency: 2)
        |> State.update_holders(@default_model, MapSet.new([1, 2]))

      # Capacity = fallback default 2, holders full -> queued.
      assert {:noreply, state2, [{3, :blocked}]} = Slots.handle_request_llm_slot(3, from, state)

      # Fallback raised 2 -> 5 -> the queued waiter is granted.
      assert {:reply, :ok, final} =
               State.do_update_config([default_llm_max_concurrency: 5], state2)

      assert final.default_llm_max_concurrency == 5
      assert MapSet.member?(State.holders_for(final, @default_model), 3)
      assert_received {^ref, :ok}
    end

    test "max_tool_concurrency increase grants queued tool waiters" do
      ref = make_ref()
      from = {self(), ref}

      state = %{
        State.from_model_profiles([], max_tool_concurrency: 2)
        | tool_holders: MapSet.new([1, 2])
      }

      assert {:noreply, state2, [{3, :blocked}]} = Slots.handle_request_tool_slot(3, from, state)

      assert {:reply, :ok, final} = State.do_update_config([max_tool_concurrency: 4], state2)

      assert final.max_tool_concurrency == 4
      assert MapSet.member?(final.tool_holders, 3)
      assert_received {^ref, :ok}
    end
  end
end
