defmodule EvoGit.Agent.ContextCompression do
  @moduledoc """
  Context compression for the agent loop.

  When the conversation context exceeds the token threshold, this module
  compresses the interaction history into a dense summary using an LLM call.
  This prevents context window overflow while preserving essential progress
  information.

  ## Cache Reuse

  The original message list is preserved and the compression instruction is
  appended as a new user message. This allows the LLM provider to reuse its
  cached prefix from previous turns, significantly improving cache hit rate
  and reducing latency/cost.

  ## Token Reset

  After a successful compression, `total_tokens` is reset to 0. This prevents
  the stale high token count from triggering redundant compressions before
  the next LLM call updates the count.

  ## Usage

  Called at the top of every `EvoGit.Agent.Runner.loop/1` iteration to check if
  compression is needed:

      case EvoGit.Agent.ContextCompression.compress_if_needed(state,
             agent_id: state.agent_id,
             llm_model: EvoGit.Agent.ToolDispatch.current_model()
           ) do
        %EvoGit.Agent.LoopState{} = state ->
          # continue the turn with the compressed (or unchanged) state

        {:error, {:llm_request_rejected, _message} = terminal} ->
          # propagate the terminal error out of the agent run
          {:error, terminal}
      end
  """

  require Logger

  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler

  @doc """
  Attempts to compress the agent's chat context if it exceeds the token threshold.

  The threshold is read from `EvoGit.Config.resolve([:llm, :compression_threshold_tokens])` which resolves from user config.

  ## Options

    * `:agent_id` — the agent's ID (required, used for logging and LLM slot acquisition)
    * `:llm_model` — the model to use for the compression LLM call (required)
    * `:llm_generation_params` — keyword list of LLM generation params (temperature, max_tokens, etc.) passed to ReqLLM (optional, defaults to [])

  ## Returns

    * `%LoopState{}` — the state with the compressed context (or the unchanged
      state when the threshold is not exceeded);
    * `{:error, {:llm_request_rejected, message}}` — the compression LLM call
      was rejected with a NON-RETRYABLE provider error (see
      `EvoGit.Agent.LlmError`), so nothing was compressed and nothing was
      charged. This is the same terminal shape the main turn's fail-fast path
      uses; the caller (`EvoGit.Agent.Runner.loop/1`) propagates it out of
      `Runner.run/3` unchanged.

  Every OTHER LLM failure (transient transport errors, 5xx, 402/429 model
  exhaustion) still RAISES — the pre-existing crash-retry / scheduler-backoff
  semantics for those classes are unchanged.
  """
  @spec compress_if_needed(LoopState.t(), keyword()) ::
          LoopState.t() | {:error, {:llm_request_rejected, String.t()}}
  def compress_if_needed(%LoopState{} = state, opts \\ []) do
    threshold = EvoGit.Config.resolve([:llm, :compression_threshold_tokens])
    agent_id = Keyword.fetch!(opts, :agent_id)
    llm_model = Keyword.fetch!(opts, :llm_model)
    llm_gen_opts = Keyword.get(opts, :llm_generation_params, [])

    if state.total_tokens > threshold do
      Logger.info(
        "Agent #{agent_id}: Context length (#{state.total_tokens} tokens) exceeded compression threshold (#{threshold} tokens). Attempting compression..."
      )

      messages = ReqLLM.Context.to_list(state.context)

      case messages do
        [system_msg, initial_user_msg | _rest] ->
          compression_instruction = compression_instruction()

          compression_context =
            state.context
            |> ReqLLM.Context.append(ReqLLM.Context.user(compression_instruction))

          # The compression LLM call. A NON-RETRYABLE provider rejection is the
          # ONE error class that does NOT raise (see `compression_llm_call/3`);
          # every other failure still raises exactly as it did when the call was
          # inlined here, so the agent loop's restart logic (AgentScheduler
          # retry) handles those unchanged. No silent degradation to
          # uncompressed state on either path.
          AgentScheduler.with_llm_slot(agent_id, fn ->
            case compression_llm_call(llm_model, compression_context, llm_gen_opts) do
              {:ok, response} ->
                text = ReqLLM.Response.text(response)

                summary_msg =
                  ReqLLM.Context.user("Summary of previous events:\n" <> text)
                  |> EvoGit.Agent.ContextBuilder.tag_message_timestamp()

                new_context = ReqLLM.Context.new([system_msg, initial_user_msg, summary_msg])
                AgentScheduler.increment_compression_count(agent_id)

                %{
                  state
                  | context: new_context,
                    total_tokens: 0,
                    usage:
                      Usage.add(
                        state.usage,
                        Usage.from_response_usage(ReqLLM.Response.usage(response))
                      )
                }

              {:error, {:llm_request_rejected, message}} = terminal ->
                # Fail fast EXACTLY like `ToolDispatch.handle_llm_failure/7`'s
                # fail-fast branch: ONE `Logger.error` line naming the agent, NO
                # scheduler backoff report, NO sleep. The terminal tuple is
                # returned unchanged for `Runner.loop/1` to propagate.
                Logger.error("Agent #{agent_id}: #{message}")

                terminal
            end
          end)

        _ ->
          state
      end
    else
      state
    end
  end

  # Runs the compression LLM call (stream + process-stream) and returns
  # `{:ok, response}` on success.
  #
  # A NON-RETRYABLE provider rejection
  # (`EvoGit.Agent.LlmError.non_retryable?/1` — a deterministic 4xx such as
  # Z.AI's HTTP 400 code 1210) is a narrow exception layered ON TOP of the
  # pre-existing raise path: the request can never succeed on a retry, so
  # returning the terminal `{:error, {:llm_request_rejected, message}}` — the
  # SAME shape `ToolDispatch.handle_llm_failure/7` uses — lets the task be
  # persisted `:failed` with the actionable message instead of crash-retrying
  # through the identical doomed call.
  #
  # EVERY other error class (transient transport errors, 5xx, 402/429 model
  # exhaustion) keeps the behaviour of the previously inlined
  # `{:ok, _} = ReqLLM...` matches: the same `MatchError` with the same
  # right-hand-side value is raised, so the existing crash-retry +
  # scheduler-backoff semantics are untouched.
  #
  # There is deliberately NO try/rescue here: exceptions (e.g.
  # `{:error, :cancelled}` from a force-kill slot purge inside
  # `AgentScheduler.with_llm_slot/2`) still propagate immediately.
  defp compression_llm_call(llm_model, context, llm_gen_opts) do
    with {:ok, stream_response} <- ReqLLM.stream_text(llm_model, context, llm_gen_opts),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response) do
      {:ok, response}
    else
      {:error, reason} = failure ->
        if EvoGit.Agent.LlmError.non_retryable?(reason) do
          # The compression call sends NO tools, so the parameter names are the
          # generation-param keys alone; the model spec is the one this call
          # targeted. Both come from the caller's own arguments (no scheduler
          # lookup, so this path cannot raise for a purged agent either).
          message =
            EvoGit.Agent.LlmError.format_failure(reason,
              params: llm_gen_opts,
              model: llm_model
            )

          {:error, {:llm_request_rejected, message}}
        else
          raise_match_error(failure)
        end

      other ->
        raise_match_error(other)
    end
  end

  # Re-produces the pre-change raise-on-match behaviour for every result that is
  # NOT a fail-fast provider rejection (and for any unexpected shape): the
  # inlined `{:ok, _} = ...` matches raised a `MatchError` carrying the unmatched
  # right-hand-side value, and `raise MatchError, term: value` renders exactly
  # that exception and message. Pure, total, never returns.
  defp raise_match_error(value) do
    raise MatchError, term: value
  end

  @doc false
  @spec compression_instruction() :: String.t()
  def compression_instruction do
    """
    <context_compression>
    Review the conversation above and create a dense, comprehensive summary that preserves all information needed to continue the work without loss.

    PRESERVE THESE EXACTLY (never paraphrase):
    - Necessary File paths, module names, function names, variable names
    - Necessary Configuration values and settings
    - Critical Error messages and stack traces at hand
    - Architectural decisions and their reasoning

    SUMMARIZE THESE:
    - Tool call results (preserve conclusions, drop raw output)
    - Code explorations (preserve findings, drop search syntax)
    - Multi-step reasoning (preserve conclusions, drop intermediate steps)
    - Conversational exchanges (preserve decisions, drop pleasantries)

    DISCARD COMPLETELY:
    - Acknowledgments, greetings, filler phrases
    - Repeated or redundant information
    - Raw tool syntax/JSON that isn't essential

    The original objective is preserved verbatim in the first user message above. Do NOT reproduce, restate, or paraphrase it in your summary. Reference it directly when needed.

    First, silently identify the most critical information. Then output a structured summary using EXACTLY this format:

    ## Current State
    [Your current state within the overall objective: what major milestones/parts are complete, what remains to be done, and what you should focus on next. This MUST reflect ALL work done across the entire session — not just recent work.]

    ## Completed
    [Bulleted list of what has been done. If possible, include the node paths or file paths where work was completed.]

    ## Key Findings
    [Important discoveries, constraints, dependencies found. Include exact names and paths.]

    ## Decisions Made
    [Architectural or design decisions with their rationale.]

    ## SubAgents Dispatched
    [Which subagents were spawned, their objectives, and their outcomes.]

    ## Errors Encountered
    [Failed approaches, bugs found, blockers. Include exact error messages and what was tried.]

    ## Next Steps
    [Precise, actionable next steps. Reference specific files and functions.]

    CRITICAL: You are working on the SAME original objective as when you started — it is preserved verbatim in the first user message above. Do NOT drift, redefine, narrow, or expand the objective. If your current work seems disconnected from the original objective, STOP and realign to it.

    IMPORTANT: When you eventually call complete_task, your final report MUST summarize the status of the ORIGINAL objective as a whole (refer to the first user message and "Current State" above) — NOT just the most recent sub-task you worked on.
    </context_compression>
    """
  end
end
