defmodule EvoGit.AgentScheduler.PendingUserMessagesTest do
  @moduledoc """
  Tests for the shape-tolerance of the pending-user-message queue.

  The queue itself is the scheduler CONTROL PLANE
  (`EvoGit.AgentScheduler.ControlPlane`: `append_message/2`, `drain_messages/1`,
  `pending_messages/1`, `delete/1`), because the agent's
  `%EvoGit.AgentScheduler.AgentState{}` row is a SUMMARY-only read model with
  one writer — its own session. The public scheduler wrappers
  (`EvoGit.AgentScheduler.Store.append_pending_user_message/2` +
  `drain_pending_user_messages/1`) are covered here too: they own the SHAPE
  contract (canonicalization + validation) in front of that transport.

  The queue must tolerate BOTH a legacy plain `String.t()` AND a
  `%{text:, attachments:}` map (multimodal injected user message):

    * a legacy binary rides through VERBATIM — byte-identical end-to-end, i.e.
      exactly the pre-change behavior (asserted explicitly below);
    * a map is canonicalized through `EvoGit.Attachments.message/1` before it is
      stored, and a malformed map raises the descriptive `ArgumentError`.

  Uses `async: true`: the tables it seeds are the app-global named
  `:evogit_agent_summary` / `:evogit_agent_inbox` / `:evogit_agent_control`
  ETS tables, so every test uses its own `unique_agent_id/0` (its 9_950_000+
  range) and never wipes a table. The `"agents"` PubSub topic of the global
  `EvoGit.PubSub` is shared, but every assertion matches on the agent id, so a
  sibling module's broadcast is benign.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Attachments
  alias EvoGit.Core.ContextNode
  alias ReqLLM.Message.ContentPart

  # --- Fixtures -------------------------------------------------------------

  # The SUMMARY row: no conversation and no cross-process control state — the
  # injected queue and the cancel flag live in `ControlPlane`.
  defp agent_state(overrides \\ []) do
    defaults = [
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      current_commit: "abc",
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

  defp create_ets_if_missing(name, opts) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
    end
  end

  # Per-test-unique agent id: the tables are app-global and shared with every
  # concurrently running `async: true` module, so this module never reuses a
  # small literal id and never wipes a table (see the moduledoc).
  defp unique_agent_id, do: 9_950_000 + System.unique_integer([:positive])

  # Registers a live agent row (the control plane refuses to queue a message for
  # an agent that is gone — the "the agent must be live" contract) and schedules
  # the removal of every row this test created.
  defp live_agent! do
    agent_id = unique_agent_id()
    :ok = Store.put_agent_state(agent_id, agent_state())
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
    agent_id
  end

  # The queue as the CONTROL PLANE holds it — the storage location the summary
  # row no longer carries.
  defp stored_messages(agent_id), do: ControlPlane.pending_messages(agent_id)

  # Registers the row and consumes the registration delta, so a broadcast test
  # observes exactly the append/drain delta.
  defp registered_agent! do
    agent_id = live_agent!()
    assert_receive {:agent_updated, ^agent_id, _insert_fields, _node}
    agent_id
  end

  defp drain_mailbox do
    receive do
      _msg -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  setup do
    create_ets_if_missing(:evogit_agent_summary, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_sched_meta, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_agent_inbox, [:bag, :named_table, :public])
    create_ets_if_missing(:evogit_agent_control, [:named_table, :public, :set])
    :ok
  end

  # --- The control-plane transport ------------------------------------------

  describe "ControlPlane — the queue transport" do
    test "append_message/2 + drain_messages/1 preserve append order" do
      agent_id = live_agent!()

      assert :ok = ControlPlane.append_message(agent_id, "first")
      assert :ok = ControlPlane.append_message(agent_id, %{text: "second", attachments: nil})
      assert :ok = ControlPlane.append_message(agent_id, "third")

      # The peek does not consume.
      assert ControlPlane.pending_messages(agent_id) == [
               "first",
               %{text: "second", attachments: nil},
               "third"
             ]

      assert ControlPlane.drain_messages(agent_id) == [
               "first",
               %{text: "second", attachments: nil},
               "third"
             ]

      assert ControlPlane.pending_messages(agent_id) == []
      assert ControlPlane.drain_messages(agent_id) == []
    end

    test "append_message/2 refuses a message for an agent that is not live" do
      unknown = unique_agent_id()

      assert {:error, :not_found} = ControlPlane.append_message(unknown, "hello")
      assert ControlPlane.pending_messages(unknown) == []
      assert ControlPlane.drain_messages(unknown) == []
    end

    test "delete/1 drops the inbox rows for that agent only" do
      agent_id = live_agent!()
      other_id = live_agent!()

      assert :ok = ControlPlane.append_message(agent_id, "drop me")
      assert :ok = ControlPlane.append_message(other_id, "keep me")

      assert :ok = ControlPlane.delete(agent_id)

      assert ControlPlane.pending_messages(agent_id) == []
      assert ControlPlane.pending_messages(other_id) == ["keep me"]
    end

    test "delete_agent_state/1 also clears the control-plane rows (no leak)" do
      agent_id = live_agent!()

      assert :ok = ControlPlane.append_message(agent_id, "queued")
      assert :ok = ControlPlane.set_cancel(agent_id, true)

      assert :ok = Store.delete_agent_state(agent_id)

      assert ControlPlane.pending_messages(agent_id) == []
      refute ControlPlane.cancel_requested?(agent_id)
      assert :ets.lookup(:evogit_agent_inbox, agent_id) == []
      assert :ets.lookup(:evogit_agent_control, agent_id) == []
    end

    test "the summary row never holds the queue or the cancel flag" do
      agent_id = live_agent!()

      assert :ok = Store.append_pending_user_message(agent_id, "queued")
      assert :ok = Store.set_cancel_requested(agent_id, true)

      assert {:ok, row} = Store.get_agent_state(agent_id)
      refute Map.has_key?(row, :pending_user_messages)
      refute Map.has_key?(row, :cancel_requested)
    end
  end

  # --- Legacy binary regression (BYTE-IDENTITY) -----------------------------

  describe "append_pending_user_message/2 — legacy binary" do
    test "append+drain returns the SAME binary (byte-identical legacy behavior)" do
      agent_id = live_agent!()

      # Legacy bytes, incl. an embedded newline and multi-byte UTF-8: nothing
      # may be trimmed, normalized, or re-encoded on the way through.
      legacy = "Please fix the failing test.\n  인코딩 ✓  \n"

      assert :ok = Store.append_pending_user_message(agent_id, legacy)

      # Explicit regression: byte-identical to the pre-change behavior.
      assert Store.drain_pending_user_messages(agent_id) == [legacy]
      assert stored_messages(agent_id) == []
    end

    test "the stored value is the identical binary (not wrapped in a map)" do
      agent_id = live_agent!()

      legacy = "cancel requested"
      assert :ok = Store.append_pending_user_message(agent_id, legacy)

      [stored] = stored_messages(agent_id)
      assert is_binary(stored)
      assert stored == legacy
      assert byte_size(stored) == byte_size(legacy)
    end

    test "a legacy binary materializes byte-identically to the legacy path" do
      agent_id = live_agent!()

      legacy = "with media? no.\n"

      assert :ok = Store.append_pending_user_message(agent_id, legacy)
      assert [stored] = Store.drain_pending_user_messages(agent_id)

      # The end-to-end result: exactly the legacy single-text content part.
      assert Attachments.to_content_parts(stored, nil) == [ContentPart.text(legacy)]
    end

    test "draining resets the queue (a second drain returns [])" do
      agent_id = live_agent!()

      assert :ok = Store.append_pending_user_message(agent_id, "first")

      assert [_] = Store.drain_pending_user_messages(agent_id)
      assert Store.drain_pending_user_messages(agent_id) == []
    end

    test "unknown agent → {:error, :not_found} (unchanged legacy behavior)" do
      unknown = unique_agent_id()

      assert {:error, :not_found} = Store.append_pending_user_message(unknown, "hello")
      assert Store.drain_pending_user_messages(unknown) == []
    end
  end

  # --- Canonical multimodal map --------------------------------------------

  describe "append_pending_user_message/2 — %{text:, attachments:} map" do
    test "appends and drains as the canonical map, media intact" do
      agent_id = live_agent!()

      message = %{text: "Look at this screenshot", attachments: [image_attachment()]}

      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert Store.drain_pending_user_messages(agent_id) == [message]
    end

    test "the stored value is exactly `EvoGit.Attachments.message/1` of the input" do
      agent_id = live_agent!()

      message = %{text: "canonical please", attachments: [image_attachment()]}

      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert stored_messages(agent_id) == [Attachments.message(message)]
    end

    test "a STRING-keyed map is canonicalized to the atom-keyed canonical shape" do
      agent_id = live_agent!()

      message = %{"text" => "string keys in", "attachments" => [image_attachment()]}

      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert [stored] = Store.drain_pending_user_messages(agent_id)
      assert stored == %{text: "string keys in", attachments: [image_attachment()]}
    end

    test "`attachments: nil` and `attachments: []` are equivalent (no media)" do
      agent_id = live_agent!()

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
      agent_id = live_agent!()

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
      unknown = unique_agent_id()

      assert {:error, :not_found} =
               Store.append_pending_user_message(unknown, %{text: "hi", attachments: nil})
    end

    test "appending a map preserves the rest of the agent state" do
      agent_id = unique_agent_id()

      :ok = Store.put_agent_state(agent_id, agent_state(objective: "keep me", turn: 4))
      on_exit(fn -> Store.delete_agent_state(agent_id) end)

      assert :ok =
               Store.append_pending_user_message(agent_id, %{
                 text: "with media",
                 attachments: [image_attachment()]
               })

      {:ok, state} = Store.get_agent_state(agent_id)
      assert state.objective == "keep me"
      assert state.turn == 4

      # The queue is NOT on the summary row: it lives in the control plane.
      assert stored_messages(agent_id) == [
               %{text: "with media", attachments: [image_attachment()]}
             ]
    end
  end

  # --- Invalid map (fail loud, queue untouched) -----------------------------

  describe "append_pending_user_message/2 — malformed map" do
    test "an unknown attachment type raises a descriptive ArgumentError and queues nothing" do
      agent_id = live_agent!()

      bad = %{text: "video?", attachments: [Map.put(image_attachment(), "type", "video")]}

      assert_raise ArgumentError, ~r/attachments\[0\]: unknown type/, fn ->
        Store.append_pending_user_message(agent_id, bad)
      end

      assert stored_messages(agent_id) == []
      assert Store.drain_pending_user_messages(agent_id) == []
    end

    test "non-base64 attachment data raises and queues nothing" do
      agent_id = live_agent!()

      bad = %{text: "x", attachments: [Map.put(image_attachment(), "data", "not base64!!")]}

      assert_raise ArgumentError, ~r/attachments\[0\]: data is not valid base64/, fn ->
        Store.append_pending_user_message(agent_id, bad)
      end

      assert stored_messages(agent_id) == []
    end

    test "a blank media_type raises and queues nothing" do
      agent_id = live_agent!()

      bad = %{text: "x", attachments: [Map.put(image_attachment(), "media_type", "  ")]}

      assert_raise ArgumentError, ~r/attachments\[0\]: missing or blank media_type/, fn ->
        Store.append_pending_user_message(agent_id, bad)
      end

      assert stored_messages(agent_id) == []
    end

    test "a non-string text raises and queues nothing" do
      agent_id = live_agent!()

      assert_raise ArgumentError, ~r/message: text must be a string/, fn ->
        Store.append_pending_user_message(agent_id, %{text: 123})
      end

      assert stored_messages(agent_id) == []
    end

    test "more than the cap of attachments raises and queues nothing" do
      agent_id = live_agent!()

      too_many = List.duplicate(image_attachment(), Attachments.max_count() + 1)

      assert_raise ArgumentError, ~r/too many attachments/, fn ->
        Store.append_pending_user_message(agent_id, %{text: "x", attachments: too_many})
      end

      assert stored_messages(agent_id) == []
    end

    test "a rejected map leaves an already-queued message untouched" do
      agent_id = live_agent!()

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

    # Registers the row and consumes the registration delta, so the assertions
    # below observe exactly the append/drain delta.
    test "appending a canonical message map broadcasts it in the :agent_updated delta" do
      agent_id = registered_agent!()

      message = %{text: "with media", attachments: [image_attachment()]}
      assert :ok = Store.append_pending_user_message(agent_id, message)

      assert_receive {:agent_updated, ^agent_id, fields, bcast_node}
      assert Keyword.get(fields, :pending_user_messages) == [message]
      assert bcast_node == node()
    end

    test "appending a legacy binary broadcasts it verbatim (never dropped)" do
      agent_id = registered_agent!()

      assert :ok = Store.append_pending_user_message(agent_id, "legacy")

      assert_receive {:agent_updated, ^agent_id, fields, _node}
      assert Keyword.get(fields, :pending_user_messages) == ["legacy"]
    end

    test "a second append broadcasts the WHOLE queue (never just the new message)" do
      agent_id = registered_agent!()

      assert :ok = Store.append_pending_user_message(agent_id, "first")
      assert_receive {:agent_updated, ^agent_id, first_fields, _node}
      assert Keyword.get(first_fields, :pending_user_messages) == ["first"]

      assert :ok = Store.append_pending_user_message(agent_id, "second")
      assert_receive {:agent_updated, ^agent_id, second_fields, _node}
      assert Keyword.get(second_fields, :pending_user_messages) == ["first", "second"]
    end

    test "draining broadcasts an EMPTY pending-user-message delta" do
      agent_id = registered_agent!()

      assert :ok = Store.append_pending_user_message(agent_id, "drain me")
      assert_receive {:agent_updated, ^agent_id, _append_fields, _node}

      assert ["drain me"] = Store.drain_pending_user_messages(agent_id)

      assert_receive {:agent_updated, ^agent_id, fields, _node}
      assert Keyword.get(fields, :pending_user_messages) == []
    end
  end
end
