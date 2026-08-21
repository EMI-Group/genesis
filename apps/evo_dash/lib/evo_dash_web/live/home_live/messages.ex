defmodule EvoDashWeb.HomeLive.Messages do
  @moduledoc """
  Converts native `%ReqLLM.Message{}` structs (as returned by
  `EvoDash.NodeContext.get_agent_history/2`) into plain display text for the
  Home chat bubbles.
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
  Converts messages into the `%{turn, type, data}` entry format consumed by
  the agents-page templates, mirroring `EvoDashWeb.AgentsLive`'s conversion
  (tool_calls, reasoning_details, tool_name, and metadata ride along in
  `data`). Kept for parity/testing.
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

  defp message_text(message) do
    message
    |> Map.get(:content, [])
    |> Enum.map(fn part -> if is_map(part), do: Map.get(part, :text), else: nil end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp to_entry(%ReqLLM.Message{} = message) do
    %{
      turn: Map.get(message.metadata, :turn) || 0,
      timestamp: Map.get(message.metadata, :timestamp),
      type: role_type(message.role),
      data: %{
        content: message_text(message),
        tool_calls: message.tool_calls,
        reasoning_details: message.reasoning_details,
        tool_name: Map.get(message.metadata, :tool_name) || message.name,
        metadata: message.metadata
      }
    }
  end

  defp to_entry(message) when is_map(message) do
    metadata = Map.get(message, :metadata) || %{}
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
