defmodule EvoGit.AgentSchedulerTest do
  @moduledoc """
  Tests for `EvoGit.AgentScheduler.run_agent/2` scheduling behavior — most
  importantly that scheduling an agent does NOT perform any worktree
  initialization (worktree creation is WorktreeManager's job, requested
  asynchronously by the agent's Runner).

  Uses `async: false` because it pushes configuration to the global
  `EvoGit.AgentScheduler` GenServer and manipulates the shared ETS state.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  defmodule DummyAgent do
    # Sleeps so the in-flight registration is observable. MUST NOT call the
    # Runner or request a worktree — this test pins the scheduler contract.
    def run(_objective, _ctx) do
      Process.sleep(300)
      {:ok, :done}
    end
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, original_timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        Process.sleep(15)
        do_wait_until(fun, deadline, original_timeout)
    end
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"

    model_profiles = GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})
    llm_model = GenServer.call(EvoGit.AgentScheduler, {:get_config, :llm_model})

    assert :ok =
             GenServer.call(
               EvoGit.AgentScheduler,
               {:update_config,
                [
                  model_profiles: [%{id: "default", model: "test:model", concurrency: 1}],
                  llm_model: "test:model"
                ]}
             )

    on_exit(fn ->
      GenServer.call(EvoGit.AgentScheduler, {:update_config, [model_profiles: model_profiles]})

      # update_config rejects a nil llm_model — skip the key when it was nil.
      if llm_model != nil do
        GenServer.call(EvoGit.AgentScheduler, {:update_config, [llm_model: llm_model]})
      end
    end)

    :ok
  end

  test "run_agent schedules the agent without doing any worktree initialization" do
    repo_root =
      Path.join(System.tmp_dir!(), "sched_noinit_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(repo_root)
    {:ok, _} = Git.init(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "initial")
    {:ok, _} = Git.add(repo_root)
    {:ok, _} = Git.commit(repo_root, "initial")
    {:ok, sha} = Git.rev_parse(repo_root)
    on_exit(fn -> File.rm_rf!(repo_root) end)

    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: repo_root},
      phylo_node: %PhyloGraphNode{repo: repo_root, base_commit: sha, current_commit: sha},
      agent_module: DummyAgent,
      objective: "test",
      repo_id: "primary"
    }

    before_ids = MapSet.new(Store.list_sched_meta(), fn {id, _} -> id end)

    caller = Task.async(fn -> EvoGit.AgentScheduler.run_agent(spec, 30_000) end)

    # The agent must be REGISTERED in ETS while the call is still in flight.
    # Old code would block inside handle_call doing worktree I/O instead of
    # replying asynchronously once the agent task completes.
    wait_until(
      fn -> MapSet.new(Store.list_sched_meta(), fn {id, _} -> id end) != before_ids end,
      2000
    )

    # The call RETURNS a result — it does not block on worktree creation.
    assert {:ok, :done} = Task.await(caller, 30_000)

    # The strongest observable: no synchronous worktree initialization —
    # the .genesis/workers dir is never created by the scheduler itself.
    refute File.dir?(Path.join(repo_root, ".genesis/workers"))

    # After the agent task completes normally, the scheduler recycles the
    # agent's ETS entries (worktree reclamation is monitor-driven elsewhere).
    wait_until(
      fn -> MapSet.new(Store.list_sched_meta(), fn {id, _} -> id end) == before_ids end,
      2000
    )
  end

  test "update_config reconciles the LLM pool without crashing" do
    # Hook A: a successful update_config (with model_profiles) reconciles the
    # ReqLLM Finch pool. In test env no origins are materialized, so reconcile
    # no-ops — this pins that the hook never crashes and returns :ok.
    assert :ok =
             GenServer.call(
               EvoGit.AgentScheduler,
               {:update_config,
                [model_profiles: [%{id: "default", model: "test:model", concurrency: 3}]]}
             )

    # The new concurrency took effect. Profile ids are strings, so the
    # "default" key in model_concurrency is the string "default".
    assert %{"default" => 3} =
             GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_concurrency})

    # Fallback path: a default_llm_max_concurrency-only update (no
    # model_profiles) also returns :ok and reconciles via the fallback total.
    assert :ok =
             GenServer.call(
               EvoGit.AgentScheduler,
               {:update_config, [default_llm_max_concurrency: 4]}
             )
  end

  test "get_config map-form includes model_profiles matching the scheduler state" do
    # The map-form return of :get_config mirrors the key-form accessor for
    # :model_profiles (the map-form previously omitted it). The setup block
    # above updates model_profiles to exactly this list, so the map must
    # reflect it.
    config = EvoGit.AgentScheduler.get_config()

    assert config.model_profiles == [%{id: "default", model: "test:model", concurrency: 1}]

    assert config.model_profiles ==
             GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})
  end

  # --- LLM hard-pause (0-capacity, PeakHourEngine) ---

  describe "LLM hard-pause (0-capacity model)" do
    # Registers a fake agent whose ETS model_id resolves to the "default" pool.
    defp register_agent(agent_id) do
      state = %AgentState{
        context_node: %ContextNode{path: "./", repo: "/tmp/sched-hard-pause"},
        llm_model: "test:model",
        model_id: "default",
        max_retries: 2,
        max_depth: 1
      }

      Store.put_agent_state(agent_id, state)
      on_exit(fn -> Store.delete_agent_state(agent_id) end)
    end

    defp agent_spec do
      %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/tmp/sched-hard-pause"},
        phylo_node: %PhyloGraphNode{
          repo: "/tmp/sched-hard-pause",
          base_commit: "abc",
          current_commit: "abc"
        },
        agent_module: __MODULE__,
        objective: "test"
      }
    end

    setup do
      # The live (old) PeakHourEngine in this worktree re-applies a FLOORED
      # model_concurrency map on every "scheduler_config" PubSub broadcast. It
      # does not yet know about the 0 hard-pause sentinel, so it would
      # asynchronously resurrect `%{"default" => 0}` back to `%{"default" => 1}`
      # between update_config and the assertions below. Suspend it for the
      # duration of these integration tests — the floor-preservation semantics
      # themselves are pinned by the pure-function tests in state_test.exs.
      engine = Process.whereis(EvoGit.PeakHourEngine)
      if engine, do: :sys.suspend(engine)
      on_exit(fn -> if engine, do: :sys.resume(engine) end)
      :ok
    end

    test "request_llm_slot blocks until capacity is restored" do
      agent_id = 9001
      register_agent(agent_id)

      # PeakHourEngine drops the model to 0 (hard-pause) — the request no
      # longer fails fast; it enqueues and blocks until capacity returns.
      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})

      task = Task.async(fn -> AgentScheduler.request_llm_slot(agent_id) end)

      try do
        # Still blocked — the call does not return at 0 capacity.
        assert Task.yield(task, 200) == nil

        # Capacity restored → the end-of-update grant sweep replies :ok.
        assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 1})
        assert Task.await(task, 2_000) == :ok

        # The restore took effect (the floor never resurrected the 0 either).
        assert AgentScheduler.get_config(:model_concurrency) == %{"default" => 1}
      after
        # Guarantee: even on a failed assertion, unblock + kill the task so no
        # orphaned blocked process leaks into later tests. Also release the slot
        # the task may have acquired (request_llm_slot alone never releases) so
        # no stale holder can starve the next test's grant sweep.
        AgentScheduler.update_config(model_concurrency: %{"default" => 1})
        AgentScheduler.release_llm_slot(agent_id)
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "with_llm_slot does not raise on 0-capacity; blocks until granted" do
      agent_id = 9002
      register_agent(agent_id)

      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})

      task =
        Task.async(fn -> AgentScheduler.with_llm_slot(agent_id, fn -> :llm_ran end) end)

      try do
        # No raise on 0-capacity — the request blocks like the paused case.
        assert Task.yield(task, 200) == nil

        assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 1})
        assert Task.await(task, 2_000) == :llm_ran
      after
        AgentScheduler.update_config(model_concurrency: %{"default" => 1})
        AgentScheduler.release_llm_slot(agent_id)
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "graceful cancel unblocks a blocked agent; force-kill still works" do
      agent_id = 9003
      ref = make_ref()
      register_agent(agent_id)

      # Top-level agent whose `from` pid is this test process — the force-kill
      # scan key. The from ref is a fake GenServer.from; cancel replies to it.
      # Status starts :running so the enqueue's :blocked transition is
      # observable (apply_status_updates only flips :running <-> :blocked).
      meta = %SchedMeta{
        id: agent_id,
        depth: 0,
        task_id: "t0cap",
        status: :running,
        from: {self(), ref},
        spec: agent_spec()
      }

      Store.put_sched_meta(agent_id, meta)
      on_exit(fn -> Store.delete_sched_meta(agent_id) end)

      # The agent's LLM request BLOCKS at 0 capacity — it is enqueued, not
      # rejected, so nothing is wedged; cancel/kill unblocks it.
      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})

      task = Task.async(fn -> AgentScheduler.request_llm_slot(agent_id) end)

      try do
        # Wait until the request is actually enqueued (meta flipped to :blocked)
        # — the graceful-cancel purge below must run AFTER the enqueue.
        wait_until(
          fn -> match?({:ok, %SchedMeta{status: :blocked}}, Store.get_sched_meta(agent_id)) end,
          2_000
        )

        # Graceful cancel: purges the waiting queue, replying {:error, :cancelled}
        # to the blocked caller (which makes its with_llm_slot raise → crash →
        # crash-retry → cancel-grace) — :ok.
        assert :ok = AgentScheduler.begin_graceful_cancel("t0cap")

        # The blocked request returns {:error, :cancelled}.
        assert Task.await(task, 2_000) == {:error, :cancelled}

        # Force-kill: finds the top-level agent by caller pid, purges queues,
        # releases slots, and removes ETS entries — :ok.
        assert :ok = AgentScheduler.force_kill_task_agents(self())

        assert Store.get_sched_meta(agent_id) == :error
        assert Store.get_agent_state(agent_id) == :error
        assert_received {^ref, {:error, :cancelled}}
      after
        AgentScheduler.update_config(model_concurrency: %{"default" => 1})
        AgentScheduler.release_llm_slot(agent_id)
        Task.shutdown(task, :brutal_kill)
      end
    end
  end
end
