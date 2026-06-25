defmodule EvoGit.AgentScheduler.WorktreesTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.Worktrees

  # --------------------------------------------------------------------------
  # Shared temp git-repo setup (mirrors test/evo_git/runtime/helpers_test.exs)
  # --------------------------------------------------------------------------
  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_worktrees_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    Git.init(tmp_dir)

    # Create an initial commit so HEAD exists and branches can be created.
    File.write!(Path.join(tmp_dir, "README.md"), "# test")
    Git.add(tmp_dir, "README.md")
    Git.commit(tmp_dir, "initial commit")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  # ==========================================================================
  # delete/2 — branch-name derivation
  #
  # The worktree directory uses underscores (worker_T1_A42) while branches
  # are created with hyphens (evogit-agent-T1-A42). delete/2 must translate
  # worker_T<id>_A<local_id> → evogit-agent-T<id>-A<local_id> so that the
  # correct branch is deleted.
  # ==========================================================================
  describe "delete/2 branch-name derivation" do
    test "deletes a branch created with hyphen naming from a worker_T<n>_A<n> dir", %{
      tmp_dir: tmp_dir
    } do
      {:ok, base_sha} = Git.rev_parse(tmp_dir)

      # Branches are created with hyphens (see dispatch.ex / complete_task.ex).
      branch_name = "evogit-agent-T1-A42"
      Git.create_branch(tmp_dir, branch_name, base_sha)
      assert branch_name in Git.list_branches(tmp_dir)

      # Worktree directories use underscores.
      workers_dir = Path.join(tmp_dir, ".evogit/workers")
      worktree_path = Path.join(workers_dir, "worker_T1_A42")
      File.mkdir_p!(worktree_path)
      File.write!(Path.join(worktree_path, "placeholder"), "")

      Worktrees.delete(worktree_path, tmp_dir)

      # The branch must be gone — this fails if the underscore-to-hyphen
      # translation in delete/2 is missing or incorrect.
      refute branch_name in Git.list_branches(tmp_dir)
    end

    test "deletes a branch for multi-digit task/local ids", %{tmp_dir: tmp_dir} do
      {:ok, base_sha} = Git.rev_parse(tmp_dir)

      branch_name = "evogit-agent-T12-A345"
      Git.create_branch(tmp_dir, branch_name, base_sha)

      worktree_path = Path.join(tmp_dir, ".evogit/workers/worker_T12_A345")
      File.mkdir_p!(worktree_path)

      Worktrees.delete(worktree_path, tmp_dir)
      refute branch_name in Git.list_branches(tmp_dir)
    end
  end
end
