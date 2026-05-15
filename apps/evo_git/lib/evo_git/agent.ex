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

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.Agent.Tools.CompleteTask

  @type state :: %{context_node: ContextNode.t(), phylo_node: PhyloGraphNode.t()}

  @doc """
  Extracts the tool name from a tool schema struct.
  """
  def tool_name(%{name: name}), do: name
  def tool_name(_), do: nil

  defmacro __using__(_opts) do
    quote do
      require Logger
      use Retry

      @max_turns 64
      # 30 minutes
      @timeout_ms 30 * 60 * 1000
      # 3 minutes
      @grace_period_ms 180 * 1000
      # 10 seconds default timeout for tools that don't specify their own
      # Normally these are simple tools that should respond quickly.
      # The max timeout for any tool is capped at 30 minutes to prevent runaway executions.
      @default_tool_timeout 10_000
      @max_tool_timeout 1_800_000
      @complete_tool "complete_task"

      # Tool output truncation thresholds
      @tool_output_max_bytes 128 * 1024
      @tool_output_truncate_size 8192

      import ReqLLM.Context, only: [user: 1, assistant: 1, system: 1, tool_result: 3]

      defp current_model do
        agent_id = EvoGit.AgentScheduler.current_agent_id()
        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
        agent_state.llm_model
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
      Event streaming is routed through the scheduler's `event_sink` field
      in the ETS agent record.
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

          objective_prompt = if objective, do: "Your Task:\n#{objective}", else: ""
          combined_prompt = "Current Context Tree:\n#{context_tree}\n\n#{objective_prompt}"

          context = ReqLLM.Context.new([system(system_prompt()), user(combined_prompt)])

          state = %{
            agent_id: agent_id,
            depth: EvoGit.AgentScheduler.current_depth(),
            node_path: node_path,
            # Loaded from ETS each turn — see load_worktree_path/1
            repo_path: nil,
            turn: 0,
            context: context,
            in_grace_period: false,
            deadline: System.monotonic_time(:millisecond) + @timeout_ms,
            # Track accumulated LLM time only
            llm_time_ms: 0,
            # Track current context length (in tokens)
            total_tokens: 0,
            # Warning tracking: last percentage warned (starts at 0)
            last_warned_time_percent: 0,
            last_warned_turns_percent: 0
          }

          # Sync initial context to ETS for dashboard
          EvoGit.AgentScheduler.update_agent_context(agent_id, context)

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

              stream_event(state.agent_id, "COMMIT_UPDATED", %{
                new_commit: current_sha
              })
            end

          {:error, code, msg} ->
            raise "Git rev_parse failed (#{code}): #{msg}"
        end
      end

      # Syncs current commit and returns the SHA (for use in completion)
      defp sync_and_get_current_commit(state) do
        repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

        {:ok, current_sha} = Git.rev_parse(repo_path)
        {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)

        if agent_state.phylo_node.current_commit != current_sha do
          updated_phylo = %{agent_state.phylo_node | current_commit: current_sha}
          AgentScheduler.update_phylo_node(state.agent_id, updated_phylo)

          stream_event(state.agent_id, "COMMIT_UPDATED", %{
            new_commit: current_sha
          })
        end

        current_sha
      end

      # Checks and sends warnings when approaching time/turn limits
      # Warning thresholds: 50%, 80%
      defp check_limit_warnings(state) do
        state
        |> maybe_warn_limit(:time, 50, 80)
        |> maybe_warn_limit(:turns, 50, 80)
      end

      defp maybe_warn_limit(state, :time, threshold_a, threshold_b) do
        percentage_used = div(state.llm_time_ms * 100, @timeout_ms)
        last_warned = state.last_warned_time_percent

        thresholds = [threshold_a, threshold_b]

        {should_warn, new_last_warned} =
          check_thresholds(percentage_used, last_warned, thresholds)

        if should_warn do
          time_used_min = Float.round(state.llm_time_ms / 60_000, 1)
          time_limit_min = Float.round(@timeout_ms / 60_000, 1)

          warning_msg =
            if new_last_warned >= 80 do
              """
              [URGENT] You have used approximately #{percentage_used}% of your time budget (#{time_used_min} / #{time_limit_min} minutes).

              STOP working on new tasks. Focus on finishing what you have at hand:
              1. Commit any file changes you have made
              2. Call complete_task as soon as possible

              In your completion message, explain:
              - What has been accomplished
              - What hasn't been done due to the time limit

              You do NOT need to complete everything. A partial completion with clear status is acceptable.
              """
            else
              """
              [NOTICE] You have used approximately #{percentage_used}% of your time budget (#{time_used_min} / #{time_limit_min} minutes).
              Consider accelerating your work by focusing on the most critical aspects of the task.
              """
            end

          new_context = ReqLLM.Context.append(state.context, user(warning_msg))

          %{state | context: new_context, last_warned_time_percent: new_last_warned}
        else
          state
        end
      end

      defp maybe_warn_limit(state, :turns, threshold_a, threshold_b) do
        percentage_used = div(state.turn * 100, @max_turns)
        last_warned = state.last_warned_turns_percent

        thresholds = [threshold_a, threshold_b]

        {should_warn, new_last_warned} =
          check_thresholds(percentage_used, last_warned, thresholds)

        if should_warn do
          warning_msg =
            if new_last_warned >= 80 do
              """
              [URGENT] You have used approximately #{percentage_used}% of your available turns (#{state.turn} / #{@max_turns}).

              STOP working on new tasks. Focus on finishing what you have at hand:
              1. Commit any file changes you have made
              2. Call complete_task as soon as possible

              In your completion message, explain:
              - What has been accomplished
              - What hasn't been done due to the turn limit

              You do NOT need to complete everything. A partial completion with clear status is acceptable.
              """
            else
              """
              [NOTICE] You have used approximately #{percentage_used}% of your available turns (#{state.turn} / #{@max_turns}).
              Consider accelerating your work by focusing on the most critical aspects of the task.
              """
            end

          stream_event(state.agent_id, "BUDGET_WARNING", %{
            type: :turns,
            percentage: percentage_used,
            turns_used: state.turn,
            max_turns: @max_turns
          })

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
        state = try_compress_chat(state)
        state = check_limit_warnings(state)

        # Sync context to ETS after any updates (compression, warnings)
        sync_context_to_ets(state.agent_id, state.context)

        cond do
          state.llm_time_ms >= @timeout_ms and not state.in_grace_period ->
            trigger_recovery(state, "15-minute LLM time limit exceeded")

          state.in_grace_period ->
            now = System.monotonic_time(:millisecond)
            time_left = state.deadline - now

            if time_left <= 0 do
              stream_event(state.agent_id, "ERROR", %{
                error: "Grace period timed out. Agent killed."
              })

              {:error, :timeout}
            else
              do_turn(state)
            end

          state.turn >= @max_turns ->
            trigger_recovery(state, "max turns (#{@max_turns}) exceeded")

          true ->
            do_turn(state)
        end
      end

      defp trigger_recovery(state, reason) do
        stream_event(state.agent_id, "ERROR", %{
          error: "Limit reached: #{reason}. Attempting one final recovery turn."
        })

        warning_msg = """
        You have exceeded the execution limit (#{reason}).
        You MUST call `#{@complete_tool}` immediately with your best answer explaining the situation.
        Do not call any other tools.
        """

        new_context = ReqLLM.Context.append(state.context, user(warning_msg))

        new_deadline = System.monotonic_time(:millisecond) + @grace_period_ms

        state = %{state | context: new_context, in_grace_period: true, deadline: new_deadline}
        loop(state)
      end

      defp do_turn(state) do
        context = state.context
        tools = effective_tools(state)

        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
        max_retries = agent_state.max_retries

        {:ok, response, llm_duration} =
          retry with:
                  exponential_backoff(1_000)
                  |> randomize()
                  |> cap(60_000)
                  |> Stream.take(max_retries) do
            with llm_start <- System.monotonic_time(:millisecond),
                 {:ok, stream_resp} <- ReqLLM.stream_text(current_model(), context, tools: tools),
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

        llm_end = System.monotonic_time(:millisecond)
        state = %{state | llm_time_ms: state.llm_time_ms + llm_duration}

        # Track current context length (replace, don't accumulate)
        usage = ReqLLM.Response.usage(response)

        current_tokens =
          usage.input_tokens + usage.output_tokens + Map.get(usage, :reasoning_tokens, 0)

        state = %{state | total_tokens: current_tokens}

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

        thinking = ReqLLM.Response.thinking(response)
        text = ReqLLM.Response.text(response)

        if thinking && thinking != "" do
          stream_event(state.agent_id, "THOUGHT_CHUNK", %{text: thinking})
        end

        if text && text != "" do
          stream_event(state.agent_id, "THOUGHT_CHUNK", %{text: text})
        end

        # Use the updated context from response (already has assistant message appended)
        state = %{state | context: response.context, turn: state.turn + 1}
        sync_context_to_ets(state.agent_id, state.context)

        case process_tool_calls(tool_calls, state) do
          {:complete, final_result} ->
            {:ok, final_result}

          {:continue, tool_responses} ->
            state = %{state | context: ReqLLM.Context.append(state.context, tool_responses)}
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
        stream_event(state.agent_id, "TOOL_CALL_END", %{
          name: @complete_tool,
          status: "success"
        })

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

        final_result = CompleteTask.complete(
          state.agent_id,
          result,
          commit_sha,
          base_commit: agent_state.phylo_node.base_commit,
          parent_id: agent_state.parent_id,
          depth: depth,
          objective: agent_state.objective
        )

        {:complete, final_result}
      end

      defp process_regular_tool_calls(tool_calls, state) do
        # 1. Index: Attach index to each call
        indexed_calls = Enum.with_index(tool_calls)

        # 2. Stream start events for all calls
        stream_start_events(tool_calls, state)

        # 3. Split: Partition into subagent and standard calls
        {indexed_subagent_calls, indexed_standard_calls} =
          Enum.split_with(indexed_calls, fn {call, _index} ->
            subagent_module_for(call.name) != nil
          end)

        # 4. Batch: Process each batch
        indexed_standard_results = process_standard_calls(indexed_standard_calls, state)

        {indexed_subagent_results, merge_message} =
          process_subagent_calls(indexed_subagent_calls, state)

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

      defp stream_start_events(tool_calls, state) do
        Enum.each(tool_calls, fn call ->
          stream_event(state.agent_id, "TOOL_CALL_START", %{
            name: call.name,
            args: call.arguments
          })
        end)
      end

      defp process_standard_calls(indexed_calls, state) do
        repo_root = Process.get(:evogit_repo_root) || raise "evogit_repo_root not in process dictionary"

        indexed_results = batch_execute_tools(indexed_calls, @max_tool_timeout, repo_root)

        # Sync current_commit after tool execution for dashboard visibility
        sync_current_commit_after_tools(state)

        # Stream end events for all calls
        Enum.each(indexed_results, fn {_index, _tool_call_id, name, _output} ->
          stream_event(state.agent_id, "TOOL_CALL_END", %{name: name})
        end)

        indexed_results
      end

      defp batch_execute_tools(indexed_calls, max_timeout, repo_root) do
        agent_id = EvoGit.AgentScheduler.current_agent_id()
        repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

        {:ok, %{context_node: %{path: node_path}}} = EvoGit.AgentScheduler.get_agent_state(agent_id)

        # Execute tools sequentially to avoid parallel execution issues
        # For example, running two git in parallel would result in git lock issues, and wasting tokens.
        results =
          Enum.map(indexed_calls, fn {call, index} ->
            tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"

            tool_timeout = Map.get(call.arguments, "timeout", @default_tool_timeout)
            tool_timeout = min(tool_timeout, max_timeout)

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

            output =
              case Task.yield(task, tool_timeout) || Task.shutdown(task) do
                {:ok, {:error, reason}} ->
                  "Error: #{inspect(reason)}"

                {:ok, result} ->
                  result
                  |> ensure_utf8()
                  |> truncate_large_output(call.name, call.arguments)

                {:exit, reason} ->
                  "Error: Tool execution crashed: #{inspect(reason)}"

                nil ->
                  "Error: Tool execution timed out after #{tool_timeout}ms"
              end

            {index, tool_call_id, call.name, output}
          end)

        results
      end

      defp ensure_utf8(result) when is_binary(result) do
        if String.valid?(result) do
          result
        else
          case :unicode.characters_to_binary(result, :utf8, :utf8) do
            {:error, valid, _} ->
              valid <> "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

            {:incomplete, valid, _} ->
              valid <> "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

            valid when is_binary(valid) ->
              valid
          end
        end
      end

      defp ensure_utf8(result), do: result

      # Truncates large tool outputs to prevent context bloat
      defp truncate_large_output(result, name, args) when is_binary(result) do
        if String.length(result) > @tool_output_max_bytes do
          Logger.warning(
            "Output truncated for tool: #{name}, arguments: #{inspect(args)}, result length: #{String.length(result)}"
          )

          half_size = div(@tool_output_truncate_size, 2)
          first_part = String.slice(result, 0, half_size)
          last_part = String.slice(result, -half_size, half_size)

          """
          [WARNING: Output exceeded #{@tool_output_max_bytes} bytes and was truncated to #{@tool_output_truncate_size} bytes]
          The output from '#{name}' was too large. Consider using more specific arguments
          or alternative tools to retrieve only the relevant portion of data.
          #{first_part}
          ... [#{String.length(result) - @tool_output_truncate_size} bytes omitted] ...
          #{last_part}
          """
          |> String.trim()
        else
          result
        end
      end

      defp truncate_large_output(result, _name, _args), do: result

      defp process_subagent_calls([], _state), do: {[], nil}

      defp process_subagent_calls(indexed_calls, state) do
        subagent_specs = build_subagent_specs(indexed_calls, state)
        results = EvoGit.AgentScheduler.spawn_sub_agents(subagent_specs)

        {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
        parent_commit = agent_state.phylo_node.current_commit

        successful_shas =
          for {:ok, %{commit_sha: sha}} <- results, is_binary(sha), do: sha

        repo_path = Process.get(:repo_path) || raise "Missing repo_path in process dictionary"

        # Skip merge if no subagents returned successful commits
        merge_message =
          if successful_shas == [] do
            nil
          else
            case EvoGit.Adapters.Git.merge_octopus(repo_path, successful_shas) do
              {:ok, output} ->
                # Check if any actual changes were made by comparing commits
                case EvoGit.Adapters.Git.rev_parse(repo_path) do
                  {:ok, ^parent_commit} ->
                    # No changes - all subagents returned the same commit
                    nil

                  {:ok, _new_commit} ->
                    """
                    System Note: Successfully auto-merged changes from subagents.
                    Merge output:
                    #{output}
                    """

                  _error ->
                    """
                    System Note: Successfully auto-merged changes from subagents.
                    Merge output:
                    #{output}
                    """
                end

              {:conflict, output} ->
                {:ok, files} = EvoGit.Adapters.Git.conflict_files(repo_path)

                """
                System Note: Auto-merging subagent changes resulted in conflicts.
                Merge output:
                #{output}

                Conflicting files:
                #{Enum.join(files, "\n")}
                """

              {:error, code, output} ->
                """
                System Note: Failed to auto-merge subagent changes (exit code #{code}).
                Merge output:
                #{output}
                """
            end
          end

        # Remove the tags created by subagents to prevent GC before the merge
        successful_tags =
          Enum.map(results, fn
            {:ok, %{tag: tag}} when is_binary(tag) -> tag
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        Enum.each(successful_tags, fn tag ->
          EvoGit.Adapters.Git.delete_tag(repo_path, tag)
        end)

        # Sync current_commit after subagents complete (parent worktree state may have changed)
        sync_current_commit_after_tools(state)

        indexed_results =
          Enum.zip(indexed_calls, results)
          |> Enum.map(fn {{call, index}, result} ->
            process_subagent_result(call, index, result, state)
          end)

        {indexed_results, merge_message}
      end

      defp build_subagent_specs(indexed_calls, state) do
        Enum.map(indexed_calls, fn {call, _index} ->
          mod = subagent_module_for(call.name)
          path = Map.get(call.arguments, "path")
          objective = Map.get(call.arguments, "objective")
          commit_id = Map.get(call.arguments, "commit_id")

          {:ok, parent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)

          sub_context_node =
            EvoGit.Core.ContextNode.load(path, parent_state.phylo_node.repo)

          # Use specified commit_id, or default to current commit
          base_commit = commit_id || parent_state.phylo_node.current_commit

          sub_phylo_node = %EvoGit.Core.PhyloGraphNode{
            repo: parent_state.phylo_node.repo,
            base_commit: base_commit,
            current_commit: base_commit
          }

          EvoGit.AgentSpec.new(sub_context_node, sub_phylo_node, mod, objective)
        end)
      end

      defp process_subagent_result(call, index, result, state) do
        stream_event(state.agent_id, "TOOL_CALL_END", %{name: call.name})

        output = format_subagent_result(result)

        tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"
        {index, tool_call_id, call.name, output}
      end

      defp format_subagent_result({:error, :path_ignored}) do
        "Error: Cannot spawn subagent in an ignored folder. The current working directory is ignored by git."
      end

      defp format_subagent_result({:error, :path_not_exist}) do
        """
        Error: The assigned node path does not exist in the repository.
        Please verify that the path is correct and is in the repository.
        Note: git does not track empty directories,
        - If the path is a directory, ensure that the path contains at least one tracked file (empty CONTEXT.md or .gitkeep is a common choice), you can use the `make_dir` tool to create a directory and auto create a tracked file within and commit it.
        - If the path is a file, ensure that the file is tracked by git. You can use the `touch` tool to create an empty file and auto commit it.
        """
      end

      defp format_subagent_result({:error, reason}) do
        "Error: Subagent failed: #{inspect(reason)}"
      end

      defp format_subagent_result({:ok, %{result: result, commit_sha: commit_sha, tag: tag}}) do
        """
        # Result
        #{result}

        # Final Commit
        #{commit_sha}
        """
        |> String.trim()
      end

      defp format_subagent_result(text) when is_binary(text), do: text
      defp format_subagent_result(other), do: inspect(other)

      # Formats git status --porcelain output for display
      # Format: "XY filename" where X = staged, Y = unstaged
      # --- Helpers ---

      defp build_dynamic_context(state) do
        case EvoGit.Core.ContextNode.build_context(state.node_path, state.repo_path) do
          {:ok, context} -> context
          {:error, _} -> "Current Path: '#{state.node_path}'."
        end
      end

      defp sync_context_to_ets(agent_id, context) do
        EvoGit.AgentScheduler.update_agent_context(agent_id, context)
      end

      defp stream_event(agent_id, type, data) do
        case EvoGit.AgentScheduler.get_event_sink(agent_id) do
          pid when is_pid(pid) ->
            send(pid, {:agent_event, %{agent_id: agent_id, type: type, data: data}})

          _ ->
            :ok
        end
      end

      defp try_compress_chat(state) do
        threshold = Application.get_env(:evo_git, :compression_threshold_tokens, 100_000)

        if state.total_tokens > threshold do
          Logger.info(
            "Agent #{state.agent_id}: Context length (#{state.total_tokens} tokens) exceeded compression threshold (#{threshold} tokens). Attempting compression..."
          )

          messages = ReqLLM.Context.to_list(state.context)

          case messages do
            [system_msg, initial_user_msg | rest_context] ->
              interaction_history = format_messages_for_compression(rest_context)

              prompt = """
              Compress the following interaction context into a dense, structured summary to be passed to the next agent iteration.

              Your goal is to preserve architectural context and progress while stripping out conversational filler, raw tool syntax, and large code blocks.

              Output your summary strictly using the following format:

              1. Current Progress:
              [1-5 sentences defining the overarching goal currently being worked on and the current state of progress.]

              2. Key Findings & Decisions:
              [Crucial context discovered, architectural decisions made, or constraints identified during the interaction.]

              3. SubAgent Ledger:
              [List previously spawned subagents and a short summary of their objectives and results, if applicable. This helps maintain a memory of delegated work.]

              4. Pending / Next Steps:
              [What specifically needs to be executed next to advance the Current Objective.]

              ---

              [INTERACTION HISTORY BEGIN]

              #{interaction_history}
              """

              compression_context = ReqLLM.Context.new([user(prompt)])

              with {:ok, stream_response} <- ReqLLM.stream_text(current_model(), compression_context),
                   {:ok, response} <- ReqLLM.StreamResponse.process_stream(stream_response),
                   text <- ReqLLM.Response.text(response),
                   summary_msg <- user("Summary of previous events:\n" <> text),
                   new_context <- ReqLLM.Context.new([system_msg, initial_user_msg, summary_msg]) do
                %{state | context: new_context}
              else
                _error -> state
              end

            _ ->
              state
          end
        else
          state
        end
      end

      # Formats a list of messages into a readable string for compression
      defp format_messages_for_compression(messages) do
        messages
        |> Enum.map(&format_single_message/1)
        |> Enum.join("\n\n")
      end

      # Formats a single message into a readable string
      defp format_single_message(%{role: :tool, name: tool_name} = msg) when is_binary(tool_name) do
        header = "[TOOL: #{tool_name}]"
        content = extract_message_content(msg)

        if String.trim(content) == "" do
          "#{header} <empty>"
        else
          "#{header}\n#{content}"
        end
      end

      defp format_single_message(%{role: role} = msg) do
        header = "[#{role |> to_string() |> String.upcase()}]"
        content = extract_message_content(msg)

        if String.trim(content) == "" do
          "#{header} <empty>"
        else
          "#{header}\n#{content}"
        end
      end

      # Extracts text content from a message's content parts
      defp extract_message_content(msg) do
        msg.content
        |> Enum.map(fn
          %{type: :text, text: text} when is_binary(text) -> text
          %{type: :thinking, text: text} when is_binary(text) -> "[THINKING]\n#{text}"
          %{type: :image_url} -> "[IMAGE]"
          %{type: :video_url} -> "[VIDEO]"
          %{type: :image} -> "[IMAGE]"
          %{type: :file, filename: filename} -> "[FILE: #{filename}]"
          _ -> ""
        end)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.join("\n")
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
            [EvoGit.Agent.CodebaseInvestigator]
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
                    "The relative path from the repository root where the subagent should operate."
                },
                "objective" => %{
                  "type" => "string",
                  "description" =>
                    "A clear, self-contained objective for the subagent. " <>
                      "Include any relevant context since it starts with a fresh context."
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
        if at_max_depth?(state) do
          excluded = MapSet.new(subagent_tools())

          available_tools()
          |> Enum.reject(fn tool ->
            name = EvoGit.Agent.tool_name(tool)
            name && MapSet.member?(excluded, name)
          end)
        else
          available_tools()
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
