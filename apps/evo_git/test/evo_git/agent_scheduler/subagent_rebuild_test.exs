defmodule EvoGit.AgentScheduler.SubagentRebuildTest do
  @moduledoc """
  Pins the REBUILD half of whole-tree resume: when no in-memory subagent batch
  survives, the resumed parent hands a plan built from the children's DURABLE
  rows to `EvoGit.AgentScheduler.rebuild_subagent_batch/3`, and
  `EvoGit.AgentScheduler.SubagentRebuild` installs exactly the scheduler state a
  live batch would have.

  Contract pinned here:

    * a `:done` slot contributes its stored result with NO registration and NO
      re-spawn (no cost paid twice);
    * a `:running` slot is re-spawned under its PERSISTED `agent_id` with its
      persisted spawn position and a spec carrying the resume opts — never a
      fresh id;
    * a `:fresh` slot (a child the pause froze BEFORE it registered) is spawned
      through the same path but WITHOUT an `:agent_id` opt, carrying only its
      batch position, so the scheduler mints its id like the original spawn;
    * a `:missing` slot answers `{:error, :subagent_result_lost}`;
    * slots are ordered by `spawn_index` (model call order), not by the order
      they arrive in;
    * a permanently failing re-spawn stores a terminal `{:error, reason}` for its
      slot, so the batch still resolves (never a hang, never a silent drop);
    * an in-flight batch is refused instead of clobbered.

  ## Why `async: true`

  No session, worktree or app-env seam is involved: the spawn half is injected
  through the explicit `:spawn_fun` option, and every fixture is a
  `%SchedMeta{}` row under this module's OWN ids (9500-9509, deleted in
  `on_exit`), exactly like `subagent_reattach_test.exs`. Nothing is asserted
  about table size and no test reuses another module's ids.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Resume.RosterBatch
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State, as: SchedulerState
  alias EvoGit.AgentScheduler.SubagentRebuild
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @parent 9500
  @child_a 9501
  @child_b 9502
  @child_c 9503
  @all_ids Enum.to_list(9500..9509)

  @turn 4
  @lost {:error, :subagent_result_lost}

  setup do
    on_exit(fn ->
      for id <- @all_ids do
        :ets.delete(:evogit_sched_meta, id)
        :ets.delete(:evogit_agent_summary, id)
      end
    end)

    :ok
  end

  # --- Fixtures ---

  defp sched_meta(id, attrs) do
    base = %SchedMeta{
      id: id,
      depth: 1,
      parent_id: nil,
      task_id: "rebuild-task",
      task_number: 1,
      worktree: "/tmp/rebuild_wt",
      status: :running,
      total_sub_specs: 0,
      sub_agent_results: %{},
      sub_agent_indices: %{},
      pending_sub_agents: MapSet.new(),
      spec: %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/test"},
        phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "abc", current_commit: "abc"},
        agent_module: nil,
        objective: "rebuild test",
        repo_id: "primary"
      }
    }

    struct(base, attrs)
  end

  defp put_parent(attrs \\ []) do
    :ets.insert(:evogit_sched_meta, {@parent, sched_meta(@parent, attrs)})
    :ok
  end

  defp row(id), do: :ets.lookup_element(:evogit_sched_meta, id, 2)

  defp child_spec(agent_id) do
    %AgentSpec{
      context_node: %ContextNode{path: "./src", repo: "/test"},
      phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "base", current_commit: "base"},
      agent_module: EvoGit.Agents.Executor,
      objective: "child #{agent_id}",
      repo_id: "primary",
      opts: [resume_agent_id: agent_id, restore_agent_state: true]
    }
  end

  # A child that never registered before the pause: a first-spawn spec, so it
  # carries NO resume identity.
  defp fresh_spec do
    %AgentSpec{
      context_node: %ContextNode{path: "./doc", repo: "/test"},
      phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "base", current_commit: "base"},
      agent_module: EvoGit.Agents.Executor,
      objective: "fresh child",
      repo_id: "primary",
      opts: [persistent_state: true]
    }
  end

  defp done_entry(index, agent_id, result) do
    %{index: index, status: :done, agent_id: agent_id, result: {:ok, result}, spec: nil}
  end

  defp running_entry(index, agent_id) do
    %{index: index, status: :running, agent_id: agent_id, result: nil, spec: child_spec(agent_id)}
  end

  defp missing_entry(index) do
    %{index: index, status: :missing, agent_id: nil, result: nil, spec: nil}
  end

  defp plan(entries) do
    %{turn: @turn, expected_count: length(entries), entries: entries}
  end

  defp from, do: {self(), make_ref()}

  defp result_a, do: %Result{result: "a", commit_sha: "c-9501"}

  # A spawn seam that records the call and reports the child under the id the
  # plan carried.
  defp recording_spawn do
    test_pid = self()

    fn state, meta, entry, registration_opts ->
      send(test_pid, {:spawned, entry.index, entry.agent_id, registration_opts, entry.spec})
      send(test_pid, {:spawned_for, meta.id})
      {:ok, entry.agent_id, state}
    end
  end

  # --- (1) a done slot costs nothing ---

  test "a finished child contributes its stored result without any re-spawn" do
    put_parent()
    stored = %Result{result: "child done", commit_sha: "sha-9501", branch: "b-9501"}
    entries = [done_entry(0, @child_a, stored)]

    test_pid = self()

    never_spawn = fn _state, _meta, entry, _registration_opts ->
      send(test_pid, {:spawned, entry.index})
      {:ok, entry.agent_id, %SchedulerState{}}
    end

    assert {:reply, {:ok, [ordered]}, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: never_spawn],
               %SchedulerState{}
             )

    assert ordered == {:ok, stored}
    refute_received {:spawned, _index}

    # Nothing pending: no waiter, no timer, and the row is cleared.
    assert state.reattach_waiters == %{}
    assert state.reattach_timers == %{}

    cleared = row(@parent)
    assert cleared.status == :running
    assert cleared.total_sub_specs == 0
    assert cleared.sub_agent_results == %{}
    assert cleared.sub_agent_indices == %{}
  end

  # --- (2) a running slot re-spawns under its persisted identity ---

  test "a still-running child is re-spawned under its persisted id and position" do
    put_parent()
    entries = [running_entry(0, @child_a)]
    waiter = from()

    assert {:noreply, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               waiter,
               [spawn_fun: recording_spawn()],
               %SchedulerState{}
             )

    # The persisted id travels as the registration id — never a fresh one — and
    # the spawn position is the slot's own index/turn.
    assert_received {:spawned, 0, @child_a, registration_opts, spec}
    assert registration_opts[:agent_id] == @child_a
    assert registration_opts[:spawn_index] == 0
    assert registration_opts[:spawn_turn] == @turn
    assert spec.opts[:resume_agent_id] == @child_a
    assert spec.opts[:restore_agent_state] == true

    # The caller is the batch's waiter, exactly like a live spawn.
    assert state.reattach_waiters[@parent] == waiter
    assert {token, timer_ref} = state.reattach_timers[@parent]
    assert is_reference(token) and is_reference(timer_ref)

    waiting = row(@parent)
    assert waiting.status == :waiting
    assert waiting.total_sub_specs == 1
    assert waiting.sub_agent_from == waiter
    assert waiting.sub_agent_indices == %{@child_a => 0}
    assert waiting.pending_sub_agents == MapSet.new([@child_a])
    assert waiting.sub_agent_results == %{}
  end

  # --- (3) an expected slot with no durable row is honestly lost ---

  test "a slot with no durable row answers :subagent_result_lost" do
    put_parent()
    entries = [missing_entry(0)]

    assert {:reply, {:ok, [@lost]}, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: recording_spawn()],
               %SchedulerState{}
             )

    refute_received {:spawned, _index, _id, _opts, _spec}
    assert state.reattach_waiters == %{}
    assert row(@parent).total_sub_specs == 0
  end

  # --- (4) model call order, not arrival order ---

  test "slots are ordered by spawn_index, not by the order they arrive in" do
    put_parent()

    first = %Result{result: "first", commit_sha: "c-9501"}
    second = %Result{result: "second", commit_sha: "c-9502"}

    entries = [
      done_entry(1, @child_b, second),
      done_entry(0, @child_a, first)
    ]

    assert {:reply, {:ok, [ordered_first, ordered_second]}, _state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: recording_spawn()],
               %SchedulerState{}
             )

    assert ordered_first == {:ok, first}
    assert ordered_second == {:ok, second}
  end

  test "re-spawns happen in slot order even when the plan lists them backwards" do
    put_parent()

    entries = [
      running_entry(1, @child_b),
      running_entry(0, @child_a)
    ]

    assert {:noreply, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: recording_spawn()],
               %SchedulerState{}
             )

    assert_received {:spawned, 0, @child_a, _opts_a, _spec_a}
    assert_received {:spawned, 1, @child_b, _opts_b, _spec_b}
    assert state.reattach_waiters != %{}

    waiting = row(@parent)
    assert waiting.sub_agent_indices == %{@child_a => 0, @child_b => 1}
    assert waiting.pending_sub_agents == MapSet.new([@child_a, @child_b])
  end

  # --- (5) a done slot + a running slot resolve together ---

  test "a mixed batch installs the done result and waits only for the re-spawned child" do
    put_parent()
    stored = %Result{result: "already done", commit_sha: "c-9501"}
    entries = [done_entry(0, @child_a, stored), running_entry(1, @child_b)]

    assert {:noreply, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: recording_spawn()],
               %SchedulerState{}
             )

    assert_received {:spawned, 1, @child_b, _opts, _spec}

    waiting = row(@parent)
    assert waiting.total_sub_specs == 2
    assert waiting.sub_agent_results == %{0 => {:ok, stored}}
    assert waiting.sub_agent_indices == %{@child_b => 1}
    assert waiting.pending_sub_agents == MapSet.new([@child_b])
    assert state.reattach_waiters != %{}
  end

  # --- (6) a permanently failing re-spawn never hangs the batch ---

  test "a failing re-spawn stores a terminal error and the batch still resolves" do
    put_parent()
    entries = [running_entry(0, @child_a)]

    failing = fn state, _meta, _entry, _registration_opts ->
      {:error, {:agent_id_taken, @child_a}, state}
    end

    assert {:reply, {:ok, [slot]}, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: failing],
               %SchedulerState{}
             )

    assert slot == {:error, {:agent_id_taken, @child_a}}
    assert state.reattach_waiters == %{}
    assert row(@parent).total_sub_specs == 0
  end

  test "a RAISING re-spawn is contained into a terminal error for its slot" do
    put_parent()
    entries = [running_entry(0, @child_a)]

    raising = fn _state, _meta, _entry, _registration_opts -> raise "kaboom" end

    assert {:reply, {:ok, [slot]}, _state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: raising],
               %SchedulerState{}
             )

    assert {:error, {:spawn_failed, message}} = slot
    assert message =~ "kaboom"
  end

  # --- (6b) a :fresh slot was frozen BEFORE it registered ---
  test "a :fresh slot is spawned WITHOUT an :agent_id opt but WITH its batch position" do
    put_parent()
    fresh = %{index: 0, status: :fresh, agent_id: nil, result: nil, spec: fresh_spec()}
    test_pid = self()

    allocating = fn state, _meta, entry, registration_opts ->
      send(test_pid, {:spawned, entry.index, registration_opts, entry.spec})
      # The scheduler mints the id, exactly as the original spawn would.
      {:ok, @child_b, state}
    end

    assert {:noreply, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan([fresh]),
               5_000,
               from(),
               [spawn_fun: allocating],
               %SchedulerState{}
             )

    assert_received {:spawned, 0, registration_opts, spec}
    # NO id: the child never registered before the pause, so it must be a FIRST
    # spawn, not a resume under a stale identity.
    refute Keyword.has_key?(registration_opts, :agent_id)
    assert registration_opts[:spawn_index] == 0
    assert registration_opts[:spawn_turn] == @turn
    assert %AgentSpec{} = spec
    waiting = row(@parent)
    assert waiting.status == :waiting
    assert waiting.sub_agent_indices == %{@child_b => 0}
    assert waiting.pending_sub_agents == MapSet.new([@child_b])
    assert state.reattach_waiters != %{}
  end

  test "a mixed done/running/fresh batch counts every slot and resolves each one" do
    put_parent()
    stored = %Result{result: "already done", commit_sha: "c-9501"}

    entries = [
      done_entry(0, @child_a, stored),
      running_entry(1, @child_c),
      %{index: 2, status: :fresh, agent_id: nil, result: nil, spec: fresh_spec()}
    ]

    test_pid = self()

    spawning = fn state, _meta, entry, registration_opts ->
      send(test_pid, {:spawned, entry.index, registration_opts})
      id = if entry.status == :fresh, do: @child_b, else: entry.agent_id
      {:ok, id, state}
    end

    assert {:noreply, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan(entries),
               5_000,
               from(),
               [spawn_fun: spawning],
               %SchedulerState{}
             )

    # `:running` keeps its id, `:fresh` arrives without one.
    assert_received {:spawned, 1, running_opts}
    assert running_opts[:agent_id] == @child_c
    assert_received {:spawned, 2, fresh_opts}
    refute Keyword.has_key?(fresh_opts, :agent_id)
    waiting = row(@parent)
    # ONE expected count over the WHOLE batch, every slot accounted for.
    assert waiting.total_sub_specs == 3
    assert waiting.sub_agent_results == %{0 => {:ok, stored}}
    assert waiting.sub_agent_indices == %{@child_c => 1, @child_b => 2}
    assert waiting.pending_sub_agents == MapSet.new([@child_c, @child_b])
    assert map_size(waiting.sub_agent_results) + MapSet.size(waiting.pending_sub_agents) == 3
    assert state.reattach_waiters != %{}
  end

  # --- (7) refusals never touch the row ---

  test "no SchedMeta row, an in-flight batch and a malformed plan are all refused" do
    # No row at all.
    assert {:reply, {:error, :no_pending_batch}, _state} =
             SubagentRebuild.handle_rebuild(
               @child_c,
               plan([done_entry(0, @child_a, result_a())]),
               5_000,
               from(),
               [],
               %SchedulerState{}
             )

    # A batch already in flight must never be clobbered.
    put_parent(total_sub_specs: 1, sub_agent_indices: %{@child_c => 0})
    before = row(@parent)
    state = %SchedulerState{}

    assert {:reply, {:error, :batch_in_flight}, ^state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan([done_entry(0, @child_a, result_a())]),
               5_000,
               from(),
               [spawn_fun: recording_spawn()],
               state
             )

    assert row(@parent) == before
    refute_received {:spawned, _index, _id, _opts, _spec}

    # A malformed plan: slot count mismatch, non-integer turn, unknown status.
    put_parent()

    malformed = [
      %{turn: @turn, expected_count: 2, entries: [done_entry(0, @child_a, result_a())]},
      %{turn: "four", expected_count: 1, entries: [missing_entry(0)]},
      %{turn: @turn, expected_count: 1, entries: [%{index: 0, status: :stale}]},
      :not_a_plan
    ]

    for bad <- malformed do
      assert {:reply, {:error, :invalid_plan}, _state} =
               SubagentRebuild.handle_rebuild(
                 @parent,
                 bad,
                 5_000,
                 from(),
                 [spawn_fun: recording_spawn()],
                 %SchedulerState{}
               )
    end

    assert row(@parent).total_sub_specs == 0
  end

  # --- (8) the two halves together: a plan from the durable roster ---

  test "a plan built from the durable roster re-spawns the child with its resume opts" do
    put_parent(depth: 0)

    parent_state = %State{
      agent_id: @parent,
      agent_module: EvoGit.Agents.Executor,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([]),
      task_id: "rebuild-task",
      persistent_state: true,
      repo_id: "primary",
      repo_path: "/tmp/rebuild-repo"
    }

    row_for(@child_a,
      status: "running",
      parent_id: @parent,
      spawn_turn: @turn,
      spawn_index: 0,
      agent_module: EvoGit.Agents.Executor,
      objective: "child objective",
      base_commit: "base-9501",
      current_commit: "commit-9501",
      branch: "genesis/agent_9501",
      anchor_ref: "refs/genesis/agent-state/rebuild-task/9501",
      node_path: "./src",
      repo_id: "primary"
    )

    assert {:ok, plan} = RosterBatch.plan(parent_state, @turn, 1, roster_fun: &roster/1)

    assert {:noreply, state} =
             SubagentRebuild.handle_rebuild(
               @parent,
               plan,
               5_000,
               from(),
               [spawn_fun: listing_spawn()],
               %SchedulerState{}
             )

    assert_received {:spawned, 0, @child_a, registration_opts, spec}

    # Identity + instance: the child continues ITS OWN run.
    assert registration_opts[:agent_id] == @child_a
    assert spec.opts[:resume_agent_id] == @child_a
    assert spec.opts[:resume_current_commit] == "commit-9501"
    assert spec.opts[:resume_branch] == "genesis/agent_9501"
    assert spec.opts[:resume_anchor_ref] == "refs/genesis/agent-state/rebuild-task/9501"
    assert spec.opts[:restore_agent_state] == true
    assert spec.opts[:persistent_state] == true
    # A child never carries a task-level pause kind.
    refute Keyword.has_key?(spec.opts, :resume_kind)

    assert row(@parent).pending_sub_agents == MapSet.new([@child_a])
    assert state.reattach_waiters != %{}
  end

  defp listing_spawn do
    test_pid = self()

    fn state, _meta, entry, registration_opts ->
      send(test_pid, {:spawned, entry.index, entry.agent_id, registration_opts, entry.spec})
      {:ok, entry.agent_id, state}
    end
  end

  defp roster(task_id) do
    Process.get({__MODULE__, :roster, task_id}, [])
  end

  defp row_for(agent_id, fields) do
    record = %Record{task_id: "rebuild-task", agent_id: agent_id, fields: Map.new(fields)}
    Process.put({__MODULE__, :roster, "rebuild-task"}, [record | roster("rebuild-task")])
    record
  end
end
