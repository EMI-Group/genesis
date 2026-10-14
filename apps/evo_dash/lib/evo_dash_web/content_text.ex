defmodule EvoDashWeb.ContentText do
  @moduledoc """
  Classifies `%ReqLLM.Message{}` content parts into the RESPONSE text.

  ReqLLM keeps reasoning/thinking strictly apart from the visible response:
  reasoning arrives as `:thinking` content parts (mirrored into
  `message.reasoning_details`) while the visible answer is carried by `:text`
  parts. Joining the `:text` of EVERY part therefore duplicates the reasoning
  into the response — this module is the single source of truth for "which
  content parts make up the response text", mirroring
  `ReqLLM.Response.text/1` (`&(&1.type == :text)`) and complementing
  `ReqLLM.Response.thinking/1`.

  Consumers: `EvoDashWeb.AgentsLive.message_to_history_entry/1` (the agent
  detail panel's `data.content`) and
  `EvoDashWeb.HomeLive.Messages.message_text/1` (the Home chat bubble + the
  assistant card's thought-process entries).

  Every function is TOTAL: atom- or string-keyed maps, bare maps without a
  `:type`, nil/absent/non-binary text and non-map parts all degrade to a safe
  value — never raise.
  """

  @doc """
  True when `part` is a content part that contributes to the response text: a
  map whose `:type`/`"type"` is `:text`/`"text"`, or is absent/nil/`""` (a bare
  `%{text: "..."}` map without a type still counts as text).

  Every other explicit type (`:thinking`, `:image`, `:image_url`, `:file`,
  `:video_url`, `:audio`, unknown) and every non-map value is `false`.
  """
  @spec text_part?(term()) :: boolean()
  def text_part?(part) when is_map(part) do
    case pget(part, :type) do
      type when type in [:text, "text"] -> true
      type when type in [nil, ""] -> true
      _ -> false
    end
  end

  def text_part?(_part), do: false

  @doc """
  The response text carried by `part`: its `:text` value when `text_part?/1` is
  true AND that value is a binary, otherwise `nil`.
  """
  @spec text_of(term()) :: binary() | nil
  def text_of(part) do
    if text_part?(part) do
      case Map.get(part, :text) do
        text when is_binary(text) -> text
        _ -> nil
      end
    else
      nil
    end
  end

  # Atom-or-string-key tolerant read (mirrors AgentsLive.pget/2) — total on any
  # map shape.
  defp pget(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
