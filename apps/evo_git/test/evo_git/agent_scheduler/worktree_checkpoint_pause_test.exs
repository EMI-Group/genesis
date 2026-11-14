defmodule EvoGit.AgentScheduler.WorktreeCheckpointPauseTest do
  # async: false — this module drives the APP-GLOBAL singleton
  # `EvoGit.AgentScheduler.WorktreeManager` GenServer, mutates the shared named
  # ETS tables `:evogit_agent_summary`, `:evogit_sched_meta` and
  # `:evogit_worktree_repos`, and sets the app-env seam
  # `:worktree_salvage_timeout_ms` plus the `:evogit_cow_worktree_enabled`
  # :persistent_term flag — all of which a concurrently running module observes.
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Salvage
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.WorktreeManager
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @moduledoc """
  Pins `EvoGit.AgentScheduler.WorktreeManager.checkpoint_for_pause/1` — the
  worktree half of a TASK-LEVEL PAUSE.

  A pause is a CLEAN exit, so unlike `salvage_for_retry/2` there is no
  abnormal-exit gate: the CURRENT worktree is committed and anchored under
  `refs/genesis/salvage/<branch>` (the reclaim that follows the paused
  session's stop deletes the agent branch, so an unanchored commit would be
  unreachable exactly when the resume needs it), and the worktree is NEVER
  reclaimed here — the session still owns it.
  """

  @agent_id_base 10_030_000
  @dirty_file "notes.txt"
  @dirty_content "work done before the pause\n"
  @branch "evogit-agent-T1-A1"

  defmodule StubAgent do
    # `checkpoint_for_pause/1` only inspects the manager's live-worktree record,
    # so only a well-formed spec is needed.
    use EvoGit.Agent
    def system_prompt, do: "worktree checkpoint pause test"
    def available_tools, do: []
  end

  # --------------------------------------------------------------------------
  # Shared committed template repo, copied per test (same rationale as
  # `worktrees_test.exs`/`salvage_test.exs`: one build per module run).
  # --------------------------------------------------------------------------
  setup_all do
    template_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_pause_checkpoint_tpl_" <> to_string(System.unique_integer([:positive]))
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
        "evogit_pause_checkpoint_" <> to_string(System.unique_integer([:positive]))
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

    old_timeout = Application.get_env(:evo_git, :worktree_salvage_timeout_ms)

    on_exit(fn ->
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

  describe "checkpoint_for_pause/1 on a DIRTY worktree" do
    test "commits the uncommitted work and anchors it under refs/genesis/salvage/<branch>",
         %{tmp_dir: tmp_dir, base_sha: base_sha} do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
      assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000

      # A pause happens mid-run: this is the work that must survive.
      File.write!(Path.join(wt_path, @dirty_file), @dirty_content)

      assert {:ok, %{commit: sha, branch: @branch}} =
               WorktreeManager.checkpoint_for_pause(agent_id)

      assert is_binary(sha)
      refute sha == base_sha

      # The commit is real and its tree carries the change.
      assert Salvage.commit_exists?(tmp_dir, sha)
      assert {:ok, content} = Git.run(["show", "#{sha}:#{@dirty_file}"], tmp_dir)
      assert String.trim(content) == String.trim(@dirty_content)

      # The retention ref is the durable anchor: the reclaim that follows the
      # paused session's stop deletes the agent branch, the ref survives.
      assert {:ok, anchored} = Git.run(["rev-parse", "refs/genesis/salvage/#{@branch}"], tmp_dir)
      assert String.trim(anchored) == sha

      # The worktree is NOT reclaimed by the checkpoint — the session still owns
      # it until it stops, and its branch is untouched.
      assert File.dir?(wt_path)
      assert Git.branch_exists?(tmp_dir, @branch)

      finish_agent(agent, agent_id, wt_path)
    end

    test "the anchored commit outlives the reclaim that follows the stop",
         %{tmp_dir: tmp_dir, base_sha: base_sha} do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
      assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000

      File.write!(Path.join(wt_path, @dirty_file), @dirty_content)
      assert {:ok, %{commit: sha}} = WorktreeManager.checkpoint_for_pause(agent_id)

      # The stop reclaims the worktree and deletes the agent branch; the resume
      # base is still resolvable through the salvage ref.
      finish_agent(agent, agent_id, wt_path)

      refute File.dir?(wt_path)
      refute Git.branch_exists?(tmp_dir, @branch)
      assert Salvage.commit_exists?(tmp_dir, sha)
      assert {:ok, content} = Git.run(["show", "#{sha}:#{@dirty_file}"], tmp_dir)
      assert String.trim(content) == String.trim(@dirty_content)

      # A second checkpoint for the now-reclaimed agent degrades to `{:ok, nil}`.
      assert {:ok, nil} = WorktreeManager.checkpoint_for_pause(agent_id)
    end
  end

  describe "checkpoint_for_pause/1 on a CLEAN worktree" do
    test "still returns the current HEAD sha, so the resume base is always defined",
         %{tmp_dir: tmp_dir, base_sha: base_sha} do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, task_local_id: 1)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      agent = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)
      assert_receive {:created, ^agent, {:ok, ^wt_path}}, 30_000

      assert {:ok, head_sha} = Git.rev_parse(wt_path, "HEAD")

      # Nothing was written: `:base_sha` is deliberately NOT passed, so the
      # clean case answers the HEAD instead of `{:ok, nil}`.
      assert {:ok, %{commit: sha, branch: @branch}} =
               WorktreeManager.checkpoint_for_pause(agent_id)

      assert sha == head_sha
      assert {:ok, anchored} = Git.run(["rev-parse", "refs/genesis/salvage/#{@branch}"], tmp_dir)
      assert String.trim(anchored) == sha
      assert File.dir?(wt_path)

      finish_agent(agent, agent_id, wt_path)
    end
  end

  describe "checkpoint_for_pause/1 on an absent agent" do
    test "answers the documented degraded shape and never raises", %{tmp_dir: tmp_dir} do
      # Never registered with the manager.
      assert {:ok, nil} = WorktreeManager.checkpoint_for_pause(unique_agent_id())
      # A registered agent with no LIVE worktree yet (queued/creating) has
      # nothing to checkpoint — and equally nothing to reclaim.
      assert {:ok, nil} = WorktreeManager.checkpoint_for_pause(unique_agent_id())
      # Non-integer input is total too (guarded clauses, no call).
      assert {:ok, nil} = WorktreeManager.checkpoint_for_pause("nope")
      assert {:ok, nil} = WorktreeManager.checkpoint_for_pause(nil)
      # No stray commit or salvage ref was produced for the unknown agent.
      assert {:error, _} =
               Git.run(["rev-parse", "refs/genesis/salvage/evogit-agent-T9-A9"], tmp_dir)
    end
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
      objective: "worktree checkpoint pause test",
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

  defp register_agent(agent_id, tmp_dir, base_sha, opts) do
    task_number = Keyword.get(opts, :task_number, 1)
    task_local_id = Keyword.get(opts, :task_local_id, 1)
    spec = build_spec(tmp_dir, base_sha)
    meta = build_meta(agent_id, spec, task_number)
    Store.put_agent_state(agent_id, build_agent_state(tmp_dir, task_local_id))
    Store.put_sched_meta(agent_id, meta)
    {spec, meta}
  end

  # The caller process stands in for the agent: the manager monitors it, so its
  # exit is the agent's exit (and `:live` is what `checkpoint_for_pause/1`
  # requires).
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

  defp await_manager_dropped(agent_id, timeout \\ 30_000) do
    wait_until(
      fn -> not Map.has_key?(:sys.get_state(WorktreeManager).agents, agent_id) end,
      timeout
    )
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

  defp wait_until(fun, timeout) do
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
