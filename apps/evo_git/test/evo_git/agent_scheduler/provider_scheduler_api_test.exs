defmodule EvoGit.AgentScheduler.ProviderSchedulerAPITest do
  # Pins the app-global AgentScheduler state and drives its public APIs.
  # PeakHourEngine is suspended before pinning and resumed only after restore,
  # otherwise its asynchronous config wakeups overwrite the test's pool map.
  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{AgentState, ModelSelection, State, Store}
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("provider-scheduler-api")
    engine = Process.whereis(EvoGit.PeakHourEngine)
    :ok = :sys.suspend(engine)
    original = :sys.get_state(AgentScheduler)

    on_exit(fn ->
      :sys.replace_state(AgentScheduler, fn _ -> original end)
      :sys.resume(engine)
    end)

    config = config()
    state = State.from_config(config)
    :sys.replace_state(AgentScheduler, fn _ -> state end)

    base = 1_000_000_000 + System.unique_integer([:positive, :monotonic]) * 100
    [a, b, c, other] = ids = Enum.to_list(base..(base + 3))

    for {id, account, model, effort} <- [
          {a, "account-a", "o3-mini", "low"},
          {b, "account-a", "o3", "high"},
          {c, "account-a", "o3-mini", "high"},
          {other, "account-b", "o3", "high"}
        ] do
      Store.put_agent_state(id, %AgentState{
        context_node: nil,
        llm_model: "openai:#{model}",
        max_retries: 1,
        max_depth: 1,
        model_id: nil,
        provider_profile_id: account,
        model_spec: %{
          "provider_profile_id" => account,
          "model" => model,
          "reasoning_effort" => effort
        }
      })
    end

    on_exit(fn -> Enum.each(ids, &Store.delete_agent_state/1) end)
    %{config: config, a: a, b: b, c: c, other: other}
  end

  defp config do
    provider = %{
      id: "account-a",
      provider: "openai",
      concurrency: 1,
      default_model: "o3-mini",
      reasoning_efforts: ["low", "high"],
      default_reasoning_effort: "low",
      models: ["o3-mini", "o3"]
    }

    %{
      scheduler: %{default_llm_max_concurrency: 2},
      llm: %{
        default_provider_profile: "account-b",
        providers: [provider, %{provider | id: "account-b", concurrency: 4}]
      }
    }
  end

  defp request(id) do
    # A real GenServer request whose delayed reply remains in this process.
    # The following status/config API call is FIFO-ordered behind this request,
    # making refute_received structural rather than a timing/quiet-window test.
    ref = make_ref()
    send(AgentScheduler, {:"$gen_call", {self(), ref}, {:request_llm_slot, id}})
    ref
  end

  defp acquire(id) do
    ref = request(id)
    assert_receive {^ref, :ok}, 5000
    ref
  end

  test "public config/status APIs expose account capacities, not model or effort pools", %{
    config: config,
    a: a,
    b: b,
    other: other
  } do
    assert AgentScheduler.get_config(:provider_profiles) ==
             EvoGit.Config.Schema.provider_profiles(config)

    assert AgentScheduler.get_config(:model_profiles) ==
             EvoGit.Config.Schema.model_selections(config)

    # The selection snapshot is internal state, not a public get_config key.
    assert :sys.get_state(AgentScheduler).model_selection_config == config
    assert AgentScheduler.get_config(:model_concurrency) == %{"account-a" => 2, "account-b" => 4}
    acquire(a)
    acquire(b)
    acquire(other)

    assert AgentScheduler.get_llm_slot_status() == %{
             "account-a" => %{used: 2, waiting: 0, capacity: 2},
             "account-b" => %{used: 1, waiting: 0, capacity: 4}
           }

    assert AgentScheduler.get_config().provider_profiles ==
             EvoGit.Config.Schema.provider_profiles(config)
  end

  test "pause is idempotent and resume drains shared-account and separate-account requests", %{
    a: a,
    b: b,
    other: other
  } do
    acquire(a)
    assert :ok = AgentScheduler.pause()
    assert :ok = AgentScheduler.pause()
    assert AgentScheduler.paused?()
    b_ref = request(b)
    other_ref = request(other)

    assert AgentScheduler.get_llm_slot_status() == %{
             "account-a" => %{used: 1, waiting: 1, capacity: 2},
             "account-b" => %{used: 0, waiting: 1, capacity: 4}
           }

    refute_received {^b_ref, :ok}
    refute_received {^other_ref, :ok}
    assert :ok = AgentScheduler.resume()
    refute AgentScheduler.paused?()
    assert_received {^b_ref, :ok}
    assert_received {^other_ref, :ok}
    assert :ok = AgentScheduler.resume()
    refute_received {^b_ref, :ok}
    refute_received {^other_ref, :ok}

    assert AgentScheduler.get_llm_slot_status()["account-a"] == %{
             used: 2,
             waiting: 0,
             capacity: 2
           }
  end

  test "runtime floor immediately grants a shared account waiter and survives canonical reload",
       %{config: config, a: a, b: b, c: c} do
    acquire(a)
    acquire(b)
    ref = request(c)

    assert AgentScheduler.get_llm_slot_status()["account-a"] == %{
             used: 2,
             waiting: 1,
             capacity: 2
           }

    refute_received {^ref, :ok}
    assert :ok = AgentScheduler.update_config(default_llm_max_concurrency: 3)
    assert_received {^ref, :ok}
    assert AgentScheduler.get_config(:model_concurrency) == %{"account-a" => 3, "account-b" => 4}
    assert :ok = AgentScheduler.update_config(ModelSelection.config_opts(config))
    assert AgentScheduler.get_config(:default_llm_max_concurrency) == 3

    assert AgentScheduler.get_llm_slot_status() == %{
             "account-a" => %{used: 3, waiting: 0, capacity: 3},
             "account-b" => %{used: 0, waiting: 0, capacity: 4}
           }

    refute_received {^ref, :ok}
    assert :ok = AgentScheduler.update_config(default_llm_max_concurrency: 1)
    assert AgentScheduler.get_config(:model_concurrency) == %{"account-a" => 3, "account-b" => 4}
  end

  test "hard pause survives floors and scheduler resume without evicting a live holder", %{
    a: a,
    b: b,
    other: other
  } do
    acquire(a)

    assert :ok =
             AgentScheduler.update_config(
               model_concurrency: %{"account-a" => 0, "account-b" => 1}
             )

    ref = request(b)
    acquire(other)
    assert :ok = AgentScheduler.update_config(default_llm_max_concurrency: 5)

    assert AgentScheduler.get_llm_slot_status() == %{
             "account-a" => %{used: 1, waiting: 1, capacity: 0},
             "account-b" => %{used: 1, waiting: 0, capacity: 5}
           }

    refute_received {^ref, :ok}
    assert :ok = AgentScheduler.pause()
    assert :ok = AgentScheduler.resume()
    refute_received {^ref, :ok}

    assert :ok =
             AgentScheduler.update_config(
               model_concurrency: %{"account-a" => 1, "account-b" => 1}
             )

    assert_received {^ref, :ok}

    assert AgentScheduler.get_llm_slot_status()["account-a"] == %{
             used: 2,
             waiting: 0,
             capacity: 5
           }
  end

  test "engine map can bypass the floor while ordinary maps reapply it" do
    assert :ok = AgentScheduler.update_config(default_llm_max_concurrency: 6)
    map = %{"account-a" => 1, "account-b" => 0}

    assert :ok =
             AgentScheduler.update_config(
               model_concurrency: map,
               model_concurrency_skip_floor: true
             )

    assert AgentScheduler.get_config(:model_concurrency) == map
    assert AgentScheduler.get_config(:default_llm_max_concurrency) == 6
    assert :ok = AgentScheduler.update_config(model_concurrency: map)
    assert AgentScheduler.get_config(:model_concurrency) == %{"account-a" => 6, "account-b" => 0}
  end
end
