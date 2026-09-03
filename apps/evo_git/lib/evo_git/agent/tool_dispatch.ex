defmodule EvoGit.Agent.ToolDispatch do
  @moduledoc """
  Core tool-execution and LLM-turn logic extracted from `EvoGit.Agent.__using__/1`.

  Handles the main agent turn cycle: LLM call with retry, tool-call processing
  (complete vs regular, subagent vs standard), batching, timeout management,
  output sanitization, and redundant-cd warnings.
  """

  require Logger
  use Retry

  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Tools.CompleteTask
  alias EvoGit.Agent.OutputSanitizer
  alias EvoGit.Agent.SubagentSchemas
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler

  import ReqLLM.Context, only: [user: 1, tool_result: 3]

  @complete_tool "complete_task"

  # Maximum consecutive "no tool calls" nudges before ending the turn gracefully.
  # When the LLM returns no tool calls, we append a user-role nudge message and
  # re-prompt. After this many consecutive nudges with still no tool calls, we
  # stop and end the turn via the existing protocol-violation path (recovery or
  # :recovery_failed) instead of crashing or spinning forever.
  @max_no_tool_call_nudges 3

  # --- Model & Generation Params ---

  @doc false
  def current_model do
    agent_id = EvoGit.AgentScheduler.current_agent_id()
    {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
    agent_state.llm_model
  end

  @doc false
  def current_generation_params do
    agent_id = EvoGit.AgentScheduler.current_agent_id()
    {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
    agent_state.llm_generation_params
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

      {:error, :protocol_violation} ->
        handle_protocol_violation(state, loop_fn, trigger_recovery_fn)
    end
  end

  # --- LLM Prompting (transient-error retry + no-tool-call nudging) ---

  @doc false
  # Calls the LLM and re-prompts (with a user-role nudge) when the model returns
  # no tool calls, instead of retrying the same unchanged context or crashing.
  # Transient transport/stream errors are still retried with exponential backoff
  # inside `call_llm_with_retry/5`; only the semantic "no tool calls" case is
  # handled here by appending a nudge message and re-prompting. After
  # `@max_no_tool_call_nudges` consecutive nudges with still no tool calls, the
  # turn ends gracefully via `{:error, :protocol_violation}`, feeding the
  # existing recovery path (no crash, no new try/rescue).
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
        case ensure_tool_calls(response, agent_id) do
          :ok ->
            {:ok, response}

          {:error, :no_tool_calls} ->
            if nudge_count >= @max_no_tool_call_nudges do
              Logger.warning(
                "Agent #{agent_id}: LLM returned no tool calls after #{nudge_count} consecutive nudges (#{nudge_count + 1} attempts), ending turn gracefully"
              )

              {:error, :protocol_violation}
            else
              Logger.warning(
                "Agent #{agent_id}: LLM returned no tool calls, appending nudge and continuing (nudge #{nudge_count + 1}/#{@max_no_tool_call_nudges})"
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

      {:error, reason} ->
        # Genuine transient failure (network/rate-limit/stream) exhausted all
        # retries. This is a real error — raise, preserving prior behavior.
        raise "LLM request failed after #{max_retries} retries: #{inspect(reason)}"
    end
  end

  @doc false
  # Calls the LLM with retry-on-transient-error semantics. The retry loop (with
  # exponential backoff) handles ONLY genuine transport/stream errors (network
  # failures, rate limits, stream-processing errors) — returned as `{:error, _}`
  # tuples. It does NOT retry the "no tool calls" case — that semantic problem
  # is handled by the caller via context nudging. Returns {:ok, response,
  # duration_ms} or {:error, reason}.
  #
  # `rescue_only: []` disables exception retrying. It stays because the remaining
  # raise paths must propagate IMMEDIATELY rather than being retried through
  # exponential backoff: the retry library's DEFAULT is
  # `rescue_only: [RuntimeError]`, which WOULD retry a raised RuntimeError
  # (bounded by max_retries, but through exponential-backoff sleeps of up to
  # 60s each — effectively a long hang). The remaining raise paths are:
  # (a) `{:error, :cancelled}` from a force-kill queue purge raises in
  # `AgentScheduler.with_llm_slot/2` → agent crash → scheduler crash-retry/cancel
  # machinery; (b) unexpected exceptions. A model with 0 LLM slots (peak
  # hard-pause) does NOT raise — its slot request BLOCKS (queued in the
  # scheduler, exactly like the paused-scheduler path) until capacity returns
  # (peak exit → `update_config` → `grant_pending_on_resume` grants queued
  # waiters) or a purge replies `{:error, :cancelled}` (force-kill).
  #
  # The LLM slot is acquired and released PER ATTEMPT (with_llm_slot sits INSIDE
  # the retry block), so the exponential-backoff sleep happens BETWEEN attempts
  # while the agent's slot is FREE. This makes `AgentScheduler.pause/0` effective
  # for a retrying agent: its next attempt blocks on slot re-acquisition when the
  # scheduler is paused (and is granted on resume). `{:error, _}` tuple returns
  # from the block are retried per the `atoms: [:error]` default.
  def call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries) do
    retry with:
            exponential_backoff(1_000)
            |> randomize()
            |> cap(60_000)
            |> Stream.take(max_retries),
          rescue_only: [] do
      AgentScheduler.with_llm_slot(agent_id, fn ->
        with llm_start <- System.monotonic_time(:millisecond),
             {:ok, stream_resp} <-
               ReqLLM.stream_text(
                 current_model(),
                 context,
                 Keyword.merge([tools: tools], llm_gen_opts)
               ),
             {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_resp),
             llm_end <- System.monotonic_time(:millisecond) do
          {:ok, response, llm_end - llm_start}
        else
          {:error, reason} ->
            Logger.warning(
              "Agent #{agent_id}: LLM request failed, retrying... Reason: #{inspect(reason)}"
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
    |> case do
      {:ok, _response, _llm_duration} = result ->
        result

      {:error, reason} ->
        if EvoGit.Agent.TruncationFeedback.is_rate_limit_error?(reason) do
          AgentScheduler.report_llm_error(agent_id, :rate_limit)
        end

        {:error, reason}
    end
  end

  @doc false
  # Appends a user-role nudge message to the context (which already contains the
  # assistant's tool-less response), instructing the model to make a tool call.
  def append_no_tool_call_nudge(context) do
    ReqLLM.Context.append(context, no_tool_call_nudge_message())
  end

  @doc false
  # The user-role nudge message appended when the LLM returns no tool calls.
  # Stamped with a creation-time timestamp (not turn-tagged — it can be
  # appended between turns inside prompt_until_tools_or_limit).
  def no_tool_call_nudge_message do
    EvoGit.Agent.ContextBuilder.tag_message_timestamp(
      user(
        "You did not make any tool calls in your last response. You must use the " <>
          "provided tools to accomplish the task. Please respond with a tool call."
      )
    )
  end

  # Handles the protocol-violation outcome (no usable tool calls) by either
  # triggering recovery (when not in the grace period), re-entering the loop
  # during grace with budget remaining (consuming one grace turn), or returning
  # :recovery_failed (when the grace budget is exhausted).
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
  `{name, arguments}`. Keeps the first occurrence in each pass. Logs a
  `Logger.warning/1` whenever duplicates are removed, including the agent id,
  the count removed, the before/after totals, and a description of what was
  removed.
  """
  def dedupe_tool_calls(tool_calls, agent_id) when is_list(tool_calls) do
    original_count = length(tool_calls)

    # Pass 1 — dedupe by :id (primary signal: "duplicated tool call ids").
    # Enum.dedup_by/2 removes consecutive duplicates, keeping the first.
    by_id = Enum.dedup_by(tool_calls, & &1.id)

    # Pass 2 — dedupe by identical content {name, arguments-as-decoded-map}
    final =
      Enum.dedup_by(by_id, fn call ->
        {ReqLLM.ToolCall.name(call), ReqLLM.ToolCall.args_map(call)}
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
  def process_llm_response(
        response,
        %LoopState{} = state,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn
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

    turn_usage = Usage.from_response_usage(usage)

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
  # Defensive fallback: an LLM response with zero tool calls is detected in
  # prompt_until_tools_or_limit/5 (via ensure_tool_calls/2) before tool calls are
  # ever extracted, so an empty list should never reach here in normal
  # operation. Kept as a guard so any unexpected empty-list input degrades to a
  # protocol violation rather than a crash in process_regular_tool_calls/3.
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
  # Detects an LLM response with zero tool calls. Returns :ok when tool calls are
  # present, otherwise {:error, :no_tool_calls}. The caller
  # (`prompt_until_tools_or_limit/5`) handles the no-tool-call case by appending a
  # nudge message and re-prompting, then ending gracefully after a bounded number
  # of nudges. This function only emits a warning; it does NOT retry or crash.
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
    complete_args = ReqLLM.ToolCall.args_map(complete_call)

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
      do_complete(complete_call, state)
    else
      repo_path = Process.get(:repo_path)

      case CompleteTask.check_workspace_dirty(repo_path) do
        {:dirty, warning_msg} ->
          Logger.warning(
            "Agent #{state.agent_id}: Workspace is dirty at completion. Warning: #{warning_msg}"
          )

          tool_responses =
            Enum.map(tool_calls, fn call ->
              tool_call_id = call.id || ReqLLM.ToolCall.name(call) || "unknown"
              tool_result(tool_call_id, ReqLLM.ToolCall.name(call), warning_msg)
            end)

          {:continue, tool_responses, nil}

        {:clean, _} ->
          do_complete(complete_call, state)
      end
    end
  end

  defp do_complete(complete_call, %LoopState{} = state) do
    # Sync the current commit before completing
    commit_sha = sync_and_get_current_commit(state)

    complete_args = ReqLLM.ToolCall.args_map(complete_call)

    result = Map.get(complete_args, "result", "Task finished.")

    # Get metadata from agent state
    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    depth = AgentScheduler.current_depth()

    # Repo-less agents have a nil phylo_node — passing nil base_commit is safe:
    # CompleteTask.complete/4 guards git-note/archive writes on base_commit
    # being truthy, so both are skipped for repo-less agents.
    base_commit = if Process.get(:repo_less), do: nil, else: agent_state.phylo_node.base_commit

    final_result =
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

    {:complete, final_result}
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
        tool_result(tool_call_id, name, output)
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
        state.delegation_level
      )

    # Sync current_commit after tool execution for dashboard visibility
    sync_current_commit_after_tools(state)

    indexed_results
  end

  @doc false
  def batch_execute_tools(indexed_calls, max_timeout, repo_root, delegation_level) do
    agent_id = AgentScheduler.current_agent_id()
    repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

    {:ok, %{context_node: %{path: node_path}}} =
      AgentScheduler.get_agent_state(agent_id)

    threshold = EvoGit.Agent.DelegationHints.delegation_hint_threshold()
    initial_hints = Process.get(:delegation_hints, %{})

    read_threshold = EvoGit.Agent.DelegationHints.read_delegation_hint_threshold()
    read_initial_hints = Process.get(:read_delegation_hints, %{})

    # Cache conflict files once per batch to avoid repeated git calls
    conflict_files = cached_conflict_files(repo_path)

    ctx = %{
      agent_id: agent_id,
      repo_path: repo_path,
      repo_root: repo_root,
      node_path: node_path,
      max_timeout: max_timeout,
      delegation_level: delegation_level,
      threshold: threshold,
      read_threshold: read_threshold,
      conflict_files: conflict_files
    }

    # Execute ALL standard tool calls in the batch CONCURRENTLY, bounded only
    # by the scheduler's tool-slot pool: each parallel task still acquires a
    # tool slot via `AgentScheduler.with_tool_slot/2` inside
    # `execute_tool_with_timeout/7` (respecting `max_tool_concurrency`).
    # `max_concurrency` is set to the batch size so every call starts
    # immediately — Elixir's `max_concurrency` only accepts positive integers
    # (`:infinity` is valid for `timeout` only) — making the scheduler, not a
    # local cap, the binding constraint. `ordered: true` keeps results in index
    # order. `timeout: :infinity` defers timeout enforcement to the per-tool
    # timeout logic inside `execute_tool_with_timeout/7` (an outer stream
    # timeout would wrongly kill legitimate long-running tools).
    concurrency = max(1, length(indexed_calls))

    tool_outputs =
      indexed_calls
      |> Task.async_stream(
        fn {call, index} -> run_tool_in_parallel(call, index, ctx) end,
        max_concurrency: concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, {%_{} = exception, stacktrace}} -> reraise(exception, stacktrace)
        {:exit, reason} -> exit(reason)
      end)

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

  # Runs a single tool call's execution inside the parallel stream, returning
  # `{index, call, output}`. Only the tool-execution call happens here — hint
  # tracking and the redundant-cd warning are applied later in the parent
  # process, in index order (see `apply_tool_output_tracking/3`).
  defp run_tool_in_parallel(call, index, ctx) do
    name = ReqLLM.ToolCall.name(call)
    args = ReqLLM.ToolCall.args_map(call)

    output =
      execute_tool_with_timeout(
        name,
        args,
        ctx.agent_id,
        ctx.repo_path,
        ctx.repo_root,
        ctx.node_path,
        ctx.max_timeout
      )

    {index, call, output}
  end

  # Applies the redundant-cd warning and write/read delegation hints to one
  # tool output in the parent process, threading the hint maps through the
  # batch accumulator (index-ordered, deterministic).
  defp apply_tool_output_tracking({index, call, output}, {acc_results, hints, read_hints}, ctx) do
    name = ReqLLM.ToolCall.name(call)
    args = ReqLLM.ToolCall.args_map(call)
    tool_call_id = call.id || name || "unknown"

    output =
      maybe_append_redundant_cd_warning(output, name, args, ctx.repo_path, ctx.repo_root)

    # Track delegation hints for write tools (skip during conflict resolution)
    {output, hints} = track_write_delegation_hint(output, hints, name, args, ctx)

    # Track read delegation hints for read tools (skip during conflict resolution)
    {output, read_hints} = track_read_delegation_hint(output, read_hints, name, args, ctx)

    {acc_results ++ [{index, tool_call_id, name, output}], hints, read_hints}
  end

  # Runs a single tool call inside a tool slot with an async task, bounded
  # timeout, and output sanitization/truncation feedback.
  defp execute_tool_with_timeout(
         name,
         args,
         agent_id,
         repo_path,
         repo_root,
         node_path,
         max_timeout
       ) do
    tool_timeout =
      Map.get(args, "timeout", EvoGit.Agent.DelegationHints.default_tool_timeout())

    tool_timeout = min(tool_timeout, max_timeout)

    AgentScheduler.with_tool_slot(agent_id, fn ->
      task =
        Task.async(fn ->
          EvoGit.Agent.Tools.execute(
            name,
            args,
            repo_path,
            repo_root,
            node_path
          )
        end)

      case Task.yield(task, tool_timeout) || Task.shutdown(task) do
        {:ok, {:error, reason}} ->
          "Error: #{inspect(reason)}"

        {:ok, result} ->
          {sanitized, truncation_info} =
            OutputSanitizer.sanitize_and_truncate(result, name, args)

          EvoGit.Agent.TruncationFeedback.append_truncation_feedback(
            sanitized,
            truncation_info,
            name
          )

        {:exit, reason} ->
          "Error: Tool execution crashed: #{inspect(reason)}"

        nil ->
          "Error: Tool execution timed out after #{tool_timeout}ms. Some output may have been partially captured by the tool."
      end
    end)
  end

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
        ctx.delegation_level
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
    if name in ["run_bash", "run_powershell"] do
      command = Map.get(args, "command", "")

      if EvoGit.Agent.Tools.ShellTool.redundant_cd?(command, repo_path, repo_root) and
           not Process.get(:redundant_cd_warned, false) do
        Process.put(:redundant_cd_warned, true)
        output <> "\n\n" <> EvoGit.Agent.Tools.ShellTool.redundant_cd_warning(repo_path)
      else
        output
      end
    else
      output
    end
  end

  # --- Shared Helpers ---

  defp agent_type_from_module(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
