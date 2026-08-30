defmodule EvoGit.WorktreeMainHeadSafetyTest do
  @moduledoc """
  Full-lifecycle integration test pinning the main-HEAD safety guarantee for
  WRITABLE foreign repos (requirements a–e): the foreign repo's MAIN working
  copy must stay on its original branch/HEAD with a clean working tree through
  the ENTIRE worktree lifecycle — worktree creation, agent assignment and
  preparation, agent commits INSIDE the worktree, worktree destruction,
  `Runtime.Helpers.merge_and_report/4` branch creation, and review pre-merge
  reads.
  """
  # async: false — real git operations across multiple repos plus the shared
  # named ETS tables (:evogit_agent_state, :evogit_sched_meta).
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Review
  alias EvoGit.Runtime.Helpers

  defmodule DummyAgent do
    # The worktree pipeline never calls the agent module — this only needs to
    # exist so the %AgentSpec{} is well-formed.
  end

  # --------------------------------------------------------------------------
  # Setup / shared helpers
  # --------------------------------------------------------------------------

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)

    on_exit(fn -> clear_ets() end)

    :ok
  end

  # --- ETS helpers (pattern from worktrees_test.exs) ---

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

  # Creates a fresh temp git repo whose default branch is deterministically
  # `main` (git >= 2.28 `init -b`; the suite already pins git >= 2.38 for
  # `git merge-tree`), with two commits and a CLEAN tree. The `.genesis/`
  # runtime-artifacts dir is git-ignored from the start — exactly what Genesis
  # auto-writes into real repos (root .gitignore + the one it creates on
  # genesis), so the main copy's `git status` stays clean while worktrees live
  # under `.genesis/workers`. Returns the absolute repo path; cleaned up via
  # on_exit. Mirrors make_git_repo!/1 in runtime/helpers_test.exs.
  defp make_git_repo!(label) do
    dir =
      Path.expand(Path.join(System.tmp_dir!(), "evogit_mh_#{label}_#{System.unique_integer()}"))

    File.mkdir_p!(dir)
    {:ok, _} = Git.run(["init", "-b", "main"], dir)

    File.write!(Path.join(dir, ".gitignore"), ".genesis/\n")
    File.write!(Path.join(dir, "README.md"), "# #{label}\n")
    {:ok, _} = Git.add(dir, ".")
    {:ok, _} = Git.commit(dir, "Initial commit")

    File.write!(Path.join(dir, "lib.txt"), "one\n")
    {:ok, _} = Git.add(dir, "lib.txt")
    {:ok, _} = Git.commit(dir, "Second commit")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Asserts the main working copy of `repo_dir` is untouched: same HEAD sha,
  # still on branch "main", clean working tree (`git status --porcelain` empty).
  defp assert_main_untouched(repo_dir, main_head_before) do
    assert {:ok, ^main_head_before} = Git.rev_parse(repo_dir)
    assert {:ok, "main"} = Git.current_branch(repo_dir)
    assert {:ok, ""} = Git.status(repo_dir)
  end

  # Registers a minimal agent (ETS rows) so Worktrees.assign_and_prepare_worktree/3
  # can derive the branch name and update the phylo_node — mirrors the
  # register_agent pattern in worktrees_test.exs.
  defp register_agent(agent_id, repo_dir, base_sha) do
    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: repo_dir},
      phylo_node: %PhyloGraphNode{repo: repo_dir, base_commit: base_sha, current_commit: base_sha},
      agent_module: DummyAgent,
      objective: "test",
      repo_id: "foreign"
    }

    meta = %SchedMeta{id: agent_id, depth: 0, spec: spec, retries: 0, task_number: 1}

    agent_state = %AgentState{
      context_node: %ContextNode{path: "./", repo: repo_dir},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8,
      repo_root: repo_dir,
      task_local_id: 1
    }

    Store.put_agent_state(agent_id, agent_state)
    Store.put_sched_meta(agent_id, meta)
  end

  # ==========================================================================
  # Full lifecycle: foreign main copy never moves
  # ==========================================================================
  describe "writable foreign repo main-HEAD safety through the worktree lifecycle" do
    test "main working copy stays on main with a clean tree from worktree create through review reads" do
      primary_dir = make_git_repo!("primary")
      foreign_dir = make_git_repo!("foreign")

      # The foreign main copy starts on `main` with a couple of commits and a
      # clean tree — the invariant we pin for the whole lifecycle.
      {:ok, main_head_before} = Git.rev_parse(foreign_dir)
      assert {:ok, "main"} = Git.current_branch(foreign_dir)
      assert {:ok, ""} = Git.status(foreign_dir)

      agent_id = :erlang.unique_integer([:positive])
      branch = "evogit-agent-T1-A1"
      wt_path = Path.join(Worktrees.workers_dir(foreign_dir), "worker_T1_A1")
      {:ok, base_sha} = Git.rev_parse(foreign_dir, "main")

      # ---- (a) worktree creation leaves the foreign main copy untouched ----
      assert {:ok, _} = Git.add_worktree(foreign_dir, wt_path, base_sha, branch)
      assert File.dir?(wt_path)
      assert_main_untouched(foreign_dir, main_head_before)

      # ---- (b) agent assignment + preparation leaves it untouched ----
      register_agent(agent_id, foreign_dir, base_sha)

      assert {:ok, ^base_sha} =
               Worktrees.assign_and_prepare_worktree(agent_id, wt_path, foreign_dir)

      # The agent's phylo_node is now bound to the WORKTREE, never the main copy.
      assert {:ok, %AgentState{phylo_node: %PhyloGraphNode{repo: wt_repo}}} =
               Store.get_agent_state(agent_id)

      assert wt_repo == wt_path
      assert_main_untouched(foreign_dir, main_head_before)

      # ---- (b) an agent commit INSIDE the worktree leaves it untouched ----
      File.write!(Path.join(wt_path, "agent_change.txt"), "agent work\n")
      {:ok, _} = Git.add(wt_path, "agent_change.txt")
      {:ok, _} = Git.commit(wt_path, "Agent change in foreign worktree")
      {:ok, agent_commit_sha} = Git.rev_parse(wt_path)
      refute agent_commit_sha == base_sha
      assert_main_untouched(foreign_dir, main_head_before)

      # ---- (c) worktree destruction leaves it untouched ----
      # Order matters: the dir must be gone FIRST, otherwise the branch is still
      # checked out in a LIVE worktree and `git branch -D` (rightly) refuses —
      # delete_branch_tolerant prunes the now-stale registration and retries.
      File.rm_rf!(wt_path)
      assert :ok = Worktrees.delete_branch_tolerant(foreign_dir, branch)
      {:ok, _} = Git.prune_worktrees(foreign_dir)
      refute File.dir?(wt_path)
      refute Git.branch_exists?(foreign_dir, branch)
      assert_main_untouched(foreign_dir, main_head_before)

      # ---- (d) merge_and_report/4 creates the genesis/agent_* branch in the
      # foreign repo WITHOUT moving its main copy ----
      {:ok, primary_sha} = Git.rev_parse(primary_dir)

      agent_output = %Result{
        commit_sha: primary_sha,
        result: "agent summary",
        tag: nil,
        usage: nil,
        agent_count: 1,
        foreign_repo_commits: %{"foreign" => agent_commit_sha}
      }

      foreign_repos = [%ForeignRepo{id: "foreign", root: foreign_dir, writable: true}]

      assert {:ok, report} =
               Helpers.merge_and_report(primary_dir, agent_output, "evolve", foreign_repos)

      assert %{commit_sha: ^agent_commit_sha, branch_name: branch_name} =
               report.repos["foreign"]

      assert is_binary(branch_name)
      assert String.starts_with?(branch_name, "genesis/agent_")
      assert Git.branch_exists?(foreign_dir, branch_name)
      assert_main_untouched(foreign_dir, main_head_before)

      # ---- (e) review pre-merge reads work while the main copy is still on
      # `main` — and the reads themselves leave it untouched ----
      assert {:ok, review_data} = Review.load_review_data(foreign_dir, branch_name)
      assert review_data.changed_files_count >= 1
      assert review_data.files != []
      assert Review.check_merge(foreign_dir, branch_name, "main") == {:ok, :clean}

      assert_main_untouched(foreign_dir, main_head_before)
    end
  end
end
