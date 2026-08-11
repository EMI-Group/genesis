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
end
