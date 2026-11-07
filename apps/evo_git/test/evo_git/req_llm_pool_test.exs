defmodule EvoGit.ReqLLMPoolTest do
  # async: true — this module never touches BEAM-global state: no
  # Application.put_env / System.put_env / :persistent_term, and it drives
  # ReqLLMPool against a PRIVATE standalone Finch (`TestReqLLMPoolFinch` /
  # `FreshTestFinch`, names used nowhere else) instead of the production
  # `ReqLLM.Finch`. The only "network" is a connect-refused request to
  # 127.0.0.1:1 (loopback, no traffic).
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.State
  alias EvoGit.ReqLLMPool

  # A tiny standalone Finch (NOT ReqLLM.Finch) so we can exercise the real  # materialization / set_pool_count path against a live pool without touching
  # the production pool. `start_pool_metrics?: true` is REQUIRED for
  # `Finch.get_pool_status(finch_name, :default)` to enumerate materialized
  # origins (see deps/finch/lib/finch/pool/manager.ex `track_default?`).
  @test_finch TestReqLLMPoolFinch
  @fresh_finch FreshTestFinch

  describe "desired_count/1" do
    test "mirrors config/runtime.exs formula with a floor of 8" do
      assert ReqLLMPool.desired_count(1) == 8
      assert ReqLLMPool.desired_count(10) == 12
      assert ReqLLMPool.desired_count(0) == 8
      assert ReqLLMPool.desired_count(100) == 102
    end
  end

  describe "error_target_count/1" do
    test "targets up to 1.5x the LLM concurrency with a floor of 8" do
      assert ReqLLMPool.error_target_count(1) == 8
      assert ReqLLMPool.error_target_count(10) == 15
      assert ReqLLMPool.error_target_count(4) == 8
      assert ReqLLMPool.error_target_count(0) == 8
      assert ReqLLMPool.error_target_count(100) == 150
    end
  end

  describe "effective_concurrency/2" do
    test "sum > default: returns the sum of map values" do
      assert ReqLLMPool.effective_concurrency(%{"a" => 5, "b" => 3}, 2) == 8
      assert ReqLLMPool.effective_concurrency(%{"a" => 3, "b" => 4}, 2) == 7
    end

    test "default > sum: returns the default_concurrency" do
      assert ReqLLMPool.effective_concurrency(%{"a" => 3}, 8) == 8
      assert ReqLLMPool.effective_concurrency(%{"a" => 3, "b" => 4}, 99) == 99
    end

    test "sum == default: returns that value" do
      assert ReqLLMPool.effective_concurrency(%{"a" => 4}, 4) == 4
    end

    test "falls back to default_concurrency for an empty map" do
      assert ReqLLMPool.effective_concurrency(%{}, 5) == 5
    end

    test "falls back to default_concurrency for nil" do
      assert ReqLLMPool.effective_concurrency(nil, 5) == 5
    end
  end

  describe "canonical provider-account sizing" do
    test "counts shared-provider accounts once each, not their nested model inventory" do
      config = account_config()
      state = State.from_config(config)

      # Both credentials use the same provider and model names, but have
      # independent slot budgets; models within each account share that budget.
      assert length(state.model_profiles) == 4
      assert state.model_concurrency == %{"team" => 7, "personal" => 5}
      total = ReqLLMPool.effective_concurrency(state.model_concurrency, 3)
      assert total == 12
      assert ReqLLMPool.desired_count(total) == 14
      assert ReqLLMPool.error_target_count(total) == 18

      expanded =
        update_in(config, [:llm, :providers], fn providers ->
          Enum.map(providers, fn account ->
            update_in(account, [:models], &(&1 ++ [%{model: "gpt-4.1-nano"}]))
          end)
        end)

      expanded_state = State.from_config(expanded)
      assert length(expanded_state.model_profiles) == 6
      assert expanded_state.model_concurrency == state.model_concurrency
      assert ReqLLMPool.effective_concurrency(expanded_state.model_concurrency, 3) == total
    end

    test "paused accounts add no demand while the auxiliary-call default remains a floor" do
      config =
        update_in(account_config(), [:llm, :providers], fn [team, personal] ->
          [%{team | concurrency: 0}, %{personal | concurrency: 7}]
        end)

      state = State.from_config(config)
      assert state.model_concurrency == %{"team" => 0, "personal" => 7}
      assert ReqLLMPool.effective_concurrency(state.model_concurrency, 3) == 7

      paused =
        update_in(config, [:llm, :providers], fn providers ->
          Enum.map(providers, &%{&1 | concurrency: 0})
        end)

      paused_state = State.from_config(paused)
      assert paused_state.model_concurrency == %{"team" => 0, "personal" => 0}
      total = ReqLLMPool.effective_concurrency(paused_state.model_concurrency, 3)
      assert total == 3
      assert ReqLLMPool.desired_count(total) == 8
    end
  end

  describe "excess_queuing_error?/1" do
    test "matches the bare Finch RuntimeError" do
      error =
        RuntimeError.exception(
          message:
            "Finch was unable to provide a connection within the timeout due to excess queuing for connections. Consider adjusting the pool size, count, timeout or reducing the rate of requests."
        )

      assert ReqLLMPool.excess_queuing_error?(error)
    end

    test "matches a ReqLLM stream error wrapping the Finch error in its cause" do
      inner =
        RuntimeError.exception(
          message:
            "Finch was unable to provide a connection within the timeout due to excess queuing for connections."
        )

      error = %ReqLLM.Error.API.Stream{reason: "Stream failed", cause: {:error, inner}}
      assert ReqLLMPool.excess_queuing_error?(error)
    end

    test "matches a ReqLLM stream error whose reason string carries the marker" do
      error = %ReqLLM.Error.API.Stream{
        reason:
          "Stream failed: {:error, %RuntimeError{message: \"unable to provide a connection\"}}",
        cause: nil
      }

      assert ReqLLMPool.excess_queuing_error?(error)
    end

    test "rejects unrelated errors" do
      refute ReqLLMPool.excess_queuing_error?({:error, %RuntimeError{message: "other"}})
      refute ReqLLMPool.excess_queuing_error?(%RuntimeError{message: "some other failure"})

      refute ReqLLMPool.excess_queuing_error?(%ReqLLM.Error.API.Stream{
               cause: {:error, %RuntimeError{message: "other"}}
             })

      refute ReqLLMPool.excess_queuing_error?("429 Too Many Requests: rate_limit exceeded")
      refute ReqLLMPool.excess_queuing_error?({:error, :rate_limit})
      refute ReqLLMPool.excess_queuing_error?(:econnrefused)
      refute ReqLLMPool.excess_queuing_error?({:error, :econnrefused})
      refute ReqLLMPool.excess_queuing_error?("plain string")
      refute ReqLLMPool.excess_queuing_error?(nil)
    end
  end

  describe "reconcile/2 against a real Finch" do
    setup :start_test_finch

    test "canonical shared-provider account budgets size the private pool, not model count" do
      materialize_origin!()
      state = State.from_config(account_config())
      total = ReqLLMPool.effective_concurrency(state.model_concurrency, 3)
      assert total == 12

      assert :ok = ReqLLMPool.reconcile(total, @test_finch)
      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_origin, metrics}] = Map.to_list(pools)
      assert length(metrics) == 14

      assert :ok = ReqLLMPool.bump_for_excess_queuing(state.model_concurrency, 3, @test_finch)
      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_origin, metrics}] = Map.to_list(pools)
      assert length(metrics) == 18

      # Peak pause reduces slot demand, but must never shrink active HTTP pools.
      assert :ok =
               ReqLLMPool.bump_for_excess_queuing(%{"team" => 0, "personal" => 0}, 3, @test_finch)

      assert :ok = ReqLLMPool.reconcile(3, @test_finch)
      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_origin, metrics}] = Map.to_list(pools)
      assert length(metrics) == 18
    end

    test "grows a materialized origin's pool to the desired count" do
      materialize_origin!()

      # Freshly materialized: the failed request started the pool with count 2.
      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      assert map_size(pools) == 1
      [{_pool_id, metrics}] = Map.to_list(pools)
      assert length(metrics) == 2

      # reconcile(10, ...) → desired 12 → grows 2 → 12.
      assert :ok = ReqLLMPool.reconcile(10, @test_finch)

      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_pool_id, metrics}] = Map.to_list(pools)
      assert length(metrics) == 12
    end

    test "is grow-only: never shrinks a pool below its current count" do
      materialize_origin!()

      assert :ok = ReqLLMPool.reconcile(10, @test_finch)
      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_pool_id, metrics}] = Map.to_list(pools)
      assert length(metrics) == 12

      # reconcile(1, ...) → desired 8 < current 12 → untouched.
      assert :ok = ReqLLMPool.reconcile(1, @test_finch)

      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_pool_id, metrics}] = Map.to_list(pools)
      assert length(metrics) == 12
    end

    test "is a no-op before any origin is materialized (:not_found grace)" do
      {:ok, _pid} = start_finch(@fresh_finch)

      assert :ok = ReqLLMPool.reconcile(10, @fresh_finch)
      assert {:error, :not_found} = Finch.get_pool_status(@fresh_finch, :default)
    end

    test "is a no-op (never raises) when the Finch instance is not running" do
      # get_pool_status/2 raises ArgumentError for a missing registry, so the
      # module guards on Process.whereis — honor the never-raise contract even
      # for callers that may run before :req_llm boots (e.g. scheduler init).
      assert :ok = ReqLLMPool.reconcile(10, :NoSuchReqLLMPoolTestFinch)

      assert :ok =
               ReqLLMPool.bump_for_excess_queuing(
                 %{"default" => 4},
                 4,
                 :NoSuchReqLLMPoolTestFinch
               )
    end
  end

  describe "bump_for_excess_queuing/3 against a real Finch" do
    setup :start_test_finch

    test "grows to the 1.5x error target and never shrinks" do
      materialize_origin!()

      # effective = 4 → error_target_count(4) = max(ceil(6), 8) = 8.
      assert :ok = ReqLLMPool.bump_for_excess_queuing(%{"default" => 4}, 4, @test_finch)

      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_pool_id, metrics}] = Map.to_list(pools)
      assert length(metrics) == 8

      # effective = 2 → error_target_count(2) = 8 → 8 not < 8 → unchanged.
      assert :ok =
               ReqLLMPool.bump_for_excess_queuing(%{"default" => 1, "other" => 1}, 2, @test_finch)

      assert {:ok, pools} = Finch.get_pool_status(@test_finch, :default)
      [{_pool_id, metrics}] = Map.to_list(pools)
      assert length(metrics) == 8
    end
  end

  # --- Helpers ---

  defp account_config do
    %{
      scheduler: %{default_llm_max_concurrency: 3},
      llm: %{
        default_provider_profile: "personal",
        providers:
          for {id, concurrency} <- [{"team", 7}, {"personal", 5}] do
            %{
              id: id,
              provider: "openai",
              auth_mode: "api_key",
              api_key_env_var: "REQ_LLM_POOL_TEST_UNUSED_KEY",
              concurrency: concurrency,
              temperature: 0.4,
              default_model: "gpt-4.1-mini",
              reasoning_efforts: ["low", "high"],
              default_reasoning_effort: "low",
              models: [
                %{model: "gpt-4.1", context_window: 64_000, temperature: 0.2},
                %{
                  model: "gpt-4.1-mini",
                  context_window: 32_000,
                  default_reasoning_effort: "high"
                }
              ]
            }
          end
      }
    }
  end

  # Starts the shared test Finch (unlinked from the test process so it survives
  # the test's `:shutdown` and can be stopped deterministically in on_exit).
  defp start_test_finch(_context) do
    {:ok, _pid} =
      start_finch(@test_finch, pools: %{default: [size: 1, count: 2, start_pool_metrics?: true]})

    :ok
  end

  defp start_finch(name, opts \\ []) do
    stop_finch(name)

    {:ok, pid} =
      case Finch.start_link([name: name] ++ opts) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, _old_pid}} ->
          # Stale instance left over from a crashed run; stop it and retry once.
          stop_finch(name)
          Finch.start_link([name: name] ++ opts)
      end

    # The test process exits with `:shutdown` after each test, which would take
    # the linked Finch down before on_exit can stop it cleanly. Unlink so the
    # instance persists until on_exit stops it explicitly.
    Process.unlink(pid)

    on_exit(fn -> stop_finch(name) end)
    {:ok, pid}
  end

  # Materializes the origin pool by issuing one request to a port that refuses
  # connections (127.0.0.1:1). Finch lazily creates the pool process (and its
  # metrics) on first request even when the connect fails.
  defp materialize_origin! do
    request = Finch.build(:get, "http://127.0.0.1:1/")
    assert {:error, _reason} = Finch.request(request, @test_finch)
    :ok
  end

  defp stop_finch(name) do
    case Process.whereis(:"#{name}.Supervisor") do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid)
        rescue
          _ -> :ok
        end
    end
  end
end
