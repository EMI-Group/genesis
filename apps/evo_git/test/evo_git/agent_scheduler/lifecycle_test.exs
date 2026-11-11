defmodule EvoGit.AgentScheduler.LifecycleTest.StubAgent do
  @moduledoc """
  The role a session-test run executes AS.

  A real `EvoGit.Agent.Session` needs a module implementing the `EvoGit.Agent`
  behaviour (`system_prompt/0`, `available_tools/0`, `delegation_level/0`). The
  tool list is deliberately EMPTY: every exchange is driven end-to-end by the
  `:llm_call` engine seam, so no tool schema is ever dispatched.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the lifecycle-test stub agent."

  @doc "No tools: the scripted model never asks for one."
  def available_tools, do: []
end

defmodule EvoGit.AgentScheduler.LifecycleTest do
  @moduledoc """
  Tests for the crash-retry logic in `EvoGit.AgentScheduler.Lifecycle.handle_agent_crash/3`,
  the cancellation logic in `cancel_agent/2`, the routing in
  `handle_session_result/3`, and the defensive handling for missing ETS entries.

  ## Sessions, not `%Task{}`

  An agent runs inside ONE `EvoGit.Agent.Session` process, so `SchedMeta` carries
  `session_pid` (never a `%Task{}`) and `Lifecycle.cancel_agent/2` force-stops
  that session through `EvoGit.Agent.Session.cancel(pid, :force)`. The two
  cancellation tests therefore start a REAL session (repo-less, with an
  `:exchange_opts` `:llm_call` seam that parks the worker) and assert the session
  dies with the `:shutdown` reason the session's own force-cancel path produces —
  the `Process.exit/2` fallback would show up as `:killed` instead.

  Uses `async: true`: every row the module seeds lives in the app-global named
  ETS tables (`:evogit_agent_summary`, `:evogit_sched_meta` and
  `:evogit_cancelling_tasks`), so it writes ONLY under per-test UNIQUE agent ids
  (`unique_agent_id/0`, its own 9_700_000+ range) and never wipes a table — a
  whole-table delete would destroy a concurrently running module's rows, and a
  small literal id would collide with one (other modules read e.g. id 3 and
  assert the scheduler-default fallback).
  """

  use ExUnit.Case, async: true

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

  # A session-owned `%EvoGit.Agent.State{}` (the summary source the session
  # publishes from) with the struct's required keys defaulted.
  defp summary_state(overrides \\ []) do
    struct!(
      EvoGit.Agent.State,
      Keyword.merge(
        [
          agent_id: unique_agent_id(),
          agent_module: EvoGit.AgentScheduler.LifecycleTest.StubAgent,
          depth: 0,
          node_path: "./",
          context: ReqLLM.Context.new([])
        ],
        overrides
      )
    )
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

  # Per-test-unique agent id: the tables are app-global and shared with every
  # concurrently running `async: true` module, so this module must never reuse a
  # small literal id and must never wipe a table (see the moduledoc).
  defp unique_agent_id, do: 9_700_000 + :erlang.unique_integer([:positive])

  # All sched_meta rows belonging to `task_id` — the async-safe replacement for
  # a whole-table size check (see the moduledoc).
  defp sched_meta_for_task(task_id) do
    :ets.tab2list(:evogit_sched_meta)
    |> Enum.filter(fn {_agent_id, meta} -> meta.task_id == task_id end)
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
    :ets.insert(:evogit_agent_summary, {agent_id, state})
  end

  # Reads through the public Store API, which returns the RAW summary row: it
  # carries no conversation and no control state (`cancel_requested` /
  # pending messages live in the control plane and are read through
  # `Store.cancel_requested?/1` / `Store.drain_pending_user_messages/1`).
  defp get_agent_state(agent_id) do
    case EvoGit.AgentScheduler.Store.get_agent_state(agent_id) do
      {:ok, state} -> {:ok, state}
      :error -> :missing
    end
  end

  # --- Real sessions (the ONE agent lifecycle) ---

  # Starts a REAL `EvoGit.Agent.Session` for `agent_id` whose exchange worker
  # parks inside its `:llm_call` seam, so the session stays `:running` until the
  # test force-cancels it. Repo-less: no worktree is ever requested, so the
  # session touches no repository and needs no `WorktreeManager`.
  #
  # Returns the session pid and its monitor ref (the ref is created BEFORE the
  # cancel, so the test can assert WHICH exit reason the session produced).
  defp start_blocked_session(agent_id, row_overrides \\ []) do
    put_agent_state(agent_id, struct!(session_agent_state(), row_overrides))

    dispatch_ctx = [
      agent_id: agent_id,
      depth: 0,
      repo_root: "/tmp/test",
      repo_id: "primary",
      worktree_path: Path.join(System.tmp_dir!(), "lifecycle_session_#{agent_id}"),
      retries: 0,
      spec: session_spec(),
      meta: %SchedMeta{id: agent_id, depth: 0, spec: session_spec()},
      repo_less: true,
      repo_less_repo_path: "/tmp/test",
      scheduler: self(),
      exchange_opts: [llm_call: blocking_llm_call(self())]
    ]

    {:ok, pid} = EvoGit.Agent.Session.start_link(dispatch_ctx)
    # An abnormal exit must not take the test process down with the session.
    Process.unlink(pid)
    ref = Process.monitor(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    # The session is only cancellable from `:running`: wait for the worker to be
    # parked in its LLM call, which is the state every assertion below assumes.
    # The worker is deliberately NOT released — the force cancel kills it.
    assert_receive {:llm_blocked, _worker}, 5_000
    assert {:ok, %{phase: :running}} = EvoGit.Agent.Session.inspect(pid, 1_000)

    %{session: pid, ref: ref}
  end

  defp session_spec do
    %AgentSpec{
      context_node: context_node(),
      phylo_node: phylo_node(),
      agent_module: EvoGit.AgentScheduler.LifecycleTest.StubAgent,
      objective: "lifecycle session test",
      opts: [
        repo_less: true,
        task_tmpdir: Path.join(System.tmp_dir!(), "lifecycle_session_tmp")
      ]
    }
  end

  # The scheduler row a session builds its state from (the identity/model fields
  # come from this row, never from the dispatch context).
  defp session_agent_state do
    %AgentState{
      context_node: context_node(),
      llm_model: "test:model",
      model_id: "lifecycle-test",
      max_retries: 15,
      max_depth: 8,
      max_turns: 128,
      repo_id: "primary",
      llm_context_window: 200_000
    }
  end

  # The scripted model: the FIRST call parks the worker until released, and any
  # later call (a grace turn, a retry) completes immediately — so a released run
  # always terminates promptly.
  defp blocking_llm_call(test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      unless Process.get(:lifecycle_session_released) do
        send(test_pid, {:llm_blocked, self()})

        receive do
          :release -> Process.put(:lifecycle_session_released, true)
        after
          5_000 -> Process.put(:lifecycle_session_released, true)
        end
      end

      message = %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("lifecycle session report")],
        tool_calls: nil
      }

      response = %ReqLLM.Response{
        id: "lifecycle-session-response",
        model: "test:model",
        context: ReqLLM.Context.append(context, message),
        message: message,
        usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
      }

      {:implicit_completion, response, "lifecycle session report"}
    end
  end

  # A stand-in for a running session in the bookkeeping tests: it answers the ONE
  # `EvoGit.Agent.Session.cancel(pid, :force)` call `Lifecycle.cancel_agent/2`
  # makes (a real session replies `:ok` there) and then stops. Without the reply
  # `cancel_agent/2` would wait out the session call timeout and take its
  # `Process.exit/2` fallback, which is not what these tests are about.
  defp session_process do
    spawn(fn ->
      receive do
        {:"$gen_call", from, {:cancel, :force}} -> GenServer.reply(from, :ok)
      end
    end)
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_agent_summary)
    create_ets_if_missing(:evogit_sched_meta)
    create_ets_if_missing(:evogit_cancelling_tasks)
    create_ets_if_missing(:evogit_agent_control)

    if :ets.whereis(:evogit_agent_inbox) == :undefined,
      do: :ets.new(:evogit_agent_inbox, [:bag, :named_table, :public])

    :ok
  end

  # --- Tests ---

  describe "handle_agent_crash/3 — retry path" do
    test "retries agent and queues it for re-dispatch" do
      agent_id = unique_agent_id()

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
      # The retry drops the dead session's pid and its phase mirror, so the
      # re-dispatch starts a FRESH session.
      assert updated_meta.session_pid == nil
      assert updated_meta.phase == nil

      # Agent queued for re-dispatch (paused → queued, not dispatched)
      assert :queue.to_list(new_state.queue) == [agent_id]
    end

    test "missing agent_state during retry doesn't crash" do
      agent_id = unique_agent_id()

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

    test "resetting agent_state clears current_commit" do
      agent_id = unique_agent_id()

      meta = %SchedMeta{id: agent_id, depth: 0, spec: agent_spec(), retries: 0}
      put_sched_meta(agent_id, meta)

      # Agent state with a worktree-bound commit recorded at registration.
      put_agent_state(agent_id, %AgentState{agent_state() | current_commit: "abc"})

      state = base_state([])

      assert {:noreply, _new_state} =
               Lifecycle.handle_agent_crash(state, agent_id, {:error, :test})

      {:ok, updated_agent_state} = get_agent_state(agent_id)
      assert updated_agent_state.current_commit == nil
    end
  end

  describe "handle_agent_crash/3 — permanent failure" do
    test "marks agent as failed after max retries and replies to caller" do
      agent_id = unique_agent_id()
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

      # A fresh id has no sched_meta or agent_state in ETS
      ghost_id = unique_agent_id()

      assert {:noreply, new_state} =
               Lifecycle.handle_agent_crash(state, ghost_id, {:error, :ghost})

      # The function returns the state completely unchanged on :error
      assert new_state == state
    end
  end

  describe "cancel_agent/2" do
    test "force-stops the agent's Session, replies {:error, :cancelled} and cleans up ETS entries" do
      agent_id = unique_agent_id()
      from_ref = make_ref()

      # A REAL session, parked in its LLM call: `Session.cancel(pid, :force)` is
      # the ONE force-stop path, and it stops the session with `:shutdown`
      # (the `Process.exit/2` fallback would show up as `:killed` instead).
      %{session: session, ref: ref} = start_blocked_session(agent_id)

      meta = %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        session_pid: session,
        from: {self(), from_ref},
        sub_agent_from: {self(), make_ref()},
        worktree: nil
      }

      put_sched_meta(agent_id, meta)

      state = base_state([])

      assert Lifecycle.cancel_agent(state, agent_id) == state

      # The session process is dead, and it died through the session's own
      # force-cancel path (a `:kill` fallback would report `:killed`).
      assert_receive {:DOWN, ^ref, :process, ^session, :shutdown}, 5_000
      refute Process.alive?(session)

      # Both blocked callers get the documented cancellation reply.
      assert_received {^from_ref, {:error, :cancelled}}

      # ETS entries deleted
      assert get_sched_meta(agent_id) == :missing
      assert get_agent_state(agent_id) == :missing
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

    test "cancel_agent stops the session but leaves the worktree dir and branch intact", %{
      repo_root: repo_root,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      %{branch: branch, wt_path: wt_path} = make_worktree(repo_root, base_sha)

      %{session: session, ref: ref} =
        start_blocked_session(agent_id, repo_root: repo_root, task_local_id: 1)

      put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        session_pid: session,
        from: nil,
        worktree: wt_path
      })

      state = base_state([])
      assert Lifecycle.cancel_agent(state, agent_id) == state

      assert_receive {:DOWN, ^ref, :process, ^session, :shutdown}, 5_000
      refute Process.alive?(session)

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

      # One stand-in session per agent that will be cancelled:
      # Lifecycle.cancel_agent/2 force-stops the stored `session_pid` through
      # `EvoGit.Agent.Session.cancel/2`.
      sessions = Enum.map(1..3, fn _ -> session_process() end)

      # A separate process whose pid is distinct from self() so that the
      # caller_pid scan in the handler does NOT match this agent.
      dummy_caller = spawn(fn -> Process.sleep(:infinity) end)

      # Per-test-unique agent ids — the tables are shared with every concurrent
      # `async: true` module (see the moduledoc).
      a1 = unique_agent_id()
      a2 = unique_agent_id()
      a3 = unique_agent_id()
      a4 = unique_agent_id()

      try do
        [session1, session2, session3] = sessions

        # Agent a1: top-level (depth: 0) whose `from` contains caller_pid.
        # This is the entry point the handler keys off of.
        meta1 = %SchedMeta{
          id: a1,
          depth: 0,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          from: {caller_pid, caller_ref},
          session_pid: session1
        }

        # Agent a2: subagent (depth: 1) sharing the same task_id.
        meta2 = %SchedMeta{
          id: a2,
          depth: 1,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          parent_id: a1,
          session_pid: session2
        }

        # Agent a3: another subagent (depth: 2) sharing the same task_id.
        meta3 = %SchedMeta{
          id: a3,
          depth: 2,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          parent_id: a2,
          session_pid: session3
        }

        # Agent a4: belongs to a DIFFERENT task_id — must NOT be cancelled.
        # Its `from` uses dummy_caller (a different pid) so it isn't matched by
        # the caller_pid scan (ETS tab2list order is unspecified).
        meta4 = %SchedMeta{
          id: a4,
          depth: 0,
          spec: agent_spec(),
          retries: 0,
          task_id: "99",
          from: {dummy_caller, make_ref()},
          session_pid: nil
        }

        put_sched_meta(a1, meta1)
        put_sched_meta(a2, meta2)
        put_sched_meta(a3, meta3)
        put_sched_meta(a4, meta4)

        # Put all four agent IDs into the dispatch queue.
        state =
          base_state([])
          |> then(fn s -> %{s | queue: Enum.reduce([a1, a2, a3, a4], s.queue, &:queue.in/2)} end)

        from = {self(), make_ref()}

        # The old (buggy) code raised ArgumentError here because :queue.filter/2
        # was called with the queue as the first argument instead of the function.
        assert {:reply, :ok, new_state} =
                 AgentScheduler.handle_call({:force_kill_task_agents, caller_pid}, from, state)

        # Agents a1-a3 are removed from the queue; a4 (different task) survives.
        assert :queue.to_list(new_state.queue) == [a4]

        # Cancelled agents are deleted from ETS.
        assert get_sched_meta(a1) == :missing
        assert get_sched_meta(a2) == :missing
        assert get_sched_meta(a3) == :missing

        # The unrelated agent's metadata is untouched.
        assert {:ok, ^meta4} = get_sched_meta(a4)
      after
        # Clean up any stand-in session left alive (cancel_agent kills its own).
        Enum.each(sessions, fn pid ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end)

        # Clean up the dummy caller process used for the unrelated agent.
        Process.exit(dummy_caller, :kill)
      end
    end

    test "releases LLM/tool slots held by cancelled agents" do
      caller_pid = self()
      caller_ref = make_ref()
      task_id = "42"

      # One stand-in session per agent that will be cancelled (see
      # `session_process/0`): `Lifecycle.cancel_agent/2` force-stops the stored
      # `session_pid`.
      sessions = Enum.map(1..2, fn _ -> session_process() end)

      # Per-test-unique agent ids (see the moduledoc).
      a1 = unique_agent_id()
      a2 = unique_agent_id()

      try do
        [session1, session2] = sessions

        # Agent a1: top-level (depth: 0) whose `from` contains caller_pid.
        meta1 = %SchedMeta{
          id: a1,
          depth: 0,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          from: {caller_pid, caller_ref},
          session_pid: session1
        }

        # Agent a2: subagent (depth: 1) sharing the same task_id.
        meta2 = %SchedMeta{
          id: a2,
          depth: 1,
          spec: agent_spec(),
          retries: 0,
          task_id: task_id,
          parent_id: a1,
          session_pid: session2
        }

        put_sched_meta(a1, meta1)
        put_sched_meta(a2, meta2)

        # Simulate both agents holding LLM and tool slots at the time of
        # cancellation.
        state =
          base_state(
            llm_holders: %{"default" => MapSet.new([a1, a2])},
            tool_holders: MapSet.new([a1, a2]),
            llm_last_granted: %{"default" => %{a1 => 1_000, a2 => 2_000}}
          )

        from = {self(), make_ref()}

        assert {:reply, :ok, new_state} =
                 AgentScheduler.handle_call({:force_kill_task_agents, caller_pid}, from, state)

        # The cancelled agents must be removed from both holder sets so that
        # the slots are returned to the pool (no permanent leak).
        default_holders = State.holders_for(new_state, "default")
        refute MapSet.member?(default_holders, a1)
        refute MapSet.member?(default_holders, a2)
        refute MapSet.member?(new_state.tool_holders, a1)
        refute MapSet.member?(new_state.tool_holders, a2)

        # llm_last_granted entries for cancelled agents are also cleaned up.
        default_last_granted = State.last_granted_for(new_state, "default")
        refute Map.has_key?(default_last_granted, a1)
        refute Map.has_key?(default_last_granted, a2)

        assert default_holders == MapSet.new()
        assert new_state.tool_holders == MapSet.new()
      after
        Enum.each(sessions, fn pid ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end)
      end
    end
  end

  describe "graceful cancel — begin_graceful_cancel / clear_cancelling_task / run_agent guard" do
    test "begin_graceful_cancel registers the task marker and notifies all agents of the task" do
      task_id = "graceful-42"
      caller_pid = self()

      # Per-test-unique agent ids (see the moduledoc).
      a1 = unique_agent_id()
      a2 = unique_agent_id()
      other = unique_agent_id()

      # Agent a1: top-level (depth 0); Agent a2: subagent (depth 1) — same task.
      put_sched_meta(a1, %SchedMeta{
        id: a1,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        task_id: task_id,
        from: {caller_pid, make_ref()}
      })

      put_sched_meta(a2, %SchedMeta{
        id: a2,
        depth: 1,
        spec: agent_spec(),
        retries: 0,
        task_id: task_id,
        parent_id: a1
      })

      # Agent `other` belongs to a DIFFERENT task — must NOT be notified.
      put_sched_meta(other, %SchedMeta{
        id: other,
        depth: 0,
        spec: agent_spec(),
        retries: 0,
        task_id: "other",
        from: {caller_pid, make_ref()}
      })

      for id <- [a1, a2, other], do: put_agent_state(id, agent_state())

      state = base_state([])
      from = {self(), make_ref()}

      assert {:reply, :ok, ^state} =
               AgentScheduler.handle_call({:begin_graceful_cancel, task_id}, from, state)

      # Marker registered.
      assert :ets.member(:evogit_cancelling_tasks, task_id)

      # Agents a1 & a2 got the cancel message + cancel_requested flag (both are
      # CONTROL-PLANE state, never fields on the summary row).
      for id <- [a1, a2] do
        assert EvoGit.AgentScheduler.Store.cancel_requested?(id),
               "agent #{id} cancel_requested not set"

        assert Enum.any?(
                 EvoGit.AgentScheduler.Store.drain_pending_user_messages(id),
                 &String.contains?(&1, "being cancelled")
               )
      end

      # The other task's agent is untouched.
      refute EvoGit.AgentScheduler.Store.cancel_requested?(other)
      assert EvoGit.AgentScheduler.Store.drain_pending_user_messages(other) == []
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

      # No agent was registered for THIS task. Scoped to the task's own
      # sched_meta slice — a table-wide size check is not async-safe (the tables
      # are shared with every concurrently running module), and registration
      # writes sched_meta unconditionally, so an empty slice proves neither
      # table gained a row for this task.
      assert sched_meta_for_task(task_id) == []
    end

    test "Dispatch.register_agent puts a newly registered agent of a cancelling task into grace" do
      task_id = "graceful-reg"
      :ets.insert(:evogit_cancelling_tasks, {task_id})

      state = base_state(next_agent_id: unique_agent_id())
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

      assert EvoGit.AgentScheduler.Store.cancel_requested?(agent_id)

      assert Enum.any?(
               EvoGit.AgentScheduler.Store.drain_pending_user_messages(agent_id),
               &String.contains?(&1, "being cancelled")
             )
    end

    test "Dispatch.register_agent does not touch agents of non-cancelling tasks" do
      task_id = "graceful-reg-other"

      state = base_state(next_agent_id: unique_agent_id())
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

      refute EvoGit.AgentScheduler.Store.cancel_requested?(agent_id)
      assert EvoGit.AgentScheduler.Store.drain_pending_user_messages(agent_id) == []
    end
  end

  describe "state-owned compression_count / total_tokens (Session.Summary.publish/3)" do
    # `compression_count` and `total_tokens` are STATE-OWNED: the session keeps
    # them in its `%EvoGit.Agent.State{}` and publishes them onto the summary row
    # (there is no `increment_compression_count/1` / `update_total_tokens/2`
    # read-modify-write anymore). The assertions below are the published ROW.
    test "publishes compression_count onto the agent state table" do
      agent_id = unique_agent_id()
      put_agent_state(agent_id, agent_state())

      assert :ok =
               EvoGit.Agent.Session.Summary.publish(agent_id, summary_state(compression_count: 1))

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.compression_count == 1

      assert :ok =
               EvoGit.Agent.Session.Summary.publish(agent_id, summary_state(compression_count: 2))

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.compression_count == 2
    end

    test "compression_count defaults to 0 on a freshly constructed AgentState" do
      assert agent_state().compression_count == 0
    end

    test "publishes total_tokens onto the agent state table" do
      agent_id = unique_agent_id()
      put_agent_state(agent_id, agent_state())

      assert :ok =
               EvoGit.Agent.Session.Summary.publish(agent_id, summary_state(total_tokens: 5000))

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.total_tokens == 5000

      assert :ok =
               EvoGit.Agent.Session.Summary.publish(agent_id, summary_state(total_tokens: 12_000))

      {:ok, updated_state} = get_agent_state(agent_id)
      assert updated_state.total_tokens == 12_000
    end

    test "total_tokens defaults to 0 on a freshly constructed AgentState" do
      assert agent_state().total_tokens == 0
    end

    test "a publish for a missing row is a no-op (a session never creates rows)" do
      # Totality replaced the old "raises when the agent state is missing"
      # contract: registration owns row creation, so a publish for a recycled
      # agent must never write and never raise.
      missing_id = unique_agent_id()
      assert :ok = EvoGit.Agent.Session.Summary.publish(missing_id, summary_state())
      assert get_agent_state(missing_id) == :missing
    end
  end

  describe "handle_session_result/3 — session result routing" do
    test "a root session result replies to the blocked caller with the agent count injected" do
      # The session delivers its ONE result to the scheduler, which routes it to
      # the caller blocked in `run_agent/2`; the session itself never replies.
      task_id = "lifecycle-session-root-#{System.unique_integer([:positive])}"
      agent_id = unique_agent_id()
      from = {self(), make_ref()}
      {_caller, caller_ref} = from

      put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: agent_spec(),
        task_id: task_id,
        from: from,
        session_pid: self(),
        foreign_repo_commits: %{"foreign1" => "sha-1"}
      })

      state = base_state(task_agent_counts: %{task_id => 3})
      result = {:ok, %Result{result: "done", commit_sha: "abc123"}}

      assert {:noreply, new_state} = Lifecycle.handle_session_result(agent_id, result, state)

      assert_received {^caller_ref, {:ok, %Result{} = replied}}
      assert replied.result == "done"
      # Whole-run accounting: the root's result carries the full agent count.
      assert replied.agent_count == 3
      # The subtree's foreign-repo commits ride along on the root reply too.
      assert replied.foreign_repo_commits == %{"foreign1" => "sha-1"}
      # The per-task counter is consumed, and the row is marked as replied so a
      # later `:DOWN` recycles instead of treating it as a crash.
      assert new_state.task_agent_counts == %{}
      assert {:ok, stored} = get_sched_meta(agent_id)
      assert stored.result_sent
    end

    test "a subagent session result lands in the parent's results and leaves the parent with the scheduler" do
      parent_id = unique_agent_id()
      child_id = unique_agent_id()
      sibling_id = unique_agent_id()
      task_id = "lifecycle-session-sub-#{System.unique_integer([:positive])}"

      put_sched_meta(parent_id, %SchedMeta{
        id: parent_id,
        depth: 0,
        spec: agent_spec(),
        task_id: task_id,
        status: :waiting,
        total_sub_specs: 2,
        pending_sub_agents: MapSet.new([child_id, sibling_id]),
        sub_agent_indices: %{child_id => 0, sibling_id => 1}
      })

      put_sched_meta(child_id, %SchedMeta{
        id: child_id,
        depth: 1,
        spec: agent_spec(),
        task_id: task_id,
        parent_id: parent_id,
        status: :running,
        session_pid: self()
      })

      state = base_state([])
      result = {:ok, %Result{result: "child report", commit_sha: "def456"}}

      assert {:noreply, new_state} = Lifecycle.handle_session_result(child_id, result, state)

      # The child's result is stored at its ORIGINAL spec index on the parent...
      assert {:ok, parent} = get_sched_meta(parent_id)
      assert parent.sub_agent_results == %{0 => result}
      # ...the child's own row is marked replied...
      assert {:ok, child} = get_sched_meta(child_id)
      assert child.result_sent
      # ...and the parent is NOT resumed yet (its second subagent is still
      # running), so nobody is replied to and the scheduler state is unchanged.
      assert parent.status == :waiting
      assert new_state.queue == state.queue
      refute_receive {_ref, _result}
    end

    test "a result for an agent with no sched_meta is ignored without touching state" do
      # Defensive: a session result can arrive after the row was reaped (cancel).
      state = base_state([])
      missing_id = unique_agent_id()
      result = {:ok, %Result{result: "late", commit_sha: "abc"}}

      assert {:noreply, ^state} =
               Lifecycle.handle_session_result(missing_id, result, state)
    end
  end

  describe "store_sub_result/3,4 — 3-level foreign-repo-commits roll-up" do
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
      # 3-level tree: root agent1 -> sub-manager agent2 -> executor agent3
      # (per-test-unique ids — see the moduledoc).
      agent1 = unique_agent_id()
      agent2 = unique_agent_id()
      agent3 = unique_agent_id()

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
         }},
        %AgentSpec{
          context_node: context_node(),
          phylo_node: phylo_node(),
          agent_module: EvoGit.Agents.Executor,
          objective: "foreign work",
          repo_id: "foreign1",
          foreign_repos: [%{id: "foreign1", root: "/tmp/foreign1", writable: true}]
        }
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

      Subagents.store_sub_result(agent1, agent2, result2, %AgentSpec{
        context_node: context_node(),
        phylo_node: phylo_node(),
        agent_module: EvoGit.Agents.Executor,
        objective: "foreign work",
        repo_id: "foreign2",
        foreign_repos: [%{id: "foreign2", root: "/tmp/foreign2", writable: true}]
      })

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
end
