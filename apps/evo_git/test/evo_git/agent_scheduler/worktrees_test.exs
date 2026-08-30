defmodule EvoGit.AgentScheduler.WorktreesTest do
  # async: false — WorktreeManager is a named GenServer with shared state
  # across tests (agents/monitors/pending maps), and the tests manipulate the
  # global named ETS tables (:evogit_agent_state, :evogit_sched_meta).
  # The Application starts the WorktreeManager, so it is available.
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.WorktreeManager
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  import ExUnit.CaptureLog

  defmodule DummyAgent do
    # The create pipeline never calls the agent module — this only needs to
    # exist so the %AgentSpec{} is well-formed.
  end

  # --------------------------------------------------------------------------
  # Shared temp git-repo setup (mirrors test/evo_git/runtime/helpers_test.exs)
  # --------------------------------------------------------------------------
  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_worktrees_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    {:ok, _} = Git.init(tmp_dir)

    # Create an initial commit so HEAD exists and branches can be created.
    File.write!(Path.join(tmp_dir, "README.md"), "# test")
    {:ok, _} = Git.add(tmp_dir, "README.md")
    {:ok, _} = Git.commit(tmp_dir, "initial commit")
    {:ok, base_sha} = Git.rev_parse(tmp_dir)

    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    # The WorktreeManager's persistent per-repo init-marker table. The lib
    # owns this table in production (created in EvoGit.Application.start/2);
    # until that merge lands, tests create it themselves. Track whether THIS
    # test created it so on_exit deletes it ONLY if self-created (never an
    # app-owned table).
    worktree_repos_self_created = create_worktree_repos_ets()
    clear_ets()

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      clear_ets()

      if worktree_repos_self_created do
        if :ets.whereis(:evogit_worktree_repos) != :undefined do
          :ets.delete(:evogit_worktree_repos)
        end
      end
    end)

    {:ok, %{tmp_dir: tmp_dir, base_sha: base_sha}}
  end

  # --- ETS helpers (pattern from lifecycle_test.exs) ---

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
  end

  # Creates the WorktreeManager's persistent per-repo init-marker table when
  # the app does not own it yet (pre-lib-merge test env). Returns true when
  # THIS test created it (so on_exit can delete it), false when the app owns
  # it. Mirrors the app's table options (:named_table/:public/:set +
  # read_concurrency), same as the other scheduler tables.
  defp create_worktree_repos_ets do
    if :ets.whereis(:evogit_worktree_repos) == :undefined do
      :ets.new(:evogit_worktree_repos, [:named_table, :public, :set, read_concurrency: true])
      true
    else
      false
    end
  end

  # Builds a well-formed %Task{} struct carrying the given pid — the shape
  # Dispatch.try_dispatch/2 stores in SchedMeta.task_ref (production sets
  # worktree + task_ref BEFORE the Runner requests the worktree). The
  # crash-restart re-monitor (rebuild_monitor/3) only reads task_ref.pid, but
  # the struct must be constructible — Elixir >= 1.18 Task enforces
  # [:mfa, :owner, :ref].
  defp task_ref_for(pid) do
    %Task{pid: pid, ref: make_ref(), owner: pid, mfa: {DummyAgent, :run, []}}
  end

  # Restarts the WorktreeManager so its `init/1` runs again — the crash-restart
  # code path under test (`rebuild_monitors/1` + marker-gated `maybe_init_repo`).
  # The running agent Tasks keep going in their live worktrees: that is exactly
  # the crash-cascade scenario under test.
  #
  # NOTE — deliberately NOT `Process.exit(pid, :kill)`: the full-dir suite ALSO
  # crash-restarts other supervisor children (PubSubTest kills the PubSub
  # Throttle), and EvoGit.Supervisor's default restart intensity is 3 restarts /
  # 5s. Repeated `:kill` restarts across files exhaust the budget — on the
  # intensity-exceeded path the supervisor permanently stops the child (and
  # tears down the whole app), which made these tests flaky in the full-dir
  # run (the 3rd kill in this file + PubSubTest's kill = 4 restarts in the
  # window). The supervisor's explicit terminate_child + restart_child pair
  # runs the SAME `start_link` → `init` → `rebuild_monitors` path as a crash
  # restart (that is the code under test) WITHOUT consuming the
  # automatic-restart budget — the same pattern the suite already uses to
  # restart Store/TaskRegistry/SystemSampler.
  defp restart_manager(timeout \\ 10_000) do
    old_pid = Process.whereis(WorktreeManager)
    assert is_pid(old_pid)

    :ok = Supervisor.terminate_child(EvoGit.Supervisor, WorktreeManager)
    assert {:ok, new_pid} = Supervisor.restart_child(EvoGit.Supervisor, WorktreeManager)
    assert new_pid != old_pid

    # restart_child is synchronous (the name registers inside start_link), but
    # keep the poll as belt-and-braces for slow filesystems/CI.
    wait_until(
      fn ->
        Process.whereis(WorktreeManager) == new_pid
      end,
      timeout
    )

    new_pid
  end

  # --- Agent registration helpers ---

  defp unique_agent_id, do: :erlang.unique_integer([:positive])

  defp build_spec(tmp_dir, base_sha) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: tmp_dir},
      phylo_node: %PhyloGraphNode{repo: tmp_dir, base_commit: base_sha, current_commit: base_sha},
      agent_module: DummyAgent,
      objective: "test",
      repo_id: "primary"
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

  # Writes both ETS entries so the WorktreeManager create pipeline can derive
  # the branch name. Returns {spec, meta} for the create call.
  defp register_agent(agent_id, tmp_dir, base_sha, opts \\ []) do
    task_number = Keyword.get(opts, :task_number, 1)
    task_local_id = Keyword.get(opts, :task_local_id, 1)
    repo_id = Keyword.get(opts, :repo_id, "primary")
    spec = %{build_spec(tmp_dir, base_sha) | repo_id: repo_id}
    meta = build_meta(agent_id, spec, task_number)
    Store.put_agent_state(agent_id, build_agent_state(tmp_dir, task_local_id))
    Store.put_sched_meta(agent_id, meta)
    {spec, meta}
  end

  # --- Async-cleanup poll helper ---

  defp wait_until(fun, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(15)
        do_wait_until(fun, deadline)

      true ->
        flunk("wait_until timed out")
    end
  end

  # ==========================================================================
  # create_worktree_for_agent/6 — the WorktreeManager GenServer
  # ==========================================================================
  describe "create_worktree_for_agent/6" do
    test "creates and prepares a fresh worktree", %{tmp_dir: tmp_dir, base_sha: base_sha} do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      assert {:ok, ^wt_path} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id,
                 tmp_dir,
                 wt_path,
                 spec,
                 meta,
                 self()
               )

      # Worktree directory exists, is a real git worktree, and has the
      # initial commit's file checked out.
      assert File.dir?(wt_path)
      assert File.read!(Path.join(wt_path, "README.md")) == "# test"

      {:ok, branches} = Git.list_branches(tmp_dir)
      assert branch in branches

      # assign_and_prepare_worktree/2 bound phylo_node.repo to the worktree.
      {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.phylo_node.repo == wt_path
    end

    test "first-time create emits no spurious leftover-branch warning", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # The branch does not exist yet — destroy_leftovers/3 runs before every
      # create, and its tolerant delete must treat "branch not found" as a
      # silent no-op instead of logging a spurious warning on every
      # first-time create.
      refute Git.branch_exists?(tmp_dir, branch)

      log =
        capture_log(fn ->
          assert {:ok, ^wt_path} =
                   WorktreeManager.create_worktree_for_agent(
                     agent_id,
                     tmp_dir,
                     wt_path,
                     spec,
                     meta,
                     self()
                   )
        end)

      refute log =~ "leftover branch"
      refute log =~ "Failed to delete branch"
    end

    test "reclaims the worktree when the agent process exits normally", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # The monitored pid — after the create returns it WAITS for an exit
      # signal instead of exiting immediately. The manager's monitor-driven
      # destroy (rm_rf + prune + branch delete) can complete before this test
      # process gets its first poll below, making the dir unobservable — the
      # agent must not exit until the test has confirmed creation.
      agent =
        spawn(fn ->
          WorktreeManager.create_worktree_for_agent(
            agent_id,
            tmp_dir,
            wt_path,
            spec,
            meta,
            self()
          )

          receive do
            :exit_please -> :ok
          end
        end)

      # Creation is real git I/O (lazy repo init + leftover destroy + CoW or
      # `git worktree add` + clean/checkout) and production allows up to 1h
      # for it (`@worktree_call_timeout`) — under load on slow machines 5s
      # (the helper default) is not enough and the test flakes.
      wait_until(fn -> File.dir?(wt_path) end, 30_000)
      assert Git.branch_exists?(tmp_dir, branch)

      # Release the agent — its :normal exit triggers monitor-driven cleanup,
      # which is async: poll until dir AND branch are gone (real git I/O, so
      # use the same 30s deadline as creation rather than the 5s default).
      send(agent, :exit_please)

      wait_until(
        fn -> not File.dir?(wt_path) and not Git.branch_exists?(tmp_dir, branch) end,
        30_000
      )
    end

    test "reclaims the worktree when the agent process crashes", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # Same exit-gating as the normal-exit test above: the agent waits for
      # the test's signal so the manager's monitor-driven destroy cannot race
      # ahead of the creation observation below.
      agent =
        spawn(fn ->
          WorktreeManager.create_worktree_for_agent(
            agent_id,
            tmp_dir,
            wt_path,
            spec,
            meta,
            self()
          )

          receive do
            :exit_please -> Process.exit(self(), :kill)
          end
        end)

      # Same creation-wait deadline rationale as the normal-exit test above.
      wait_until(fn -> File.dir?(wt_path) end, 30_000)
      assert Git.branch_exists?(tmp_dir, branch)

      # Release the agent — its abnormal exit triggers cleanup identical to
      # the normal-exit case (no reuse semantics), async: poll until dir AND
      # branch are gone with the same 30s deadline as creation.
      send(agent, :exit_please)

      wait_until(
        fn -> not File.dir?(wt_path) and not Git.branch_exists?(tmp_dir, branch) end,
        30_000
      )
    end

    test "destroys a stale real worktree before creating a fresh one", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # A REAL stale git worktree at the target path, with a marker file
      # dropped inside it (simulates a leftover from a crashed previous run).
      File.mkdir_p!(Path.dirname(wt_path))
      {:ok, _} = Git.add_worktree(tmp_dir, wt_path, base_sha, branch)
      marker = Path.join(wt_path, "stale-marker.txt")
      File.write!(marker, "stale")
      assert File.exists?(marker)

      assert {:ok, ^wt_path} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id,
                 tmp_dir,
                 wt_path,
                 spec,
                 meta,
                 self()
               )

      # The stale marker is gone — replaced by a fresh checkout.
      refute File.exists?(marker)
      assert File.read!(Path.join(wt_path, "README.md")) == "# test"
    end

    test "retry-after-crash gets a fresh worktree", %{tmp_dir: tmp_dir, base_sha: base_sha} do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      parent = self()

      # Proc A creates the worktree, then crashes. The create reply goes to
      # proc A itself (it passes self() as the monitored agent pid).
      spawn(fn ->
        WorktreeManager.create_worktree_for_agent(agent_id, tmp_dir, wt_path, spec, meta, self())
        Process.exit(self(), :kill)
      end)

      wait_until(fn -> File.dir?(wt_path) end)

      # IMMEDIATELY re-create for the SAME agent_id — the old agent's :DOWN
      # has likely not been processed yet (retry-after-crash race). Must
      # succeed regardless of which manager branch handles it.
      proc_b =
        spawn(fn ->
          result =
            WorktreeManager.create_worktree_for_agent(
              agent_id,
              tmp_dir,
              wt_path,
              spec,
              meta,
              self()
            )

          send(parent, {:recreated, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:recreated, {:ok, ^wt_path}}, 10_000

      # Exactly one valid worktree exists.
      assert File.dir?(wt_path)
      assert File.read!(Path.join(wt_path, "README.md")) == "# test"
      {:ok, branches} = Git.list_branches(tmp_dir)
      assert branch in branches

      # Kill proc B so the monitor-driven cleanup reclaims the worktree and
      # the registration does not leak into later tests.
      Process.exit(proc_b, :kill)

      wait_until(fn ->
        not File.dir?(wt_path) and not Git.branch_exists?(tmp_dir, branch)
      end)
    end

    test "defers a re-create request while the previous create is still in flight", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      # Deterministic serialization probe: a sleeping worktree init script
      # keeps the first create in flight long enough to observe the deferral.
      # The script is a /bin/sh script — skip on Windows.
      if EvoGit.Platform.windows?() do
        :ok
      else
        agent_id = unique_agent_id()
        {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
        wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
        branch = "evogit-agent-T1-A1"

        File.write!(
          Path.join(tmp_dir, "genesis.toml"),
          "[worktree]\nscript = \"#!/bin/sh\\nsleep 2\"\n"
        )

        parent = self()

        proc_a =
          spawn(fn ->
            result =
              WorktreeManager.create_worktree_for_agent(
                agent_id,
                tmp_dir,
                wt_path,
                spec,
                meta,
                self()
              )

            send(parent, {:first_create, result})
            Process.sleep(:infinity)
          end)

        # The dir exists once the create task has finished the git part and is
        # inside the init-script sleep (~2s) — i.e. the create is still in
        # flight (creating: true in the manager).
        wait_until(fn -> File.dir?(wt_path) end)

        # Kill the agent mid-create — cleanup is deferred until the create
        # task finishes.
        Process.exit(proc_a, :kill)

        # The re-create for the same agent_id must be deferred
        # (pending_requests) and eventually succeed with one valid worktree.
        assert {:ok, ^wt_path} =
                 WorktreeManager.create_worktree_for_agent(
                   agent_id,
                   tmp_dir,
                   wt_path,
                   spec,
                   meta,
                   self()
                 )

        assert File.dir?(wt_path)
        assert File.read!(Path.join(wt_path, "README.md")) == "# test"
        {:ok, branches} = Git.list_branches(tmp_dir)
        assert branch in branches
      end
    end

    test "runs the configured worktree init script on create", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      # The init script is a /bin/sh script — skip on Windows.
      if EvoGit.Platform.windows?() do
        :ok
      else
        agent_id = unique_agent_id()
        {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
        wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

        File.write!(
          Path.join(tmp_dir, "genesis.toml"),
          "[worktree]\nscript = \"#!/bin/sh\\ntouch \\\"$TARGET_WORKTREE_PATH/init-marker.txt\\\"\"\n"
        )

        assert {:ok, ^wt_path} =
                 WorktreeManager.create_worktree_for_agent(
                   agent_id,
                   tmp_dir,
                   wt_path,
                   spec,
                   meta,
                   self()
                 )

        assert File.exists?(Path.join(wt_path, "init-marker.txt"))
      end
    end
  end

  # ==========================================================================
  # Worktrees.assign_and_prepare_worktree/3 — linked-worktree guard
  # (foreign-repo main-HEAD-leak hardening)
  # ==========================================================================
  #
  # `Git.clean`/`Git.checkout` against a PLAIN unregistered dir act on the
  # repo's MAIN working copy — moving its HEAD onto the agent branch (the
  # foreign-repo main-HEAD leak). The guard (`ensure_linked_worktree/2`)
  # asserts `wt` is a REGISTERED linked worktree (a `.git` FILE whose
  # `gitdir:` content points under `<repo_root>/.git/worktrees/`) BEFORE any
  # git runs.
  describe "assign_and_prepare_worktree/3" do
    test "refuses a plain unregistered dir at the wt path", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {_spec, _meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # A PLAIN dir at the worktree path (no `.git` file, not registered) —
      # the dangerous broken-registration state. The guard must refuse
      # WITHOUT running any git against it. (Actual lib return shape is the
      # unwrapped `{:worktree_prepare_failed, :not_a_linked_worktree}` — the
      # `with` else clause passes the guard error through without the outer
      # `:error` wrapper.)
      File.mkdir_p!(wt_path)
      File.write!(Path.join(wt_path, "junk.txt"), "junk")

      assert {:worktree_prepare_failed, :not_a_linked_worktree} =
               Worktrees.assign_and_prepare_worktree(agent_id, wt_path, tmp_dir)

      # Main HEAD untouched; the plain dir survives (not deleted, not
      # git-touched); the agent branch was never created; the agent state's
      # phylo_node stays nil (never worktree-bound).
      assert {:ok, ^base_sha} = Git.rev_parse(tmp_dir)
      assert File.dir?(wt_path)
      refute Git.branch_exists?(tmp_dir, branch)
      {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.phylo_node == nil
    end

    test "refuses the repo ROOT itself as the wt path", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {_spec, _meta} = register_agent(agent_id, tmp_dir, base_sha)

      # The repo root has a `.git` DIRECTORY — not a linked-worktree `.git`
      # FILE — so the guard refuses without running any git against the main
      # copy. HEAD stays put. (Return shape as in the plain-dir test above:
      # unwrapped `{:worktree_prepare_failed, :not_a_linked_worktree}`.)
      assert {:worktree_prepare_failed, :not_a_linked_worktree} =
               Worktrees.assign_and_prepare_worktree(agent_id, tmp_dir, tmp_dir)

      assert {:ok, ^base_sha} = Git.rev_parse(tmp_dir)
    end

    test "accepts a real registered linked worktree and binds phylo_node to it", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {_spec, _meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      File.mkdir_p!(Path.dirname(wt_path))
      {:ok, _} = Git.add_worktree(tmp_dir, wt_path, base_sha, branch)

      assert {:ok, ^base_sha} =
               Worktrees.assign_and_prepare_worktree(agent_id, wt_path, tmp_dir)

      # The worktree-bound phylo_node (repo points at the WORKTREE, not the
      # main copy).
      {:ok, agent_state} = Store.get_agent_state(agent_id)
      assert agent_state.phylo_node.repo == wt_path
    end
  end

  # ==========================================================================
  # per-repo init scoping — foreign repos preserve real task branches
  # ==========================================================================
  #
  # `maybe_init_repo/3` is private; it runs inside the public
  # `create_worktree_for_agent/6` GenServer call, gated on
  # `EvoGit.Core.ForeignRepo.primary?(spec.repo_id)` (worktree_manager.ex:152/161).
  # On a repo's FIRST create request (persistent per-repo init marker
  # `:evogit_worktree_repos` absent) it wipes the workers dir AND deletes EVERY
  # `evogit-agent-*` branch — but ONLY for the PRIMARY repo. Foreign repos may
  # hold REAL task work from previous runs, so their lazy init must skip the
  # destructive steps. Each test uses its own fresh temp repo (no marker yet)
  # so the first-create path is what runs.
  describe "per-repo init scoping (foreign vs primary)" do
    test "foreign repo first init preserves real task branches (no orphan cleanup)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      # A REAL task branch from a previous run — a plain ref at HEAD, never
      # checked out: exactly what the primary-repo orphan cleanup
      # (`clean_orphaned_branches/1`) would delete.
      real_branch = "evogit-agent-T99-A99"
      {:ok, _} = Git.create_branch(tmp_dir, real_branch, base_sha)
      assert Git.branch_exists?(tmp_dir, real_branch)

      # First create for this repo (fresh temp repo — no persistent marker
      # yet), with a FOREIGN repo id: the lazy per-repo init must skip the
      # destructive wipe (rm_rf workers dir + orphaned-branch cleanup).
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, repo_id: "original")
      refute ForeignRepo.primary?(spec.repo_id)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

      assert {:ok, ^wt_path} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id,
                 tmp_dir,
                 wt_path,
                 spec,
                 meta,
                 self()
               )

      # The real task branch must SURVIVE the foreign-repo init. (The create
      # itself makes its own evogit-agent-T1-A1 worktree branch — assert only
      # on the pre-existing real branch.)
      assert Git.branch_exists?(tmp_dir, real_branch)
      assert File.dir?(wt_path)
    end

    test "primary repo first init wipes real task branches (orphan cleanup)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      real_branch = "evogit-agent-T99-A99"
      {:ok, _} = Git.create_branch(tmp_dir, real_branch, base_sha)
      assert Git.branch_exists?(tmp_dir, real_branch)

      # Primary repo id → the destructive first-init runs: rm_rf the workers
      # dir + `clean_orphaned_branches/1` deletes EVERY evogit-agent-* branch.
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha, repo_id: "primary")
      assert ForeignRepo.primary?(spec.repo_id)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

      assert {:ok, ^wt_path} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id,
                 tmp_dir,
                 wt_path,
                 spec,
                 meta,
                 self()
               )

      # The real task branch is GONE — cleaned up by the primary-repo orphan
      # cleanup, while the fresh worktree is created normally.
      refute Git.branch_exists?(tmp_dir, real_branch)
      assert File.dir?(wt_path)
    end
  end

  # ==========================================================================
  # WorktreeManager crash-restart — persistent per-repo marker (Bug 2/3)
  # ==========================================================================
  #
  # The WorktreeManager is a one_for_one child of EvoGit.Supervisor: a crash
  # restarts ONLY it, while the running agent Tasks keep executing in their
  # live worktrees. The fix gates the destructive per-repo init (rm_rf workers
  # dir + orphaned-branch cleanup + prune) on a persistent marker in the
  # `:evogit_worktree_repos` ETS table and re-monitors live agents from their
  # scheduler ETS rows on restart. `restart_manager/0` restarts the manager
  # through the supervisor's terminate_child + restart_child pair (same
  # start_link → init path as a crash restart, but without exhausting the
  # supervisor's automatic-restart budget — see its doc comment).
  describe "WorktreeManager crash-restart" do
    test "restart does NOT wipe live worktrees (marker present)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      # Agent 1 creates a live worktree — the create pipeline runs
      # maybe_init_repo, which records the persistent per-repo marker.
      agent_id_1 = unique_agent_id()
      {spec, meta} = register_agent(agent_id_1, tmp_dir, base_sha)
      wt1 = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch1 = "evogit-agent-T1-A1"

      assert {:ok, ^wt1} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id_1,
                 tmp_dir,
                 wt1,
                 spec,
                 meta,
                 self()
               )

      assert File.dir?(wt1)
      assert Git.branch_exists?(tmp_dir, branch1)

      # Mirror production: Dispatch.try_dispatch/2 sets worktree + task_ref in
      # the sched_meta row BEFORE the Runner requests the worktree — the
      # crash-restart re-monitor (rebuild_monitor/3) needs both.
      Store.put_sched_meta(agent_id_1, %{meta | worktree: wt1, task_ref: task_ref_for(self())})

      # Restart ONLY the manager (one_for_one child of EvoGit.Supervisor;
      # the running agent Tasks keep going in their live worktrees).
      restart_manager()

      # Marker present → the destructive wipe is skipped → the live worktree
      # and its branch survive the restart.
      assert File.dir?(wt1)
      assert Git.branch_exists?(tmp_dir, branch1)

      # A second agent can still create its own worktree after the restart
      # (the marker-present init only ensures the workers dir exists).
      agent_id_2 = unique_agent_id()
      {spec2, meta2} = register_agent(agent_id_2, tmp_dir, base_sha, task_number: 2)
      wt2 = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T2_A1")

      assert {:ok, ^wt2} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id_2,
                 tmp_dir,
                 wt2,
                 spec2,
                 meta2,
                 self()
               )

      assert File.dir?(wt1)
      assert File.dir?(wt2)
    end

    test "marker-absent restart re-runs the full wipe", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      workers_dir = Worktrees.workers_dir(tmp_dir)

      # Agent 1's create runs maybe_init_repo and records the marker.
      agent_id_1 = unique_agent_id()
      {spec, meta} = register_agent(agent_id_1, tmp_dir, base_sha)
      wt1 = Path.join(workers_dir, "worker_T1_A1")

      assert {:ok, ^wt1} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id_1,
                 tmp_dir,
                 wt1,
                 spec,
                 meta,
                 self()
               )

      assert File.dir?(wt1)
      assert :ets.member(:evogit_worktree_repos, tmp_dir)

      # Leftover junk inside the workers dir (simulates artifacts from a
      # previous BEAM run). Placed AFTER the first create so it survives until
      # the marker is removed below — the first create's init already wiped
      # the (empty) workers dir.
      sentinel = Path.join(workers_dir, "sentinel")
      File.write!(sentinel, "sentinel")
      assert File.exists?(sentinel)

      # Remove the marker — simulating a genuine BEAM/app restart, where the
      # app-owned table dies with it and no live agents exist.
      :ets.delete(:evogit_worktree_repos, tmp_dir)
      refute :ets.member(:evogit_worktree_repos, tmp_dir)

      restart_manager()

      # A second agent's create re-runs the full wipe (marker absent): the
      # sentinel AND agent 1's worktree are removed, then a fresh worktree is
      # created for agent 2.
      agent_id_2 = unique_agent_id()
      {spec2, meta2} = register_agent(agent_id_2, tmp_dir, base_sha, task_number: 2)
      wt2 = Path.join(workers_dir, "worker_T2_A1")

      assert {:ok, ^wt2} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id_2,
                 tmp_dir,
                 wt2,
                 spec2,
                 meta2,
                 self()
               )

      refute File.exists?(sentinel)
      refute File.dir?(wt1)
      assert File.dir?(wt2)
    end

    test "restart re-monitors live agents → exit triggers cleanup", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # Controllable agent: creates its own worktree, then waits for the
      # test's exit signal (same pattern as the normal/crash-exit tests).
      parent = self()

      agent =
        spawn(fn ->
          result =
            WorktreeManager.create_worktree_for_agent(
              agent_id,
              tmp_dir,
              wt_path,
              spec,
              meta,
              self()
            )

          send(parent, {:created, result})

          receive do
            :exit_please -> Process.exit(self(), :kill)
          end
        end)

      # Wait for the create call to FULLY complete — NOT just for the dir to
      # appear: the CoW pipeline creates the empty worktree dir early
      # (`git worktree add --no-checkout`), so `File.dir?` can pass while the
      # create task is still in flight. Proceeding then (manager kill + agent
      # exit) would race the in-flight create: the rebuilt monitor's :DOWN
      # cleanup removes the dir, but the create task's `Git.add_worktree`
      # fallback recreates it — leaving an orphaned worktree with no monitor.
      # 30s deadline like the other create tests.
      assert_receive {:created, {:ok, ^wt_path}}, 30_000
      assert File.dir?(wt_path)
      assert Git.branch_exists?(tmp_dir, branch)

      # Mirror production: the sched_meta row carries the live worktree +
      # %Task{} ref so the crash-restart re-monitor can find the agent.
      Store.put_sched_meta(agent_id, %{meta | worktree: wt_path, task_ref: task_ref_for(agent)})

      restart_manager()

      # Robustness: re-put the rows after the restart too (harmless) so the
      # re-monitor definitely sees them even if the restart raced the write.
      Store.put_sched_meta(agent_id, %{meta | worktree: wt_path, task_ref: task_ref_for(agent)})

      # Release the agent — the REBUILT monitor delivers :DOWN → cleanup.
      send(agent, :exit_please)

      wait_until(
        fn -> not File.dir?(wt_path) and not Git.branch_exists?(tmp_dir, branch) end,
        30_000
      )
    end
  end

  # ==========================================================================
  # Worktrees.delete_branch_tolerant/2 — the tolerant branch-delete helper
  # ==========================================================================
  describe "delete_branch_tolerant/2" do
    test "treats a missing branch as a silent no-op", %{tmp_dir: tmp_dir} do
      refute Git.branch_exists?(tmp_dir, "evogit-agent-T99-A99")

      # `git branch -D` on a non-existent branch exits 1 with
      # "error: branch '<name>' not found" — the goal ("branch is gone") is
      # already met, so the tolerant helper must return :ok, not an error.
      assert :ok = Worktrees.delete_branch_tolerant(tmp_dir, "evogit-agent-T99-A99")
    end

    test "returns {:error, output} for a genuine failure (branch checked out)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      File.mkdir_p!(Path.dirname(wt_path))
      {:ok, _} = Git.add_worktree(tmp_dir, wt_path, base_sha, "evogit-agent-T1-A1")

      # The branch is checked out in a live worktree — `git branch -D` refuses
      # (wording varies across git versions: "checked out at ..." or "used by
      # worktree at ..."). The output does NOT contain "not found", so this is
      # a genuine failure the helper must surface as {:error, output}.
      assert {:error, output} = Worktrees.delete_branch_tolerant(tmp_dir, "evogit-agent-T1-A1")
      assert output =~ "branch"
      refute output =~ "not found"
    end

    test "recovers from a STALE worktree registration (dir removed without prune)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      File.mkdir_p!(Path.dirname(wt_path))
      branch = "evogit-agent-T1-A1"

      {:ok, _} = Git.add_worktree(tmp_dir, wt_path, base_sha, branch)

      # Remove the worktree DIR without pruning — the registration stays
      # stale, so `git branch -D` refuses ("cannot delete branch 'X' used by
      # worktree at '<path>'") even though no LIVE worktree holds the branch.
      # delete_branch_tolerant/2 must prune stale registrations + retry and
      # succeed. (The live-checkout test above keeps pinning the other side:
      # a branch genuinely checked out in a LIVE worktree still returns
      # {:error, output}.)
      File.rm_rf!(wt_path)
      refute File.dir?(wt_path)
      assert Git.branch_exists?(tmp_dir, branch)

      assert :ok = Worktrees.delete_branch_tolerant(tmp_dir, branch)
      refute Git.branch_exists?(tmp_dir, branch)
    end
  end

  # ==========================================================================
  # Worktrees.prepare_new_worktree/5 — genuine delete failure still warns
  # ==========================================================================
  describe "prepare_new_worktree/5 leftover cleanup" do
    test "logs a warning when a genuine branch-deletion failure occurs", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      # A live worktree holds the agent branch checked out — deleting it is a
      # GENUINE failure ("checked out", not "not found"), so the tolerant
      # helper surfaces {:error, output} and destroy_leftovers/3 must warn.
      wt1 = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      File.mkdir_p!(Path.dirname(wt1))
      {:ok, _} = Git.add_worktree(tmp_dir, wt1, base_sha, "evogit-agent-T1-A1")

      # A second agent sharing the same branch name (same task/task-local id)
      # but a different worktree path — its leftover cleanup targets a branch
      # that is still checked out in wt1, so the delete genuinely fails.
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt2 = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1_retry")

      log =
        capture_log(fn ->
          # The create itself legitimately fails (the branch is still checked
          # out in wt1) — the assertion that matters is the warning below.
          assert {:error, _} = Worktrees.prepare_new_worktree(agent_id, tmp_dir, wt2, spec, meta)
        end)

      assert log =~ "Could not remove leftover branch"
    end

    test "escalates when a leftover dir cannot be removed (rm_rf failure)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")

      # A leftover dir that cannot be removed: non-empty + read-only (tests
      # run as non-root, so rm_rf fails). Creating on top of a
      # partially-removed dir is the main-HEAD-leak precondition, so the
      # pipeline must ESCALATE (`{:error, {:worktree_create_failed, msg}}`)
      # instead of silently proceeding with the plain dir in place.
      File.mkdir_p!(wt_path)
      File.write!(Path.join(wt_path, "leftover.txt"), "leftover")
      File.chmod!(wt_path, 0o555)

      # LIFO: restore the chmod BEFORE the shared setup's on_exit rm_rf runs,
      # so teardown can delete the dir.
      on_exit(fn -> File.chmod!(wt_path, 0o755) end)

      log =
        capture_log(fn ->
          assert {:error, {:worktree_create_failed, msg}} =
                   Worktrees.prepare_new_worktree(agent_id, tmp_dir, wt_path, spec, meta)

          assert msg =~ "could not remove leftover worktree"
        end)

      assert log =~ "refusing to create"
    end

    test "re-preparing over a leftover registered worktree destroys it (main copy untouched)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      # Ignore the workers dir so the main-copy status assertion below is
      # genuinely empty (`git status --porcelain` would otherwise report the
      # untracked `?? .genesis/` directory).
      File.write!(Path.join(tmp_dir, ".gitignore"), ".genesis/\n")
      {:ok, _} = Git.add(tmp_dir, ".gitignore")
      {:ok, _} = Git.commit(tmp_dir, "ignore genesis dir")
      {:ok, new_base} = Git.rev_parse(tmp_dir)

      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      File.mkdir_p!(Path.dirname(wt_path))
      branch = "evogit-agent-T1-A1"

      # A leftover REGISTERED worktree from a previous run (crash-retry race).
      {:ok, _} = Git.add_worktree(tmp_dir, wt_path, new_base, branch)
      assert File.dir?(wt_path)

      # A fresh agent re-prepares at the SAME path — destroy_leftovers/3
      # cleans the leftover (rm_rf + prune + tolerant branch delete), then
      # the create pipeline rebuilds a fresh worktree.
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)

      assert {:ok, ^wt_path} =
               Worktrees.prepare_new_worktree(agent_id, tmp_dir, wt_path, spec, meta)

      assert File.read!(Path.join(wt_path, "README.md")) == "# test"

      # The MAIN copy is untouched: HEAD unmoved and the working tree clean.
      assert {:ok, ^new_base} = Git.rev_parse(tmp_dir)
      assert {:ok, ""} = Git.status(tmp_dir)
    end
  end

  # ==========================================================================
  # Worktrees.branch_name/2 — pure naming helper
  # ==========================================================================
  describe "Worktrees.branch_name/2" do
    test "derives the agent branch name from task number and task-local id" do
      assert Worktrees.branch_name(1, 42) == "evogit-agent-T1-A42"
      assert Worktrees.branch_name(12, 345) == "evogit-agent-T12-A345"
    end
  end
end
