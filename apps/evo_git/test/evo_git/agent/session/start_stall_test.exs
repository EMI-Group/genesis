defmodule EvoGit.Agent.Session.StartStallTest.StubAgent do
  @moduledoc """
  The role a start-window session runs AS: an INTERACTIVE session
  (`session_mode/0` = `:interactive`) whose tool list is EMPTY.
  Defined ABOVE the test module on purpose: `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the start-stall stub agent."

  @doc "No tools: nothing can run a tool in these tests."
  def available_tools, do: []

  @doc "Opt this role into the interactive session driver."
  def session_mode, do: :interactive
end

defmodule EvoGit.Agent.Session.StartStallTest do
  @moduledoc """
  The `:starting` window must stay ANSWERABLE while the durable setup — the
  `:infinity` worktree request to the app-global
  `EvoGit.AgentScheduler.WorktreeManager` — is slow, queued or hung.

  1. A create that never returns fails the session DIAGNOSABLY: exactly ONE
     terminal `{:error, {:worktree_create_stalled, ms}}` result plus ONE
     `:agent_session_closed`, and the session stops `:normal`.
  2. `cancel/2` `:force` during the start window answers `:ok` at once and the
     session stops `:shutdown` WITHOUT delivering a result.

  In both cases `identity/1` and `close/2` answer immediately while the create is
  parked, which is the defect this module pins: the parked create used to block
  the session process itself.

  ## Why `async: false` — forcing BEAM-GLOBALS
  * the app-env seam `:worktree_create_fun`, read at create admission by the
    app-global `EvoGit.AgentScheduler.WorktreeManager` — a concurrently running
    module would observe this module's parked probe;
  * the two new timeout seams `:worktree_create_slow_warn_ms` and
    `:worktree_create_stall_timeout_ms`, read at CALL time by every session's
    start task — and each test needs a DIFFERENT value (200 ms for the stall,
    60 s so the deadline cannot fire for the force-cancel case), which no
    per-process seam can express.

  Every row is written under a per-test unique agent id
  (`9_980_000 + unique_integer`) and a unique task id in its OWN temp git repo,
  and deleted in `on_exit`; no test wipes a table or asserts on table size.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.StartStallTest.StubAgent
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A range of its own (the async `session_runtime_invariants_test` owns
  # 9_970_000+): the summary/sched tables are shared with every concurrently
  # running module, so the only safe key is a unique one.
  @agent_id_base 9_980_000
  # Every awaited event is reachable by construction on an idle machine; this
  # budget only absorbs the shared host's scheduling latency.
  @wait_budget_ms 10_000

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_start_stall_#{agent_id}")
    File.mkdir_p!(tmp_dir)
    repo_root = Path.join(tmp_dir, "repo")
    base_commit = init_repo!(repo_root)
    worktree_path = Path.join([repo_root, ".genesis/workers", "worker_T1_A1"])
    task_id = "task-#{agent_id}"

    spec = repo_backed_spec(repo_root, base_commit, tmp_dir)
    meta = sched_meta(agent_id, task_id, spec)

    :ok = SchedStore.put_agent_state(agent_id, agent_state(agent_id, repo_root, task_id))
    :ok = SchedStore.put_sched_meta(agent_id, meta)

    old_create = Application.get_env(:evo_git, :worktree_create_fun)
    old_slow = Application.get_env(:evo_git, :worktree_create_slow_warn_ms)
    old_stall = Application.get_env(:evo_git, :worktree_create_stall_timeout_ms)

    # Every parked create task reports itself here so teardown can RELEASE it.
    # Unlinked on purpose: linked helpers die with the test process, and
    # `on_exit` runs in a different process than the test.
    {:ok, parked} = Agent.start(fn -> [] end)

    test_pid = self()

    Application.put_env(:evo_git, :worktree_create_fun, fn _agent_id,
                                                           _repo_root,
                                                           _worktree_path,
                                                           _spec,
                                                           _meta ->
      # `self()` MUST be captured HERE (the create task), never inside the
      # `Agent.update/2` callback, which runs in the Agent's own server process.
      create_task_pid = self()
      Agent.update(parked, &[create_task_pid | &1])
      send(test_pid, {:create_parked, create_task_pid})

      receive do
        :release -> {:error, {:worktree_create_failed, "released by test"}}
      after
        30_000 -> {:error, {:worktree_create_failed, "parked probe timed out"}}
      end
    end)

    on_exit(fn ->
      # Teardown order is load-bearing: release every parked create so the
      # app-global WorktreeManager frees its admission permit, wait for those
      # agent registrations to be released, and ONLY THEN drop the ETS rows and
      # remove the fixture dirs — so no manager cleanup races the removal.
      for pid <- Agent.get(parked, & &1), do: send(pid, :release)

      ExUnit.CaptureLog.capture_log(fn -> await_manager_release(agent_id) end)

      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)

      restore_app_env(:worktree_create_fun, old_create)
      restore_app_env(:worktree_create_slow_warn_ms, old_slow)
      restore_app_env(:worktree_create_stall_timeout_ms, old_stall)

      File.rm_rf(tmp_dir)
      Agent.stop(parked)
    end)

    %{
      agent_id: agent_id,
      tmp_dir: tmp_dir,
      repo_root: repo_root,
      worktree_path: worktree_path,
      task_id: task_id,
      spec: spec,
      meta: meta
    }
  end

  test "a stalled create fails the session diagnosably instead of silencing it",
       %{
         agent_id: agent_id
       } = ctx do
    install_seam(:worktree_create_stall_timeout_ms, 200)
    install_seam(:worktree_create_slow_warn_ms, 100)

    {:ok, pid, ref} = start_session(dispatch_ctx(ctx))

    # The create request is parked INSIDE the worktree manager, i.e. the session
    # process itself is not blocked on it.
    assert_receive {:create_parked, _create_task_pid}, @wait_budget_ms

    # RESPONSIVE during `:starting`: the public API answers while the create hangs.
    assert Session.identity(pid) == {:ok, agent_id}
    assert Session.close(pid) == {:error, {:bad_state, :starting}}

    assert_receive {:agent_session_result, ^agent_id, ^pid,
                    {:error, {:worktree_create_stalled, ms}}},
                   @wait_budget_ms

    assert ms == 200

    assert_receive {:agent_session_closed, ^agent_id, {:error, {:worktree_create_stalled, _}}},
                   @wait_budget_ms

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_budget_ms

    # EXACTLY ONE terminal result for the whole session.
    refute_received {:agent_session_result, ^agent_id, ^pid, _other}
    refute_received {:agent_session_closed, ^agent_id, _other}
  end

  test "force cancel during the start window answers at once", %{agent_id: agent_id} = ctx do
    # A deadline that cannot fire during this test, so the FORCE CANCEL is what
    # ends the session.
    install_seam(:worktree_create_stall_timeout_ms, 60_000)

    {:ok, pid, ref} = start_session(dispatch_ctx(ctx))

    assert_receive {:create_parked, _create_task_pid}, @wait_budget_ms

    assert Session.cancel(pid, :force) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, @wait_budget_ms

    # A force cancel delivers NO result (and no close notice).
    refute_received {:agent_session_result, ^agent_id, ^pid, _result}
    refute_received {:agent_session_closed, ^agent_id, _result}
  end

  # ---------------------------------------------------------------------------
  # Harness — a repo-backed session with real ETS registration rows
  # ---------------------------------------------------------------------------
  defp agent_state(_agent_id, repo_root, _task_id) do
    %AgentState{
      context_node: context_node(repo_root),
      objective: "start stall objective sentinel",
      parent_id: nil,
      archive: false,
      llm_model: "test:model",
      model_id: "session-start-stall-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: 8,
      repo_id: "primary",
      repo_root: repo_root,
      # `WorktreeManager` derives the branch name from these two numbers.
      task_local_id: 1,
      llm_context_window: 200_000
    }
  end

  defp repo_backed_spec(repo_root, sha, tmp_dir) do
    %AgentSpec{
      context_node: context_node(repo_root),
      phylo_node: %PhyloGraphNode{repo: repo_root, base_commit: sha, current_commit: sha},
      agent_module: StubAgent,
      objective: "start stall objective sentinel",
      repo_id: "primary",
      opts: [task_tmpdir: tmp_dir]
    }
  end

  defp sched_meta(agent_id, task_id, spec) do
    %SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: task_id,
      task_number: 1,
      spec: spec,
      from: {self(), make_ref()}
    }
  end

  defp dispatch_ctx(ctx) do
    [
      agent_id: ctx.agent_id,
      depth: 0,
      repo_root: ctx.repo_root,
      repo_id: "primary",
      worktree_path: ctx.worktree_path,
      retries: 0,
      spec: ctx.spec,
      meta: ctx.meta,
      # NO `repo_less` key: the real `WorktreeManager` branch runs (through the
      # parked seam) with this SESSION as the create owner.
      notify: self(),
      # A TEST-OWNED scheduler sink, so a terminal result lands here instead of
      # the app-global scheduler.
      scheduler: self(),
      # The exchange must NEVER run in these tests: the start task never
      # succeeds.
      exchange_opts: [
        llm_call: fn _context, _tools, _params, _agent_id, _retries ->
          raise "the exchange must never run in the start-stall test"
        end
      ]
    ]
  end

  defp start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, pid, ref}
  end

  # The parked create's WorktreeManager cleanup is deferred until its create
  # task finishes, so wait for that registration to be released before the
  # fixture dirs are removed.
  defp await_manager_release(agent_id) do
    wait_until(
      fn ->
        manager_state = :sys.get_state(EvoGit.AgentScheduler.WorktreeManager)
        not Map.has_key?(manager_state.agents, agent_id)
      end,
      @wait_budget_ms
    )
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within the wait budget")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  # --- app-env seams (GLOBAL — restored by the setup's on_exit) ---
  defp install_seam(key, value), do: Application.put_env(:evo_git, key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)

  defp context_node(repo), do: %ContextNode{path: "./", repo: repo}

  defp init_repo!(repo_root) do
    File.mkdir_p!(repo_root)
    {:ok, _} = Git.init(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "initial\n")
    {:ok, _} = Git.add(repo_root)
    {:ok, _} = Git.commit(repo_root, "initial")
    {:ok, sha} = Git.rev_parse(repo_root)
    sha
  end
end
