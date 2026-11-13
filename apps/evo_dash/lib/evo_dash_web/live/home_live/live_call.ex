defmodule EvoDashWeb.HomeLive.LiveCall do
  @moduledoc """
  Projects the core's replaceable current LLM call onto the Assistant surface.

  Call ids, not text equality, identify the live bubble and reasoning entry.
  Phase replacements overwrite captured prefixes; chunks alone append.
  Retry discards the failed attempt, while checkpoint retirement keeps its answer.
  """

  alias EvoDashWeb.HomeLive.Transcript

  @phases [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools]

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
      call == nil -> %{acc | delta: %{acc.delta | thinking: ""}}
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
      | delta: %{acc.delta | call_entry_id: nil, thinking: "", text_in_turn: false},
        transcript: Enum.reject(Transcript.normalize(acc.transcript), &(&1.id == id)),
        thought_process:
          Enum.reject(
            entries(acc.thought_process),
            &(call_id != nil and thought_id(&1) == call_id)
          )
    }
  end

  defp render(acc) do
    call = acc.delta.activity.current_call
    id = acc.delta.call_entry_id
    transcript = Transcript.normalize(acc.transcript)
    existing? = id != nil and Enum.any?(transcript, &(&1.id == id))

    {transcript, id} =
      cond do
        existing? ->
          {Enum.map(transcript, fn entry ->
             if entry.id == id, do: %{entry | text: call.text}, else: entry
           end)
           |> Transcript.normalize(), id}

        call.text != "" ->
          entry = Transcript.entry(:assistant, call.text, streaming: true)
          {Transcript.append(Transcript.close_streaming(transcript), entry), entry.id}

        true ->
          {transcript, nil}
      end

    thoughts = entries(acc.thought_process)
    previous = Enum.find(thoughts, &(thought_id(&1) == call.id))
    thoughts = Enum.reject(thoughts, &(thought_id(&1) == call.id))

    thoughts =
      if call.thinking == "" do
        thoughts
      else
        thought = thinking_entry(call.turn, call.thinking, %{thinking: true, call_id: call.id})
        thought = if previous, do: %{thought | timestamp: previous.timestamp}, else: thought

        Enum.take(thoughts ++ [thought], -40)
      end

    %{
      acc
      | delta: %{
          acc.delta
          | call_entry_id: id,
            turn: call.turn,
            thinking: call.thinking,
            text_in_turn: call.text != ""
        },
        transcript: transcript,
        thought_process: thoughts
    }
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
        reasoning_details: [%{text: text, type: "thinking"}],
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
