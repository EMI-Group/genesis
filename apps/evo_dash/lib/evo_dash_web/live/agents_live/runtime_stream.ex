defmodule EvoDashWeb.AgentsLive.RuntimeStream do
  @moduledoc """
  Pure inspector projection of `EvoGit.Agent.Stream`, not an Assistant transcript.

  `messages` remains the raw checkpoint history; `projections` contains only live
  assistant-message projections, in arrival order, including the current one.
  The top-level `response`, `thinking` and `tool_calls` mirror the current
  projection. Nothing rewrites or extracts text from checkpoint messages.

  An explicit `:message_start` identity (a map with `:turn`, `:message_index`
  and/or `:id`, a non-negative integer interpreted as `:message_index`, or a
  nonempty binary interpreted as `:id`) starts a message. Repeating the current
  message's identity is idempotent. An authoritative
  `{:activity, %{phase: :llm, ...identity...}}` selects a message only when it
  includes identity fields. Identity-free activity never clears content.

  For today's identity-free stream, `:turn` completes the current projection
  WITHOUT clearing it. The next text/thinking chunk starts a new projection;
  intervening tool announcements/results still belong to the completed one.
  This reflects accounting after an LLM response, not completion of its tools.
  `generation_complete` is set by `:turn` or `:yield`, never merely by a failed
  lifecycle finish. It does not assert complete thinking capture: a consumer
  attaching mid-generation may have missed chunks even after generation ends.
  `:yield` completes a message and parks the lifecycle; `:finished` terminates
  it. Neither erases the message's reasoning. A nonempty yield text replaces
  the current response (it is a complete response, not another chunk).

  Activity is optional, authoritative data, never inferred from thinking text
  or tool announcements. Missing activity is `nil`, not an idle assertion.
  Snapshot `:in_flight` accepts `:response` (or `:text`), `:thinking`, `:turn`,
  `:message_index`, `:id` and optional `:generation_complete`. Its explicit
  `capture_coverage: :complete` assertion proves full capture only when both
  response and thinking are binaries (empty thinking must be explicit).
  Observing `:message_start` before this message's first chunk also proves
  complete capture; activity alone never does, and a late repeated start never
  upgrades partial capture. `message_identity/1` is the shared identity reader.
  Seed replaces all previous live projections so a resync cannot concatenate
  old chunks into a new checkpoint.

  A snapshot without in-flight coverage can omit already flushed chunks.
  This reducer does not pretend that attachment is lossless or deduplicate
  projections against checkpoint history.
  """

  alias EvoGit.Agent.Stream

  @type projection :: %{
          identity: map(),
          turn: non_neg_integer() | nil,
          message_index: non_neg_integer(),
          response: binary(),
          thinking: binary(),
          tool_calls: [map()],
          complete: boolean(),
          generation_complete: boolean(),
          capture_coverage: :complete | :partial,
          chunks_seen: boolean()
        }
  @type t :: %__MODULE__{
          agent_id: term(),
          node: term(),
          seq: non_neg_integer(),
          phase: atom() | nil,
          activity: atom() | map() | nil,
          turn: non_neg_integer(),
          messages: list(),
          response: binary(),
          thinking: binary(),
          tool_calls: [map()],
          projections: [projection()],
          message_index: non_neg_integer() | nil,
          finished: boolean(),
          status: atom() | nil
        }

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
            message_index: nil,
            finished: false,
            status: nil

  @doc "Builds an empty projection scoped to one agent and node."
  @spec new(term(), term()) :: t()
  def new(agent_id, node), do: %__MODULE__{agent_id: agent_id, node: node}

  @doc """
  Replaces state with a snapshot, preserving only agent/node ownership.

  Malformed fields clear to their empty defaults; missing optional struct keys
  are safe. A snapshot explicitly naming another agent is ignored. A valid
  explicit seq wins, then snapshot seq, then zero. Non-struct state resets to
  an unowned empty state. Callers must guard node/attachment generations.
  """
  @spec seed(term(), term(), term()) :: t()
  def seed(%__MODULE__{} = state, snapshot, seq) do
    if field(snapshot, :agent_id) in [nil, state.agent_id] do
      phase = atom_or_nil(field(snapshot, :phase))
      finished = phase in [:finished, :completed, :failed, :cancelled]

      seeded = %{
        new(state.agent_id, state.node)
        | seq: number(seq) || number(field(snapshot, :seq)) || 0,
          phase: phase,
          activity: activity(field(snapshot, :activity)),
          turn: number(field(snapshot, :turn)) || 0,
          messages: list(field(snapshot, :messages)),
          finished: finished,
          status: atom_or_nil(field(snapshot, :status)) || phase
      }

      seeded = seed_in_flight(seeded, field(snapshot, :in_flight))
      if finished, do: %{complete_current(seeded) | activity: nil}, else: seeded
    else
      state
    end
  end

  def seed(_state, _snapshot, _seq), do: new(nil, nil)

  @doc """
  Applies a newer batch for the owned agent, otherwise returns state unchanged.

  Uses the shared stream normalization/stale rule. Unknown or malformed events
  are ignored; a valid newer batch still advances seq. Finished state accepts
  no further batches. Node and watch-generation guards belong to the caller.
  """
  @spec apply_batch(term(), term(), term(), term()) :: t()
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

  @doc "True only for a nonterminal running/cancelling lifecycle, not an activity guess."
  @spec active?(term()) :: boolean()
  def active?(%__MODULE__{finished: false, phase: phase}),
    do: phase in [:running, :cancelling]

  def active?(_state), do: false

  defp seed_in_flight(state, flight) when is_map(flight) do
    state = start_message(state, message_identity(flight))
    response = field(flight, :response) || field(flight, :text)
    thinking = field(flight, :thinking)

    # Only an explicit complete snapshot assertion with both content fields
    # proves capture; lifecycle and a missing thinking field prove nothing.
    coverage =
      if field(flight, :capture_coverage) == :complete and is_binary(response) and
           is_binary(thinking),
         do: :complete,
         else: :partial

    update_current(state, fn message ->
      %{
        message
        | response: text(response),
          thinking: text(thinking),
          capture_coverage: coverage,
          chunks_seen: response not in [nil, ""] or thinking not in [nil, ""],
          generation_complete: field(flight, :generation_complete) == true,
          complete: field(flight, :generation_complete) == true
      }
    end)
  end

  defp seed_in_flight(state, _flight), do: state

  # Once a terminal fact appears, later events in the same batch are inert too.
  defp apply_event(_event, %{finished: true} = state), do: state

  defp apply_event({kind, chunk}, state)
       when kind in [:text, :thinking] and is_binary(chunk) and chunk != "" do
    state = ensure_message(state, true)
    key = if kind == :text, do: :response, else: :thinking

    update_current(state, fn message ->
      message
      |> Map.update!(key, fn previous -> previous <> chunk end)
      |> Map.put(:chunks_seen, true)
    end)
  end

  defp apply_event({:message_start, value}, state) do
    case message_identity(value) do
      identity when map_size(identity) > 0 ->
        state
        |> start_message(identity)
        |> update_current(fn message ->
          if not message.chunks_seen and not message.generation_complete,
            do: %{message | capture_coverage: :complete},
            else: message
        end)

      _ ->
        state
    end
  end

  defp apply_event({:activity, value}, state) when is_atom(value) or is_map(value) do
    state = %{state | activity: activity(value)}

    if field(value, :phase) == :llm and map_size(message_identity(value)) > 0 do
      start_message(state, message_identity(value))
    else
      state
    end
  end

  defp apply_event({:tool_call, id, name}, state) when is_binary(name) and name != "" do
    state = ensure_message(state, false)

    update_current(state, fn message ->
      %{message | tool_calls: announce_tool(message.tool_calls, id, name)}
    end)
  end

  defp apply_event({:tool_result, id, status}, state) when not is_nil(id) do
    projections =
      Enum.map(state.projections, fn message ->
        tools =
          Enum.map(message.tool_calls, fn tool ->
            if tool.id == id, do: %{tool | status: status}, else: tool
          end)

        %{message | tool_calls: tools}
      end)

    sync(%{state | projections: projections})
  end

  defp apply_event({:turn, info}, state) when is_map(info) do
    turn = number(field(info, :turn)) || state.turn
    state = %{state | turn: turn}

    state
    |> update_current(fn message -> %{message | turn: turn, generation_complete: true} end)
    |> complete_current()
  end

  defp apply_event({:yield, value}, state) when is_binary(value) do
    state =
      if value == "" do
        state
      else
        state
        |> ensure_message(false)
        |> update_current(fn message -> %{message | response: value} end)
      end

    state = update_current(state, &%{&1 | generation_complete: true})
    %{complete_current(state) | phase: :awaiting_input, status: :awaiting_input, activity: nil}
  end

  defp apply_event({:finished, status}, state) when is_atom(status) and not is_nil(status) do
    %{complete_current(state) | finished: true, phase: :finished, status: status, activity: nil}
  end

  defp apply_event(_event, state), do: state

  defp ensure_message(state, advance_completed?) do
    case List.last(state.projections) do
      nil -> start_message(state, %{})
      %{complete: true} when advance_completed? -> start_message(state, %{})
      _ -> state
    end
  end

  defp start_message(state, identity) do
    case List.last(state.projections) do
      %{identity: previous} when map_size(identity) > 0 and previous == identity ->
        state

      _ ->
        state = complete_current(state)
        index = number(field(identity, :message_index)) || next_index(state)
        turn = number(field(identity, :turn)) || state.turn

        message = %{
          identity: identity,
          turn: turn,
          message_index: index,
          response: "",
          thinking: "",
          tool_calls: [],
          complete: false,
          generation_complete: false,
          capture_coverage: :partial,
          chunks_seen: false
        }

        sync(%{state | projections: state.projections ++ [message], turn: turn})
    end
  end

  defp next_index(%{projections: []}), do: 0
  defp next_index(state), do: Enum.max_by(state.projections, & &1.message_index).message_index + 1

  defp complete_current(state),
    do: update_current(state, fn message -> %{message | complete: true} end)

  defp update_current(%{projections: []} = state, _fun), do: state

  defp update_current(state, fun) do
    {older, [current]} = Enum.split(state.projections, -1)
    sync(%{state | projections: older ++ [fun.(current)]})
  end

  defp sync(%{projections: []} = state), do: state

  defp sync(state) do
    current = List.last(state.projections)

    %{
      state
      | response: current.response,
        thinking: current.thinking,
        tool_calls: current.tool_calls,
        message_index: current.message_index
    }
  end

  # Streaming announcements may lack ids; the dispatch announcement supplies it.
  # Neither announcement is evidence that execution has actually started.
  defp announce_tool(tools, id, name) do
    index =
      Enum.find_index(tools, fn tool ->
        (not is_nil(id) and tool.id == id) or (is_nil(tool.id) and tool.name == name)
      end)

    if is_nil(index) do
      tools ++ [%{id: id, name: name, status: :announced}]
    else
      List.update_at(tools, index, fn tool -> %{tool | id: id || tool.id, name: name} end)
    end
  end

  @doc "Normalizes explicit stream/checkpoint message identity, never a local row ordinal."
  def message_identity(value) when is_integer(value) and value >= 0, do: %{message_index: value}
  def message_identity(value) when is_binary(value) and value != "", do: %{id: value}

  def message_identity(value) when is_map(value) do
    Enum.reduce([:turn, :message_index, :id], %{}, fn key, acc ->
      candidate = field(value, key)

      cond do
        key in [:turn, :message_index] and not is_nil(number(candidate)) ->
          Map.put(acc, key, candidate)

        key == :id and (is_binary(candidate) or is_integer(candidate)) and candidate != "" ->
          Map.put(acc, key, candidate)

        true ->
          acc
      end
    end)
  end

  def message_identity(_value), do: %{}

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
  defp activity(value) when is_atom(value) or is_map(value), do: value
  defp activity(_value), do: nil
end
