defmodule EvoGit.ReqLLMPoolTest do
  use ExUnit.Case, async: false

  alias EvoGit.ReqLLMPool

  # A tiny standalone Finch (NOT ReqLLM.Finch) so we can exercise the real
  # materialization / set_pool_count path against a live pool without touching
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
    test "sums map values for a non-empty map" do
      assert ReqLLMPool.effective_concurrency(%{"a" => 3, "b" => 4}, 99) == 7
    end

    test "falls back to default_concurrency for an empty map" do
      assert ReqLLMPool.effective_concurrency(%{}, 5) == 5
    end

    test "falls back to default_concurrency for nil" do
      assert ReqLLMPool.effective_concurrency(nil, 5) == 5
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
