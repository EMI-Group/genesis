defmodule EvoGit.Agent do
  @moduledoc """
  A stateful pure-function loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.

  Agent state follows the design spec:
  - `context_node` (spatial): the node in the Context Tree
  - `phylo_node` (temporal): git commit state with `base_commit` and `current_commit`
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
      """
      def run(query, caller_pid, system_prompt \\ nil) do
        actual_system_prompt = system_prompt || system_prompt()

        state = %{
          caller_pid: caller_pid,
          agent_id: EvoGit.AgentScheduler.current_agent_id(),
          depth: EvoGit.AgentScheduler.current_depth(),
          turn: 0,
          history: [ReqLLM.Context.user(query)],
          system_prompt: actual_system_prompt,
          in_grace_period: false,
          deadline: System.monotonic_time(:millisecond) + @timeout_ms
        }

        loop(state)
      end

      # --- Internal Execution Logic ---

      defp loop(state) do
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
        EvoGit.Agent.Tools.schemas() ++ [completion_schema()]
      end

      @doc """
      Returns a list of tool name strings that represent sub-agent invocations.
      These tools are automatically filtered out when the agent is at maximum
      recursion depth, preventing the LLM from seeing or calling them.

      Override this in your agent module to declare sub-agent tools.
      """
      def subagent_tools, do: []

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

      def execute_tool(call, _state) do
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
      defoverridable available_tools: 0, execute_tool: 2, system_prompt: 0, subagent_tools: 0
    end
  end
end
