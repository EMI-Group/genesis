defmodule EvoDashWeb.HomeLive.LiveCall do
  @moduledoc """
  Projects the core's replaceable current LLM call onto the Assistant surface.

  Call ids, not text equality, identify the live bubble and reasoning entry.
  Phase replacements overwrite captured prefixes; chunks alone append.
  Retry discards the failed attempt, while checkpoint retirement keeps its answer.
  """

  alias EvoDashWeb.HomeLive.Transcript

  # Kept in step with `EvoDashWeb.HomeLive.Delta` / `Transcript`'s per-turn
  # reasoning cap: the live thought list never outgrows the history-derived one.
  @max_thought_entries 40

  # `:compressing` and `:preparing` are non-call phases as well: admitting them keeps
  # the Assistant's shown activity current instead of freezing on the previous phase.
  @phases [
    :idle,
    :llm_waiting,
    :llm,
    :llm_complete,
    :retry_wait,
    :tools,
    :compressing,
    :preparing
  ]

  def replace(acc, %{phase: phase, current_call: call} = activity) when phase in @phases do
    if valid_call?(call) do
      acc = prepare_call(acc, call, phase)
      acc = %{acc | delta: %{acc.delta | activity: activity}}
      if call, do: render(acc), else: acc
    else
      acc
    end
  end

  def replace(acc, _activity), do: acc

  def append(acc, kind, chunk) do
    case acc.delta.activity do
      %{current_call: %{} = call} = activity ->
        call = Map.update!(call, kind, &(&1 <> chunk))
        render(%{acc | delta: %{acc.delta | activity: %{activity | current_call: call}}})

      _ ->
        acc
    end
  end

  defp prepare_call(acc, call, phase) do
    previous = acc.delta.activity && acc.delta.activity.current_call

    cond do
      phase == :retry_wait -> discard(acc, previous)
      call == nil -> %{acc | delta: %{acc.delta | thinking: "", reasoning_text: ""}}
      previous && previous.id == call.id -> acc
      previous && previous.turn == call.turn -> discard(acc, previous)
      true -> %{acc | delta: %{acc.delta | call_entry_id: nil}}
    end
  end

  defp discard(acc, previous) do
    id = acc.delta.call_entry_id
    call_id = previous && previous.id

    %{
      acc
      | delta: %{
          acc.delta
          | call_entry_id: nil,
            thinking: "",
            reasoning_text: "",
            text_in_turn: false
        },
        transcript: Enum.reject(Transcript.normalize(acc.transcript), &(&1.id == id)),
        thought_process:
          Enum.reject(
            entries(acc.thought_process),
            &(call_id != nil and thought_id(&1) == call_id)
          )
    }
  end

  # The hot path (one ~75 ms delta batch): exactly ONE whole-transcript
  # normalization. Everything below — the bubble write, the reasoning attach
  # and the close-then-open of a fresh bubble — operates on that already
  # normalized list, so no further whole-list pass runs here.
  defp render(acc) do
    call = acc.delta.activity.current_call
    id = acc.delta.call_entry_id

    transcript = Transcript.normalize(acc.transcript)

    thoughts = entries(acc.thought_process)
    previous = Enum.find(thoughts, &(thought_id(&1) == call.id))
    thoughts = Enum.reject(thoughts, &(thought_id(&1) == call.id))

    thoughts =
      if call.thinking == "" do
        thoughts
      else
        thought = thinking_entry(call.turn, call.thinking, %{thinking: true, call_id: call.id})
        thought = if previous, do: %{thought | timestamp: previous.timestamp}, else: thought

        Enum.take(thoughts ++ [thought], -@max_thought_entries)
      end

    # Already capped at @max_thought_entries above, so this is exactly the list
    # `Transcript.put_reasoning/3` would store — attached inline to avoid the
    # second whole-transcript pass that helper would cost.
    reasoning = Enum.filter(thoughts, &(thought_id(&1) == call.id))
    {transcript, id} = render_bubble(transcript, id, call.text, reasoning)

    %{
      acc
      | delta: %{
          acc.delta
          | call_entry_id: id,
            turn: call.turn,
            thinking: call.thinking,
            reasoning_text: call.thinking,
            text_in_turn: call.text != ""
        },
        transcript: transcript,
        thought_process: thoughts
    }
  end

  # Writes the live bubble into an ALREADY-NORMALIZED transcript: a known id
  # keeps that entry streaming and takes the projected text (plus its reasoning),
  # otherwise the previous streaming bubble is closed and a fresh one opened.
  defp render_bubble(transcript, id, text, reasoning) do
    cond do
      id != nil and Enum.any?(transcript, &(&1.id == id)) ->
        {Enum.map(transcript, fn
           %{id: ^id} = entry ->
             entry
             |> Map.put(:text, Transcript.cap_text(text))
             |> Map.put(:reasoning, reasoning)

           entry ->
             entry
         end), id}

      text != "" ->
        entry = Transcript.entry(:assistant, text, streaming: true, reasoning: reasoning)
        {Transcript.append(Transcript.close_streaming_normalized(transcript), entry), entry.id}

      true ->
        {transcript, nil}
    end
  end

  @doc false
  def thinking_entry(turn, text, metadata \\ %{thinking: true}) do
    %{
      turn: turn,
      timestamp: System.system_time(:second),
      type: "assistant",
      data: %{
        content: "",
        tool_calls: [],
        reasoning_details: [
          %{text: Transcript.cap_thought_text(text), type: "thinking"}
        ],
        tool_name: nil,
        metadata: metadata
      }
    }
  end

  defp thought_id(%{data: %{metadata: %{call_id: id}}}), do: id
  defp thought_id(_entry), do: nil
  defp entries(entries) when is_list(entries), do: entries
  defp entries(_entries), do: []

  defp valid_call?(nil), do: true

  defp valid_call?(%{id: id, turn: turn, attempt: attempt, text: text, thinking: thinking}),
    do:
      is_binary(id) and is_integer(turn) and turn >= 0 and is_integer(attempt) and attempt >= 0 and
        is_binary(text) and is_binary(thinking)

  defp valid_call?(_call), do: false
end
