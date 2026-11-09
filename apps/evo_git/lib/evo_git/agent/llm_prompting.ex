defmodule EvoGit.Agent.LLMPrompting do
  @moduledoc """
  The LLM side of one agent turn: the request, its retry policy and the
  empty-response nudge.

  `call_llm_with_retry/5` runs the manual retry loop (LLM slot per attempt,
  model-exhaustion backoff realized by the scheduler, fail-fast on a
  non-retryable provider rejection, short exponential backoff otherwise) and
  `prompt_until_tools_or_limit/5` classifies each turn outcome through
  `EvoGit.Agent.CompletionProtocol`, nudging an EMPTY response exactly once
  before handing the turn back to the caller's protocol-violation path.
  """

  require Logger

  alias EvoGit.Agent.CompletionProtocol
  alias EvoGit.AgentScheduler

  import ReqLLM.Context, only: [user: 1]

  # Maximum consecutive EMPTY-response nudges before ending the turn gracefully.
  # A response with zero tool calls and no usable text (e.g. a provider
  # returning an empty message) is still a protocol failure — but a recoverable
  # one, so it gets exactly ONE nudge and re-prompt (the reference harness
  # recovers the same case as an EMPTY_RESPONSE code). After that the turn ends
  # via the existing protocol-violation path (grace/recovery or
  # :recovery_failed) instead of crashing or spinning forever.
  #
  # A response with zero tool calls and NON-EMPTY text is NOT a failure: it is
  # the model finishing, and it never reaches this nudge (see
  # `EvoGit.Agent.CompletionProtocol`).
  @max_no_tool_call_nudges 1

  # Base (ms) of the LLM retry exponential backoff. Overridable at call time via
  # the app env `:llm_retry_backoff_base_ms` (mirrors the other app-env test
  # seams such as `:peak_hours_now_fun` / `:worktree_create_fun`); when unset the
  # default below applies, so production behavior is unchanged.
  @default_retry_backoff_ms 1_000

  # --- LLM Prompting (transient-error retry + empty-response nudging) ---

  @doc false
  # Calls the LLM and classifies the turn outcome via
  # `EvoGit.Agent.CompletionProtocol.classify/1`:
  #
  #   * `{:tool_calls, _}` → `{:ok, response}`, the loop continues normally.
  #   * `{:text_reply, text}` → `{:implicit_completion, response, text}`: the
  #     model finished by writing text instead of calling a tool (the harness
  #     completion signal). No nudge — nudging here would fight the training
  #     distribution and turn a legitimate finish into a protocol violation.
  #   * `:empty` → zero tool calls AND no usable text, a recoverable protocol
  #     failure: append ONE nudge and re-prompt, then end the turn gracefully
  #     via `{:error, :protocol_violation}` (feeding the existing
  #     grace/recovery path — no crash, no new try/rescue).
  #
  # Transient transport/stream errors are still retried with exponential backoff
  # inside `call_llm_with_retry/5`.
  #
  # A NON-RETRYABLE provider rejection (`EvoGit.Agent.LlmError`) is the one
  # other graceful terminal arm: the retry loop already failed fast, so
  # `{:error, {:llm_request_rejected, message}}` is passed through unchanged.
  # Every other `{:error, reason}` still raises exactly as before.
  def prompt_until_tools_or_limit(context, tools, llm_gen_opts, agent_id, max_retries) do
    prompt_until_tools_or_limit(context, tools, llm_gen_opts, agent_id, max_retries, 0)
  end

  defp prompt_until_tools_or_limit(
         context,
         tools,
         llm_gen_opts,
         agent_id,
         max_retries,
         nudge_count
       ) do
    case call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries) do
      {:ok, response, _llm_duration} ->
        case CompletionProtocol.classify(response) do
          {:tool_calls, _calls} ->
            {:ok, response}

          {:text_reply, text} ->
            {:implicit_completion, response, text}

          :empty ->
            if nudge_count >= @max_no_tool_call_nudges do
              Logger.warning(
                "Agent #{agent_id}: LLM returned an empty response (no tool calls, no text) after #{nudge_count} consecutive nudges (#{nudge_count + 1} attempts), ending turn gracefully"
              )

              {:error, :protocol_violation}
            else
              Logger.warning(
                "Agent #{agent_id}: LLM returned an empty response (no tool calls, no text), appending nudge and continuing (nudge #{nudge_count + 1}/#{@max_no_tool_call_nudges})"
              )

              nudge_context = append_no_tool_call_nudge(response.context)

              prompt_until_tools_or_limit(
                nudge_context,
                tools,
                llm_gen_opts,
                agent_id,
                max_retries,
                nudge_count + 1
              )
            end
        end

      {:error, {:llm_request_rejected, _message} = terminal} ->
        # Non-retryable provider rejection: the loop already failed fast (no
        # further attempts) and the message is actionable as-is. Pass it through
        # as a GRACEFUL terminal error — no raise, so the runtime returns
        # `{:error, ...}` to the task wrapper, which persists the task as
        # `:failed` with this message instead of crash-retrying the agent
        # through the same doomed retry cycle.
        {:error, terminal}

      {:error, reason} ->
        # Genuine transient failure (network/rate-limit/stream) exhausted all
        # retries. This is a real error — raise, preserving prior behavior.
        raise "LLM request failed after #{max_retries} retries: #{inspect(reason)}"
    end
  end

  @doc false
  # Calls the LLM with retry-on-transient-error semantics using a MANUAL retry
  # loop (not the `retry` macro) so error CLASSES can be discriminated:
  #
  #   * MODEL-EXHAUSTION errors (e.g. "insufficient balance" / HTTP 402) are
  #     classified by `EvoGit.Agent.TruncationFeedback.classify_model_exhaustion/1`;
  #     the agent reports them to the scheduler via `report_llm_error/3` and then
  #     recurses IMMEDIATELY with NO agent-side sleep. The long wait is realized
  #     by the scheduler's per-model backoff: the next attempt's
  #     `AgentScheduler.with_llm_slot/2` BLOCKS in the backoff queue (a purgeable
  #     `:infinity` call, unblocked by force-kill/graceful-cancel or granted when
  #     the backoff expires). That keeps the wait cancel-safe and preserves the
  #     SAME turn/context across attempts (no context loss).
  #   * ORDINARY transient errors keep the previous schedule EXACTLY: a short
  #     exponential backoff of base `retry_backoff_base_ms()`, doubling each step,
  #     capped at 60s, with the same +/-10% jitter (see `short_delay_ms/1`).
  #
  # The loop handles ONLY genuine transport/stream errors returned as `{:error, _}`
  # tuples; it does NOT retry the "no tool calls" case — that semantic problem is
  # handled by the caller via context nudging. The first attempt runs with NO
  # initial sleep; total attempts = `max_retries + 1`. Returns `{:ok, response,
  # duration_ms}` or `{:error, reason}`.
  #
  # There is NO try/rescue around the loop: exceptions MUST propagate IMMEDIATELY
  # rather than being retried through backoff sleeps. The raise paths are:
  # (a) `{:error, :cancelled}` from a force-kill queue purge raises in
  # `AgentScheduler.with_llm_slot/2` → agent crash → scheduler crash-retry/cancel
  # machinery; (b) unexpected exceptions. A model with 0 LLM slots (peak
  # hard-pause) does NOT raise — its slot request BLOCKS (queued in the
  # scheduler, exactly like the paused-scheduler path), until capacity returns
  # (peak exit → `update_config` → `grant_pending_on_resume` grants queued
  # waiters) or a purge replies `{:error, :cancelled}` (force-kill).
  #
  # The LLM slot is acquired and released PER ATTEMPT (`with_llm_slot` wraps a
  # SINGLE attempt), so the backoff wait happens BETWEEN attempts while the
  # agent's slot is FREE. This keeps `AgentScheduler.pause/0` effective for a
  # retrying agent: its next attempt blocks on slot re-acquisition when the
  # scheduler is paused (and is granted on resume).
  def call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries) do
    do_call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries, 0)
  end

  # Manual retry loop. `attempt` is 0-based; total attempts = max_retries + 1.
  defp do_call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries, attempt) do
    case run_llm_attempt(context, tools, llm_gen_opts, agent_id) do
      {:ok, _response, _llm_duration} = result ->
        result

      {:error, reason} ->
        handle_llm_failure(context, tools, llm_gen_opts, agent_id, max_retries, attempt, reason)
    end
  end

  # The resolved model spec for a DIAGNOSTIC annotation on the fail-fast error
  # message (`handle_llm_failure/7`), as opposed to `current_model/0`'s raising
  # lookup. Deliberately TOTAL: an annotation must never turn the graceful
  # terminal `{:error, {:llm_request_rejected, message}}` into an agent crash
  # (the agent state can legitimately be gone by then — a purge/cancel or a
  # scheduler restart while the call was in flight), so a missing state simply
  # omits the model from the message.
  defp diagnostic_model_spec do
    with agent_id when not is_nil(agent_id) <- AgentScheduler.current_agent_id(),
         {:ok, agent_state} <- AgentScheduler.get_agent_state(agent_id) do
      agent_state.llm_model
    else
      _other -> nil
    end
  end

  # Classifies a failed attempt and decides what to do next: recurse
  # (model-exhaustion → immediate recursion, the scheduler realizes the wait;
  # ordinary transient → short backoff sleep), FAIL FAST on a non-retryable
  # provider rejection, or return the terminal error once attempts are
  # exhausted.
  #
  # Branch order matters:
  #
  #   1. MODEL EXHAUSTION first — 402 (insufficient balance) / 429 (rate limit)
  #      keep their existing long scheduler-side backoff untouched, for both the
  #      in-flight retry and the exhausted case.
  #   2. NON-RETRYABLE provider rejection (`EvoGit.Agent.LlmError`) — a
  #      deterministic 4xx (e.g. HTTP 400 code 1210 "Invalid API parameter")
  #      can never succeed on a retry, so the loop returns the terminal
  #      `{:error, {:llm_request_rejected, message}}` IMMEDIATELY: no sleep, no
  #      further attempt, no scheduler backoff. `prompt_until_tools_or_limit/6`
  #      passes this value through instead of raising, so the runtime returns
  #      `{:error, ...}` to the task wrapper, which persists the task as
  #      `:failed` with the actionable message in its structured error record —
  #      instead of a `RuntimeError` crash that the scheduler crash-retries
  #      (each crash-retry re-running the whole retry cycle).
  #   3. Attempts exhausted → the unchanged terminal `{:error, reason}` (still
  #      raising downstream).
  #   4. Ordinary transient error → the unchanged short backoff + recurse.
  defp handle_llm_failure(context, tools, llm_gen_opts, agent_id, max_retries, attempt, reason) do
    class = EvoGit.Agent.TruncationFeedback.classify_model_exhaustion(reason)

    cond do
      class && attempt >= max_retries ->
        # Attempts exhausted. Keep the model-wide backoff fresh for the
        # crash-retry: `prompt_until_tools_or_limit/6` still raises as before,
        # but the crash-retry then lands after a long scheduler wait instead of
        # immediately re-hitting an exhausted model.
        AgentScheduler.report_llm_error(
          agent_id,
          class,
          EvoGit.Agent.LlmRetryPolicy.model_exhaustion_delay(15)
        )

        {:error, reason}

      class ->
        # Model exhaustion with attempts remaining: report to the scheduler and
        # recurse IMMEDIATELY — the next attempt's `with_llm_slot/2` BLOCKS in the
        # per-model backoff queue. No agent-side sleep here (the long wait is the
        # scheduler's, and stays cancel-safe).
        AgentScheduler.report_llm_error(
          agent_id,
          class,
          EvoGit.Agent.LlmRetryPolicy.model_exhaustion_delay(attempt + 1)
        )

        do_call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries, attempt + 1)

      EvoGit.Agent.LlmError.non_retryable?(reason) ->
        # Deterministic provider rejection: fail fast with an actionable message
        # that also names the request parameters Genesis SENT for this call and
        # the resolved model spec to check (see `EvoGit.Agent.LlmError`'s
        # `format_failure/2`). Parameter NAMES only — never a value, the
        # objective, a tool result or a credential.
        message =
          EvoGit.Agent.LlmError.format_failure(reason,
            params: request_parameters(tools, llm_gen_opts),
            model: diagnostic_model_spec()
          )

        Logger.error("Agent #{agent_id}: #{message}")

        {:error, {:llm_request_rejected, message}}

      attempt >= max_retries ->
        {:error, reason}

      true ->
        # Ordinary transient error: short exponential-backoff sleep, then recurse.
        :timer.sleep(short_delay_ms(attempt + 1))

        do_call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries, attempt + 1)
    end
  end

  # Runs ONE LLM attempt, acquiring and releasing the LLM slot for THAT single
  # attempt (the slot-per-attempt invariant). Any exception raised inside — e.g.
  # `{:error, :cancelled}` from a force-kill purge in
  # `AgentScheduler.with_llm_slot/2` — propagates IMMEDIATELY (no rescue).
  defp run_llm_attempt(context, tools, llm_gen_opts, agent_id) do
    request_params = request_parameters(tools, llm_gen_opts)
    log_request_parameters(agent_id, request_params)

    AgentScheduler.with_llm_slot(agent_id, fn ->
      with llm_start <- System.monotonic_time(:millisecond),
           {:ok, stream_resp} <-
             ReqLLM.stream_text(
               EvoGit.Agent.ToolDispatch.current_model(),
               context,
               request_params
             ),
           {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_resp),
           llm_end <- System.monotonic_time(:millisecond) do
        {:ok, response, llm_end - llm_start}
      else
        {:error, reason} ->
          Logger.warning(
            "Agent #{agent_id}: LLM request failed#{retry_intent(reason)} Reason: #{inspect(reason)}"
          )

          if EvoGit.ReqLLMPool.excess_queuing_error?(reason) do
            EvoGit.ReqLLMPool.bump_for_excess_queuing(
              AgentScheduler.get_config(:model_concurrency),
              AgentScheduler.get_config(:default_llm_max_concurrency)
            )
          end

          {:error, reason}
      end
    end)
  end

  # The EXACT keyword list handed to `ReqLLM.stream_text/3` for one attempt —
  # the single source of the request's parameter names for both the debug log
  # and the fail-fast message's self-diagnosing tail.
  defp request_parameters(tools, llm_gen_opts), do: Keyword.merge([tools: tools], llm_gen_opts)

  # Emits the parameter NAMES of the request once per attempt at DEBUG level so
  # even an ORDINARY (retryable) failure is diagnosable after the fact — e.g. a
  # provider rejecting an unsupported generation parameter whose name never
  # appears in the error body. Nothing here is logged at info/error on the happy
  # path, and the lazy (0-arity) message means the names are rendered ONLY when
  # the debug level is actually enabled, so the normal path pays nothing.
  defp log_request_parameters(agent_id, request_params) do
    Logger.debug(fn ->
      names = EvoGit.Agent.LlmError.parameter_names(request_params)

      "Agent #{agent_id}: LLM request parameters sent: " <>
        EvoGit.Agent.LlmError.format_parameter_names(names)
    end)
  end

  # Per-attempt failure log suffix. A non-retryable provider rejection is
  # TERMINAL (`handle_llm_failure/7` returns immediately, see
  # `EvoGit.Agent.LlmError`), so the log must not claim it is "retrying"; every
  # other class keeps the original wording. Pure and total.
  defp retry_intent(reason) do
    if EvoGit.Agent.LlmError.non_retryable?(reason) do
      " (non-retryable — failing fast)."
    else
      ", retrying..."
    end
  end

  # Short exponential-backoff delay (ms) before attempt `k` (k >= 1) for ORDINARY
  # transient errors — preserves the prior schedule exactly: base
  # `retry_backoff_base_ms()`, doubling each step, capped at 60_000 ms, with the
  # same +/-10% jitter as `Retry.DelayStreams.randomize/2`. The raw stream's first
  # element is the base delay, so the delay before attempt k is the (k-1)-th
  # element (`Enum.at(stream, k - 1)`).
  defp short_delay_ms(k) do
    retry_backoff_base_ms()
    |> Retry.DelayStreams.exponential_backoff()
    |> Retry.DelayStreams.randomize()
    |> Retry.DelayStreams.cap(60_000)
    |> Enum.at(k - 1, 60_000)
  end

  # Retry backoff base (ms) — call-time app-env seam so tests can shrink the
  # exponential-backoff sleeps; defaults to `@default_retry_backoff_ms`.
  defp retry_backoff_base_ms do
    Application.get_env(:evo_git, :llm_retry_backoff_base_ms, @default_retry_backoff_ms)
  end

  @doc false
  # Appends a user-role nudge message to the context (which already contains the
  # assistant's EMPTY response), asking the model to either call a tool or say
  # what it did.
  def append_no_tool_call_nudge(context) do
    ReqLLM.Context.append(context, no_tool_call_nudge_message())
  end

  @doc false
  # The user-role nudge message appended when the LLM returns an EMPTY response
  # (zero tool calls AND no usable text). It is deliberately NOT used for a
  # text-only reply — that reply is the completion signal, not a failure.
  # Stamped with a creation-time timestamp (not turn-tagged — it can be
  # appended between turns inside prompt_until_tools_or_limit).
  def no_tool_call_nudge_message do
    EvoGit.Agent.ContextBuilder.tag_message_timestamp(
      user(
        "Your last response was empty: you did not make any tool calls and you " <>
          "did not write any text. If you have finished the task, reply with a " <>
          "plain-text summary of what you did — no tool call is needed to " <>
          "finish. Otherwise, respond with a tool call."
      )
    )
  end
end
