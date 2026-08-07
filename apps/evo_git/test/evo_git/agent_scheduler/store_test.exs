defmodule EvoGit.AgentScheduler.StoreTest do
  @moduledoc """
  Tests for `EvoGit.AgentScheduler.Store` — the shared ETS helpers, focused on
  the per-message timestamp stamping performed by `update_agent_context/2`.

  Uses `async: false` because the tests manipulate global named ETS tables
  (`:evogit_agent_state` and `:evogit_sched_meta`).
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # --- Shared test fixtures ---

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp phylo_node do
    %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"}
  end

  defp agent_state(overrides \\ []) do
    defaults = [
      context_node: context_node(),
      phylo_node: phylo_node(),
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    ]

    struct!(AgentState, Keyword.merge(defaults, overrides))
  end

  defp message(role, overrides \\ []) do
    defaults = [role: role, content: [ReqLLM.Message.ContentPart.text("hello")]]
    struct!(ReqLLM.Message, Keyword.merge(defaults, overrides))
  end

  # --- ETS helpers (reuse pattern from lifecycle_test.exs) ---

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

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    clear_ets()
    on_exit(fn -> clear_ets() end)
    :ok
  end

  defp stored_context(agent_id) do
    {:ok, state} = Store.get_agent_state(agent_id)
    state.context
  end

  # --- Tests ---

  describe "update_agent_context/2 — timestamp stamping" do
    test "stamps metadata[:timestamp] on every message" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user), message(:assistant)]}

      before = System.system_time(:second)
      _stamped = Store.update_agent_context(agent_id, context)
      after_ = System.system_time(:second)

      stamped = stored_context(agent_id).messages
      assert length(stamped) == 2

      for msg <- stamped do
        ts = msg.metadata[:timestamp]
        assert is_integer(ts), "expected integer timestamp, got: #{inspect(ts)}"
        assert ts >= before and ts <= after_
      end
    end

    test "does not overwrite an already-stamped timestamp" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      original_ts = 1_600_000_000
      context = %ReqLLM.Context{messages: [message(:user, metadata: %{timestamp: original_ts})]}

      _stamped = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert msg.metadata[:timestamp] == original_ts
    end

    test "is idempotent across repeated syncs of an already-stamped context" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user)]}
      _stamped = Store.update_agent_context(agent_id, context)

      first_ts =
        stored_context(agent_id).messages
        |> hd()
        |> Map.fetch!(:metadata)
        |> Map.fetch!(:timestamp)

      # Re-sync the already-stamped stored context — the guard must keep the
      # original timestamp rather than re-stamping with a newer `now`.
      stamped = Store.update_agent_context(agent_id, stored_context(agent_id))

      second_ts =
        stamped.messages
        |> hd()
        |> Map.fetch!(:metadata)
        |> Map.fetch!(:timestamp)

      assert second_ts == first_ts
      # The returned context is the exact value written to ETS.
      assert stamped.messages == stored_context(agent_id).messages
    end

    test "preserves pre-existing metadata (e.g. :turn) while adding the timestamp" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user, metadata: %{turn: 3})]}
      _stamped = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert msg.metadata[:turn] == 3
      assert is_integer(msg.metadata[:timestamp])
    end

    test "stamps messages whose metadata is nil" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user, metadata: nil)]}
      _stamped = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert is_integer(msg.metadata[:timestamp])
    end

    test "leaves non-Message entries untouched" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      loose = %{role: :user, content: "not a struct"}
      context = %ReqLLM.Context{messages: [loose]}
      _stamped = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id).messages == [loose]
    end

    test "handles an empty messages list" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: []}
      _stamped = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id).messages == []
    end
  end

  describe "update_agent_context/2 + batch_update_agent/2 — two-turn write sequence" do
    test "batch_update stamps immediately; end-of-turn sync preserves original stamps" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      # Distinctive past value so the turn-2 `now` timestamp can never collide.
      old_ts = 1_600_000_000

      # Turn 1: post-LLM-response write via batch_update_agent (tool_dispatch.ex:411).
      ctx1 = %ReqLLM.Context{messages: [message(:user, metadata: %{timestamp: old_ts})]}
      :ok = Store.batch_update_agent(agent_id, context: ctx1)

      # No no-timestamp window: the ETS context has timestamps immediately.
      [m1] = stored_context(agent_id).messages
      assert m1.metadata[:timestamp] == old_ts

      # End-of-turn sync (tool_dispatch.ex:465) returns the stamped context.
      stamped1 = Store.update_agent_context(agent_id, ctx1)
      assert [sm1] = stamped1.messages
      assert sm1.metadata[:timestamp] == old_ts

      # Turn 2: append a new assistant message to the in-memory context.
      ctx2 = %ReqLLM.Context{
        messages: [message(:user, metadata: %{timestamp: old_ts}), message(:assistant)]
      }

      :ok = Store.batch_update_agent(agent_id, context: ctx2)

      # Pre-existing message keeps its EXACT original timestamp; the new message
      # gets a fresh integer timestamp immediately (no no-timestamp window).
      [u1, u2] = stored_context(agent_id).messages
      assert u1.metadata[:timestamp] == old_ts
      assert is_integer(u2.metadata[:timestamp])
      assert u2.metadata[:timestamp] >= old_ts

      # Final sync — idempotence guard keeps turn-1 stamps exact.
      stamped2 = Store.update_agent_context(agent_id, ctx2)
      [s1, s2] = stamped2.messages
      assert s1.metadata[:timestamp] == old_ts
      assert is_integer(s2.metadata[:timestamp])
      assert s2.metadata[:timestamp] >= old_ts
      # The new message must NOT share the turn-1 timestamp.
      assert s1.metadata[:timestamp] != s2.metadata[:timestamp]

      # The returned context carries the same stamps as what's in ETS.
      assert stamped2.messages == stored_context(agent_id).messages
    end
  end
end
