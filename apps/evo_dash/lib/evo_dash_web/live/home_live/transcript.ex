defmodule EvoDashWeb.HomeLive.Transcript do
  @moduledoc """
  Pure chat-transcript model for the Home chat LiveView.

  A transcript is a list of entries (oldest first), where each entry is a plain
  map `%{id: String.t(), role: :user | :assistant | :error, text: String.t(),
  streaming: boolean()}`. An entry MAY additionally carry `:reasoning` — the
  list of that turn's OWN reasoning entries (opaque terms, normally the maps
  `EvoDashWeb.HomeLive.Messages.to_entries/1` produces). The key is optional so
  legacy/garbage entries keep their exact shape; it is present whenever the
  input carried one and whenever `put_reasoning/3` set a non-empty list.

  All functions are total: `normalize/1` coerces arbitrary (persisted) entry
  data into the current entry shape before it is consumed, so malformed
  entries degrade instead of crashing.

  Caps (applied on every produce and normalize path):

    * at most 200 transcript entries — the NEWEST are kept;
    * at most 8_000 graphemes of `text` per entry (grapheme-safe);
    * at most 40 reasoning entries per turn (oldest dropped).
  """

  @max_entries 200
  @max_entry_chars 8_000
  @max_reasoning_entries 40

  @type role :: :user | :assistant | :error

  @type entry :: %{
          required(:id) => String.t(),
          required(:role) => role,
          required(:text) => String.t(),
          required(:streaming) => boolean(),
          optional(:reasoning) => [term()]
        }

  @type t :: [entry]

  @doc "Returns a new, empty transcript."
  @spec new() :: t
  def new, do: []

  @doc """
  Normalizes arbitrary transcript data into the current entry shape
  `%{id, role, text, streaming}` (plus `:reasoning` when the input carried
  one). Used to restore persisted chat state
  (`EvoDashWeb.HomeLive.ChatState.restore/1`): stored entries may carry
  non-binary ids, missing keys, or unknown roles.

  Total: non-lists → `[]`; non-map entries are dropped; ids are coerced to
  binaries (`nil`/malformed ids get a fresh unique id); roles are whitelisted
  to `:user | :assistant | :error` (unknown → `:assistant`, keeping the entry
  visible left-aligned); text is coerced to a binary and capped at 8_000
  graphemes; `streaming` is boolean-ized (`true` only for exactly `true`);
  `:reasoning` is capped at 40 entries. Only the NEWEST 200 entries are kept.
  """
  @spec normalize(term()) :: t
  def normalize(entries) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_entry/1)
    |> cap_entries()
  end

  def normalize(_entries), do: []

  @doc "Appends an entry to the end of the transcript (capped, newest kept)."
  @spec append(t, entry) :: t
  def append(transcript, entry) when is_list(transcript) do
    cap_entries(transcript ++ [normalize_entry(entry)])
  end

  def append(_transcript, entry), do: [normalize_entry(entry)]

  @doc """
  Builds an entry with a unique string id.

  Options: `:streaming` (default `false`) and `:reasoning` (default `[]`).
  The text is capped at 8_000 graphemes.
  """
  @spec entry(role, String.t(), keyword()) :: entry
  def entry(role, text, opts \\ []) do
    %{
      id: System.unique_integer([:positive]) |> Integer.to_string(),
      role: role,
      text: truncate_entry_text(text),
      streaming: Keyword.get(opts, :streaming, false) == true,
      reasoning: normalize_reasoning(Keyword.get(opts, :reasoning))
    }
  end

  @doc """
  Updates the text of the last streaming entry, or appends a new streaming
  assistant entry when none is streaming. Idempotent — used when a refetched
  agent history replaces the in-progress bubble.
  """
  @spec put_streaming_text(t, String.t()) :: t
  def put_streaming_text(transcript, text) do
    text = truncate_entry_text(text)

    case last_streaming_index(transcript) do
      nil ->
        append(transcript, entry(:assistant, text, streaming: true))

      index ->
        transcript
        |> List.update_at(index, &Map.put(&1, :text, text))
        |> cap_entries()
    end
  end

  @doc """
  Finalizes the last streaming entry (sets `streaming: false` and replaces its
  text), or appends a new non-streaming assistant entry when none is streaming.
  Used when the final result arrives.
  """
  @spec finalize_assistant(t, String.t()) :: t
  def finalize_assistant(transcript, text) do
    text = truncate_entry_text(text)

    case last_streaming_index(transcript) do
      nil ->
        append(transcript, entry(:assistant, text))

      index ->
        transcript
        |> List.update_at(index, &Map.put(&1, :text, text))
        |> List.update_at(index, &Map.put(&1, :streaming, false))
        |> cap_entries()
    end
  end

  @doc """
  Sets (replaces) the `:reasoning` list of the entry with the given id.

  Used to attach a turn's own reasoning instead of one global "last turn"
  buffer. Total: a non-list transcript normalizes to `[]`-based normalization,
  an unknown/unusable id leaves the transcript unchanged, and a non-list
  reasoning term becomes `[]`. The list is capped at 40 entries (oldest
  dropped) and stored opaquely.
  """
  @spec put_reasoning(t, term(), term()) :: t
  def put_reasoning(transcript, id, reasoning) do
    entries = normalize(transcript)
    target_id = entry_id(id)
    reasoning = normalize_reasoning(reasoning)

    if target_id != nil and Enum.any?(entries, &(&1.id == target_id)) do
      Enum.map(entries, fn entry ->
        if entry.id == target_id, do: Map.put(entry, :reasoning, reasoning), else: entry
      end)
    else
      entries
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
      transcript
      |> normalize()
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

  defp normalize_entry(entry) do
    base = %{
      id: normalize_id(Map.get(entry, :id)),
      role: normalize_role(Map.get(entry, :role)),
      text: truncate_entry_text(normalize_text(Map.get(entry, :text))),
      streaming: Map.get(entry, :streaming) == true
    }

    reasoning = normalize_reasoning(reasoning_value(entry))

    # CRITICAL: a stored entry without a reasoning key keeps its exact shape —
    # an absent `:reasoning` must never be invented here.
    if reasoning_key?(entry) or reasoning != [] do
      Map.put(base, :reasoning, reasoning)
    else
      base
    end
  end

  defp reasoning_key?(entry) do
    Map.has_key?(entry, :reasoning) or Map.has_key?(entry, "reasoning")
  end

  defp reasoning_value(entry) do
    case Map.fetch(entry, :reasoning) do
      {:ok, value} -> value
      :error -> Map.get(entry, "reasoning")
    end
  end

  defp normalize_reasoning(reasoning) when is_list(reasoning),
    do: Enum.take(reasoning, -@max_reasoning_entries)

  defp normalize_reasoning(_reasoning), do: []

  # Keeps the NEWEST entries (the tail of the oldest-first list).
  defp cap_entries(entries) when is_list(entries), do: Enum.take(entries, -@max_entries)
  defp cap_entries(entries), do: entries

  defp normalize_role(:user), do: :user
  defp normalize_role(:assistant), do: :assistant
  defp normalize_role(:error), do: :error
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("error"), do: :error
  defp normalize_role(_role), do: :assistant

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(_id), do: System.unique_integer([:positive]) |> Integer.to_string()

  # Entry LOOKUP id — never invents an id (unlike normalize_id/1).
  defp entry_id(id) when is_binary(id) and id != "", do: id
  defp entry_id(id) when is_integer(id), do: Integer.to_string(id)
  defp entry_id(_id), do: nil

  # Index of the last entry with `streaming: true`, or nil when none.
  defp last_streaming_index(transcript) when is_list(transcript) do
    transcript
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{streaming: true}, index}, _acc -> index
      _, acc -> acc
    end)
  end

  defp last_streaming_index(_transcript), do: nil

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

  # Per-entry text cap: grapheme-safe truncation, no ellipsis (a truncated
  # bubble must not grow a marker the model never produced).
  defp truncate_entry_text(text) when is_binary(text) do
    cond do
      # Every grapheme is at least one byte, so a byte-size short cut is safe.
      byte_size(text) <= @max_entry_chars -> text
      String.valid?(text) -> String.slice(text, 0, @max_entry_chars)
      true -> binary_part(text, 0, @max_entry_chars)
    end
  end

  defp truncate_entry_text(text), do: truncate_entry_text(normalize_text(text))

  defp normalize_text(nil), do: ""
  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(text) when is_atom(text) or is_number(text), do: to_string(text)
  defp normalize_text(_text), do: ""
end
