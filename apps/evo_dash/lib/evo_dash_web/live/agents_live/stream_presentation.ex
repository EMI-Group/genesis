defmodule EvoDashWeb.AgentsLive.StreamPresentation do
  @moduledoc """
  Bounded, display-only view of an inspector RuntimeStream.

  Core activity owns the single live call; retirement removes its excerpts
  instead of guessing overlap with checkpoint history. Every omitted byte and
  tool has an explicit count. `omitted_response`/`omitted_thinking` count
  render-stage graphemes only; their byte counterparts include reducer AND
  render omissions without counting full replacement transmissions twice.

  Activity comes ONLY from the authoritative phase, never lifecycle, chunks or
  tool announcements. Missing activity is unknown, not idle. Empty thinking is
  reported only after successful generation with complete source capture and
  no omitted thinking. Atomic snapshot handoff belongs to StreamWatch; checkpoint
  parts are never suppressed by guessed overlap with live excerpts.
  """

  alias EvoDashWeb.AgentsLive.{RuntimeStream, StreamLimits}

  @max_messages 12
  @max_characters 12_000
  @max_tools 20

  @doc "Maximum messages rendered, also the reducer's live retention limit."
  def max_messages, do: min(@max_messages, StreamLimits.max_projections())

  @doc "Maximum graphemes displayed per response/thinking excerpt."
  def max_characters, do: @max_characters

  @doc "Maximum tools displayed per live message."
  def max_tools, do: @max_tools

  @doc "Builds a bounded render model without changing raw state or interpreting checkpoint messages."
  def build(state) do
    projections = list(field(state, :projections))
    retained = Enum.take(projections, -max_messages())
    generating = activity(field(state, :activity)) == :llm and field(state, :finished) != true

    messages =
      retained
      |> Enum.with_index()
      |> Enum.map(fn {projection, index} ->
        active =
          generating and index == length(retained) - 1 and
            field(projection, :complete) != true

        Map.put(message(projection), :active, active)
      end)

    %{
      activity: activity(field(state, :activity)),
      generating: generating and (messages == [] or List.last(messages).active),
      phase: field(state, :phase),
      status: field(state, :status),
      finished: field(state, :finished) == true,
      messages: messages,
      omitted_messages:
        count(field(state, :omitted_messages)) + max(length(projections) - length(retained), 0)
    }
  end

  @doc "Classifies only authoritative activity; unknown shapes remain unknown."
  def activity(value) when is_map(value), do: activity(field(value, :phase))
  def activity(:llm), do: :llm
  def activity(:tools), do: :tool
  def activity(:idle), do: :idle
  def activity(:llm_waiting), do: :waiting
  def activity(:llm_complete), do: :llm_complete
  def activity(:retry_wait), do: :retry_wait
  def activity(_value), do: :unknown

  @doc """
  Thinking availability, without equating missing chunks with absent reasoning.

  `:none` requires both completed generation and explicitly complete capture.
  `:unavailable` means generation ended but this observer cannot prove absence.
  Failed/aborted lifecycle completion is NOT generation completion; callers
  providing their own message maps must preserve that distinction.
  """
  def thinking_status(projection) do
    coverage = field(projection, :capture_coverage)

    cond do
      text(field(projection, :thinking)) != "" -> :present
      count(field(projection, :omitted_thinking_bytes)) > 0 -> :unavailable
      field(projection, :generation_complete) != true -> :pending
      coverage == :complete -> :none
      true -> :unavailable
    end
  end

  @doc "True only for a RuntimeStream owned by the exact selected agent and viewed node."
  def owned?(%RuntimeStream{agent_id: id, node: target}, id, target), do: true
  def owned?(_state, _id, _target), do: false

  defp message(projection) do
    {response, omitted_response, response_bytes} = preview(field(projection, :response))
    {thinking, omitted_thinking, thinking_bytes} = preview(field(projection, :thinking))
    tools = list(field(projection, :tool_calls))

    %{
      identity: call_identity(field(projection, :identity)),
      capture_coverage: field(projection, :capture_coverage),
      generation_complete: field(projection, :generation_complete) == true,
      message_index: field(projection, :message_index),
      turn: field(projection, :turn),
      attempt: field(projection, :attempt),
      complete: field(projection, :complete) == true,
      response: response,
      thinking: thinking,
      thinking_status: thinking_status(projection),
      omitted_response: omitted_response,
      omitted_thinking: omitted_thinking,
      omitted_response_bytes: count(field(projection, :omitted_response_bytes)) + response_bytes,
      omitted_thinking_bytes: count(field(projection, :omitted_thinking_bytes)) + thinking_bytes,
      tool_calls: tools |> Enum.take(@max_tools) |> Enum.map(&tool/1),
      omitted_tools: count(field(projection, :omitted_tools)) + max(length(tools) - @max_tools, 0)
    }
  end

  defp call_identity(%{id: id}) when is_binary(id), do: %{id: id}
  defp call_identity(_value), do: %{}

  defp tool(value) do
    {name, omitted_name} =
      StreamLimits.preview(text(field(value, :name)), StreamLimits.max_tool_name_bytes())

    %{
      name: name,
      omitted_name: max(String.length(text(field(value, :name))) - String.length(name), 0),
      omitted_name_bytes: count(field(value, :omitted_name_bytes)) + omitted_name,
      status: tool_status(field(value, :status))
    }
  end

  defp tool_status(value) when value in [:announced, :ok, :error, :timeout], do: value
  defp tool_status(_value), do: :unknown

  defp preview(value) do
    value = text(value)
    {bounded, _omitted} = StreamLimits.preview(value, StreamLimits.max_text_bytes())
    preview = bounded |> String.slice(0, @max_characters) |> :binary.copy()

    {preview, max(String.length(value) - String.length(preview), 0),
     byte_size(value) - byte_size(preview)}
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, to_string(key)))

  defp field(_value, _key), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
