defmodule EvoDashWeb.AgentsLive.RuntimeStream do
  @moduledoc """
  Pure, bounded inspector projection of the core's replaceable live activity.

  Snapshots and `{:activity, %{phase: phase, current_call: call}}` events contain
  the whole accumulated current call, including text captured before attachment.
  They REPLACE text/thinking; ordinary chunks append after that replacement.
  Only one current call is retained: a fresh call id replaces the previous
  attempt, and `current_call: nil` retires live excerpts in favour of checkpoint
  history. Neither accounting, yield nor tool announcements resurrect a call.

  `activity` stores only the authoritative phase, avoiding an unbounded second
  copy of the producer's accumulated content. `projections` contains at most one
  bounded call, with the top-level response/thinking/tools mirroring that call.
  A local monotonic message_index supplies stable DOM keys, not checkpoint ids.
  Complete capture follows from explicit binary text AND thinking in the core
  projection; successful generation follows only from :llm_complete or :tools.
  Failure, retry, turn accounting and lifecycle finish do not prove completion.

  Text retains independent UTF-8-safe byte prefixes. Replacement omission counts
  describe the replacement value, not repeated transmissions of the same bytes;
  later omitted chunks add to that count. Raw checkpoint messages are unchanged.
  Scope/snapshot admission belongs to StreamWatch; newer batches alone advance
  the sequence watermark, and terminal state ignores all later events.
  """

  alias EvoGit.Agent.Stream
  alias EvoDashWeb.AgentsLive.StreamLimits

  defdelegate max_projections(), to: StreamLimits
  defdelegate max_text_bytes(), to: StreamLimits
  defdelegate max_tools(), to: StreamLimits
  defdelegate max_tool_name_bytes(), to: StreamLimits

  @phases [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools]

  defstruct agent_id: nil,
            node: nil,
            seq: 0,
            phase: nil,
            activity: nil,
            turn: 0,
            messages: [],
            response: "",
            thinking: "",
            tool_calls: [],
            projections: [],
            omitted_messages: 0,
            message_index: nil,
            finished: false,
            status: nil

  @type t :: %__MODULE__{}

  @doc "Builds an empty projection scoped to one agent and node."
  def new(agent_id, node), do: %__MODULE__{agent_id: agent_id, node: node}

  @doc "Replaces content from an admitted snapshot, preserving agent/node ownership."
  def seed(%__MODULE__{} = state, snapshot, seq) do
    if field(snapshot, :agent_id) in [nil, state.agent_id] do
      phase = atom_or_nil(field(snapshot, :phase))
      finished = phase in [:finished, :completed, :failed, :cancelled]

      seeded = %{
        new(state.agent_id, state.node)
        | message_index: state.message_index,
          projections: state.projections,
          seq: number(seq) || number(field(snapshot, :seq)) || 0,
          phase: phase,
          turn: number(field(snapshot, :turn)) || 0,
          messages: list(field(snapshot, :messages)),
          finished: finished,
          status: atom_or_nil(field(snapshot, :status)) || phase
      }

      seeded = replace_activity(seeded, field(snapshot, :activity))
      if finished, do: complete_current(seeded), else: seeded
    else
      state
    end
  end

  def seed(_state, _snapshot, _seq), do: new(nil, nil)

  @doc "Applies only a newer batch for the owned, nonterminal agent."
  def apply_batch(%__MODULE__{} = state, agent_id, seq, events) do
    if agent_id == state.agent_id and not state.finished and
         not Stream.stale?(seq, state.seq) do
      events
      |> Stream.normalize_batch()
      |> Enum.reduce(state, &apply_event/2)
      |> Map.put(:seq, seq)
    else
      state
    end
  end

  def apply_batch(_state, _agent_id, _seq, _events), do: new(nil, nil)

  @doc """
  Whether an ordered batch crosses a checkpoint/live ownership boundary.

  A current call's retirement or replacement requires an atomic snapshot before
  ANY of this batch is rendered. Inspect every activity event, not just the final
  call id: a batch can retire one call and start another. No text, turn, message
  index, tool result or yield is evidence of checkpoint adoption.
  """
  def checkpoint_transition?(%__MODULE__{} = state, events) when is_list(events) do
    events
    |> Enum.reduce_while(current_call_id(state), fn
      {:activity, %{phase: phase, current_call: call}}, previous when phase in @phases ->
        next = if is_map(call), do: Map.get(call, :id), else: nil

        if is_binary(previous) and next != previous do
          {:halt, :transition}
        else
          {:cont, next}
        end

      _event, previous ->
        {:cont, previous}
    end)
    |> Kernel.==(:transition)
  end

  def checkpoint_transition?(_state, _events), do: false

  @doc "The authoritative live call id, never a checkpoint-message identity."
  def current_call_id(%__MODULE__{projections: [%{identity: %{id: id}}]}), do: id
  def current_call_id(_state), do: nil

  @doc "True only for a nonterminal running/cancelling lifecycle, not an activity guess."
  def active?(%__MODULE__{finished: false, phase: phase}),
    do: phase in [:running, :cancelling]

  def active?(_state), do: false

  # Once a terminal fact appears, later events in the same batch are inert too.
  defp apply_event(_event, %{finished: true} = state), do: state

  defp apply_event({:activity, value}, state), do: replace_activity(state, value)

  defp apply_event({kind, chunk}, state)
       when kind in [:text, :thinking] and is_binary(chunk) and chunk != "" do
    key = if kind == :text, do: :response, else: :thinking

    update_current(state, fn message ->
      {excerpt, omitted} =
        if Map.fetch!(message, omission_key(key)) > 0,
          do: {Map.fetch!(message, key), byte_size(chunk)},
          else: StreamLimits.append(Map.fetch!(message, key), chunk)

      message
      |> Map.put(key, excerpt)
      |> Map.update!(omission_key(key), &(&1 + omitted))
      |> Map.put(:chunks_seen, true)
    end)
  end

  defp apply_event({:tool_call, id, name}, state) when is_binary(name) and name != "" do
    update_current(state, fn message ->
      {tools, omitted} = announce_tool(message.tool_calls, id, name)
      %{message | tool_calls: tools, omitted_tools: message.omitted_tools + omitted}
    end)
  end

  defp apply_event({:tool_result, id, status}, state) when not is_nil(id) do
    update_current(state, fn message ->
      tools =
        Enum.map(message.tool_calls, fn tool ->
          if tool.id == id, do: %{tool | status: status}, else: tool
        end)

      %{message | tool_calls: tools}
    end)
  end

  defp apply_event({:turn, info}, state) when is_map(info),
    do: %{state | turn: number(field(info, :turn)) || state.turn}

  # Yield text is checkpoint output, not another live chunk/replacement.
  defp apply_event({:yield, value}, state) when is_binary(value),
    do: %{complete_current(state) | phase: :awaiting_input, status: :awaiting_input}

  defp apply_event({:finished, status}, state) when is_atom(status) and not is_nil(status),
    do: %{complete_current(state) | finished: true, phase: :finished, status: status}

  defp apply_event(_event, state), do: state

  defp replace_activity(state, value) when is_map(value) do
    phase = field(value, :phase)

    if phase in @phases and has_field?(value, :current_call) do
      state = %{state | activity: phase}

      case field(value, :current_call) do
        nil -> retire(state)
        call when is_map(call) -> replace_call(state, call, phase)
        _ -> retire(state)
      end
    else
      state
    end
  end

  defp replace_activity(state, _value), do: state

  defp replace_call(state, call, phase) do
    case field(call, :id) do
      id when is_binary(id) ->
        previous = List.last(state.projections)
        same? = previous != nil and previous.identity == %{id: id}
        index = if same?, do: previous.message_index, else: (state.message_index || -1) + 1
        response = field(call, :text)
        thinking = field(call, :thinking)
        generation_complete = phase in [:llm_complete, :tools]

        message =
          %{
            identity: %{id: id},
            turn: number(field(call, :turn)),
            attempt: number(field(call, :attempt)),
            message_index: index,
            response: "",
            thinking: "",
            tool_calls: if(same?, do: previous.tool_calls, else: []),
            omitted_tools: if(same?, do: previous.omitted_tools, else: 0),
            complete: generation_complete,
            generation_complete: generation_complete,
            capture_coverage:
              if(is_binary(response) and is_binary(thinking), do: :complete, else: :partial),
            chunks_seen: response not in [nil, ""] or thinking not in [nil, ""],
            omitted_response_bytes: 0,
            omitted_thinking_bytes: 0
          }
          |> replace_text(:response, text(response))
          |> replace_text(:thinking, text(thinking))

        sync(%{state | projections: [message]})

      _ ->
        retire(state)
    end
  end

  defp retire(state), do: sync(%{state | projections: [], omitted_messages: 0})

  defp complete_current(state),
    do: update_current(state, fn message -> %{message | complete: true} end)

  defp update_current(%{projections: []} = state, _fun), do: state

  defp update_current(%{projections: [current]} = state, fun),
    do: sync(%{state | projections: [fun.(current)]})

  defp sync(%{projections: []} = state),
    do: %{state | response: "", thinking: "", tool_calls: []}

  defp sync(%{projections: [current]} = state) do
    %{
      state
      | response: current.response,
        thinking: current.thinking,
        tool_calls: current.tool_calls,
        message_index: current.message_index
    }
  end

  # Anonymous stream announcements are upgraded when dispatch supplies an id.
  # Announcements alone never establish actual tool execution.
  defp announce_tool(tools, id, name) do
    {name, omitted_name_bytes} = StreamLimits.preview(name, max_tool_name_bytes())

    index =
      Enum.find_index(tools, fn tool ->
        (not is_nil(id) and tool.id == id) or
          (is_nil(tool.id) and tool.name == name and tool.omitted_name_bytes == omitted_name_bytes)
      end)

    cond do
      not is_nil(index) ->
        {List.update_at(tools, index, fn tool ->
           %{tool | id: id || tool.id, name: name, omitted_name_bytes: omitted_name_bytes}
         end), 0}

      length(tools) < max_tools() ->
        {tools ++
           [%{id: id, name: name, status: :announced, omitted_name_bytes: omitted_name_bytes}], 0}

      true ->
        {tools, 1}
    end
  end

  defp replace_text(message, key, value) do
    {excerpt, omitted} = StreamLimits.preview(value, max_text_bytes())
    message |> Map.put(key, excerpt) |> Map.put(omission_key(key), omitted)
  end

  defp omission_key(:response), do: :omitted_response_bytes
  defp omission_key(:thinking), do: :omitted_thinking_bytes

  defp has_field?(value, key), do: Map.has_key?(value, key) or Map.has_key?(value, to_string(key))

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, to_string(key)))

  defp field(_value, _key), do: nil
  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(_value), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp atom_or_nil(value) when is_atom(value), do: value
  defp atom_or_nil(_value), do: nil
end
