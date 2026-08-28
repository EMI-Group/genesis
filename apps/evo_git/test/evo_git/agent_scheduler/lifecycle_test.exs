defmodule EvoGit.AgentScheduler.LifecycleTest do
  @moduledoc """
  Tests for the crash-retry logic in `EvoGit.AgentScheduler.Lifecycle.handle_agent_crash/3`,
  the cancellation logic in `cancel_agent/2`, and the defensive handling for missing ETS entries.

  Uses `async: false` because the tests manipulate global named ETS tables
  (`:evogit_agent_state` and `:evogit_sched_meta`).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Subagents
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
    # Start from a per-model pool state (single default model)
    profiles = [%{id: "default", model: "test:model", concurrency: 3}]

    base =
      State.from_model_profiles(profiles)
      |> struct!(paused: true, agent_max_retries: 3, ref_to_agent: %{make_ref() => 1})

    struct!(base, overrides)
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

    if :ets.whereis(:evogit_cancelling_tasks) != :undefined,
      do: :ets.delete_all_objects(:evogit_cancelling_tasks)
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
    create_ets_if_missing(:evogit_cancelling_tasks)
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

  describe "worktree ownership transfer — lifecycle cleanup does NOT delete worktrees" do
    setup do
      repo_root =
        Path.join(System.tmp_dir!(), "lifecycle_own_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(repo_root)
      {:ok, _} = Git.init(repo_root)
      File.write!(Path.join(repo_root, "README.md"), "initial")
      {:ok, _} = Git.add(repo_root)
      {:ok, _} = Git.commit(repo_root, "initial")
      {:ok, base_sha} = Git.rev_parse(repo_root)
      on_exit(fn -> File.rm_rf!(repo_root) end)
      %{repo_root: repo_root, base_sha: base_sha}
    end

    defp make_worktree(repo_root, base_sha) do
      branch = "evogit-agent-T1-A1"
      wt_path = Path.join(repo_root, ".genesis/workers/worker_T1_A1")
      {:ok, _} = Git.create_branch(repo_root, branch, base_sha)
      File.mkdir_p!(wt_path)
      File.write!(Path.join(wt_path, "marker.txt"), "stale")
      %{branch: branch, wt_path: wt_path}
    end

    test "recycle_agent removes ETS entries but leaves the worktree dir and branch intact", %{
      repo_root: repo_root,
      base_sha: base_sha
    } do
      agent_id = :erlang.unique_integer([:positive])
      %{branch: branch, wt_path: wt_path} = make_worktree(repo_root, base_sha)

      put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        worktree: wt_path
      })

      put_agent_state(agent_id, %AgentState{
        agent_state()
        | repo_root: repo_root,
          task_local_id: 1
      })

      state = base_state([])
      assert Lifecycle.recycle_agent(state, agent_id) == state

      assert get_sched_meta(agent_id) == :missing
      assert get_agent_state(agent_id) == :missing
      assert File.dir?(wt_path)
      assert Git.branch_exists?(repo_root, branch)
    end

    test "cancel_agent kills the task but leaves the worktree dir and branch intact", %{
      repo_root: repo_root,
      base_sha: base_sha
    } do
      agent_id = :erlang.unique_integer([:positive])
      %{branch: branch, wt_path: wt_path} = make_worktree(repo_root, base_sha)

      task = Task.async(fn -> Process.sleep(10_000) end)

      put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        task_ref: task,
        from: nil,
        worktree: wt_path
      })

      put_agent_state(agent_id, %AgentState{
        agent_state()
        | repo_root: repo_root,
          task_local_id: 1
      })

      state = base_state([])
      assert Lifecycle.cancel_agent(state, agent_id) == state

      Process.sleep(50)
      refute Process.alive?(task.pid)

      assert get_sched_meta(agent_id) == :missing
      assert get_agent_state(agent_id) == :missing
      assert File.dir?(wt_path)
      assert Git.branch_exists?(repo_root, branch)
    end

    test "handle_agent_crash permanent-failure leaves the worktree dir and branch intact", %{
      repo_root: repo_root,
      base_sha: base_sha
    } do
      agent_id = :erlang.unique_integer([:positive])
      %{branch: branch, wt_path: wt_path} = make_worktree(repo_root, base_sha)

      ref = make_ref()

      put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 3,
        from: {self(), ref},
        task_id: "t-own",
        worktree: wt_path
      })

      put_agent_state(agent_id, %AgentState{
        agent_state()
        | repo_root: repo_root,
          task_local_id: 1
      })

      state = base_state(agent_max_retries: 3)
      assert {:noreply, _} = Lifecycle.handle_agent_crash(state, agent_id, {:error, :final})
      assert_received {^ref, {:error, :agent_max_retries_exceeded}}

      assert get_sched_meta(agent_id) == :missing
      assert get_agent_state(agent_id) == :missing
      assert File.dir?(wt_path)
      assert Git.branch_exists?(repo_root, branch)
    end
  end

  describe "handle_call({:force_kill_task_agents, _}, _, _)" do
    test "filters cancelled agents from the dispatch queue without crashing" do
      caller_pid = self()
      caller_ref = make_ref()
      task_id = "42"

      # Spawn real long-running tasks for each agent that will be cancelled.
      # Lifecycle.cancel_agent/2 calls Task.shutdown/2 on the stored task_ref.
      tasks =
        Enum.map(1..3, fn _ -> Task.async(fn -> Process.sleep(:infinity) end) end)

      # A separate process whose pid is distinct from self() so that the
      # caller_pid scan in the handler does NOT match this agent.
      dummy_caller = spawn(fn -> Process.sleep(:infinity) end)

      try do
        [task1, task2, task3] = tasks

        # Agent 1: top-level (depth: 0) whose `from` contains caller_pid.
        # This is the entry point the handler keys off of.
        meta1 = %SchedMeta{
          id: 1,
          depth: 0,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          from: {caller_pid, caller_ref},
          task_ref: task1
        }

        # Agent 2: subagent (depth: 1) sharing the same task_id.
        meta2 = %SchedMeta{
          id: 2,
          depth: 1,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          parent_id: 1,
          task_ref: task2
        }

        # Agent 3: another subagent (depth: 2) sharing the same task_id.
        meta3 = %SchedMeta{
          id: 3,
          depth: 2,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          parent_id: 2,
          task_ref: task3
        }

        # Agent 4: belongs to a DIFFERENT task_id — must NOT be cancelled.
        # Its `from` uses dummy_caller (a different pid) so it isn't matched by
        # the caller_pid scan (ETS tab2list order is unspecified).
        meta4 = %SchedMeta{
          id: 4,
          depth: 0,
          spec: agent_spec(),
          retries: 0,
          task_id: "99",
          from: {dummy_caller, make_ref()},
          task_ref: nil
        }

        put_sched_meta(1, meta1)
        put_sched_meta(2, meta2)
        put_sched_meta(3, meta3)
        put_sched_meta(4, meta4)

        # Put all four agent IDs into the dispatch queue.
        state =
          base_state([])
          |> then(fn s -> %{s | queue: Enum.reduce([1, 2, 3, 4], s.queue, &:queue.in/2)} end)

        from = {self(), make_ref()}

        # The old (buggy) code raised ArgumentError here because :queue.filter/2
        # was called with the queue as the first argument instead of the function.
        assert {:reply, :ok, new_state} =
                 AgentScheduler.handle_call({:force_kill_task_agents, caller_pid}, from, state)

        # Agents 1-3 are removed from the queue; agent 4 (different task) survives.
        assert :queue.to_list(new_state.queue) == [4]

        # Cancelled agents are deleted from ETS.
        assert get_sched_meta(1) == :missing
        assert get_sched_meta(2) == :missing
        assert get_sched_meta(3) == :missing

        # The unrelated agent's metadata is untouched.
        assert {:ok, ^meta4} = get_sched_meta(4)
      after
        # Clean up spawned tasks (Task.shutdown is idempotent if already killed).
        Enum.each(tasks, fn task ->
          Task.shutdown(task, :brutal_kill)
        end)

        # Clean up the dummy caller process used for the unrelated agent.
        Process.exit(dummy_caller, :kill)
      end
    end

    test "releases LLM/tool slots held by cancelled agents" do
      caller_pid = self()
      caller_ref = make_ref()
      task_id = "42"

      # Spawn real long-running tasks for each agent that will be cancelled.
      tasks =
        Enum.map(1..2, fn _ -> Task.async(fn -> Process.sleep(:infinity) end) end)

      try do
        [task1, task2] = tasks

        # Agent 1: top-level (depth: 0) whose `from` contains caller_pid.
        meta1 = %SchedMeta{
          id: 1,
          depth: 0,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          from: {caller_pid, caller_ref},
          task_ref: task1
        }

        # Agent 2: subagent (depth: 1) sharing the same task_id.
        meta2 = %SchedMeta{
          id: 2,
          depth: 1,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          parent_id: 1,
          task_ref: task2
        }

        put_sched_meta(1, meta1)
        put_sched_meta(2, meta2)

        # Simulate both agents holding LLM and tool slots at the time of
        # cancellation.
        state =
          base_state(
            llm_holders: %{"default" => MapSet.new([1, 2])},
            tool_holders: MapSet.new([1, 2]),
            llm_last_granted: %{"default" => %{1 => 1_000, 2 => 2_000}}
          )

        from = {self(), make_ref()}

        assert {:reply, :ok, new_state} =
                 AgentScheduler.handle_call({:force_kill_task_agents, caller_pid}, from, state)

        # The cancelled agents must be removed from both holder sets so that
        # the slots are returned to the pool (no permanent leak).
        default_holders = State.holders_for(new_state, "default")
        refute MapSet.member?(default_holders, 1)
        refute MapSet.member?(default_holders, 2)
        refute MapSet.member?(new_state.tool_holders, 1)
        refute MapSet.member?(new_state.tool_holders, 2)

        # llm_last_granted entries for cancelled agents are also cleaned up.
        default_last_granted = State.last_granted_for(new_state, "default")
        refute Map.has_key?(default_last_granted, 1)
        refute Map.has_key?(default_last_granted, 2)

        assert default_holders == MapSet.new()
        assert new_state.tool_holders == MapSet.new()
      after
        Enum.each(tasks, fn task ->
          Task.shutdown(task, :brutal_kill)
        end)
      end
    end
  end

  describe "graceful cancel — begin_graceful_cancel / clear_cancelling_task / run_agent guard" do
    test "begin_graceful_cancel registers the task marker and notifies all agents of the task" do
      task_id = "graceful-42"
      caller_pid = self()

      # Agent 1: top-level (depth 0); Agent 2: subagent (depth 1) — same task.
      put_sched_meta(1, %SchedMeta{
        id: 1,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        task_id: task_id,
        from: {caller_pid, make_ref()}
      })

      put_sched_meta(2, %SchedMeta{
        id: 2,
        depth: 1,
        spec: agent_spec(),
        retries: 0,
        task_id: task_id,
        parent_id: 1
      })

      # Agent 3 belongs to a DIFFERENT task — must NOT be notified.
      put_sched_meta(3, %SchedMeta{
        id: 3,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        task_id: "other",
        from: {caller_pid, make_ref()}
      })

      for id <- [1, 2, 3], do: put_agent_state(id, agent_state())

      state = base_state([])
      from = {self(), make_ref()}

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call({:begin_graceful_cancel, task_id}, from, state)

      # Marker registered.
      assert :ets.member(:evogit_cancelling_tasks, task_id)

      # Agents 1 & 2 got the cancel message + cancel_requested flag.
      for id <- [1, 2] do
        {:ok, st} = get_agent_state(id)
        assert st.cancel_requested == true, "agent #{id} cancel_requested not set"
        assert Enum.any?(st.pending_user_messages, &String.contains?(&1, "being cancelled"))
      end

      # Agent 3 (different task) untouched.
      {:ok, st3} = get_agent_state(3)
      assert st3.cancel_requested != true
      assert st3.pending_user_messages == []
    end

    test "begin_graceful_cancel with no agents still registers the marker" do
      task_id = "graceful-empty"
      state = base_state([])
      from = {self(), make_ref()}

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call({:begin_graceful_cancel, task_id}, from, state)

      assert :ets.member(:evogit_cancelling_tasks, task_id)
    end

    test "clear_cancelling_task removes the task from the marker" do
      task_id = "graceful-clear"
      :ets.insert(:evogit_cancelling_tasks, {task_id})
      state = base_state([])
      from = {self(), make_ref()}

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call({:clear_cancelling_task, task_id}, from, state)

      refute :ets.member(:evogit_cancelling_tasks, task_id)

      # Idempotent — clearing a non-member is a no-op.
      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call({:clear_cancelling_task, task_id}, from, state)
    end

    test "run_agent replies {:error, :cancelled} immediately for a cancelling task" do
      task_id = "graceful-blocked"
      :ets.insert(:evogit_cancelling_tasks, {task_id})

      spec = %{agent_spec() | opts: [task_id: task_id]}

      state = base_state([])
      from = {self(), make_ref()}

      assert {:reply, {:error, :cancelled}, ^state} =
               AgentScheduler.handle_call({:run_agent, spec}, from, state)

      # No agent was registered.
      assert :ets.info(:evogit_sched_meta, :size) == 0
      assert :ets.info(:evogit_agent_state, :size) == 0
    end

    test "Dispatch.register_agent puts a newly registered agent of a cancelling task into grace" do
      task_id = "graceful-reg"
      :ets.insert(:evogit_cancelling_tasks, {task_id})

      state = base_state([])
      spec = agent_spec()

      {agent_id, _new_state} =
        EvoGit.AgentScheduler.Dispatch.register_agent(
          state,
          spec,
          {self(), make_ref()},
          nil,
          0,
          task_id,
          1
        )

      {:ok, st} = get_agent_state(agent_id)
      assert st.cancel_requested == true
      assert Enum.any?(st.pending_user_messages, &String.contains?(&1, "being cancelled"))
    end

    test "Dispatch.register_agent does not touch agents of non-cancelling tasks" do
      task_id = "graceful-reg-other"

      state = base_state([])
      spec = agent_spec()

      {agent_id, _new_state} =
        EvoGit.AgentScheduler.Dispatch.register_agent(
          state,
          spec,
          {self(), make_ref()},
          nil,
          0,
          task_id,
          1
        )

      {:ok, st} = get_agent_state(agent_id)
      assert st.cancel_requested != true
      assert st.pending_user_messages == []
    end
  end

  describe "increment_compression_count/1" do
    test "increments compression_count in the agent state table" do
      agent_id = 1
      put_agent_state(agent_id, agent_state())

      AgentScheduler.increment_compression_count(agent_id)

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.compression_count == 1

      AgentScheduler.increment_compression_count(agent_id)

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.compression_count == 2
    end

    test "defaults to 0 on a freshly constructed AgentState" do
      assert agent_state().compression_count == 0
    end

    test "raises when the agent state is missing" do
      # The agent MUST exist — a missing entry indicates a deep bug.
      assert_raise MatchError, fn ->
        AgentScheduler.increment_compression_count(999_999)
      end
    end
  end

  describe "update_total_tokens/2" do
    test "updates total_tokens in the agent state table" do
      agent_id = 1
      put_agent_state(agent_id, agent_state())

      AgentScheduler.update_total_tokens(agent_id, 5000)

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.total_tokens == 5000

      AgentScheduler.update_total_tokens(agent_id, 12_000)

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.total_tokens == 12_000
    end

    test "defaults to 0 on a freshly constructed AgentState" do
      assert agent_state().total_tokens == 0
    end

    test "raises when the agent state is missing" do
      # The agent MUST exist — a missing entry indicates a deep bug.
      assert_raise MatchError, fn ->
        AgentScheduler.update_total_tokens(999_999, 100)
      end
    end
  end

  describe "store_sub_result/3 — 3-level foreign-repo-commits roll-up" do
    # Seeds a SchedMeta row for an agent that has spawned subagents, carrying
    # the given pre-accumulated foreign repo commits.
    defp frc_sched_meta(agent_id, sub_indices, frc) do
      %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        sub_agent_indices: sub_indices,
        sub_agent_results: %{},
        foreign_repo_commits: frc
      }
    end

    test "rolls up foreign-repo commits across three levels, child wins for shared keys" do
      # 3-level tree: root agent1 -> sub-manager agent2 -> executor agent3.
      agent1 = 101
      agent2 = 102
      agent3 = 103

      # agent1 already has its OWN direct foreign work on "foreign1" before
      # delegating — a pre-existing entry the deeper subtree view must override.
      put_sched_meta(
        agent1,
        frc_sched_meta(agent1, %{agent2 => 0}, %{"foreign1" => "agent1_sha"})
      )

      put_sched_meta(agent2, frc_sched_meta(agent2, %{agent3 => 0}, %{}))

      # Level 3: the executor completes with its own foreign-repo commit.
      Subagents.store_sub_result(
        agent2,
        agent3,
        {:ok,
         %Result{
           result: "exec done",
           commit_sha: nil,
           foreign_repo_commits: %{"foreign1" => "exec_sha"}
         }}
      )

      {:ok, agent2_meta} = get_sched_meta(agent2)
      assert agent2_meta.foreign_repo_commits == %{"foreign1" => "exec_sha"}

      # Level 2: the sub-manager completes. Its completion result carries BOTH
      # its subtree view (agent3's commits, as injected by Lifecycle) AND its
      # own direct foreign work (commit_sha "mid_sha" on repo "foreign2").
      result2 =
        {:ok,
         %Result{
           result: "mid done",
           commit_sha: "mid_sha",
           repo_id: "foreign2",
           foreign_repo_commits: %{"foreign1" => "exec_sha"}
         }}

      Subagents.store_sub_result(agent1, agent2, result2)

      {:ok, agent1_meta} = get_sched_meta(agent1)
      # Map.merge is child-wins: agent2's subtree view (carrying agent3's deeper
      # "exec_sha") overrides agent1's own "agent1_sha" for "foreign1", while the
      # direct commit on "foreign2" is recorded via Map.put.
      assert agent1_meta.foreign_repo_commits == %{
               "foreign1" => "exec_sha",
               "foreign2" => "mid_sha"
             }

      # Root reply: Lifecycle.inject_foreign_repo_commits replaces the result's
      # field with the accumulated subtree map from sched_meta.
      root_result =
        Lifecycle.inject_foreign_repo_commits(
          {:ok, %Result{result: "root done", commit_sha: nil}},
          agent1_meta.foreign_repo_commits
        )

      assert {:ok, %Result{} = root} = root_result
      # Use Map.get — the field may be absent in some result shapes.
      assert Map.get(root, :foreign_repo_commits) ==
               %{"foreign1" => "exec_sha", "foreign2" => "mid_sha"}
    end
  end

  describe "archive record collection" do
    setup do
      # The app owns :evogit_archive_records — create it only if missing, and
      # only clear its contents for isolation (never delete the table itself).
      create_ets_if_missing(:evogit_archive_records)

      if :ets.whereis(:evogit_archive_records) != :undefined do
        :ets.delete_all_objects(:evogit_archive_records)
      end

      on_exit(fn ->
        if :ets.whereis(:evogit_archive_records) != :undefined do
          :ets.delete_all_objects(:evogit_archive_records)
        end
      end)

      :ok
    end

    test "collect_archive_records is scoped per task" do
      :ets.insert(:evogit_archive_records, {{"t1", "a1"}, %{agent_id: "a1", task: "t1"}})
      :ets.insert(:evogit_archive_records, {{"t2", "b1"}, %{agent_id: "b1", task: "t2"}})

      assert Lifecycle.collect_archive_records("t1") == [%{agent_id: "a1", task: "t1"}]

      assert Lifecycle.clear_archive_records("t1") == :ok
      assert Lifecycle.collect_archive_records("t1") == []

      # The other task's records are untouched.
      assert Lifecycle.collect_archive_records("t2") == [%{agent_id: "b1", task: "t2"}]
    end

    test "handle_task_result collects and clears per-task archive records at root completion" do
      ref = make_ref()
      from_ref = make_ref()
      from = {self(), from_ref}

      put_sched_meta("root1", %SchedMeta{
        id: "root1",
        depth: 0,
        spec: agent_spec(),
        task_id: "t1",
        parent_id: nil,
        from: from,
        result_sent: false
      })

      # One archive record for task "t1" (consumed at completion) plus a control
      # record for a different task ("t2") that must survive.
      :ets.insert(:evogit_archive_records, {{"t1", "a1"}, %{agent_id: "a1"}})
      :ets.insert(:evogit_archive_records, {{"t2", "b1"}, %{agent_id: "b1"}})

      state =
        base_state([])
        |> struct!(ref_to_agent: %{ref => "root1"}, task_agent_counts: %{"t1" => 1})

      assert {:noreply, _} =
               Lifecycle.handle_task_result(
                 ref,
                 {:ok, %EvoGit.Agent.Result{result: "done", commit_sha: "abc"}},
                 state
               )

      assert_receive {^from_ref, {:ok, %EvoGit.Agent.Result{archive_records: records}}}
      assert length(records) == 1
      assert hd(records).agent_id == "a1"

      # The successful collection CONSUMED the task's records…
      assert Lifecycle.collect_archive_records("t1") == []

      # …but the other task's control record is untouched.
      assert [%{agent_id: "b1"}] = Lifecycle.collect_archive_records("t2")
    end

    test "handle_task_result does NOT clear archive records on error results" do
      ref = make_ref()
      from_ref = make_ref()
      from = {self(), from_ref}

      put_sched_meta("root2", %SchedMeta{
        id: "root2",
        depth: 0,
        spec: agent_spec(),
        task_id: "t3",
        parent_id: nil,
        from: from,
        result_sent: false
      })

      :ets.insert(:evogit_archive_records, {{"t3", "c1"}, %{agent_id: "c1"}})

      state =
        base_state([])
        |> struct!(ref_to_agent: %{ref => "root2"}, task_agent_counts: %{"t3" => 1})

      assert {:noreply, _} =
               Lifecycle.handle_task_result(ref, {:error, :recovery_failed}, state)

      assert_receive {^from_ref, {:error, :recovery_failed}}

      # Non-{:ok, %Result{}} results must NOT consume/clear the collection.
      assert [%{agent_id: "c1"}] = Lifecycle.collect_archive_records("t3")
    end
  end
end
