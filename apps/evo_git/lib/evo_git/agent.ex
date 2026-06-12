defmodule EvoGit.Agent do
  @moduledoc """
  A stateful pure-function loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.

  Agent state follows the design spec:
  - `context_node` (spatial): the node in the Context Tree
  - `phylo_node` (temporal): git commit state with `base_commit` and `current_commit`

  The agent reads its spatial/temporal state from the `:evogit_agent_state` ETS
  table managed by `EvoGit.AgentScheduler`. The worktree path lives inside
  `phylo_node.repo` and is re-read at the start of **every turn** via
  `load_worktree_path/1`. This ensures correctness when an agent is rescheduled
  to a different worktree after yielding (e.g., during subagent delegation).

  Scheduling metadata (status, worktree assignment, parent tracking) lives in
  a separate `:evogit_sched_meta` table owned by the scheduler — agents never
  read or write that table.

  ## Prompting Rules
  - **System Prompt:** Used STRICTLY to define the agent's behavior, rules, and persona.
    It must not contain the objective or the context tree.
  - **User Prompt:** The framework automatically injects the current Context Tree and
    the user's objective (the query) as user prompts.
  """

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.Agent.OutputSanitizer
  alias EvoGit.Agent.Tools.CompleteTask
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage

  @type state :: LoopState.t()

  @doc """
  Extracts the tool name from a tool schema struct.
  """
  def tool_name(%{name: name}), do: name
  def tool_name(_), do: nil

  defmacro __using__(_opts) do
    quote do
      require Logger
      use Retry

      @default_max_turns 128
      # 10 seconds default timeout for tools that don't specify their own
      # Normally these are simple tools that should respond quickly.
      # The max timeout for any tool is capped at 30 minutes to prevent runaway executions.
      @default_tool_timeout 10_000
      @max_tool_timeout 1_800_000
      @complete_tool "complete_task"
      # Number of write-tool calls to the same child directory before nudging
      # the agent to spawn a subagent. Set to 0 to disable delegation hints.
      @delegation_hint_threshold 5
      # Write tools whose file paths should be tracked for delegation hints
      @write_tools_for_delegation ~w(write_file edit_file create_files make_dir write_context edit_context)

      import ReqLLM.Context, only: [user: 1, assistant: 1, system: 1, tool_result: 3]

      defp current_model do
        agent_id = EvoGit.AgentScheduler.current_agent_id()
        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
        agent_state.llm_model
      end

      defp current_generation_params do
        agent_id = EvoGit.AgentScheduler.current_agent_id()
        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
        agent_state.llm_generation_params
      end

      # --- Public API ---

      @doc """
      Runs the agent asynchronously in a Task, returning the Task struct.
      """
      def run_task(query) do
        Task.async(fn ->
          run(query)
        end)
      end

      @doc """
      Runs the agent synchronously, blocking until it completes.

      The agent reads its spatial/temporal state from ETS every turn via
      `load_worktree_path/1`, ensuring it always has the correct worktree path.
      Agent state is synced to ETS every turn for dashboard visibility.
      The dashboard reads the `context` field from `evogit_agent_state` table.
      """
      def run(objective) do
        agent_id = EvoGit.AgentScheduler.current_agent_id()

        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)

        # Validate that the assigned node path exists
        node_path = agent_state.context_node.path
        repo_path = Process.get(:repo_path)
        full_path = Path.join(repo_path, node_path)

        unless File.exists?(full_path) do
          Logger.error(
            "Agent #{agent_id}: Assigned node path does not exist: #{full_path} (node_path=#{node_path})"
          )

          {:error, :path_not_exist}
        else
          # Build context tree and merge into first user prompt
          # Use :repo_path (set by scheduler to worktree path)
          context_tree = build_dynamic_context(%{node_path: node_path, repo_path: repo_path})
          foreign_repos_section = build_foreign_repos_section(agent_state.foreign_repos)
          objective_prompt = if objective, do: "Your Task:\n#{objective}", else: ""
          combined_prompt = "Current Context Tree:\n#{context_tree}\n\n#{foreign_repos_section}\n\n#{objective_prompt}"

          context = ReqLLM.Context.new([system(system_prompt()), user(combined_prompt)])

          # Load skill schemas hierarchically — only skills enabled in the
          # Context Tree (from root to this agent's node) are available.
          repo_root = Process.get(:evogit_repo_root)
          skill_schemas = if repo_root && is_binary(repo_root) do
            all_skills = EvoGit.Skills.load_skills(repo_root)
            skill_names = EvoGit.Skills.hierarchical_skill_names(node_path, repo_path)
            all_skills
            |> EvoGit.Skills.filter_skills(skill_names)
            |> EvoGit.Skills.to_tool_schemas()
          else
            []
          end

          max_turns = agent_state.max_turns || @default_max_turns

          state = %LoopState{
            agent_id: agent_id,
            agent_module: __MODULE__,
            depth: EvoGit.AgentScheduler.current_depth(),
            node_path: node_path,
            context: context,
            max_turns: max_turns,
            skill_schemas: skill_schemas,
            foreign_repos: agent_state.foreign_repos
          }

          # Sync initial context to ETS for dashboard
          EvoGit.AgentScheduler.update_agent_context(agent_id, context)

          Process.put(:delegation_hints, %{})
          loop(state)
        end
      end

      # --- Internal Execution Logic ---

      defp load_worktree_path(state) do
        case EvoGit.AgentScheduler.get_agent_state(state.agent_id) do
          {:ok, %AgentState{phylo_node: %{repo: wt}}} when not is_nil(wt) ->
            Process.put(:repo_path, wt)
            %{state | repo_path: wt}

          {:ok, %AgentState{phylo_node: phylo_node}} when is_nil(phylo_node.repo) ->
            raise "PhyloNode repo is nil for agent #{state.agent_id} - scheduler bug"

          _ ->
            raise "No ETS state found for agent #{state.agent_id} - scheduler bug"
        end
      end

      defp sync_current_commit_after_tools(state) do
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

      # Syncs current commit and returns the SHA (for use in completion)
      defp sync_and_get_current_commit(state) do
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

      # Checks and sends warnings when approaching time/turn limits.
      # Threshold configs and messages live in EvoGit.Agents.Warnings.
      defp check_limit_warnings(state) do
        state
        |> maybe_warn_limit(:turns, EvoGit.Agents.Warnings.turn_thresholds(state.max_turns))
      end

      defp maybe_warn_limit(state, :turns, thresholds) do
        percentage_used = div(state.turn * 100, state.max_turns)
        last_warned = state.last_warned_turns_percent
        threshold_values = Enum.map(thresholds, fn {t, _} -> t end)

        {should_warn, new_last_warned} =
          check_thresholds(percentage_used, last_warned, threshold_values)

        if should_warn do
          {_, msg_fn} = Enum.find(thresholds, fn {t, _} -> t == new_last_warned end)
          warning_msg = msg_fn.(percentage_used, state)

          new_context = ReqLLM.Context.append(state.context, user(warning_msg))
          %{state | context: new_context, last_warned_turns_percent: new_last_warned}
        else
          state
        end
      end

      # Returns {should_warn, new_last_warned}
      defp check_thresholds(current_percent, last_warned, thresholds) do
        passed_thresholds =
          thresholds
          |> Enum.filter(&(&1 > last_warned and &1 <= current_percent))
          |> Enum.sort()

        case passed_thresholds do
          [] -> {false, last_warned}
          [h | _] -> {true, h}
        end
      end

      defp loop(state) do
        # Re-read worktree from ETS every turn
        state = load_worktree_path(state)

        context_before = state.context

        state =
          EvoGit.Agent.ContextCompression.compress_if_needed(state,
            agent_id: state.agent_id,
            llm_model: current_model(),
            llm_generation_params: current_generation_params()
          )

        state = check_limit_warnings(state)

        # Sync context to ETS after any updates (compression, warnings)
        if context_before != state.context do
          sync_context_to_ets(state.agent_id, state.context)
        end

        cond do
          state.turn >= state.max_turns ->
            trigger_recovery(state, "max turns (#{state.max_turns}) exceeded")

          true ->
            do_turn(state)
        end
      end

      defp trigger_recovery(state, reason) do
        warning_msg = """
        You have exceeded the execution limit (#{reason}).
        You MUST call `#{@complete_tool}` immediately with your best answer explaining the situation.
        Do not call any other tools.
        """

        new_context = ReqLLM.Context.append(state.context, user(warning_msg))

        state = %{state | context: new_context, in_grace_period: true}
        loop(state)
      end

      defp do_turn(state) do
        context = state.context
        tools = effective_tools(state)

        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
        max_retries = agent_state.max_retries
        llm_gen_opts = agent_state.llm_generation_params

        {:ok, response, llm_duration} =
          AgentScheduler.with_llm_slot(state.agent_id, fn ->
            retry with:
                    exponential_backoff(1_000)
                    |> randomize()
                    |> cap(60_000)
                    |> Stream.take(max_retries) do
              with llm_start <- System.monotonic_time(:millisecond),
                   {:ok, stream_resp} <-
                     ReqLLM.stream_text(current_model(), context, Keyword.merge([tools: tools], llm_gen_opts)),
                   {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_resp),
                   llm_end <- System.monotonic_time(:millisecond) do
                {:ok, response, llm_end - llm_start}
              else
                {:error, reason} ->
                  Logger.warning(
                    "Agent #{state.agent_id}: LLM request failed, retrying... Reason: #{inspect(reason)}"
                  )

                  {:error, reason}
              end
            end
            |> case do
              {:ok, response, llm_duration} = result ->
                result

              {:error, reason} ->
                if is_rate_limit_error?(reason) do
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
        state = %{state | context: compacted_context, turn: state.turn + 1}
        sync_context_to_ets(state.agent_id, state.context)
        sync_usage_to_ets(state.agent_id, state.usage)

        # Initialize delegation hints in process dictionary for this turn
        Process.put(:delegation_hints, state.delegation_hints)

        case process_tool_calls(tool_calls, state) do
          {:complete, final_result} ->
            {:ok, final_result}

          {:continue, tool_responses} ->
            # Pick up updated delegation hints from tool execution
            updated_hints = Process.get(:delegation_hints, state.delegation_hints)
            Process.delete(:delegation_hints)
            state = %{state | context: ReqLLM.Context.append(state.context, tool_responses), delegation_hints: updated_hints}
            sync_context_to_ets(state.agent_id, state.context)
            loop(state)

          {:error, :protocol_violation} ->
            if state.in_grace_period do
              {:error, :recovery_failed}
            else
              trigger_recovery(state, "agent stopped calling tools")
            end
        end
      end

      # Compacts fragmented reasoning_details from streaming into a single entry.
      # When LLMs stream responses, reasoning/thinking content arrives in multiple
      # small fragments. This function merges them into one entry to keep the
      # context lean (especially important for ETS storage and dashboard display).
      defp compact_reasoning_details(context) do
        messages = context.messages

        # Find the last assistant message
        last_assistant_idx =
          messages
          |> Enum.reverse()
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

      defp process_tool_calls([], _state), do: {:error, :protocol_violation}

      defp process_tool_calls(tool_calls, state) do
        complete_call = Enum.find(tool_calls, &(&1.name == @complete_tool))

        if complete_call do
          handle_complete_call(complete_call, state, tool_calls)
        else
          process_regular_tool_calls(tool_calls, state)
        end
      end

      defp handle_complete_call(complete_call, state, tool_calls) do
        # Check if git status validation is enabled (default: true)
        check_git_status =
          Map.get(complete_call.arguments, "check_git_status") != false

        if check_git_status do
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

              {:continue, tool_responses}

            {:clean, _} ->
              do_complete(complete_call, state)
          end
        else
          do_complete(complete_call, state)
        end
      end

      defp do_complete(complete_call, state) do
        # Sync the current commit before completing
        commit_sha = sync_and_get_current_commit(state)

        result =
          Map.get(complete_call.arguments, "result") ||
            Map.get(complete_call.arguments, :result, "Task finished.")

        # Get metadata from agent state
        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
        depth = EvoGit.AgentScheduler.current_depth()

        final_result =
          CompleteTask.complete(
            state.agent_id,
            result,
            commit_sha,
            base_commit: agent_state.phylo_node.base_commit,
            parent_id: agent_state.parent_id,
            depth: depth,
            objective: agent_state.objective,
            usage: state.usage
          )

        {:complete, final_result}
      end

      defp process_regular_tool_calls(tool_calls, state) do
        # 1. Index: Attach index to each call
        indexed_calls = Enum.with_index(tool_calls)

        # 3. Split: Partition into subagent and standard calls
        {indexed_subagent_calls, indexed_standard_calls} =
          Enum.split_with(indexed_calls, fn {call, _index} ->
            subagent_module_for(call.name) != nil
          end)

        # 4. Batch: Process each batch
        indexed_standard_results = process_standard_calls(indexed_standard_calls, state)

        {indexed_subagent_results, merge_message} =
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

        {:continue, all_results}
      end

      defp process_standard_calls(indexed_calls, state) do
        repo_root =
          Process.get(:evogit_repo_root) || raise "evogit_repo_root not in process dictionary"

        indexed_results = batch_execute_tools(indexed_calls, @max_tool_timeout, repo_root)

        # Sync current_commit after tool execution for dashboard visibility
        sync_current_commit_after_tools(state)

        indexed_results
      end

      defp batch_execute_tools(indexed_calls, max_timeout, repo_root) do
        agent_id = EvoGit.AgentScheduler.current_agent_id()
        repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

        {:ok, %{context_node: %{path: node_path}}} =
          EvoGit.AgentScheduler.get_agent_state(agent_id)

        threshold = delegation_hint_threshold()
        initial_hints = Process.get(:delegation_hints, %{})

        # Execute tools sequentially, threading delegation hints through
        {results, final_hints} =
          Enum.reduce(indexed_calls, {[], initial_hints}, fn {call, index}, {acc_results, hints} ->
            tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"

            tool_timeout = Map.get(call.arguments, "timeout", @default_tool_timeout)
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
                    {sanitized, truncation_info} = OutputSanitizer.sanitize_and_truncate(result, call.name, call.arguments)
                    append_truncation_feedback(sanitized, truncation_info, call.name)

                  {:exit, reason} ->
                    "Error: Tool execution crashed: #{inspect(reason)}"

                  nil ->
                    "Error: Tool execution timed out after #{tool_timeout}ms"
                end
              end)

            # Track delegation hints for write tools
            {output, hints} =
              if threshold > 0 do
                child_paths = extract_child_paths(call.name, call.arguments, node_path, repo_path)
                maybe_append_delegation_hint(output, hints, child_paths, threshold)
              else
                {output, hints}
              end

            {acc_results ++ [{index, tool_call_id, call.name, output}], hints}
          end)

        # Store updated hints in process dictionary for do_turn to pick up
        Process.put(:delegation_hints, final_hints)

        results
      end

      # --- Delegation Hinting ---
      # Tracks how many write-tool calls target child directories of the agent's
      # assigned node. When the count exceeds a threshold, a friendly nudge is
      # appended to the tool output suggesting the agent spawn a subagent for
      # that child directory instead of editing files there directly.

      defp delegation_hint_threshold do
        # Allow config to override the compile-time default
        EvoGit.Config.resolve([:scheduler, :delegation_hint_threshold]) || @delegation_hint_threshold
      end

      @doc false
      defp extract_child_paths(tool_name, args, node_path, repo_path) do
        if tool_name in @write_tools_for_delegation do
          do_extract_child_paths(tool_name, args, node_path, repo_path)
        else
          []
        end
      end

      defp do_extract_child_paths("create_files", args, node_path, repo_path) do
        case EvoGit.Agent.Tools.Shared.fetch_array_arg(args, "paths") do
          {:ok, paths} -> Enum.flat_map(paths, &path_to_child_dir(&1, node_path, repo_path))
          _ -> []
        end
      end

      defp do_extract_child_paths("make_dir", args, node_path, repo_path) do
        case EvoGit.Agent.Tools.Shared.fetch_array_arg(args, "paths") do
          {:ok, paths} -> Enum.flat_map(paths, &path_to_child_dir(&1, node_path, repo_path))
          _ -> []
        end
      end

      defp do_extract_child_paths(tool_name, args, node_path, repo_path)
           when tool_name in ~w(write_context edit_context) do
        case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "dir_path") do
          {:ok, dir_path} -> path_to_child_dir(dir_path, node_path, repo_path)
          _ -> []
        end
      end

      defp do_extract_child_paths(_tool_name, args, node_path, repo_path) do
        # write_file, edit_file
        case EvoGit.Agent.Tools.Shared.fetch_string_arg(args, "file_path") do
          {:ok, file_path} -> file_path_to_child_dir(file_path, node_path, repo_path)
          _ -> []
        end
      end

      # For file paths: extract the directory and find the first child segment
      defp file_path_to_child_dir(file_path, node_path, repo_path) do
        dir_path = Path.dirname(file_path)
        path_to_child_dir(dir_path, node_path, repo_path)
      end

      # For directory paths: find the first child directory segment under node_path
      defp path_to_child_dir(dir_path, node_path, repo_path) do
        expanded = EvoGit.Agent.Tools.Shared.expand_path(dir_path, repo_path)
        relative = Path.relative_to(expanded, repo_path)
        normalized_target = EvoGit.Agent.Tools.Shared.normalize_relpath(relative)
        normalized_node = EvoGit.Agent.Tools.Shared.normalize_relpath(node_path)

        # Only track strict children (not the node itself)
        if normalized_node == "./" do
          # Root node: extract first path segment as child
          extract_first_segment(normalized_target)
        else
          if String.starts_with?(normalized_target, normalized_node <> "/") do
            # Extract the first segment under node_path
            remainder = String.replace_prefix(normalized_target, normalized_node <> "/", "")
            extract_first_segment_from_remainder(remainder, normalized_node)
          else
            []
          end
        end
      end

      defp extract_first_segment("./"), do: []
      defp extract_first_segment(path) do
        # Remove leading "./" and take first segment
        stripped = String.replace_prefix(path, "./", "")
        case String.split(stripped, "/", parts: 2) do
          [first | _] when first != "" ->
            normalized = "./" <> first
            [normalized]
          _ ->
            []
        end
      end

      defp extract_first_segment_from_remainder(remainder, node_path) do
        case String.split(remainder, "/", parts: 2) do
          [first | _] when first != "" ->
            [node_path <> "/" <> first]
          _ ->
            []
        end
      end

      defp update_delegation_hints(hints, child_paths) do
        Enum.reduce(child_paths, hints, fn child_path, acc ->
          current = Map.get(acc, child_path, %{count: 0, hint_shown: false})
          Map.put(acc, child_path, %{current | count: current.count + 1})
        end)
      end

      defp maybe_append_delegation_hint(output, hints, child_paths, threshold) do
        new_hints = update_delegation_hints(hints, child_paths)

        # Check if any child path has crossed the threshold for the first time
        hint =
          child_paths
          |> Enum.filter(fn child_path ->
            entry = Map.get(new_hints, child_path)
            entry && entry.count >= threshold && !entry.hint_shown
          end)
          |> Enum.map(fn child_path ->
            "💡 **Delegation Hint**: You've been editing files in `#{child_path}` for #{threshold}+ turns. " <>
              "Consider spawning a subagent at `#{child_path}` to handle this work more efficiently. " <>
              "The subagent will run in its own isolated worktree and can handle the implementation autonomously."
          end)
          |> Enum.join("\n\n")

        {updated_output, updated_hints} =
          if hint != "" do
            # Mark these paths as hint-shown
            marked_hints =
              Enum.reduce(child_paths, new_hints, fn child_path, acc ->
                entry = Map.get(acc, child_path)
                if entry && entry.count >= threshold do
                  Map.put(acc, child_path, %{entry | hint_shown: true})
                else
                  acc
                end
              end)

            {output <> "\n\n" <> hint, marked_hints}
          else
            {output, new_hints}
          end

        {updated_output, updated_hints}
      end

      defp is_rate_limit_error?(reason) do
        reason_str = inspect(reason)

        String.contains?(reason_str, "rate_limit") or
          String.contains?(reason_str, "quota") or
          String.contains?(reason_str, "429") or
          String.contains?(reason_str, "resource_exhausted")
      end

      defp append_truncation_feedback(output, nil, _tool_name), do: output

      defp append_truncation_feedback(output, truncation_info, tool_name) do
        suggestion = tool_truncation_suggestion(tool_name)

        feedback =
          """
          ---
          ⚠️ **Output Truncated** (#{format_truncation_reason(truncation_info)})
          Original size: #{format_byte_size(truncation_info.original_size)} → Truncated to: #{format_byte_size(truncation_info.truncated_size)}

          **Suggestion:** #{suggestion}
          """
          |> String.trim()

        output <> "\n\n" <> feedback
      end

      defp tool_truncation_suggestion(tool_name) when tool_name in ["run_bash", "run_powershell"] do
        "Consider using `head`, `tail`, `grep`, or piping output to a file. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion("read_file") do
        "Consider using `offset` and `limit` parameters to read only the needed portion. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion("rg") do
        "Consider narrowing the search pattern or specifying a more targeted path. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion("curl") do
        "The HTTP response was large. You can pass `max_bytes` to increase the output limit if you need more of the response."
      end

      defp tool_truncation_suggestion("run_git") do
        "Consider using flags like `--stat`, `--oneline`, or `-n <count>` to reduce output. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion("search_history") do
        "Consider reducing `max_count` or narrowing the search pattern. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion("search_web") do
        "Consider reducing `max_results`. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion("search_context") do
        "Consider narrowing the pattern or specifying a more targeted path. You can also pass `max_bytes` to increase the output limit."
      end

      defp tool_truncation_suggestion(_tool_name) do
        "Consider using more specific arguments to reduce output. You can also pass `max_bytes` to increase the output limit."
      end

      defp format_truncation_reason(%{reason: :size_exceeded}), do: "output exceeded size limit"
      defp format_truncation_reason(%{reason: :invalid_utf8}), do: "invalid UTF-8 data was repaired/truncated"

      defp format_byte_size(bytes) do
        cond do
          bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)} MB"
          bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
          true -> "#{bytes} bytes"
        end
      end

      # Formats git status --porcelain output for display
      # Format: "XY filename" where X = staged, Y = unstaged
      # --- Helpers ---

      defp build_dynamic_context(state) do
        case EvoGit.Core.ContextNode.build_context(state.node_path, state.repo_path) do
          {:ok, context} -> context
          {:error, _} -> "Current Path: '#{state.node_path}'."
        end
      end

      defp build_foreign_repos_section(foreign_repos) do
        repos =
          foreign_repos
          |> Enum.reject(&EvoGit.Core.ForeignRepo.primary?(&1.id))

        if repos == [] do
          ""
        else
          rows =
            repos
            |> Enum.map(fn repo -> "| #{repo.name} | :#{repo.id} | #{repo.root} |" end)
            |> Enum.join("\n")

          "# Foreign Repositories\n\n" <>
            "| Name | ID | Path |\n|------|----|------|\n#{rows}\n\n" <>
            "Use absolute paths (e.g., `#{hd(repos).root}`) when delegating to foreign repositories."
        end
      end

      defp sync_context_to_ets(agent_id, context) do
        EvoGit.AgentScheduler.update_agent_context(agent_id, context)
      end

      defp sync_usage_to_ets(agent_id, usage) do
        EvoGit.AgentScheduler.update_agent_usage(agent_id, usage)
      end


      def available_tools do
        EvoGit.Agent.Tools.schemas() ++ subagent_schemas() ++ [CompleteTask.schema()]
      end

      @doc """
      Returns the tool name used when this agent is spawned as a subagent.
      Override this in your agent module.
      """
      def subagent_tool_name, do: nil

      @doc """
      Returns the tool description used when this agent is spawned as a subagent.
      Override this in your agent module.
      """
      def subagent_tool_description, do: ""

      @doc """
      Returns the agent type: `:read` or `:read_write`.

      - `:read` - Read-only agents can only read files and update CONTEXT.md files
      - `:read_write` - Read-write agents can read, write, and modify code

      Override this in your agent module to declare its type.

      ## Rules for Subagent Delegation

      - **Read agents** can only spawn other read subagents
      - **Read-write agents** can spawn both read and read-write subagents,
        but read-write subagents must operate within the same node or child nodes
        of the parent agent's assigned node (no permission escalation)

      ## Example

          def agent_type, do: :read_write
      """
      def agent_type, do: :read_write

      @doc """
      Returns a list of agent modules that can be spawned as subagents.
      The framework automatically generates tool schemas and execution logic
      from each module's `subagent_tool_name/0` and `subagent_tool_description/0`.

      Override this in your agent module to declare subagents.

      ## Example

          def subagent_modules do
            [EvoGit.Agents.CodebaseInvestigator]
          end
      """
      def subagent_modules, do: []

      @doc false
      def subagent_tools do
        Enum.map(subagent_modules(), & &1.subagent_tool_name())
      end

      defp subagent_schemas do
        Enum.map(subagent_modules(), fn mod ->
          ReqLLM.tool(
            name: mod.subagent_tool_name(),
            description: mod.subagent_tool_description(),
            parameter_schema: %{
              "type" => "object",
              "properties" => %{
                "path" => %{
                  "type" => "string",
                  "description" =>
                    "The path to a DIRECTORY where the subagent should operate. " <>
                      "Use a RELATIVE path from the repository root for the current project (e.g., './src/auth', './lib/utils'). " <>
                      "Use an ABSOLUTE path to delegate to a FOREIGN REPOSITORY configured in evogit.toml " <>
                      "(e.g., '/Source/original-proj'). MUST be a directory node, NOT a file path.\n\n" <>
                      "IMPORTANT: When delegating to a foreign repo, prefer using the repository ROOT path " <>
                      "(e.g., '/Source/original-proj' rather than '/Source/original-proj/src'). " <>
                      "Since you have no prior knowledge of the foreign repo's structure, starting at the root " <>
                      "allows the subagent to discover the codebase layout via its CONTEXT.md routing table. " <>
                      "Spawning at a non-root path is allowed but discouraged unless you have specific knowledge of that path.\n\n" <>
                      "IMPORTANT: Delegating work to child directories is more efficient than editing files there yourself. " <>
                      "When you find yourself repeatedly editing files in the same child directory, spawn a subagent at that path to handle the work autonomously."
                },
                "objective" => %{
                  "type" => "string",
                  "description" =>
                    "A clear, self-contained objective for the subagent. " <>
                      "Include any relevant context since it starts with a fresh context. " <>
                      "IMPORTANT: The subagent's working directory is automatically set correctly. " <>
                      "Do NOT include worktree paths or `cd` commands in the objective — just describe what to do (e.g., 'run `mix test`'). " <>
                      "Include all relevant context, findings, and file paths so the subagent can start working immediately without re-investigating."
                },
                "commit_id" => %{
                  "type" => "string",
                  "description" =>
                    "Optional: The commit SHA to spawn the subagent on. " <>
                      "Defaults to the current commit if not specified."
                }
              },
              "required" => ["path", "objective"]
            },
            callback: fn _args -> {:ok, nil} end
          )
        end)
      end

      defp subagent_module_for(tool_name) do
        Enum.find(subagent_modules(), fn mod -> mod.subagent_tool_name() == tool_name end)
      end

      defp effective_tools(state) do
        skill_schemas = Map.get(state, :skill_schemas, [])
        all_tools = available_tools() ++ skill_schemas

        if at_max_depth?(state) do
          excluded = MapSet.new(subagent_tools())

          all_tools
          |> Enum.reject(fn tool ->
            name = EvoGit.Agent.tool_name(tool)
            name && MapSet.member?(excluded, name)
          end)
        else
          all_tools
        end
      end

      defp at_max_depth?(state) do
        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
        state.depth >= agent_state.max_depth
      end

      @doc """
      Returns the system prompt that defines the agent's core behavior, persona, and rules.

      IMPORTANT: The system prompt MUST NOT contain dynamic state, the context tree,
      or the specific objective/query. System prompts are strictly for defining
      the agent's behavior. The objective and context tree are automatically
      provided to the agent as user prompts.
      """
      def system_prompt, do: ""

      # Give adopting modules default implementations they can override
      defoverridable available_tools: 0,
                     system_prompt: 0,
                     subagent_tool_name: 0,
                     subagent_tool_description: 0,
                     subagent_modules: 0,
                     agent_type: 0
    end
  end
end
