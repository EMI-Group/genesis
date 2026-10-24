defmodule EvoGit.Agent.ContextCompression do
  @moduledoc """
  Two-stage context compression for the agent loop.

  When the conversation's reported token count passes the configured
  window-relative trigger, the transcript is relieved in TWO stages, cheapest
  first:

    1. **Stage 1 — model-free pruning**
       (`EvoGit.Agent.Compression.ToolResultPruner`): the TEXT of old `:tool`
       results is rewritten to head + marker + tail and old media parts collapse
       into one placeholder. NO LLM call.
    2. **Stage 2 — summarising checkpoint**
       (`EvoGit.Agent.Compression.Checkpoint`): the OLD span of the transcript
       (everything older than the last
       `EvoGit.Agent.Compression.Recency.default_keep_recent_turns/0` turns) is
       replaced by ONE checkpoint message carrying a summary written by the
       model from `EvoGit.Agent.Compression.SummaryPrompt.instruction/1`.

  ## Stage 1 is gated hard — it must recover a LOT

  Stage 1 exists for ONE situation: the agent accidentally read a lot of huge
  text (a build log, an `rg` dump, a file read it drew one conclusion from).
  Rewriting those old tool results changes the transcript, so it INVALIDATES the
  provider's prefix cache for the rest of the run; a prune that saves a little is
  therefore a net loss.

  Consequently pruning is adopted ONLY when it pruned something AND the projected
  token count lands at or under the Stage-1 target — a fraction of the configured
  window (`EvoGit.Agent.Compression.Threshold.pruning_target/2`, default
  `0.5` of the window) — AND it actually reduced the reported count. Anything
  less falls through to Stage 2 instead of adopting the prune.

  ## Stage 2 deliberately reads the ORIGINAL transcript

  Stage 2 pays for a full summarising request, and it sends the ORIGINAL,
  un-pruned message list rather than a pruned one. Pruning the request body would
  make that request cheaper but would feed the summariser the very information
  the summary is supposed to preserve — so the larger request is the deliberate
  choice: information loss is worse than one bigger call. The pruned list is used
  ONLY as the adopted result of Stage 1.

  ## What is never touched

  The system prompt and the original first user message (the provider's
  cacheable prefix) stay BYTE-IDENTICAL, and the last K turns stay VERBATIM
  (metadata, turn tags and `tool_call_id`/`tool_calls` pairing intact). Runtime
  context freshness is therefore delivered by APPENDING a refresh message
  (`EvoGit.Agent.ContextBuilder.build_context_refresh_message/2`) rather than
  rewriting message #1: a CONTEXT.md edit made in the worktree mid-run is
  visible again, and the cached prefix survives.

  The refresh message carries the agent's LIVE background shell jobs
  (`EvoGit.Agent.BackgroundJobNotice.section/1`, snapshot injected in
  `refresh_messages/2`) ONLY on the summarising path, where the old span — the
  job's only other trace — is about to be replaced by a summary. The prune-only
  path appends the same plain runtime-context refresh with NO jobs section. On
  the summarising path every earlier refresh message that carries a
  `## Background Jobs` section is dropped before the new one is appended
  (`drop_stale_background_job_refreshes/1`), so exactly ONE section — the
  CURRENT snapshot — survives a compression, even when an older snapshot sits
  inside the protected recent tail.

  ## Token reset

  After every compression event `total_tokens` is reset to 0. This prevents the
  stale high token count from triggering redundant compressions before the next
  LLM call updates the count.

  ## Usage

  Called at the top of every `EvoGit.Agent.Runner.loop/1` iteration to check if
  compression is needed:

      case EvoGit.Agent.ContextCompression.compress_if_needed(state,
             agent_id: state.agent_id,
             llm_model: EvoGit.Agent.ToolDispatch.current_model(),
             llm_context_window: EvoGit.Agent.ToolDispatch.current_context_window()
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

  The threshold is window-relative: `EvoGit.Agent.Compression.Threshold.for_model/2`
  derives it from the CONFIGURED context window (`:llm_context_window`), with
  `[:llm, :compression_threshold_tokens]` acting as an optional explicit
  override.

  ## Options

    * `:agent_id` — the agent's ID (required, used for logging and LLM slot acquisition)
    * `:llm_model` — the model to use for the stage-2 summarising call (required;
      also the source of the catalog output reservation)
    * `:llm_context_window` — the configured context window in tokens (optional;
      defaults to `EvoGit.Config.Schema.LLM.default_context_window/0` = 200_000)
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
  model exhaustion) still RAISES — see `EvoGit.Agent.Compression.LlmRetry` — so
  the pre-existing crash-retry / scheduler-backoff semantics for those classes
  are unchanged. There is deliberately NO silent "fall back to the pruned
  context" degradation: the retained last-K-turns tail may itself exceed the
  window, so a silent fallback would just defer the overflow to the very next
  LLM request (a hard provider error) with no operator-visible signal.
  """
  @spec compress_if_needed(LoopState.t(), keyword()) ::
          LoopState.t() | {:error, {:llm_request_rejected, String.t()}}
  def compress_if_needed(%LoopState{} = state, opts \\ []) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    llm_model = Keyword.fetch!(opts, :llm_model)
    llm_gen_opts = Keyword.get(opts, :llm_generation_params, [])

    llm_context_window =
      Keyword.get(
        opts,
        :llm_context_window,
        EvoGit.Config.Schema.LLM.default_context_window()
      )

    info = Threshold.for_model(llm_model, context_window: llm_context_window)

    # Gate on the configured window BEFORE doing any work: below the trigger
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
    target = Threshold.pruning_target(info, pruning_target_fraction())

    Logger.info(
      "Agent #{agent_id}: Context length (#{state.total_tokens} tokens) exceeded the compression " <>
        "threshold (#{info.threshold} tokens, source: #{info.source}, window: " <>
        "#{Map.get(info, :window)} tokens). Stage 1 target: #{target} tokens."
    )

    if tool_result_pruning_enabled?() do
      prune_or_summarise(agent_id, llm_model, llm_gen_opts, info, target, state, messages)
    else
      Logger.info(
        "Agent #{agent_id}: stage 1 (tool-result pruning) disabled by config — stage 2 " <>
          "(summarising) runs over the ORIGINAL #{length(messages)} message(s)."
      )

      summarise(agent_id, llm_model, llm_gen_opts, state, messages)
    end
  end

  # STAGE 1 — model-free. Adopted only when it recovered a LOT: pruning rewrites
  # history and therefore invalidates the provider's cached prefix, so a small
  # saving is not worth it. Otherwise Stage 2 runs over the ORIGINAL list.
  defp prune_or_summarise(agent_id, llm_model, llm_gen_opts, info, target, state, messages) do
    pruned = ToolResultPruner.prune(messages)
    projected = Threshold.project(state.total_tokens, pruned.chars_before, pruned.chars_after)

    if adopt_pruned?(pruned, projected, target, state.total_tokens) do
      Logger.info(
        "Agent #{agent_id}: stage 1 adopted — pruned #{pruned.pruned} old tool result(s): " <>
          "#{pruned.chars_before} -> #{pruned.chars_after} chars (projected #{projected} tokens, " <>
          "target #{target} tokens ≤ threshold #{info.threshold} tokens). " <>
          "Keeping the pruned context; no LLM call."
      )

      keep_context(state, agent_id, pruned.messages, nil, false)
    else
      Logger.info(
        "Agent #{agent_id}: stage 1 rejected — pruned #{pruned.pruned} old tool result(s): " <>
          "#{pruned.chars_before} -> #{pruned.chars_after} chars (projected #{projected} tokens, " <>
          "target #{target} tokens, current #{state.total_tokens} tokens). " <>
          "Stage 2 (summarising) runs over the ORIGINAL context."
      )

      summarise(agent_id, llm_model, llm_gen_opts, state, messages)
    end
  end

  # Adoption needs ALL THREE: something was actually pruned, the projection
  # reached the Stage-1 target, and the reported count really came down.
  defp adopt_pruned?(pruned, projected, target, total_tokens) do
    pruned.pruned > 0 and projected <= target and projected < total_tokens
  end

  # STAGE 2 — replace the old span with ONE checkpoint. Skipped entirely when
  # there is nothing older than the protected last-K-turns suffix: an LLM call
  # would have nothing to replace (`Checkpoint.build/3` would report
  # `replaced: 0`), so paying for it is pure waste.
  defp summarise(agent_id, llm_model, llm_gen_opts, state, messages) do
    split = Checkpoint.split(messages)

    if split.old == [] do
      Logger.info(
        "Agent #{agent_id}: nothing older than the last " <>
          "#{length(split.recent)} message(s) to replace — stage 2 (summarising) skipped."
      )

      finish_without_checkpoint(state, agent_id, messages)
    else
      summarise_old_span(agent_id, llm_model, llm_gen_opts, state, messages)
    end
  end

  defp summarise_old_span(agent_id, llm_model, llm_gen_opts, state, messages) do
    # The summarising model reads the ORIGINAL transcript plus ONE appended
    # instruction message. Deliberately NOT the pruned list: pruning would make
    # this request cheaper but would hide from the summariser exactly what the
    # summary must preserve. A prior checkpoint's summary is merged in so
    # repeated compactions ACCUMULATE instead of forgetting earlier facts.
    instruction = SummaryPrompt.instruction(Checkpoint.prior_summary(messages))

    context = ReqLLM.Context.new(messages ++ [ReqLLM.Context.user(instruction)])

    case LlmRetry.summarise(agent_id, llm_model, context, llm_gen_opts) do
      {:ok, response} ->
        summary = ReqLLM.Response.text(response)
        # Read the usage map ONCE — it feeds both the token counts
        # (`Usage.from_response_usage/1`) and the self-computed cost.
        usage_map = ReqLLM.Response.usage(response)
        built = Checkpoint.build(messages, summary, turn: state.turn)

        compression_usage =
          Usage.from_response_usage(usage_map)
          |> Cost.apply_to_usage(usage_map, agent_id)

        if built.replaced == 0 do
          # A blank summary must never fabricate a checkpoint that silently
          # drops the transcript, so the ORIGINAL context is what we keep — but
          # the request WAS billed, so its usage is still accounted for.
          keep_context(state, agent_id, messages, compression_usage, true)
        else
          rebuilt =
            drop_stale_background_job_refreshes(built.messages) ++
              refresh_messages(state, true)

          AgentScheduler.increment_compression_count(agent_id)

          %{
            state
            | context: ReqLLM.Context.new(rebuilt),
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

  # The no-checkpoint finish shared by (a) "nothing older than the recent tail
  # to replace" and (b) "the summary came back blank". The messages are the
  # ORIGINAL list, so the context is only rebuilt with the runtime-context
  # refresh appended — on this summarising path that refresh carries the CURRENT
  # background-job snapshot, and any earlier snapshot is dropped first.
  defp finish_without_checkpoint(state, agent_id, messages) do
    keep_context(state, agent_id, messages, nil, true)
  end

  # Rebuilds the context with the runtime-context refresh appended as the last
  # message. `include_background_jobs?` is true ONLY on the summarising path:
  # there the old span (which may hold the job's only other trace) is being
  # replaced, so the CURRENT snapshot must be re-injected and stale ones dropped.
  # The prune-only path keeps the pre-existing plain refresh.
  defp keep_context(state, agent_id, messages, compression_usage, include_background_jobs?) do
    AgentScheduler.increment_compression_count(agent_id)

    usage =
      case compression_usage do
        nil -> state.usage
        spent -> Usage.add(state.usage, spent)
      end

    rebuilt =
      if include_background_jobs? do
        drop_stale_background_job_refreshes(messages) ++ refresh_messages(state, true)
      else
        messages ++ refresh_messages(state, false)
      end

    %{
      state
      | context: ReqLLM.Context.new(rebuilt),
        total_tokens: 0,
        usage: usage
    }
  end

  # The runtime-context refresh message appended as the LAST message of every
  # compression event, so a CONTEXT.md edit made in the worktree mid-run is
  # visible again WITHOUT rewriting the cacheable first message. `nil` (blank
  # context block) appends nothing.
  #
  # When `include_background_jobs?` is true the live background-job snapshot is
  # injected into the state map here (the agent process IS the job owner pid),
  # because a background shell job outlives the tool call that started it and its
  # only other trace is the transcript span that compression just summarised
  # away. `snapshot/1` is a non-reconciling state read that answers `[]` when the
  # registry is down, so a registry hiccup can never fail a compression.
  defp refresh_messages(state, include_background_jobs?) do
    refreshed_state =
      if include_background_jobs? do
        Map.put(state, :background_jobs, EvoGit.BackgroundJobs.snapshot(owner_pid: self()))
      else
        state
      end

    case ContextBuilder.build_context_refresh_message(refreshed_state, state.turn) do
      nil -> []
      message -> [message]
    end
  end

  # The exact section marker rendered by
  # `EvoGit.Agent.BackgroundJobNotice.section/1`.
  @background_jobs_marker "## Background Jobs"

  @doc false
  # Drops every runtime-context refresh message that carries a
  # `## Background Jobs` section, preserving the ORDER and every non-matching
  # message (system prompt, first user message, checkpoint, recent tail, tool
  # messages, `[NOTICE]` messages). TOTAL: a non-list input is returned as-is,
  # and a malformed message simply never matches.
  @spec drop_stale_background_job_refreshes([term()]) :: [term()]
  def drop_stale_background_job_refreshes(messages) when is_list(messages) do
    Enum.reject(messages, &stale_background_job_refresh?/1)
  end

  def drop_stale_background_job_refreshes(messages), do: messages

  defp stale_background_job_refresh?(message) do
    ContextBuilder.refresh_message?(message) and
      String.contains?(message_text(message), @background_jobs_marker)
  end

  # The `:text` content parts of a message, joined. Total over malformed shapes.
  defp message_text(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join("")
  end

  defp message_text(_message), do: ""

  # --- Stage-1 gating config ---

  # Anything that is not an explicit `false` keeps pruning enabled: the key's
  # schema default is `true` and a nil/unreadable value must not silently change
  # the pipeline.
  defp tool_result_pruning_enabled? do
    case EvoGit.Config.resolve([:llm, :tool_result_pruning]) do
      false -> false
      _other -> true
    end
  end

  defp pruning_target_fraction do
    EvoGit.Config.resolve([:llm, :tool_result_pruning_target_fraction])
  end

  @doc """
  The stage-2 summarisation instruction (backward-compatible entry point).

  Delegates to `EvoGit.Agent.Compression.SummaryPrompt.instruction/0` — the
  single source of the eight fixed summary sections — so callers that only need
  the instruction text keep working.
  """
  @spec compression_instruction() :: String.t()
  def compression_instruction, do: SummaryPrompt.instruction()
end
