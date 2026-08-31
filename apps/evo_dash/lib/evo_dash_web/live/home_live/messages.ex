defmodule EvoDashWeb.HomeLive.Messages do
  @moduledoc """
  Converts native `%ReqLLM.Message{}` structs (as returned by
  `EvoDash.NodeContext.get_agent_history/2`) into plain display text and
  thought-process entries for the Home chat page.

  Every function here is TOTAL: nil/absent content, string content, non-map
  content parts, nil metadata, and missing keys all degrade to safe defaults —
  never raise (the history payload crosses an async/RPC boundary and its shape
  is owned by the `:evo_git` core).
  """

  @doc """
  Returns the assistant text from a list of messages: the text parts of every
  `:assistant` message, one message per line. User/system/tool messages are
  skipped (the reflect agent's user-role messages echo the sent objective;
  HomeLive renders the user bubble itself). Never raises.
  """
  @spec assistant_text([map()] | nil) :: String.t()
  def assistant_text(messages) when is_list(messages) do
    messages
    |> Enum.filter(&assistant_message?/1)
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def assistant_text(_messages), do: ""

  @doc """
  Extracts the display text of a single message. Total: `nil`/absent content →
  `""`; a plain binary content → itself; a content-part list → the `:text` of
  each map part, with non-map parts and parts without `:text` skipped.
  `:thinking`-only parts contribute nothing here — they surface via
  `reasoning_details` in `to_entries/1` (the thought-process section) instead,
  keeping the streamed bubble clean. Never raises.
  """
  @spec message_text(term()) :: String.t()
  def message_text(message) when is_map(message) do
    case Map.get(message, :content, []) do
      content when is_list(content) ->
        content
        |> Enum.map(fn
          part when is_map(part) ->
            case Map.get(part, :text) do
              text when is_binary(text) -> text
              _ -> ""
            end

          part when is_binary(part) ->
            part

          _ ->
            ""
        end)
        |> Enum.join()

      content when is_binary(content) ->
        content

      _ ->
        ""
    end
  end

  def message_text(_message), do: ""

  @doc """
  Converts messages into the `%{turn, type, data}` entry format consumed by
  the agents-page templates, mirroring `EvoDashWeb.AgentsLive`'s conversion
  (tool_calls, reasoning_details, tool_name, and metadata ride along in
  `data`). Used for the assistant card's collapsible "Thought process" section.
  Never raises.
  """
  @spec to_entries([map()] | nil) :: [map()]
  def to_entries(messages) when is_list(messages) do
    messages
    |> Enum.map(&to_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  def to_entries(_messages), do: []

  defp assistant_message?(message) when is_map(message) do
    role = Map.get(message, :role)
    role == :assistant or role == "assistant"
  end

  defp assistant_message?(_message), do: false

  defp to_entry(%ReqLLM.Message{} = message) do
    metadata = if is_map(message.metadata), do: message.metadata, else: %{}

    %{
      turn: Map.get(metadata, :turn) || 0,
      timestamp: Map.get(metadata, :timestamp),
      type: role_type(message.role),
      data: %{
        content: message_text(message),
        tool_calls: message.tool_calls,
        reasoning_details: message.reasoning_details,
        tool_name: Map.get(metadata, :tool_name) || message.name,
        metadata: metadata
      }
    }
  end

  defp to_entry(message) when is_map(message) do
    metadata =
      case Map.get(message, :metadata) do
        value when is_map(value) -> value
        _ -> %{}
      end

    role = Map.get(message, :role)

    %{
      turn: Map.get(metadata, :turn) || 0,
      timestamp: Map.get(metadata, :timestamp),
      type: role_type(role),
      data: %{
        content: message_text(message),
        tool_calls: Map.get(message, :tool_calls),
        reasoning_details: Map.get(message, :reasoning_details),
        tool_name: Map.get(metadata, :tool_name) || Map.get(message, :name),
        metadata: metadata
      }
    }
  end

  defp to_entry(_message), do: nil

  defp role_type(role) when is_atom(role), do: Atom.to_string(role)
  defp role_type(role) when is_binary(role), do: role
  defp role_type(_role), do: ""
end
