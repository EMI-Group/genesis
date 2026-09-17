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
  The remaining one-off cost is ReqLLM's `LLMDB.load/1` catalog decode, paid ONCE
  in `setup_all/1` (see `warm_pool/0`).

  `async: false` — touches the global `EvoGit.AgentScheduler` GenServer (config
  update, pause/resume) and the shared scheduler ETS tables.

  It also pins the model-exhaustion (HTTP 402 "insufficient balance") retry
  handling: a 402 drives the LONG model-exhaustion schedule reported
  SCHEDULER-side (the agent recurses immediately and queues behind the per-model
  backoff — never an agent-side sleep), while an ordinary transient error keeps
  the short schedule and sets no backoff. The 402 is produced end-to-end by
  `EvoGit.TestLlmServer` (a raw-TCP HTTP server), so no mocks or fixtures are
  needed; the default 60s/8h backoffs are asserted (never waited out) and the
  scheduler pool is restored via `purge_llm_pool/1` in `on_exit`.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  # --- Model-exhaustion (HTTP 402) fixture --------------------------------

  # The DeepSeek "Insufficient Balance" response, answered by a local raw-TCP
  # HTTP server (see EvoGit.TestLlmServer) so the 402 reaches the retry loop as
  # a real `%ReqLLM.Error.API.Request{}` — no mocks, no fixtures.
  @insufficient_balance_status 402
  @insufficient_balance_body ~s({"error":{"message":"Insufficient Balance"}})

  # --- Retry/slot synchronization constants -------------------------------

  # Base (ms) of the production exponential-backoff between retry attempts,
  # overridden per test through the call-time app-env seam
  # `:llm_retry_backoff_base_ms` read by `ToolDispatch` at call time. 75ms is
  # chosen so that (a) the retry sequences that used to cost ~3s / ~1s / ~7s
  # collapse to ~0.22s / ~0.22s / ~0.53s, and (b) every backoff window stays far
  # longer than a connection-refused attempt against a warmed Finch pool —
  # MEASURED at 1.0-2.5ms (p99 1.81ms, max 2.46ms over 300 samples) — and far
  # longer than a scheduler round trip (<=0.03ms) — so the deterministic waits
  # below (anchored on slot/queue STATE, never on the clock) cannot race the
  # window. `randomize/1` shifts each delay by at most 10%, so the SMALLEST
  # randomized window is 75 * 0.9 = 67.5ms — ~27x the measured worst-case
  # attempt and still >2x the old, deliberately conservative 30ms estimate.
  @retry_backoff_base_ms 75

  # The model pool every retry test drives: a SINGLE-slot pool, pinned by the
  # setup (`model_profiles: [%{id: "default", ..., concurrency: 1}]`).
  @model_id "default"

  # Agent id the test process uses to hold that only slot. Holding it makes the
  # retrying agent's FIRST attempt provably QUEUED at slot acquisition — a
  # persistent state, so there is no short "hold window" to catch by polling —
  # and the release then grants that attempt inside the SAME scheduler state
  # transition (`Slots.handle_release_llm_slot/2` removes the holder and grants
  # the waiters together). Together the two replace the old
  # `Process.sleep(150)`/"give the first attempt time to fail" guess with
  # certainty.
  @slot_owner_agent_id 99

  # Agent id of a second agent that probes whether the retrying agent's slot is
  # FREE between attempts. Its request is enqueued from a SEPARATE process while
  # the owner above still holds the slot (so an immediate grant is impossible)
  # and the SCHEDULER's own release sweep then hands it the slot — the grant
  # lands in the between-attempts interval without this test process having to
  # win any wall-clock race against the retrying agent's remaining attempts.
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

  # The FIRST ReqLLM call in a fresh BEAM pays a one-off `LLMDB.load/1`: reading
  # + JSON-decoding + indexing the packaged `priv/llm_db/snapshot.json` catalog
  # (8.6 MB), MEASURED at ~2.5-3.5s (`:timer.tc` around `LLMDB.load/1` alone;
  # every other step of `ReqLLM.stream_text/3` — model resolution, provider
  # build — is <=11ms). This is NOT Finch per-origin pool creation: a brand-new
  # destination costs ~2ms once the catalog is loaded. It is unavoidable for any
  # test that exercises ReqLLM, so `setup_all/1` pays it ONCE per module (it does
  # not reduce total wall clock — it only stops one arbitrary test from being
  # charged ~2.5s by `setup/1`).
  #
  # After the catalog load, warm the Finch pool + Mint modules for the refused
  # destination too: the FIRST transport attempt costs ~39ms vs ~1-2ms once warm
  # (a brand-new destination is only ~2-3ms once the catalog is loaded). Warming
  # keeps every retry attempt in the low milliseconds, so the retry-sleep windows
  # below are deterministic.
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

  # A model whose base_url points at the raw-TCP test HTTP server
  # (`EvoGit.TestLlmServer`): ReqLLM's OpenAI provider streams a real request at
  # it and surfaces whatever status/body it answers with (e.g. a DeepSeek-style
  # 402 "Insufficient Balance"). The dummy key clears ReqLLM's provider-build
  # phase; it is never validated by the local server.
  defp model_at(url) do
    %{provider: :openai, id: "test-llm-server", base_url: url, api_key: "test-key"}
  end

  # Registers a fake agent in the scheduler ETS with the connection-refused model.
  # Only the agent-state table is needed (ToolDispatch.current_model/0 reads
  # llm_model; slot resolution reads model_id) — no sched-meta entry is required.
  defp register_agent(agent_id), do: register_agent(agent_id, refused_model())

  # Same, with an explicit model spec (used by the model-exhaustion 402 tests).
  defp register_agent(agent_id, model) do
    state = %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/genesis-retry-slot-test"},
      llm_model: model,
      max_retries: 2,
      max_depth: 1,
      model_id: @model_id
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

  # --- Model-exhaustion backoff helpers -----------------------------------

  # Remaining ms of the "default" model's LLM backoff, or `nil` when the model
  # is NOT in backoff. The backoff is internal scheduler state with no public
  # read accessor, so it is read from the live state (the sibling
  # `agent_scheduler_test.exs` uses the same `:sys.get_state` seam).
  defp model_backoff_remaining do
    state = :sys.get_state(EvoGit.AgentScheduler)

    case State.backoff_for(state, @model_id) do
      nil -> nil
      until -> until - System.monotonic_time(:millisecond)
    end
  end

  # Clears the "default" model's backoff without touching any other pool.
  defp clear_model_backoff do
    :sys.replace_state(EvoGit.AgentScheduler, fn state ->
      %{state | llm_backoff_until: Map.delete(state.llm_backoff_until, @model_id)}
    end)
  end

  # Restores the global scheduler's LLM pools to a neutral state for one test
  # agent: removes it from every holder set AND every waiting queue (a killed
  # agent left queued would be granted later and permanently hog the
  # single-slot "default" pool), and clears the "default" model's backoff.
  defp purge_llm_pool(agent_id) do
    :sys.replace_state(EvoGit.AgentScheduler, fn state ->
      holders =
        Map.new(state.llm_holders, fn {model_id, set} ->
          {model_id, MapSet.delete(set, agent_id)}
        end)

      waiting =
        Map.new(state.llm_waiting, fn {model_id, queue} ->
          {model_id, :queue.filter(fn entry -> entry_agent_id(entry) != agent_id end, queue)}
        end)

      %{
        state
        | llm_holders: holders,
          llm_waiting: waiting,
          llm_backoff_until: Map.delete(state.llm_backoff_until, @model_id)
      }
    end)
  end

  defp entry_agent_id({agent_id, _from, _backoff}), do: agent_id
  defp entry_agent_id({agent_id, _from}), do: agent_id
  defp entry_agent_id(_entry), do: nil
  # One-off module warm-up (see warm_pool/0): pays the unavoidable
  # `LLMDB.load/1` catalog cost ONCE for the whole module, in a clearly
  # attributed place, instead of charging ~2.5s to whichever test happens to run
  # first. It does NOT reduce the module's total wall clock.
  #
  # The API key is pinned only for the duration of the warm-up call (the
  # per-test `setup/1` below keeps pinning it the way it always has).
  setup_all do
    previous_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    try do
      warm_pool()
    after
      if previous_api_key do
        Application.put_env(:req_llm, :openai_api_key, previous_api_key)
      else
        Application.delete_env(:req_llm, :openai_api_key)
      end
    end

    :ok
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"

    # Ensure a clean, unpaused scheduler regardless of prior tests (resume/1 is
    # a no-op when not paused).
    AgentScheduler.resume()

    # Defensive: a sibling test may have left the "default" model in a long
    # model-exhaustion backoff (see the HTTP 402 tests below) — clear it so
    # every test starts from a neutral per-model pool, and clear it again on
    # exit so no long backoff leaks into later modules.
    clear_model_backoff()
    on_exit(fn -> clear_model_backoff() end)
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
    # is ~75ms instead of ~1s — the retry sequences below shrink from
    # ~3s / ~1s / ~7s to ~0.22s / ~0.22s / ~0.53s without touching lib. The value
    # is restored (or removed when it had none) in `on_exit`, keeping the seam out
    # of sibling tests.
    original_backoff_base = Application.get_env(:evo_git, :llm_retry_backoff_base_ms)
    Application.put_env(:evo_git, :llm_retry_backoff_base_ms, @retry_backoff_base_ms)

    # Single-slot "default" pool: while the retrying agent holds the slot NO other
    # agent can be granted — makes the between-retries release observable.
    AgentScheduler.update_config(
      model_profiles: [%{id: "default", model: "test:model", concurrency: 1}]
    )

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

    # Failure-proof, order-proof cleanup: a flunked assertion can leave any of the
    # three agent ids holding or still waiting for the single slot, and a release
    # sweep can promote a still-queued waiter into a fresh holder. Releasing every
    # id twice — from ONE process, so the casts stay ordered — drains both the
    # holder set and any waiter the preceding sweep promoted, so no leaked holder
    # can wedge the single-slot pool for sibling tests.
    on_exit(fn ->
      for _ <- 1..2, id <- [@slot_owner_agent_id, agent_id, @probe_agent_id] do
        AgentScheduler.release_llm_slot(id)
      end
    end)

    # Keep the probe at the absent-default recursion depth (`Slots.depth_of/1`
    # reads `:evogit_sched_meta`; no row -> 999) so the grant sweep prefers the
    # EARLIER queue entry — the first attempt — on a full tie. The probe is then
    # granted only by that attempt's OWN release.
    Store.delete_sched_meta(@probe_agent_id)

    # The test process takes the model's only slot first, which forces the
    # retrying agent's first attempt to QUEUE at slot acquisition (see the
    # `@slot_owner_agent_id` notes above).
    acquire_llm_slot(@slot_owner_agent_id)

    retrying = start_retrying_agent(agent_id, 2)

    assert await_llm_waiting(1, "the first retry attempt to queue for the model's slot")

    # The probe issues its request from a SEPARATE process while the owner still
    # holds the only slot, so an immediate grant is impossible: the request
    # provably QUEUES behind the first attempt. Pre-queueing it removes the old
    # race in which this process had to acquire the free slot before the retrying
    # agent's remaining attempts completed (a load-starved test process could lose
    # that race and then never observe a waiter at all).
    probe = Task.async(fn -> AgentScheduler.request_llm_slot(@probe_agent_id, 5_000) end)
    assert await_llm_waiting(2, "the probe to queue behind the first attempt")

    # Releasing the owner hands the slot to the first attempt (the earlier queue
    # entry). When that attempt releases, the SCHEDULER's own sweep grants the
    # probe — i.e. the probe is granted inside the between-attempts interval. That
    # is the structural proof that the slot is FREE between attempts: a slot held
    # across the whole retry sequence (old behavior) would never release the first
    # attempt, so the probe could not be granted here.
    AgentScheduler.release_llm_slot(@slot_owner_agent_id)
    assert :ok == Task.await(probe, 5_000)

    # The retrying agent's NEXT attempt now queues behind the probe's
    # persistently-held slot: it re-requested the slot it released instead of
    # holding it across the retry sequence.
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
    # the only slot so the first attempt is provably QUEUED.
    acquire_llm_slot(@slot_owner_agent_id)

    # max_retries = 2 → three attempts total: the first is granted by the release
    # below, the second is the one the pause must block at re-acquisition, and the
    # third runs after resume.
    retrying = start_retrying_agent(agent_id, 2)

    assert await_llm_waiting(1, "the first retry attempt to queue for the model's slot")

    # Pause BEFORE the hand-off: the pause is therefore in place while the first
    # attempt is still queued — before ANY attempt acquires the slot — so no
    # wall-clock race between this process and the agent's backoff windows can let
    # the pause land too late (the failure mode of the old
    # `await_llm_slot_free` + `pause()` ordering, where the remaining attempts
    # could all complete first under load).
    #
    # The release still grants the queued first attempt: the release sweep is not
    # paused-gated (`Slots.handle_release_llm_slot/2` → `grant_pending_llm_slots/1`
    # has no `paused` check). That attempt runs, releases into its backoff sleep,
    # and its NEXT attempt is then blocked at re-acquisition by the pause.
    AgentScheduler.pause()
    assert AgentScheduler.paused?()

    AgentScheduler.release_llm_slot(@slot_owner_agent_id)
    assert await_llm_slot_free("the retrying agent to release its slot into the backoff sleep")

    # Its next attempt blocks on slot RE-acquisition (queued as :blocked) even
    # though the slot is FREE — the pause, not contention, is what blocks it. A
    # slot held across the whole retry sequence (old behavior) never re-requests,
    # so this wait can never be satisfied.
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
  # Model-exhaustion (HTTP 402 "insufficient balance") retry handling
  #
  # A 402 is not a transient transport hiccup: the agent must not burn the short
  # retry schedule, and it must not sit in a multi-hour agent-side sleep either.
  # The loop reports the LONG model-exhaustion backoff to the scheduler and
  # recurses IMMEDIATELY — the wait is realized scheduler-side (the next
  # attempt's slot request queues in the per-model backoff, purgeable by
  # force-kill / graceful cancel). These tests drive a real 402 through
  # EvoGit.TestLlmServer (a raw-TCP HTTP server) so the error classification
  # runs end-to-end, and a real connection-refused spec for the ordinary path.
  # ---------------------------------------------------------------------------

  describe "model-exhaustion (HTTP 402) retry handling" do
    test "reports a long backoff and recurses with NO agent-side sleep" do
      agent_id = 111

      server =
        EvoGit.TestLlmServer.start!(@insufficient_balance_status, @insufficient_balance_body)

      register_agent(agent_id, model_at(server.url))
      on_exit(fn -> purge_llm_pool(agent_id) end)

      started = System.monotonic_time(:millisecond)
      task = start_retrying_agent(agent_id, 1)

      try do
        # Attempt 1 fails with 402 → the loop reports the model-exhaustion
        # backoff (default 60s) and recurses IMMEDIATELY: attempt 2's slot
        # request lands in the model's backoff queue within milliseconds. An
        # agent-side 60s sleep (the old behavior for an unclassified 402) could
        # never satisfy this wait inside its 5s deadline.
        assert await_llm_waiting(1, "the 402 retry to queue behind the model-exhaustion backoff")

        # Confirms the recursion was near-instant (no sleep of the reported
        # backoff anywhere agent-side).
        assert System.monotonic_time(:millisecond) - started < 5_000

        # The reported backoff IS the model-exhaustion schedule's first entry
        # (~60s) — not the short transient schedule (~75ms via the seam).
        remaining = model_backoff_remaining()
        assert is_integer(remaining)
        assert remaining > 30_000
        assert remaining <= 60_000
      after
        # Failure-proof cleanup: a flunked assertion can leave the task blocked
        # on the :infinity slot call. The `on_exit` above purges the pool.
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "an ordinary transient error keeps the short schedule and sets NO backoff" do
      agent_id = 112
      register_agent(agent_id)

      started = System.monotonic_time(:millisecond)
      task = start_retrying_agent(agent_id, 2)

      # 3 connection-refused attempts with the 75ms seam → ~0.2s, never a
      # model-exhaustion wait.
      assert {:error, _reason} = Task.await(task, 15_000)
      assert System.monotonic_time(:millisecond) - started < 3_000

      # No model-exhaustion class was reported: the model is NOT in backoff.
      assert model_backoff_remaining() == nil
    end

    test "an exhausted model-exhaustion retry reports the last (capped) schedule entry" do
      agent_id = 113

      server =
        EvoGit.TestLlmServer.start!(@insufficient_balance_status, @insufficient_balance_body)

      register_agent(agent_id, model_at(server.url))
      on_exit(fn -> purge_llm_pool(agent_id) end)

      started = System.monotonic_time(:millisecond)
      # max_retries 0 → a SINGLE attempt, whose 402 is terminal.
      task = start_retrying_agent(agent_id, 0)

      assert {:error, reason} = Task.await(task, 10_000)
      # Terminal, promptly — no agent-side sleep of the (8h) reported backoff.
      assert System.monotonic_time(:millisecond) - started < 5_000

      # ReqLLM wraps the HTTP error in an `API.Stream` whose `cause` is the real
      # `%ReqLLM.Error.API.Request{status: 402}` — the classification matched it
      # through the insufficient-balance phrase fallback (see the "Insufficient
      # Balance" reason above).
      assert %ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{status: 402}} = reason
      # The final report refreshes the model-wide backoff with the LAST
      # schedule entry (model_exhaustion_delay(15) = the 8h cap), so the
      # crash-retry lands after a long scheduler wait instead of immediately
      # re-hitting the exhausted model.
      remaining = model_backoff_remaining()
      assert is_integer(remaining)
      assert remaining > 28_000_000
      assert remaining <= 28_800_000
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
