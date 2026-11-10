defmodule EvoDashWeb.AgentsLive.OptimisticMessagesTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.AgentsLive.OptimisticMessages — the
  optimistic user-message display helpers for the Agents page chat history.

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, or DB setup is required.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.OptimisticMessages

  # A fixed UTC instant for the sent_at timestamps carried by optimistic entries.
  @sent_at ~U[2026-01-02 03:04:05Z]

  # An optimistic (not-yet-drained) entry whose content is `content`.
  defp entry(content), do: %{content: content, sent_at: @sent_at}

  # A real history entry of `type` whose data content is `content`.
  defp history_entry(type, content, turn \\ 1),
    do: %{turn: turn, type: type, data: %{content: content}}

  defp contents(messages, agent_id), do: Enum.map(messages[agent_id], & &1.content)

  describe "append/3" do
    test "appends at the END per agent, initializes absent keys and tolerates a nil map" do
      messages =
        %{}
        |> OptimisticMessages.append(1, "for-1")
        |> OptimisticMessages.append(1, "for-1-again")
        |> OptimisticMessages.append(2, "for-2")

      from_nil = OptimisticMessages.append(nil, 1, "hello")

      assert {contents(messages, 1), contents(messages, 2),
              Enum.map(from_nil[1], &{&1.content, match?(%DateTime{}, &1.sent_at)})} ==
               {["for-1", "for-1-again"], ["for-2"], [{"hello", true}]}
    end
  end

  describe "merge/2" do
    test "a real user entry (current or legacy USER) drops the matching optimistic send" do
      for type <- ["user", "USER"] do
        history = [history_entry(type, "hello")]

        assert OptimisticMessages.merge(history, [entry("hello")]) == history
      end
    end

    test "non-user entries never reflect; pending entries append AFTER history at the latest turn" do
      non_user = [
        history_entry("assistant", "hello", 4),
        history_entry("system", "hello", 7),
        history_entry("THOUGHT_CHUNK", "hello", 9)
      ]

      # An empty history renders the optimistic entry at turn 0; base indices are
      # unchanged because every optimistic entry is appended after the history.
      for {history, expected_turn} <- [{[], 0}, {non_user, 9}] do
        merged = OptimisticMessages.merge(history, [entry("hello")])

        assert Enum.split(merged, length(history)) ==
                 {history,
                  [
                    %{
                      turn: expected_turn,
                      timestamp: @sent_at,
                      type: "user",
                      data: %{content: "hello"},
                      optimistic: true
                    }
                  ]}
      end
    end

    test "multiple pending entries are preserved in order (all at the latest turn)" do
      merged = OptimisticMessages.merge([], [entry("first"), entry("second")])

      assert Enum.map(merged, &{&1.data.content, &1.turn, &1.optimistic}) ==
               [{"first", 0, true}, {"second", 0, true}]
    end

    test "identical repeated content: each real user entry consumes at most one optimistic send" do
      # {real user entries, optimistic sends, unconsumed pending copies}
      for {real, sends, left} <- [{2, 3, 1}, {1, 2, 1}] do
        history = for turn <- 1..real//1, do: history_entry("user", "same", turn)
        merged = OptimisticMessages.merge(history, List.duplicate(entry("same"), sends))

        assert {Enum.take(merged, real),
                for(e <- Enum.drop(merged, real), do: {e.data.content, e.optimistic})} ==
                 {history, List.duplicate({"same", true}, left)}
      end
    end

    test "nil or empty inputs produce an empty list" do
      assert {OptimisticMessages.merge([], nil), OptimisticMessages.merge([], [])} == {[], []}
    end
  end

  describe "latest_turn/1" do
    test "returns the maximum turn, treating empty history and nil turns as 0" do
      for {history, expected} <- [
            {[], 0},
            {[
               history_entry("user", "a", 1),
               history_entry("assistant", "b", 5),
               history_entry("system", "c", 3)
             ], 5},
            {[
               history_entry("user", "a", nil),
               history_entry("assistant", "b", 2),
               history_entry("user", "c", 4)
             ], 4}
          ] do
        assert OptimisticMessages.latest_turn(history) == expected
      end
    end
  end

  describe "prune/4" do
    test "classifies each entry against the known/unknown pending queue and the user history" do
      rows = [
        # Queue UNKNOWN: a history-reflected entry is dropped, an unreflected one kept.
        {"unknown queue", [entry("reflected"), entry("still-pending")],
         [history_entry("user", "reflected")], nil, [entry("still-pending")]},
        # A still-queued (KNOWN) message is KEPT even though the history reflects it.
        {"known & still queued", [entry("hello")], [history_entry("user", "hello")], ["hello"],
         [entry("hello")]},
        # A KNOWN (empty) queue alone proves the drain — compression may have folded
        # the real user entry into a summary, so the history no longer reflects it.
        {"known & drained", [entry("drained")], [history_entry("assistant", "summary")], [], []},
        # Queue UNKNOWN: non-user history entries never reflect, so the entry stays.
        {"non-user history", [entry("hello")],
         [history_entry("assistant", "hello"), history_entry("system", "hello", 2)], nil,
         [entry("hello")]},
        # The legacy uppercase USER role reflects like the current lowercase one.
        {"legacy USER", [entry("hello")], [history_entry("USER", "hello")], nil, []},
        # The canonical multimodal queue shape holds its text, atom- or string-keyed.
        {"atom map queue", [entry("hello")], [history_entry("user", "hello")], [%{text: "hello"}],
         [entry("hello")]},
        {"string map queue", [entry("hello")], [history_entry("user", "hello")],
         [%{"text" => "hello"}], [entry("hello")]},
        # Queue entries carrying no content are ignored, so nothing vouches for it.
        {"content-less queue", [entry("hello")], [], [:garbage, %{}, %{other: "hello"}], []},
        # First-match consumption: one real user entry reflects one identical send.
        {"first match", [entry("same"), entry("same")], [history_entry("user", "same")], nil,
         [entry("same")]},
        # KNOWN and drained: both identical sends go.
        {"known twice drained", [entry("same"), entry("same")], [history_entry("user", "same")],
         [], []},
        # KNOWN and still holding: neither entry consumes the queue slot.
        {"known twice held", [entry("same"), entry("same")], [history_entry("user", "same")],
         ["same"], [entry("same"), entry("same")]}
      ]

      for {label, entries, history, queue, expected} <- rows do
        assert OptimisticMessages.prune(%{1 => entries}, 1, history, queue) ==
                 if(expected == [], do: %{}, else: %{1 => expected}),
               label
      end
    end

    test "the agent_id key is deleted when its kept list becomes empty; other keys are untouched" do
      other = [entry("other-agent")]

      assert OptimisticMessages.prune(%{1 => [entry("drained")], 2 => other}, 1, [], []) ==
               %{2 => other}
    end

    test "is total on garbage inputs" do
      content_less = %{sent_at: @sent_at}

      rows = [
        # nil map -> empty result.
        {nil, nil, nil, %{}},
        # Absent key -> the map is returned with no key added.
        {%{2 => []}, nil, nil, %{2 => []}},
        # Non-list stored value -> no entries, so the key is deleted from the output.
        {%{1 => "garbage"}, [], nil, %{}},
        # A non-list queue is UNKNOWN and a non-list history is empty: the
        # content-less entry cannot be proven drained, so it is kept verbatim.
        {%{1 => [content_less]}, nil, "garbage", %{1 => [content_less]}},
        # An entry without :content yields nil, which a KNOWN queue cannot hold, so
        # it is treated as drained.
        {%{1 => [content_less]}, [], [], %{}}
      ]

      for {messages, history, queue, expected} <- rows do
        assert OptimisticMessages.prune(messages, 1, history, queue) == expected
      end
    end
  end
end
