defmodule EvoDashWeb.AgentsLive.StreamPresentation do
  @moduledoc """
  Bounded, display-only view of an inspector RuntimeStream.

  This does not merge live excerpts into checkpoint history: today's core does
  not supply a transcript-coverage watermark, so doing so would risk duplication
  or loss. Raw reducer content remains unchanged. Every omitted character,
  projection and tool has an explicit count in the returned view.

  Activity comes ONLY from the authoritative activity field, never lifecycle,
  thinking chunks, tool announcements or tool results. Missing activity is
  unknown, not idle. `thinking_status/2` defaults to partial capture; callers
  may assert complete coverage only when the core guarantees it for that message.
  A completed projection alone is not proof that no thinking was generated.
  """

  alias EvoDashWeb.AgentsLive.RuntimeStream

  @max_messages 12
  @max_characters 12_000
  @max_tools 20

  @doc "Builds a bounded render model without changing raw state or interpreting checkpoint messages."
  def build(state) do
    projections = list(field(state, :projections))
    retained = Enum.take(projections, -@max_messages)

    %{
      activity: activity(field(state, :activity)),
      phase: field(state, :phase),
      status: field(state, :status),
      finished: field(state, :finished) == true,
      messages: Enum.map(retained, &message/1),
      omitted_messages: max(length(projections) - length(retained), 0)
    }
  end

  @doc "Classifies only authoritative activity; unknown shapes remain unknown."
  def activity(value) when is_map(value), do: activity(field(value, :phase))
  def activity(:llm), do: :llm
  def activity(:tool), do: :tool
  def activity(:tools), do: :tool
  def activity(:idle), do: :idle
  def activity(:waiting), do: :waiting
  def activity(_value), do: :unknown

  @doc """
  Thinking availability, without equating missing chunks with absent reasoning.

  `:none` requires both completed generation and explicitly complete capture.
  `:unavailable` means generation ended but this observer cannot prove absence.
  Failed/aborted lifecycle completion is NOT generation completion; callers
  providing their own message maps must preserve that distinction.
  """
  def thinking_status(projection, coverage \\ :partial) do
    cond do
      text(field(projection, :thinking)) != "" -> :present
      field(projection, :generation_complete) != true -> :pending
      coverage == :complete -> :none
      true -> :unavailable
    end
  end

  @doc "True only for a RuntimeStream owned by the exact selected agent and viewed node."
  def owned?(%RuntimeStream{agent_id: id, node: target}, id, target), do: true
  def owned?(_state, _id, _target), do: false

  defp message(projection) do
    {response, omitted_response} = preview(field(projection, :response))
    {thinking, omitted_thinking} = preview(field(projection, :thinking))
    tools = list(field(projection, :tool_calls))

    %{
      message_index: field(projection, :message_index),
      turn: field(projection, :turn),
      complete: field(projection, :complete) == true,
      response: response,
      thinking: thinking,
      thinking_status: thinking_status(projection),
      omitted_response: omitted_response,
      omitted_thinking: omitted_thinking,
      tool_calls: tools |> Enum.take(@max_tools) |> Enum.map(&tool/1),
      omitted_tools: max(length(tools) - @max_tools, 0)
    }
  end

  defp tool(value) do
    {name, omitted_name} = preview(field(value, :name))

    %{
      name: name,
      omitted_name: omitted_name,
      status: tool_status(field(value, :status))
    }
  end

  defp tool_status(value) when value in [:announced, :ok, :error, :timeout], do: value
  defp tool_status(_value), do: :unknown

  defp preview(value) do
    value = text(value)
    length = String.length(value)
    {String.slice(value, 0, @max_characters), max(length - @max_characters, 0)}
  end

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, to_string(key)))

  defp field(_value, _key), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
