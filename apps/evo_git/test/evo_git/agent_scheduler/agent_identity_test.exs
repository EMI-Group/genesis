defmodule EvoGit.AgentScheduler.AgentIdentityTest do
  @moduledoc """
  Stable agent identity + spawn facts (P1 / Track C): the scheduler's BOOT
  counter seed, EXPLICIT-id registration and the dispatch context a session is
  started with.

  `async: true`: every registration runs under an id from this file's own high
  range (`70_000_0xx`) and deletes its two ETS rows in `on_exit`; nothing here
  asserts on a table as a whole, so a concurrently running module can never
  observe these writes. LIVENESS is proven through the real
  `EvoGit.Agent.Session.Registry` (the documented `agent_id` → session lookup,
  the authority for "an id is held"), never through a fabricated summary row.

  The boot seed starts the scheduler module through `GenServer.start/3`
  (UNNAMED — the application already owns the registered name) and reads the
  resulting state with `:sys.get_state/1`, so the assertion is about `init/1`
  itself. Each seed case passes an isolated `:agent_state_store` (or none),
  which is why no app-global row can leak into the expected number.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A valid `EvoGit.Agent` role — never run here (nothing in this module starts
  # a session; registration and ctx assembly only).
  defmodule DummyAgent do
    use EvoGit.Agent
    def available_tools, do: []
  end

  # Ids this module owns. High on purpose: a concurrently dispatched REAL agent
  # gets small scheduler-allocated ids, and these must never collide with one.
  @adoptable_id 70_000_007
  @held_id 70_000_008
  @counter_base 70_000_100

  # --- Boot seeding of next_agent_id ---------------------------------------

  describe "boot seed of next_agent_id" do
    test "seeds above the largest durable agent id", %{tmp_dir: dir} do
      store = start_agent_state!(dir)
      task_id = unique_task_id("seed")
      seed_durable_run!(store, task_id, 7)

      scheduler = start_scheduler!(agent_state_store: store)

      assert %State{next_agent_id: 8} = :sys.get_state(scheduler)
    end

    test "seeds 1 when no store is configured" do
      scheduler = start_scheduler!(agent_state_store: nil)

      assert %State{next_agent_id: 1} = :sys.get_state(scheduler)
    end

    test "seeds 1 when the configured store is gone", %{tmp_dir: dir} do
      store = start_agent_state!(dir)
      task_id = unique_task_id("gone")
      seed_durable_run!(store, task_id, 7)
      :ok = Supervisor.stop(store, :normal, 5_000)
      refute Process.alive?(store)

      scheduler = start_scheduler!(agent_state_store: store)

      assert %State{next_agent_id: 1} = :sys.get_state(scheduler)
    end
  end

  # --- Explicit-id registration --------------------------------------------

  describe "explicit-id registration" do
    test "adopts a FREE explicit id and moves the counter past it" do
      refute match?({:ok, _pid}, EvoGit.Agent.Session.whereis(@adoptable_id))
      task_id = unique_task_id("adopt")

      # A base counter BELOW the adopted id, so the adoption has to jump it.
      assert {@adoptable_id, state} =
               Dispatch.register_agent(state(1), spec(), nil, nil, 0, task_id, 2,
                 agent_id: @adoptable_id
               )

      cleanup_agent(@adoptable_id)

      assert state.next_agent_id == @adoptable_id + 1

      assert {:ok, %SchedMeta{id: @adoptable_id, task_id: ^task_id}} =
               Store.get_sched_meta(@adoptable_id)

      assert {:ok, %AgentState{parent_id: nil, task_local_id: 1}} =
               Store.get_agent_state(@adoptable_id)
    end

    test "an adopted id behind the counter does not rewind it" do
      task_id = unique_task_id("adopt-behind")

      assert {@adoptable_id, state} =
               Dispatch.register_agent(state(@counter_base), spec(), nil, nil, 0, task_id, 2,
                 agent_id: @adoptable_id
               )

      cleanup_agent(@adoptable_id)

      assert state.next_agent_id == @counter_base
    end

    test "refuses an id a live session holds, writing nothing" do
      hold_agent_id!(@held_id)
      task_id = unique_task_id("held")

      assert {:error, {:agent_id_taken, @held_id}} =
               Dispatch.register_agent(state(@counter_base), spec(), nil, nil, 0, task_id, 2,
                 agent_id: @held_id
               )

      # FAIL CLOSED: no row written, and the counter was not consumed — the very
      # next allocation still hands out the counter's value.
      assert Store.get_sched_meta(@held_id) == :error
      assert Store.get_agent_state(@held_id) == :error

      assert {@counter_base, _state} =
               Dispatch.register_agent(state(@counter_base), spec(), nil, nil, 0, task_id, 2)

      cleanup_agent(@counter_base)
    end

    test "ignores a non-positive or non-integer explicit id" do
      task_id = unique_task_id("invalid")
      expected_next = @counter_base + 1

      for bogus <- [0, -7, "7", nil] do
        assert {@counter_base, %State{next_agent_id: ^expected_next}} =
                 Dispatch.register_agent(state(@counter_base), spec(), nil, nil, 0, task_id, 2,
                   agent_id: bogus
                 )

        cleanup_agent(@counter_base)
      end
    end

    test "allocation without an explicit id is unchanged" do
      task_id = unique_task_id("allocate")
      expected_next = @counter_base + 1

      assert {@counter_base, %State{next_agent_id: ^expected_next}} =
               Dispatch.register_agent(state(@counter_base), spec(), nil, nil, 0, task_id, 2)

      cleanup_agent(@counter_base)
    end
  end

  # --- Spawn facts on the registered row -----------------------------------

  describe "spawn facts on the stored spec" do
    test "two children of one batch carry their spawn turn and index" do
      task_id = unique_task_id("batch")

      {first, state} =
        Dispatch.register_agent(state(@counter_base), spec(), nil, 5, 1, task_id, 2,
          spawn_turn: 3,
          spawn_index: 0
        )

      cleanup_agent(first)

      {second, _state} =
        Dispatch.register_agent(state, spec(), nil, 5, 1, task_id, 2,
          spawn_turn: 3,
          spawn_index: 1
        )

      cleanup_agent(second)

      assert %SchedMeta{spec: %AgentSpec{opts: first_opts}} = meta!(first)
      assert %SchedMeta{spec: %AgentSpec{opts: second_opts}} = meta!(second)

      assert Keyword.get(first_opts, :spawn_turn) == 3
      assert Keyword.get(first_opts, :spawn_index) == 0
      assert Keyword.get(second_opts, :spawn_turn) == 3
      assert Keyword.get(second_opts, :spawn_index) == 1
    end

    test "a ROOT registration carries neither fact" do
      task_id = unique_task_id("root")

      {id, _state} =
        Dispatch.register_agent(state(@counter_base), spec(), nil, nil, 0, task_id, 2,
          spawn_turn: nil,
          spawn_index: nil
        )

      cleanup_agent(id)

      assert %SchedMeta{spec: %AgentSpec{opts: opts}} = meta!(id)
      refute Keyword.has_key?(opts, :spawn_turn)
      refute Keyword.has_key?(opts, :spawn_index)
    end
  end

  # --- Dispatch context ----------------------------------------------------

  describe "dispatch context" do
    test "a ROOT carries no spawn facts, the branch name and the row's commit" do
      task_id = unique_task_id("ctx-root")
      meta = sched_meta(spec(), task_id, task_number: 2)
      agent_state = agent_row(task_local_id: 1, current_commit: "abc123")

      plan = Dispatch.resume_plan(1, meta.spec, meta, "/home/user/primary", 0)

      ctx =
        Dispatch.build_dispatch_ctx(
          1,
          meta,
          agent_state,
          plan,
          "/home/user/primary",
          "/home/user/primary/.genesis/workers/worker_T2_A1"
        )

      assert ctx[:agent_id] == 1
      assert ctx[:spawn_turn] == nil
      assert ctx[:spawn_index] == nil
      assert ctx[:branch] == Worktrees.branch_name(2, 1)
      # A first attempt stands on the spec's own commit (the row's current
      # commit is the same sha at registration time).
      assert ctx[:base_commit] == "abc123"
      assert ctx[:base_commit] == agent_state.current_commit
      assert ctx[:restore_agent_state] == false
      refute Keyword.has_key?(ctx, :resume_kind)
    end

    test "a CHILD carries the spawn facts stored on its spec" do
      task_id = unique_task_id("ctx-child")

      meta =
        sched_meta(spec(spawn_turn: 3, spawn_index: 1), task_id, task_number: 4, depth: 1)

      agent_state = agent_row(task_local_id: 2, current_commit: "abc123")
      plan = Dispatch.resume_plan(9, meta.spec, meta, "/home/user/primary", 0)

      ctx =
        Dispatch.build_dispatch_ctx(
          9,
          meta,
          agent_state,
          plan,
          "/home/user/primary",
          "/home/user/primary/.genesis/workers/worker_T4_A2"
        )

      assert ctx[:spawn_turn] == 3
      assert ctx[:spawn_index] == 1
      assert ctx[:branch] == Worktrees.branch_name(4, 2)
      assert ctx[:base_commit] == "abc123"
    end

    test "the RESUME base wins as base_commit when one was applied" do
      task_id = unique_task_id("ctx-resume")

      meta =
        %{sched_meta(spec(), task_id, task_number: 2) | retries: 1, crash_commit: "cafe1234"}

      # A resume plan that DID apply a base (as `apply_crash_base/3` /
      # `apply_resume_base/6` do): the ctx must report that sha, not the spec's.
      plan = %{
        spec: meta.spec,
        meta: meta,
        worktree_resume_from: "cafe1234",
        persistent_state: true,
        restore_agent_state: true,
        resume_kind: :clean_pause
      }

      ctx =
        Dispatch.build_dispatch_ctx(
          1,
          meta,
          agent_row(task_local_id: 1, current_commit: "abc123"),
          plan,
          "/home/user/primary",
          "/home/user/primary/.genesis/workers/worker_T2_A1"
        )

      assert ctx[:base_commit] == "cafe1234"
      assert ctx[:worktree_resume_from] == "cafe1234"
      assert ctx[:restore_agent_state] == true
      assert ctx[:resume_kind] == :clean_pause
    end
  end

  # --- Fixtures ------------------------------------------------------------

  defp spec(extra_opts \\ []) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
      phylo_node: %PhyloGraphNode{
        repo: "/home/user/primary/.genesis/workers/worker_T2_A1",
        base_commit: "abc123",
        current_commit: "abc123"
      },
      agent_module: DummyAgent,
      objective: "test",
      repo_id: "primary",
      # A locked legacy selection skips the user model-selection script, so a
      # developer's own agents.toml can never change the resolved selection.
      opts: [model_id_locked: true] ++ extra_opts
    }
  end

  defp sched_meta(spec, task_id, opts) do
    %SchedMeta{
      id: 1,
      depth: Keyword.get(opts, :depth, 0),
      status: :pending,
      parent_id: nil,
      task_id: task_id,
      task_number: Keyword.get(opts, :task_number, 1),
      mode: :oneshot,
      spec: spec
    }
  end

  defp state(next_agent_id) do
    %{
      State.from_model_profiles([%{id: "default", model: "provider:default"}])
      | next_agent_id: next_agent_id
    }
  end

  defp meta!(agent_id) do
    {:ok, meta} = Store.get_sched_meta(agent_id)
    meta
  end

  # The registered agent-state row shape the ctx derives display/branch facts
  # from (`task_local_id`) — the enforced keys are irrelevant to that.
  defp agent_row(opts) do
    %AgentState{
      context_node: %ContextNode{path: "./", repo: "/home/user/primary"},
      llm_model: "provider:default",
      max_retries: 3,
      max_depth: 5,
      task_local_id: Keyword.fetch!(opts, :task_local_id),
      current_commit: Keyword.fetch!(opts, :current_commit)
    }
  end

  defp unique_task_id(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp cleanup_agent(agent_id) do
    on_exit(fn ->
      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
    end)
  end

  # A registered holder under `agent_id` — the SAME mechanism a real session
  # uses (`EvoGit.Agent.Session.Registry`, `keys: :unique`), which is the
  # authority `Dispatch` consults.
  defp hold_agent_id!(agent_id) do
    test_pid = self()

    holder =
      spawn(fn ->
        {:ok, _} = Registry.register(EvoGit.Agent.Session.Registry, agent_id, nil)
        send(test_pid, {:held, agent_id})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:held, ^agent_id}, 1_000
    on_exit(fn -> send(holder, :stop) end)
    assert {:ok, ^holder} = EvoGit.Agent.Session.whereis(agent_id)
  end

  defp start_scheduler!(opts) do
    {:ok, pid} = GenServer.start(EvoGit.AgentScheduler, opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)
    pid
  end

  # An ISOLATED agent-state instance (unnamed, its own database file).
  defp start_agent_state!(data_dir) do
    dir = Path.join(data_dir, "agent_state")
    File.mkdir_p!(dir)

    {:ok, pid} =
      EvoGit.AgentState.start_link(database: Path.join(dir, "agent_state.sqlite"), name: nil)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000) end)
    pid
  end

  # One durable run row for `agent_id`, written through the real writer path.
  defp seed_durable_run!(store, task_id, agent_id) do
    :ok =
      EvoGit.AgentState.checkpoint(
        task_id,
        agent_id,
        %{
          kind: :rewrite,
          messages: [
            %ReqLLM.Message{
              role: :user,
              content: [ReqLLM.Message.ContentPart.text("durable run #{agent_id}")]
            }
          ],
          fields: %{phase: "running"}
        },
        store: store
      )

    :ok = EvoGit.AgentState.flush(store: store)
    assert {:ok, _record} = EvoGit.AgentState.load(task_id, agent_id, store: store)
  end
end
