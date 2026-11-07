defmodule EvoGit.AgentScheduler.ProviderPoolRegressionTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.{Dispatch, Slots, State, Store}
  alias EvoGit.AgentSpec
  alias EvoGit.TestSupport.ConfigDir

  # Pure state/slot handlers with real registered, uniquely keyed ETS bindings.
  # No global scheduler, env mutation, wall-clock waits or LLM requests.
  setup do
    ConfigDir.isolate!("provider-pool-regression")
    state = State.from_config(config())

    state = %{
      state
      | next_agent_id: 1_000_000_000 + System.unique_integer([:positive, :monotonic]) * 100
    }

    {a, state} = register(state, "account-a", "o3-mini", "low")
    {b, state} = register(state, "account-a", "o3", "high")
    {c, state} = register(state, "account-b", "o3", "high")
    {d, state} = register(state, "account-a", "o3-mini", "high")
    %{state: state, a: a, b: b, c: c, d: d}
  end

  defp config do
    provider = %{
      id: "account-a",
      provider: "openai",
      concurrency: 1,
      default_model: "o3-mini",
      reasoning_efforts: ["low", "high"],
      default_reasoning_effort: "low",
      models: [
        %{model: "o3-mini", context_window: 100_000},
        %{model: "o3", context_window: 150_000}
      ]
    }

    %{
      scheduler: %{default_llm_max_concurrency: 1},
      llm: %{
        default_provider_profile: "account-b",
        providers: [provider, %{provider | id: "account-b"}]
      }
    }
  end

  defp register(state, provider, model, effort) do
    id = state.next_agent_id

    selection = %{
      "provider_profile_id" => provider,
      "model" => model,
      "reasoning_effort" => effort
    }

    spec = %AgentSpec{
      context_node: nil,
      phylo_node: EvoGit.Core.PhyloGraphNode.new(File.cwd!()),
      agent_module: EvoGit.Agents.Executor,
      objective: "shared provider slots",
      model_spec: selection
    }

    on_exit(fn ->
      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
    end)

    assert {^id, state} = Dispatch.register_agent(state, spec, nil, nil, 0, "provider-pools", 1)
    {id, state}
  end

  defp from, do: {self(), make_ref()}

  defp grant(state, id) do
    assert {:reply, :ok, state, []} = Slots.handle_request_llm_slot(id, from(), state)
    state
  end

  defp enqueue(state, id) do
    {_, ref} = from = from()
    assert {:noreply, state, [{^id, :blocked}]} = Slots.handle_request_llm_slot(id, from, state)
    {state, ref}
  end

  defp expire_backoff(state, pool) do
    # Move both the account deadline and its queued copies into the past;
    # drive the real retry handler synchronously, never sleep for a backoff.
    past = System.monotonic_time(:millisecond) - 1
    waiting = State.waiting_for(state, pool) |> :queue.to_list()
    waiting = :queue.from_list(Enum.map(waiting, fn {id, from, _} -> {id, from, past} end))
    state |> State.update_backoff(pool, past) |> State.update_waiting(pool, waiting)
  end

  test "different models and efforts share one account capacity and release queue", %{
    state: state,
    a: a,
    b: b
  } do
    assert Slots.resolve_model_id(a, state) == "account-a"
    assert Slots.resolve_model_id(b, state) == "account-a"
    assert {:ok, first} = Store.get_agent_state(a)
    assert {:ok, second} = Store.get_agent_state(b)
    assert first.llm_model == "openai:o3-mini"
    assert second.llm_model == "openai:o3"
    assert first.model_spec["reasoning_effort"] == "low"
    assert second.model_spec["reasoning_effort"] == "high"
    assert first.llm_generation_params[:reasoning_effort] == :low
    assert second.llm_generation_params[:reasoning_effort] == :high
    assert first.llm_context_window == 100_000
    assert second.llm_context_window == 150_000
    assert first.model_id == nil
    assert second.model_id == nil

    state = grant(state, a)
    {state, ref} = enqueue(state, b)
    assert State.holders_for(state, "account-a") == MapSet.new([a])
    assert [{^b, {_, ^ref}, nil}] = :queue.to_list(State.waiting_for(state, "account-a"))
    assert Map.keys(state.llm_holders) |> Enum.sort() == ["account-a", "account-b"]
    refute_received {^ref, :ok}
    {state, [{^b, :running}]} = Slots.handle_release_llm_slot(a, state)
    assert_received {^ref, :ok}
    assert State.holders_for(state, "account-a") == MapSet.new([b])
    assert :queue.is_empty(State.waiting_for(state, "account-a"))
    assert Map.has_key?(State.last_granted_for(state, "account-a"), b)
    refute_received {^ref, :ok}
  end

  test "two efforts on the same model cannot double an account's capacity", %{
    state: state,
    a: a,
    d: d
  } do
    state = grant(state, a)
    {state, ref} = enqueue(state, d)
    {state, [{^d, :running}]} = Slots.handle_release_llm_slot(a, state)
    assert_received {^ref, :ok}
    assert State.holders_for(state, "account-a") == MapSet.new([d])
  end

  test "accounts on the same provider and same concrete model have independent slots", %{
    state: state,
    b: b,
    c: c
  } do
    state = state |> grant(b) |> grant(c)
    assert State.holders_for(state, "account-a") == MapSet.new([b])
    assert State.holders_for(state, "account-b") == MapSet.new([c])
    assert state.model_concurrency == %{"account-a" => 1, "account-b" => 1}
    {released, []} = Slots.handle_release_llm_slot(b, state)
    assert State.holders_for(released, "account-b") == MapSet.new([c])
  end

  for error <- [:rate_limit, :insufficient_balance, :model_exhaustion] do
    test "#{error} backs off all models/efforts in only the reporting account", %{
      state: state,
      a: a,
      b: b,
      c: c,
      d: d
    } do
      state = grant(state, a)
      {state, b_ref} = enqueue(state, b)
      before = System.monotonic_time(:millisecond)

      assert {:reply, :ok, state, []} =
               Slots.handle_report_llm_error(a, unquote(error), 60_000, state)

      deadline = State.backoff_for(state, "account-a")
      assert deadline >= before + 60_000
      assert deadline <= System.monotonic_time(:millisecond) + 60_000
      assert State.backoff_for(state, "account-b") == nil

      assert [{^b, {_, ^b_ref}, ^deadline}] =
               :queue.to_list(State.waiting_for(state, "account-a"))

      {state, d_ref} = enqueue(state, d)

      assert Enum.all?(:queue.to_list(State.waiting_for(state, "account-a")), fn {_, _, backoff} ->
               backoff == deadline
             end)

      state = grant(state, c)
      {state, []} = Slots.handle_release_llm_slot(a, state)
      assert State.holders_for(state, "account-a") == MapSet.new()
      refute_received {^b_ref, :ok}
      refute_received {^d_ref, :ok}
      assert State.holders_for(state, "account-b") == MapSet.new([c])

      assert {:noreply, state, [{^b, :running}]} =
               state |> expire_backoff("account-a") |> Slots.handle_retry_llm_waiting()

      assert_received {^b_ref, :ok}
      refute_received {^d_ref, :ok}
      assert State.backoff_for(state, "account-a") == nil
      assert State.holders_for(state, "account-b") == MapSet.new([c])
      {state, [{^d, :running}]} = Slots.handle_release_llm_slot(b, state)
      assert_received {^d_ref, :ok}
      assert State.holders_for(state, "account-a") == MapSet.new([d])
    end
  end

  test "releasing a holder while globally paused does not grant another model", %{
    state: state,
    a: a,
    b: b
  } do
    state = grant(state, a)
    {state, ref} = enqueue(%{state | paused: true}, b)
    {state, updates} = Slots.handle_release_llm_slot(a, state)
    assert updates == []
    assert State.holders_for(state, "account-a") == MapSet.new()
    assert [{^b, {_, ^ref}, nil}] = :queue.to_list(State.waiting_for(state, "account-a"))
    refute_received {^ref, :ok}
    {state, [{^b, :running}]} = Slots.grant_pending_on_resume(%{state | paused: false})
    assert_received {^ref, :ok}
    assert State.holders_for(state, "account-a") == MapSet.new([b])
  end

  test "raising an account floor while globally paused preserves queued calls until resume", %{
    state: state,
    a: a,
    b: b
  } do
    state = grant(state, a)
    {state, ref} = enqueue(%{state | paused: true}, b)
    assert {:reply, :ok, state} = State.do_update_config([default_llm_max_concurrency: 2], state)
    assert state.paused
    assert state.model_concurrency == %{"account-a" => 2, "account-b" => 2}
    assert State.holders_for(state, "account-a") == MapSet.new([a])
    assert [{^b, {_, ^ref}, nil}] = :queue.to_list(State.waiting_for(state, "account-a"))
    refute_received {^ref, :ok}
    {state, [{^b, :running}]} = Slots.grant_pending_on_resume(%{state | paused: false})
    assert_received {^ref, :ok}
    assert State.holders_for(state, "account-a") == MapSet.new([a, b])
  end

  test "an expired account backoff does not bypass global pause", %{state: state, a: a, b: b} do
    {:reply, :ok, state, []} = Slots.handle_report_llm_error(a, :rate_limit, 60_000, state)
    {state, ref} = enqueue(%{state | paused: true}, b)

    assert {:noreply, state, updates} =
             state |> expire_backoff("account-a") |> Slots.handle_retry_llm_waiting()

    assert updates == []
    assert State.holders_for(state, "account-a") == MapSet.new()
    refute_received {^ref, :ok}
    {state, [{^b, :running}]} = Slots.grant_pending_on_resume(%{state | paused: false})
    assert_received {^ref, :ok}
    assert State.holders_for(state, "account-a") == MapSet.new([b])
  end

  test "ordinary errors are exact no-ops for every account", %{state: state, a: a} do
    for error <- [:timeout, :transport, :invalid_request] do
      assert Slots.handle_report_llm_error(a, error, 60_000, state) == {:reply, :ok, state, []}
    end
  end

  test "immutable provider binding wins over a conflicting legacy model id", %{state: state, a: a} do
    assert {:ok, binding} = Store.get_agent_state(a)
    Store.put_agent_state(a, %{binding | model_id: "account-b"})
    assert Slots.resolve_model_id(a, state) == "account-a"
    state = grant(state, a)
    assert State.holders_for(state, "account-a") == MapSet.new([a])
    assert State.holders_for(state, "account-b") == MapSet.new()
  end

  test "legacy selection aliases route to account pools; missing rows use configured default", %{
    state: state,
    a: a
  } do
    alias_profile = %{id: "legacy-fast", provider_profile_id: "account-a", model: "openai:o3"}
    state = %{state | model_profiles: [alias_profile | state.model_profiles]}
    assert {:ok, binding} = Store.get_agent_state(a)
    Store.put_agent_state(a, %{binding | provider_profile_id: nil, model_id: "legacy-fast"})
    assert State.pool_id(state, "legacy-fast") == "account-a"
    assert Slots.resolve_model_id(a, state) == "account-a"
    Store.delete_agent_state(a)
    assert Slots.resolve_model_id(a, state) == "account-b"
    assert State.default_pool_id(state) == "account-b"
  end

  test "release after ETS removal still frees the original account and grants a different model",
       %{state: state, a: a, b: b} do
    state = grant(state, a)
    {state, ref} = enqueue(state, b)
    Store.delete_agent_state(a)
    {state, [{^b, :running}]} = Slots.handle_release_llm_slot(a, state)
    assert_received {^ref, :ok}
    assert State.holders_for(state, "account-a") == MapSet.new([b])
    assert State.last_granted_for(state, "account-a")[a] == nil
    assert Slots.handle_release_llm_slot(a, state) == {state, []}
    refute_received {^ref, :ok}
  end

  test "death purges an account waiter exactly once without disturbing another account", %{
    state: state,
    a: a,
    b: b,
    c: c
  } do
    state = state |> grant(a) |> grant(c)
    {state, ref} = enqueue(state, b)
    {state, []} = Slots.release_agent_slots(state, b)
    assert_received {^ref, {:error, :cancelled}}
    assert State.holders_for(state, "account-a") == MapSet.new([a])
    assert State.holders_for(state, "account-b") == MapSet.new([c])
    assert :queue.is_empty(State.waiting_for(state, "account-a"))
    assert Slots.release_agent_slots(state, b) == {state, []}
    refute_received {^ref, _}
  end

  test "canonical reload preserves one live account pool, queued reply, backoff and recency", %{
    state: state,
    a: a,
    b: b,
    c: c
  } do
    state = grant(state, a)
    {state, ref} = enqueue(state, b)
    {:reply, :ok, state, []} = Slots.handle_report_llm_error(a, :rate_limit, 60_000, state)
    deadline = State.backoff_for(state, "account-a")
    recency = State.last_granted_for(state, "account-a")
    opts = EvoGit.AgentScheduler.ModelSelection.config_opts(config())
    assert {:reply, :ok, reloaded} = State.do_update_config(opts, state)
    assert reloaded.model_concurrency == %{"account-a" => 1, "account-b" => 1}
    assert State.holders_for(reloaded, "account-a") == MapSet.new([a])
    assert State.backoff_for(reloaded, "account-a") == deadline
    assert State.last_granted_for(reloaded, "account-a") == recency
    assert [{^b, {_, ^ref}, ^deadline}] = :queue.to_list(State.waiting_for(reloaded, "account-a"))
    refute_received {^ref, :ok}
    reloaded = grant(reloaded, c)
    {reloaded, []} = Slots.handle_release_llm_slot(a, reloaded)

    {:noreply, reloaded, [{^b, :running}]} =
      reloaded |> expire_backoff("account-a") |> Slots.handle_retry_llm_waiting()

    assert_received {^ref, :ok}
    assert State.holders_for(reloaded, "account-a") == MapSet.new([b])
  end

  test "removed account with live work remains releasable instead of losing queued callers", %{
    state: state,
    a: a,
    b: b,
    c: c
  } do
    state = state |> grant(a) |> grant(c)
    {state, ref} = enqueue(state, b)
    config = config()
    kept = Enum.filter(config.llm.providers, &(&1.id == "account-b"))
    config = put_in(config, [:llm, :providers], kept)
    opts = EvoGit.AgentScheduler.ModelSelection.config_opts(config)
    assert {:reply, :ok, reloaded} = State.do_update_config(opts, state)
    refute Map.has_key?(reloaded.model_concurrency, "account-a")
    assert "account-a" in State.all_model_ids(reloaded)
    assert State.holders_for(reloaded, "account-a") == MapSet.new([a])
    refute_received {^ref, :ok}
    {reloaded, [{^b, :running}]} = Slots.handle_release_llm_slot(a, reloaded)
    assert_received {^ref, :ok}
    assert State.holders_for(reloaded, "account-a") == MapSet.new([b])
    assert State.holders_for(reloaded, "account-b") == MapSet.new([c])
  end
end
