defmodule EvoGit.Agent.Coder do
  @moduledoc """
  A stateful pure-function loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.
  """

  defmacro __using__(_opts) do
    quote do
      require Logger

      @max_turns 20
      # 10 minutes
      @timeout_ms 10 * 60 * 1000
      # 1 minute
      @grace_period_ms 60 * 1000
      @complete_tool "complete_task"
      @model Application.compile_env(:evo_git, :llm_model, "google:gemini-3.1-flash-lite-preview")

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
        dynamic_context = build_dynamic_context()
        full_system_prompt = state.system_prompt <> dynamic_context

        context = ReqLLM.Context.new([ReqLLM.Context.system(full_system_prompt) | state.history])

        {:ok, response} =
          ReqLLM.generate_text(
            @model,
            context,
            tools: available_tools()
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

      defp build_dynamic_context do
        repo_path = Process.get(:repo_path)
        node_path = Process.get(:node_path)

        try do
          context_nodes = EvoGit.Core.ContextNode.hier_context(node_path, repo_path)

          context_files =
            Enum.map(context_nodes, fn node ->
              if node.type == :directory do
                Path.join(node.path, "CONTEXT.md")
              else
                node.path
              end
            end)
            |> Enum.filter(&File.exists?/1)

          context_contents =
            Enum.map_join(context_files, "\n\n", fn file ->
              case File.read(file) do
                {:ok, content} ->
                  truncated_content =
                    if String.length(content) > 10000 do
                      String.slice(content, 0, 10000) <> "\n... [Content Truncated] ..."
                    else
                      content
                    end

                  "File: #{Path.relative_to(file, repo_path)}\n```\n#{truncated_content}\n```"

                _ ->
                  "File: #{Path.relative_to(file, repo_path)} (not found or error reading)"
              end
            end)

          if context_contents == "" do
            ""
          else
            "\n\n# Context Tree\n" <> context_contents
          end
        rescue
          _e -> ""
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

          case ReqLLM.generate_text(@model, context) do
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
          parameters: [
            result: [type: :string, required: true, doc: "The final result or findings"]
          ],
          callback: fn _args -> {:ok, "Task finished"} end
        )
      end

      def available_tools do
        EvoGit.Agent.Tools.schemas() ++ [completion_schema()]
      end

      def execute_tool(call, _state) do
        result = EvoGit.Agent.Tools.execute(call.name, call.arguments)

        if is_binary(result) and String.length(result) > 20000 do
          String.slice(result, 0, 20000) <> "\n... [Output Truncated] ..."
        else
          result
        end
      end

      def system_prompt, do: ""

      # Give adopting modules default implementations they can override
      defoverridable available_tools: 0, execute_tool: 2, system_prompt: 0
    end
  end
end
