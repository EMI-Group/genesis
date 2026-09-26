defmodule EvoGit.Agent.ContextCompressionFailFastTest do
  @moduledoc """
  End-to-end coverage of `EvoGit.Agent.ContextCompression.compress_if_needed/2`'s
  failure paths, driven against a REAL HTTP endpoint.

  The compression LLM call is exercised against `EvoGit.TestLlmServer` — a
  raw-TCP HTTP/1.1 server (`test/support/llm_server.ex`) that answers every
  request with a fixed status + body — so a genuine
  `%ReqLLM.Error.API.Request{}` reaches the production classifier end-to-end,
  with no mocks, no VCR fixtures, and no network access.

  Pinned behaviour:

    * a NON-RETRYABLE provider rejection (HTTP 400) is TERMINAL — exactly ONE
      LLM request, exactly ONE `Logger.error` line, NO scheduler backoff
      report, the slot released by `with_llm_slot/2`'s `try/after`, and the
      `{:error, {:llm_request_rejected, message}}` tuple returned unchanged;
    * every OTHER failure class (HTTP 500, HTTP 402 model exhaustion, a refused
      transport) still RAISES the pre-existing `MatchError` — the crash-retry /
      scheduler-backoff semantics are unchanged, and the compression call has NO
      retry loop of its own (exactly one request).

  `async: false` — drives the GLOBAL `EvoGit.AgentScheduler` GenServer: the
  setup rewrites its `model_profiles` (a single-slot pool), the per-model
  backoff is read/cleared through `:sys.get_state/1` + `:sys.replace_state/2`,
  and the non-retryable test acquires/releases a slot from the shared scheduler
  LLM slot pools. All of that is BEAM-global state observable by any
  concurrently running module.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Agent.ContextCompression
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.State

  # The only profile the setup installs. Its id is what the scheduler resolves a
  # slot request to when the agent has NO ETS state row (`Slots.resolve_model_id/2`
  # falls back to the first profile's id), so every slot below lives in the
  # "default" model pool.
  @model_id "default"

  # The Z.AI HTTP 400 rejection body — a deterministic client/request error,
  # deliberately free of the model-exhaustion phrases ("balance", "quota",
  # "rate_limit", "429", "resource_exhausted") that
  # `EvoGit.Agent.TruncationFeedback.classify_model_exhaustion/1` inspects.
  @rejected_status 400

  @rejected_body ~s({"error":{"code":1210,"message":"Invalid API parameter, please check the documentation."}})

  # The DeepSeek-style 402 body. The "Insufficient Balance" phrase is what the
  # RAW-reason classification in `ToolDispatch.handle_llm_failure/7` matches
  # (a substring fallback over `inspect/1`, since the reason arrives wrapped in
  # an `API.Stream`), so this is the realistic out-of-credit shape.
  @exhausted_status 402
  @exhausted_body ~s({"error":{"message":"Insufficient Balance"}})

  @transient_status 500
  @transient_body ~s({"error":{"message":"Internal Server Error"}})

  # The per-test agent ids. High and distinct so no sibling test's leftover ETS
  # agent-state row can steer a slot request to another model pool.
  @rejected_agent_id 9_101
  @transient_agent_id 9_102
  @exhausted_agent_id 9_103
  @refused_agent_id 9_104

  # --- Model specs ---------------------------------------------------------

  # A model whose base_url points at the raw-TCP test HTTP server: ReqLLM's
  # OpenAI provider streams a real request at it and surfaces whatever
  # status/body it answers with. The dummy key clears ReqLLM's provider-build
  # phase and is never validated by the local server.
  defp model_at(url) do
    %{provider: :openai, id: "test-llm-server", base_url: url, api_key: "test-key"}
  end

  # A model whose base_url points at a closed loopback port (1): ReqLLM fails
  # with a connection-refused transport error, so the raise path is exercised
  # without any live endpoint. The dummy key is required so the failure is the
  # transport error rather than a provider-build error.
  defp refused_model do
    %{provider: :openai, id: "test-refused", base_url: "http://127.0.0.1:1", api_key: "test-key"}
  end

  # --- State / call helpers ------------------------------------------------

  # The compression threshold resolves from config (default 180_000) — read it
  # at runtime rather than hardcoding, so the fixture overflows whatever the
  # environment configures.
  defp threshold, do: EvoGit.Config.resolve([:llm, :compression_threshold_tokens])

  # The minimal compressible `LoopState`: above the threshold and shaped
  # `[system, user | rest]`, which is the ONLY shape `compress_if_needed/2`
  # compresses (any other shape returns the state unchanged).
  defp state(agent_id) do
    %LoopState{
      agent_id: agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are a test agent."),
          ReqLLM.Context.user("Objective: exercise the compression path.")
        ]),
      total_tokens: threshold() + 1,
      usage: Usage.zero()
    }
  end

  defp compress(agent_id, model) do
    ContextCompression.compress_if_needed(state(agent_id),
      agent_id: agent_id,
      llm_model: model
    )
  end

  # `{used, waiting}` of `model_id`'s live LLM pool, defaulting to a clean pool
  # when the model has no pool entry yet.
  defp used_and_waiting(model_id) do
    status =
      AgentScheduler.get_llm_slot_status()
      |> Map.get(model_id, %{used: 0, waiting: 0})

    {status.used, status.waiting}
  end

  # --- Model-exhaustion backoff helpers -----------------------------------

  # Remaining ms of the "default" model's LLM backoff, or `nil` when the model
  # is NOT in backoff. The backoff is internal scheduler state with no public
  # read accessor, so it is read from the live state (the sibling
  # `tool_dispatch_retry_slot_test.exs` uses the same `:sys.get_state` seam).
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

  # Pays ReqLLM's one-off `LLMDB.load/1` catalog decode (the packaged 8.6 MB
  # `priv/llm_db/snapshot.json`, MEASURED at ~2.5-4s) ONCE for this module, so
  # the per-test timing bound below measures the compression call rather than an
  # arbitrary test being charged the catalog load. It does NOT lower the
  # BEAM-wide total — the catalog is cached after the first load anywhere.
  defp warm_up do
    previous_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    try do
      case ReqLLM.stream_text(refused_model(), ReqLLM.Context.new(), []) do
        {:ok, stream_resp} -> _ = ReqLLM.StreamResponse.process_stream(stream_resp)
        {:error, _reason} -> :ok
      end
    after
      if previous_api_key do
        Application.put_env(:req_llm, :openai_api_key, previous_api_key)
      else
        Application.delete_env(:req_llm, :openai_api_key)
      end
    end

    :ok
  end

  setup_all do
    warm_up()
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"

    # A clean, unpaused scheduler regardless of prior tests (resume/1 is a no-op
    # when not paused).
    AgentScheduler.resume()

    # Defensive: a sibling test may have left the "default" model in a long
    # model-exhaustion backoff — clear it so every test starts from a neutral
    # per-model pool, and clear it again on exit so no backoff leaks out.
    clear_model_backoff()
    on_exit(fn -> clear_model_backoff() end)

    # Pin a test API key so the OpenAI provider requests clear the build phase
    # (ReqLLM's key resolution) and reach the transport layer.
    original_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    original_profiles = AgentScheduler.get_config(:model_profiles)

    # A SINGLE-slot "default" pool, so a leaked holder (e.g. a killed test task
    # bypassing `try/after`) or a leaked waiter is observable via the clean-pool
    # assertions.
    AgentScheduler.update_config(
      model_profiles: [%{id: @model_id, model: "test:model", concurrency: 1}]
    )

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

  # ---------------------------------------------------------------------------
  # HTTP 400 — the fail-fast terminal path
  # ---------------------------------------------------------------------------

  test "a 400 rejection returns the terminal tuple with one request, one Logger.error, no backoff, and a released slot" do
    # Defensive release: a flunked assertion kills the test's Task, and a
    # `:kill` signal bypasses `with_llm_slot/2`'s `try/after` — so without this
    # guard a leaked holder could wedge the single-slot pool for sibling tests.
    on_exit(fn -> AgentScheduler.release_llm_slot(@rejected_agent_id) end)

    server = EvoGit.TestLlmServer.start!(@rejected_status, @rejected_body)

    started = System.monotonic_time(:millisecond)

    # The call runs in a Task with a hard await bound: a regression into a
    # sleep/retry loop fails fast here instead of hanging the suite.
    log =
      capture_log(fn ->
        task = Task.async(fn -> compress(@rejected_agent_id, model_at(server.url)) end)
        send(self(), {:compression_result, Task.await(task, 5_000)})
      end)

    elapsed = System.monotonic_time(:millisecond) - started

    assert_received {:compression_result, result}

    # The terminal tuple is returned UNCHANGED — nothing was compressed, and
    # nothing was raised.
    assert {:error, {:llm_request_rejected, message}} = result
    assert message =~ "HTTP 400"
    assert message =~ "Invalid API parameter"
    assert message =~ "non-retryable"

    # No retry loop of its own: exactly ONE HTTP request was issued.
    assert EvoGit.TestLlmServer.request_count(server) == 1

    # EXACTLY one error line, carrying the actionable `format_failure/1` text.
    rejecting_lines =
      log |> String.split("\n") |> Enum.filter(&(&1 =~ "Provider rejected the LLM request"))

    assert length(rejecting_lines) == 1
    assert hd(rejecting_lines) =~ "Invalid API parameter"

    # The terminal path reports NO scheduler backoff — there is nothing to sleep
    # out; the fix is one call and a graceful terminal.
    assert model_backoff_remaining() == nil

    # `try/after` released the slot: the "default" pool is clean again.
    assert used_and_waiting(@model_id) == {0, 0}

    # Fail-fast, not a hang: far below the 5s await bound (the LLM catalog is
    # already warm from `setup_all/1`).
    assert elapsed < 2_000
  end

  # ---------------------------------------------------------------------------
  # Every other failure class still raises the pre-existing MatchError
  # ---------------------------------------------------------------------------

  test "a 500 still raises MatchError pinning the failed tuple, with one request and a released slot" do
    on_exit(fn -> AgentScheduler.release_llm_slot(@transient_agent_id) end)

    server = EvoGit.TestLlmServer.start!(@transient_status, @transient_body)

    e = assert_raise MatchError, fn -> compress(@transient_agent_id, model_at(server.url)) end

    # `raise MatchError, term: value` carries the unmatched right-hand side.
    assert {:error, _reason} = e.term

    # The compression call has NO retry loop: exactly one request.
    assert EvoGit.TestLlmServer.request_count(server) == 1

    # The raise propagated THROUGH `with_llm_slot/2`'s `try/after`, which
    # released the slot on the way out.
    assert used_and_waiting(@model_id) == {0, 0}
  end

  test "a 402 model exhaustion still raises MatchError and reports no scheduler backoff" do
    on_exit(fn -> AgentScheduler.release_llm_slot(@exhausted_agent_id) end)

    server = EvoGit.TestLlmServer.start!(@exhausted_status, @exhausted_body)

    e = assert_raise MatchError, fn -> compress(@exhausted_agent_id, model_at(server.url)) end

    assert {:error, _reason} = e.term
    assert EvoGit.TestLlmServer.request_count(server) == 1

    # The compression path never reports a scheduler backoff for model
    # exhaustion: it has no retry loop to wait out, so the pre-existing
    # crash-retry semantics are preserved untouched.
    assert model_backoff_remaining() == nil
    assert used_and_waiting(@model_id) == {0, 0}
  end

  test "a refused transport still raises MatchError pinning the failed tuple" do
    on_exit(fn -> AgentScheduler.release_llm_slot(@refused_agent_id) end)

    e = assert_raise MatchError, fn -> compress(@refused_agent_id, refused_model()) end

    assert {:error, _reason} = e.term
    assert used_and_waiting(@model_id) == {0, 0}
  end
end
