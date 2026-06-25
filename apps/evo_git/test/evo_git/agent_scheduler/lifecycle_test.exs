defmodule EvoGit.AgentScheduler.LifecycleTest do
  @moduledoc """
  Tests for the crash-retry logic in `EvoGit.AgentScheduler.Lifecycle.handle_agent_crash/3`,
  the cancellation logic in `cancel_agent/2`, and the defensive handling for missing ETS entries.

  Uses `async: false` because the tests manipulate global named ETS tables
  (`:evogit_agent_state` and `:evogit_sched_meta`).
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # --- Shared test fixtures ---

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp phylo_node do
    %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"}
  end

  defp agent_spec do
    %AgentSpec{
      context_node: context_node(),
      phylo_node: phylo_node(),
      agent_module: __MODULE__,
      objective: "test"
    }
  end

  defp agent_state do
    %AgentState{
      context_node: context_node(),
      llm_model: "test:model",
      max_retries: 15,
      max_depth: 8
    }
  end

  defp base_state(overrides) when is_list(overrides) do
    struct!(
      %State{paused: true, agent_max_retries: 3, ref_to_agent: %{make_ref() => 1}},
      overrides
    )
  end

  # --- ETS helpers ---

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

  defp put_sched_meta(agent_id, meta) do
    :ets.insert(:evogit_sched_meta, {agent_id, meta})
  end

  defp get_sched_meta(agent_id) do
    case :ets.lookup(:evogit_sched_meta, agent_id) do
      [{^agent_id, meta}] -> {:ok, meta}
      [] -> :missing
    end
  end

  defp put_agent_state(agent_id, state) do
    :ets.insert(:evogit_agent_state, {agent_id, state})
  end

  defp get_agent_state(agent_id) do
    case :ets.lookup(:evogit_agent_state, agent_id) do
      [{^agent_id, state}] -> {:ok, state}
      [] -> :missing
    end
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    clear_ets()
    on_exit(fn -> clear_ets() end)
    :ok
  end

  # --- Tests ---

  describe "handle_agent_crash/3 — retry path" do
    test "retries agent and queues it for re-dispatch" do
      agent_id = 1

      meta = %SchedMeta{id: agent_id, depth: 0, spec: agent_spec(), retries: 0}
      put_sched_meta(agent_id, meta)
      put_agent_state(agent_id, agent_state())

      state = base_state(agent_max_retries: 3)

      assert {:noreply, new_state} =
               Lifecycle.handle_agent_crash(state, agent_id, {:error, :test_crash})

      # The lifecycle function does NOT touch ref_to_agent; the derived count stays stable.
      assert map_size(new_state.ref_to_agent) == map_size(state.ref_to_agent)

      # Meta updated in ETS
      {:ok, updated_meta} = get_sched_meta(agent_id)
      assert updated_meta.retries == 1
      assert updated_meta.status == :pending
      assert updated_meta.task_ref == nil

      # Agent queued for re-dispatch (paused → queued, not dispatched)
      assert :queue.to_list(new_state.queue) == [agent_id]
    end

    test "missing agent_state during retry doesn't crash" do
      agent_id = 1

      # sched_meta present but NO agent_state entry
      meta = %SchedMeta{id: agent_id, depth: 0, spec: agent_spec(), retries: 0}
      put_sched_meta(agent_id, meta)

      state = base_state([])

      # Should NOT raise — returns normally with updated meta
      assert {:noreply, new_state} =
               Lifecycle.handle_agent_crash(state, agent_id, {:error, :test})

      # ref_to_agent is untouched by the lifecycle function
      assert map_size(new_state.ref_to_agent) == map_size(state.ref_to_agent)

      {:ok, updated_meta} = get_sched_meta(agent_id)
      assert updated_meta.retries == 1
      assert updated_meta.status == :pending
    end

    test "resetting agent_state sets phylo_node and context to nil" do
      agent_id = 1

      meta = %SchedMeta{id: agent_id, depth: 0, spec: agent_spec(), retries: 0}
      put_sched_meta(agent_id, meta)

      # Agent state with non-nil phylo_node and context
      put_agent_state(agent_id, %AgentState{
        agent_state()
        | phylo_node: phylo_node(),
          context: %{messages: ["fake"]}
      })

      state = base_state([])

      assert {:noreply, _new_state} =
               Lifecycle.handle_agent_crash(state, agent_id, {:error, :test})

      {:ok, updated_agent_state} = get_agent_state(agent_id)
      assert updated_agent_state.phylo_node == nil
      assert updated_agent_state.context == nil
    end
  end

  describe "handle_agent_crash/3 — permanent failure" do
    test "marks agent as failed after max retries and replies to caller" do
      agent_id = 1
      ref = make_ref()

      meta = %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 3,
        from: {self(), ref},
        worktree: nil
      }

      put_sched_meta(agent_id, meta)
      put_agent_state(agent_id, agent_state())

      state = base_state(agent_max_retries: 3)

      assert {:noreply, _new_state} =
               Lifecycle.handle_agent_crash(state, agent_id, {:error, :final})

      # Both ETS entries deleted
      assert get_sched_meta(agent_id) == :missing
      assert get_agent_state(agent_id) == :missing

      # Caller receives the error reply via GenServer.reply({pid, ref}, msg)
      # which sends {ref, msg} to the pid
      assert_received {^ref, {:error, :agent_max_retries_exceeded}}
    end
  end

  describe "handle_agent_crash/3 — missing sched_meta" do
    test "missing sched_meta returns state completely unchanged" do
      state = base_state([])

      # Agent ID 9999 has no sched_meta or agent_state in ETS
      assert {:noreply, new_state} = Lifecycle.handle_agent_crash(state, 9999, {:error, :ghost})

      # The function returns the state completely unchanged on :error
      assert new_state == state
    end
  end

  describe "cancel_agent/2" do
    test "kills the agent's Task process and cleans up ETS entries" do
      agent_id = 1

      # Spawn a real long-running task
      task = Task.async(fn -> Process.sleep(10_000) end)

      meta = %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        task_ref: task,
        worktree: nil
      }

      put_sched_meta(agent_id, meta)

      state = base_state([])

      assert Lifecycle.cancel_agent(state, agent_id) == state

      # Task process should be dead
      Process.sleep(50)
      refute Process.alive?(task.pid)

      # ETS entry deleted
      assert get_sched_meta(agent_id) == :missing
    end
  end
end
