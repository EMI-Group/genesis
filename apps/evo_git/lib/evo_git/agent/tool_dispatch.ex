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
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler

  import ReqLLM.Context, only: [user: 1, tool_result: 3]

  @complete_tool "complete_task"

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
    repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

    case Git.rev_parse(repo_path) do
      {:ok, current_sha} ->
        {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)

        if agent_state.phylo_node.current_commit != current_sha do
          updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
          AgentScheduler.update_phylo_node(state.agent_id, updated_phylo)
        end

      {:error, code, msg} ->
        raise "Git rev_parse failed (#{code}): #{msg}"
    end
  end

  @doc false
  # Syncs current commit and returns the SHA (for use in completion)
  def sync_and_get_current_commit(%LoopState{} = state) do
    repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

    current_sha =
      case Git.rev_parse(repo_path) do
        {:ok, sha} -> sha
        {:error, code, msg} -> raise "Git rev_parse failed (#{code}): #{msg}"
      end

    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)

    if agent_state.phylo_node.current_commit != current_sha do
      updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
      AgentScheduler.update_phylo_node(state.agent_id, updated_phylo)
    end

    current_sha
  end

  # --- Main Turn ---

  @doc false
  def do_turn(%LoopState{} = state, effective_tools_fn, subagent_modules, loop_fn, trigger_recovery_fn) do
    context = state.context
    tools = effective_tools_fn.(state)

    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    max_retries = agent_state.max_retries
    llm_gen_opts = agent_state.llm_generation_params

    {:ok, response, _llm_duration} =
      AgentScheduler.with_llm_slot(state.agent_id, fn ->
        retry with:
                exponential_backoff(1_000)
                |> randomize()
                |> cap(60_000)
                |> Stream.take(max_retries) do
          with llm_start <- System.monotonic_time(:millisecond),
               {:ok, stream_resp} <-
                 ReqLLM.stream_text(
                   current_model(),
                   context,
                   Keyword.merge([tools: tools], llm_gen_opts)
                 ),
               {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_resp),
               llm_end <- System.monotonic_time(:millisecond),
               :ok <- ensure_tool_calls(response, state.agent_id) do
            {:ok, response, llm_end - llm_start}
          else
            {:error, :no_tool_calls} = err ->
              # Warning already logged in ensure_tool_calls/2; just propagate for retry.
              err

            {:error, reason} ->
              Logger.warning(
                "Agent #{state.agent_id}: LLM request failed, retrying... Reason: #{inspect(reason)}"
              )

              {:error, reason}
          end
        end
        |> case do
          {:ok, _response, _llm_duration} = result ->
            result

          {:error, reason} ->
            if EvoGit.Agent.TruncationFeedback.is_rate_limit_error?(reason) do
              AgentScheduler.report_llm_error(state.agent_id, :rate_limit)
            end

            raise "LLM request failed after #{max_retries} retries: #{inspect(reason)}"
        end
      end)

    # Track current context length (replace, don't accumulate)
    usage = ReqLLM.Response.usage(response)

    current_tokens =
      if is_map(usage) do
        usage.input_tokens + usage.output_tokens + Map.get(usage, :reasoning_tokens, 0)
      else
        # Usage is nil - can happen with some providers or cached responses
        # Keep the previous token count
        Logger.warning(
          "Agent #{state.agent_id}: LLM response doesn't contain token usage info."
        )

        state.total_tokens
      end

    state = %{state | total_tokens: current_tokens}

    # Accumulate cumulative usage (separate from total_tokens used for compression)
    turn_usage = Usage.from_response_usage(usage)
    state = %{state | usage: Usage.add(state.usage, turn_usage)}

    tool_calls =
      ReqLLM.Response.tool_calls(response)
      |> Enum.map(&ReqLLM.ToolCall.from_map/1)

    # Validate tool calls have IDs
    invalid_calls = Enum.filter(tool_calls, fn call -> is_nil(Map.get(call, :id)) end)

    if invalid_calls != [] do
      Logger.error(
        "Agent #{state.agent_id}: Found #{length(invalid_calls)} tool calls without IDs: #{inspect(invalid_calls)}"
      )
    end

    # Use the updated context from response (already has assistant message appended)
    # Compact reasoning_details to avoid N small fragments from streaming
    compacted_context = compact_reasoning_details(response.context)
    new_turn = state.turn + 1
    compacted_context = EvoGit.Agent.ContextBuilder.tag_context_tail_with_turn(compacted_context, new_turn)
    state = %{state | context: compacted_context, turn: new_turn}

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
        if EvoGit.Agent.grace_period_continue_failed?(state) do
          {:error, :recovery_failed}
        else
          # Pick up updated delegation hints from tool execution
          updated_hints = Process.get(:delegation_hints, state.delegation_hints)
          Process.delete(:delegation_hints)

          updated_read_hints =
            Process.get(:read_delegation_hints, state.read_delegation_hints)

          Process.delete(:read_delegation_hints)

          # Detect subagent calls to reset the middle-warning counter
          had_subagent_call =
            Enum.any?(tool_calls, fn call ->
              subagent_module_for(call.name, subagent_modules) != nil
            end)

          new_turns_since = if had_subagent_call, do: 0, else: state.turns_since_subagent + 1

          tagged_tool_responses =
            Enum.map(tool_responses, &EvoGit.Agent.ContextBuilder.tag_message_turn(&1, state.turn))

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

          EvoGit.Agent.ContextBuilder.sync_context_to_ets(state.agent_id, state.context)

          # Sync accumulated subagent usage to ETS
          AgentScheduler.batch_update_agent(state.agent_id, usage: state.usage)

          loop_fn.(state)
        end

      {:error, :protocol_violation} ->
        if state.in_grace_period do
          {:error, :recovery_failed}
        else
          trigger_recovery_fn.(state, "agent stopped calling tools")
        end
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
  # Defensive fallback: an LLM response with zero tool calls is now detected
  # inside the do_turn retry loop (via ensure_tool_calls/2), so an empty list
  # should never reach here in normal operation. Kept as a guard so any
  # unexpected empty-list input degrades to a protocol violation rather than a
  # crash in process_regular_tool_calls/3.
  def process_tool_calls([], _state, _subagent_modules), do: {:error, :protocol_violation}

  def process_tool_calls(tool_calls, %LoopState{} = state, subagent_modules)
       when is_list(tool_calls) and tool_calls != [] do
    complete_call = Enum.find(tool_calls, &(&1.name == @complete_tool))

    if complete_call do
      handle_complete_call(complete_call, state, tool_calls)
    else
      process_regular_tool_calls(tool_calls, state, subagent_modules)
    end
  end

  @doc false
  # Detects an LLM response with zero tool calls. Such responses are treated as
  # a retriable LLM failure (logged + retried in the do_turn retry loop) rather
  # than a fatal protocol violation. Returns :ok when tool calls are present,
  # otherwise {:error, :no_tool_calls} (after logging a warning).
  def ensure_tool_calls(response, agent_id) do
    if ReqLLM.Response.tool_calls(response) == [] do
      Logger.warning("Agent #{agent_id}: LLM returned no tool calls, retrying...")
      {:error, :no_tool_calls}
    else
      :ok
    end
  end

  @doc false
  def handle_complete_call(complete_call, %LoopState{in_grace_period: grace} = state, tool_calls) do
    # Check if git status validation is enabled (default: true).
    # During the grace period, skip the dirty workspace check entirely: the
    # agent gets exactly one recovery turn, and a dirty workspace would return
    # {:continue, ...} → grace_period_continue_failed?/1 → :recovery_failed.
    # That deadlocks the agent (it can neither commit nor complete). The
    # priority during the grace turn is salvaging whatever is already
    # committed — the :end/:critical warnings already prompted a commit.
    check_git_status =
      not state.in_grace_period and
        Map.get(complete_call.arguments, "check_git_status") != false

    if grace or not check_git_status do
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
              tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"
              tool_result(tool_call_id, call.name, warning_msg)
            end)

          {:continue, tool_responses, nil}

        {:clean, _} ->
          do_complete(complete_call, state)
      end
    end
  end

  @doc false
  def do_complete(complete_call, %LoopState{} = state) do
    # Sync the current commit before completing
    commit_sha = sync_and_get_current_commit(state)

    result =
      Map.get(complete_call.arguments, "result") ||
        Map.get(complete_call.arguments, :result, "Task finished.")

    # Get metadata from agent state
    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    depth = AgentScheduler.current_depth()

    final_result =
      CompleteTask.complete(
        state.agent_id,
        result,
        commit_sha,
        base_commit: agent_state.phylo_node.base_commit,
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
        compression_threshold: EvoGit.Defaults.compression_threshold_tokens()
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
        subagent_module_for(call.name, subagent_modules) != nil
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
      Process.get(:evogit_repo_root) || raise "evogit_repo_root not in process dictionary"

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
    conflict_files =
      case Git.conflict_files(repo_path) do
        {:ok, files} -> files
        _ -> []
      end

    # Execute tools sequentially, threading delegation hints through
    {results, final_hints, read_final_hints} =
      Enum.reduce(indexed_calls, {[], initial_hints, read_initial_hints}, fn {call, index},
                                                                             {acc_results,
                                                                              hints,
                                                                              read_hints} ->
        tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"

        tool_timeout =
          Map.get(call.arguments, "timeout", EvoGit.Agent.DelegationHints.default_tool_timeout())

        tool_timeout = min(tool_timeout, max_timeout)

        output =
          AgentScheduler.with_tool_slot(agent_id, fn ->
            task =
              Task.async(fn ->
                EvoGit.Agent.Tools.execute(
                  call.name,
                  call.arguments,
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
                  OutputSanitizer.sanitize_and_truncate(result, call.name, call.arguments)

                EvoGit.Agent.TruncationFeedback.append_truncation_feedback(
                  sanitized,
                  truncation_info,
                  call.name
                )

              {:exit, reason} ->
                "Error: Tool execution crashed: #{inspect(reason)}"

              nil ->
                "Error: Tool execution timed out after #{tool_timeout}ms"
            end
          end)

        output = maybe_append_redundant_cd_warning(output, call, repo_path, repo_root)

        # Track delegation hints for write tools (skip during conflict resolution)
        {output, hints} =
          if threshold > 0 do
            child_paths =
              EvoGit.Agent.DelegationHints.extract_child_paths(
                call.name,
                call.arguments,
                node_path,
                repo_path
              )

            child_paths =
              EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(
                child_paths,
                conflict_files
              )

            EvoGit.Agent.DelegationHints.maybe_append_delegation_hint(
              output,
              hints,
              child_paths,
              threshold
            )
          else
            {output, hints}
          end

        # Track read delegation hints for read tools (skip during conflict resolution)
        {output, read_hints} =
          if read_threshold > 0 do
            read_child_paths =
              EvoGit.Agent.DelegationHints.extract_read_child_paths(
                call.name,
                call.arguments,
                node_path,
                repo_path
              )

            read_child_paths =
              EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(
                read_child_paths,
                conflict_files
              )

            EvoGit.Agent.DelegationHints.maybe_append_read_delegation_hint(
              output,
              read_hints,
              read_child_paths,
              read_threshold,
              delegation_level
            )
          else
            {output, read_hints}
          end

        {acc_results ++ [{index, tool_call_id, call.name, output}], hints, read_hints}
      end)

    # Store updated hints in process dictionary for do_turn to pick up
    Process.put(:delegation_hints, final_hints)
    Process.put(:read_delegation_hints, read_final_hints)

    results
  end

  # --- Redundant CD Warning ---
  # The "you don't need to cd into your worktree" warning fires only once
  # per agent run (tracked via the process dictionary), unlike the
  # wrong-path cd warnings which fire every time.

  @doc false
  def maybe_append_redundant_cd_warning(output, call, repo_path, repo_root) do
    if call.name in ["run_bash", "run_powershell"] do
      command = Map.get(call.arguments, "command", "")

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

  @doc false
  def subagent_module_for(tool_name, subagent_mods) do
    Enum.find(subagent_mods, fn mod -> mod.subagent_tool_name() == tool_name end)
  end
end
