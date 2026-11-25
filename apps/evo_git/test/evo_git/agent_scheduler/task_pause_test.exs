defmodule EvoGit.AgentScheduler.TaskPauseTest do
  @moduledoc """
  TASK-LEVEL PAUSE on the scheduler side — the FREEZE COORDINATOR.

  A task pause is a durable, resumable resting state, NOT a cancel and NOT a
  failure: `EvoGit.AgentScheduler.begin_task_pause/1` marks the task in the
  `:evogit_task_pause` control-plane table, sets the `pause_requested` flag on the
  control row (`{agent_id, cancel_requested, pause_requested}`) of every live
  agent of that task, purges those agents from the LLM/tool waiting queues
  replying `{:error, :paused}`, and opens ONE `%TaskFreeze{}` over the whole agent
  TREE.

  The freeze is what makes a pause coherent:

    * a parent blocked in `spawn_sub_agents/2` is PARKED — its caller receives
      `{:freeze, :task_pause}` and its batch fields are cleared, so no child
      result can ever complete that batch;
    * `spawn_sub_agents/2` for a pausing task is answered `{:freeze, :task_pause}`
      and registers nothing;
    * every agent (root and children) reports `{:paused, info}` to the freeze;
      NOBODY is answered until the LAST pending agent reports, and that ONE
      task-level answer carries `pause_kind: :clean | :dirty`;
    * a child's pause never lands in a parent batch, never merges and never
      narrates a completion;
    * a quiesce timer forces whatever has not reported (`{:task_freeze, :force}`
      to its session) and ONE bounded grace timer then completes the pause DIRTY.

  What these tests also pin:

    * the pause flag is atomic and INDEPENDENT of the cancel flag;
    * a NEW agent of an already-pausing task is seeded `pause_requested = true`
      (late registration / crash retry), which is why the task marker exists;
    * `begin_task_pause/1` flags exactly the task's agents, purges their queued
      slot waits with `{:error, :paused}`, and leaves the cancel flag alone;
    * CANCEL WINS: `begin_graceful_cancel/1` clears a pending pause, and a pause
      that arrives while the task is cancelling is a total no-op;
    * a force kill clears the task pause marker.

  `async: false` — the quiesce cases pin the PROCESS-WIDE app env keys
  `:task_pause_quiesce_ms` / `:task_pause_force_grace_ms` via
  `Application.put_env/3`, which a concurrently running module could observe.
  Every other test here only writes its OWN rows in the app-global named ETS
  tables under per-test UNIQUE agent ids (`9_960_000+`) and task ids and deletes
  exactly those rows — never a whole-table wipe.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.TaskFreeze
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

  # An agent whose "session" is THIS test process, so a force command is
  # observable in the mailbox and the freeze counts it as live.
  defp put_session_agent!(task_id, overrides) do
    put_live_agent!(task_id, Map.put(Map.new(overrides), :session_pid, self()))
  end

  # Drives `begin_task_pause/1` through the real handler and returns the new
  # scheduler state (with the freeze opened).
  defp begin_pause!(state, task_id) do
    assert {:reply, :ok, new_state} =
             AgentScheduler.handle_call({:begin_task_pause, task_id}, {self(), make_ref()}, state)

    assert ControlPlane.task_pausing?(task_id)
    on_exit(fn -> ControlPlane.clear_task_pausing(task_id) end)
    new_state
  end

  defp freeze_for(state, task_id), do: Map.fetch!(state.task_freezes, task_id)

  defp freeze_timer_token(state, task_id, kind) do
    {token, _timer} = state.task_freeze_timers |> Map.fetch!(task_id) |> Map.fetch!(kind)
    token
  end

  defp paused_info(task_id, agent_id, overrides \\ []) do
    Map.merge(
      %{
        agent_id: agent_id,
        task_id: task_id,
        checkpoint: "checkpoint-#{agent_id}",
        branch: "branch-#{agent_id}",
        durable: true,
        clean_freeze: true,
        reason: :task_pause
      },
      Map.new(overrides)
    )
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

      assert {:reply, :ok, paused_state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      assert ControlPlane.task_pausing?(task_id)
      assert AgentScheduler.task_freezing?(paused_state, task_id)

      for id <- [root, child] do
        assert Store.pause_requested?(id), "agent #{id} of the task must be flagged"
        refute Store.cancel_requested?(id), "a pause is not a cancel"
      end

      refute Store.pause_requested?(other), "another task's agent must not be flagged"
      refute ControlPlane.task_pausing?(other_task)
      refute AgentScheduler.task_freezing?(paused_state, other_task)

      # clear_task_pause/1 clears the marker AND every flag of the task — and it
      # must take the freeze (and its timers) with it, so a timer can never fire
      # for a task that is no longer pausing.
      assert {:reply, :ok, cleared_state} =
               AgentScheduler.handle_call(
                 {:clear_task_pause, task_id},
                 {self(), make_ref()},
                 paused_state
               )

      refute ControlPlane.task_pausing?(task_id)
      refute AgentScheduler.task_freezing?(cleared_state, task_id)
      assert cleared_state.task_freeze_timers == %{}
      for id <- [root, child], do: refute(Store.pause_requested?(id))

      # Idempotent / total with nothing left.
      assert {:reply, :ok, ^cleared_state} =
               AgentScheduler.handle_call(
                 {:clear_task_pause, unique_task_id("pause-empty")},
                 {self(), make_ref()},
                 cleared_state
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

      assert {:reply, :ok, paused_state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      assert ControlPlane.task_pausing?(task_id)
      assert Store.pause_requested?(agent_id)

      assert {:reply, :ok, cancelled_state} =
               AgentScheduler.handle_call(
                 {:begin_graceful_cancel, task_id},
                 {self(), make_ref()},
                 paused_state
               )

      refute ControlPlane.task_pausing?(task_id), "the cancel abandoned the pause marker"
      refute Store.pause_requested?(agent_id), "the cancel cleared the pause flag"

      refute AgentScheduler.task_freezing?(cancelled_state, task_id),
             "the cancel abandoned the freeze"

      assert Store.cancel_requested?(agent_id), "the cancel flag owns the drain now"
    end

    test "a force kill clears the task pause marker" do
      task_id = unique_task_id("pause-force-kill")
      agent_id = put_live_agent!(task_id, %{from: {self(), make_ref()}})
      on_exit(fn -> AgentScheduler.clear_cancelling_task(task_id) end)

      state = base_state()

      assert {:reply, :ok, paused_state} =
               AgentScheduler.handle_call(
                 {:begin_task_pause, task_id},
                 {self(), make_ref()},
                 state
               )

      assert ControlPlane.task_pausing?(task_id)

      assert {:reply, :ok, killed_state} =
               AgentScheduler.handle_call(
                 {:force_kill_task_agents_for_task, task_id},
                 {self(), make_ref()},
                 paused_state
               )

      refute ControlPlane.task_pausing?(task_id)
      refute Store.pause_requested?(agent_id)
      refute AgentScheduler.task_freezing?(killed_state, task_id)
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

  # --- The freeze: parking a waiting parent ---------------------------------

  describe "begin_task_pause/1 — parking the tree" do
    test "parks a waiting parent and leaves the task DRAINING (no result reply)" do
      task_id = unique_task_id("pause-park")
      {_caller, waiter_ref} = waiter = {self(), make_ref()}
      child = unique_agent_id()

      parent =
        put_session_agent!(task_id, %{
          depth: 0,
          parent_id: nil,
          status: :waiting,
          sub_agent_from: waiter,
          total_sub_specs: 1,
          pending_sub_agents: MapSet.new([child]),
          sub_agent_indices: %{child => 0}
        })

      state = begin_pause!(base_state(), task_id)

      # The parent's exchange is released with the PARK term — not a result.
      assert_received {^waiter_ref, {:freeze, :task_pause}}
      refute_received {^waiter_ref, {:ok, _}}
      refute_received {^waiter_ref, {:paused, _}}

      # …and its batch is cleared, so no child result can ever complete it.
      assert {:ok, parked} = Store.get_sched_meta(parent)
      assert parked.sub_agent_from == nil
      assert parked.total_sub_specs == 0
      assert parked.pending_sub_agents == MapSet.new()
      assert parked.sub_agent_results == %{}
      assert parked.sub_agent_indices == %{}
      assert parked.status == :running

      # The freeze covers the whole live tree and waits for every report.
      freeze = freeze_for(state, task_id)
      assert TaskFreeze.root_id(freeze) == parent
      assert TaskFreeze.pending(freeze) == [parent]
      assert TaskFreeze.kind(freeze) == :clean
      assert Map.has_key?(state.task_freeze_timers, task_id)
    end
  end

  # --- The freeze: {:paused, info} routing ----------------------------------

  describe "the task freeze — {:paused, info} routing" do
    test "a paused result with no freeze is ignored entirely" do
      task_id = unique_task_id("pause-no-freeze")
      waiter_ref = make_ref()
      parent_ref = make_ref()

      parent =
        put_session_agent!(task_id, %{
          depth: 0,
          parent_id: nil,
          status: :waiting,
          sub_agent_from: {self(), parent_ref},
          total_sub_specs: 1,
          sub_agent_indices: %{}
        })

      child = put_session_agent!(task_id, %{depth: 1, parent_id: parent})
      info = paused_info(task_id, child)
      state = base_state()

      # No freeze for the task: the old "a paused child fills the parent's batch"
      # behaviour is GONE — nothing is stored, merged, resumed or replied.
      assert {:noreply, ^state} =
               Lifecycle.handle_session_result(child, {:paused, info}, state)

      assert {:ok, parent_meta} = Store.get_sched_meta(parent)
      assert parent_meta.sub_agent_results == %{}
      assert parent_meta.foreign_repo_commits == %{}
      assert parent_meta.status == :waiting
      assert :queue.to_list(state.queue) == []

      # The child's run DID stop, so its row is marked replied (a `:DOWN` after
      # this recycles instead of crash-retrying)…
      assert {:ok, child_meta} = Store.get_sched_meta(child)
      assert child_meta.result_sent
      # …and nobody was answered.
      refute_received {^parent_ref, _}
      refute_received {^waiter_ref, _}
    end

    test "a child's paused report fills NOTHING in the parent and never merges" do
      task_id = unique_task_id("pause-child-report")
      parent_ref = make_ref()

      parent =
        put_session_agent!(task_id, %{
          depth: 0,
          parent_id: nil,
          status: :waiting,
          sub_agent_from: {self(), parent_ref},
          total_sub_specs: 1
        })

      child = put_session_agent!(task_id, %{depth: 1, parent_id: parent})

      state = begin_pause!(base_state(), task_id)
      assert_received {^parent_ref, {:freeze, :task_pause}}

      info = paused_info(task_id, child)
      {_close_caller, close_ref} = close_from = {self(), make_ref()}
      state = Lifecycle.register_close_waiter(state, child, close_from)

      assert {:noreply, pending_state} =
               Lifecycle.handle_session_result(child, {:paused, info}, state)

      # Nothing lands in the parent batch, nothing is merged, nobody is resumed.
      assert {:ok, parent_meta} = Store.get_sched_meta(parent)
      assert parent_meta.sub_agent_results == %{}
      assert parent_meta.foreign_repo_commits == %{}
      assert parent_meta.sub_agent_from == nil
      assert parent_meta.status == :running
      assert :queue.to_list(pending_state.queue) == []
      refute_received {^parent_ref, _}

      # The individual agent's own close waiters ARE flushed with its own term.
      assert_received {^close_ref, {:paused, ^info}}

      # The freeze records the report and now waits for the parent only.
      freeze = freeze_for(pending_state, task_id)
      assert TaskFreeze.pending(freeze) == [parent]
      assert child in TaskFreeze.agents(freeze)
      assert TaskFreeze.kind(freeze) == :clean
    end

    test "the ROOT is answered only by the LAST pending report, with pause_kind" do
      task_id = unique_task_id("pause-last")
      {_caller, caller_ref} = caller = {self(), make_ref()}
      {_close_caller, close_ref} = close_from = {self(), make_ref()}

      parent = put_session_agent!(task_id, %{depth: 0, parent_id: nil, from: caller})
      child = put_session_agent!(task_id, %{depth: 1, parent_id: parent})

      state = base_state(task_agent_counts: %{task_id => 2})
      state = begin_pause!(state, task_id)
      state = Lifecycle.register_close_waiter(state, parent, close_from)

      root_info = paused_info(task_id, parent)

      assert {:noreply, waiting_state} =
               Lifecycle.handle_session_result(parent, {:paused, root_info}, state)

      # The root's OWN close waiters get its own term; the task caller waits.
      assert_received {^close_ref, {:paused, ^root_info}}
      refute_received {^caller_ref, _}
      assert TaskFreeze.pending(freeze_for(waiting_state, task_id)) == [child]

      child_info = paused_info(task_id, child)

      assert {:noreply, done_state} =
               Lifecycle.handle_session_result(child, {:paused, child_info}, waiting_state)

      assert_received {^caller_ref, {:paused, term}}
      assert term.agent_id == parent
      assert term.task_id == task_id
      assert term.reason == :task_pause
      assert term.pause_kind == :clean
      assert term.checkpoint == root_info.checkpoint
      assert term.branch == root_info.branch
      assert term.durable == true
      assert term.clean_freeze == true
      assert term.frozen_agents == Enum.sort([parent, child])

      # The freeze and its timers are gone; the count is kept while rows linger.
      refute AgentScheduler.task_freezing?(done_state, task_id)
      assert done_state.task_freeze_timers == %{}
      assert done_state.close_waiters == %{}
      assert done_state.task_agent_counts[task_id] == 2
    end

    test "a report that is not clean-freeze completes the pause DIRTY" do
      task_id = unique_task_id("pause-dirty")
      {_caller, caller_ref} = caller = {self(), make_ref()}
      root = put_session_agent!(task_id, %{depth: 0, parent_id: nil, from: caller})

      state = begin_pause!(base_state(), task_id)
      info = paused_info(task_id, root, %{clean_freeze: false})

      assert {:noreply, done_state} =
               Lifecycle.handle_session_result(root, {:paused, info}, state)

      assert_received {^caller_ref, {:paused, term}}
      assert term.pause_kind == :dirty
      assert term.clean_freeze == false
      assert term.frozen_agents == [root]
      refute AgentScheduler.task_freezing?(done_state, task_id)
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

  # --- The freeze: spawning while pausing -----------------------------------

  describe "spawn_sub_agents/2 while the task is pausing" do
    test "answers {:freeze, :task_pause} and registers nothing" do
      task_id = unique_task_id("pause-spawn")
      parent = put_session_agent!(task_id, %{depth: 0, parent_id: nil})
      :ok = ControlPlane.mark_task_pausing(task_id)
      on_exit(fn -> ControlPlane.clear_task_pausing(task_id) end)

      state = base_state(paused: false)
      rows_before = length(Store.list_sched_meta())

      assert {:reply, {:freeze, :task_pause}, ^state} =
               AgentScheduler.handle_call(
                 {:spawn_sub_agents, parent, [agent_spec()]},
                 {self(), make_ref()},
                 state
               )

      assert length(Store.list_sched_meta()) == rows_before,
             "a spawn during a pause must register no child"

      # The parent keeps NO installed batch (nothing to wait for, nothing to fill).
      assert {:ok, meta} = Store.get_sched_meta(parent)
      assert meta.total_sub_specs == 0
      assert meta.pending_sub_agents == MapSet.new()
      assert meta.sub_agent_results == %{}
    end
  end

  # --- The freeze: quiesce + grace timers -----------------------------------

  describe "the freeze quiesce/grace timers" do
    setup do
      prev_quiesce = Application.get_env(:evo_git, :task_pause_quiesce_ms)
      prev_grace = Application.get_env(:evo_git, :task_pause_force_grace_ms)
      Application.put_env(:evo_git, :task_pause_quiesce_ms, 20)
      Application.put_env(:evo_git, :task_pause_force_grace_ms, 20)

      on_exit(fn ->
        restore_env(:task_pause_quiesce_ms, prev_quiesce)
        restore_env(:task_pause_force_grace_ms, prev_grace)
      end)

      :ok
    end

    test "a quiesce timeout force-freezes the remaining agents and completes DIRTY" do
      task_id = unique_task_id("pause-quiesce")
      {_caller, caller_ref} = caller = {self(), make_ref()}

      parent = put_session_agent!(task_id, %{depth: 0, parent_id: nil, from: caller})
      child = put_session_agent!(task_id, %{depth: 1, parent_id: parent})

      state = begin_pause!(base_state(), task_id)
      assert TaskFreeze.pending(freeze_for(state, task_id)) == Enum.sort([parent, child])

      # The quiesce seam is read at CALL time: the armed timer really fires fast.
      timeout_token = freeze_timer_token(state, task_id, :timeout)

      assert_receive {:task_freeze_timeout, ^task_id, ^timeout_token}, 1_000

      assert {:noreply, forced_state} =
               AgentScheduler.handle_info(
                 {:task_freeze_timeout, task_id, timeout_token},
                 state
               )

      # Every still-pending agent's session is told to force-freeze (both fake
      # sessions are THIS process).
      assert_receive {:task_freeze, :force}, 1_000
      assert_receive {:task_freeze, :force}, 1_000

      freeze = freeze_for(forced_state, task_id)
      assert freeze.forced
      assert TaskFreeze.kind(freeze) == :dirty
      assert TaskFreeze.pending(freeze) == []
      assert TaskFreeze.agents(freeze) == Enum.sort([parent, child])
      refute_received {^caller_ref, _}

      # The grace seam is a bounded second chance: the pause then completes DIRTY
      # from whatever is durable (nothing was reported here).
      grace_token = freeze_timer_token(forced_state, task_id, :grace)

      assert_receive {:task_freeze_grace, ^task_id, ^grace_token}, 1_000

      assert {:noreply, done_state} =
               AgentScheduler.handle_info(
                 {:task_freeze_grace, task_id, grace_token},
                 forced_state
               )

      assert_receive {^caller_ref, {:paused, term}}, 1_000
      assert term.agent_id == parent
      assert term.task_id == task_id
      assert term.pause_kind == :dirty
      assert term.checkpoint == nil
      assert term.branch == nil
      assert term.frozen_agents == Enum.sort([parent, child])
      refute AgentScheduler.task_freezing?(done_state, task_id)
    end

    test "a stale timer token is ignored" do
      task_id = unique_task_id("pause-stale-timer")
      parent = put_session_agent!(task_id, %{depth: 0, parent_id: nil})

      state = begin_pause!(base_state(), task_id)

      assert {:noreply, ^state} =
               AgentScheduler.handle_info({:task_freeze_timeout, task_id, make_ref()}, state)

      assert {:noreply, ^state} =
               AgentScheduler.handle_info({:task_freeze_grace, task_id, make_ref()}, state)

      refute_received {:task_freeze, :force}
      assert TaskFreeze.pending(freeze_for(state, task_id)) == [parent]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_env(key, value), do: Application.put_env(:evo_git, key, value)

  # --- A paused child is never a completion (agent-side consumers) ----------

  describe "a paused child is never a completion" do
    test "a paused payload is not a merge child and narrates no PAUSED result" do
      spec = agent_spec()

      info = %{
        agent_id: 7,
        task_id: "t",
        checkpoint: "c-sha",
        branch: "b-name",
        reason: :task_pause
      }

      # It never reaches a parent batch, so it is never a merge child.
      assert {[], []} =
               SubagentProcessing.collect_mergeable_results(
                 [{3, spec}],
                 [{:paused, info}],
                 "primary"
               )

      # The old "PAUSED … a task resume re-spawns it" narration is gone: the
      # formatter no longer has a paused clause at all.
      text = SubagentProcessing.format_subagent_result({:paused, info})
      refute text =~ "PAUSED"
      refute text =~ "A task resume re-spawns it from its own durable state"
      refute String.starts_with?(text, "Error:")
    end
  end
end
