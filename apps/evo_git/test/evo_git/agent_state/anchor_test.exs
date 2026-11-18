defmodule EvoGit.AgentState.AnchorTest do
  # async: true — every case owns its own `:tmp_dir` repository and the anchor
  # dedupe lives in the CALLER's process dictionary; no app-env key, ETS table,
  # :persistent_term entry or global process is mutated (the supervised anchor
  # task under `EvoGit.TaskSupervisor` is the only shared resource and it is
  # never inspected).
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentState.Anchor

  describe "ref/2" do
    test "names the per-run namespace under refs/genesis/agent-state" do
      assert Anchor.ref("task-1", 7) == "refs/genesis/agent-state/task-1/7"
      assert Anchor.ref(12, 3) == "refs/genesis/agent-state/12/3"
      assert Anchor.ref("abc", "A") == "refs/genesis/agent-state/abc/A"
    end

    test "is total for any identifier" do
      assert is_binary(Anchor.ref(nil, nil))
      assert Anchor.ref(nil, nil) == "refs/genesis/agent-state//"
      assert is_binary(Anchor.ref(%{a: 1}, self()))
    end
  end

  describe "anchor/4" do
    test "creates the ref for a real commit", %{tmp_dir: dir} do
      {repo, sha} = init_repo(dir)

      assert Anchor.anchor(repo, "task-1", 1, sha) == :ok
      assert Anchor.last_anchored(repo, "task-1", 1) == sha

      assert wait_for_ref(repo, Anchor.ref("task-1", 1), sha) == {:ok, sha}
    end

    test "dedupes an unchanged commit and moves the ref for a newer one", %{tmp_dir: dir} do
      {repo, first} = init_repo(dir)
      ref_name = Anchor.ref("task-1", 7)

      assert Anchor.anchor(repo, "task-1", 7, first) == :ok
      assert wait_for_ref(repo, ref_name, first) == {:ok, first}
      assert Anchor.last_anchored(repo, "task-1", 7) == first

      # Same sha from the same process: no write is dispatched (the dedupe is
      # the process-dictionary entry), so the recorded sha and the ref value
      # stay put.
      assert Anchor.anchor(repo, "task-1", 7, first) == :ok
      assert Anchor.last_anchored(repo, "task-1", 7) == first
      assert Git.rev_parse(repo, ref_name) == {:ok, first}

      # A NEWER sha moves the ref.
      {:ok, second} = commit_file(repo, "work.txt", "agent work", "agent work")

      assert Anchor.anchor(repo, "task-1", 7, second) == :ok
      assert wait_for_ref(repo, ref_name, second) == {:ok, second}
      assert Anchor.last_anchored(repo, "task-1", 7) == second
    end

    test "a nil repo path or sha is a no-op", %{tmp_dir: dir} do
      {repo, sha} = init_repo(dir)

      assert Anchor.anchor(nil, "task-1", 1, sha) == :ok
      assert Anchor.anchor(repo, "task-1", 1, nil) == :ok
      assert Anchor.anchor(repo, "task-1", 1, :not_a_binary) == :ok
      assert Anchor.anchor("", "task-1", 1, sha) == :ok

      assert Anchor.last_anchored(nil, "task-1", 1) == nil
      assert Anchor.last_anchored(repo, "task-1", 1) == nil
      assert match?({:error, _}, Git.rev_parse(repo, Anchor.ref("task-1", 1)))
    end

    test "the anchored commit survives branch deletion, reclamation and git gc", %{tmp_dir: dir} do
      {repo, base} = init_repo(dir)
      {:ok, tree} = Git.rev_parse(repo, "HEAD^{tree}")

      # An agent commit whose ONLY references are the agent branch and (once
      # anchored) our ref: `commit-tree` writes the object with no HEAD reflog
      # entry, exactly like a commit made in an agent worktree.
      agent_sha = commit_tree(repo, tree, base, "agent work")

      # A second commit that stays completely unreachable — the control that
      # proves this test's `git gc` really prunes.
      lost_sha = commit_tree(repo, tree, base, "lost work")

      assert {:ok, _} = Git.create_branch(repo, "evogit-agent-T1-A1", agent_sha)
      assert {:ok, ^agent_sha} = Git.rev_parse(repo, "evogit-agent-T1-A1")

      ref_name = Anchor.ref("task-1", 1)
      assert Anchor.anchor(repo, "task-1", 1, agent_sha) == :ok
      assert wait_for_ref(repo, ref_name, agent_sha) == {:ok, agent_sha}

      # Simulate a BEAM restart + reclamation: the agent branch is deleted
      # (WorktreeManager.clean_orphaned_branches/1) and the workers tree is
      # wiped, then the repo is garbage collected.
      assert {:ok, _} = Git.delete_branch(repo, "evogit-agent-T1-A1")
      assert Git.branch_exists?(repo, "evogit-agent-T1-A1") == false
      File.rm_rf!(Path.join(repo, ".genesis/workers"))
      assert {:ok, _} = Git.run(["gc", "--prune=now", "--quiet"], repo)

      # The anchor still names the commit and the commit object is alive.
      assert Git.rev_parse(repo, ref_name) == {:ok, agent_sha}
      assert commit_exists?(repo, agent_sha)

      # The control commit proves gc actually pruned unreachable objects.
      refute commit_exists?(repo, lost_sha)
    end
  end

  # --- fixtures -------------------------------------------------------------

  # A throw-away repo with one commit on the default branch. Identity comes
  # from `EvoGit.GitEnv` through the adapter (no `-c` flags needed).
  defp init_repo(dir) do
    File.mkdir_p!(dir)
    assert {:ok, _} = Git.init(dir)
    File.write!(Path.join(dir, "README.md"), "# fixture\n")
    assert {:ok, _} = Git.add(dir)
    assert {:ok, _} = Git.commit(dir, "initial")
    {:ok, sha} = Git.rev_parse(dir, "HEAD")
    {dir, sha}
  end

  defp commit_file(repo, name, content, message) do
    File.write!(Path.join(repo, name), content)
    {:ok, _} = Git.add(repo)
    {:ok, _} = Git.commit(repo, message)
    Git.rev_parse(repo, "HEAD")
  end

  # Writes a commit object with NO ref and no reflog entry pointing at it.
  defp commit_tree(repo, tree, parent, message) do
    {:ok, sha} =
      Git.run(["commit-tree", tree, "-p", parent, "-m", message], repo)

    sha
  end

  defp commit_exists?(repo, sha) do
    match?({:ok, _}, Git.run(["cat-file", "-e", sha <> "^{commit}"], repo))
  end

  # Bounded poll: `anchor/4` is fire-and-forget, so the ref lands asynchronously
  # in a supervised task. No fixed sleep — the wait is paid only until the ref
  # answers.
  defp wait_for_ref(repo, ref_name, expected, attempts \\ 300) do
    case Git.rev_parse(repo, ref_name) do
      {:ok, ^expected} = ok ->
        ok

      other ->
        if attempts > 0 do
          Process.sleep(10)
          wait_for_ref(repo, ref_name, expected, attempts - 1)
        else
          other
        end
    end
  end
end
