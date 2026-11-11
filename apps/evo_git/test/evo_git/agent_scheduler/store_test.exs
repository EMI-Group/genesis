defmodule EvoGit.AgentScheduler.StoreTest do
  @moduledoc """
  Tests for `EvoGit.AgentScheduler.Store` — the ETS helper layer over the
  `:evogit_agent_summary` SUMMARY row (`%AgentState{}`) and `:evogit_sched_meta`.

  The summary row is a READ MODEL with exactly ONE runtime writer (the agent's
  `EvoGit.Agent.Session`, through `EvoGit.Agent.Session.Summary.publish/3`): it
  carries no conversation (`:context` is gone — the session serves it through
  `EvoGit.Agent.Session.history/2`) and no cross-process control state (the
  injected inbox and the graceful-cancel flag live in
  `EvoGit.AgentScheduler.ControlPlane`). So these tests pin:

    * the RAW row read/write (`get_agent_state/1` applies no projection and
      `put_agent_state/2` neither strips fields nor resets control state);
    * `message_count`, `current_commit` and `last_activity_at` are ORDINARY
      tracked summary fields, so they reach the row and the delta broadcast;
    * the control-plane wrappers (`set_cancel_requested/…`,
      `append_pending_user_message/2`, `drain_pending_user_messages/1`) that
      replaced the old on-row control fields.

  Uses `async: true`: the rows it seeds live in the app-global named ETS tables
  (`:evogit_agent_summary`, `:evogit_sched_meta`, `:evogit_agent_inbox`,
  `:evogit_agent_control`), so every test uses its own `unique_agent_id/0` (its
  9_950_000+ range) and never wipes a table. The `"agents"` PubSub topic
  (`PubSub.agent_topic`) of the global `EvoGit.PubSub` is shared, but every
  assertion matches on the agent id, so a sibling module's broadcast is benign.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  # --- Shared test fixtures ---

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp agent_state(overrides \\ []) do
    defaults = [
      context_node: context_node(),
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    ]

    struct!(AgentState, Keyword.merge(defaults, overrides))
  end

  # --- ETS helpers (reuse pattern from lifecycle_test.exs) ---

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  # Per-test-unique agent id: the tables are app-global and shared with every
  # concurrently running `async: true` module, so this module never reuses a
  # small literal id and never wipes a table (see the moduledoc).
  defp unique_agent_id, do: 9_950_000 + :erlang.unique_integer([:positive])

  defp drain_mailbox do
    receive do
      _msg -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_agent_summary)
    create_ets_if_missing(:evogit_sched_meta)
    create_ets_if_missing(:evogit_agent_inbox)
    create_ets_if_missing(:evogit_agent_control)
    :ok
  end

  # --- Tests ---

  describe "get_agent_state/1 — the RAW summary row" do
    test "returns :error for an unknown agent" do
      assert Store.get_agent_state(unique_agent_id()) == :error
    end

    test "returns the row EXACTLY as written, with no control-plane projection" do
      agent_id = unique_agent_id()

      state =
        agent_state(
          status: :running,
          message_count: 7,
          current_commit: "abc123",
          objective_preview: "preview",
          llm_generation_params: [temperature: 0.2]
        )

      assert :ok = Store.put_agent_state(agent_id, state)

      # The whole struct round-trips: a summary row carries no conversation, so
      # there is nothing for a read to project (and nothing to drop).
      assert {:ok, stored} = Store.get_agent_state(agent_id)
      assert stored == state
      refute Map.has_key?(stored, :context)
      refute Map.has_key?(stored, :pending_user_messages)
      refute Map.has_key?(stored, :cancel_requested)
      refute Map.has_key?(stored, :phylo_node)
    end
  end

  describe "put_agent_state/2 — ordinary tracked summary fields" do
    test "tracks message_count, current_commit and last_activity_at on an existing row" do
      agent_id = unique_agent_id()
      assert :ok = Store.put_agent_state(agent_id, agent_state())

      {:ok, %AgentState{} = initial} = Store.get_agent_state(agent_id)
      assert initial.message_count == 0
      assert initial.current_commit == nil
      assert initial.last_activity_at == nil

      now = DateTime.utc_now()

      assert :ok =
               Store.put_agent_state(
                 agent_id,
                 %AgentState{
                   initial
                   | message_count: 4,
                     current_commit: "deadbeef",
                     last_activity_at: now
                 }
               )

      assert {:ok, stored} = Store.get_agent_state(agent_id)
      assert stored.message_count == 4
      assert stored.current_commit == "deadbeef"
      assert stored.last_activity_at == now
    end

    test "writes every summary field verbatim (no stripping of heavy fields)" do
      agent_id = unique_agent_id()

      heavy = %{
        "provider_profile_id" => "account",
        "model" => "gpt-4o-mini",
        "reasoning_effort" => "low"
      }

      state =
        agent_state(
          model_spec: heavy,
          provider_profile_id: "account",
          llm_generation_params: [temperature: 0.2, max_tokens: 1000],
          foreign_repos: [],
          archive: true,
          objective: String.duplicate("x", 5_000),
          objective_preview: String.duplicate("x", 4_096)
        )

      assert :ok = Store.put_agent_state(agent_id, state)

      assert {:ok, stored} = Store.get_agent_state(agent_id)
      assert stored == state
      assert stored.llm_generation_params == [temperature: 0.2, max_tokens: 1000]
      assert stored.model_spec == heavy
    end
  end

  describe "broadcast payload hygiene" do
    setup do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, PubSub.agent_topic())
      # Flush any broadcasts that arrived before this test subscribed
      drain_mailbox()

      on_exit(fn ->
        Phoenix.PubSub.unsubscribe(EvoGit.PubSub, PubSub.agent_topic())
      end)

      :ok
    end

    test "a first insert broadcasts the initial tracked fields (never :context)" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state(message_count: 2))

      assert_receive {:agent_updated, ^agent_id, fields, bcast_node}
      assert Keyword.keyword?(fields)
      refute Keyword.has_key?(fields, :context)
      refute Keyword.has_key?(fields, :cancel_requested)
      assert Keyword.fetch!(fields, :message_count) == 2
      assert Keyword.fetch!(fields, :llm_model) == "test:model"
      assert bcast_node == node()
    end

    test "an update broadcasts a delta carrying message_count and current_commit" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())
      assert_receive {:agent_updated, ^agent_id, _insert_fields, _node}

      {:ok, %AgentState{} = current} = Store.get_agent_state(agent_id)

      assert :ok =
               Store.put_agent_state(
                 agent_id,
                 %AgentState{current | message_count: 5, current_commit: "cafe"}
               )

      assert_receive {:agent_updated, ^agent_id, fields, bcast_node}
      assert Keyword.fetch!(fields, :message_count) == 5
      assert Keyword.fetch!(fields, :current_commit) == "cafe"
      # Only the changed fields ride the delta — an unchanged field is absent.
      refute Keyword.has_key?(fields, :turn)
      assert bcast_node == node()
    end

    test "a rewrite that changes nothing tracked broadcast no delta at all" do
      agent_id = unique_agent_id()
      state = agent_state(message_count: 1)
      Store.put_agent_state(agent_id, state)
      assert_receive {:agent_updated, ^agent_id, _insert_fields, _node}

      # Same values again — the row is identical, so there is no delta.
      assert :ok = Store.put_agent_state(agent_id, state)
      refute_receive {:agent_updated, ^agent_id, _fields, _node}, 100
    end
  end

  describe "control-plane wrappers — graceful-cancel flag" do
    test "set_cancel_requested/1 returns :ok and sets the flag for a live agent" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())

      assert :ok = Store.set_cancel_requested(agent_id)
      assert Store.cancel_requested?(agent_id)
    end

    test "set_cancel_requested/1 returns {:error, :not_found} for an unknown agent" do
      assert {:error, :not_found} = Store.set_cancel_requested(unique_agent_id())
    end

    test "cancel_requested?/1 is false when the agent state is missing" do
      refute Store.cancel_requested?(unique_agent_id())
    end

    test "cancel_requested?/1 is false by default and reflects the flag after set/clear" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())

      refute Store.cancel_requested?(agent_id)

      assert :ok = Store.set_cancel_requested(agent_id)
      assert Store.cancel_requested?(agent_id)

      assert :ok = Store.clear_cancel_requested(agent_id)
      refute Store.cancel_requested?(agent_id)
    end

    test "clear_cancel_requested/1 returns {:error, :not_found} for an unknown agent" do
      assert {:error, :not_found} = Store.clear_cancel_requested(unique_agent_id())
    end

    test "the flag is control-plane state: it survives a whole-row put_agent_state/2" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())
      assert :ok = Store.set_cancel_requested(agent_id)

      # A whole-struct write of an unrelated row never resets control state —
      # the flag does not live on the summary row at all.
      assert :ok = Store.put_agent_state(agent_id, agent_state(turn: 7))
      assert {:ok, state} = Store.get_agent_state(agent_id)
      assert state.turn == 7
      assert Store.cancel_requested?(agent_id)
    end

    test "delete_agent_state/1 drops the control-plane rows too" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())
      assert :ok = Store.set_cancel_requested(agent_id)
      assert :ok = Store.append_pending_user_message(agent_id, "hi")

      assert :ok = Store.delete_agent_state(agent_id)

      assert Store.get_agent_state(agent_id) == :error
      refute Store.cancel_requested?(agent_id)
      assert Store.drain_pending_user_messages(agent_id) == []
    end
  end

  describe "control-plane wrappers — pending user messages" do
    test "append_pending_user_message/2 queues in order and drain returns exactly-once" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())

      assert :ok = Store.append_pending_user_message(agent_id, "first")
      assert :ok = Store.append_pending_user_message(agent_id, "second")

      assert Store.drain_pending_user_messages(agent_id) == ["first", "second"]
      # The drain consumed them: a second drain is empty.
      assert Store.drain_pending_user_messages(agent_id) == []
    end

    test "append_pending_user_message/2 returns {:error, :not_found} for a recycled agent" do
      assert {:error, :not_found} = Store.append_pending_user_message(unique_agent_id(), "late")
    end

    test "a queued message never reaches the summary row" do
      agent_id = unique_agent_id()
      Store.put_agent_state(agent_id, agent_state())
      assert :ok = Store.append_pending_user_message(agent_id, "queued")

      assert {:ok, state} = Store.get_agent_state(agent_id)
      refute Map.has_key?(state, :pending_user_messages)
    end
  end
end
