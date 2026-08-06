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
      :ok = Store.update_agent_context(agent_id, context)
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

      :ok = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert msg.metadata[:timestamp] == original_ts
    end

    test "is idempotent across repeated syncs of an already-stamped context" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user)]}
      :ok = Store.update_agent_context(agent_id, context)

      first_ts =
        stored_context(agent_id).messages
        |> hd()
        |> Map.fetch!(:metadata)
        |> Map.fetch!(:timestamp)

      # Re-sync the already-stamped stored context — the guard must keep the
      # original timestamp rather than re-stamping with a newer `now`.
      :ok = Store.update_agent_context(agent_id, stored_context(agent_id))

      second_ts =
        stored_context(agent_id).messages
        |> hd()
        |> Map.fetch!(:metadata)
        |> Map.fetch!(:timestamp)

      assert second_ts == first_ts
    end

    test "preserves pre-existing metadata (e.g. :turn) while adding the timestamp" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user, metadata: %{turn: 3})]}
      :ok = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert msg.metadata[:turn] == 3
      assert is_integer(msg.metadata[:timestamp])
    end

    test "stamps messages whose metadata is nil" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: [message(:user, metadata: nil)]}
      :ok = Store.update_agent_context(agent_id, context)

      [msg] = stored_context(agent_id).messages
      assert is_integer(msg.metadata[:timestamp])
    end

    test "leaves non-Message entries untouched" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      loose = %{role: :user, content: "not a struct"}
      context = %ReqLLM.Context{messages: [loose]}
      :ok = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id).messages == [loose]
    end

    test "handles an empty messages list" do
      agent_id = 1
      Store.put_agent_state(agent_id, agent_state())

      context = %ReqLLM.Context{messages: []}
      :ok = Store.update_agent_context(agent_id, context)

      assert stored_context(agent_id).messages == []
    end
  end
end
