defmodule EvoGit.AgentScheduler.PendingUserMessagesTest do
  @moduledoc """
  Tests for the shape-tolerance of the pending-user-message queue
  (`EvoGit.AgentScheduler.Store.append_pending_user_message/2` +
  `drain_pending_user_messages/1`).

  The queue must tolerate BOTH a legacy plain `String.t()` AND a
  `%{text:, attachments:}` map (multimodal injected user message):

    * a legacy binary rides through VERBATIM — byte-identical end-to-end, i.e.
      exactly the pre-change behavior (asserted explicitly below);
    * a map is canonicalized through `EvoGit.Attachments.message/1` before it is
      stored, and a malformed map raises the descriptive `ArgumentError`.

  Uses `async: false` because the tests manipulate the global named
  `:evogit_agent_state` ETS table and subscribe to the shared `"agents"` PubSub
  topic of the global `EvoGit.PubSub`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Attachments
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias ReqLLM.Message.ContentPart

  # --- Fixtures -------------------------------------------------------------

  defp agent_state(overrides \\ []) do
    defaults = [
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    ]

    struct!(AgentState, Keyword.merge(defaults, overrides))
  end

  # A small VALID image attachment (PNG magic bytes, base64-encoded — never raw
  # binary, per the pinned base64-only wire contract).
  defp image_attachment do
    %{
      "type" => "image",
      "name" => "pixel.png",
      "media_type" => "image/png",
      "data" => Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)
    }
  end

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  defp clear_ets do
    if :ets.whereis(:evogit_agent_state) != :undefined,
      do: :ets.delete_all_objects(:evogit_agent_state)

    if :ets.whereis(:evogit_sched_meta) != :undefined,
      do: :ets.delete_all_objects(:evogit_sched_meta)
  end

  defp drain_mailbox do
    receive do
      _msg -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp stored_messages(agent_id) do
    {:ok, state} = Store.get_agent_state(agent_id)
    state.pending_user_messages
  end

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    clear_ets()
    on_exit(fn -> clear_ets() end)
    :ok
  end

  # --- Legacy binary regression (BYTE-IDENTITY) -----------------------------

  describe "append_pending_user_message/2 — legacy binary" do
    test "append+drain returns the SAME binary (byte-identical legacy behavior)" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      # Legacy bytes, incl. an embedded newline and multi-byte UTF-8: nothing
      # may be trimmed, normalized, or re-encoded on the way through.
      legacy = "Please fix the failing test.\n  인코딩 ✓  \n"

      assert :ok = Store.append_pending_user_message(agent_id, legacy)

      # Explicit regression: byte-identical to the pre-change behavior.
      assert Store.drain_pending_user_messages(agent_id) == [legacy]
      assert stored_messages(agent_id) == []
    end

    test "the stored value in ETS is the identical binary (not wrapped in a map)" do
      agent_id = 2
      Store.put_agent_state(agent_id, agent_state())

      legacy = "cancel requested"
      assert :ok = Store.append_pending_user_message(agent_id, legacy)

      [stored] = stored_messages(agent_id)
      assert is_binary(stored)
      assert stored == legacy
      assert byte_size(stored) == byte_size(legacy)
    end

    test "a legacy binary materializes byte-identically to the legacy path" do
      agent_id = 3
      Store.put_agent_state(agent_id, agent_state())

      legacy = "with media? no.\n"

      assert :ok = Store.append_pending_user_message(agent_id, legacy)
      assert [stored] = Store.drain_pending_user_messages(agent_id)

      # The end-to-end result: exactly the legacy single-text content part.
      assert Attachments.to_content_parts(stored, nil) == [ContentPart.text(legacy)]
    end

    test "draining resets the queue (a second drain returns [])" do
      agent_id = 4
      Store.put_agent_state(agent_id, agent_state())

      assert :ok = Store.append_pending_user_message(agent_id, "first")

      assert [_] = Store.drain_pending_user_messages(agent_id)
      assert Store.drain_pending_user_messages(agent_id) == []
    end

    test "unknown agent → {:error, :not_found} (unchanged legacy behavior)" do
      assert {:error, :not_found} = Store.append_pending_user_message(999, "hello")
      assert Store.drain_pending_user_messages(999) == []
    end
  end

  # --- Canonical multimodal map --------------------------------------------

  describe "append_pending_user_message/2 — %{text:, attachments:} map" do
    test "appends and drains as the canonical map, media intact" do
      agent_id = 11
      Store.put_agent_state(agent_id, agent_state())

      message = %{text: "Look at this screenshot", attachments: [image_attachment()]}

      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert Store.drain_pending_user_messages(agent_id) == [message]
    end

    test "the stored value is exactly `EvoGit.Attachments.message/1` of the input" do
      agent_id = 12
      Store.put_agent_state(agent_id, agent_state())

      message = %{text: "canonical please", attachments: [image_attachment()]}

      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert stored_messages(agent_id) == [Attachments.message(message)]
    end

    test "a STRING-keyed map is canonicalized to the atom-keyed canonical shape" do
      agent_id = 13
      Store.put_agent_state(agent_id, agent_state())

      message = %{"text" => "string keys in", "attachments" => [image_attachment()]}

      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert [stored] = Store.drain_pending_user_messages(agent_id)
      assert stored == %{text: "string keys in", attachments: [image_attachment()]}
    end

    test "`attachments: nil` and `attachments: []` are equivalent (no media)" do
      agent_id = 14
      Store.put_agent_state(agent_id, agent_state())

      assert :ok = Store.append_pending_user_message(agent_id, %{text: "nil media"})

      assert :ok =
               Store.append_pending_user_message(agent_id, %{text: "empty media", attachments: []})

      assert [first, second] = Store.drain_pending_user_messages(agent_id)
      assert first == %{text: "nil media", attachments: nil}
      assert second == %{text: "empty media", attachments: []}

      # Both materialize to just the text part.
      assert Attachments.to_content_parts(first.text, first.attachments) ==
               [ContentPart.text("nil media")]

      assert Attachments.to_content_parts(second.text, second.attachments) ==
               [ContentPart.text("empty media")]
    end

    test "mixed legacy + map appends drain in order, each in its own shape" do
      agent_id = 15
      Store.put_agent_state(agent_id, agent_state())

      assert :ok = Store.append_pending_user_message(agent_id, "legacy first")

      assert :ok =
               Store.append_pending_user_message(agent_id, %{
                 text: "map second",
                 attachments: [image_attachment()]
               })

      assert :ok = Store.append_pending_user_message(agent_id, "legacy third")

      assert Store.drain_pending_user_messages(agent_id) == [
               "legacy first",
               %{text: "map second", attachments: [image_attachment()]},
               "legacy third"
             ]
    end

    test "unknown agent + valid map → {:error, :not_found}" do
      assert {:error, :not_found} =
               Store.append_pending_user_message(999, %{text: "hi", attachments: nil})
    end

    test "appending a map preserves the rest of the agent state" do
      agent_id = 16
      Store.put_agent_state(agent_id, agent_state(objective: "keep me", turn: 4))

      assert :ok =
               Store.append_pending_user_message(agent_id, %{
                 text: "with media",
                 attachments: [image_attachment()]
               })

      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.objective == "keep me"
      assert state.turn == 4

      assert state.pending_user_messages == [
               %{text: "with media", attachments: [image_attachment()]}
             ]
    end
  end

  # --- Invalid map (fail loud, queue untouched) -----------------------------

  describe "append_pending_user_message/2 — malformed map" do
    test "an unknown attachment type raises a descriptive ArgumentError and queues nothing" do
      agent_id = 21
      Store.put_agent_state(agent_id, agent_state())

      bad = %{text: "video?", attachments: [Map.put(image_attachment(), "type", "video")]}

      assert_raise ArgumentError, ~r/attachments\[0\]: unknown type/, fn ->
        Store.append_pending_user_message(agent_id, bad)
      end

      assert stored_messages(agent_id) == []
      assert Store.drain_pending_user_messages(agent_id) == []
    end

    test "non-base64 attachment data raises and queues nothing" do
      agent_id = 22
      Store.put_agent_state(agent_id, agent_state())

      bad = %{text: "x", attachments: [Map.put(image_attachment(), "data", "not base64!!")]}

      assert_raise ArgumentError, ~r/attachments\[0\]: data is not valid base64/, fn ->
        Store.append_pending_user_message(agent_id, bad)
      end

      assert stored_messages(agent_id) == []
    end

    test "a blank media_type raises and queues nothing" do
      agent_id = 23
      Store.put_agent_state(agent_id, agent_state())

      bad = %{text: "x", attachments: [Map.put(image_attachment(), "media_type", "  ")]}

      assert_raise ArgumentError, ~r/attachments\[0\]: missing or blank media_type/, fn ->
        Store.append_pending_user_message(agent_id, bad)
      end

      assert stored_messages(agent_id) == []
    end

    test "a non-string text raises and queues nothing" do
      agent_id = 24
      Store.put_agent_state(agent_id, agent_state())

      assert_raise ArgumentError, ~r/message: text must be a string/, fn ->
        Store.append_pending_user_message(agent_id, %{text: 123})
      end

      assert stored_messages(agent_id) == []
    end

    test "more than the cap of attachments raises and queues nothing" do
      agent_id = 25
      Store.put_agent_state(agent_id, agent_state())

      too_many = List.duplicate(image_attachment(), Attachments.max_count() + 1)

      assert_raise ArgumentError, ~r/too many attachments/, fn ->
        Store.append_pending_user_message(agent_id, %{text: "x", attachments: too_many})
      end

      assert stored_messages(agent_id) == []
    end

    test "a rejected map leaves an already-queued message untouched" do
      agent_id = 26
      Store.put_agent_state(agent_id, agent_state())

      assert :ok = Store.append_pending_user_message(agent_id, "keep me")

      assert_raise ArgumentError, fn ->
        Store.append_pending_user_message(agent_id, %{text: "x", attachments: [:nope]})
      end

      assert Store.drain_pending_user_messages(agent_id) == ["keep me"]
    end
  end

  # --- Broadcast tolerance (delta rides the queue shapes safely) ------------

  describe "pending_user_messages delta broadcast" do
    setup do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, PubSub.agent_topic())
      drain_mailbox()

      on_exit(fn -> Phoenix.PubSub.unsubscribe(EvoGit.PubSub, PubSub.agent_topic()) end)

      :ok
    end

    test "appending a canonical message map broadcasts it in the :agent_updated delta" do
      agent_id = 31
      Store.put_agent_state(agent_id, agent_state())

      # The insert path broadcasts the initial tracked fields.
      assert_receive {:agent_updated, ^agent_id, _insert_fields, _node}

      message = %{text: "with media", attachments: [image_attachment()]}
      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert_receive {:agent_updated, ^agent_id, fields, bcast_node}
      assert Keyword.get(fields, :pending_user_messages) == [message]
      assert bcast_node == node()
    end

    test "appending a legacy binary broadcasts it verbatim (never dropped)" do
      agent_id = 32
      Store.put_agent_state(agent_id, agent_state())

      assert_receive {:agent_updated, ^agent_id, _insert_fields, _node}

      assert :ok = Store.append_pending_user_message(agent_id, "legacy")

      assert_receive {:agent_updated, ^agent_id, fields, _node}
      assert Keyword.get(fields, :pending_user_messages) == ["legacy"]
    end
  end
end
