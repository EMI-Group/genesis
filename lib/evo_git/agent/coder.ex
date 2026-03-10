defmodule EvoGit.Agent.Coder do
  @moduledoc """
  A stateful GenServer that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.
  """
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

  @doc """
  Spawns the agent process and returns its PID.
  `caller_pid` is where we will stream the live UI events.
  """
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
    # 1. Start the strict 10-minute deadline timer
    Process.send_after(self(), :deadline_timeout, @timeout_ms)

    state = %{
      caller_pid: caller_pid,
      turn: 0,
      history: [%{role: "user", content: query}],
      system_prompt: system_prompt,
      in_grace_period: false
    }

    # Kick off the ReAct loop asynchronously so we don't block initialization
    send(self(), :execute_turn)

    {:ok, state}
  end

  @impl true
  def handle_info(:execute_turn, state) do
    # 2. Token Compression: Check if history is too long before sending
    state = try_compress_chat(state)

    # 3. Limit Check: Max turns reached
    if state.turn >= @max_turns and not state.in_grace_period do
      send(self(), {:trigger_recovery, "max turns (#{@max_turns}) exceeded"})
      {:noreply, state}
    else
      # Execute the actual model call and tool execution
      do_turn(state)
    end
  end

  @impl true
  def handle_info(:deadline_timeout, state) do
    # 4. Timeout Handling
    if state.in_grace_period do
      # If we time out *during* the grace period, it's a hard kill.
      stream_event(state.caller_pid, "ERROR", %{error: "Grace period timed out. Agent killed."})
      send(state.caller_pid, {:agent_finished, {:error, :timeout}})
      {:stop, :normal, state}
    else
      # Standard timeout hit. Trigger the grace period.
      send(self(), {:trigger_recovery, "10-minute time limit exceeded"})
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:trigger_recovery, reason}, state) do
    # 5. The Grace Period Recovery Logic
    stream_event(state.caller_pid, "ERROR", %{
      error: "Limit reached: #{reason}. Attempting one final recovery turn."
    })

    warning_msg = """
    You have exceeded the execution limit (#{reason}).
    You MUST call `#{@complete_tool}` immediately with your best answer. Do not call any other tools.
    """

    new_history = state.history ++ [%{role: "user", content: warning_msg}]

    # Start a 1-minute grace period timer
    Process.send_after(self(), :deadline_timeout, @grace_period_ms)

    state = %{state | history: new_history, in_grace_period: true}
    send(self(), :execute_turn)

    {:noreply, state}
  end

  # --- Internal Execution Logic ---

  defp do_turn(state) do
    # Build context from system prompt and history
    context = ReqLLM.Context.new([ReqLLM.Context.system(state.system_prompt) | state.history])

    {:ok, response} =
      ReqLLM.generate_text(
        @model,
        context,
        tools: available_tools()
      )

    tool_calls = ReqLLM.Response.tool_calls(response)

    # 6. Stream Thought Chunk to UI
    if response.text && response.text != "" do
      stream_event(state.caller_pid, "THOUGHT_CHUNK", %{text: response.text})
    end

    state = %{state | history: state.history ++ [response.message], turn: state.turn + 1}

    # Process requested tools
    case process_tool_calls(tool_calls, state) do
      {:complete, final_result} ->
        # The agent successfully finished!
        send(state.caller_pid, {:agent_finished, {:ok, final_result}})
        {:stop, :normal, state}

      {:continue, tool_responses} ->
        # Agent used tools. Append the tool outputs to history and loop again.
        state = %{state | history: state.history ++ tool_responses}
        send(self(), :execute_turn)
        {:noreply, state}

      {:error, :protocol_violation} ->
        # The agent output text but didn't call ANY tools (including complete_task)
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
      stream_event(state.caller_pid, "TOOL_CALL_END", %{name: @complete_tool, status: "success"})

      result =
        Map.get(complete_call.arguments, "result") ||
          Map.get(complete_call.arguments, :result, "Task finished.")

      {:complete, result}
    else
      results =
        Enum.map(tool_calls, fn call ->
          # 7. Stream Tool Start
          stream_event(state.caller_pid, "TOOL_CALL_START", %{
            name: call.name,
            args: call.arguments
          })

          output = EvoGit.Agent.Tools.execute(call.name, call.arguments)

          # 8. Stream Tool End
          stream_event(state.caller_pid, "TOOL_CALL_END", %{name: call.name})
          tool_call_id = Map.get(call, :id, call.name)
          ReqLLM.Context.tool_result(tool_call_id, call.name, output)
        end)

      {:continue, results}
    end
  end

  # --- Helpers ---

  defp stream_event(caller_pid, type, data) do
    # This replaces local-invocation.ts. It pushes updates directly to the parent process/UI.
    send(caller_pid, {:subagent_activity, %{type: type, data: data}})
  end

  defp try_compress_chat(state) do
    # If the history gets too large (e.g., after `cat`ing a huge file),
    # summarize the older messages to save tokens.
    if length(state.history) > 15 do
      summarized_history = MockCompressionService.compress(state.history)
      %{state | history: summarized_history}
    else
      state
    end
  end

  defp available_tools, do: EvoGit.Agent.Tools.schemas() ++ [completion_schema()]

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
end
