defmodule EvoDash.ChatHistoryTest do
  use ExUnit.Case, async: false

  alias EvoDash.ChatHistory

  # The store is a single shared global GenServer + ETS table started by
  # EvoDash.Application. async: false (same convention as update_status_test /
  # directory_picker_test for shared global GenServers): with async: true the
  # per-test setup reset/0 would wipe the shared table while sibling tests in
  # this module are mid-assertion.
  setup do
    ChatHistory.reset()
    :ok
  end

  describe "supervision" do
    test "is started under EvoDash.Application with its named ETS table" do
      assert Process.whereis(EvoDash.ChatHistory) != nil
      assert :ets.whereis(:evo_dash_chat_history) != :undefined
    end
  end

  describe "new_chat/0" do
    test "creates a chat, makes it current, and returns a positive integer id" do
      id = ChatHistory.new_chat()

      assert is_integer(id) and id > 0
      assert ChatHistory.current_chat_id() == id
      assert ChatHistory.list_chats() == [id]
    end

    test "returns unique ids across calls" do
      ids = for _ <- 1..5, do: ChatHistory.new_chat()

      assert length(Enum.uniq(ids)) == 5
      # ids come from System.unique_integer([:positive]): unique but not
      # guaranteed strictly increasing — creation order is tracked separately
      # (an internal monotonic seq drives list_chats/0's newest-first order).
      assert ChatHistory.current_chat_id() == List.last(ids)
    end
  end

  describe "current_chat_id/0 and set_current_chat/1" do
    test "current_chat_id/0 is nil when no chat is current" do
      assert ChatHistory.current_chat_id() == nil
    end

    test "set_current_chat/1 switches the current pointer" do
      first = ChatHistory.new_chat()
      second = ChatHistory.new_chat()

      assert ChatHistory.current_chat_id() == second
      assert ChatHistory.set_current_chat(first) == :ok
      assert ChatHistory.current_chat_id() == first
    end

    test "set_current_chat/1 does not validate the chat id" do
      assert ChatHistory.set_current_chat(999_999) == :ok
      assert ChatHistory.current_chat_id() == 999_999
      assert ChatHistory.get_state(999_999) == nil
    end
  end

  describe "list_chats/0" do
    test "is empty when no chats exist" do
      assert ChatHistory.list_chats() == []
    end

    test "returns chat ids newest-first" do
      first = ChatHistory.new_chat()
      second = ChatHistory.new_chat()
      third = ChatHistory.new_chat()

      assert ChatHistory.list_chats() == [third, second, first]
    end
  end

  describe "put_state/2 and get_state/1" do
    test "round-trips opaque state for an existing chat" do
      id = ChatHistory.new_chat()

      assert ChatHistory.get_state(id) == nil
      assert ChatHistory.put_state(id, %{messages: ["hello"]}) == :ok
      assert ChatHistory.get_state(id) == %{messages: ["hello"]}
    end

    test "put_state/2 overwrites previous state" do
      id = ChatHistory.new_chat()
      ChatHistory.put_state(id, :first)
      ChatHistory.put_state(id, :second)

      assert ChatHistory.get_state(id) == :second
    end

    test "get_state/1 returns nil for an unknown chat" do
      assert ChatHistory.get_state(123_456) == nil
    end

    test "put_state/2 upserts an unknown chat id as a new (newest) chat" do
      existing = ChatHistory.new_chat()

      assert ChatHistory.put_state(42, "transcript") == :ok
      assert ChatHistory.list_chats() == [42, existing]
      assert ChatHistory.get_state(42) == "transcript"
    end
  end

  describe "delete_chat/1" do
    test "removes the chat and its state" do
      id = ChatHistory.new_chat()
      ChatHistory.put_state(id, %{messages: ["x"]})

      assert ChatHistory.delete_chat(id) == :ok
      assert ChatHistory.list_chats() == []
      assert ChatHistory.get_state(id) == nil
    end

    test "clears the current pointer when the deleted chat was current" do
      id = ChatHistory.new_chat()

      assert ChatHistory.delete_chat(id) == :ok
      assert ChatHistory.current_chat_id() == nil
    end

    test "keeps the current pointer when a non-current chat is deleted" do
      first = ChatHistory.new_chat()
      second = ChatHistory.new_chat()

      assert ChatHistory.delete_chat(first) == :ok
      assert ChatHistory.current_chat_id() == second
      assert ChatHistory.list_chats() == [second]
    end

    test "is a no-op for unknown chat ids" do
      assert ChatHistory.delete_chat(42) == :ok
      assert ChatHistory.current_chat_id() == nil
      assert ChatHistory.list_chats() == []
    end
  end

  describe "prune/1" do
    test "keeps only the newest max_chats chats" do
      ChatHistory.new_chat()
      second = ChatHistory.new_chat()
      third = ChatHistory.new_chat()

      assert ChatHistory.prune(2) == :ok
      assert ChatHistory.list_chats() == [third, second]
    end

    test "clears the current pointer when the current chat is pruned away" do
      first = ChatHistory.new_chat()
      newest = ChatHistory.new_chat()
      ChatHistory.set_current_chat(first)

      assert ChatHistory.prune(1) == :ok
      assert ChatHistory.list_chats() == [newest]
      assert ChatHistory.current_chat_id() == nil
    end

    test "keeps the current pointer when the current chat survives" do
      ChatHistory.new_chat()
      current = ChatHistory.new_chat()

      assert ChatHistory.prune(1) == :ok
      assert ChatHistory.current_chat_id() == current
      assert ChatHistory.list_chats() == [current]
    end

    test "with 0 clears all chats and the current pointer" do
      ChatHistory.new_chat()
      ChatHistory.new_chat()

      assert ChatHistory.prune(0) == :ok
      assert ChatHistory.list_chats() == []
      assert ChatHistory.current_chat_id() == nil
    end

    test "with a bound >= chat count is a no-op" do
      id = ChatHistory.new_chat()

      assert ChatHistory.prune(10) == :ok
      assert ChatHistory.list_chats() == [id]
    end

    test "ignores non-integer or negative bounds" do
      id = ChatHistory.new_chat()

      assert ChatHistory.prune(-1) == :ok
      assert ChatHistory.prune(:nope) == :ok
      assert ChatHistory.prune(nil) == :ok

      assert ChatHistory.list_chats() == [id]
      assert ChatHistory.current_chat_id() == id
    end
  end

  describe "reset/0" do
    test "clears all chats, states, and the current pointer" do
      ChatHistory.new_chat()
      ChatHistory.new_chat()

      assert ChatHistory.reset() == :ok
      assert ChatHistory.list_chats() == []
      assert ChatHistory.current_chat_id() == nil
    end
  end
end
