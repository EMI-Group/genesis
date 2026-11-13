defmodule EvoDashWeb.AgentsLive.StreamPresentation do
  @moduledoc """
  Bounded, display-only view of an inspector RuntimeStream.

  This does not merge live excerpts into checkpoint history: today's core does
  not supply a transcript-coverage watermark, so doing so would risk duplication
  or loss. Raw reducer content remains unchanged. Every omitted character,
  projection and tool has an explicit count in the returned view.

  Activity comes ONLY from the authoritative activity field, never lifecycle,
  thinking chunks, tool announcements or tool results. Missing activity is
  unknown, not idle. `thinking_status/2` uses the reducer's capture coverage by
  default; an explicit second argument remains a caller-owned coverage override.
  Completed generation alone is not proof that no thinking was generated.
  `checkpoint_part_covered?/4` is a conservative identity/coverage-aware display
  predicate over only wholly rendered parts, never bounded-prefix equality.
  """

  alias EvoDashWeb.AgentsLive.RuntimeStream

  @max_messages 12
  @max_characters 12_000
  @max_tools 20

  @doc "Builds a bounded render model without changing raw state or interpreting checkpoint messages."
  def build(state) do
    projections = list(field(state, :projections))
    retained = Enum.take(projections, -@max_messages)
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
  def thinking_status(projection, coverage \\ nil) do
    coverage = coverage || field(projection, :capture_coverage)

    cond do
      text(field(projection, :thinking)) != "" -> :present
      field(projection, :generation_complete) != true -> :pending
      coverage == :complete -> :none
      true -> :unavailable
    end
  end

  @doc """
  Whether a checkpoint part is wholly represented in a currently rendered live message.

  The caller must supply the checkpoint's authoritative message identity, never
  its row index, a turn guess or a text match. Identity must exactly match the
  explicit stream identity and contain an id or message_index. Unknown identity,
  partial capture, unfinished generation, omitted projections and truncated
  parts all return false. This is a display predicate, never a history mutation.
  """
  def checkpoint_part_covered?(state, checkpoint_identity, part, value)
      when part in [:response, :thinking] and is_map(checkpoint_identity) and
             is_binary(value) and value != "" do
    identity = RuntimeStream.message_identity(checkpoint_identity)
    omission_key = if part == :response, do: :omitted_response, else: :omitted_thinking

    if Map.has_key?(identity, :id) or Map.has_key?(identity, :message_index) do
      Enum.any?(build(state).messages, fn message ->
        message.identity == identity and message.capture_coverage == :complete and
          message.generation_complete and Map.get(message, omission_key) == 0 and
          Map.get(message, part) == value
      end)
    else
      false
    end
  end

  def checkpoint_part_covered?(_state, _identity, _part, _value), do: false

  @doc "True only for a RuntimeStream owned by the exact selected agent and viewed node."
  def owned?(%RuntimeStream{agent_id: id, node: target}, id, target), do: true
  def owned?(_state, _id, _target), do: false

  defp message(projection) do
    {response, omitted_response} = preview(field(projection, :response))
    {thinking, omitted_thinking} = preview(field(projection, :thinking))
    tools = list(field(projection, :tool_calls))

    %{
      identity: RuntimeStream.message_identity(field(projection, :identity)),
      capture_coverage: field(projection, :capture_coverage),
      generation_complete: field(projection, :generation_complete) == true,
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
