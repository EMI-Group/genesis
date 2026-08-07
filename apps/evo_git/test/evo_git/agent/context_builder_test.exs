defmodule EvoGit.Agent.ContextBuilderTest do
  @moduledoc """
  Pure-function unit tests for `EvoGit.Agent.ContextBuilder`'s turn-tagging and
  creation-time timestamp stamping helpers.

  Timestamps are Unix seconds (`System.system_time(:second)`). Idempotence
  assertions use deterministic pre-stamped values so they never race with `now`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextBuilder

  # Distinctive past Unix-seconds value — far from any real `now`.
  @old_ts 1_600_000_000

  defp message(role, overrides \\ []) do
    defaults = [role: role, content: [ReqLLM.Message.ContentPart.text("hello")]]
    struct!(ReqLLM.Message, Keyword.merge(defaults, overrides))
  end

  describe "tag_message_turn/2" do
    test "stamps metadata[:timestamp] (Unix seconds) alongside :turn" do
      before = System.system_time(:second)

      msg = ContextBuilder.tag_message_turn(message(:user), 3)
      after_ = System.system_time(:second)

      assert msg.metadata[:turn] == 3
      ts = msg.metadata[:timestamp]
      assert is_integer(ts), "expected integer timestamp, got: #{inspect(ts)}"
      assert ts >= before and ts <= after_
    end

    test "preserves an already-present timestamp (idempotent)" do
      msg = message(:user, metadata: %{timestamp: @old_ts, turn: 1})

      tagged = ContextBuilder.tag_message_turn(msg, 2)

      assert tagged.metadata[:timestamp] == @old_ts
      assert tagged.metadata[:turn] == 2
    end

    test "tolerates metadata: nil" do
      msg = ContextBuilder.tag_message_turn(message(:user, metadata: nil), 1)

      assert msg.metadata[:turn] == 1
      assert is_integer(msg.metadata[:timestamp])
    end
  end

  describe "tag_message_timestamp/1" do
    test "stamps a single message with a Unix-seconds timestamp" do
      before = System.system_time(:second)

      msg = ContextBuilder.tag_message_timestamp(message(:user))
      after_ = System.system_time(:second)

      ts = msg.metadata[:timestamp]
      assert is_integer(ts), "expected integer timestamp, got: #{inspect(ts)}"
      assert ts >= before and ts <= after_
    end

    test "is idempotent — keeps an already-present timestamp" do
      msg = message(:user, metadata: %{timestamp: @old_ts})

      assert ContextBuilder.tag_message_timestamp(msg).metadata[:timestamp] == @old_ts
    end

    test "tolerates metadata: nil" do
      msg = ContextBuilder.tag_message_timestamp(message(:user, metadata: nil))

      assert is_integer(msg.metadata[:timestamp])
    end
  end

  describe "tag_context_tail_with_turn/2" do
    test "stamps the last message only" do
      context = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts, turn: 1}),
          message(:assistant)
        ]
      }

      tagged = ContextBuilder.tag_context_tail_with_turn(context, 2)

      [m1, m2] = tagged.messages
      # Covered (tail) message: gets the new turn + a fresh timestamp.
      assert m2.metadata[:turn] == 2
      assert is_integer(m2.metadata[:timestamp])
      # Already-stamped message keeps its exact timestamp.
      assert m1.metadata[:timestamp] == @old_ts
      assert m1.metadata[:turn] == 1
    end

    test "an already-stamped tail keeps its exact timestamp" do
      context = %ReqLLM.Context{
        messages: [message(:assistant, metadata: %{timestamp: @old_ts, turn: 1})]
      }

      tagged = ContextBuilder.tag_context_tail_with_turn(context, 2)

      [msg] = tagged.messages
      assert msg.metadata[:timestamp] == @old_ts
      assert msg.metadata[:turn] == 2
    end

    test "handles an empty messages list" do
      context = %ReqLLM.Context{messages: []}

      assert ContextBuilder.tag_context_tail_with_turn(context, 1) == context
    end
  end

  describe "tag_context_messages_with_turn/2" do
    test "stamps every message with the turn and an integer timestamp" do
      context = %ReqLLM.Context{messages: [message(:user), message(:assistant), message(:user)]}

      tagged = ContextBuilder.tag_context_messages_with_turn(context, 0)

      for msg <- tagged.messages do
        assert msg.metadata[:turn] == 0
        assert is_integer(msg.metadata[:timestamp])
      end
    end

    test "already-stamped messages keep their exact timestamps" do
      context = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts}),
          message(:assistant, metadata: %{timestamp: @old_ts + 1})
        ]
      }

      tagged = ContextBuilder.tag_context_messages_with_turn(context, 4)

      [m1, m2] = tagged.messages
      assert m1.metadata[:timestamp] == @old_ts
      assert m2.metadata[:timestamp] == @old_ts + 1
      assert m1.metadata[:turn] == 4
      assert m2.metadata[:turn] == 4
    end

    test "handles an empty messages list" do
      context = %ReqLLM.Context{messages: []}

      assert ContextBuilder.tag_context_messages_with_turn(context, 1) == context
    end
  end
end
