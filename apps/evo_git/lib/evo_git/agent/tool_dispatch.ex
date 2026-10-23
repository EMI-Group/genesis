defmodule EvoGit.Agent.ToolDispatch do
  @moduledoc """
  Core tool-execution and LLM-turn logic extracted from `EvoGit.Agent.__using__/1`.

  Handles the main agent turn cycle: LLM call with retry, tool-call processing
  (complete vs regular, subagent vs standard), batching, timeout management,
  output sanitization, and redundant-cd warnings.

  ## Multimodal tool outputs (the wrap boundary)

  This module is the ONE place a `%EvoGit.Agent.ToolOutput{}` (text + optional
  images/audio) is wrapped, unwrapped and materialized. A tool may return a
  `%ToolOutput{}`; `sanitize_tool_result/3` wraps the raw return, runs the
  BINARY-ONLY sanitize/truncate-feedback pipeline on its text component and
  re-attaches the sanitized text (`ToolOutput.with_text/2`) so the media
  survive, collapsing an all-text output back to a plain binary. `assemble_tool_result/3`
  materializes it into the tool-result message — media-carrying outputs become a
  content-part LIST (`ToolOutput.to_content_parts/1`), while a plain binary is
  passed through BYTE-IDENTICALLY to `ReqLLM.Context.tool_result/3`. The
  delegation-hint and redundant-cd hint appenders unwrap to text before their
  string concatenation and re-wrap afterwards. `EvoGit.Agent.OutputSanitizer`,
  `EvoGit.Agent.TruncationFeedback` and `EvoGit.Agent.DelegationHints` never see
  or return a `%ToolOutput{}`.

  ## Completion protocol (harness-aligned)

  The turn ends when the model STOPS calling tools — a text reply with zero tool
  calls is an IMPLICIT COMPLETION, exactly like the reference harness the models
  are trained on (`EvoGit.Agent.CompletionProtocol` classifies each response):

    * tool calls present → execute them and continue the loop (the model may
      still call `complete_task` explicitly — that tool stays fully functional,
      including its dirty-workspace gate, archive refs and git note);
    * ZERO tool calls with usable text → `implicit_complete/2` commits any
      pending work and builds the SAME `%EvoGit.Agent.Result{}` the explicit
      route builds, so scheduler result handling, `merge_and_report`, the
      `genesis/agent_*` review branch, task persistence and the dashboard are
      all unchanged;
    * ZERO tool calls and no usable text (an empty provider response) → one
      nudge, then the unchanged bounded protocol-violation path
      (grace/recovery), so a genuinely broken turn still cannot spin forever.

  `complete_task` is therefore a supported, OPTIONAL tool rather than the only
  way to finish.
  """
  require Logger

  alias EvoGit.Agent.CompletionProtocol
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.ToolInvocation
  alias EvoGit.Agent.Tools.CompleteTask
  alias EvoGit.Agent.OutputSanitizer
  alias EvoGit.Agent.ToolOutput
  alias EvoGit.Agent.SubagentSchemas
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Usage
  alias EvoGit.Agent.Cost
  alias EvoGit.AgentScheduler

  import ReqLLM.Context, only: [user: 1, tool_result: 3]

  @complete_tool "complete_task"

  # Extra per-call headroom (ms) granted on top of the approval window for
  # level-2/3 `run_command` calls so the handler can execute AFTER the user
  # approves, before the tool task is killed.
  @approval_execution_buffer 30_000

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

  # --- Model & Generation Params ---

  @doc false
  def current_model do
    agent_state = fetch_current_agent_state!(:current_model)
    agent_state.llm_model
  end

  @doc false
  def current_generation_params do
    agent_state = fetch_current_agent_state!(:current_generation_params)
    agent_state.llm_generation_params
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

  # Shared lookup for current_model/0 + current_generation_params/0. Raises a
  # descriptive ArgumentError instead of a context-free MatchError when the
  # calling process is not a scheduled agent (no :evogit_agent_id) or the
  # scheduler has no ETS state for it — the latter typically means the agent
  # was purged/cancelled mid-call or the scheduler restarted while the process
  # was blocked waiting for an LLM slot.
  defp fetch_current_agent_state!(caller) do
    case AgentScheduler.current_agent_id() do
      nil ->
        raise ArgumentError,
              "#{inspect(caller)}: current process is not a scheduled agent (no " <>
                ":evogit_agent_id in the process dictionary), so the scheduler has " <>
                "no agent state to read"

      agent_id ->
        case AgentScheduler.get_agent_state(agent_id) do
          {:ok, agent_state} ->
            agent_state

          :error ->
            raise ArgumentError,
                  "#{inspect(caller)}: the scheduler has no agent state for agent " <>
                    "#{inspect(agent_id)} — the agent was likely purged or cancelled " <>
                    "mid-call, or the scheduler restarted"
        end
    end
  end

  # --- Commit Syncing ---

  @doc false
  def sync_current_commit_after_tools(%LoopState{} = state) do
    # Repo-less agents have no worktree and no phylo_node — skip git entirely.
    if Process.get(:repo_less) do
      :ok
    else
      repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

      case Git.rev_parse(repo_path) do
        {:ok, current_sha} ->
          {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)

          if agent_state.phylo_node.current_commit != current_sha do
            updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
            AgentScheduler.update_phylo_node(state.agent_id, updated_phylo)
          end

        {:error, reason} ->
          raise_rev_parse_error(reason)
      end
    end
  end

  # Syncs current commit and returns the SHA (for use in completion)
  defp sync_and_get_current_commit(%LoopState{} = state) do
    # Repo-less agents have no worktree and no phylo_node — no commit to sync;
    # completion receives a nil commit_sha.
    if Process.get(:repo_less) do
      nil
    else
      repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

      current_sha =
        case Git.rev_parse(repo_path) do
          {:ok, sha} -> sha
          {:error, reason} -> raise_rev_parse_error(reason)
        end

      {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)

      if agent_state.phylo_node.current_commit != current_sha do
        updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
        AgentScheduler.update_phylo_node(state.agent_id, updated_phylo)
      end

      current_sha
    end
  end

  # Raises a clear, diagnosable error for a failed `Git.rev_parse`. A missing
  # repo/worktree directory (`:enoent` — `Git.run/2`'s pre-check returns
  # `{:error, {:enoent, "Repository path does not exist: ..."}}`) means the
  # worktree was removed while the agent was running (e.g. a WorktreeManager
  # crash cascade): the agent cannot continue without its repo, but the
  # operator must be told the retry will start from a fresh worktree. All
  # other error shapes keep the original opaque message.
  defp raise_rev_parse_error({:enoent, msg}) do
    raise(
      "Worktree vanished while agent was running (removed mid-run): #{msg} — " <>
        "the retried agent will get a fresh worktree; uncommitted work is lost by design of the retry"
    )
  end

  defp raise_rev_parse_error({code, msg}) do
    raise "Git rev_parse failed (#{code}): #{msg}"
  end

  # --- Main Turn ---

  @doc false
  def do_turn(
        %LoopState{} = state,
        effective_tools_fn,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn
      ) do
    context = state.context
    tools = effective_tools_fn.(state)

    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    max_retries = agent_state.max_retries
    llm_gen_opts = agent_state.llm_generation_params

    case prompt_until_tools_or_limit(
           context,
           tools,
           llm_gen_opts,
           state.agent_id,
           max_retries
         ) do
      {:ok, response} ->
        process_llm_response(response, state, subagent_modules, loop_fn, trigger_recovery_fn)

      {:implicit_completion, response, text} ->
        # The model stopped calling tools and wrote text: that is the harness's
        # completion signal. Route it through the SAME post-response
        # bookkeeping as a tool-calling turn (usage, turn advance, ETS sync, so
        # the dashboard still sees the final assistant message), then finish.
        process_llm_response(
          response,
          state,
          subagent_modules,
          loop_fn,
          trigger_recovery_fn,
          text
        )

      {:error, :protocol_violation} ->
        handle_protocol_violation(state, loop_fn, trigger_recovery_fn)

      {:error, {:llm_request_rejected, _} = terminal} ->
        # Non-retryable provider rejection (the fail-fast path of
        # `handle_llm_failure/7`): the turn ends with a GRACEFUL terminal error
        # that propagates out of `Runner.run/3` unchanged. Deliberately NOT
        # routed through `handle_protocol_violation/3` — that would burn the
        # grace budget / trigger recovery against a request that can never
        # succeed, when the only real fix is a model-profile / request-parameter
        # change. The task is persisted `:failed` with the actionable message.
        {:error, terminal}
    end
  end

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
               current_model(),
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

  # Handles the protocol-violation outcome (an EMPTY response — no tool calls and
  # no usable text, after the single nudge was already spent) by either
  # triggering recovery (when not in the grace period), re-entering the loop
  # during grace with budget remaining (consuming one grace turn), or returning
  # :recovery_failed (when the grace budget is exhausted).
  #
  # A response with non-empty text never reaches here: it is an implicit
  # completion (see `EvoGit.Agent.CompletionProtocol`).
  defp handle_protocol_violation(%LoopState{} = state, loop_fn, trigger_recovery_fn) do
    cond do
      EvoGit.Agent.grace_period_continue_failed?(state) ->
        {:error, :recovery_failed}

      state.in_grace_period ->
        # In grace with budget remaining: consume one grace turn and re-enter
        # the loop so the LLM gets another chance to produce a valid turn.
        loop_fn.(consume_grace_turn(state))

      true ->
        trigger_recovery_fn.(state, "agent stopped calling tools")
    end
  end

  # --- Post-LLM Response Processing ---

  @doc """
  Removes duplicate tool calls emitted by buggy LLM models and replaces the
  last assistant message's `tool_calls` with the deduplicated list in both the
  response context and the response message.

  `tool_calls` are `%ReqLLM.ToolCall{}` structs (kept as structs so the OpenAI
  Responses API request encoder — which calls `ReqLLM.ToolCall.name/1` and
  `ReqLLM.ToolCall.args_json/1`, both struct-only — works on the next turn).
  The deduped list is written back into the message's `tool_calls` as the same
  structs; we never down-cast to plain maps.

  Since `response.message` and the last message in `response.context.messages`
  are the same struct reference (ReqLLM's response builder appends the message
  to the context), we update the `tool_calls` once and apply the same updated
  message struct to both places — no separate "sync context" step is needed.

  Returns `{deduped_tool_calls, updated_response}`. When no duplicates are
  found, the response is returned unchanged.
  """
  def dedupe_and_sync(tool_calls, response, agent_id) do
    deduped = dedupe_tool_calls(tool_calls, agent_id)

    if length(deduped) == length(tool_calls) do
      {tool_calls, response}
    else
      messages = response.context.messages
      count = length(messages)

      # Replace the last message's tool_calls with the deduped list directly.
      # The deduped list already contains the exact %ReqLLM.ToolCall{} structs
      # we want to keep, so there is no need to re-filter the message's
      # original structs.
      updated_response =
        case List.last(messages) do
          nil ->
            response

          last_msg ->
            updated_msg = %{last_msg | tool_calls: deduped}
            updated_messages = List.replace_at(messages, count - 1, updated_msg)
            updated_context = %{response.context | messages: updated_messages}

            %{response | context: updated_context, message: response.message && updated_msg}
        end

      {deduped, updated_response}
    end
  end

  @doc """
  Deduplicates a list of `%ReqLLM.ToolCall{}` structs.

  Tool calls arrive as `%ReqLLM.ToolCall{}` structs (the canonical shape stored
  in the assistant message so the OpenAI Responses API request encoder works on
  the next turn). Deduplication uses the struct accessors
  `ReqLLM.ToolCall.name/1` and `ReqLLM.ToolCall.args_map/1` rather than flat
  `:name`/`:arguments` keys.

  Deduplicates by `:id` first, then by identical content tuple
  `{normalized name, arguments}`. Keeps the first occurrence in each pass. Logs a
  `Logger.warning/1` whenever duplicates are removed, including the agent id,
  the count removed, the before/after totals, and a description of what was
  removed.

  Names are compared **ALIAS-AWARE**: the content pass normalises each call's
  name through `EvoGit.Agent.ToolNames.normalize/1`, so a response that emits
  the model-facing spelling (`write`/`read`/`bash`) alongside the internal
  dispatch key (`write_file`/`read_file`/`run_bash`) with identical arguments
  collapses to ONE call — otherwise the same mutation would be executed twice.
  """
  def dedupe_tool_calls(tool_calls, agent_id) when is_list(tool_calls) do
    original_count = length(tool_calls)

    # Pass 1 — dedupe by :id (primary signal: "duplicated tool call ids").
    # Enum.dedup_by/2 removes consecutive duplicates, keeping the first.
    by_id = Enum.dedup_by(tool_calls, & &1.id)

    # Pass 2 — dedupe by identical content {alias-normalized-name,
    # arguments-as-decoded-map}. Normalising the name is what makes
    # `write_file` and `write` (same args) the SAME call.
    final =
      Enum.dedup_by(by_id, fn call ->
        {EvoGit.Agent.ToolNames.normalize(ReqLLM.ToolCall.name(call)),
         ReqLLM.ToolCall.args_map(call)}
      end)

    final_count = length(final)
    removed_count = original_count - final_count

    if removed_count > 0 do
      # Enum.dedup_by keeps the same struct references, so list difference
      # yields exactly the removed items.
      removed = tool_calls -- final
      removed_list = Enum.map(removed, &"#{ReqLLM.ToolCall.name(&1)}(id=#{&1.id})")

      Logger.warning(
        "Agent #{agent_id}: Removed #{removed_count} duplicate tool call(s) " <>
          "(before: #{original_count}, after: #{final_count}). Removed: #{Enum.join(removed_list, ", ")}"
      )
    end

    final
  end

  @doc false
  # Handles one LLM response: usage accounting, tool-call dedupe, turn/context
  # advance, ETS sync, then either the implicit-completion finish (when
  # `completion_text` is supplied — the model replied with text and no tool
  # calls) or normal tool-call processing.
  #
  # `completion_text` (optional, default `nil`) is the model's own report text
  # from `EvoGit.Agent.CompletionProtocol`; it becomes the agent result verbatim.
  def process_llm_response(
        response,
        %LoopState{} = state,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn,
        completion_text \\ nil
      ) do
    state = update_turn_usage(state, response)
    {tool_calls, response} = prepare_tool_calls(response, state.agent_id)
    state = advance_turn_context(state, response)

    AgentScheduler.batch_update_agent(state.agent_id,
      context: state.context,
      turn: state.turn,
      usage: state.usage,
      total_tokens: state.total_tokens
    )

    # Initialize delegation hints in process dictionary for this turn
    Process.put(:delegation_hints, state.delegation_hints)
    Process.put(:read_delegation_hints, state.read_delegation_hints)

    if completion_text do
      # Implicit completion: the bookkeeping above already recorded the turn
      # (including the final assistant message in the context), so all that is
      # left is the completion side effects shared with explicit `complete_task`.
      {:ok, build_completion(state, completion_text)}
    else
      case process_tool_calls(tool_calls, state, subagent_modules) do
        {:complete, final_result} ->
          {:ok, final_result}

        {:continue, tool_responses, subagent_usage} ->
          continue_after_tools(
            tool_responses,
            subagent_usage,
            tool_calls,
            state,
            subagent_modules,
            loop_fn
          )

        {:error, :protocol_violation} ->
          handle_protocol_violation(state, loop_fn, trigger_recovery_fn)
      end
    end
  end

  # Tracks the current context length (replace, don't accumulate) and
  # accumulates cumulative usage (separate from total_tokens used for
  # compression).
  defp update_turn_usage(%LoopState{} = state, response) do
    usage = ReqLLM.Response.usage(response)

    current_tokens =
      if is_map(usage) do
        usage.input_tokens + usage.output_tokens + Map.get(usage, :reasoning_tokens, 0)
      else
        # Usage is nil - can happen with some providers or cached responses
        # Keep the previous token count
        Logger.warning("Agent #{state.agent_id}: LLM response doesn't contain token usage info.")

        state.total_tokens
      end

    # Cost is recomputed by `EvoGit.Agent.Cost` from the raw token counts + the
    # llm_db pricing catalog with an explicit peak/off-peak period (ReqLLM's
    # reported cost double-charges multi-period models and applies no cache
    # discount); when there is nothing to recompute from, ReqLLM's reported
    # cost is kept verbatim.
    turn_usage =
      Usage.from_response_usage(usage)
      |> Cost.apply_to_usage(usage, state.agent_id)

    %{state | total_tokens: current_tokens, usage: Usage.add(state.usage, turn_usage)}
  end

  # Extracts tool calls from the response, deduplicates them (handles buggy
  # models that emit identical duplicate calls — e.g. two identical subagent
  # spawns), and validates that all calls carry IDs.
  defp prepare_tool_calls(response, agent_id) do
    # Keep tool calls as %ReqLLM.ToolCall{} structs (the shape already present
    # in message.tool_calls). Do NOT convert them via ReqLLM.ToolCall.from_map/1,
    # which returns plain maps — those would break the OpenAI Responses API
    # request encoder (it calls ReqLLM.ToolCall.name/1 and args_json/1, which
    # only match the struct) on the next turn. Access name/arguments via
    # ReqLLM.ToolCall.name/1 and args_map/1 throughout the dispatch code.
    tool_calls = ReqLLM.Response.tool_calls(response)

    {tool_calls, response} = dedupe_and_sync(tool_calls, response, agent_id)

    # Validate tool calls have IDs
    invalid_calls = Enum.filter(tool_calls, fn call -> is_nil(Map.get(call, :id)) end)

    if invalid_calls != [] do
      Logger.error(
        "Agent #{agent_id}: Found #{length(invalid_calls)} tool calls without IDs: #{inspect(invalid_calls)}"
      )
    end

    {tool_calls, response}
  end

  # Uses the updated context from response (already has assistant message
  # appended): compacts reasoning_details to avoid N small fragments from
  # streaming and tags the context tail with the new turn number.
  defp advance_turn_context(%LoopState{} = state, response) do
    compacted_context = compact_reasoning_details(response.context)
    new_turn = state.turn + 1

    compacted_context =
      EvoGit.Agent.ContextBuilder.tag_context_tail_with_turn(compacted_context, new_turn)

    %{state | context: compacted_context, turn: new_turn}
  end

  # Handles the {:continue, ...} outcome of tool-call processing: picks up the
  # updated delegation hints from the process dictionary, tags and appends the
  # tool responses to the context, accumulates subagent usage, syncs state to
  # ETS, and re-enters the loop.
  defp continue_after_tools(
         tool_responses,
         subagent_usage,
         tool_calls,
         %LoopState{} = state,
         subagent_modules,
         loop_fn
       ) do
    if EvoGit.Agent.grace_period_continue_failed?(state) do
      {:error, :recovery_failed}
    else
      # A turn ended without complete_task: if in a grace period, consume one
      # grace turn (decrement grace_turns_remaining). Outside a grace period
      # this is a no-op (counter stays at its default 0).
      state = consume_grace_turn(state)

      # Pick up updated delegation hints from tool execution
      updated_hints = Process.get(:delegation_hints, state.delegation_hints)
      Process.delete(:delegation_hints)

      updated_read_hints =
        Process.get(:read_delegation_hints, state.read_delegation_hints)

      Process.delete(:read_delegation_hints)

      # Detect subagent calls to reset the middle-warning counter
      had_subagent_call =
        Enum.any?(tool_calls, fn call ->
          SubagentSchemas.subagent_module_for(ReqLLM.ToolCall.name(call), subagent_modules) != nil
        end)

      new_turns_since = if had_subagent_call, do: 0, else: state.turns_since_subagent + 1

      tagged_tool_responses =
        Enum.map(
          tool_responses,
          &EvoGit.Agent.ContextBuilder.tag_message_turn(&1, state.turn)
        )

      # Accumulate subagent usage into the parent agent's cumulative usage
      usage = if subagent_usage, do: Usage.add(state.usage, subagent_usage), else: state.usage

      state = %{
        state
        | context: ReqLLM.Context.append(state.context, tagged_tool_responses),
          delegation_hints: updated_hints,
          read_delegation_hints: updated_read_hints,
          turns_since_subagent: new_turns_since,
          usage: usage
      }

      # Sync updated context to ETS for dashboard visibility (returns :ok).
      # The in-memory context is already stamped at creation — no rebind.
      EvoGit.Agent.ContextBuilder.sync_context_to_ets(state.agent_id, state.context)

      # Sync accumulated subagent usage to ETS
      AgentScheduler.batch_update_agent(state.agent_id, usage: state.usage)

      loop_fn.(state)
    end
  end

  # Consumes one grace turn: decrements `grace_turns_remaining` when the agent
  # is in a grace period (a turn ended without `complete_task`). Outside a
  # grace period the counter stays at its default 0. Only reached when
  # `grace_period_continue_failed?/1` returned `false` (i.e. remaining > 1), so
  # the decremented value is always >= 1.
  defp consume_grace_turn(%LoopState{in_grace_period: true, grace_turns_remaining: n} = state) do
    %{state | grace_turns_remaining: n - 1}
  end

  defp consume_grace_turn(%LoopState{} = state), do: state

  # Note: `loop/1` and `trigger_recovery/2` are called via passed function
  # references (loop_fn, trigger_recovery_fn) from the agent's quote block.

  # --- Reasoning Compaction ---

  @doc false
  # Compacts fragmented reasoning_details from streaming into a single entry.
  # When LLMs stream responses, reasoning/thinking content arrives in multiple
  # small fragments. This function merges them into one entry to keep the
  # context lean (especially important for ETS storage and dashboard display).
  def compact_reasoning_details(context) do
    messages = context.messages

    # Find the last assistant message
    last_assistant_idx =
      messages
      |> :lists.reverse()
      |> Enum.find_index(&(&1.role == :assistant))

    case last_assistant_idx do
      nil ->
        context

      _ ->
        original_idx = length(messages) - 1 - last_assistant_idx
        last_msg = Enum.at(messages, original_idx)

        case last_msg.reasoning_details do
          details when is_list(details) and length(details) > 1 ->
            first = List.first(details)
            merged_text = Enum.map_join(details, "", & &1.text)

            compacted = %ReqLLM.Message.ReasoningDetails{
              text: merged_text,
              signature: first.signature,
              encrypted?: first.encrypted?,
              provider: first.provider,
              format: first.format,
              index: 0,
              provider_data: first.provider_data
            }

            updated_msg = %{last_msg | reasoning_details: [compacted]}
            updated_messages = List.replace_at(messages, original_idx, updated_msg)
            %{context | messages: updated_messages}

          _ ->
            # nil, empty list, or single entry — no-op
            context
        end
    end
  end

  # --- Tool Call Processing ---

  @doc false
  # Defensive fallback: an EMPTY response (zero tool calls, no usable text) is
  # detected in prompt_until_tools_or_limit/6 via
  # `EvoGit.Agent.CompletionProtocol.classify/1` before tool calls are ever
  # extracted, and a text-only reply is turned into an implicit completion
  # there, so an empty list should never reach here in normal operation. Kept as
  # a guard so any unexpected empty-list input degrades to a protocol violation
  # rather than a crash in process_regular_tool_calls/3.
  def process_tool_calls([], _state, _subagent_modules), do: {:error, :protocol_violation}

  def process_tool_calls(tool_calls, %LoopState{} = state, subagent_modules)
      when is_list(tool_calls) and tool_calls != [] do
    complete_call = Enum.find(tool_calls, &(ReqLLM.ToolCall.name(&1) == @complete_tool))

    if complete_call do
      handle_complete_call(complete_call, state, tool_calls)
    else
      process_regular_tool_calls(tool_calls, state, subagent_modules)
    end
  end

  @doc false
  # Predicate + log line: did the response carry any tool call?
  #
  # The TURN OUTCOME is decided by `EvoGit.Agent.CompletionProtocol.classify/1`
  # (tool calls → continue, text reply → implicit completion, neither → one
  # nudge), so this helper is not on the decision path. It is retained as the
  # public "no tool calls at all" check + warning used when diagnosing an empty
  # response.
  def ensure_tool_calls(response, agent_id) do
    if ReqLLM.Response.tool_calls(response) == [] do
      Logger.warning("Agent #{agent_id}: LLM returned no tool calls")
      {:error, :no_tool_calls}
    else
      :ok
    end
  end

  @doc false
  def handle_complete_call(complete_call, %LoopState{in_grace_period: grace} = state, tool_calls) do
    case ToolInvocation.arguments(complete_call) do
      {:ok, complete_args} when is_map(complete_args) ->
        finish_complete_call(complete_args, state, tool_calls, grace)

      {:error, reason} ->
        invalid_complete_arguments(tool_calls, reason)

      {:ok, _raw_arguments} ->
        # The tolerant parse handed back a raw (unparseable) string: there is no
        # `result` / `check_git_status` to read, so ask the model to re-issue the
        # call instead of silently completing with a placeholder result.
        invalid_complete_arguments(
          tool_calls,
          "the arguments could not be decoded as a JSON object"
        )
    end
  end

  # A `complete_task` call whose arguments do not decode must not complete the
  # turn with a fabricated result, and must not crash on `Map.get/2` with nil:
  # answer every call in the batch with the standard invalid-arguments result so
  # the model can self-correct on the next turn (mirroring the dirty-workspace
  # path, which also answers EVERY call to keep the tool-call/result pairing).
  defp invalid_complete_arguments(tool_calls, reason) do
    {:continue, error_tool_responses(tool_calls, ToolInvocation.invalid_arguments_result(reason)),
     nil}
  end

  defp finish_complete_call(complete_args, state, tool_calls, grace) do
    # Check if git status validation is enabled (default: true).
    # During the grace period, skip the dirty workspace check entirely: the
    # agent gets exactly one recovery turn, and a dirty workspace would return
    # {:continue, ...} → grace_period_continue_failed?/1 → :recovery_failed.
    # That deadlocks the agent (it can neither commit nor complete). The
    # priority during the grace turn is salvaging whatever is already
    # committed — the :end/:critical warnings already prompted a commit.
    check_git_status =
      not state.in_grace_period and
        Map.get(complete_args, "check_git_status") != false

    # Repo-less agents never write to disk, so the dirty-workspace check is
    # skipped entirely (the real Genesis source root being dirty is irrelevant,
    # and a dirty real repo would wedge completion with warnings).
    if Process.get(:repo_less) == true or grace or not check_git_status do
      do_complete(complete_args, state)
    else
      repo_path = Process.get(:repo_path)

      case CompleteTask.check_workspace_dirty(repo_path) do
        {:dirty, warning_msg} ->
          Logger.warning(
            "Agent #{state.agent_id}: Workspace is dirty at completion. Warning: #{warning_msg}"
          )

          {:continue, error_tool_responses(tool_calls, warning_msg), nil}

        {:clean, _} ->
          do_complete(complete_args, state)
      end
    end
  end

  # One tool result per call in the batch carrying `message` — keeps the
  # tool-call / tool-result pairing intact (a missing result for any call in the
  # batch causes provider API errors).
  defp error_tool_responses(tool_calls, message) do
    Enum.map(tool_calls, fn call ->
      tool_call_id = call.id || ReqLLM.ToolCall.name(call) || "unknown"
      tool_result(tool_call_id, ReqLLM.ToolCall.name(call), message)
    end)
  end

  # The EXPLICIT completion route (`complete_task`): sync the worktree commit,
  # then build the result. Its dirty-workspace gate was already applied by
  # `finish_complete_call/5`.
  defp do_complete(complete_args, %LoopState{} = state) do
    # Sync the current commit before completing
    commit_sha = sync_and_get_current_commit(state)

    result = Map.get(complete_args, "result", "Task finished.")

    {:complete, build_completion(state, result, commit_sha)}
  end

  # The IMPLICIT completion route (a text reply with no tool calls).
  #
  # Any pending work is committed FIRST so the sha reported to the runtime is
  # reviewable: without this the commit would only happen in `Runner.run/3`'s
  # post-run auto-commit fallback, i.e. AFTER `commit_sha` was captured, and
  # `Runtime.Helpers.merge_and_report/3,4` would take the no-changes path and
  # drop the work with the worktree. `commit_pending_in_worktree/0` is a no-op
  # for a clean workspace and for repo-less agents, and it never raises (git
  # errors are logged, not propagated), so it cannot turn a legitimate finish
  # into a failure. The explicit dirty-workspace gate is deliberately NOT
  # applied here — the model has finished; there is nothing to correct.
  defp build_completion(%LoopState{} = state, result) do
    AgentScheduler.Dispatch.commit_pending_in_worktree()
    build_completion(state, result, sync_and_get_current_commit(state))
  end

  # Shared completion builder for BOTH routes: identical `%Result{}` shape and
  # identical side effects (git note when `base_commit` is set, archive refs when
  # archiving), so every downstream consumer is oblivious to how the agent
  # finished.
  defp build_completion(%LoopState{} = state, result, commit_sha) do
    # Get metadata from agent state
    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    depth = AgentScheduler.current_depth()

    # Repo-less agents have a nil phylo_node — passing nil base_commit is safe:
    # CompleteTask.complete/4 guards git-note/archive writes on base_commit
    # being truthy, so both are skipped for repo-less agents.
    base_commit = if Process.get(:repo_less), do: nil, else: agent_state.phylo_node.base_commit

    CompleteTask.complete(
      state.agent_id,
      result,
      commit_sha,
      base_commit: base_commit,
      parent_id: agent_state.parent_id,
      depth: depth,
      objective: agent_state.objective,
      usage: state.usage,
      archive: agent_state.archive,
      compression_count: agent_state.compression_count,
      repo_id: agent_state.repo_id,
      repo_root: agent_state.repo_root,
      llm_model: agent_state.llm_model,
      model_id: agent_state.model_id,
      llm_generation_params: agent_state.llm_generation_params,
      max_turns: agent_state.max_turns,
      max_retries: agent_state.max_retries,
      max_agent_depth: agent_state.max_depth,
      foreign_repos: agent_state.foreign_repos,
      compression_threshold: EvoGit.Config.resolve([:llm, :compression_threshold_tokens]),
      agent_type: agent_type_from_module(state.agent_module),
      context_node_path: state.node_path
    )
  end

  @doc false
  def process_regular_tool_calls(tool_calls, %LoopState{} = state, subagent_modules) do
    # 1. Index: Attach index to each call
    indexed_calls = Enum.with_index(tool_calls)

    # 3. Split: Partition into subagent and standard calls
    {indexed_subagent_calls, indexed_standard_calls} =
      Enum.split_with(indexed_calls, fn {call, _index} ->
        SubagentSchemas.subagent_module_for(ReqLLM.ToolCall.name(call), subagent_modules) != nil
      end)

    # 4. Batch: Process each batch
    indexed_standard_results = process_standard_calls(indexed_standard_calls, state)

    {indexed_subagent_results, merge_message, subagent_usage} =
      EvoGit.Agent.SubagentProcessing.process_subagent_calls(
        indexed_subagent_calls,
        state,
        sync_commit_fn: &sync_current_commit_after_tools/1
      )

    # 5. Re-sort: Merge and sort by index to restore original order
    all_indexed_results = indexed_subagent_results ++ indexed_standard_results
    sorted_results = Enum.sort_by(all_indexed_results, &elem(&1, 0))

    # Validate that we have the same number of results as tool calls
    if length(sorted_results) != length(indexed_calls) do
      Logger.error(
        "Agent #{state.agent_id}: Tool call count mismatch! Expected #{length(indexed_calls)} results, got #{length(sorted_results)}. " <>
          "This will cause API errors."
      )
    end

    all_results =
      Enum.map(sorted_results, fn {_index, tool_call_id, name, output} ->
        assemble_tool_result(tool_call_id, name, output)
      end)

    all_results =
      if merge_message do
        all_results ++ [user(merge_message)]
      else
        all_results
      end

    {:continue, all_results, subagent_usage}
  end

  @doc false
  def process_standard_calls(indexed_calls, %LoopState{} = state) do
    repo_root =
      Process.get(:genesis_repo_root) || raise "genesis_repo_root not in process dictionary"

    indexed_results =
      batch_execute_tools(
        indexed_calls,
        EvoGit.Agent.DelegationHints.max_tool_timeout(),
        repo_root,
        state.delegation_level,
        # The RECEIVING role: the read-delegation nudge names only the subagent
        # tools this role can actually spawn (its `subagent_modules/0`).
        state.agent_module
      )

    # Sync current_commit after tool execution for dashboard visibility
    sync_current_commit_after_tools(state)

    indexed_results
  end

  @doc false
  def batch_execute_tools(
        indexed_calls,
        max_timeout,
        repo_root,
        delegation_level,
        agent_module \\ nil
      ) do
    agent_id = AgentScheduler.current_agent_id()
    repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

    # The OWNER identity every spawned tool task needs, resolved ONCE per batch
    # (this function always runs in the AGENT process, so `self()` IS the agent
    # pid) and threaded down to `execute_tool_task/7`, which re-installs it in
    # each tool task's process dictionary.
    #
    # The pid MUST be the AGENT's, never the tool task's: the tool `Task` is
    # shut down IMMEDIATELY after the tool returns
    # (`Task.yield(task, tool_timeout) || Task.shutdown(task)`), so anything
    # monitoring it — `EvoGit.BackgroundJobs` binds a detached job's lifetime to
    # its owner — would see an exit at once and kill the job on the spot. The
    # AGENT pid is the one lifetime signal that covers agent completion, crash,
    # graceful cancel and force-kill.
    owner = %{
      agent_id: agent_id,
      task_id: AgentScheduler.task_id_for_agent(agent_id),
      agent_pid: self()
    }

    {:ok, %{context_node: %{path: node_path}}} =
      AgentScheduler.get_agent_state(agent_id)

    threshold = EvoGit.Agent.DelegationHints.delegation_hint_threshold()
    initial_hints = Process.get(:delegation_hints, %{})

    read_threshold = EvoGit.Agent.DelegationHints.read_delegation_hint_threshold()
    read_initial_hints = Process.get(:read_delegation_hints, %{})

    # Cache conflict files once per batch to avoid repeated git calls
    conflict_files = cached_conflict_files(repo_path)

    ctx = %{
      owner: owner,
      repo_path: repo_path,
      repo_root: repo_root,
      node_path: node_path,
      max_timeout: max_timeout,
      delegation_level: delegation_level,
      # The receiving role module, used by the read-delegation nudge to name
      # only the subagent tools this role actually has.
      agent_module: agent_module,
      threshold: threshold,
      read_threshold: read_threshold,
      conflict_files: conflict_files,
      # Resolved once here (in the agent process, which owns the process dict)
      # and re-installed inside each spawned tool task so the per-task tmpdir
      # survives the `Task.async` boundary (spawned tasks do not inherit the
      # caller's process dictionary). `nil` is a harmless no-op.
      taskdir: EvoGit.TaskTmpdir.current()
    }

    # Partition the batch: tool calls that read-modify-write files
    # (`EvoGit.Agent.Tools.serial_tool?/1` — the single classification source of
    # truth) must NOT overlap each other, because each reads the ORIGINAL bytes
    # and the last write wins, silently discarding every other same-file edit in
    # the batch. Run them SEQUENTIALLY in this (parent agent) process, one call
    # at a time, in request order. Everything else stays concurrent below.
    #
    # The SERIAL phase runs FIRST, deliberately: a file mutation then always
    # lands BEFORE any read or shell command in the same batch that could
    # observe it, so `[write_file x.ex, run_bash "mix test"]` and
    # `[edit_file x, read_file x]` behave as the model expects. The reverse
    # order would let a same-batch read/exec observe stale bytes.
    {serial_calls, parallel_calls} =
      Enum.split_with(indexed_calls, fn {call, _index} ->
        EvoGit.Agent.Tools.serial_tool?(ReqLLM.ToolCall.name(call))
      end)

    serial_outputs =
      Enum.map(serial_calls, fn {call, index} -> run_tool_call(call, index, ctx) end)

    # Execute the remaining standard tool calls CONCURRENTLY, bounded only
    # by the scheduler's tool-slot pool: each parallel task still acquires a
    # tool slot via `AgentScheduler.with_tool_slot/2` inside
    # `execute_tool_with_timeout/8` (respecting `max_tool_concurrency`).
    # `max_concurrency` is set to the batch size so every call starts
    # immediately — Elixir's `max_concurrency` only accepts positive integers
    # (`:infinity` is valid for `timeout` only) — making the scheduler, not a
    # local cap, the binding constraint. `ordered: true` keeps results in index
    # order. `timeout: :infinity` defers timeout enforcement to the per-tool
    # timeout logic inside `execute_tool_with_timeout/8` (an outer stream
    # timeout would wrongly kill legitimate long-running tools).
    concurrency = max(1, length(parallel_calls))

    parallel_outputs =
      parallel_calls
      |> Task.async_stream(
        fn {call, index} -> run_tool_call(call, index, ctx) end,
        max_concurrency: concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, {%_{} = exception, stacktrace}} -> reraise(exception, stacktrace)
        {:exit, reason} -> exit(reason)
      end)

    # Both phases ran in request-independent order, so re-sort by index before
    # hint tracking: the LLM must receive results in request order.
    tool_outputs =
      (serial_outputs ++ parallel_outputs) |> Enum.sort_by(fn {index, _, _} -> index end)

    # Apply hint tracking in the PARENT process, in index order, so the
    # process-dictionary-backed delegation-hint maps and the once-per-run
    # redundant-cd warning accumulate deterministically (running them inside
    # the parallel tasks would make accumulation racy/non-deterministic).
    {results, final_hints, read_final_hints} =
      Enum.reduce(
        tool_outputs,
        {[], initial_hints, read_initial_hints},
        &apply_tool_output_tracking(&1, &2, ctx)
      )

    # Store updated hints in process dictionary for do_turn to pick up
    Process.put(:delegation_hints, final_hints)
    Process.put(:read_delegation_hints, read_final_hints)

    results
  end

  # Runs a single tool call's execution, returning `{index, call, output}`,
  # where `output` is `String.t() | %ToolOutput{} | nil` — a plain binary for an
  # all-text result (the legacy shape) and a `%ToolOutput{}` only when the tool
  # attached media. Used by BOTH batch phases: sequentially in the parent process
  # for the serial (file-mutating) group and inside the `Task.async_stream`
  # worker for the parallel group. Only the tool-execution call happens here —
  # hint tracking and the redundant-cd warning are applied later in the parent
  # process, in index order (see `apply_tool_output_tracking/3`).
  #
  # Arguments go through the tolerant three-stage parse
  # (`EvoGit.Agent.ToolInvocation.arguments/1`): a decoded JSON object is passed
  # to the tool layer, a non-blank but unparseable argument string is passed
  # through RAW (the tool layer answers with a self-correcting error), and when
  # nothing is recoverable the call is answered with a normal
  # `Error: invalid arguments: …` result. This is the fix for the crash path:
  # `ReqLLM.ToolCall.args_map/1` returns nil for undecodable arguments, and a
  # nil reaching `EvoGit.Agent.Tools.execute/5` (whose clauses are `is_map` /
  # `is_binary`) raised `FunctionClauseError` inside the LINKED tool task and
  # killed the whole agent instead of letting the model self-correct.
  defp run_tool_call(call, index, ctx) do
    name = ReqLLM.ToolCall.name(call)

    output =
      case ToolInvocation.arguments(call) do
        {:ok, args} ->
          execute_tool_with_timeout(
            name,
            args,
            ctx.owner,
            ctx.repo_path,
            ctx.repo_root,
            ctx.node_path,
            ctx.max_timeout,
            ctx.taskdir
          )

        {:error, reason} ->
          ToolInvocation.invalid_arguments_result(reason)
      end

    {index, call, output}
  end

  @doc false
  # Applies the redundant-cd warning and write/read delegation hints to one
  # tool output in the parent process, threading the hint maps through the
  # batch accumulator (index-ordered, deterministic).
  #
  # The wrap boundary lives here too: the redundant-cd warning preserves media,
  # while the delegation-hint modules are BINARY-ONLY, so the text component is
  # unwrapped, the hint appends run on it, and the (possibly extended) text is
  # re-attached with the media preserved (`ToolOutput.with_text/2`). An all-text
  # output never becomes a struct — `rewrap_output/2` returns the plain binary.
  def apply_tool_output_tracking({index, call, output}, {acc_results, hints, read_hints}, ctx) do
    name = ReqLLM.ToolCall.name(call)
    # TOTAL accessor: the tolerant parse may have handed a RAW string to the tool
    # layer (undecodable arguments), and the hint helpers are map-only.
    args = ToolInvocation.arguments_map(call)
    tool_call_id = call.id || name || "unknown"

    output =
      maybe_append_redundant_cd_warning(output, name, args, ctx.repo_path, ctx.repo_root)

    text = output_text(output)

    # Track delegation hints for write tools (skip during conflict resolution)
    {text, hints} = track_write_delegation_hint(text, hints, name, args, ctx)

    # Track read delegation hints for read tools (skip during conflict resolution)
    {text, read_hints} = track_read_delegation_hint(text, read_hints, name, args, ctx)

    output = rewrap_output(output, text)

    {acc_results ++ [{index, tool_call_id, name, output}], hints, read_hints}
  end

  # Returns the TEXT component of a tool output — the plain binary itself, or
  # `ToolOutput.text/1` for a media-carrying `%ToolOutput{}`. The sanitize /
  # truncation / hint pipeline is BINARY-ONLY and therefore always consumes this.
  defp output_text(%ToolOutput{} = output), do: ToolOutput.text(output)
  defp output_text(text), do: text

  # Re-attaches `text` to the SAME media set as `output`: a `%ToolOutput{}`
  # keeps its attachments (`ToolOutput.with_text/2`), while a plain binary (or
  # the legacy non-binary pass-through) is returned as-is.
  defp rewrap_output(%ToolOutput{} = output, text), do: ToolOutput.with_text(output, text)
  defp rewrap_output(_output, text), do: text

  # Runs a single tool call inside a tool slot with an async task, bounded
  # timeout, and output sanitization/truncation feedback.
  #
  # The per-call timeout rule lives in `EvoGit.Agent.ToolInvocation.resolve_timeout/4`:
  # an explicit `timeout` argument wins (clamped by `[:scheduler,
  # :max_tool_timeout]`), an OMITTED timeout on the platform shell tool
  # (`bash` / `run_bash` / `run_powershell` / `pwsh` / `shell` / …) gets a
  # generous 120 s default — the shell schema advertises a long timeout, so a
  # long test run that simply omits the argument must not be silently cut at the
  # generic 10 s `[:scheduler, :default_tool_timeout]` — and every other tool
  # keeps that configured default.
  #
  # The ADVERTISED-DEFAULT seam (`EvoGit.Agent.Tools.default_timeout_ms/1`) is
  # then applied on top: a tool that publishes its own default timeout for the
  # "model omitted the argument" case (today the platform shell tool's 120 s)
  # raises the resolved timeout to that value. It is a pure MAX — it can never
  # LOWER the resolved timeout, so `resolve_timeout/4`'s own shell fallback and
  # an explicit `timeout` argument are both unaffected — and it is clamped by
  # the same `max_timeout`.
  #
  # `owner` is the batch's resolved owner identity (`%{agent_id:, task_id:,
  # agent_pid:}` — see `batch_execute_tools/4`): the agent id is what the tool
  # slot pool is acquired under, and the WHOLE map is re-installed inside the
  # spawned task below.
  defp execute_tool_with_timeout(
         name,
         args,
         owner,
         repo_path,
         repo_root,
         node_path,
         max_timeout,
         taskdir
       ) do
    tool_timeout =
      ToolInvocation.resolve_timeout(
        name,
        args,
        EvoGit.Agent.DelegationHints.default_tool_timeout(),
        max_timeout
      )

    tool_timeout = apply_advertised_tool_timeout(tool_timeout, name, args, max_timeout)

    tool_timeout =
      if approval_window_tool_call?(name, args) do
        # A level-2/3 `run_command` call BLOCKS inside the command shell while
        # the user approves/denies it in the /help chat (EvoGit.CommandApproval,
        # app-env `[:evo_git, :command_approval_timeout]`, default 120s). The
        # 10s default per-call timeout would kill the task mid-wait, so give
        # approval-requiring calls a per-call timeout that covers the approval
        # window PLUS handler execution — still capped by the scheduler's
        # `max_tool_timeout` (30 min). Level-1 `run_command` calls keep their
        # exact current behavior.
        approval_timeout = EvoGit.CommandApproval.timeout()
        tool_timeout |> max(approval_timeout + @approval_execution_buffer) |> min(max_timeout)
      else
        tool_timeout
      end

    AgentScheduler.with_tool_slot(owner.agent_id, fn ->
      task =
        Task.async(fn ->
          execute_tool_task(
            name,
            args,
            repo_path,
            repo_root,
            node_path,
            taskdir,
            owner
          )
        end)

      case Task.yield(task, tool_timeout) || Task.shutdown(task) do
        {:ok, {:tool_crashed, message}} ->
          "Error: Tool execution crashed: #{message}"

        {:ok, {:error, reason}} ->
          "Error: #{inspect(reason)}"

        {:ok, result} ->
          # Wrap → sanitize → truncation-feedback → re-wrap, all in one place
          # (the wrap boundary — see `sanitize_tool_result/3`). A plain binary
          # return round-trips BYTE-IDENTICALLY; a media-carrying return keeps
          # its attachments.
          sanitize_tool_result(result, name, args)

        {:exit, reason} ->
          "Error: Tool execution crashed: #{inspect(reason)}"

        nil ->
          "Error: Tool execution timed out after #{tool_timeout}ms. Some output may have been partially captured by the tool."
      end
    end)
  end

  # Applies a tool's OWN advertised default timeout
  # (`EvoGit.Agent.Tools.default_timeout_ms/1`) to the resolved per-call timeout.
  #
  # Pure MAX + `max_timeout` clamp: `min(max(resolved, advertised), max_timeout)`.
  # It can only RAISE the resolved timeout, never lower it, so the platform-shell
  # 120 s fallback in `ToolInvocation.resolve_timeout/4` and a resolved value
  # that is already larger both survive untouched. An explicit `timeout`
  # argument (a positive integer under `"timeout"`) means the model asked for a
  # specific budget, so the advertised default does not apply — that is the same
  # "explicit wins" rule `resolve_timeout/4` implements.
  defp apply_advertised_tool_timeout(resolved, name, args, max_timeout) do
    case EvoGit.Agent.Tools.default_timeout_ms(name) do
      advertised when is_integer(advertised) and advertised > 0 ->
        if explicit_timeout_arg?(args) do
          resolved
        else
          resolved |> max(advertised) |> min(max_timeout)
        end

      _no_advertised_default ->
        resolved
    end
  end

  # True when `args` carries a usable explicit `timeout` (a positive integer).
  # TOTAL: the tolerant arguments parse can hand the dispatcher a RAW string, a
  # nil or anything else — only a map can declare a `timeout`.
  defp explicit_timeout_arg?(args) when is_map(args) do
    case Map.get(args, "timeout") do
      timeout when is_integer(timeout) and timeout > 0 -> true
      _absent_or_invalid -> false
    end
  end

  defp explicit_timeout_arg?(_args), do: false

  # The body of one tool-execution task. Runs INSIDE the `Task.async` (so it is
  # linked to the agent process) and therefore contains the failure containment
  # described below.
  #
  # `owner` is the batch's owner identity (`%{agent_id:, task_id:, agent_pid:}`
  # — resolved ONCE per batch in `batch_execute_tools/4`, in the agent process).
  defp execute_tool_task(
         name,
         args,
         repo_path,
         repo_root,
         node_path,
         taskdir,
         owner
       ) do
    # Spawned tasks do NOT inherit the caller's process dictionary, so
    # re-install the resolved per-task tmpdir unconditionally — every tool
    # that consults `EvoGit.Sandbox.resolve_tmpdir/0` (sandbox TMPDIR
    # injection, commit-message files, skill scripts, partial outputs)
    # must see the correct dir. A nil value is harmless (`current/0`
    # returns nil for a non-binary).
    EvoGit.TaskTmpdir.put_current(taskdir)

    # EVERY tool task gets the full owner identity (no `run_command` special
    # case):
    #
    #   * `:evogit_agent_pid` — the AGENT's pid, read by
    #     `EvoGit.BackgroundJobs.current_owner_pid/0` to bind a detached job's
    #     lifetime to its owner. It MUST be the agent pid, never `self()` here:
    #     this tool task is shut down the moment the tool returns
    #     (`Task.yield/2 || Task.shutdown/1`), so a job monitored on it would be
    #     killed instantly — the agent pid is the one lifetime signal covering
    #     agent completion, crash, graceful cancel and force-kill.
    #   * `:evogit_agent_id` / `:evogit_task_id` — read by the command-approval
    #     gate (`EvoGit.CommandShell.request_approval/3`) and by the
    #     task-control/background-job tools that report who acted.
    Process.put(:evogit_agent_id, owner.agent_id)
    Process.put(:evogit_task_id, owner.task_id)
    Process.put(:evogit_agent_pid, owner.agent_pid)

    # Reason for the try/rescue/catch: `Task.async/1` LINKS this task to the
    # agent process, so a RAISING tool implementation (a wrong-typed argument, an
    # unresolved executable inside a tool, a buggy custom tool) would kill the
    # whole agent before `Task.yield/2` could ever observe it — the caller's
    # `{:exit, reason}` arm is unreachable for raises, because the linked exit
    # signal is delivered directly and the agent does not trap exits. Containing
    # the failure HERE converts it into a normal tool result
    # (`Error: Tool execution crashed: …`) that the model can self-correct from
    # on the next turn. `:kill` (this module's own timeout shutdown) and the
    # `:shutdown`/`:normal` exit family are re-raised unchanged so a legitimate
    # task exit is never swallowed and still reaches the `{:exit, reason}` arm.
    try do
      EvoGit.Agent.Tools.execute(name, args, repo_path, repo_root, node_path)
    rescue
      exception ->
        {:tool_crashed, Exception.format_banner(:error, exception)}
    catch
      :exit, reason when reason in [:normal, :shutdown, :kill] ->
        exit(reason)

      :exit, {:shutdown, _} = reason ->
        exit(reason)

      kind, reason ->
        {:tool_crashed, "#{kind} #{inspect(reason)}"}
    end
  end

  # --- Multimodal tool output: wrap boundary ---

  @doc false
  # Finalizes a tool's raw return value for the tool-result message: wraps it
  # (`ToolOutput.wrap/1`), runs the BINARY-ONLY sanitize → truncation-feedback
  # pipeline on the TEXT component only, and re-attaches the sanitized text
  # while PRESERVING any media (`ToolOutput.with_text/2`).
  #
  # An all-text return (the shape every built-in tool produces today) comes back
  # as the plain sanitized BINARY — byte-identical to the legacy path, never
  # promoted to a `%ToolOutput{}`. A return carrying media comes back as a
  # `%ToolOutput{}` from which the media parts are materialized exactly once at
  # the message-construction site (`assemble_tool_result/3`).
  #
  # `nil` (a tool that legitimately returns nothing) stays `nil`. Any other
  # non-binary term is passed through verbatim to preserve the legacy
  # pass-through sanitizer behavior — no built-in tool returns one (the
  # `execute/5` contract is `String.t() | %ToolOutput.t() | {:error, reason}`,
  # and the error path is stringified upstream).
  def sanitize_tool_result(nil, _name, _args), do: nil

  def sanitize_tool_result(result, name, args)
      when is_binary(result) or is_struct(result, ToolOutput) do
    output = ToolOutput.wrap(result)

    sanitized =
      output
      |> ToolOutput.text()
      |> sanitize_and_append_truncation_feedback(name, args)

    output
    |> ToolOutput.with_text(sanitized)
    |> collapse_all_text_output()
  end

  def sanitize_tool_result(other, _name, _args), do: other

  # Runs the BINARY-ONLY sanitize → truncation-feedback pipeline on the text
  # component. Neither `OutputSanitizer` nor `TruncationFeedback` ever sees a
  # `%ToolOutput{}`.
  defp sanitize_and_append_truncation_feedback(text, name, args) do
    {sanitized, truncation_info} = OutputSanitizer.sanitize_and_truncate(text, name, args)

    EvoGit.Agent.TruncationFeedback.append_truncation_feedback(sanitized, truncation_info, name)
  end

  # A `%ToolOutput{}` carrying NO media collapses back to its plain text binary:
  # the all-text path must stay BYTE-IDENTICAL to the legacy string pipeline and
  # behave like a plain string for every downstream consumer. A media-carrying
  # output stays a struct.
  defp collapse_all_text_output(%ToolOutput{} = output) do
    if ToolOutput.media?(output), do: output, else: ToolOutput.text(output)
  end

  @doc false
  # Builds the `%ReqLLM.Message{}` for one tool result — the ONE
  # message-construction site that materializes a `%ToolOutput{}` into LLM
  # content parts (`ToolOutput.to_content_parts/1` → `[ContentPart.text(text) |
  # media parts…]`). An all-text output (a plain binary — the only shape the
  # legacy pipeline ever produced, plus subagent result strings) is passed
  # through as the plain BINARY string, so the resulting message is
  # BYTE-IDENTICAL to today's `ReqLLM.Context.tool_result(id, name, binary)`.
  def assemble_tool_result(tool_call_id, name, output) do
    case output do
      %ToolOutput{} = out ->
        if ToolOutput.media?(out) do
          tool_result(tool_call_id, name, ToolOutput.to_content_parts(out))
        else
          tool_result(tool_call_id, name, ToolOutput.text(out))
        end

      binary ->
        tool_result(tool_call_id, name, binary)
    end
  end

  # True when the tool call is a `run_command` whose command path has security
  # level >= 2 (EvoGit.CommandShell.security_level/1) — i.e. the command will
  # BLOCK awaiting interactive user approval inside the shell, so the per-call
  # timeout must cover the approval window plus execution. Cheap peek: the
  # command path is the first whitespace-delimited token of args["command"];
  # unparsable/unknown paths report level 1 (they fail dispatch fast).
  defp approval_window_tool_call?("run_command", %{"command" => command})
       when is_binary(command) do
    first_token = command |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd()
    EvoGit.CommandShell.security_level(first_token) >= 2
  end

  defp approval_window_tool_call?(_name, _args), do: false

  # Appends the write-tool delegation hint when the write threshold is
  # exceeded (skipped during conflict resolution).
  defp track_write_delegation_hint(output, hints, name, args, ctx) do
    if ctx.threshold > 0 do
      child_paths =
        EvoGit.Agent.DelegationHints.extract_child_paths(
          name,
          args,
          ctx.node_path,
          ctx.repo_path
        )

      child_paths =
        EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(
          child_paths,
          ctx.conflict_files
        )

      EvoGit.Agent.DelegationHints.maybe_append_delegation_hint(
        output,
        hints,
        child_paths,
        ctx.threshold
      )
    else
      {output, hints}
    end
  end

  # Appends the read-tool delegation hint when the read threshold is exceeded
  # (skipped during conflict resolution).
  defp track_read_delegation_hint(output, read_hints, name, args, ctx) do
    if ctx.read_threshold > 0 do
      read_child_paths =
        EvoGit.Agent.DelegationHints.extract_read_child_paths(
          name,
          args,
          ctx.node_path,
          ctx.repo_path
        )

      read_child_paths =
        EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(
          read_child_paths,
          ctx.conflict_files
        )

      EvoGit.Agent.DelegationHints.maybe_append_read_delegation_hint(
        output,
        read_hints,
        read_child_paths,
        ctx.read_threshold,
        ctx.delegation_level,
        ctx.agent_module
      )
    else
      {output, read_hints}
    end
  end

  # Caches conflict files once per batch to avoid repeated git calls.
  defp cached_conflict_files(repo_path) do
    case Git.conflict_files(repo_path) do
      {:ok, files} -> files
      _ -> []
    end
  end

  # --- Redundant CD Warning ---
  # The "you don't need to cd into your worktree" warning fires only once
  # per agent run (tracked via the process dictionary), unlike the
  # wrong-path cd warnings which fire every time.

  @doc false
  def maybe_append_redundant_cd_warning(output, name, args, repo_path, repo_root) do
    # ALIAS-AWARE: the model-facing shell tool name is `bash` while the internal
    # dispatch keys are `run_bash` / `run_powershell`, so compare through the
    # alias spine (`EvoGit.Agent.ToolNames`) instead of a hardcoded name list —
    # otherwise a `bash` call never reaches the warning.
    if EvoGit.Agent.ToolNames.normalize(name) == EvoGit.Agent.ToolNames.shell_tool_name() do
      command = Map.get(args, "command", "")

      if EvoGit.Agent.Tools.ShellTool.redundant_cd?(command, repo_path, repo_root) and
           not Process.get(:redundant_cd_warned, false) do
        Process.put(:redundant_cd_warned, true)

        append_output_text(
          output,
          "\n\n" <> EvoGit.Agent.Tools.ShellTool.redundant_cd_warning(repo_path)
        )
      else
        output
      end
    else
      output
    end
  end

  # Appends `suffix` to the TEXT component of a tool output while PRESERVING any
  # media: a `%ToolOutput{}` is unwrapped (`ToolOutput.text/1`), the suffix is
  # concatenated, and the result is re-attached (`ToolOutput.with_text/2`); a
  # plain binary stays a plain binary (the byte-identity invariant).
  defp append_output_text(%ToolOutput{} = output, suffix) do
    ToolOutput.with_text(output, ToolOutput.text(output) <> suffix)
  end

  defp append_output_text(binary, suffix) when is_binary(binary), do: binary <> suffix

  # --- Shared Helpers ---

  defp agent_type_from_module(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
