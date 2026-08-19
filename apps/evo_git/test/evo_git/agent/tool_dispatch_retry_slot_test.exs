defmodule EvoGit.Agent.ToolDispatchRetrySlotTest do
  @moduledoc """
  Pins per-attempt LLM slot acquisition in `EvoGit.Agent.ToolDispatch.call_llm_with_retry/5`:
  the scheduler's LLM slot is released between retry attempts (during the
  exponential-backoff sleep), so a retrying agent does not hold its slot for the
  whole retry sequence and `AgentScheduler.pause/0` takes effect at the next slot
  re-acquisition.

  `async: false` — touches the global `EvoGit.AgentScheduler` GenServer (config
  update, pause/resume) and the shared scheduler ETS tables.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  # A model spec whose base_url points at a closed loopback port (1). ReqLLM
  # fails fast with a connection-refused transport error, so the OUTER retry loop
  # is exercised without a live LLM endpoint. There is no mocking library
  # (Mox/Meck) in this codebase and ReqLLM's VCR fixture backend is not shipped
  # (see the note in context_compression_test.exs).
  # A dummy api_key is required so ReqLLM's OpenAI provider gets past the
  # request-build phase — without it the failure is a build-phase error
  # (:provider_build_failed), not the connection-refused transport error
  # (:http_streaming_failed) the retry loop expects to see. The key is never
  # sent to the server because the connection is refused before any request.
  defp refused_model do
    %{provider: :openai, id: "test-refused", base_url: "http://127.0.0.1:1", api_key: "test-key"}
  end

  # The FIRST stream_text to a fresh Finch destination creates the connection
  # pool (~1.7s); subsequent calls to the same destination fail in ~1-2ms. Warm
  # the pool so each retry attempt fails in milliseconds, making the retry-sleep
  # windows deterministic for the assertions below.
  #
  # stream_text/3 returns {:ok, stream_resp} once the provider build phase
  # succeeds (the API key is resolved); the actual transport failure surfaces
  # later in process_stream/1 as {:error, ...}. We only need the pool warmed, so
  # the process_stream result is discarded.
  defp warm_pool do
    case ReqLLM.stream_text(refused_model(), ReqLLM.Context.new(), []) do
      {:ok, stream_resp} ->
        _ = ReqLLM.StreamResponse.process_stream(stream_resp)
        :ok

      {:error, _reason} ->
        # Build-phase failure (e.g. missing API key from a polluted env): the
        # pool is not warmed, but build-phase errors are also instantaneous, so
        # the retry timing assertions still hold without a warm pool.
        :ok
    end
  end

  # Registers a fake agent in the scheduler ETS with the connection-refused model.
  # Only the agent-state table is needed (ToolDispatch.current_model/0 reads
  # llm_model; slot resolution reads model_id) — no sched-meta entry is required.
  defp register_agent(agent_id) do
    state = %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/genesis-retry-slot-test"},
      llm_model: refused_model(),
      max_retries: 2,
      max_depth: 1,
      model_id: "default"
    }

    Store.put_agent_state(agent_id, state)
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
  end

  # Runs call_llm_with_retry in a separate process with the agent's process-dict
  # key set (ToolDispatch.current_model/0 reads AgentScheduler.current_agent_id()).
  defp start_retrying_agent(agent_id, max_retries) do
    Task.async(fn ->
      Process.put(:evogit_agent_id, agent_id)
      ToolDispatch.call_llm_with_retry(ReqLLM.Context.new(), [], [], agent_id, max_retries)
    end)
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"

    # Ensure a clean, unpaused scheduler regardless of prior tests (resume/1 is
    # a no-op when not paused).
    AgentScheduler.resume()

    # Pin a test API key in the ReqLLM application env so the refused_model's
    # OpenAI provider requests clear the build phase (ReqLLM.Keys resolution)
    # and reach the transport layer where they fail fast with connection-refused.
    # Without this, a prior test that deletes :openai_api_key (e.g.
    # config_test's credential cleanup) leaves the env empty, causing a
    # provider-build failure that changes the error shape and crashes warm_pool/0.
    original_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    original_profiles = AgentScheduler.get_config(:model_profiles)

    # Single-slot "default" pool: while the retrying agent holds the slot NO other
    # agent can be granted — makes the between-retries release observable.
    AgentScheduler.update_config(
      model_profiles: [%{id: "default", model: "test:model", concurrency: 1}]
    )

    warm_pool()

    on_exit(fn ->
      AgentScheduler.resume()
      AgentScheduler.update_config(model_profiles: original_profiles)

      if original_api_key do
        Application.put_env(:req_llm, :openai_api_key, original_api_key)
      else
        Application.delete_env(:req_llm, :openai_api_key)
      end
    end)

    :ok
  end

  test "releases the LLM slot between retry attempts so another agent can acquire it" do
    agent_id = 101
    register_agent(agent_id)

    retrying = start_retrying_agent(agent_id, 2)

    # Give the first attempt time to fail (connection refused, ~ms after the pool
    # warm-up) and enter the ~1s exponential-backoff sleep.
    Process.sleep(150)

    # While the retrying agent sleeps between attempts, a second agent must be
    # able to acquire the model's only LLM slot. If the slot were held for the
    # whole retry sequence (old behavior) this request would block past its
    # 500ms timeout.
    probe =
      Task.async(fn ->
        AgentScheduler.request_llm_slot(2, 500)
      end)

    assert Task.await(probe, 2_000) == :ok

    # Release the probe's slot so the retrying agent can proceed with its next
    # attempt once its sleep ends.
    AgentScheduler.release_llm_slot(2)

    # All retries exhaust (connection refused is not a rate limit), returning
    # {:error, reason} — the caller (prompt_until_tools_or_limit/5) raises on this.
    assert {:error, _reason} = Task.await(retrying, 15_000)
  end

  test "a paused scheduler blocks the retrying agent's next attempt at slot re-acquisition" do
    agent_id = 102
    register_agent(agent_id)

    # max_retries = 1 → two attempts total: first attempt, ~1s sleep, final
    # attempt. Without the fix (slot held across the whole sequence) the task
    # finishes in ~1s regardless of pause.
    retrying = start_retrying_agent(agent_id, 1)

    # Let the first attempt fail fast and enter the ~1s backoff sleep, then pause.
    Process.sleep(150)
    AgentScheduler.pause()
    assert AgentScheduler.paused?()

    # After the first sleep elapses, the agent's next attempt blocks on slot
    # re-acquisition (queued as :blocked) instead of retrying. The task must
    # still be alive well past the point where the un-paused retry would finish.
    assert Task.yield(retrying, 1_500) == nil

    # Resume: the blocked slot request is granted and the retry stream exhausts.
    AgentScheduler.resume()
    refute AgentScheduler.paused?()
    assert {:error, _reason} = Task.await(retrying, 10_000)
  end

  test "0-capacity model blocks at slot acquisition until capacity is restored" do
    agent_id = 103
    register_agent(agent_id)

    # The live (old) PeakHourEngine re-applies a FLOORED model_concurrency map
    # on every "scheduler_config" broadcast, which would asynchronously
    # resurrect the hard-pause 0 back to the default. Suspend it so the
    # 0-capacity request path below is deterministic (the pure-function
    # floor-preservation semantics are pinned in state_test.exs).
    engine = Process.whereis(EvoGit.PeakHourEngine)
    if engine, do: :sys.suspend(engine)
    on_exit(fn -> if engine, do: :sys.resume(engine) end)

    # PeakHourEngine-style hard-pause: the dynamic map drops "default" to 0.
    # The scheduler's floor must keep the explicit 0 (never resurrect it).
    assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})

    task = start_retrying_agent(agent_id, 3)

    try do
      # A 0-capacity slot request is ENQUEUED (blocking-like-paused), not
      # rejected: the task blocks at slot acquisition instead of raising the
      # old "0 LLM slots" error, and no retry has run yet (Task.yield returns
      # nil because the task is still alive, not finished).
      assert Task.yield(task, 500) == nil

      # Restore capacity: the end-of-update grant_pending_on_resume sweep
      # grants the queued slot request and the retry sequence runs against the
      # connection-refused model.
      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 1})

      # The retries exhaust (connection refused is not a rate limit) with
      # {:error, reason} — NOT a raise, and the reason carries no trace of the
      # old fail-fast "0 LLM slots" message.
      assert {:error, reason} = Task.await(task, 15_000)
      refute Exception.message(reason) =~ "0 LLM slots"
    after
      # Failure-proof cleanup: a failed assertion above can leave the task
      # blocked on the 0-capacity slot with an :infinity GenServer.call.
      # Restore capacity (grants the queued waiter), terminate the task, and
      # release any slot it may hold — no orphaned blocked process (or leaked
      # holder) may survive into sibling tests, where a later update_config
      # would otherwise grant the orphan and let it hog the single "default"
      # slot.
      AgentScheduler.update_config(model_concurrency: %{"default" => 1})
      Task.shutdown(task, :brutal_kill)
      AgentScheduler.release_llm_slot(agent_id)
    end
  end
end
