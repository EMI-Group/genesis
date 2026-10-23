defmodule EvoGit.Agent.Compression.LlmRetry do
  @moduledoc """
  The bounded retry loop around the stage-2 (summarising) compression LLM call.

  Owns the SLOT discipline and the FAILURE CLASSIFICATION for that one call, so
  `EvoGit.Agent.ContextCompression` can stay a pure orchestration of the two
  compression stages.

  ## Slot discipline

  The LLM slot is acquired and released PER ATTEMPT (`AgentScheduler.with_llm_slot/2`
  wraps a SINGLE attempt), so a backoff sleep happens with the slot FREE and a
  retrying agent still blocks on slot re-acquisition when the scheduler is
  paused. There is deliberately NO `try`/`rescue`: exceptions raised inside an
  attempt — e.g. `{:error, :cancelled}` from a force-kill slot purge — propagate
  immediately.

  ## Classification (mirrors `EvoGit.Agent.ToolDispatch`)

  The branch order is the same one the main turn's
  `call_llm_with_retry/5` + `handle_llm_failure/7` use:

    1. **Non-retryable provider rejection** (`EvoGit.Agent.LlmError`) — a
       deterministic 4xx can never succeed on a retry, so it returns
       `{:error, {:llm_request_rejected, message}}` IMMEDIATELY: ONE request, no
       sleep, no scheduler backoff. `EvoGit.Agent.LlmError.non_retryable?/1`
       already excludes the model-exhaustion classes, so this branch can never
       mask them.
    2. **Model exhaustion** (402/429-style,
       `EvoGit.Agent.TruncationFeedback.classify_model_exhaustion/1`) — NOT
       retried in-loop. The long wait belongs to the scheduler's model-wide
       backoff queue and to the task's crash-retry: an in-loop retry would block
       on that same queue while holding this agent, and it must stay
       cancel-safe. The exhaustion is therefore reported ONCE (with the deep
       `LlmRetryPolicy` delay a crash-retry should land after) and the term is
       raised.
    3. **Attempts exhausted** (an ordinary transient error on the last attempt) —
       raise.
    4. **Ordinary transient error with attempts remaining** — short backoff
       sleep on the SAME schedule as the main turn, then recurse.

  ## Why "raise" and not a silent fallback

  Branches 2 and 3 raise `MatchError` carrying `{:error, reason}`, which
  preserves the PRE-EXISTING crash-retry / scheduler-backoff semantics for every
  non-fail-fast failure. We deliberately do NOT fall back to a silently pruned
  context: the retained last-K-turns tail may itself exceed the window, so a
  silent fallback would only defer the overflow to the very next LLM request (a
  hard provider error) with no operator-visible signal.

  ## Seams

    * `:compression_llm_max_attempts` — total attempts (default 3), read at CALL
      time. An operational knob, not a config.toml key.
    * `:llm_retry_backoff_base_ms` — the SAME backoff base seam the main turn
      reads (default 1_000 ms), so tests can shrink the sleeps.
  """

  require Logger

  alias EvoGit.Agent.LlmRetryPolicy
  alias EvoGit.Agent.TruncationFeedback
  alias EvoGit.AgentScheduler

  @default_max_attempts 3
  @default_backoff_base_ms 1_000
  @max_backoff_ms 60_000

  @typedoc """
  `{:ok, response}` on success; `{:error, {:llm_request_rejected, message}}` for
  a terminal non-retryable provider rejection. Every other failure raises.
  """
  @type result ::
          {:ok, ReqLLM.Response.t()} | {:error, {:llm_request_rejected, String.t()}}

  @doc """
  Runs the summarising call for `context` on `llm_model`, retrying transient
  failures up to the call-time attempt budget.

  `gen_opts` is the keyword list of generation params handed to
  `ReqLLM.stream_text/3` (and, on a non-retryable rejection, used to name the
  request's parameter keys in the self-diagnosing error message).
  """
  @spec summarise(pos_integer(), term(), ReqLLM.Context.t(), keyword()) :: result()
  def summarise(agent_id, llm_model, context, gen_opts) do
    do_summarise(agent_id, llm_model, context, gen_opts, 0, max_attempts())
  end

  @doc """
  The total attempt budget for one compression call (call-time app-env seam; an
  unusable value falls back to the default rather than raising in the per-turn
  path).
  """
  @spec max_attempts() :: pos_integer()
  def max_attempts do
    case Application.get_env(:evo_git, :compression_llm_max_attempts, @default_max_attempts) do
      attempts when is_integer(attempts) and attempts > 0 -> attempts
      _other -> @default_max_attempts
    end
  end

  # `attempt` is 0-based; total attempts = `max_attempts`.
  defp do_summarise(agent_id, llm_model, context, gen_opts, attempt, max_attempts) do
    case run_attempt(agent_id, llm_model, context, gen_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = failure ->
        handle_failure(
          agent_id,
          llm_model,
          context,
          gen_opts,
          failure,
          reason,
          attempt,
          max_attempts
        )

      other ->
        # An unexpected (non `{:ok, _}` / non `{:error, _}`) shape: preserve the
        # old inline-match behaviour, which raised a `MatchError` carrying it.
        raise_match_error(other)
    end
  end

  defp handle_failure(
         agent_id,
         llm_model,
         context,
         gen_opts,
         failure,
         reason,
         attempt,
         max_attempts
       ) do
    class = TruncationFeedback.classify_model_exhaustion(reason)

    cond do
      EvoGit.Agent.LlmError.non_retryable?(reason) ->
        # The compression call sends NO tools, so the parameter names are the
        # generation-param keys alone; the model spec is the one this call
        # targeted. Both come from the caller's own arguments (no scheduler
        # lookup, so this path cannot raise for a purged agent either).
        message =
          EvoGit.Agent.LlmError.format_failure(reason,
            params: gen_opts,
            model: llm_model
          )

        {:error, {:llm_request_rejected, message}}

      class ->
        # Model exhaustion: report once so the crash-retry lands after the
        # scheduler's model-wide backoff instead of instantly re-hitting an
        # exhausted model, then raise (the long wait is NOT this loop's job).
        AgentScheduler.report_llm_error(
          agent_id,
          class,
          LlmRetryPolicy.model_exhaustion_delay(15)
        )

        raise_match_error(failure)

      attempt + 1 >= max_attempts ->
        raise_match_error(failure)

      true ->
        delay = short_delay_ms(attempt + 1)

        Logger.warning(
          "Agent #{agent_id}: compression LLM request failed, retrying in #{delay}ms " <>
            "(attempt #{attempt + 1}/#{max_attempts}). Reason: #{inspect(reason)}"
        )

        :timer.sleep(delay)

        do_summarise(agent_id, llm_model, context, gen_opts, attempt + 1, max_attempts)
    end
  end

  # ONE attempt, inside a single `with_llm_slot/2` (the slot-per-attempt
  # invariant). Any exception raised inside — e.g. `{:error, :cancelled}` from a
  # force-kill purge — propagates immediately (no rescue).
  defp run_attempt(agent_id, llm_model, context, gen_opts) do
    AgentScheduler.with_llm_slot(agent_id, fn ->
      with {:ok, stream_response} <- ReqLLM.stream_text(llm_model, context, gen_opts),
           {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response) do
        {:ok, response}
      end
    end)
  end

  # Re-produces the pre-change raise-on-match behaviour: `raise MatchError,
  # term: value` renders exactly the exception and message the previously
  # inlined `{:ok, _} = ...` match raised. Pure, total, never returns.
  defp raise_match_error(value) do
    raise MatchError, term: value
  end

  # Short exponential-backoff delay (ms) before attempt `k` (k >= 1) for ORDINARY
  # transient errors — the same schedule the main turn uses: base
  # `:llm_retry_backoff_base_ms`, doubling each step, capped at 60_000 ms, with
  # the same +/-10% jitter as `Retry.DelayStreams.randomize/2`. The raw stream's
  # first element is the base delay, so the delay before attempt k is the (k-1)-th
  # element.
  defp short_delay_ms(k) do
    Application.get_env(:evo_git, :llm_retry_backoff_base_ms, @default_backoff_base_ms)
    |> Retry.DelayStreams.exponential_backoff()
    |> Retry.DelayStreams.randomize()
    |> Retry.DelayStreams.cap(@max_backoff_ms)
    |> Enum.at(k - 1, @max_backoff_ms)
  end
end
