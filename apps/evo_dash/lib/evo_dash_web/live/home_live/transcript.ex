defmodule EvoDashWeb.HomeLive.Transcript do
  @moduledoc """
  Pure chat-transcript model for the Home chat LiveView.

  A transcript is a list of entries (oldest first), where each entry is a plain
  map `%{id: String.t(), role: :user | :assistant | :error, text: String.t(),
  streaming: boolean()}`.
  """

  @type role :: :user | :assistant | :error
  @type entry :: %{id: String.t(), role: role, text: String.t(), streaming: boolean()}
  @type t :: [entry]

  @doc "Returns a new, empty transcript."
  @spec new() :: t
  def new, do: []

  @doc "Appends an entry to the end of the transcript."
  @spec append(t, entry) :: t
  def append(transcript, entry), do: transcript ++ [entry]

  @doc """
  Builds an entry with a unique string id.

  Options: `:streaming` (default `false`).
  """
  @spec entry(role, String.t(), keyword()) :: entry
  def entry(role, text, opts \\ []) do
    %{
      id: System.unique_integer([:positive]) |> Integer.to_string(),
      role: role,
      text: text,
      streaming: Keyword.get(opts, :streaming, false)
    }
  end

  @doc """
  Updates the text of the last streaming entry, or appends a new streaming
  assistant entry when none is streaming. Idempotent — used when a refetched
  agent history replaces the in-progress bubble.
  """
  @spec put_streaming_text(t, String.t()) :: t
  def put_streaming_text(transcript, text) do
    case last_streaming_index(transcript) do
      nil -> append(transcript, entry(:assistant, text, streaming: true))
      index -> List.update_at(transcript, index, &Map.put(&1, :text, text))
    end
  end

  @doc """
  Finalizes the last streaming entry (sets `streaming: false` and replaces its
  text), or appends a new non-streaming assistant entry when none is streaming.
  Used when the final result arrives.
  """
  @spec finalize_assistant(t, String.t()) :: t
  def finalize_assistant(transcript, text) do
    case last_streaming_index(transcript) do
      nil ->
        append(transcript, entry(:assistant, text))

      index ->
        transcript
        |> List.update_at(index, &Map.put(&1, :text, text))
        |> List.update_at(index, &Map.put(&1, :streaming, false))
    end
  end

  @doc "Appends an error entry to the transcript."
  @spec append_error(t, String.t()) :: t
  def append_error(transcript, text), do: append(transcript, entry(:error, text))

  @doc """
  Builds the bounded conversation-memory preamble prepended to a new message's
  objective so the transient reflect agent has context.

  Rules: `:error` entries are skipped; entries are paired into exchanges in
  order (each `:user` entry opens an exchange, the next `:assistant` entry
  completes it; unpaired user entries are included as `"User: ..."` only); only
  the last `:max_exchanges` exchanges are kept (default 8); individual texts
  are truncated to `:max_entry_chars` (default 600, appending `"…"`); the whole
  preamble is capped at `:max_chars` (default 4000). Returns `:empty` when
  there are no user/assistant entries.
  """
  @spec build_preamble(t, keyword()) :: {:ok, String.t()} | :empty
  def build_preamble(transcript, opts \\ []) do
    max_exchanges = Keyword.get(opts, :max_exchanges, 8)
    max_entry_chars = Keyword.get(opts, :max_entry_chars, 600)
    max_chars = Keyword.get(opts, :max_chars, 4000)

    blocks =
      (transcript || [])
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&(Map.get(&1, :role) == :error))
      |> build_blocks([])

    case blocks do
      [] ->
        :empty

      blocks ->
        body =
          blocks
          |> Enum.take(-max_exchanges)
          |> Enum.map(&format_block(&1, max_entry_chars))
          |> Enum.join("\n\n")

        preamble = "Previous conversation:\n" <> body <> "\n"
        {:ok, truncate(preamble, max_chars)}
    end
  end

  # Index of the last entry with `streaming: true`, or nil when none.
  defp last_streaming_index(transcript) do
    transcript
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{streaming: true}, index}, _acc -> index
      _, acc -> acc
    end)
  end

  # Pairs entries into ordered blocks: user/assistant exchanges, standalone
  # user entries, and standalone assistant entries.
  defp build_blocks([], acc), do: Enum.reverse(acc)

  defp build_blocks(
         [%{role: :user, text: user_text}, %{role: :assistant, text: assistant_text} | rest],
         acc
       ) do
    build_blocks(rest, [{:exchange, user_text, assistant_text} | acc])
  end

  defp build_blocks([%{role: :user, text: text} | rest], acc) do
    build_blocks(rest, [{:standalone, :user, text} | acc])
  end

  defp build_blocks([%{role: :assistant, text: text} | rest], acc) do
    build_blocks(rest, [{:standalone, :assistant, text} | acc])
  end

  defp build_blocks([_ | rest], acc), do: build_blocks(rest, acc)

  defp format_block({:exchange, user_text, assistant_text}, max_chars) do
    "User: " <>
      truncate(user_text, max_chars) <> "\nAssistant: " <> truncate(assistant_text, max_chars)
  end

  defp format_block({:standalone, :user, text}, max_chars),
    do: "User: " <> truncate(text, max_chars)

  defp format_block({:standalone, :assistant, text}, max_chars),
    do: "Assistant: " <> truncate(text, max_chars)

  defp truncate(text, max) do
    text = normalize_text(text)

    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(other), do: to_string(other)
end
