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

    test "request_llm_slot fails fast with {:error, :no_capacity} after the engine drops a model to 0" do
      agent_id = 9001
      register_agent(agent_id)

      # PeakHourEngine applies its dynamic map via update_config — the floor
      # must keep the explicit 0 (hard-pause) instead of resurrecting it.
      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})

      # The GenServer call returns immediately — no hang, distinct error atom.
      assert {:error, :no_capacity} = AgentScheduler.request_llm_slot(agent_id)

      # The model was NOT resurrected by the floor.
      assert AgentScheduler.get_config(:model_concurrency) == %{"default" => 0}
    end

    test "with_llm_slot raises a clear, model-resolving error on 0-capacity" do
      agent_id = 9002
      register_agent(agent_id)

      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})

      err =
        assert_raise RuntimeError, ~r/0 LLM slots/, fn ->
          AgentScheduler.with_llm_slot(agent_id, fn -> :ok end)
        end

      # The message resolves the model id for debuggability.
      assert err.message =~ "default"
    end

    test "graceful cancel and force-kill still work for an affected agent" do
      agent_id = 9003
      ref = make_ref()
      register_agent(agent_id)

      # Top-level agent whose `from` pid is this test process — the force-kill
      # scan key. The from ref is a fake GenServer.from; cancel replies to it.
      meta = %SchedMeta{
        id: agent_id,
        depth: 0,
        task_id: "t0cap",
        from: {self(), ref},
        spec: agent_spec()
      }

      Store.put_sched_meta(agent_id, meta)
      on_exit(fn -> Store.delete_sched_meta(agent_id) end)

      # The agent's LLM request is REJECTED at 0 capacity — it received its
      # reply, so nothing is wedged in a pending-request state.
      assert :ok = AgentScheduler.update_config(model_concurrency: %{"default" => 0})
      assert {:error, :no_capacity} = AgentScheduler.request_llm_slot(agent_id)

      # Graceful cancel: notifies the agent (cancel message + flag) — :ok.
      assert :ok = AgentScheduler.begin_graceful_cancel("t0cap")

      # Force-kill: finds the top-level agent by caller pid, purges queues,
      # releases slots, and removes ETS entries — :ok.
      assert :ok = AgentScheduler.force_kill_task_agents(self())

      assert Store.get_sched_meta(agent_id) == :error
      assert Store.get_agent_state(agent_id) == :error
      assert_received {^ref, {:error, :cancelled}}
    end
  end
end
