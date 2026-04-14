defmodule EvoGit.Agent do
  @moduledoc """
  A stateful pure-function loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.

  Agent state follows the design spec:
  - `context_node` (spatial): the node in the Context Tree
  - `phylo_node` (temporal): git commit state with `base_commit` and `current_commit`

  The agent reads its core spatial/temporal state from the ETS table managed
  by `EvoGit.AgentScheduler`. Crucially, `node_path` and `repo_path` (worktree)
  are re-read from ETS at the start of **every turn**, not cached at init time.
  This ensures correctness when an agent is rescheduled to a different worktree
  after yielding (e.g., during sub-agent delegation).
  """

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @type state :: %{context_node: ContextNode.t(), phylo_node: PhyloGraphNode.t()}

  @doc """
  Extracts the tool name from a tool schema struct.
  """
  def tool_name(%{name: name}), do: name
  def tool_name(_), do: nil

  defmacro __using__(_opts) do
    quote do
      require Logger

      @max_turns 20
      # 10 minutes
      @timeout_ms 10 * 60 * 1000
      # 1 minute
      @grace_period_ms 60 * 1000
      @complete_tool "complete_task"

      defp current_model do
        Application.get_env(:evo_git, :llm_model, "google:gemini-3.1-flash-lite-preview")
      end

      # --- Public API ---

      @doc """
      Runs the agent asynchronously in a Task, returning the Task struct.
      """
      def run_task(query, caller_pid, system_prompt \\ nil) do
        Task.async(fn ->
          run(query, caller_pid, system_prompt)
        end)
      end

      @doc """
      Runs the agent synchronously, blocking until it completes.

      The agent reads its spatial/temporal state from ETS every turn via
      `load_ets_state/1`, ensuring it always has the correct worktree path.
      """
      def run(query, caller_pid, system_prompt \\ nil) do
        actual_system_prompt = system_prompt || system_prompt()
        agent_id = EvoGit.AgentScheduler.current_agent_id()

        state = %{
          caller_pid: caller_pid,
          agent_id: agent_id,
          depth: EvoGit.AgentScheduler.current_depth(),
          # Loaded from ETS each turn — see load_ets_state/1
          node_path: nil,
          repo_path: nil,
          turn: 0,
          history: [ReqLLM.Context.user(query)],
          system_prompt: actual_system_prompt,
          in_grace_period: false,
          deadline: System.monotonic_time(:millisecond) + @timeout_ms
        }

        loop(state)
      end

      # --- Internal Execution Logic ---

      defp load_ets_state(state) do
        case EvoGit.AgentScheduler.get_agent(state.agent_id) do
          {:ok, %{context_node: ctx, worktree: wt}} when not is_nil(wt) ->
            # Update process dict so tools use the correct worktree
            Process.put(:repo_path, wt)
            %{state | node_path: ctx.path, repo_path: wt}

          {:ok, %{context_node: ctx, phylo_node: phylo}} when not is_nil(phylo) ->
            Process.put(:repo_path, phylo.repo)
            %{state | node_path: ctx.path, repo_path: phylo.repo}

          _ ->
            Logger.warning("Agent #{inspect(state.agent_id)}: No ETS state found, using defaults")
            fallback = Process.get(:repo_path, File.cwd!())
            %{state | node_path: state.node_path || ".", repo_path: state.repo_path || fallback}
        end
      end

      defp loop(state) do
        # Re-read worktree/node from ETS every turn
        state = load_ets_state(state)
        state = try_compress_chat(state)

        now = System.monotonic_time(:millisecond)
        time_left = state.deadline - now

        cond do
          time_left <= 0 and not state.in_grace_period ->
            trigger_recovery(state, "10-minute time limit exceeded")

          time_left <= 0 and state.in_grace_period ->
            stream_event(state.caller_pid, "ERROR", %{
              error: "Grace period timed out. Agent killed."
            })

            send(state.caller_pid, {:agent_finished, {:error, :timeout}})
            {:error, :timeout}

          state.turn >= @max_turns and not state.in_grace_period ->
            trigger_recovery(state, "max turns (#{@max_turns}) exceeded")

          true ->
            do_turn(state)
        end
      end

      defp trigger_recovery(state, reason) do
        stream_event(state.caller_pid, "ERROR", %{
          error: "Limit reached: #{reason}. Attempting one final recovery turn."
        })

        warning_msg = """
        You have exceeded the execution limit (#{reason}).
        You MUST call `#{@complete_tool}` immediately with your best answer. Do not call any other tools.
        """

        new_history = state.history ++ [ReqLLM.Context.user(warning_msg)]
        new_deadline = System.monotonic_time(:millisecond) + @grace_period_ms

        state = %{state | history: new_history, in_grace_period: true, deadline: new_deadline}
        loop(state)
      end

      defp do_turn(state) do
        dynamic_context = build_dynamic_context(state)
        full_system_prompt = state.system_prompt <> dynamic_context

        context = ReqLLM.Context.new([ReqLLM.Context.system(full_system_prompt) | state.history])

        tools = effective_tools(state)

        {:ok, response} =
          ReqLLM.generate_text(
            current_model(),
            context,
            tools: tools
          )

        tool_calls =
          ReqLLM.Response.tool_calls(response)
          |> Enum.map(&ReqLLM.ToolCall.from_map/1)

        text = ReqLLM.Response.text(response)

        if text && text != "" do
          stream_event(state.caller_pid, "THOUGHT_CHUNK", %{text: text})
        end

        state = %{state | history: state.history ++ [response.message], turn: state.turn + 1}

        case process_tool_calls(tool_calls, state) do
          {:complete, final_result} ->
            send(state.caller_pid, {:agent_finished, {:ok, final_result}})
            {:ok, final_result}

          {:continue, tool_responses} ->
            state = %{state | history: state.history ++ tool_responses}
            loop(state)

          {:error, :protocol_violation} ->
            if state.in_grace_period do
              send(state.caller_pid, {:agent_finished, {:error, :recovery_failed}})
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
          stream_event(state.caller_pid, "TOOL_CALL_END", %{
            name: @complete_tool,
            status: "success"
          })

          result =
            Map.get(complete_call.arguments, "result") ||
              Map.get(complete_call.arguments, :result, "Task finished.")

          {:complete, result}
        else
          results =
            Enum.map(tool_calls, fn call ->
              stream_event(state.caller_pid, "TOOL_CALL_START", %{
                name: call.name,
                args: call.arguments
              })

              output = execute_tool(call, state)

              stream_event(state.caller_pid, "TOOL_CALL_END", %{name: call.name})
              tool_call_id = Map.get(call, :id, call.name)
              ReqLLM.Context.tool_result(tool_call_id, call.name, output)
            end)

          {:continue, results}
        end
      end

      # --- Helpers ---

      defp build_dynamic_context(state) do
        case EvoGit.Core.ContextNode.build_context(state.node_path, state.repo_path) do
          {:ok, context} -> context
          {:error, _} -> "Current Target Node: '#{state.node_path}'."
        end
      end

      defp stream_event(caller_pid, type, data) do
        send(caller_pid, {:subagent_activity, %{type: type, data: data}})
      end

      defp try_compress_chat(state) do
        if length(state.history) > 15 do
          [first_message | rest_history] = state.history
          {older_messages, recent_messages} = Enum.split(rest_history, -5)

          prompt = """
          Please provide a concise summary of the important information discoveries, and context from the following interaction history that are related to the current task.

          #{inspect(older_messages, limit: :infinity, printable_limit: :infinity)}
          """

          context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

          case ReqLLM.generate_text(current_model(), context) do
            {:ok, response} ->
              text = ReqLLM.Response.text(response)
              summary_msg = ReqLLM.Context.user("Summary of previous events:\n" <> (text || ""))

              %{state | history: [first_message, summary_msg | recent_messages]}

            _error ->
              state
          end
        else
          state
        end
      end

      defp completion_schema do
        ReqLLM.tool(
          name: @complete_tool,
          description:
            "Call this tool to submit your final findings. This is the ONLY way to finish.",
          parameter_schema: %{
            "type" => "object",
            "properties" => %{
              "result" => %{
                "type" => "string",
                "description" => "The final result or findings"
              }
            },
            "required" => ["result"]
          },
          callback: fn _args -> {:ok, "Task finished"} end
        )
      end

      def available_tools do
        EvoGit.Agent.Tools.schemas() ++ subagent_schemas() ++ [completion_schema()]
      end

      @doc """
      Returns the tool name used when this agent is spawned as a sub-agent.
      Override this in your agent module.
      """
      def subagent_tool_name, do: nil

      @doc """
      Returns the tool description used when this agent is spawned as a sub-agent.
      Override this in your agent module.
      """
      def subagent_tool_description, do: ""

      @doc """
      Returns a list of agent modules that can be spawned as sub-agents.
      The framework automatically generates tool schemas and execution logic
      from each module's `subagent_tool_name/0` and `subagent_tool_description/0`.

      Override this in your agent module to declare sub-agents.

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
                "objective" => %{
                  "type" => "string",
                  "description" =>
                    "A clear, self-contained objective for the sub-agent. " <>
                      "Include any relevant paths or context since it starts with a fresh context."
                }
              },
              "required" => ["objective"]
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
        state.depth >= EvoGit.AgentScheduler.max_depth()
      end

      def execute_tool(call, state) do
        case subagent_module_for(call.name) do
          nil -> execute_standard_tool(call)
          mod -> execute_subagent(mod, call, state)
        end
      end

      defp execute_subagent(mod, call, state) do
        objective = Map.get(call.arguments, "objective")

        # Read the parent's current state from ETS to pass to the sub-agent
        {:ok, parent_ets} = EvoGit.AgentScheduler.get_agent(state.agent_id)

        sub_spec = %{
          context_node: parent_ets.context_node,
          phylo_node: parent_ets.phylo_node,
          agent_module: mod,
          objective: objective,
          opts: [caller_pid: state.caller_pid]
        }

        [result] = EvoGit.AgentScheduler.spawn_sub_agents([sub_spec])

        case result do
          {:ok, text} -> text
          {:error, reason} -> "Error: Sub-agent failed: #{inspect(reason)}"
          text when is_binary(text) -> text
          other -> inspect(other)
        end
      end

      defp execute_standard_tool(call) do
        result = EvoGit.Agent.Tools.execute(call.name, call.arguments)

        if is_binary(result) and String.length(result) > 20000 do
          Logger.warning(
            "Output truncated for tool: #{call.name}, arguments: #{inspect(call.arguments)}, result length: #{String.length(result)}"
          )

          truncate_size = 3000
          half_size = div(truncate_size, 2)
          first_part = String.slice(result, 0, half_size)
          last_part = String.slice(result, -half_size, half_size)
          first_part <> "\n... [Output Truncated, Only 3000 bytes Shown] ...\n" <> last_part
        else
          result
        end
      end

      def system_prompt, do: ""

      # Give adopting modules default implementations they can override
      defoverridable available_tools: 0,
                     execute_tool: 2,
                     system_prompt: 0,
                     subagent_tool_name: 0,
                     subagent_tool_description: 0,
                     subagent_modules: 0
    end
  end
end
