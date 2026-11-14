defmodule EvoGit.Agent.Resume do
  @moduledoc """
  Crash-resume repair: make a restored transcript provider-valid and tell the
  agent what happened.

  `apply/1` runs ONCE at the very top of `EvoGit.Agent.Exchange.run/2`, before
  the loop, and ONLY for a genuine CRASH RETRY — `state.resume_info` says the
  dispatch ctx carried `restore_agent_state: true` (see
  `EvoGit.Agent.Session.Setup.build_initial_state/3`) and durable state is
  enabled. Every other run (a fresh agent, a resume/merge follow-up, an
  interactive session) passes through untouched.

  ## Two steps, both driven by transcript SHAPE

  The in-flight marker (`state.pending_tool_batch`) supplies PROVENANCE (which
  turn, which calls, which classes); the transcript supplies the TRUTH (is a
  tool call actually unanswered):

  1. **Repair** — when the LAST message is an assistant message carrying
     `tool_calls` and no `:tool` answers followed it, append ONE synthetic
     `:tool` message per unanswered call, in the assistant's call order, built
     with the same `EvoGit.Agent.ToolDispatch.assemble_tool_result/3` and
     turn-tagged exactly like a real result. The content is class-specific and
     honest (`EvoGit.Agent.Resume.ToolBatch`); without it the next provider call
     rejects the unpaired `tool_call_id` (HTTP 400 → `EvoGit.Agent.LlmError`
     fail-fast → a `:failed` task).
  2. **Notice** — append ONE `[RESUME]`-framed, NON-user-authored `:user`
     message (`EvoGit.Agent.Resume.Notice`) stating the interruption, the
     interrupted calls and their classes, the worktree situation and how to
     proceed.

  ## Hard invariants

    * NEVER touches the system message or the first user message — the prompt
      cache prefix must stay byte-identical across a resume.
    * TOTAL: no raises, no LLM call, no I/O, no scheduler interaction.
    * At most ONE notice per resumed run: the notice carries
      `metadata[:resume_notice]` and an existing one short-circuits the append
      (a transcript restored from a previous resume already contains it).
    * `persistent_state: false` is FULLY inert — no repair, no notice, no
      marker write.
    * The marker is always CLEARED by the time this returns: repair exists to
      close it.
  """

  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.Resume.Notice
  alias EvoGit.Agent.Resume.ToolBatch, as: Impact
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.ToolDispatch

  @notice_key :resume_notice

  @doc """
  Repairs and annotates a crash-resumed state; a no-op for every other state.

  Total: a malformed state/context returns the state unchanged.
  """
  @spec apply(State.t()) :: State.t()
  def apply(%State{} = state) do
    if crash_retry?(state) do
      batch = ToolBatch.normalize(state.pending_tool_batch)
      state = %{state | pending_tool_batch: batch}
      state |> repair(batch) |> annotate(batch) |> clear_marker()
    else
      state
    end
  end

  def apply(state), do: state

  @doc """
  True when this state is a CRASH RETRY: the durable restore was requested by the
  dispatch ctx AND persistent state is enabled for the task.

  A `resume_info` map that is absent/malformed, a `restore_agent_state` that is
  not `true`, or `persistent_state: false` all answer `false`.
  """
  @spec crash_retry?(State.t()) :: boolean()
  def crash_retry?(%State{persistent_state: true, resume_info: %{} = info}),
    do: Map.get(info, :restore_agent_state) == true

  def crash_retry?(_state), do: false

  @doc """
  Clears the in-flight marker. `nil` is already clear, so this is a plain (and
  total) field write used by every path that stops executing a batch.
  """
  @spec clear_marker(State.t()) :: State.t()
  def clear_marker(%State{pending_tool_batch: nil} = state), do: state
  def clear_marker(%State{} = state), do: %{state | pending_tool_batch: nil}
  def clear_marker(state), do: state

  @doc """
  The unanswered tool calls of the FINAL assistant message, or `:none`.

  Returns `{:ok, turn, calls}` where `calls` are the `%ReqLLM.ToolCall{}`
  structs with no following `:tool` message, in the assistant's call order, and
  `turn` is the turn to tag the synthetic results with (the assistant message's
  own `metadata[:turn]` when present, else `state.turn`). Only a DANGLING TAIL is
  repairable: if anything follows the assistant message (or the last message is
  not an assistant with tool calls), there is nothing to answer in place.

  Total — a malformed context answers `:none`.
  """
  @spec dangling(State.t()) :: {:ok, integer() | nil, [term()]} | :none
  def dangling(%State{context: %ReqLLM.Context{messages: messages}} = state)
      when is_list(messages) and messages != [] do
    case List.last(messages) do
      %ReqLLM.Message{role: :assistant, tool_calls: calls} = message
      when is_list(calls) and calls != [] ->
        {:ok, message_turn(message, state), calls}

      _other ->
        :none
    end
  end

  def dangling(_state), do: :none

  @doc """
  True when the transcript already carries a `[RESUME]` notice (the
  exactly-once guard). Total.
  """
  @spec notice_present?(term()) :: boolean()
  def notice_present?(%ReqLLM.Context{messages: messages}) when is_list(messages) do
    Enum.any?(messages, &notice_marked?/1)
  end

  def notice_present?(_context), do: false

  ## Repair

  defp repair(%State{} = state, batch) do
    case dangling(state) do
      {:ok, turn, calls} ->
        results =
          calls
          |> Enum.map(&synthetic_result(&1, batch, state))
          |> Enum.map(&ContextBuilder.tag_message_turn(&1, turn))

        %{state | context: ReqLLM.Context.append(state.context, results)}

      :none ->
        state
    end
  end

  defp synthetic_result(call, batch, state) do
    class = class_for(call, batch, state)
    text = Impact.impact(class, call, [])
    ToolDispatch.assemble_tool_result(call_id(call), call_name(call), text)
  end

  # Provenance: prefer the marker entry for the SAME provider id, then the entry
  # at the SAME index; when the marker is absent (a crash outside a batch) the
  # class is re-derived from the call name.
  defp class_for(call, batch, state) do
    case marker_class(call, batch) do
      nil -> ToolBatch.class(call_name(call), agent_subagent_modules(state))
      class -> class
    end
  end

  defp marker_class(call, batch) do
    entries = ToolBatch.calls(batch)
    id = call_id(call)

    by_id =
      if is_binary(id) do
        Enum.find(entries, fn entry -> entry.id == id end)
      end

    case by_id || by_index(call, entries) do
      %{class: class} -> class
      nil -> nil
    end
  end

  defp by_index(call, entries) do
    case call_index(call) do
      nil -> nil
      index -> Enum.find(entries, fn entry -> entry.index == index end)
    end
  end

  defp call_index(%ReqLLM.ToolCall{}), do: nil
  defp call_index(call) when is_map(call), do: Map.get(call, :index)
  defp call_index(_call), do: nil

  defp agent_subagent_modules(%State{agent_module: module}) when is_atom(module) do
    if function_exported?(module, :subagent_modules, 0) do
      module.subagent_modules()
    else
      []
    end
  end

  defp agent_subagent_modules(_state), do: []

  ## Notice

  defp annotate(%State{} = state, batch) do
    if notice_present?(state.context) or not repair_target?(state) do
      state
    else
      message =
        state
        |> Notice.text(batch)
        |> ContextBuilder.build_injected_message(state.turn)
        |> mark_notice()

      %{state | context: ReqLLM.Context.append(state.context, message)}
    end
  end

  # The notice is part of the crash-resume contract, so it is appended whenever
  # the state is a crash retry with a usable context.
  defp repair_target?(%State{context: %ReqLLM.Context{}}), do: true
  defp repair_target?(_state), do: false

  defp mark_notice(%ReqLLM.Message{} = message) do
    %{message | metadata: Map.put(message.metadata || %{}, @notice_key, true)}
  end

  defp notice_marked?(%ReqLLM.Message{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, @notice_key) == true

  defp notice_marked?(_message), do: false

  ## Call accessors (total: a restored transcript may carry plain maps)

  defp call_id(%ReqLLM.ToolCall{id: id}), do: id
  defp call_id(call) when is_map(call), do: Map.get(call, :id) || Map.get(call, "id")
  defp call_id(_call), do: nil

  defp call_name(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.name(call)
  defp call_name(call) when is_map(call), do: Map.get(call, :name) || Map.get(call, "name")
  defp call_name(_call), do: nil

  defp message_turn(%ReqLLM.Message{metadata: metadata}, %State{turn: state_turn}) do
    case is_map(metadata) && Map.get(metadata, :turn) do
      turn when is_integer(turn) -> turn
      _none -> state_turn
    end
  end
end
