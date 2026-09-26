defmodule EvoGit.Agent.LlmErrorFailFastTest do
  @moduledoc """
  Pins the FAIL-FAST path of `EvoGit.Agent.ToolDispatch.handle_llm_failure/7`
  for a NON-RETRYABLE provider rejection (HTTP 400-class, e.g. Z.AI provider
  code 1210 "Invalid API parameter") — driven END-TO-END through a real HTTP
  server (`EvoGit.TestLlmServer`, a raw-TCP HTTP/1.1 server), so the whole chain
  runs unmocked:

      ReqLLM.stream_text/3 → ReqLLM.StreamResponse.process_stream/1
        → {:error, %ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{status: 400}}}
        → ToolDispatch.call_llm_with_retry/5 → handle_llm_failure/7
        → {:error, {:llm_request_rejected, message}}

  What is pinned:

    * the rejection is IMMEDIATE — exactly ONE HTTP request (the configured
      `max_retries` budget is NOT burned), one `Logger.error/1` carrying the
      actionable `EvoGit.Agent.LlmError.format_failure/1` message, no
      per-model scheduler backoff and a clean LLM slot pool;
    * `prompt_until_tools_or_limit/5` passes the tuple through UNCHANGED
      (graceful terminal error, NOT a `RuntimeError`) — unlike every other
      exhausted error, which still raises;
    * the NEGATIVES keep their existing behaviour: an HTTP 402 carrying the
      "Insufficient Balance" phrase still takes the long model-exhaustion path
      (report + immediate recursion into the per-model backoff queue, and the
      capped schedule entry on the terminal attempt), and an HTTP 500 is still
      retried.

  The model-exhaustion schedule is a genuinely long one (60 s base doubling to
  an 8 h cap) so nothing here is ever slept out: the CALL-TIME app-env seams
  `:llm_model_exhaustion_backoff_base_ms` / `:llm_model_exhaustion_backoff_cap_ms`
  are shrunk per test (restored in `on_exit`) and the backoff is asserted by
  READING the scheduler state, never by waiting. The DEFAULT 60 s / 8 h
  magnitudes are already pinned by `tool_dispatch_retry_slot_test.exs`, which is
  why this suite shrinks them instead of duplicating that assertion.

  `async: false` — this module touches BEAM-global state: the global
  `EvoGit.AgentScheduler` GenServer (config update via `update_config/1`,
  backoff access via `:sys.get_state` / `:sys.replace_state`) plus the shared
  scheduler ETS tables (agent state via `EvoGit.AgentScheduler.Store`). It also
  writes the same `:llm_model_exhaustion_backoff_*_ms` app-env seams read by the
  sibling `async: false` suites `llm_retry_policy_test.exs` and
  `tool_dispatch_retry_slot_test.exs`, so it must never run concurrently with
  them.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  # --- Non-retryable provider rejection (HTTP 400) fixture ----------------
  #
  # The real Z.AI shape: the provider body nests the details under "error";
  # ReqLLM unwraps it (`ReqLLM.Streaming.Failure.error_body/1`) into
  # `response_body = %{"code" => 1210, "message" => ...}`, sets `provider_code:
  # 1210`, `reason:` to the provider message and `retryable: false` (400 is not
  # a retryable status). Deliberately free of the balance/quota/rate-limit
  # phrases `EvoGit.Agent.TruncationFeedback.classify_model_exhaustion/1`
  # searches for, so the model-exhaustion branch cannot shadow the fail-fast one.
  @zai_status 400

  @zai_body ~s({"error":{"code":1210,"message":"Invalid API parameter, please check the documentation."}})

  @zai_human_message "Invalid API parameter, please check the documentation."

  # --- Model-exhaustion (HTTP 402) fixture --------------------------------
  #
  # The DeepSeek out-of-credit response. The "Insufficient Balance" phrase is
  # what keeps it classified as a model-exhaustion signal (the classification
  # falls back to an `inspect/1` substring search for a wrapped reason).
  @insufficient_balance_status 402
  @insufficient_balance_body ~s({"error":{"message":"Insufficient Balance"}})

  # --- Retryable (HTTP 500) fixture ---------------------------------------
  #
  # Carry no balance/quota/rate-limit phrase either, so 500 can only be the
  # ordinary-transient path.
  @server_error_status 500
  @server_error_body ~s({"error":{"message":"Internal Server Error"}})

  # --- Timing seams -------------------------------------------------------

  # Base (ms) of the production SHORT exponential-backoff between ordinary
  # transient retry attempts — shrunk through the call-time app-env seam
  # `:llm_retry_backoff_base_ms` (same 75ms value the sibling
  # `tool_dispatch_retry_slot_test.exs` uses) so the 500 retry test costs
  # ~0.25s instead of ~3s. It is also a safety net: if the 400 path ever
  # regressed into the ordinary retry branch, the test would still finish
  # quickly enough to observe the failure instead of timing out.
  @retry_backoff_base_ms 75

  # Model-exhaustion schedule seams (base / cap). With 5_000 / 30_000 the
  # 15-entry schedule is [5_000, 10_000, 30_000, 30_000, ...] (2 doubling
  # entries, the rest flat at the cap), so `model_exhaustion_delay(1)` is
  # 5_000 (the in-flight recursion's report) and `model_exhaustion_delay(15)`
  # is 30_000 (the exhausted attempt's terminal report). The production 60s/8h
  # defaults are pinned in `tool_dispatch_retry_slot_test.exs` — never slept
  # out there either.
  @exhaustion_base_ms 5_000
  @exhaustion_cap_ms 30_000

  # The model pool every test drives: a SINGLE-slot pool, pinned by the setup.
  @model_id "default"

  # A model whose base_url points at a closed loopback port — used ONLY by
  # `setup_all/1` to pay ReqLLM's one-off catalog cost outside any per-test
  # timeout (see `warm_reqllm/0`). A dummy api_key keeps the failure at the
  # transport layer, where it is instantaneous.
  @warmup_url "http://127.0.0.1:1"

  # --- Fixtures / helpers -------------------------------------------------

  # A model whose base_url points at the raw-TCP test HTTP server: ReqLLM's
  # OpenAI provider streams a real request at it and surfaces whatever
  # status/body it answers with. The dummy key clears ReqLLM's provider-build
  # phase (ReqLLM.Keys resolution); the local server never validates it.
  defp model_at(url) do
    %{provider: :openai, id: "test-llm-server", base_url: url, api_key: "test-key"}
  end

  # Registers a fake agent in the scheduler ETS with the given model. Only the
  # agent-state table is needed: `ToolDispatch.current_model/0` reads `llm_model`
  # and the slot resolution reads `model_id`. The `max_retries` field mirrors the
  # production default (15) so the fail-fast tests prove the attempt budget is
  # NOT burned; the retry budget under test is always the explicit argument
  # passed to `call_llm_with_retry/5`.
  defp register_agent(agent_id, model, max_retries) do
    state = %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/genesis-llm-failfast-test"},
      llm_model: model,
      max_retries: max_retries,
      max_depth: 1,
      model_id: @model_id
    }

    Store.put_agent_state(agent_id, state)
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
  end

  # Runs `fun` in a separate, LINKED process with the agent's process-dictionary
  # key set (ToolDispatch.current_model/0 reads it through
  # `AgentScheduler.current_agent_id/0`). Being a Task gives the caller a bound
  # (`Task.await/2`) — and that bound IS the "no retry loop / no sleep" evidence
  # for the fail-fast tests: a 15-attempt retry schedule with the production
  # backoff would take minutes, so anything that returns inside the bound
  # provably did not retry.
  defp start_agent_call(agent_id, fun) do
    Task.async(fn ->
      Process.put(:evogit_agent_id, agent_id)
      fun.()
    end)
  end

  defp call_llm_with_retry(agent_id, max_retries) do
    ToolDispatch.call_llm_with_retry(ReqLLM.Context.new(), [], [], agent_id, max_retries)
  end

  defp prompt_until_tools_or_limit(agent_id, max_retries) do
    ToolDispatch.prompt_until_tools_or_limit(ReqLLM.Context.new(), [], [], agent_id, max_retries)
  end

  # --- One-off ReqLLM warm-up ---------------------------------------------

  # The FIRST ReqLLM call in a fresh BEAM pays a one-off catalog load (reading
  # + JSON-decoding + indexing llm_db's packaged snapshot, measured at ~2.5-3.5s
  # in the sibling suite) and the first transport attempt against a brand-new
  # destination pays Finch/Mint module loading. Paying both in `setup_all/1`
  # keeps them out of the per-test `Task.await/2` bounds below (and does not
  # reduce the module's total wall clock).
  #
  # `stream_text/3` returns `{:ok, stream_resp}` once the provider build phase
  # succeeds; the real transport failure surfaces later in `process_stream/1`,
  # whose result is discarded — only the pool/module warmth is wanted.
  defp warm_reqllm do
    model = %{
      provider: :openai,
      id: "test-llm-server",
      base_url: @warmup_url,
      api_key: "test-key"
    }

    case ReqLLM.stream_text(model, ReqLLM.Context.new(), []) do
      {:ok, stream_resp} ->
        _ = ReqLLM.StreamResponse.process_stream(stream_resp)
        :ok

      {:error, _reason} ->
        # Build-phase failure (e.g. a polluted key env): the pool is not warmed,
        # but build-phase errors are instantaneous too.
        :ok
    end
  end

  # --- Deterministic slot waits (no fixed sleeps) -------------------------

  # Waits until `expected` agents are QUEUED for `@model_id`'s slot — either the
  # scheduler's paused path or a request parked behind the per-model backoff.
  defp await_llm_waiting(expected, description) do
    await_llm_slot(:waiting, expected, description)
  end

  # Waits until `@model_id`'s slot has no holder left. Needed because releasing
  # an LLM slot is an ASYNCHRONOUS cast, so the slot may still read as held for
  # an instant after the call under test has already returned.
  defp await_llm_slot_free(description) do
    await_llm_slot(:used, 0, description)
  end

  # Polls the live per-model slot status until `field` matches `expected`, or
  # flunks with the last observed status. `used`/`waiting` are PERSISTENT
  # scheduler states, so the poll cannot race a short-lived window; the 1ms
  # interval only bounds the detection latency.
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

  # The per-model slot status entry. `@model_id` is always present after the
  # setup's `update_config(model_profiles: ...)` (all_model_ids/1 includes every
  # configured profile), so a missing key is itself a failure.
  defp llm_slot_status do
    AgentScheduler.get_llm_slot_status() |> Map.fetch!(@model_id)
  end

  # --- Model-exhaustion backoff helpers -----------------------------------

  # Remaining ms of the "default" model's LLM backoff, or `nil` when the model
  # is NOT in backoff. The backoff is internal scheduler state with no public
  # read accessor, so it is read from the live state (the same `:sys.get_state`
  # seam the sibling `tool_dispatch_retry_slot_test.exs` uses).
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
  # agent left queued would be granted later and permanently hog the single-slot
  # "default" pool), and clears the "default" model's backoff.
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

  # Restores a call-time app-env seam: `put_env/3` when the key HAD a value,
  # `delete_env/2` when it was absent (so the production default applies again).
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup_all do
    previous_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    try do
      warm_reqllm()
    after
      restore_env(:req_llm, :openai_api_key, previous_api_key)
    end

    :ok
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"

    # Ensure a clean, unpaused scheduler regardless of prior tests (resume/1 is a
    # no-op when not paused).
    AgentScheduler.resume()

    # Defensive: a sibling test may have left the "default" model in a long
    # model-exhaustion backoff — clear it so every test starts neutral, and clear
    # it again on exit so no backoff leaks into later modules.
    clear_model_backoff()
    on_exit(fn -> clear_model_backoff() end)

    # Pin a test API key so the fake model's OpenAI provider clears the request
    # build phase (ReqLLM.Keys resolution) instead of failing with a
    # :provider_build_failed error shape.
    original_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    original_profiles = AgentScheduler.get_config(:model_profiles)

    # Shrink BOTH call-time timing seams (read by `ToolDispatch` and
    # `EvoGit.Agent.LlmRetryPolicy` per call) so nothing in this module is ever
    # slept out; restored in `on_exit`.
    original_backoff_base = Application.get_env(:evo_git, :llm_retry_backoff_base_ms)

    original_exhaustion_base =
      Application.get_env(:evo_git, :llm_model_exhaustion_backoff_base_ms)

    original_exhaustion_cap = Application.get_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms)

    Application.put_env(:evo_git, :llm_retry_backoff_base_ms, @retry_backoff_base_ms)
    Application.put_env(:evo_git, :llm_model_exhaustion_backoff_base_ms, @exhaustion_base_ms)
    Application.put_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms, @exhaustion_cap_ms)

    # Single-slot "default" pool: the fail-fast test must end with that slot
    # cleanly released, and the 402 test's queued retry is observable per model.
    AgentScheduler.update_config(
      model_profiles: [%{id: @model_id, model: "test:model", concurrency: 1}]
    )

    on_exit(fn ->
      AgentScheduler.resume()
      AgentScheduler.update_config(model_profiles: original_profiles)
      restore_env(:evo_git, :llm_retry_backoff_base_ms, original_backoff_base)
      restore_env(:evo_git, :llm_model_exhaustion_backoff_base_ms, original_exhaustion_base)
      restore_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms, original_exhaustion_cap)
      restore_env(:req_llm, :openai_api_key, original_api_key)
    end)

    :ok
  end

  describe "non-retryable 400 rejection (fail fast)" do
    test "fails fast: exactly one HTTP request, one Logger.error, no backoff, no slot" do
      agent_id = 201
      server = EvoGit.TestLlmServer.start!(@zai_status, @zai_body)

      # The production default attempt budget: proof the fail-fast does not burn
      # it (15 retries would need 15 requests and minutes of backoff).
      register_agent(agent_id, model_at(server.url), 15)
      on_exit(fn -> purge_llm_pool(agent_id) end)

      task = start_agent_call(agent_id, fn -> call_llm_with_retry(agent_id, 15) end)

      # The log is captured while the work runs, so the Task's Logger.error/1 is
      # included in `log`.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:llm_request_rejected, message}} = Task.await(task, 5_000)

          assert message =~ "HTTP 400"
          assert message =~ "code 1210"
          assert message =~ @zai_human_message
          assert message =~ "non-retryable"
        end)

      # EXACTLY one HTTP request: no further attempt was made.
      assert EvoGit.TestLlmServer.request_count(server) == 1

      # EXACTLY one rejection log line, carrying the actionable message.
      rejection_lines =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "Provider rejected the LLM request"))

      assert length(rejection_lines) == 1,
             "expected exactly one rejection log line, captured log was:\n#{log}"

      assert hd(rejection_lines) =~ @zai_human_message

      # No per-model scheduler backoff was recorded — the fail-fast path reports
      # nothing to the scheduler.
      assert model_backoff_remaining() == nil

      # The per-attempt LLM slot was released (used/1 waiting/1 are the only
      # non-clean states the single-slot pool could be left in).
      assert await_llm_slot_free("the fail-fast attempt's LLM slot to be released")
      assert llm_slot_status().waiting == 0
    end

    test "fails fast through prompt_until_tools_or_limit/5 (graceful terminal, not a raise)" do
      agent_id = 202
      server = EvoGit.TestLlmServer.start!(@zai_status, @zai_body)

      register_agent(agent_id, model_at(server.url), 15)
      on_exit(fn -> purge_llm_pool(agent_id) end)

      task = start_agent_call(agent_id, fn -> prompt_until_tools_or_limit(agent_id, 15) end)

      # The very same tuple comes back — `prompt_until_tools_or_limit/5` has a
      # dedicated pass-through arm for it. A REGRESSION to the generic
      # exhausted-error arm would raise a RuntimeError instead (the Task would
      # exit, so `Task.await/2` would fail here rather than return the tuple).
      assert {:error, {:llm_request_rejected, message}} = Task.await(task, 5_000)
      assert message =~ "HTTP 400"
      assert message =~ "non-retryable"
      assert EvoGit.TestLlmServer.request_count(server) == 1
      assert model_backoff_remaining() == nil
    end
  end

  describe "model-exhaustion 402 (NOT fail fast)" do
    test "with attempts remaining the 402 reports the backoff and the retry QUEUES behind it" do
      agent_id = 211

      server =
        EvoGit.TestLlmServer.start!(@insufficient_balance_status, @insufficient_balance_body)

      register_agent(agent_id, model_at(server.url), 1)
      on_exit(fn -> purge_llm_pool(agent_id) end)

      # max_retries 1 → attempt 1's 402 is NOT terminal: the loop reports the
      # model-exhaustion backoff and recurses IMMEDIATELY, so attempt 2 queues in
      # the per-model backoff queue (no agent-side sleep). A fail-fast
      # classification would have returned a {:llm_request_rejected, _} tuple
      # before any queue could form.
      task = start_agent_call(agent_id, fn -> call_llm_with_retry(agent_id, 1) end)

      try do
        assert await_llm_waiting(1, "the 402 retry to queue behind the model-exhaustion backoff")

        # The report used the schedule's FIRST entry (@exhaustion_base_ms via the
        # shrunk seam), bounded and strictly positive.
        remaining = model_backoff_remaining()
        assert is_integer(remaining)
        assert remaining > 0
        assert remaining <= @exhaustion_base_ms
      after
        # Failure-proof cleanup: a flunked assertion can leave the task blocked on
        # the :infinity slot call. The `on_exit` above purges the pool.
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "with no attempts remaining the 402 is terminal and refreshes the capped backoff" do
      agent_id = 212

      server =
        EvoGit.TestLlmServer.start!(@insufficient_balance_status, @insufficient_balance_body)

      register_agent(agent_id, model_at(server.url), 0)
      on_exit(fn -> purge_llm_pool(agent_id) end)

      # max_retries 0 → a SINGLE attempt, whose 402 is the exhausted branch: it
      # reports the LAST (capped) schedule entry and returns the raw reason —
      # NOT the fail-fast tuple.
      task = start_agent_call(agent_id, fn -> call_llm_with_retry(agent_id, 0) end)

      result = Task.await(task, 10_000)
      assert {:error, reason} = result
      refute match?({:error, {:llm_request_rejected, _}}, result)

      # ReqLLM wraps the HTTP error in an API.Stream whose cause is the real
      # %ReqLLM.Error.API.Request{status: 402}.
      assert %ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{status: 402}} = reason

      # The terminal report refreshed the model-wide backoff with the capped
      # entry (@exhaustion_cap_ms via the shrunk seam).
      remaining = model_backoff_remaining()
      assert is_integer(remaining)
      assert remaining > 0
      assert remaining <= @exhaustion_cap_ms
    end
  end

  describe "retryable 500 (unchanged retry path)" do
    test "an HTTP 500 is still retried and sets no model backoff" do
      agent_id = 221
      server = EvoGit.TestLlmServer.start!(@server_error_status, @server_error_body)

      register_agent(agent_id, model_at(server.url), 2)
      on_exit(fn -> purge_llm_pool(agent_id) end)

      # max_retries 2 → 3 attempts. The 500 is neither a model-exhaustion signal
      # nor a non-retryable rejection, so the ordinary short-backoff loop runs
      # (~75ms + ~150ms with the shrunk seam) and the exhausted branch returns
      # the raw reason.
      task = start_agent_call(agent_id, fn -> call_llm_with_retry(agent_id, 2) end)

      result = Task.await(task, 10_000)
      assert {:error, _reason} = result
      refute match?({:error, {:llm_request_rejected, _}}, result)

      # The retry ACTUALLY happened: each of the 3 attempts issued one request
      # (a `>= 400` response other than 429 is not retried inside ReqLLM's
      # streaming layer — `ReqLLM.Streaming.Retry.handle_http_failure/5` — so the
      # requests observed here are exactly this loop's attempts).
      assert EvoGit.TestLlmServer.request_count(server) == 3

      # An ordinary transient error never touches the per-model backoff.
      assert model_backoff_remaining() == nil
    end
  end
end
