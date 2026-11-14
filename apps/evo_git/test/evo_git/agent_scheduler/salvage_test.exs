defmodule EvoGit.AgentScheduler.SalvageTest do
  # async: false — this module drives the APP-GLOBAL singleton
  # `EvoGit.AgentScheduler.WorktreeManager` GenServer, mutates the shared named
  # ETS tables `:evogit_agent_summary`, `:evogit_sched_meta` and
  # `:evogit_worktree_repos`, and sets the app-env seams `:worktree_create_fun`
  # and `:worktree_salvage_timeout_ms` plus the `:evogit_cow_worktree_enabled`
  # :persistent_term flag — all of which a concurrently running module observes.
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.Salvage
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.WorktreeManager
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  import ExUnit.CaptureLog

  @agent_id_base 9_970_000

  defmodule StubAgent do
    # The dispatch test never reaches the LLM loop: the worktree-create probe
    # parks the session inside its start task, so only a well-formed spec is
    # needed.
    use EvoGit.Agent

    @impl true
    def system_prompt, do: "salvage test"

    @impl true
    def available_tools, do: []
  end

  # --------------------------------------------------------------------------
  # Shared committed template repo (see worktrees_test.exs for the rationale):
  # one commit, built ONCE per module run, copied per test.
  # --------------------------------------------------------------------------
  setup_all do
    template_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_salvage_tpl_" <> to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(template_dir)
    {:ok, _} = Git.init(template_dir)
    File.write!(Path.join(template_dir, "README.md"), "# test")
    {:ok, _} = Git.add(template_dir)
    {:ok, _} = Git.commit(template_dir, "initial")
    {:ok, base_sha} = Git.rev_parse(template_dir, "HEAD")
    {:ok, _} = Git.run(["config", "user.name", "Genesis"], template_dir)
    {:ok, _} = Git.run(["config", "user.email", "noreply@evogit.ai"], template_dir)
    File.rm_rf!(Path.join(template_dir, ".git/hooks"))
    File.rm_rf!(Path.join(template_dir, ".git/logs"))
    on_exit(fn -> File.rm_rf!(template_dir) end)

    {:ok, template_dir: template_dir, base_sha: base_sha}
  end

  setup %{template_dir: template_dir} do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_salvage_" <> to_string(System.unique_integer([:positive]))
      )

    {:ok, _} = File.cp_r(template_dir, tmp_dir)
    EvoGit.GitEnv.prime_config_identity_cache(tmp_dir, "Genesis", "noreply@evogit.ai")

    create_ets_if_missing(:evogit_agent_summary)
    create_ets_if_missing(:evogit_sched_meta)
    repos_created? = create_worktree_repos_ets()
    clear_ets()
    # Marker present => the lazy per-repo init skips the destructive wipe.
    :ets.insert(:evogit_worktree_repos, {tmp_dir, 0})
    EvoGit.Adapters.CowWorktree.disable()

    old_fun = Application.get_env(:evo_git, :worktree_create_fun)
    old_timeout = Application.get_env(:evo_git, :worktree_salvage_timeout_ms)

    on_exit(fn ->
      restore_app_env(:worktree_create_fun, old_fun)
      restore_app_env(:worktree_salvage_timeout_ms, old_timeout)

      for tab <- [:evogit_agent_summary, :evogit_sched_meta] do
        if :ets.whereis(tab) != :undefined, do: :ets.delete_all_objects(tab)
      end

      if :ets.whereis(:evogit_worktree_repos) != :undefined do
        :ets.delete(:evogit_worktree_repos, tmp_dir)
        if repos_created?, do: :ets.delete(:evogit_worktree_repos)
      end

      :persistent_term.erase(:evogit_cow_worktree_enabled)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ==========================================================================
  # (a) abnormal death => salvage commit exists, anchored, retry bases on it
  # ==========================================================================
  test "abnormal agent death salvages the crashed run's dirty state before reclaim",
       %{tmp_dir: tmp_dir, base_sha: base_sha} do
    agent_id = unique_agent_id()
    {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
    wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
    branch = "evogit-agent-T1-A1"

    agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
    assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000

    # The crashed run's uncommitted work — the try/after auto-commit never runs
    # on an ABNORMAL death, so this is exactly what salvage must preserve.
    File.write!(Path.join(wt_path, "notes.txt"), "dirty work\n")

    down_ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^down_ref, :process, ^agent, :killed}, 10_000

    # The :DOWN handler salvages BEFORE reclaiming; the manager registration is
    # dropped only after the reclaim finished.
    await_manager_dropped(agent_id)

    assert {:ok, sha} = WorktreeManager.salvage_for_retry(agent_id, :killed)
    assert is_binary(sha)
    assert Salvage.commit_exists?(tmp_dir, sha)

    # The salvage ref is the durable anchor (the reclaim deletes the branch).
    assert {:ok, anchored} = Git.run(["rev-parse", "refs/genesis/salvage/#{branch}"], tmp_dir)
    assert String.trim(anchored) == sha
    assert {:ok, content} = Git.run(["show", "#{sha}:notes.txt"], tmp_dir)
    assert String.trim(content) == "dirty work"
    refute Git.branch_exists?(tmp_dir, branch)
    refute File.dir?(wt_path)

    # A retry worktree based on the salvaged sha contains the preserved work.
    retry_id = unique_agent_id()
    {retry_spec, retry_meta} = register_agent(retry_id, tmp_dir, sha, task_local_id: 2)
    retry_wt = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A2")
    retry_agent = spawn_caller(retry_id, tmp_dir, retry_wt, retry_spec, retry_meta)
    assert_receive {:created, ^retry_agent, {:ok, ^retry_wt}}, 30_000
    assert File.read!(Path.join(retry_wt, "notes.txt")) == "dirty work\n"
    finish_agent(retry_agent, retry_id, retry_wt)
  end

  test "a crash retry resumes from the salvaged commit and reports it in the dispatch ctx",
       %{tmp_dir: tmp_dir, base_sha: base_sha} do
    agent_id = unique_agent_id()
    {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
    wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

    agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
    assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000
    File.write!(Path.join(wt_path, "notes.txt"), "dirty work\n")

    assert {:ok, sha} =
             Salvage.salvage(wt_path, tmp_dir,
               base_sha: base_sha,
               branch_name: "evogit-agent-T1-A1"
             )

    assert is_binary(sha)
    # A NORMAL exit takes no salvage of its own; reclaim is unchanged.
    finish_agent(agent, agent_id, wt_path)

    retry_id = unique_agent_id()
    {retry_spec, _retry_meta} = register_agent(retry_id, tmp_dir, base_sha, task_local_id: 2)
    {:ok, retry_meta} = Store.get_sched_meta(retry_id)

    Store.put_sched_meta(retry_id, %{
      retry_meta
      | retries: 1,
        crash_commit: sha,
        crash_reason: {:error, :boom}
    })

    install_create_probe()

    state = %{
      State.from_model_profiles([%{id: "salvage-dispatch", model: "test:model", concurrency: 1}])
      | next_agent_id: retry_id,
        agent_max_retries: 0
    }

    task_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {^retry_id, state} =
      Dispatch.register_agent(state, retry_spec, {self(), make_ref()}, nil, 0, task_id, 1)

    # Registration rewrites both rows for the resolved id; re-seed the retry
    # shape (retries + salvaged commit + crash reason) on the surviving rows.
    Store.put_agent_state(retry_id, build_agent_state(tmp_dir, 2))

    Store.put_sched_meta(retry_id, %{
      retry_meta
      | retries: 1,
        crash_commit: sha,
        crash_reason: {:error, :boom}
    })

    dispatched = Dispatch.try_dispatch(state, retry_id)

    _state =
      case dispatched do
        {:noreply, state} -> state
        %State{} = state -> state
      end

    assert_receive {:create_parked, create_pid, ^retry_id, _wt, parked_spec, _parked_meta}, 15_000

    # The retry base is the salvaged commit, persisted on the SchedMeta row.
    assert parked_spec.phylo_node.current_commit == sha
    assert {:ok, %SchedMeta{crash_commit: ^sha}} = Store.get_sched_meta(retry_id)

    ctx = dispatch_ctx(retry_id)
    assert ctx[:worktree_resume_from] == sha
    assert ctx[:retry_reason] == {:error, :boom}
    assert ctx[:retries] == 1

    send(create_pid, {:release, :fail})
    await_session_gone(retry_id)
  end

  # ==========================================================================
  # (b) salvage failure / timeout => fall back to the task base, still dispatch
  # ==========================================================================
  test "a salvage timeout falls back to the task base and reclaims normally",
       %{tmp_dir: tmp_dir, base_sha: base_sha} do
    Application.put_env(:evo_git, :worktree_salvage_timeout_ms, 1)

    agent_id = unique_agent_id()
    {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
    wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
    branch = "evogit-agent-T1-A1"

    agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
    assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000
    File.write!(Path.join(wt_path, "notes.txt"), "dirty work\n")

    down_ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^down_ref, :process, ^agent, :killed}, 10_000
    await_manager_dropped(agent_id)

    # Salvage failed => nothing retained, nothing anchored, reclaim unchanged.
    assert {:ok, nil} = WorktreeManager.salvage_for_retry(agent_id, :killed)
    assert {:error, _} = Git.run(["rev-parse", "refs/genesis/salvage/#{branch}"], tmp_dir)
    refute File.dir?(wt_path)

    # The retry therefore falls back to the task base and still dispatches.
    retry_id = unique_agent_id()
    {retry_spec, retry_meta} = register_agent(retry_id, tmp_dir, base_sha, task_local_id: 2)
    retry_wt = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A2")
    retry_agent = spawn_caller(retry_id, tmp_dir, retry_wt, retry_spec, retry_meta)
    assert_receive {:created, ^retry_agent, {:ok, ^retry_wt}}, 30_000
    refute File.exists?(Path.join(retry_wt, "notes.txt"))
    finish_agent(retry_agent, retry_id, retry_wt)
  end

  test "salvage of an absent worktree is an error, never a raise",
       %{tmp_dir: tmp_dir, base_sha: base_sha} do
    missing = Path.join(tmp_dir, ".genesis/workers/worker_T9_A9")

    assert {:error, _reason} =
             Salvage.salvage(missing, tmp_dir, base_sha: base_sha, branch_name: "gone")

    refute Salvage.commit_exists?(tmp_dir, base_sha <> "dead")
  end

  # ==========================================================================
  # (c) normal / shutdown exits => NO salvage, byte-identical reclaim
  # ==========================================================================
  test "a normal exit takes no salvage and reclaim is unchanged",
       %{tmp_dir: tmp_dir, base_sha: base_sha} do
    agent_id = unique_agent_id()
    {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
    wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

    agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
    assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000
    File.write!(Path.join(wt_path, "notes.txt"), "dirty work\n")

    finish_agent(agent, agent_id, wt_path)

    assert {:ok, nil} = WorktreeManager.salvage_for_retry(agent_id, :normal)

    assert {:error, _} =
             Git.run(["rev-parse", "refs/genesis/salvage/evogit-agent-T1-A1"], tmp_dir)

    assert {:ok, %SchedMeta{crash_commit: nil}} = Store.get_sched_meta(agent_id)
  end

  test "a shutdown exit takes no salvage", %{tmp_dir: tmp_dir, base_sha: base_sha} do
    agent_id = unique_agent_id()
    {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
    wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

    agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
    assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000
    File.write!(Path.join(wt_path, "notes.txt"), "dirty work\n")

    down_ref = Process.monitor(agent)
    Process.exit(agent, :shutdown)
    assert_receive {:DOWN, ^down_ref, :process, ^agent, :shutdown}, 10_000
    await_manager_dropped(agent_id)

    assert {:ok, nil} = WorktreeManager.salvage_for_retry(agent_id, :shutdown)
    assert {:ok, nil} = WorktreeManager.salvage_for_retry(agent_id, {:shutdown, :upgrade})

    assert {:error, _} =
             Git.run(["rev-parse", "refs/genesis/salvage/evogit-agent-T1-A1"], tmp_dir)

    # (d) reclaim still removes the worktree directory.
    refute File.dir?(wt_path)
  end

  # --------------------------------------------------------------------------
  # Fixture helpers
  # --------------------------------------------------------------------------
  defp unique_agent_id do
    System.unique_integer([:positive, :monotonic]) + @agent_id_base
  end

  defp build_spec(tmp_dir, base_sha) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: tmp_dir},
      phylo_node: %PhyloGraphNode{repo: tmp_dir, base_commit: base_sha, current_commit: base_sha},
      agent_module: StubAgent,
      objective: "salvage test",
      repo_id: "primary",
      opts: [model_id_locked: true]
    }
  end

  defp build_meta(agent_id, spec, task_number) do
    %SchedMeta{id: agent_id, depth: 0, spec: spec, retries: 0, task_number: task_number}
  end

  defp build_agent_state(tmp_dir, task_local_id) do
    %AgentState{
      context_node: %ContextNode{path: "./", repo: tmp_dir},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8,
      repo_root: tmp_dir,
      task_local_id: task_local_id
    }
  end

  defp register_agent(agent_id, tmp_dir, base_sha, opts \\ []) do
    task_number = Keyword.get(opts, :task_number, 1)
    task_local_id = Keyword.get(opts, :task_local_id, 1)

    spec = build_spec(tmp_dir, base_sha)
    meta = build_meta(agent_id, spec, task_number)
    Store.put_agent_state(agent_id, build_agent_state(tmp_dir, task_local_id))
    Store.put_sched_meta(agent_id, meta)
    {spec, meta}
  end

  # The caller process stands in for the agent: the manager monitors it, so an
  # abnormal exit of this process is an agent crash.
  defp spawn_caller(agent_id, repo_root, worktree_path, spec, meta) do
    parent = self()

    spawn(fn ->
      result =
        WorktreeManager.create_worktree_for_agent(
          agent_id,
          repo_root,
          worktree_path,
          spec,
          meta,
          self()
        )

      send(parent, {:created, self(), result})

      receive do
        :exit_please -> :ok
      end
    end)
  end

  defp finish_agent(agent, agent_id, wt_path) do
    down_ref = Process.monitor(agent)
    send(agent, :exit_please)
    assert_receive {:DOWN, ^down_ref, :process, ^agent, _reason}, 10_000
    await_manager_dropped(agent_id)
    refute File.dir?(wt_path)
  end

  defp install_create_probe do
    test_pid = self()

    Application.put_env(:evo_git, :worktree_create_fun, fn agent_id,
                                                           _repo_root,
                                                           worktree_path,
                                                           spec,
                                                           meta ->
      send(test_pid, {:create_parked, self(), agent_id, worktree_path, spec, meta})

      receive do
        {:release, :materialize} ->
          File.mkdir_p!(worktree_path)
          {:ok, worktree_path}

        {:release, other} ->
          {:error, {:worktree_create_failed, "probe released with #{inspect(other)}"}}
      after
        30_000 -> {:error, {:worktree_create_failed, "probe timeout"}}
      end
    end)
  end

  defp dispatch_ctx(agent_id) do
    wait_until(fn -> session_pid(agent_id) != nil end, 10_000)
    pid = session_pid(agent_id)
    assert pid != nil

    case :sys.get_state(pid) do
      {_phase, %{dispatch_ctx: ctx}} -> ctx
      %{dispatch_ctx: ctx} -> ctx
    end
  end

  defp session_pid(agent_id) do
    case Registry.lookup(EvoGit.Agent.Session.Registry, agent_id) do
      [{pid, _value}] -> pid
      _ -> nil
    end
  end

  defp await_manager_dropped(agent_id, timeout \\ 30_000) do
    wait_until(
      fn -> not Map.has_key?(:sys.get_state(WorktreeManager).agents, agent_id) end,
      timeout
    )
  end

  defp await_session_gone(agent_id, timeout \\ 10_000) do
    wait_until(fn -> session_pid(agent_id) == nil end, timeout)
  end

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  defp create_worktree_repos_ets do
    if :ets.whereis(:evogit_worktree_repos) == :undefined do
      :ets.new(:evogit_worktree_repos, [:named_table, :public, :set, read_concurrency: true])
      true
    else
      false
    end
  end

  defp clear_ets do
    for tab <- [:evogit_agent_summary, :evogit_sched_meta] do
      if :ets.whereis(tab) != :undefined, do: :ets.delete_all_objects(tab)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)

  defp wait_until(fun, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, 1)
  end

  defp do_wait_until(fun, deadline, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        beat = min(interval, 15)
        Process.sleep(beat)
        do_wait_until(fun, deadline, beat * 2)

      true ->
        flunk("wait_until timed out")
    end
  end
end
