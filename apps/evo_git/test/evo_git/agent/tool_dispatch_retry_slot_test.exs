defmodule EvoGit.Agent.ToolDispatchRetrySlotTest do
  @moduledoc """
  Pins per-attempt LLM slot acquisition in `EvoGit.Agent.ToolDispatch.call_llm_with_retry/5`:
  the scheduler's LLM slot is released between retry attempts (during the
  exponential-backoff sleep), so a retrying agent does not hold its slot for the
  whole retry sequence and `AgentScheduler.pause/0` takes effect at the next slot
  re-acquisition.

  The production exponential-backoff sleeps (1s base) dominate this file's
  runtime, so the setup shrinks the CALL-TIME app-env seam
  `:llm_retry_backoff_base_ms` to `@retry_backoff_base_ms` and every wait below is
  a real scheduler condition (`AgentScheduler.get_llm_slot_status/0` / `paused?/0`)
  rather than a fixed sleep — see the synchronization notes above the constants.

  `async: false` — touches the global `EvoGit.AgentScheduler` GenServer (config
  update, pause/resume) and the shared scheduler ETS tables.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  # --- Retry/slot synchronization constants -------------------------------

  # Base (ms) of the production exponential-backoff between retry attempts,
  # overridden per test through the call-time app-env seam
  # `:llm_retry_backoff_base_ms` read by `ToolDispatch` at call time. 250ms is
  # chosen so that (a) the retry sequences that used to cost ~3s / ~1s / ~7s
  # collapse to ~0.75s / ~0.25s / ~1.75s, and (b) every backoff window stays far
  # longer than the ~10-30ms a connection-refused attempt needs against a warmed
  # Finch pool — and far longer than a scheduler round trip — so the
  # deterministic waits below (anchored on slot/queue STATE, never on the clock)
  # cannot race the window.
  @retry_backoff_base_ms 250

  # The model pool every retry test drives: a SINGLE-slot pool, pinned by the
  # setup (`model_profiles: [%{id: "default", ..., concurrency: 1}]`).
  @model_id "default"

  # Agent id the TEST process uses to hold that only slot. Holding it makes the
  # retrying agent's FIRST attempt provably QUEUED at slot acquisition — a
  # persistent state, so there is no short "hold window" to catch by polling —
  # and the release then grants that attempt inside the SAME scheduler state
  # transition (`Slots.handle_release_llm_slot/2` removes the holder and grants
  # the waiters together), so the first "slot free again" observation can only be
  # that attempt's OWN release. Together the two replace the old
  # `Process.sleep(150)`/"give the first attempt time to fail" guess with
  # certainty.
  @slot_owner_agent_id 99

  # Agent id of the second agent that probes whether the retrying agent's slot is
  # FREE between attempts (unchanged from the pre-optimization test).
  @probe_agent_id 2

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

  # Runs the given zero-arity fun in a fresh process with `:evogit_agent_id`
  # REMOVED from its process dictionary — current_model/0 and
  # current_generation_params/0 read AgentScheduler.current_agent_id() from the
  # calling process's dictionary, so assertions about the "not a scheduled
  # agent" path must run where that key is absent (and must not leak into the
  # test process of this async:false file).
  #
  # Both helpers catch (and re-report, never swallow) the raised exception —
  # a raise inside the Task's process escapes as an EXIT the caller can only
  # receive as a linked crash, so assert_raise cannot observe it directly.
  # Returns `{:ok, result}` or `{:raised, exception}`.
  defp in_unscheduled_process(fun) do
    in_fresh_process(fn ->
      Process.delete(:evogit_agent_id)
      fun.()
    end)
  end

  # Runs the given zero-arity fun in a fresh process with the given agent id in
  # its process dictionary (no ETS row is registered unless the fun does it).
  defp in_agent_process(agent_id, fun) do
    in_fresh_process(fn ->
      Process.put(:evogit_agent_id, agent_id)
      fun.()
    end)
  end

  defp in_fresh_process(fun) do
    Task.async(fn ->
      try do
        {:ok, fun.()}
      rescue
        e -> {:raised, e}
      end
    end)
    |> Task.await(5_000)
  end

  # assert_raise can only observe exceptions raised in the calling process, so
  # the fresh-process helpers report `{:raised, exception}` and tests re-raise
  # it in-process for assert_raise to pin the type + match the message.
  defp re_raise({:raised, e}), do: raise(e)
  defp re_raise({:ok, result}), do: flunk("expected a raise, got: #{inspect(result)}")

  # --- Deterministic slot/retry waits (no fixed sleeps) -------------------

  # Grants `@model_id`'s only LLM slot to `agent_id` FROM THE TEST PROCESS — a
  # real scheduler grant (no ETS agent row is needed: an unknown id resolves to
  # the default model). Registered as an `on_exit` release so a failed assertion
  # can never leak a holder that would wedge the single-slot pool for sibling
  # tests.
  defp acquire_llm_slot(agent_id) do
    on_exit(fn -> AgentScheduler.release_llm_slot(agent_id) end)
    assert :ok = AgentScheduler.request_llm_slot(agent_id, 5_000)
  end

  # Waits until `expected` agents are QUEUED for `@model_id`'s slot — the
  # scheduler's `:blocked` path (paused scheduler or 0-capacity model), i.e.
  # until an attempt is blocked at slot acquisition.
  defp await_llm_waiting(expected, description) do
    await_llm_slot(:waiting, expected, description)
  end

  # Waits until `@model_id`'s slot has no holder left.
  defp await_llm_slot_free(description) do
    await_llm_slot(:used, 0, description)
  end

  # Polls the live per-model slot status until `field` matches `expected`, or
  # flunks with the last observed status.
  #
  # `used`/`waiting` are PERSISTENT scheduler states (a queued waiter stays
  # queued until it is granted; a released slot stays released) — or a state the
  # caller has arranged to be unreachable until it holds — so neither poll can
  # race a short-lived window. The 1ms poll interval only bounds the detection
  # latency (each status read is a µs-scale scheduler call).
  defp await_llm_slot(field, expected, description, deadline_ms \\ 5_000) do
    await_llm_slot_until(
      field,
      expected,
      description,
      System.monotonic_time(:millisecond) + deadline_ms
    )
  end

  defp await_llm_slot_until(field, expected, description, deadline) do
    status = llm_slot_status()

    cond do
      Map.fetch!(status, field) == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "timed out waiting for #{description}; " <>
            "last #{@model_id} slot status: #{inspect(status)}"
        )

      true ->
        Process.sleep(1)
        await_llm_slot_until(field, expected, description, deadline)
    end
  end

  defp llm_slot_status do
    AgentScheduler.get_llm_slot_status()
    |> Map.get(@model_id, %{used: 0, waiting: 0, capacity: 0})
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

    # Shrink the retry loop's exponential-backoff base through the call-time
    # app-env seam `:llm_retry_backoff_base_ms` (read by
    # `ToolDispatch.call_llm_with_retry/5` on every call) so each backoff sleep
    # is ~250ms instead of ~1s — the retry sequences below shrink from
    # ~3s / ~1s / ~7s to ~0.75s / ~0.25s / ~1.75s without touching lib. The value
    # is restored (or removed when it had none) in `on_exit`, keeping the seam out
    # of sibling tests.
    original_backoff_base = Application.get_env(:evo_git, :llm_retry_backoff_base_ms)
    Application.put_env(:evo_git, :llm_retry_backoff_base_ms, @retry_backoff_base_ms)

    # Single-slot "default" pool: while the retrying agent holds the slot NO other
    # agent can be granted — makes the between-retries release observable.
    AgentScheduler.update_config(
      model_profiles: [%{id: "default", model: "test:model", concurrency: 1}]
    )

    warm_pool()

    on_exit(fn ->
      AgentScheduler.resume()
      AgentScheduler.update_config(model_profiles: original_profiles)

      if original_backoff_base do
        Application.put_env(:evo_git, :llm_retry_backoff_base_ms, original_backoff_base)
      else
        Application.delete_env(:evo_git, :llm_retry_backoff_base_ms)
      end

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

    # The test process takes the model's only slot first, which forces the
    # retrying agent's first attempt to QUEUE at slot acquisition (see the
    # `@slot_owner_agent_id` notes above).
    acquire_llm_slot(@slot_owner_agent_id)

    retrying = start_retrying_agent(agent_id, 2)

    assert await_llm_waiting(1, "the first retry attempt to queue for the model's slot")

    # Releasing our hold grants that attempt within the SAME scheduler state
    # transition, so the next "slot free" state observable is the attempt's OWN
    # release: the retrying agent is now provably in its backoff sleep with the
    # slot FREE.
    AgentScheduler.release_llm_slot(@slot_owner_agent_id)
    assert await_llm_slot_free("the retrying agent to release its slot into the backoff sleep")

    # While the retrying agent sleeps between attempts, a second agent must be
    # able to acquire the model's only LLM slot. The 5s bound inside
    # `acquire_llm_slot/1` is only a safety net: the STRUCTURAL proof that the
    # slot was free BETWEEN attempts is the re-queue assertion below — a slot held
    # for the whole retry sequence (old behavior) never produces a second slot
    # request.
    acquire_llm_slot(@probe_agent_id)

    # The retrying agent's NEXT attempt queues behind the probe: it re-requests
    # the slot it released instead of holding it across the retry sequence.
    assert await_llm_waiting(1, "the next retry attempt to re-request the model's slot")

    # Release the probe's slot so the retrying agent can proceed with its next
    # attempt once its sleep ends.
    AgentScheduler.release_llm_slot(@probe_agent_id)

    # All retries exhaust (connection refused is not a rate limit), returning
    # {:error, reason} — the caller (prompt_until_tools_or_limit/5) raises on this.
    assert {:error, _reason} = Task.await(retrying, 15_000)
  end

  test "a paused scheduler blocks the retrying agent's next attempt at slot re-acquisition" do
    agent_id = 102
    register_agent(agent_id)

    # Same deterministic hand-off as in the previous test: the test process holds
    # the only slot so the first attempt is provably queued, and the release
    # (which grants it atomically) is followed by the attempt's own release.
    acquire_llm_slot(@slot_owner_agent_id)

    # max_retries = 2 → three attempts total. The extra attempt buys the headroom
    # this test needs: the pause below must land before the retrying agent has
    # spent its whole retry stream (its remaining backoff windows are the grace
    # period for the pause). Without the fix (slot held across the whole
    # sequence) the agent never re-requests the slot, so the wait below can never
    # be satisfied regardless of how many attempts are left.
    retrying = start_retrying_agent(agent_id, 2)

    assert await_llm_waiting(1, "the first retry attempt to queue for the model's slot")

    AgentScheduler.release_llm_slot(@slot_owner_agent_id)
    assert await_llm_slot_free("the retrying agent to release its slot into the backoff sleep")

    # The retrying agent has RUN an attempt and is now sleeping between attempts —
    # the pause lands BETWEEN attempts, as the old fixed `Process.sleep(150)` +
    # pause aimed to arrange.
    AgentScheduler.pause()
    assert AgentScheduler.paused?()

    # Its next attempt blocks on slot RE-acquisition (queued as :blocked) instead
    # of retrying.
    assert await_llm_waiting(1, "the next retry attempt to be blocked at slot re-acquisition")

    # The task is still alive: it is blocked in the scheduler's waiting queue, not
    # finished (this replaces the old `Task.yield(retrying, 1_500)` fixed wait —
    # a queued, unanswered request cannot complete, so no wall-clock bound is
    # needed to prove it).
    assert Task.yield(retrying, 0) == nil

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
      # rejected: the request shows up in the model's waiting queue instead of
      # raising the old "0 LLM slots" error.
      assert await_llm_waiting(1, "the 0-capacity slot request to be enqueued, not rejected")

      # No retry has run yet: the task is blocked at slot acquisition (this
      # replaces the old `Task.yield(task, 500) == nil` fixed wait — the enqueued,
      # unanswered request proves the task cannot have completed an attempt).
      assert Task.yield(task, 0) == nil

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

  # ---------------------------------------------------------------------------
  # Descriptive errors from current_model/0 + current_generation_params/0

  # Both helpers raise a descriptive ArgumentError (naming the agent id, or
  # stating the process is not a scheduled agent) instead of the old
  # context-free MatchError ("no match of right hand side value: :error") when
  # the scheduler has no state for the calling process — e.g. the agent was
  # purged/cancelled mid-call or the scheduler restarted while the process was
  # blocked waiting for an LLM slot. assert_raise pins the exception TYPE, so a
  # regression back to MatchError fails these tests.
  # ---------------------------------------------------------------------------

  test "current_model/0 raises a descriptive error when the process is not a scheduled agent" do
    assert_raise ArgumentError, ~r/not a scheduled agent/, fn ->
      re_raise(in_unscheduled_process(&ToolDispatch.current_model/0))
    end
  end

  test "current_generation_params/0 raises a descriptive error when the process is not a scheduled agent" do
    assert_raise ArgumentError, ~r/not a scheduled agent/, fn ->
      re_raise(in_unscheduled_process(&ToolDispatch.current_generation_params/0))
    end
  end

  test "current_model/0 raises a descriptive error naming the agent id when its state is gone" do
    assert_raise ArgumentError,
                 ~r/no agent state for agent 999.*purged or cancelled.*scheduler restarted/s,
                 fn ->
                   re_raise(in_agent_process(999, &ToolDispatch.current_model/0))
                 end
  end

  test "current_generation_params/0 raises a descriptive error naming the agent id when its state is gone" do
    assert_raise ArgumentError,
                 ~r/no agent state for agent 999.*purged or cancelled.*scheduler restarted/s,
                 fn ->
                   re_raise(in_agent_process(999, &ToolDispatch.current_generation_params/0))
                 end
  end

  test "current_model/0 and current_generation_params/0 return the registered state on the happy path" do
    agent_id = 104

    state = %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/genesis-retry-slot-test"},
      llm_model: refused_model(),
      llm_generation_params: [temperature: 0.7, max_tokens: 128],
      max_retries: 2,
      max_depth: 1,
      model_id: "default"
    }

    Store.put_agent_state(agent_id, state)
    on_exit(fn -> Store.delete_agent_state(agent_id) end)

    assert {:ok, model} = in_agent_process(agent_id, &ToolDispatch.current_model/0)
    assert model == refused_model()

    assert {:ok, [temperature: 0.7, max_tokens: 128]} =
             in_agent_process(agent_id, &ToolDispatch.current_generation_params/0)
  end
end
