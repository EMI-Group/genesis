defmodule EvoGit.Agent.ContextCompression do
  @moduledoc """
  Two-stage context compression for the agent loop.

  When the conversation's reported token count passes the window-relative
  trigger, the transcript is relieved in TWO stages, cheapest first:

    1. **Stage 1 — model-free pruning**
       (`EvoGit.Agent.Compression.ToolResultPruner`): the TEXT of old `:tool`
       results is rewritten to head + marker + tail and old media parts collapse
       into one placeholder. NO LLM call. When the projected token count falls
       back under the trigger, this IS the whole compression — the main cost
       win.
    2. **Stage 2 — summarising checkpoint**
       (`EvoGit.Agent.Compression.Checkpoint`): only when pruning was not
       enough. The OLD span of the transcript (everything older than the last
       `EvoGit.Agent.Compression.Recency.default_keep_recent_turns/0` turns) is
       replaced by ONE checkpoint message carrying a summary written by the
       model from `EvoGit.Agent.Compression.SummaryPrompt.instruction/1`.

  ## Why two stages

  Summarising costs a full LLM call over the WHOLE transcript, and most of the
  pressure in a long agent run is raw tool output (build logs, `rg` dumps, file
  reads) the agent has already drawn its conclusion from. Shrinking that is
  free, so it is always tried first; only the residue pruning cannot remove —
  an enormous RECENT tail — is worth paying a summarising call for.

  ## What is never touched

  The system prompt and the original first user message (the provider's
  cacheable prefix) stay BYTE-IDENTICAL, and the last K turns stay VERBATIM
  (metadata, turn tags and `tool_call_id`/`tool_calls` pairing intact). Runtime
  context freshness is therefore delivered by APPENDING a refresh message
  (`EvoGit.Agent.ContextBuilder.build_context_refresh_message/2`) rather than
  rewriting message #1: a CONTEXT.md edit made in the worktree mid-run is
  visible again, and the cached prefix survives.

  ## Token reset

  After every compression event `total_tokens` is reset to 0. This prevents the
  stale high token count from triggering redundant compressions before the next
  LLM call updates the count.

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

  alias EvoGit.Agent.Compression.Checkpoint
  alias EvoGit.Agent.Compression.LlmRetry
  alias EvoGit.Agent.Compression.SummaryPrompt
  alias EvoGit.Agent.Compression.Threshold
  alias EvoGit.Agent.Compression.ToolResultPruner
  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.Cost
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler

  @doc """
  Attempts to compress the agent's chat context if it exceeds the token
  threshold.

  The threshold is window-relative: `EvoGit.Agent.Compression.Threshold.for_model/1`
  derives it from the model's own context window, falling back to
  `EvoGit.Config.resolve([:llm, :compression_threshold_tokens])` when the window
  is unknown.

  ## Options

    * `:agent_id` — the agent's ID (required, used for logging and LLM slot acquisition)
    * `:llm_model` — the model to use for the stage-2 summarising call (required)
    * `:llm_generation_params` — keyword list of LLM generation params (temperature, max_tokens, etc.) passed to ReqLLM (optional, defaults to [])

  ## Returns

    * `%LoopState{}` — the state with the compressed context (or the unchanged
      state when the threshold is not exceeded, when the message shape is not
      compressible, or when there was nothing to compact);
    * `{:error, {:llm_request_rejected, message}}` — the stage-2 LLM call was
      rejected with a NON-RETRYABLE provider error (see
      `EvoGit.Agent.LlmError`), so nothing was compacted and nothing was
      charged. This is the same terminal shape the main turn's fail-fast path
      uses; the caller (`EvoGit.Agent.Runner.loop/1`) propagates it out of
      `Runner.run/3` unchanged.

  Every OTHER stage-2 LLM failure (transient transport errors, 5xx, 402/429
  model exhaustion) still RAISES — see `do_compression_llm_call/6` — so the
  pre-existing crash-retry / scheduler-backoff semantics for those classes are
  unchanged. There is deliberately NO silent "fall back to the pruned context"
  degradation: the retained last-K-turns tail may itself exceed the window, so a
  silent fallback would just defer the overflow to the very next LLM request (a
  hard provider error) with no operator-visible signal.
  """
  @spec compress_if_needed(LoopState.t(), keyword()) ::
          LoopState.t() | {:error, {:llm_request_rejected, String.t()}}
  def compress_if_needed(%LoopState{} = state, opts \\ []) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    llm_model = Keyword.fetch!(opts, :llm_model)
    llm_gen_opts = Keyword.get(opts, :llm_generation_params, [])

    info = Threshold.for_model(llm_model)

    # Gate on the model's own window BEFORE doing any work: below the trigger
    # there is nothing to compress, so no log line and no LLM slot are spent.
    if Threshold.exceeded?(state.total_tokens, info) do
      case ReqLLM.Context.to_list(state.context) do
        # A compressible conversation always starts with [system, first_user];
        # any other shape (empty, a lone system message) is left alone.
        [_system, _first_user | _rest] = messages ->
          compress(agent_id, llm_model, llm_gen_opts, info, state, messages)

        _other ->
          state
      end
    else
      state
    end
  end

  # --- Orchestration ---

  defp compress(agent_id, llm_model, llm_gen_opts, info, state, messages) do
    # STAGE 1 — model-free. Always runs first: it is cheap, and when it is
    # enough it saves the entire summarising call.
    pruned = ToolResultPruner.prune(messages)
    projected = Threshold.project(state.total_tokens, pruned.chars_before, pruned.chars_after)

    Logger.info(
      "Agent #{agent_id}: Context length (#{state.total_tokens} tokens) exceeded the compression " <>
        "threshold (#{info.threshold} tokens, source: #{info.source}). Stage 1 pruned " <>
        "#{pruned.pruned} old tool result(s): #{pruned.chars_before} -> #{pruned.chars_after} chars " <>
        "(projected #{projected} tokens)."
    )

    # Pruning alone is enough: rebuild from the pruned list and spend nothing.
    if pruned.pruned > 0 and projected <= info.threshold do
      finish_pruned_only(state, agent_id, pruned.messages)
    else
      summarise(agent_id, llm_model, llm_gen_opts, pruned, state)
    end
  end

  # STAGE 2 — replace the old span with ONE checkpoint. Skipped entirely when
  # there is nothing older than the protected last-K-turns suffix: an LLM call
  # would have nothing to replace (`Checkpoint.build/3` would report
  # `replaced: 0`), so paying for it is pure waste.
  defp summarise(agent_id, llm_model, llm_gen_opts, pruned, state) do
    split = Checkpoint.split(pruned.messages)

    if split.old == [] do
      Logger.info(
        "Agent #{agent_id}: nothing older than the last " <>
          "#{length(split.recent)} message(s) to replace — stage 2 (summarising) skipped."
      )

      finish_pruned_only(state, agent_id, pruned.messages)
    else
      summarise_old_span(agent_id, llm_model, llm_gen_opts, pruned, state)
    end
  end

  defp summarise_old_span(agent_id, llm_model, llm_gen_opts, pruned, state) do
    # The summarising model reads the PRUNED transcript plus ONE appended
    # instruction message — never the raw list, so a huge old tool result is not
    # paid for twice. A prior checkpoint's summary is merged in so repeated
    # compactions ACCUMULATE instead of forgetting earlier facts.
    instruction = SummaryPrompt.instruction(Checkpoint.prior_summary(pruned.messages))

    context =
      ReqLLM.Context.new(pruned.messages ++ [ReqLLM.Context.user(instruction)])

    case LlmRetry.summarise(agent_id, llm_model, context, llm_gen_opts) do
      {:ok, response} ->
        summary = ReqLLM.Response.text(response)
        # Read the usage map ONCE — it feeds both the token counts
        # (`Usage.from_response_usage/1`) and the self-computed cost.
        usage_map = ReqLLM.Response.usage(response)
        built = Checkpoint.build(pruned.messages, summary, turn: state.turn)

        compression_usage =
          Usage.from_response_usage(usage_map)
          |> Cost.apply_to_usage(usage_map, agent_id)

        if built.replaced == 0 do
          # A blank summary must never fabricate a checkpoint that silently
          # drops the transcript, so the pruned context is what we keep — but
          # the request WAS billed, so its usage is still accounted for.
          keep_pruned_context(state, agent_id, pruned.messages, compression_usage)
        else
          context = built.messages ++ refresh_messages(state)

          AgentScheduler.increment_compression_count(agent_id)

          %{
            state
            | context: ReqLLM.Context.new(context),
              total_tokens: 0,
              usage: Usage.add(state.usage, compression_usage)
          }
        end

      {:error, {:llm_request_rejected, message}} = terminal ->
        # Fail fast EXACTLY like `ToolDispatch.handle_llm_failure/7`'s fail-fast
        # branch: ONE `Logger.error` line naming the agent, NO scheduler
        # backoff report, NO sleep. The terminal tuple is returned unchanged for
        # `Runner.loop/1` to propagate.
        Logger.error("Agent #{agent_id}: #{message}")

        terminal
    end
  end

  # The prune-only finish shared by (a) "pruning was enough", (b) "nothing older
  # than the recent tail to replace" and (c) "the summary came back blank". The
  # messages are NOT shortened by this stage, so the context is only rebuilt
  # with the pruned tool text plus the runtime-context refresh appended.
  defp finish_pruned_only(state, agent_id, messages) do
    keep_pruned_context(state, agent_id, messages, nil)
  end

  defp keep_pruned_context(state, agent_id, messages, compression_usage) do
    AgentScheduler.increment_compression_count(agent_id)

    usage =
      case compression_usage do
        nil -> state.usage
        spent -> Usage.add(state.usage, spent)
      end

    %{
      state
      | context: ReqLLM.Context.new(messages ++ refresh_messages(state)),
        total_tokens: 0,
        usage: usage
    }
  end

  # The runtime-context refresh message appended as the LAST message of every
  # compression event, so a CONTEXT.md edit made in the worktree mid-run is
  # visible again WITHOUT rewriting the cacheable first message. `nil` (blank
  # context block) appends nothing.
  defp refresh_messages(state) do
    case ContextBuilder.build_context_refresh_message(state, state.turn) do
      nil -> []
      message -> [message]
    end
  end

  # --- Stage-2 LLM call ---

  # The bounded retry loop, the slot-per-attempt discipline and the failure
  # classification live in `EvoGit.Agent.Compression.LlmRetry` (mirroring
  # `EvoGit.Agent.ToolDispatch.call_llm_with_retry/5` exactly). Two outcomes
  # matter to this module: `{:ok, response}` to build the checkpoint, and the
  # terminal `{:error, {:llm_request_rejected, message}}` for a NON-RETRYABLE
  # provider rejection. Every other failure class RAISES out of there, preserving
  # the pre-existing crash-retry / scheduler-backoff semantics.
  @doc """
  The stage-2 summarisation instruction (backward-compatible entry point).

  Delegates to `EvoGit.Agent.Compression.SummaryPrompt.instruction/0` — the
  single source of the eight fixed summary sections — so callers that only need
  the instruction text keep working.
  """
  @spec compression_instruction() :: String.t()
  def compression_instruction, do: SummaryPrompt.instruction()
end
