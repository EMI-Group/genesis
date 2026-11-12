defmodule EvoDashWeb.HomeLive.DisplayMessages do
  @moduledoc """
  The chat-transcript projection rule for the Home chat page: which history
  messages the user actually sees, in what order, and with what text.

  The payload of `EvoDash.NodeContext.get_agent_history/2` is the AGENT's LLM
  context, not a chat log: it starts with the role's system prompt, then the
  harness's first user message (`<context>…</context>` plus
  `<objective>…</objective>`), and it keeps every runtime injection the agent
  loop appends — the turn-budget `[NOTICE]`/`[WARNING]`/`[URGENT]` notices, the
  runtime-context refresh after a compression, compression checkpoints, the
  graceful-cancel save-work message, and tool results. None of that was
  written by the user, so none of it belongs in a chat bubble.

  The transcript is therefore an ORDERED projection of the history:

    * `:system` and `:tool` messages never become bubbles — the live tool rows
      come from stream deltas, and the thought-process panel keeps the raw
      detail (`EvoDashWeb.HomeLive.Messages.to_entries/1`);
    * an `:assistant` message becomes an `:assistant` bubble carrying its
      response text (`EvoDashWeb.HomeLive.Messages.message_text/1`, thinking
      parts already excluded); empty / thinking-only messages produce nothing;
    * a `:user` message becomes a `:user` bubble ONLY when it is
      user-authored (see `user_authored?/1`).

  Bubbles keep chronological order (`user1 → assistant1 → user2 → …`), so the
  transcript reads exactly like the conversation the user had.

  ## The user-authored discriminator

  The authority is the core's marker `metadata[:user_authored]` (atom or
  string key; only a real boolean counts): when it is present it decides —
  `true` keeps the turn, `false` drops it.

  When the marker is ABSENT (older core payloads) a shape heuristic decides:

    * the turn-0 wrapped first message contributes ONLY its
      `<objective>…</objective>` body (a blank body contributes nothing);
    * a body that is only a `<context>…</context>` block contributes nothing;
    * `metadata[:checkpoint] == true` (stamped by
      `EvoGit.Agent.Compression.Checkpoint`) contributes nothing;
    * a runtime-context refresh contributes nothing (its text starts with the
      pinned notice below, mirrored from
      `EvoGit.Agent.ContextBuilder`'s `@context_refresh_notice`);
    * `[NOTICE] ` / `[WARNING] ` / `[URGENT] ` texts contribute nothing
      (`EvoGit.Agent.TurnWarning` and `EvoGit.Agent.BackgroundJobNotice`);
    * the turn-budget grace warning (`You have exceeded your turn budget`,
      `EvoGit.Agent.Exchange.Grace.recovery_warning_message/2`) contributes
      nothing;
    * the graceful-cancel save-work message (`The task is being cancelled by
      the user.`, `EvoGit.AgentScheduler`'s `@cancel_message`) contributes
      nothing;
    * anything else is a user turn and is shown (trimmed).

  The prefixes are pinned HERE, not read from the core, so the dashboard
  projection stays self-contained and total; the marker is the durable
  discriminator that makes the heuristic a fallback.

  Every function is TOTAL: nil/non-list input, plain maps with string or atom
  keys, nil metadata, missing keys and non-binary content all degrade to "no
  bubble" instead of raising — the payload crosses an async/RPC boundary whose
  shape is owned by the `:evo_git` core.
  """

  alias EvoDashWeb.HomeLive.Messages

  # Mirrors `EvoGit.Agent.ContextBuilder`'s `@context_refresh_notice` (only the
  # leading sentence is needed: it is the whole message's prefix).
  @refresh_prefix "This is an automatically generated runtime-context refresh."

  # Runtime-injection prefixes that are never user turns.
  @notice_prefixes ["[NOTICE] ", "[WARNING] ", "[URGENT] "]

  @notice_texts [
    # `EvoGit.Agent.Exchange.Grace.recovery_warning_message/2`
    "You have exceeded your turn budget",
    # `EvoGit.AgentScheduler` `@cancel_message`
    "The task is being cancelled by the user."
  ]

  @context_open "<context>"
  @objective_open "<objective>"
  @objective_close "</objective>"

  @doc """
  Projects a history payload into the ordered display bubbles, oldest first:
  `[{:user | :assistant, text}]`. Total — non-list input yields `[]`, and each
  message that produces no bubble (system/tool/notice/checkpoint/empty) is
  dropped. Never raises.
  """
  @spec bubbles(term()) :: [{:user | :assistant, String.t()}]
  def bubbles(messages) when is_list(messages) do
    Enum.flat_map(messages, fn message ->
      case bubble(message) do
        nil -> []
        pair -> [pair]
      end
    end)
  end

  def bubbles(_messages), do: []

  @doc """
  Projects ONE history message into its display bubble, or `nil` when it must
  not be shown. Total — any non-map, an unknown role, empty/blank text and
  every runtime injection yield `nil`. Never raises.
  """
  @spec bubble(term()) :: nil | {:user | :assistant, String.t()}
  def bubble(message) when is_map(message) do
    case role(message) do
      :assistant -> assistant_bubble(message)
      :user -> user_bubble(message)
      _other -> nil
    end
  end

  def bubble(_message), do: nil

  @doc """
  Whether a message is a USER-AUTHORED turn: `true`, `false`, or `:unknown`
  when the payload carries no usable `metadata[:user_authored]` marker (atom or
  string key, boolean values only). Total.
  """
  @spec user_authored?(term()) :: boolean() | :unknown
  def user_authored?(message) when is_map(message) do
    marker(metadata(message))
  end

  def user_authored?(_message), do: :unknown

  # --- bubbles ---

  defp assistant_bubble(message) do
    case text_of(message) do
      "" -> nil
      text -> {:assistant, text}
    end
  end

  defp user_bubble(message) do
    text = text_of(message)

    cond do
      text == "" -> nil
      user_authored?(message) == true -> user_pair(authored_text(text))
      user_authored?(message) == false -> nil
      checkpoint?(message) -> nil
      injection?(text) -> nil
      true -> user_pair(authored_text(text))
    end
  end

  defp user_pair(nil), do: nil
  defp user_pair(text), do: {:user, text}

  # The user-visible part of an authored turn: the wrapped first message
  # contributes only its `<objective>` body; a context-only body contributes
  # nothing; anything else is shown as typed.
  defp authored_text(text) do
    case objective_body(text) do
      nil -> if context_only?(text), do: nil, else: blank_to_nil(text)
      body -> blank_to_nil(body)
    end
  end

  # Extracts the `<objective>…</objective>` body, or nil when the text carries
  # no complete objective block.
  defp objective_body(text) when is_binary(text) do
    with [_before, rest] <- String.split(text, @objective_open, parts: 2),
         [body, _after] <- String.split(rest, @objective_close, parts: 2) do
      String.trim(body)
    else
      _other -> nil
    end
  end

  defp objective_body(_text), do: nil

  defp context_only?(text) when is_binary(text) do
    String.starts_with?(text, @context_open)
  end

  defp context_only?(_text), do: false

  # Runtime injections that ride `:user` messages but were produced by the
  # harness, never by the user.
  defp injection?(text) when is_binary(text) do
    String.starts_with?(text, @refresh_prefix) or
      Enum.any?(@notice_prefixes, &String.starts_with?(text, &1)) or
      Enum.any?(@notice_texts, &String.starts_with?(text, &1))
  end

  defp injection?(_text), do: false

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_text), do: nil

  # --- message shape accessors (total) ---

  defp text_of(message) do
    message |> Messages.message_text() |> String.trim()
  end

  defp role(message) do
    message
    |> fetch_key(:role)
    |> role_atom()
  end

  defp role_atom({:ok, role}) when is_atom(role) and role not in [nil, true, false], do: role
  defp role_atom({:ok, role}) when is_binary(role), do: role_atom_of_string(role)
  defp role_atom(_role), do: :other

  defp role_atom_of_string("user"), do: :user
  defp role_atom_of_string("assistant"), do: :assistant
  defp role_atom_of_string("system"), do: :system
  defp role_atom_of_string("tool"), do: :tool
  defp role_atom_of_string(_role), do: :other

  defp checkpoint?(message) do
    case fetch_key(metadata(message), :checkpoint) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp marker(metadata) do
    case fetch_key(metadata, :user_authored) do
      {:ok, value} when is_boolean(value) -> value
      _other -> :unknown
    end
  end

  defp metadata(message) do
    case Map.get(message, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  # Atom key first, then the string spelling (both shapes cross the RPC
  # boundary in practice).
  defp fetch_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error when is_atom(key) ->
        Map.fetch(map, Atom.to_string(key))

      :error ->
        :error
    end
  end

  defp fetch_key(_map, _key), do: :error
end
