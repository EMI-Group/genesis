defmodule EvoGit.AgentScheduler.TaskPauseTest do
  @moduledoc """
  TASK-LEVEL PAUSE on the scheduler side.

  A task pause is a durable, resumable resting state, NOT a cancel and NOT a
  failure: `EvoGit.AgentScheduler.begin_task_pause/1` marks the task in the
  `:evogit_task_pause` control-plane table and sets the `pause_requested` flag on
  the control row (`{agent_id, cancel_requested, pause_requested}`) of every live
  agent of that task, then purges those agents from the LLM/tool waiting queues
  replying `{:error, :paused}`. Agents honour the flag at their next TURN
  BOUNDARY and deliver `{:paused, info}` — a term the scheduler routes like a
  normal terminal result but without completion semantics.

  What these tests pin:

    * the pause flag is atomic and INDEPENDENT of the cancel flag;
    * a NEW agent of an already-pausing task is seeded `pause_requested = true`
      (late registration / crash retry), which is why the task marker exists;
    * `begin_task_pause/1` flags exactly the task's agents, purges their queued
      slot waits with `{:error, :paused}`, and leaves the cancel flag alone;
    * CANCEL WINS: `begin_graceful_cancel/1` clears a pending pause, and a pause
      that arrives while the task is cancelling is a total no-op;
    * a force kill clears the task pause marker;
    * `{:paused, info}` routing: a ROOT replies `{:paused, info}` to its caller
      and `await_close/2` waiters, a CHILD lands as a paused sub-result and
      resumes the parent, and neither runs completion semantics.

  `async: true`: every row used here lives in the app-global named ETS tables, so
  each test writes ONLY under per-test UNIQUE agent ids (`9_960_000+`) and task
  ids, and deletes exactly its own rows — never a whole-table wipe.
  """
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @id_base 9_960_000

  # --- Fixtures -------------------------------------------------------------

  defp unique_agent_id, do: @id_base + :erlang.unique_integer([:positive])
  defp unique_task_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp context_node, do: %ContextNode{path: "./", repo: "/tmp/test"}

  defp phylo_node,
    do: %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"}

  defp agent_spec do
    %AgentSpec{
      context_node: context_node(),
      phylo_node: phylo_node(),
      agent_module: __MODULE__,
      objective: "pause test"
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

  defp base_state(overrides \\ []) do
    profiles = [%{id: "default", model: "test:model", concurrency: 3}]

    State.from_model_profiles(profiles)
    |> struct!(Keyword.merge([paused: true, agent_max_retries: 3, ref_to_agent: %{}], overrides))
  end

  # Registers a live agent (summary row + sched_meta for `task_id`) and schedules
  # the removal of every row it created.
  defp put_live_agent!(task_id, overrides \\ []) do
    agent_id = unique_agent_id()

    meta =
      struct!(
        %SchedMeta{id: agent_id, depth: 0, spec: agent_spec(), task_id: task_id, retries: 0},
        overrides
      )

    :ets.insert(:evogit_sched_meta, {agent_id, meta})
    :ok = Store.put_agent_state(agent_id, agent_state())

    on_exit(fn ->
      :ets.delete(:evogit_sched_meta, agent_id)
      Store.delete_agent_state(agent_id)
    end)

    agent_id
  end

  setup do
    create_ets_if_missing(:evogit_agent_summary, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_sched_meta, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_agent_inbox, [:bag, :named_table, :public])
    create_ets_if_missing(:evogit_agent_control, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_task_pause, [:named_table, :public, :set])
    create_ets_if_missing(:evogit_cancelling_tasks, [:named_table, :public, :set])
    :ok
  end

  defp create_ets_if_missing(name, opts) do
    if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    :ok
  end

  defp control_row(agent_id) do
    case :ets.lookup(:evogit_agent_control, agent_id) do
      [row] -> row
      [] -> nil
    end
  end

  # --- Control row shape ----------------------------------------------------

  describe "control row — {agent_id, cancel_requested, pause_requested}" do
    test "the pause flag is atomic and independent of the cancel flag" do
      agent_id = put_live_agent!(unique_task_id("pause-flags"))

      assert :ok = Store.set_pause_requested(agent_id)
      assert Store.pause_requested?(agent_id)
      refute Store.cancel_requested?(agent_id)

      # Setting the cancel flag must not disturb the pause flag (one atomic
      # single-element update per flag, never a whole-row rewrite).
      assert :ok = Store.set_cancel_requested(agent_id)
      assert Store.cancel_requested?(agent_id)
      assert Store.pause_requested?(agent_id)

      # …and clearing one leaves the other alone.
      assert :ok = Store.clear_cancel_requested(agent_id)
      refute Store.cancel_requested?(agent_id)
      assert Store.pause_requested?(agent_id)

      assert :ok = Store.clear_pause_requested(agent_id)
      refute Store.pause_requested?(agent_id)
      assert control_row(agent_id) == {agent_id, nil, nil}

      # The agent's own summary row was never touched by either flag.
      {:ok, row} = Store.get_agent_state(agent_id)
      refute Map.has_key?(row, :pause_requested)
      refute Map.has_key?(row, :cancel_requested)
    end

    test "a legacy 2-tuple control row is upgraded instead of failing the update" do
      agent_id = put_live_agent!(unique_task_id("pause-legacy"))
      :ets.insert(:evogit_agent_control, {agent_id, true})

      # A row written by an older build must not make a flag update fail.
      assert :ok = ControlPlane.set_pause(agent_id, true)
      assert {^agent_id, true, true} = control_row(agent_id)
      assert ControlPlane.cancel_requested?(agent_id)
      assert ControlPlane.pause_requested?(agent_id)
    end

    test "the flags are total for a missing agent" do
      absent = unique_agent_id()

      refute ControlPlane.pause_requested?(absent)
      refute Store.pause_requested?(absent)
      assert {:error, :not_found} = ControlPlane.set_pause(absent, true)
      assert {:error, :not_found} = Store.set_pause_requested(absent)
      assert {:error, :not_found} = Store.clear_pause_requested(absent)
    end
  end

  # --- Late registration ----------------------------------------------------

  describe "late registration seeding (the task pause marker)" do
    test "a NEW agent of a pausing task starts with pause_requested = true" do
      task_id = unique_task_id("pause-late")
      other_task = unique_task_id("pause-late-other")

      :ok = ControlPlane.mark_task_pausing(task_id)
      on_exit(fn -> ControlPlane.clear_task_pausing(task_id) end)

      late = put_live_agent!(task_id)
      unrelated = put_live_agent!(other_task)

      assert :ok = ControlPlane.ensure_row(late)

      assert Store.pause_requested?(late),
             "a late-registered agent of a pausing task must start paused"

      assert :ok = ControlPlane.ensure_row(unrelated)
      refute Store.pause_requested?(unrelated)
    end

    test "an existing row is never reset by ensure_row/1" do
      task_id = unique_task_id("pause-keep")
      agent_id = put_live_agent!(task_id)
      :ok = Store.set_cancel_requested(agent_id)

      :ok = ControlPlane.ensure_row(agent_id)

      assert Store.cancel_requested?(agent_id)
      refute Store.pause_requested?(agent_id)
    end
  end

  # --- begin_task_pause / clear_task_pause ----------------------------------

  describe "begin_task_pause/1 and clear_task_pause/1" do
    test "flags every agent of the task and nobody else, without touching cancel" do
      task_id = unique_task_id("pause-begin")
      other_task = unique_task_id("pause-begin-other")

      root = put_live_agent!(task_id)
      child = put_live_agent!(task_id, %{depth: 1, parent_id: root})
      other = put_live_agent!(other_task)

      on_exit(fn -> AgentScheduler.clear_task_pause(task_id) end)

      state = base_state()

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      assert ControlPlane.task_pausing?(task_id)

      for id <- [root, child] do
        assert Store.pause_requested?(id), "agent #{id} of the task must be flagged"
        refute Store.cancel_requested?(id), "a pause is not a cancel"
      end

      refute Store.pause_requested?(other), "another task's agent must not be flagged"
      refute ControlPlane.task_pausing?(other_task)

      # clear_task_pause/1 clears the marker AND every flag of the task.
      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call(
                 {:clear_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      refute ControlPlane.task_pausing?(task_id)
      for id <- [root, child], do: refute(Store.pause_requested?(id))

      # Idempotent / total with nothing left.
      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call(
                 {:clear_task_pause, unique_task_id("pause-empty")},
                 {self(), make_ref()},
                 state
               )
    end

    test "a pause arriving while the task is cancelling is ignored entirely" do
      task_id = unique_task_id("pause-vs-cancel")
      agent_id = put_live_agent!(task_id)
      :ets.insert(:evogit_cancelling_tasks, {task_id})
      on_exit(fn -> :ets.delete(:evogit_cancelling_tasks, task_id) end)

      state = base_state()

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      refute ControlPlane.task_pausing?(task_id), "no marker while cancelling"
      refute Store.pause_requested?(agent_id), "no flag while cancelling"
    end

    test "begin_graceful_cancel/1 abandons a pending pause (cancel wins)" do
      task_id = unique_task_id("pause-then-cancel")
      agent_id = put_live_agent!(task_id)
      on_exit(fn -> AgentScheduler.clear_cancelling_task(task_id) end)

      state = base_state()

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      assert ControlPlane.task_pausing?(task_id)
      assert Store.pause_requested?(agent_id)

      assert {:reply, :ok, _state} =
               AgentScheduler.handle_call(
                 {:begin_graceful_cancel, task_id},
                 {self(), make_ref()},
                 state
               )

      refute ControlPlane.task_pausing?(task_id), "the cancel abandoned the pause marker"
      refute Store.pause_requested?(agent_id), "the cancel cleared the pause flag"
      assert Store.cancel_requested?(agent_id), "the cancel flag owns the drain now"
    end

    test "a force kill clears the task pause marker" do
      task_id = unique_task_id("pause-force-kill")
      agent_id = put_live_agent!(task_id, %{from: {self(), make_ref()}})
      on_exit(fn -> AgentScheduler.clear_cancelling_task(task_id) end)

      state = base_state()

      assert {:reply, :ok, _state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      assert ControlPlane.task_pausing?(task_id)

      assert {:reply, :ok, _state} =
               AgentScheduler.handle_call(
                 {:force_kill_task_agents_for_task, task_id},
                 {self(), make_ref()},
                 state
               )

      refute ControlPlane.task_pausing?(task_id)
      refute Store.pause_requested?(agent_id)
    end
  end

  # --- Slot-wait purge ------------------------------------------------------

  describe "pause purge of queued slot waits" do
    test "a waiter purged for a pause receives {:error, :paused}" do
      ref = make_ref()
      from = {self(), ref}

      state =
        base_state(
          model_concurrency: %{"default" => 0},
          llm_waiting: %{"default" => :queue.from_list([{42, from, nil}])}
        )

      {purged, _updates} = Slots.purge_agents_from_queues(state, MapSet.new([42]), :paused)

      assert_received {^ref, {:error, :paused}}
      assert :queue.is_empty(State.waiting_for(purged, "default"))
    end

    test "purge_agents_from_queues/2 still answers {:error, :cancelled} byte-identically" do
      ref = make_ref()
      from = {self(), ref}

      state =
        base_state(
          model_concurrency: %{"default" => 0},
          llm_waiting: %{"default" => :queue.from_list([{43, from, nil}])}
        )

      {purged, _updates} = Slots.purge_agents_from_queues(state, MapSet.new([43]))

      assert_received {^ref, {:error, :cancelled}}
      assert :queue.is_empty(State.waiting_for(purged, "default"))
    end

    test "a tool waiter purged for a pause also receives {:error, :paused}" do
      ref = make_ref()
      from = {self(), ref}

      state =
        base_state(
          max_tool_concurrency: 0,
          tool_waiting: :queue.from_list([{44, from}])
        )

      {purged, _updates} = Slots.purge_agents_from_queues(state, MapSet.new([44]), :paused)

      assert_received {^ref, {:error, :paused}}
      assert :queue.is_empty(purged.tool_waiting)
    end
  end

  # --- {:paused, info} routing ----------------------------------------------

  describe "handle_session_result/3 — {:paused, info}" do
    test "a ROOT replies {:paused, info} to the caller and to await_close waiters" do
      task_id = unique_task_id("pause-root")
      agent_id = unique_agent_id()
      from = {self(), make_ref()}
      {_caller, caller_ref} = from
      close_from = {self(), make_ref()}
      {_close_caller, close_ref} = close_from

      put_live_agent!(task_id)

      :ets.insert(
        :evogit_sched_meta,
        {agent_id,
         %SchedMeta{
           id: agent_id,
           depth: 0,
           spec: agent_spec(),
           task_id: task_id,
           retries: 0,
           from: from,
           session_pid: self(),
           foreign_repo_commits: %{"foreign1" => "sha-1"}
         }}
      )

      on_exit(fn -> :ets.delete(:evogit_sched_meta, agent_id) end)

      state =
        base_state(task_agent_counts: %{task_id => 2})
        |> Lifecycle.register_close_waiter(agent_id, close_from)

      info = %{
        agent_id: agent_id,
        task_id: task_id,
        checkpoint: "checkpoint-sha",
        branch: "evogit-agent-paused",
        reason: :task_pause
      }

      assert {:noreply, new_state} =
               Lifecycle.handle_session_result(agent_id, {:paused, info}, state)

      # The caller and every close waiter receive the SAME term — a pause is a
      # terminal outcome, but it is NOT a result/report.
      assert_received {^caller_ref, {:paused, ^info}}
      assert_received {^close_ref, {:paused, ^info}}
      refute_received {^caller_ref, {:ok, _}}

      assert new_state.task_agent_counts == %{}
      assert new_state.close_waiters == %{}
      assert {:ok, stored} = Store.get_sched_meta(agent_id)
      assert stored.result_sent
    end

    test "a CHILD lands as a paused sub-result and resumes the parent" do
      task_id = unique_task_id("pause-child")
      parent_id = unique_agent_id()
      child_id = unique_agent_id()
      # A LIVE waiter (a running parent blocked on its batch) — NOT the retained
      # `sub_agent_from: nil` marker, which keeps the parent :running instead.
      subagent_from = {self(), make_ref()}

      :ets.insert(
        :evogit_sched_meta,
        {parent_id,
         %SchedMeta{
           id: parent_id,
           depth: 0,
           spec: agent_spec(),
           task_id: task_id,
           retries: 0,
           status: :waiting,
           sub_agent_from: subagent_from,
           total_sub_specs: 1,
           pending_sub_agents: MapSet.new([child_id]),
           sub_agent_indices: %{child_id => 0}
         }}
      )

      :ets.insert(
        :evogit_sched_meta,
        {child_id,
         %SchedMeta{
           id: child_id,
           depth: 1,
           spec: agent_spec(),
           task_id: task_id,
           parent_id: parent_id,
           retries: 0,
           status: :running,
           session_pid: self()
         }}
      )

      :ok = Store.put_agent_state(parent_id, agent_state())

      info = %{
        agent_id: child_id,
        task_id: task_id,
        checkpoint: "c-sha",
        branch: "b",
        reason: :task_pause
      }

      state = base_state()

      assert {:noreply, new_state} =
               Lifecycle.handle_session_result(child_id, {:paused, info}, state)

      # A paused child is NOT a failure: it is stored verbatim as its sub-result…
      assert {:ok, parent} = Store.get_sched_meta(parent_id)
      assert parent.sub_agent_results == %{0 => {:paused, info}}
      refute Map.get(parent.foreign_repo_commits, "primary")

      # …the child's row is marked replied (so its :DOWN recycles, not retries)…
      assert {:ok, child} = Store.get_sched_meta(child_id)
      assert child.result_sent

      # …and the parent is resumed with the scheduler (queued here because the
      # scheduler state is paused).
      assert parent.status == :ready
      assert :queue.to_list(new_state.queue) == [parent_id]

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, parent_id)
        :ets.delete(:evogit_sched_meta, child_id)
        Store.delete_agent_state(parent_id)
      end)
    end

    test "a paused term for an agent with no sched_meta is ignored" do
      state = base_state()

      assert {:noreply, ^state} =
               Lifecycle.handle_session_result(unique_agent_id(), {:paused, %{}}, state)
    end

    test "the result injectors pass a paused term through unchanged" do
      info = %{agent_id: 1, task_id: "t", checkpoint: "c", branch: "b", reason: :task_pause}
      paused = {:paused, info}

      assert Lifecycle.inject_foreign_repo_commits(paused, %{"foreign1" => "sha-1"}) == paused
      assert Lifecycle.inject_agent_count(paused, 3) == paused
    end
  end

  # --- Paused child format + merge (agent-side consumers) -------------------

  describe "a paused subagent is formatted and merged like a completion" do
    test "the formatted text is neutral and names the pause" do
      text =
        SubagentProcessing.format_subagent_result(
          {:paused, %{checkpoint: "abc123", branch: "evogit-agent-x", reason: :task_pause}}
        )

      refute String.starts_with?(text, "Error:")
      refute text =~ "Error"
      assert text =~ "PAUSED"
      assert text =~ "abc123"
      assert text =~ "evogit-agent-x"
      assert text =~ "not resumable after a restart"
    end

    test "the paused checkpoint becomes a merge child like a normal completion" do
      spec = agent_spec()

      info = %{
        agent_id: 7,
        task_id: "t",
        checkpoint: "c-sha",
        branch: "b-name",
        reason: :task_pause
      }

      {children, cross_repo} =
        SubagentProcessing.collect_mergeable_results([{3, spec}], [{:paused, info}], "primary")

      assert cross_repo == []

      assert [%{index: 3, commit_sha: "c-sha", branch: "b-name", node_path: "./"} = child] =
               children

      assert child.objective == spec.objective

      # No checkpoint sha ⇒ today's behaviour (no merge attempt).
      assert {[], []} =
               SubagentProcessing.collect_mergeable_results(
                 [{3, spec}],
                 [{:paused, %{info | checkpoint: nil}}],
                 "primary"
               )
    end
  end
end
