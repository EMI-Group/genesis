defmodule EvoGit.Agent.MessageMarker do
  @moduledoc """
  The ONE place that decides which conversation messages are USER-AUTHORED.

  A consumer reading a conversation (`EvoGit.Agent.Session.history/2`,
  `EvoGit.Agent.Stream.Snapshot.messages`) sees many `:user`-role messages that
  the human never wrote: turn-limit / grace warnings, background-job notices,
  compression checkpoints, the runtime-context refresh, the empty-response
  nudge and the subagent merge-conflict note all ride the SAME role. The marker
  is how a display layer tells real user turns from harness text.

  The marker is ONE metadata key, `:user_authored => true`, stamped on exactly
  two kinds of message:

    * the session's FIRST user turn — the `<context>`/`<objective>` message
      built by `EvoGit.Agent.ContextBuilder.build_initial_messages/4` (its
      `<objective>` block IS the task the user submitted). Stamped by
      `EvoGit.Agent.Session.Setup.build_initial_state/3` through
      `mark_first_user_authored/1`;
    * a message actually delivered by a USER SEND at runtime — the pending
      message transport drained by
      `EvoGit.Agent.Exchange.Pending.drain_and_inject_user_messages/2`
      (`EvoGit.AgentScheduler.send_session_message/3` /
      `send_user_message/2`, including every per-message send of an interactive
      assistant session), stamped by `mark_user_authored/1`. The one exception
      is the graceful-cancel save-work notice, which the scheduler injects into
      that same transport — it stays UNMARKED because no human wrote it.

  The rule is deliberately OPT-IN: an unmarked message is the default, so no
  synthetic builder (warnings, notices, checkpoints, refreshes, nudges, merge
  notes) can acquire the marker by accident.

  `%ReqLLM.Message{}.metadata` is INTERNAL bookkeeping — ReqLLM encodes a
  message from its role and content parts only, so this marker is never sent in
  a provider request body. It merges into whatever metadata already exists
  (`:turn`, `:timestamp`, `:checkpoint` are preserved), and both stamping and
  reading are TOTAL: a non-message term is answered unchanged / `false`, and a
  `nil` metadata map is treated as empty.
  """

  @typedoc "The metadata key carrying the marker."
  @type key :: :user_authored

  @key :user_authored

  @doc "The metadata key carrying the marker (`:user_authored`)."
  @spec key() :: key()
  def key, do: @key

  @doc """
  Stamps `:user_authored => true` on a message, merging into its existing
  metadata (never replacing `:turn` / `:timestamp` / `:checkpoint`).

  TOTAL: a term that is not a `%ReqLLM.Message{}` comes back UNCHANGED, and a
  message whose metadata is `nil` gets a fresh map.
  """
  @spec mark_user_authored(term()) :: term()
  def mark_user_authored(%ReqLLM.Message{} = message) do
    %{message | metadata: Map.put(metadata(message), @key, true)}
  end

  def mark_user_authored(other), do: other

  @doc """
  True only for a message carrying the marker.

  TOTAL: `nil`, another struct or map, and a non-map metadata value all answer
  `false`; never raises.
  """
  @spec user_authored?(term()) :: boolean()
  def user_authored?(%ReqLLM.Message{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, @key) == true
  end

  def user_authored?(_message), do: false

  @doc """
  Stamps the FIRST `:user`-role message of a context (the session's wrapped
  `<context>`/`<objective>` turn) and leaves every other message untouched —
  in particular the `:system` persona, which is never user-authored.

  TOTAL: a context with no `:user` message (or a non-context term) comes back
  unchanged.
  """
  @spec mark_first_user_authored(term()) :: term()
  def mark_first_user_authored(%ReqLLM.Context{messages: messages} = context)
      when is_list(messages) do
    case Enum.find_index(messages, &user_message?/1) do
      nil -> context
      index -> %{context | messages: List.update_at(messages, index, &mark_user_authored/1)}
    end
  end

  def mark_first_user_authored(context), do: context

  defp user_message?(%ReqLLM.Message{role: :user}), do: true
  defp user_message?(_message), do: false

  defp metadata(%ReqLLM.Message{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(%ReqLLM.Message{}), do: %{}
end
