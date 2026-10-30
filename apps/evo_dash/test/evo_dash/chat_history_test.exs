defmodule EvoDash.ChatHistoryTest do
  use ExUnit.Case, async: true

  alias EvoDash.ChatHistory

  # ChatHistory is ONE process-wide GenServer + named ETS table started by
  # EvoDash.Application, so these exact-global assertions are safe only while no
  # concurrently running module writes that table.
  # setup's reset/0 is a WHOLE-TABLE wipe, confined to this module's own tests
  # (tests inside one module always run serially, so a sibling's reset/0 can
  # never race an assertion).
  # The sole writer is a connected `/help` mount (HomeLive calls new_chat/0,
  # put_state/2 and prune/1), and EVERY module in this tree that mounts `/help`
  # is `async: false`: home_live_test, page_controller_test, and the `/help` case
  # in ProjectsLiveSyncTest — ExUnit drains ALL async modules before starting
  # any sync one, so none of them can write the table while these assertions run.
  # A FUTURE `/help` mount added to an `async: true` module breaks that contract:
  # it must live in a sync module instead, or this module must go sync.
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
    test "creates a chat, makes it current, and returns unique positive ids" do
      id = ChatHistory.new_chat()

      assert is_integer(id) and id > 0
      assert ChatHistory.current_chat_id() == id
      assert ChatHistory.list_chats() == [id]

      ids = for _ <- 1..5, do: ChatHistory.new_chat()

      assert length(Enum.uniq(ids)) == 5
      # ids come from System.unique_integer([:positive]): unique but not
      # guaranteed strictly increasing — creation order is tracked separately
      # (an internal monotonic seq drives list_chats/0's newest-first order).
      assert ChatHistory.current_chat_id() == List.last(ids)
      # list_chats/0 is newest-first.
      assert Enum.take(ChatHistory.list_chats(), 5) == Enum.reverse(ids)
    end
  end

  describe "current_chat_id/0 and set_current_chat/1" do
    test "the current pointer starts nil, switches freely, and does not validate ids" do
      assert ChatHistory.current_chat_id() == nil

      first = ChatHistory.new_chat()
      second = ChatHistory.new_chat()

      assert ChatHistory.current_chat_id() == second
      assert ChatHistory.set_current_chat(first) == :ok
      assert ChatHistory.current_chat_id() == first

      # An unknown id is accepted verbatim (no lookup, no error).
      assert ChatHistory.set_current_chat(999_999) == :ok
      assert ChatHistory.current_chat_id() == 999_999
      assert ChatHistory.get_state(999_999) == nil
    end
  end

  describe "list_chats/0" do
    test "is empty with no chats and newest-first otherwise" do
      assert ChatHistory.list_chats() == []

      first = ChatHistory.new_chat()
      second = ChatHistory.new_chat()
      third = ChatHistory.new_chat()

      assert ChatHistory.list_chats() == [third, second, first]
    end
  end

  describe "put_state/2 and get_state/1" do
    test "round-trips opaque state, overwrites it, and upserts unknown chats as newest" do
      id = ChatHistory.new_chat()

      assert ChatHistory.get_state(id) == nil
      assert ChatHistory.put_state(id, %{messages: ["hello"]}) == :ok
      assert ChatHistory.get_state(id) == %{messages: ["hello"]}

      ChatHistory.put_state(id, :first)
      ChatHistory.put_state(id, :second)
      assert ChatHistory.get_state(id) == :second

      assert ChatHistory.get_state(123_456) == nil

      assert ChatHistory.put_state(42, "transcript") == :ok
      assert ChatHistory.list_chats() == [42, id]
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

    test "clears the current pointer only when the deleted chat was current" do
      first = ChatHistory.new_chat()

      assert ChatHistory.delete_chat(first) == :ok
      assert ChatHistory.current_chat_id() == nil

      second = ChatHistory.new_chat()
      third = ChatHistory.new_chat()

      assert ChatHistory.delete_chat(second) == :ok
      assert ChatHistory.current_chat_id() == third
      assert ChatHistory.list_chats() == [third]
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

    test "clears the current pointer only when the current chat is pruned away" do
      first = ChatHistory.new_chat()
      newest = ChatHistory.new_chat()
      ChatHistory.set_current_chat(first)

      assert ChatHistory.prune(1) == :ok
      assert ChatHistory.list_chats() == [newest]
      assert ChatHistory.current_chat_id() == nil

      ChatHistory.set_current_chat(newest)
      assert ChatHistory.prune(1) == :ok
      assert ChatHistory.current_chat_id() == newest
      assert ChatHistory.list_chats() == [newest]
    end

    test "with 0 clears everything; a bound >= the chat count is a no-op" do
      ChatHistory.new_chat()
      ChatHistory.new_chat()

      assert ChatHistory.prune(0) == :ok
      assert ChatHistory.list_chats() == []
      assert ChatHistory.current_chat_id() == nil

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
      id = ChatHistory.new_chat()
      ChatHistory.put_state(id, :state)
      ChatHistory.new_chat()

      assert ChatHistory.reset() == :ok
      assert ChatHistory.list_chats() == []
      assert ChatHistory.current_chat_id() == nil
      assert ChatHistory.get_state(id) == nil
    end
  end
end
