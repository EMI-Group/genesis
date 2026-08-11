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

  describe "append/3" do
    test "absent key initializes a single-entry list" do
      messages = OptimisticMessages.append(%{}, 1, "hello")

      assert [entry] = messages[1]
      assert entry.content == "hello"
      assert %DateTime{} = entry.sent_at
    end

    test "existing entries are preserved and the new entry goes at the END" do
      messages = %{1 => [%{content: "first", sent_at: @sent_at}]}

      assert messages
             |> OptimisticMessages.append(1, "second")
             |> Map.fetch!(1)
             |> Enum.map(& &1.content) ==
               ["first", "second"]
    end

    test "nil map is treated as empty" do
      messages = OptimisticMessages.append(nil, 1, "hello")

      assert [entry] = messages[1]
      assert entry.content == "hello"
    end

    test "per-agent entries are independent" do
      messages =
        %{}
        |> OptimisticMessages.append(1, "for-1")
        |> OptimisticMessages.append(2, "for-2")
        |> OptimisticMessages.append(1, "for-1-again")

      assert messages[1] |> Enum.map(& &1.content) == ["for-1", "for-1-again"]
      assert messages[2] |> Enum.map(& &1.content) == ["for-2"]
    end
  end

  describe "merge/2" do
    test "optimistic entry is dropped once its content appears as a real user entry" do
      history = [%{turn: 1, type: "user", data: %{content: "hello"}}]
      optimistic = [%{content: "hello", sent_at: @sent_at}]

      assert OptimisticMessages.merge(history, optimistic) == history
    end

    test "legacy uppercase USER history entry reflects an optimistic entry" do
      history = [%{turn: 1, type: "USER", data: %{content: "hello"}}]
      optimistic = [%{content: "hello", sent_at: @sent_at}]

      assert OptimisticMessages.merge(history, optimistic) == history
    end

    test "non-user entries never reflect (drop) optimistic entries" do
      history = [
        %{turn: 1, type: "assistant", data: %{content: "hello"}},
        %{turn: 1, type: "system", data: %{content: "hello"}},
        %{turn: 1, type: "THOUGHT_CHUNK", data: %{content: "hello"}}
      ]

      optimistic = [%{content: "hello", sent_at: @sent_at}]

      merged = OptimisticMessages.merge(history, optimistic)

      # Base history unchanged; the optimistic copy is still appended at the end.
      assert Enum.take(merged, 3) == history
      assert [pending] = Enum.drop(merged, 3)
      assert pending.optimistic == true
      assert pending.data.content == "hello"
    end

    test "multiple pending entries are preserved until drained (turn 0)" do
      optimistic = [
        %{content: "first", sent_at: @sent_at},
        %{content: "second", sent_at: @sent_at}
      ]

      merged = OptimisticMessages.merge([], optimistic)

      assert merged |> Enum.map(& &1.data.content) == ["first", "second"]
      assert merged |> Enum.map(& &1.turn) == [0, 0]
      assert Enum.all?(merged, & &1.optimistic)
    end

    test "identical repeated content: each real user entry consumes at most one optimistic send" do
      history = [
        %{turn: 1, type: "user", data: %{content: "same"}},
        %{turn: 2, type: "user", data: %{content: "same"}}
      ]

      optimistic = [
        %{content: "same", sent_at: @sent_at},
        %{content: "same", sent_at: @sent_at},
        %{content: "same", sent_at: @sent_at}
      ]

      merged = OptimisticMessages.merge(history, optimistic)

      # 2 real entries + 1 unconsumed pending copy (first-match consumption).
      assert length(merged) == 3
      assert Enum.take(merged, 2) == history
      assert [pending] = Enum.drop(merged, 2)
      assert pending.optimistic == true
    end

    test "a single real user entry reflects only the first matching optimistic send" do
      history = [%{turn: 1, type: "user", data: %{content: "same"}}]

      optimistic = [
        %{content: "same", sent_at: @sent_at},
        %{content: "same", sent_at: @sent_at}
      ]

      merged = OptimisticMessages.merge(history, optimistic)

      assert length(merged) == 2
      assert Enum.take(merged, 1) == history
      assert [pending] = Enum.drop(merged, 1)
      assert pending.optimistic == true
    end

    test "optimistic entries are appended AFTER real history; base indices unchanged" do
      history = [
        %{turn: 1, type: "user", data: %{content: "real-1"}},
        %{turn: 2, type: "assistant", data: %{content: "reply"}}
      ]

      optimistic = [
        # Dropped: already reflected by the real "real-1" user entry.
        %{content: "real-1", sent_at: @sent_at},
        # Kept: nothing real with this content yet.
        %{content: "pending-1", sent_at: @sent_at}
      ]

      merged = OptimisticMessages.merge(history, optimistic)

      assert Enum.take(merged, 2) == history
      assert [pending] = Enum.drop(merged, 2)
      assert pending.data.content == "pending-1"
      assert pending.optimistic == true
    end

    test "optimistic entries carry the latest history turn and their sent_at timestamp" do
      history = [
        %{turn: 4, type: "assistant", data: %{content: "reply"}},
        %{turn: 7, type: "assistant", data: %{content: "another reply"}}
      ]

      optimistic = [%{content: "hello", sent_at: @sent_at}]

      assert [entry] = Enum.drop(OptimisticMessages.merge(history, optimistic), 2)
      assert entry.turn == 7
      assert entry.timestamp == @sent_at
      assert entry.type == "user"
      assert entry.data == %{content: "hello"}
      assert entry.optimistic == true
    end

    test "nil or empty inputs produce an empty list" do
      assert OptimisticMessages.merge([], nil) == []
      assert OptimisticMessages.merge([], []) == []
    end
  end

  describe "latest_turn/1" do
    test "returns 0 for empty history" do
      assert OptimisticMessages.latest_turn([]) == 0
    end

    test "returns the maximum turn" do
      history = [
        %{turn: 1, type: "user", data: %{content: "a"}},
        %{turn: 5, type: "assistant", data: %{content: "b"}},
        %{turn: 3, type: "system", data: %{content: "c"}}
      ]

      assert OptimisticMessages.latest_turn(history) == 5
    end

    test "nil-tolerant: entries with a nil turn count as 0" do
      history = [
        %{turn: nil, type: "user", data: %{content: "a"}},
        %{turn: 2, type: "assistant", data: %{content: "b"}},
        %{turn: 4, type: "user", data: %{content: "c"}}
      ]

      assert OptimisticMessages.latest_turn(history) == 4
    end
  end
end
