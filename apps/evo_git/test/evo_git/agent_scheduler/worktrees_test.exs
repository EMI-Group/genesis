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
    clear_ets()

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      clear_ets()
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
    spec = build_spec(tmp_dir, base_sha)
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

      # The monitored pid — exits :normal right after the create returns.
      spawn(fn ->
        WorktreeManager.create_worktree_for_agent(agent_id, tmp_dir, wt_path, spec, meta, self())
      end)

      wait_until(fn -> File.dir?(wt_path) end)
      assert Git.branch_exists?(tmp_dir, branch)

      # Monitor-driven cleanup is async — poll until dir AND branch are gone.
      wait_until(fn ->
        not File.dir?(wt_path) and not Git.branch_exists?(tmp_dir, branch)
      end)
    end

    test "reclaims the worktree when the agent process crashes", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      agent_id = unique_agent_id()
      {spec, meta} = register_agent(agent_id, tmp_dir, base_sha)
      wt_path = Path.join(Worktrees.workers_dir(tmp_dir), "worker_T1_A1")
      branch = "evogit-agent-T1-A1"

      # The monitored pid — exits abnormally right after the create returns.
      spawn(fn ->
        WorktreeManager.create_worktree_for_agent(agent_id, tmp_dir, wt_path, spec, meta, self())
        Process.exit(self(), :kill)
      end)

      wait_until(fn -> File.dir?(wt_path) end)
      assert Git.branch_exists?(tmp_dir, branch)

      # Cleanup is identical for abnormal exits — no reuse semantics.
      wait_until(fn ->
        not File.dir?(wt_path) and not Git.branch_exists?(tmp_dir, branch)
      end)
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
