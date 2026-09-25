defmodule EvoGit.AgentScheduler.ForeignWorktreeTest do
  @moduledoc """
  Lifecycle tests for `EvoGit.AgentScheduler.ForeignWorktree` — the PERSISTENT
  worktree of every WRITABLE foreign repo (`<root>/.genesis/foreign_repos/<id>`).

  Real git on temp dirs (mirrors `test/evo_git/runtime/helpers_test.exs`).
  `async: true` — every assertion is scoped to a per-test temp repo, and the
  `sync_from_agent/0` tests drive the TEST process's own process dictionary.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.ForeignWorktree
  alias EvoGit.Core.ForeignRepo

  setup do
    root = new_repo!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # ensure/2 — create
  # ---------------------------------------------------------------------------

  describe "ensure/2 (create)" do
    test "creates the persistent worktree at the given commit without moving the main HEAD", %{
      root: root
    } do
      {:ok, head} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      refute File.exists?(wt)
      assert ForeignWorktree.ensure(repo, head) == :ok

      # A real LINKED worktree: a directory whose `.git` is a FILE.
      assert File.dir?(wt)
      assert File.regular?(Path.join(wt, ".git"))
      assert {:ok, ^head} = Git.rev_parse(wt)

      # The foreign repo's MAIN working-copy HEAD never moves.
      assert {:ok, ^head} = Git.rev_parse(root)

      # The worktree truly reflects the committed content.
      assert File.read!(Path.join(wt, "README.md")) == "hello\n"
    end

    test "is a no-op for a read-only foreign repo", %{root: root} do
      {:ok, head} = Git.rev_parse(root)
      repo = %ForeignRepo{id: "original", root: root}
      wt = ForeignRepo.worktree_path(repo)

      assert ForeignWorktree.ensure(repo, head) == :ok
      refute File.exists?(wt)
    end

    test "creates no branch in the foreign repo", %{root: root} do
      {:ok, head} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      {:ok, before_branches} = Git.run(["branch", "--list"], root)

      assert :ok = ForeignWorktree.ensure(repo, head)

      {:ok, after_branches} = Git.run(["branch", "--list"], root)
      assert after_branches == before_branches
    end

    test "replaces a leftover plain directory with a real linked worktree", %{root: root} do
      {:ok, head} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      # A leftover plain dir (no `.git` file) — `git worktree add` alone would
      # fail with "already exists".
      File.mkdir_p!(wt)
      File.write!(Path.join(wt, "junk.txt"), "junk")

      assert :ok = ForeignWorktree.ensure(repo, head)
      assert File.regular?(Path.join(wt, ".git"))
      assert {:ok, ^head} = Git.rev_parse(wt)
      refute File.exists?(Path.join(wt, "junk.txt"))
    end
  end

  # ---------------------------------------------------------------------------
  # ensure/2 — advance / idempotence
  # ---------------------------------------------------------------------------

  describe "ensure/2 (advance)" do
    test "advances an existing worktree to a newer commit and is idempotent", %{root: root} do
      {:ok, first} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      assert :ok = ForeignWorktree.ensure(repo, first)

      # A newer commit created OUTSIDE the main working copy (a scratch
      # worktree), so the foreign repo's main HEAD stays exactly where it was.
      scratch = Path.join(root, ".genesis/workers/scratch")
      File.mkdir_p!(Path.dirname(scratch))
      assert {:ok, _} = Git.add_worktree(root, scratch, first)
      {:ok, second} = commit_file!(scratch, "second.txt", "second")
      refute second == first

      assert :ok = ForeignWorktree.ensure(repo, second)
      assert {:ok, ^second} = Git.rev_parse(wt)
      assert File.read!(Path.join(wt, "second.txt")) == "second"

      # The main working copy is untouched (still on the original commit).
      assert {:ok, ^first} = Git.rev_parse(root)

      # A second identical call is an idempotent no-op.
      assert :ok = ForeignWorktree.ensure(repo, second)
      assert {:ok, ^second} = Git.rev_parse(wt)
      assert {:ok, ^first} = Git.rev_parse(root)
    end

    test "advances the worktree to a newer MAIN-branch commit without touching the main HEAD",
         %{root: root} do
      {:ok, first} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      assert :ok = ForeignWorktree.ensure(repo, first)

      # A second commit ON the main branch: main HEAD legitimately becomes it,
      # and the persistent worktree follows without moving it any further.
      {:ok, second} = commit_file!(root, "second.txt", "second")

      assert :ok = ForeignWorktree.ensure(repo, second)
      assert {:ok, ^second} = Git.rev_parse(wt)
      assert {:ok, ^second} = Git.rev_parse(root)
    end

    test "re-creates the worktree when the directory was deleted behind git's back", %{root: root} do
      {:ok, head} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      assert :ok = ForeignWorktree.ensure(repo, head)
      File.rm_rf!(wt)

      assert :ok = ForeignWorktree.ensure(repo, head)
      assert File.regular?(Path.join(wt, ".git"))
      assert {:ok, ^head} = Git.rev_parse(wt)
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_all/1
  # ---------------------------------------------------------------------------

  describe "ensure_all/1" do
    test "provisions writable repos and skips read-only ones", %{root: root} do
      other = new_repo!()
      on_exit(fn -> File.rm_rf!(other) end)

      writable = writable_repo("writable", root)
      read_only = %ForeignRepo{id: "readonly", root: other}

      assert ForeignWorktree.ensure_all([writable, read_only]) == :ok

      {:ok, root_head} = Git.rev_parse(root)
      {:ok, other_head} = Git.rev_parse(other)

      wt = ForeignRepo.worktree_path(writable)
      assert File.regular?(Path.join(wt, ".git"))
      assert {:ok, ^root_head} = Git.rev_parse(wt)

      refute File.exists?(ForeignRepo.worktree_path(read_only))
      assert {:ok, ^other_head} = Git.rev_parse(other)
    end

    test "provisions each writable repo at its own base_sha and skips the primary", %{root: root} do
      other = new_repo!()
      on_exit(fn -> File.rm_rf!(other) end)

      {:ok, other_first} = Git.rev_parse(other)
      {:ok, _other_second} = commit_file!(other, "later.txt", "later")

      at_base = %ForeignRepo{
        id: "at_base",
        root: other,
        writable: true,
        base_sha: other_first
      }

      primary = %ForeignRepo{id: "primary", root: root, writable: true}

      assert ForeignWorktree.ensure_all([at_base, primary]) == :ok

      assert {:ok, ^other_first} = Git.rev_parse(ForeignRepo.worktree_path(at_base))
      # The primary repo is never given a foreign worktree.
      refute File.exists?(Path.join(root, ".genesis/foreign_repos/primary"))
    end

    test "never raises for unparseable entries or non-list input" do
      assert ForeignWorktree.ensure_all([%{"no-root" => true}, nil, "junk"]) == :ok
      assert ForeignWorktree.ensure_all(nil) == :ok
    end

    test "logs a warning and returns :ok when a repo cannot be provisioned" do
      missing = %ForeignRepo{
        id: "gone",
        root: Path.join(System.tmp_dir!(), "evogit-fw-missing-#{System.unique_integer()}"),
        writable: true
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ForeignWorktree.ensure_all([missing]) == :ok
        end)

      assert log =~ "ForeignWorktree:"
      assert log =~ "gone"
    end
  end

  # ---------------------------------------------------------------------------
  # start_commit/1
  # ---------------------------------------------------------------------------

  describe "start_commit/1" do
    test "returns base_sha when set", %{root: root} do
      repo = %ForeignRepo{id: "original", root: root, writable: true, base_sha: "abc123"}

      assert ForeignWorktree.start_commit(repo) == {:ok, "abc123"}
    end

    test "falls back to the repo HEAD when base_sha is nil", %{root: root} do
      {:ok, head} = Git.rev_parse(root)

      assert ForeignWorktree.start_commit(%ForeignRepo{id: "original", root: root}) ==
               {:ok, head}
    end

    test "returns an error tuple (never raises) for an invalid repo", %{root: root} do
      missing = %ForeignRepo{id: "gone", root: Path.join(root, "nope")}

      assert {:error, _reason} = ForeignWorktree.start_commit(missing)
      assert {:error, {:invalid_repo, :junk}} = ForeignWorktree.start_commit(:junk)
    end
  end

  # ---------------------------------------------------------------------------
  # sync_from_agent/0
  # ---------------------------------------------------------------------------

  describe "sync_from_agent/0" do
    setup do
      saved = %{
        evogit_repo_id: Process.get(:evogit_repo_id),
        repo_path: Process.get(:repo_path),
        foreign_repos: Process.get(:foreign_repos),
        repo_less: Process.get(:repo_less)
      }

      on_exit(fn ->
        restore(:evogit_repo_id, saved.evogit_repo_id)
        restore(:repo_path, saved.repo_path)
        restore(:foreign_repos, saved.foreign_repos)
        restore(:repo_less, saved.repo_less)
      end)

      :ok
    end

    test "advances the persistent worktree to the agent's HEAD", %{root: root} do
      {:ok, first} = Git.rev_parse(root)
      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      assert :ok = ForeignWorktree.ensure(repo, first)

      # The agent ran in its own worktree (under `.genesis/workers/...`) and
      # committed there — that worktree's HEAD is the newest state.
      agent_wt = Path.join(root, ".genesis/workers/agent-worktree")
      File.mkdir_p!(Path.dirname(agent_wt))
      assert {:ok, _} = Git.add_worktree(root, agent_wt, first)
      {:ok, agent_sha} = commit_file!(agent_wt, "agent.txt", "agent work")
      refute agent_sha == first

      Process.put(:evogit_repo_id, "original")
      Process.put(:repo_path, agent_wt)
      Process.put(:foreign_repos, [repo])

      assert ForeignWorktree.sync_from_agent() == :ok

      assert {:ok, ^agent_sha} = Git.rev_parse(wt)
      assert File.read!(Path.join(wt, "agent.txt")) == "agent work"
      # The foreign repo's main HEAD still did not move.
      assert {:ok, ^first} = Git.rev_parse(root)
    end

    test "carries a string-keyed foreign-repo map (Codec round trip)" do
      root = new_repo!()
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, head} = Git.rev_parse(root)

      repo = writable_repo("original", root)
      wt = ForeignRepo.worktree_path(repo)

      Process.put(:evogit_repo_id, "original")
      Process.put(:repo_path, root)
      Process.put(:foreign_repos, [%{"id" => "original", "root" => root, "writable" => true}])

      assert ForeignWorktree.sync_from_agent() == :ok
      assert {:ok, ^head} = Git.rev_parse(wt)
    end

    test "is a no-op for a repo-less agent", %{root: root} do
      repo = writable_repo("original", root)
      Process.put(:repo_less, true)
      Process.put(:evogit_repo_id, "original")
      Process.put(:repo_path, root)
      Process.put(:foreign_repos, [repo])

      assert ForeignWorktree.sync_from_agent() == :ok
      refute File.exists?(ForeignRepo.worktree_path(repo))
    end

    test "is a no-op for the primary agent", %{root: root} do
      repo = writable_repo("original", root)
      Process.put(:evogit_repo_id, "primary")
      Process.put(:repo_path, root)
      Process.put(:foreign_repos, [repo])

      assert ForeignWorktree.sync_from_agent() == :ok
      refute File.exists?(ForeignRepo.worktree_path(repo))
    end

    test "is a no-op for a non-writable foreign repo", %{root: root} do
      repo = %ForeignRepo{id: "original", root: root}
      Process.put(:evogit_repo_id, "original")
      Process.put(:repo_path, root)
      Process.put(:foreign_repos, [repo])

      assert ForeignWorktree.sync_from_agent() == :ok
      refute File.exists?(ForeignRepo.worktree_path(repo))
    end

    test "never raises when the repo id / repo path / repo list are missing" do
      Process.delete(:evogit_repo_id)
      Process.delete(:repo_path)
      Process.delete(:foreign_repos)

      assert ForeignWorktree.sync_from_agent() == :ok

      Process.put(:evogit_repo_id, "original")
      Process.put(:repo_path, "")
      Process.put(:foreign_repos, [])

      assert ForeignWorktree.sync_from_agent() == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # worktree_path/1
  # ---------------------------------------------------------------------------

  test "worktree_path/1 delegates to ForeignRepo.worktree_path/1", %{root: root} do
    repo = writable_repo("original", root)

    assert ForeignWorktree.worktree_path(repo) == ForeignRepo.worktree_path(repo)

    assert ForeignWorktree.worktree_path(repo) ==
             Path.join([root, ".genesis", "foreign_repos", "original"])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp new_repo! do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "evogit_fw_#{System.unique_integer([:positive])}"))

    File.mkdir_p!(root)
    {:ok, _} = Git.init(root)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], root)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], root)
    File.write!(Path.join(root, "README.md"), "hello\n")
    {:ok, _} = Git.add(root, "README.md")
    {:ok, _} = Git.commit(root, "Initial commit")
    root
  end

  # Commits a new file in `repo` and returns the new HEAD sha.
  defp commit_file!(repo, name, content) do
    File.write!(Path.join(repo, name), content)
    {:ok, _} = Git.add(repo, name)
    {:ok, _} = Git.commit(repo, "Add #{name}")
    Git.rev_parse(repo)
  end

  defp writable_repo(id, root) do
    %ForeignRepo{id: id, root: root, writable: true}
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)
end
