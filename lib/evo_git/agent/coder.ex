defmodule EvoGit.Agent.Coder do
  @moduledoc """
  A stateful GenServer template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      require Logger

      @max_turns 20
      # 10 minutes
      @timeout_ms 10 * 60 * 1000
      # 1 minute
      @grace_period_ms 60 * 1000
      @complete_tool "complete_task"
      @model Application.compile_env(:evo_git, :llm_model, "google:gemini-3.1-flash-lite-preview")

      # --- Public API ---

      def start_link(query, caller_pid, system_prompt \\ "") do
        GenServer.start_link(__MODULE__, %{
          query: query,
          caller_pid: caller_pid,
          system_prompt: system_prompt
        })
      end

      # --- GenServer Callbacks ---

      @impl true
      def init(%{query: query, caller_pid: caller_pid, system_prompt: system_prompt}) do
        Process.send_after(self(), :deadline_timeout, @timeout_ms)

        state = %{
          caller_pid: caller_pid,
          turn: 0,
          history: [%{role: "user", content: query}],
          system_prompt: system_prompt,
          in_grace_period: false
        }

        send(self(), :execute_turn)

        {:ok, state}
      end

      @impl true
      def handle_info(:execute_turn, state) do
        state = try_compress_chat(state)

        if state.turn >= @max_turns and not state.in_grace_period do
          send(self(), {:trigger_recovery, "max turns (\#{@max_turns}) exceeded"})
          {:noreply, state}
        else
          do_turn(state)
        end
      end

      @impl true
      def handle_info(:deadline_timeout, state) do
        if state.in_grace_period do
          stream_event(state.caller_pid, "ERROR", %{
            error: "Grace period timed out. Agent killed."
          })

          send(state.caller_pid, {:agent_finished, {:error, :timeout}})
          {:stop, :normal, state}
        else
          send(self(), {:trigger_recovery, "10-minute time limit exceeded"})
          {:noreply, state}
        end
      end

      @impl true
      def handle_info({:trigger_recovery, reason}, state) do
        stream_event(state.caller_pid, "ERROR", %{
          error: "Limit reached: \#{reason}. Attempting one final recovery turn."
        })

        warning_msg = """
        You have exceeded the execution limit (\#{reason}).
        You MUST call `\#{@complete_tool}` immediately with your best answer. Do not call any other tools.
        """

        new_history = state.history ++ [%{role: "user", content: warning_msg}]
        Process.send_after(self(), :deadline_timeout, @grace_period_ms)

        state = %{state | history: new_history, in_grace_period: true}
        send(self(), :execute_turn)

        {:noreply, state}
      end

      # Handle delegated subagent events generically (for Generalist or other agents with subagents)
      @impl true
      def handle_info({:subagent_activity, activity}, state) do
        # Forward subagent events up to the actual UI/caller
        send(state.caller_pid, {:subagent_activity, activity})
        {:noreply, state}
      end

      # --- Internal Execution Logic ---

      defp do_turn(state) do
        context = ReqLLM.Context.new([ReqLLM.Context.system(state.system_prompt) | state.history])

        {:ok, response} =
          ReqLLM.generate_text(
            @model,
            context,
            tools: available_tools()
          )

        tool_calls = ReqLLM.Response.tool_calls(response)

        if response.text && response.text != "" do
          stream_event(state.caller_pid, "THOUGHT_CHUNK", %{text: response.text})
        end

        state = %{state | history: state.history ++ [response.message], turn: state.turn + 1}

        case process_tool_calls(tool_calls, state) do
          {:complete, final_result} ->
            send(state.caller_pid, {:agent_finished, {:ok, final_result}})
            {:stop, :normal, state}

          {:continue, tool_responses} ->
            state = %{state | history: state.history ++ tool_responses}
            send(self(), :execute_turn)
            {:noreply, state}

          {:error, :protocol_violation} ->
            if state.in_grace_period do
              send(state.caller_pid, {:agent_finished, {:error, :recovery_failed}})
              {:stop, :normal, state}
            else
              send(self(), {:trigger_recovery, "agent stopped calling tools"})
              {:noreply, state}
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

      defp stream_event(caller_pid, type, data) do
        send(caller_pid, {:subagent_activity, %{type: type, data: data}})
      end

      defp try_compress_chat(state) do
        if length(state.history) > 15 do
          [first_message | rest_history] = state.history
          {older_messages, recent_messages} = Enum.split(rest_history, -5)

          prompt = """
          Please provide a concise summary of the important information discoveries, and context from the following interaction history that are related to the current task.

          \#{inspect(older_messages, limit: :infinity, printable_limit: :infinity)}
          """

          context = ReqLLM.Context.new([%{role: "user", content: prompt}])

          case ReqLLM.generate_text(@model, context) do
            {:ok, response} ->
              summary_msg = %{
                role: "user",
                content: "Summary of previous events:\n" <> (response.text || "")
              }

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
        EvoGit.Agent.Tools.execute(call.name, call.arguments)
      end

      # Give adopting modules default implementations they can override
      defoverridable available_tools: 0, execute_tool: 2
    end
  end
end
