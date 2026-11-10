defmodule EvoGit.Agent.ToolDispatch do
  @moduledoc """
  Turn orchestration for a scheduled agent: one prompt, one response, and the
  tool calls it carries.

  This module owns the turn loop only — the current model/generation-param
  accessors, commit syncing, `do_turn/5,6`, post-LLM response processing (usage
  accounting, tool-call dedupe, turn/context advance, reasoning compaction),
  tool-call processing and the completion route.

    * PROMPTING lives in `EvoGit.Agent.LLMPrompting` (transient-error retry,
      fail-fast on a non-retryable rejection, the empty-response nudge, turn
      classification via `EvoGit.Agent.CompletionProtocol`) and is delegated here.
    * EXECUTION lives in `EvoGit.ToolRuntime` (serial/parallel partition,
      per-call timeouts, tool slots, spawned tool task, `EvoGit.ProcessManager`
      tracking, sanitize pipeline); `batch_execute_tools/5` resolves the
      agent-side context into ONE `EvoGit.ToolRuntime.Request` and delegates the
      whole batch to `EvoGit.ToolRuntime.execute_batch/2`.
    * HINT TRACKING lives in `EvoGit.Agent.ToolOutputTracking` (delegation hints
      plus the once-per-run redundant-cd warning, applied after the batch in the
      parent process, in request order) and is delegated here.

  The wrap boundary stays here: `sanitize_tool_result/3` is a thin delegator to
  `EvoGit.ToolRuntime.Output.sanitize/3` that re-attaches the sanitized text
  (`ToolOutput.with_text/2`) so media survive, and `assemble_tool_result/3`
  materializes a `%ToolOutput{}` into content parts
  (`ToolOutput.to_content_parts/1`) while passing a plain binary through
  BYTE-IDENTICALLY to `ReqLLM.Context.tool_result/3`.

  A text reply with ZERO tool calls is an IMPLICIT COMPLETION: pending work is
  committed and the reply text IS the report. That is the ONE terminal outcome of
  a turn: `{:finish, state, %EvoGit.Agent.Result{}}` — the result is built and
  its completion side effects written HERE, so the engine only finalizes. ZERO
  tool calls and no usable text is the only error path (one nudge, then the
  bounded protocol-violation route); there is NO completion tool.

  The turn runs on `%EvoGit.Agent.State{}`. Its outside-world dependencies are
  injectable through `EvoGit.Agent.Exchange.Seams` (the `:llm_call`,
  `:tool_batch` and `:scheduler` seams, resolved from ONE `opts` keyword list and
  DEFAULT-INERT: an absent seam is the production path, byte-identical).
  """

  require Logger

  alias EvoGit.Agent.Completion
  alias EvoGit.Agent.Compression.Threshold
  alias EvoGit.Agent.ConflictState
  alias EvoGit.Agent.Exchange.Seams
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolOutput
  alias EvoGit.Agent.SubagentSchemas
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Usage
  alias EvoGit.Agent.Cost
  alias EvoGit.AgentScheduler
  import ReqLLM.Context, only: [user: 1, tool_result: 3]

  # --- Model & Generation Params ---

  # These three accessors stay exported (`@doc false`) for compatibility: the
  # runner, the compression trigger and `LLMPrompting` still resolve the caller
  # from the process dictionary + ETS. The ENGINE no longer calls them — it reads
  # the same values off `%EvoGit.Agent.State{}`.

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

  # The CONFIGURED context window for the calling agent, threaded into the
  # compression trigger. Read defensively: the field is populated by the
  # scheduler from the model profile's `context_window`, and an older/absent
  # value simply means "use the platform default".
  @doc false
  def current_context_window do
    agent_state = fetch_current_agent_state!(:current_context_window)
    normalize_context_window(Map.get(agent_state, :llm_context_window))
  end

  @doc false
  # The ONE context-window normalization: a positive configured integer, else
  # the platform default. Public so the engine reuses this EXACT rule (from
  # `%State{}.llm_context_window`) instead of re-implementing it.
  def normalize_context_window(window) when is_integer(window) and window > 0, do: window

  def normalize_context_window(_window),
    do: EvoGit.Config.Schema.LLM.default_context_window()

  # Shared lookup for current_model/0 + current_generation_params/0.
  # DISPLAY / IMMUTABLE-IDENTITY METADATA ONLY — neither is a conversation or
  # loop value (both are fixed at registration). Raises a
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
  # Records the post-tool worktree HEAD as a PER-PROCESS derived value
  # (`:evogit_current_commit`), which `continue_after_tools/7` moves onto the
  # owned `%State{}` at the turn checkpoint — no ETS write happens here.
  def sync_current_commit_after_tools(%State{}) do
    # Repo-less agents have no worktree and no commit — skip git entirely.
    if Process.get(:repo_less) do
      :ok
    else
      repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

      case Git.rev_parse(repo_path) do
        {:ok, current_sha} ->
          Process.put(:evogit_current_commit, current_sha)
          :ok

        {:error, reason} ->
          raise_rev_parse_error(reason)
      end
    end
  end

  # Reads the current commit for the completion payload (no ETS write).
  defp sync_and_get_current_commit(%State{} = _state) do
    # Repo-less agents have no worktree and no commit; completion receives a
    # nil commit_sha.
    if Process.get(:repo_less) do
      nil
    else
      repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

      case Git.rev_parse(repo_path) do
        {:ok, sha} -> sha
        {:error, reason} -> raise_rev_parse_error(reason)
      end
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
        state,
        effective_tools_fn,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn,
        opts \\ []
      )

  def do_turn(
        %State{} = state,
        effective_tools_fn,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn,
        opts
      ) do
    context = state.context
    tools = effective_tools_fn.(state)

    seams = Seams.from_opts(opts)
    llm_call = seams.llm_call || Seams.default_llm_call()

    # `max_retries` and the generation parameters used to be read from the
    # scheduler's ETS row here (`AgentScheduler.get_agent_state/1`); they are
    # carried on the struct itself now. Identical values: the runner populates
    # both fields from that same row when it builds the state.
    max_retries = state.max_retries
    llm_gen_opts = state.llm_generation_params

    case llm_call.(
           context,
           tools,
           llm_gen_opts,
           state.agent_id,
           max_retries
         ) do
      {:ok, response} ->
        process_llm_response(
          response,
          state,
          subagent_modules,
          loop_fn,
          trigger_recovery_fn,
          nil,
          opts
        )

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
          text,
          opts
        )

      {:error, :protocol_violation} ->
        handle_protocol_violation(state, loop_fn, trigger_recovery_fn)

      {:error, {:llm_request_rejected, _} = terminal} ->
        # Non-retryable provider rejection (the fail-fast path of
        # `handle_llm_failure/7`): the turn ends with a GRACEFUL terminal error
        # that propagates out of `Exchange.run/2` (and the session worker)
        # unchanged. Deliberately NOT
        # routed through `handle_protocol_violation/3` — that would burn the
        # grace budget / trigger recovery against a request that can never
        # succeed, when the only real fix is a model-profile / request-parameter
        # change. The task is persisted `:failed` with the actionable message.
        {:error, terminal}
    end
  end

  # --- LLM Prompting (delegators to `EvoGit.Agent.LLMPrompting`) ---

  @doc false
  defdelegate prompt_until_tools_or_limit(context, tools, llm_gen_opts, agent_id, max_retries),
    to: EvoGit.Agent.LLMPrompting

  @doc false
  defdelegate call_llm_with_retry(context, tools, llm_gen_opts, agent_id, max_retries),
    to: EvoGit.Agent.LLMPrompting

  @doc false
  defdelegate append_no_tool_call_nudge(context), to: EvoGit.Agent.LLMPrompting

  @doc false
  defdelegate no_tool_call_nudge_message(), to: EvoGit.Agent.LLMPrompting

  # Handles the protocol-violation outcome (an EMPTY response — no tool calls and
  # no usable text, after the single nudge was already spent) by either
  # triggering recovery (when not in the grace period), re-entering the loop
  # during grace with budget remaining (consuming one grace turn), or returning
  # :recovery_failed (when the grace budget is exhausted).
  #
  # A response with non-empty text never reaches here: it is an implicit
  # completion (see `EvoGit.Agent.CompletionProtocol`).
  defp handle_protocol_violation(%State{} = state, loop_fn, trigger_recovery_fn) do
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
        state,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn,
        completion_text \\ nil,
        opts \\ []
      )

  def process_llm_response(
        response,
        %State{} = state,
        subagent_modules,
        loop_fn,
        trigger_recovery_fn,
        completion_text,
        opts
      ) do
    state = update_turn_usage(state, response)
    {tool_calls, response} = prepare_tool_calls(response, state.agent_id)
    state = advance_turn_context(state, response)

    # No ETS write-through here: this turn's state is published by the engine's
    # ONE `:checkpoint` seam at the turn boundary.

    # Initialize delegation hints in process dictionary for this turn
    Process.put(:delegation_hints, state.delegation_hints)
    Process.put(:read_delegation_hints, state.read_delegation_hints)

    if completion_text do
      # Implicit completion: the bookkeeping above already recorded the turn
      # (including the final assistant message in the context), so all that is
      # left is the completion side effects in `EvoGit.Agent.Completion`.
      {:finish, state, build_completion(state, completion_text)}
    else
      case process_tool_calls(tool_calls, state, subagent_modules, opts) do
        {:continue, tool_responses, subagent_usage} ->
          continue_after_tools(
            tool_responses,
            subagent_usage,
            tool_calls,
            state,
            subagent_modules,
            loop_fn,
            opts
          )

        {:error, :protocol_violation} ->
          handle_protocol_violation(state, loop_fn, trigger_recovery_fn)
      end
    end
  end

  # Tracks the current context length (replace, don't accumulate) and
  # accumulates cumulative usage (separate from total_tokens used for
  # compression).
  defp update_turn_usage(%State{} = state, response) do
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
    # The pricing identity (effective `llm_model` + the selection's provider
    # profile) is owned by `%State{}`, so no ETS read happens per turn.
    turn_usage =
      Usage.from_response_usage(usage)
      |> Cost.apply_to_usage(usage, state)

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
  defp advance_turn_context(%State{} = state, response) do
    compacted_context = compact_reasoning_details(response.context)
    new_turn = state.turn + 1

    compacted_context =
      EvoGit.Agent.ContextBuilder.tag_context_tail_with_turn(compacted_context, new_turn)

    %{state | context: compacted_context, turn: new_turn}
  end

  # Handles the {:continue, ...} outcome of tool-call processing: picks up the
  # updated delegation hints from the process dictionary, tags and appends the
  # tool responses to the context, accumulates subagent usage, and re-enters the
  # loop. The turn's state is the authority; no ETS write happens here.
  defp continue_after_tools(
         tool_responses,
         subagent_usage,
         tool_calls,
         %State{} = state,
         subagent_modules,
         loop_fn,
         _opts
       ) do
    if EvoGit.Agent.grace_period_continue_failed?(state) do
      {:error, :recovery_failed}
    else
      # A turn ended without finishing the run: if in a grace period, consume
      # one grace turn (decrement grace_turns_remaining). Outside a grace
      # period this is a no-op (counter stays at its default 0).
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

      # One merge-conflict check per turn, taken at the END of the turn: the
      # snapshot lives in the process dictionary (`EvoGit.Agent.ConflictState`)
      # and is reused by every consumer in the NEXT turn with zero extra git
      # calls.
      conflict_files = ConflictState.refresh(Process.get(:repo_path))

      new_turns_since =
        next_turns_since_subagent(
          state.turns_since_subagent,
          had_subagent_call,
          conflict_files != []
        )

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

      # Carry the commit recorded after tool execution (if any) onto the
      # checkpointed state. Delete-on-read, so a stale sha can never leak into a
      # later turn.
      state =
        case Process.delete(:evogit_current_commit) do
          sha when is_binary(sha) -> %{state | current_commit: sha}
          _ -> state
        end

      # No ETS write-through: the updated context and accumulated usage ride the
      # returned state, and the engine publishes it at the turn boundary.
      loop_fn.(state)
    end
  end

  # Consumes one grace turn: decrements `grace_turns_remaining` when the agent
  # is in a grace period (a turn ended without finishing the run). Outside a
  # grace period the counter stays at its default 0. Only reached when
  # `grace_period_continue_failed?/1` returned `false` (i.e. remaining > 1), so
  # the decremented value is always >= 1.
  defp consume_grace_turn(%State{in_grace_period: true, grace_turns_remaining: n} = state) do
    %{state | grace_turns_remaining: n - 1}
  end

  defp consume_grace_turn(%State{} = state), do: state

  # Computes the next `turns_since_subagent` counter after a completed turn.
  # Three cases:
  #   1. a subagent call happened this turn → 0 (delegation always resets,
  #      conflicts or not);
  #   2. the agent's worktree is in a merge conflict → the counter is FROZEN
  #      (returned unchanged, NOT incremented), because subagents branch from
  #      clean commits and therefore can never resolve conflict markers in the
  #      parent's worktree — nudging the agent to delegate while it is
  #      conflict-resolving only burns its budget (same rationale as
  #      `EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts/2`);
  #   3. otherwise → increment (today's behaviour).
  # `@doc false` + public solely so it can be tested directly.
  @doc false
  def next_turns_since_subagent(turns_since_subagent, had_subagent_call, in_conflict) do
    cond do
      had_subagent_call -> 0
      in_conflict -> turns_since_subagent
      true -> turns_since_subagent + 1
    end
  end

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
  # rather than a crash in process_regular_tool_calls/4.
  def process_tool_calls(tool_calls, state, subagent_modules),
    do: process_tool_calls(tool_calls, state, subagent_modules, [])

  @doc false
  def process_tool_calls([], _state, _subagent_modules, _opts), do: {:error, :protocol_violation}

  @doc false
  def process_tool_calls(tool_calls, %State{} = state, subagent_modules, opts)
      when is_list(tool_calls) and tool_calls != [] do
    process_regular_tool_calls(tool_calls, state, subagent_modules, opts)
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

  # The completion route (a text reply with no tool calls).
  #
  # Any pending work is committed FIRST so the sha reported to the runtime is
  # reviewable: without this the commit would only happen in the post-run
  # auto-commit fallback (`Session.Worker`'s `after` block), i.e. AFTER
  # `commit_sha` was captured, and
  # `Runtime.Helpers.merge_and_report/3,4` would take the no-changes path and
  # drop the work with the worktree. `commit_pending_in_worktree/0` is a no-op
  # for a clean workspace and for repo-less agents, and it never raises (git
  # errors are logged, not propagated), so it cannot turn a legitimate finish
  # into a failure.
  defp build_completion(%State{} = state, result) do
    AgentScheduler.Dispatch.commit_pending_in_worktree()
    build_completion(state, result, sync_and_get_current_commit(state))
  end

  # Builds the `%Result{}` and writes its completion side effects (git note when
  # `base_commit` is set, archive refs/row when archiving), so every downstream
  # consumer is oblivious to how the agent finished.
  defp build_completion(%State{} = state, result, commit_sha) do
    # REGISTRATION METADATA ONLY: `base_commit` comes from the spec's phylo node
    # captured at registration, and the archive/model registration metadata from
    # the summary row; the completion side effects (git note, archive refs/row)
    # must stay byte-identical. No conversation/loop value is read from ETS here
    # — notably `compression_count` and `current_commit` come from the owned state.
    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    {:ok, meta} = EvoGit.AgentScheduler.Store.get_sched_meta(state.agent_id)

    # Repo-less agents have no spec phylo node — passing nil base_commit is safe:
    # Completion.complete/4 guards git-note/archive writes on base_commit
    # being truthy, so both are skipped for repo-less agents.
    base_commit =
      if Process.get(:repo_less),
        do: nil,
        else: meta.spec.phylo_node && meta.spec.phylo_node.base_commit

    Completion.complete(
      state.agent_id,
      result,
      commit_sha,
      base_commit: base_commit,
      parent_id: agent_state.parent_id,
      depth: state.depth,
      objective: state.objective,
      usage: state.usage,
      archive: agent_state.archive,
      compression_count: state.compression_count,
      repo_id: agent_state.repo_id,
      repo_root: agent_state.repo_root,
      llm_model: agent_state.llm_model,
      model_id: agent_state.model_id,
      model_spec: Map.get(agent_state, :model_spec),
      llm_generation_params: agent_state.llm_generation_params,
      max_turns: agent_state.max_turns,
      max_retries: agent_state.max_retries,
      max_agent_depth: agent_state.max_depth,
      foreign_repos: agent_state.foreign_repos,
      compression_threshold:
        Threshold.for_model(agent_state.llm_model,
          context_window: Map.get(agent_state, :llm_context_window)
        ).threshold,
      agent_type: agent_type_from_module(state.agent_module),
      context_node_path: state.node_path
    )
  end

  @doc false
  def process_regular_tool_calls(tool_calls, state, subagent_modules),
    do: process_regular_tool_calls(tool_calls, state, subagent_modules, [])

  @doc false
  def process_regular_tool_calls(tool_calls, %State{} = state, subagent_modules, opts) do
    # 1. Index: Attach index to each call
    indexed_calls = Enum.with_index(tool_calls)

    # 3. Split: Partition into subagent and standard calls
    {indexed_subagent_calls, indexed_standard_calls} =
      Enum.split_with(indexed_calls, fn {call, _index} ->
        SubagentSchemas.subagent_module_for(ReqLLM.ToolCall.name(call), subagent_modules) != nil
      end)

    # 4. Batch: Process each batch
    indexed_standard_results = process_standard_calls(indexed_standard_calls, state, opts)

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
  def process_standard_calls(indexed_calls, state),
    do: process_standard_calls(indexed_calls, state, [])

  @doc false
  def process_standard_calls(indexed_calls, %State{} = state, opts) do
    case Seams.from_opts(opts) do
      %Seams{tool_batch: nil} ->
        repo_root =
          Process.get(:genesis_repo_root) || raise "genesis_repo_root not in process dictionary"

        indexed_results =
          batch_execute_tools(
            indexed_calls,
            EvoGit.Agent.DelegationHints.max_tool_timeout(),
            repo_root,
            state.delegation_level,
            # The RECEIVING role: the read-delegation nudge names only the
            # subagent tools this role can actually spawn (its
            # `subagent_modules/0`).
            state.agent_module
          )

        # Sync current_commit after tool execution for dashboard visibility
        sync_current_commit_after_tools(state)

        indexed_results

      %Seams{tool_batch: tool_batch} ->
        # The documented `:tool_batch` seam REPLACES the whole standard-call
        # batch: no `EvoGit.ToolRuntime` call and no commit sync after tools
        # (the batch is expected to be a stub). Everything else — result
        # ordering, the subagent partition and the `%ReqLLM.Message{}`
        # construction — stays here.
        tool_batch.(indexed_calls, state)
    end
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

    # DISPLAY / SPATIAL-AUTHORIZATION METADATA ONLY: the node path (plus the
    # per-batch identity below) is registration data, never a loop value.
    {:ok, %{context_node: %{path: node_path}}} =
      AgentScheduler.get_agent_state(agent_id)

    # The AGENT-side identity, resolved ONCE per batch and handed to the managed
    # runtime in ONE request struct.
    #
    # The pid MUST be the AGENT's, never a tool task's: the tool task is shut
    # down IMMEDIATELY after the tool returns
    # (`Task.yield(task, tool_timeout) || Task.shutdown(task)`), so anything
    # monitoring it — `EvoGit.BackgroundJobs` binds a detached job's lifetime to
    # its owner — would see an exit at once and kill the job on the spot. The
    # AGENT pid is the one lifetime signal that covers agent completion, crash,
    # graceful cancel and force-kill.
    #
    # Nor is it this process's `self()`: this batch runs inside an exchange
    # WORKER (one short-lived `Task` per exchange) that owns nothing durable
    # (design decision D7), so the tracked execution / detached background job
    # must be owned by the SESSION that outlives the worker. The session pid is
    # installed on the process dictionary by
    # `EvoGit.Agent.Session.Setup.install_process_context/3`; `self()` is only
    # the fallback for a driver that installs no owner (the one-shot path
    # installs `self()` there, so both paths agree).
    request =
      EvoGit.ToolRuntime.Request.new(%{
        agent_id: agent_id,
        task_id: AgentScheduler.task_id_for_agent(agent_id),
        agent_pid: Process.get(:evogit_agent_pid) || self(),
        repo_path: repo_path,
        repo_root: repo_root,
        node_path: node_path,
        # Resolved once here (in the agent process, which owns the process dict)
        # and re-installed inside each spawned tool task so the per-task tmpdir
        # survives the spawned-task boundary (spawned tasks do not inherit the
        # caller's process dictionary). `nil` is a harmless no-op.
        taskdir: EvoGit.TaskTmpdir.current(),
        max_timeout: max_timeout,
        delegation_level: delegation_level,
        agent_module: agent_module,
        # The ROLE-GUARD inputs `EvoGit.Agent.Tools.execute/5` consults; the
        # runtime re-installs them in every tool task.
        role: %{
          repo_less: Process.get(:repo_less) == true,
          foreign_repos: Process.get(:foreign_repos, []),
          repo_id: Process.get(:evogit_repo_id)
        }
      })

    ctx = %{
      repo_path: repo_path,
      repo_root: repo_root,
      node_path: node_path,
      threshold: EvoGit.Agent.DelegationHints.delegation_hint_threshold(),
      read_threshold: EvoGit.Agent.DelegationHints.read_delegation_hint_threshold(),
      # ONE merge-conflict check per turn: reuse the snapshot refreshed at the
      # END of the previous turn (`EvoGit.Agent.ConflictState`) — that is
      # immediately before this batch, so it is fresher than a pre-batch check
      # and free of any extra git call. A never-refreshed process dictionary
      # yields `[]`.
      conflict_files: ConflictState.files(),
      # The receiving role: its delegation level and module, used by the
      # read-delegation nudge to name only the subagent tools this role actually
      # has.
      delegation_level: delegation_level,
      agent_module: agent_module
    }

    initial_hints = Process.get(:delegation_hints, %{})
    read_initial_hints = Process.get(:read_delegation_hints, %{})

    calls_by_index = Map.new(indexed_calls, fn {call, index} -> {index, call} end)

    # Apply hint tracking in the PARENT process, in index order, so the
    # process-dictionary-backed delegation-hint maps and the once-per-run
    # redundant-cd warning accumulate deterministically (running them inside
    # the runtime's parallel tasks would make accumulation racy/non-deterministic).
    {results, final_hints, read_final_hints} =
      indexed_calls
      |> EvoGit.ToolRuntime.execute_batch(request)
      |> Enum.reduce({[], initial_hints, read_initial_hints}, fn {index, _id, _name, output},
                                                                 acc ->
        apply_tool_output_tracking({index, Map.fetch!(calls_by_index, index), output}, acc, ctx)
      end)

    # Store updated hints in process dictionary for do_turn to pick up
    Process.put(:delegation_hints, final_hints)
    Process.put(:read_delegation_hints, read_final_hints)

    results
  end

  # --- Tool Output Tracking (delegators to `EvoGit.Agent.ToolOutputTracking`) ---

  @doc false
  defdelegate apply_tool_output_tracking(entry, acc, ctx),
    to: EvoGit.Agent.ToolOutputTracking

  @doc false
  defdelegate maybe_append_redundant_cd_warning(output, name, args, repo_path, repo_root),
    to: EvoGit.Agent.ToolOutputTracking

  # --- Multimodal tool output: wrap boundary ---

  @doc false
  # Finalizes a tool's raw return value for the tool-result message.
  #
  # The pipeline itself MOVED to `EvoGit.ToolRuntime.Output.sanitize/3` (it is
  # runtime-owned, like execution and tracking); this delegator stays because it
  # is the long-standing public entry point of the wrap boundary and is called
  # directly by suites.
  #
  # An all-text return (the shape every built-in tool produces today) comes back
  # as the plain sanitized BINARY — byte-identical to the legacy path, never
  # promoted to a `%ToolOutput{}`. A return carrying media comes back as a
  # `%ToolOutput{}` from which the media parts are materialized exactly once at
  # the message-construction site (`assemble_tool_result/3`).
  defdelegate sanitize_tool_result(result, name, args),
    to: EvoGit.ToolRuntime.Output,
    as: :sanitize

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

  # --- Shared Helpers ---

  defp agent_type_from_module(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
