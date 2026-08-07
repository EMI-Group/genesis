defmodule EvoGit.AgentScheduler.StoreTest do
  @moduledoc """
  Tests for `EvoGit.AgentScheduler.Store` — the shared ETS helpers, focused on
  the dumb pass-through semantics of `update_agent_context/2`. Per-message
  `metadata[:timestamp]` stamping happens at message-creation time in the agent
  code (`EvoGit.Agent.ContextBuilder`), never in the store.

  Uses `async: false` because the tests manipulate global named ETS tables
  (`:evogit_agent_state` and `:evogit_sched_meta`).
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # Distinctive past Unix-seconds value for deterministic pre-stamped
  # timestamps — far from any real `now`, so assertions can never collide.
  @old_ts 1_600_000_000

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

  defp message(role, overrides) do
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

  describe "update_agent_context/2 — dumb pass-through write" do
    test "returns :ok and stores a pre-stamped context exactly as given" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts, turn: 1}),
          message(:assistant, metadata: %{timestamp: @old_ts + 1, turn: 2})
        ]
      }

      assert :ok = Store.update_agent_context(agent_id, context)

      # No re-stamping, no modification — the exact value written is the exact
      # value read back through the store's context-read path.
      assert stored_context(agent_id) == context
    end

    test "does not re-stamp or modify any pre-existing metadata" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{
        messages: [message(:user, metadata: %{timestamp: @old_ts, turn: 3})]
      }

      assert :ok = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert msg.metadata[:timestamp] == @old_ts
      assert msg.metadata[:turn] == 3
    end

    test "is a pass-through across repeated syncs of an already-stamped context" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{
        messages: [message(:user, metadata: %{timestamp: @old_ts, turn: 1})]
      }

      # Re-sync the same pre-stamped context — stored unchanged every time.
      assert :ok = Store.update_agent_context(agent_id, context)
      assert :ok = Store.update_agent_context(agent_id, stored_context(agent_id))

      [msg] = stored_context(agent_id).messages
      assert msg.metadata[:timestamp] == @old_ts
      assert msg.metadata[:turn] == 1
    end

    test "passes through messages with nil metadata untouched" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user, metadata: nil)]}

      assert :ok = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id) == context
    end

    test "leaves non-Message entries untouched" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      loose = %{role: :user, content: "not a struct"}
      context = %ReqLLM.Context{messages: [loose]}

      assert :ok = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id).messages == [loose]
    end

    test "handles an empty messages list" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: []}

      assert :ok = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id).messages == []
    end
  end

  describe "update_agent_context/2 + batch_update_agent/2 — one-way write sequence" do
    test "repeated writes of pre-stamped contexts store them unchanged every time" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      # Turn 1: post-LLM-response write via batch_update_agent (tool_dispatch.ex).
      ctx1 = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts, turn: 1}),
          message(:assistant, metadata: %{timestamp: @old_ts + 1, turn: 1})
        ]
      }

      :ok = Store.batch_update_agent(agent_id, context: ctx1)
      assert stored_context(agent_id) == ctx1

      # End-of-turn sync — dumb pass-through: returns :ok, stores unchanged.
      assert :ok = Store.update_agent_context(agent_id, ctx1)
      assert stored_context(agent_id) == ctx1

      # Turn 2: append a new pre-stamped assistant message to the in-memory
      # context (the agent code stamps it at creation — not the store).
      ctx2 = %ReqLLM.Context{
        messages: [
          message(:user, metadata: %{timestamp: @old_ts, turn: 1}),
          message(:assistant, metadata: %{timestamp: @old_ts + 1, turn: 1}),
          message(:assistant, metadata: %{timestamp: @old_ts + 2, turn: 2})
        ]
      }

      :ok = Store.batch_update_agent(agent_id, context: ctx2)
      assert stored_context(agent_id) == ctx2

      # Final sync — pass-through again; exact timestamps survive every write.
      assert :ok = Store.update_agent_context(agent_id, ctx2)
      assert stored_context(agent_id) == ctx2
    end
  end
end
