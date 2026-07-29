defmodule EvoGit.Adapters.CowWorktreeTest do
  @moduledoc """
  Tests for CoW (copy-on-write) optimized worktree creation.

  Uses `async: false` because `:persistent_term` (`:evogit_cow_worktree_enabled`)
  is global state shared across all tests — concurrent flag mutations would race.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Adapters.CowWorktree

  @flag_key :evogit_cow_worktree_enabled

  # -------------------------------------------------------------------------
  # Setup / teardown
  # -------------------------------------------------------------------------

  setup do
    # Isolate config so Config.resolve([:git, :cow_worktree_creation]) returns
    # the schema default (:auto) — no user TOML interferes.
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "cow-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    # Erase the global flag so each test starts from a known state.
    :persistent_term.erase(@flag_key)

    on_exit(fn ->
      # Restore flag to unset (clean slate for subsequent test files).
      :persistent_term.erase(@flag_key)

      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp make_repo(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cow_test_#{prefix}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Git.init(dir)
    # Set local git identity so commits work even without global config.
    Git.run(["config", "user.email", "test@example.com"], dir)
    Git.run(["config", "user.name", "Test User"], dir)
    Git.run(["config", "commit.gpgsign", "false"], dir)

    dir
  end

  defp write_file(repo, relative_path, content) do
    full = Path.join(repo, relative_path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp commit_all(repo, message) do
    Git.add(repo, ".")
    Git.commit(repo, message)
    {:ok, sha} = Git.rev_parse(repo, "HEAD")
    sha
  end

  defp make_worktree_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "cow_wt_#{prefix}_#{System.unique_integer([:positive])}"
    )
  end

  defp cleanup_worktree(repo, worktree_path) do
    Git.run(["worktree", "remove", "--force", worktree_path], repo)
    Git.run(["worktree", "prune"], repo)
    File.rm_rf!(worktree_path)
  end

  # -------------------------------------------------------------------------
  # Git.ls_tree_names / Git.diff_name_only (new Git adapter functions)
  # -------------------------------------------------------------------------

  describe "Git.ls_tree_names/2" do
    test "lists all files in a tree including nested paths" do
      repo = make_repo("lstree")

      write_file(repo, "a.txt", "content a")
      write_file(repo, "sub/b.txt", "content b")
      write_file(repo, "sub/deep/c.txt", "content c")
      commit_all(repo, "Add nested files")

      assert {:ok, files} = Git.ls_tree_names(repo, "HEAD")

      file_set = MapSet.new(files)
      assert MapSet.new(["a.txt", "sub/b.txt", "sub/deep/c.txt"]) ==
               MapSet.intersection(file_set, MapSet.new(["a.txt", "sub/b.txt", "sub/deep/c.txt"]))
    end

    test "returns empty list for an empty tree" do
      repo = make_repo("lstree_empty")
      # No commits yet — HEAD doesn't resolve, so we make an empty commit.
      Git.run(["commit", "--allow-empty", "-m", "empty"], repo)

      assert {:ok, []} = Git.ls_tree_names(repo, "HEAD")
    end
  end

  describe "Git.diff_name_only/3" do
    test "lists changed files between two commits" do
      repo = make_repo("diff")

      write_file(repo, "a.txt", "v1")
      write_file(repo, "b.txt", "v1")
      sha1 = commit_all(repo, "Commit 1")

      write_file(repo, "a.txt", "v2")
      write_file(repo, "c.txt", "new")
      sha2 = commit_all(repo, "Commit 2")

      assert {:ok, changed} = Git.diff_name_only(repo, sha1, sha2)

      # Order is not guaranteed — compare as a set.
      assert MapSet.new(changed) == MapSet.new(["a.txt", "c.txt"])
    end

    test "returns empty list when commits are identical" do
      repo = make_repo("diff_same")

      write_file(repo, "a.txt", "v1")
      sha = commit_all(repo, "Commit 1")

      assert {:ok, []} = Git.diff_name_only(repo, sha, sha)
    end
  end

  # -------------------------------------------------------------------------
  # Flag management (persistent_term)
  # -------------------------------------------------------------------------

  describe "flag/0, enable/0, disable/0" do
    test "flag/0 returns :not_set initially after erase" do
      assert CowWorktree.flag() == :not_set
    end

    test "enable/0 sets the flag to :enabled" do
      CowWorktree.enable()
      assert CowWorktree.flag() == :enabled
    end

    test "disable/0 sets the flag to :disabled" do
      CowWorktree.disable()
      assert CowWorktree.flag() == :disabled
    end

    test "enable then disable transitions correctly" do
      CowWorktree.enable()
      assert CowWorktree.flag() == :enabled

      CowWorktree.disable()
      assert CowWorktree.flag() == :disabled
    end
  end

  # -------------------------------------------------------------------------
  # enabled?/0 (feature gate)
  # -------------------------------------------------------------------------

  describe "enabled?/0" do
    test "returns false when flag is :disabled (config resolves to :auto)" do
      CowWorktree.disable()
      assert CowWorktree.enabled?() == false
    end

    test "returns true when flag is :enabled (config resolves to :auto)" do
      # On Linux/macOS with cp available, :auto + :enabled flag → true.
      CowWorktree.enable()
      assert CowWorktree.enabled?() == true
    end

    test "auto-detects on first call when flag is :not_set" do
      # In :auto mode with :not_set, auto-detect runs:
      # not windows? and cp available? → true on Linux/macOS CI.
      # The flag is cached (enable/disable) as a side-effect.
      result = CowWorktree.enabled?()

      # On this platform (Linux), cp is available → true.
      assert result == true
      # After auto-detection, flag should be cached.
      assert CowWorktree.flag() in [:enabled, :disabled]
    end
  end

  # -------------------------------------------------------------------------
  # create_worktree/5 — happy path
  # -------------------------------------------------------------------------

  describe "create_worktree/5" do
    test "creates a valid worktree with correct content via CoW" do
      repo = make_repo("create_ok")
      worktree_path = make_worktree_path("create_ok")
      branch = "cow-branch-ok"

      # Commit 1: shared.txt, changed.txt (v1), sub/deep.txt
      write_file(repo, "shared.txt", "same")
      write_file(repo, "changed.txt", "v1")
      write_file(repo, "sub/deep.txt", "deep v1")
      _sha1 = commit_all(repo, "Initial files")

      # Commit 2: change changed.txt to v2
      write_file(repo, "changed.txt", "v2")
      target = commit_all(repo, "Update changed.txt")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      # source_path is the repo working tree itself; target_commit = HEAD.
      result =
        CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      assert result == :ok

      # Verify all files exist with correct content.
      assert File.read!(Path.join(worktree_path, "shared.txt")) == "same"
      assert File.read!(Path.join(worktree_path, "changed.txt")) == "v2"
      assert File.read!(Path.join(worktree_path, "sub/deep.txt")) == "deep v1"

      # The worktree should be a valid git worktree.
      assert {:ok, _} = Git.run(["status", "--porcelain"], worktree_path)
    end

    test "worktree content matches a standard git checkout" do
      repo = make_repo("parity")
      wt_cow = make_worktree_path("parity_cow")
      wt_std = make_worktree_path("parity_std")
      branch_cow = "cow-parity"
      branch_std = "std-parity"

      # Create multiple files across directories.
      write_file(repo, "root.txt", "root content")
      write_file(repo, "dir/a.txt", "a content")
      write_file(repo, "dir/sub/b.txt", "b content")
      write_file(repo, "deep/x/y/z.txt", "deep content")
      target = commit_all(repo, "Multi-file commit")

      on_exit(fn ->
        cleanup_worktree(repo, wt_cow)
        cleanup_worktree(repo, wt_std)
      end)

      # Create worktree via CoW.
      assert :ok =
               CowWorktree.create_worktree(repo, wt_cow, target, branch_cow, repo)

      # Create worktree via standard git (for content parity comparison).
      assert {:ok, _} = Git.add_worktree(repo, wt_std, target, branch_std)

      # Every file in the standard worktree should have identical content in
      # the CoW worktree.
      {:ok, files} = Git.ls_tree_names(repo, target)

      for file <- files do
        std_content = File.read!(Path.join(wt_std, file))
        cow_content = File.read!(Path.join(wt_cow, file))
        assert cow_content == std_content,
               "Content mismatch for #{file}: CoW=#{inspect(cow_content)}, std=#{inspect(std_content)}"
      end
    end
  end

  # -------------------------------------------------------------------------
  # create_worktree/5 — dirty file exclusion
  # -------------------------------------------------------------------------

  describe "create_worktree/5 dirty file handling" do
    test "excludes dirty files from copy — dirty.txt gets committed content" do
      repo = make_repo("dirty")
      worktree_path = make_worktree_path("dirty")
      branch = "cow-branch-dirty"

      # Commit files.
      write_file(repo, "keep.txt", "keep content")
      write_file(repo, "dirty.txt", "clean committed content")
      target = commit_all(repo, "Initial commit")

      # Modify dirty.txt in the working tree (do NOT commit).
      write_file(repo, "dirty.txt", "DIRTY uncommitted content")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      result =
        CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      assert result == :ok

      # dirty.txt should have the COMMITTED content (restored by checkout),
      # NOT the dirty working-tree content.
      assert File.read!(Path.join(worktree_path, "dirty.txt")) ==
               "clean committed content"

      # keep.txt should also have correct content.
      assert File.read!(Path.join(worktree_path, "keep.txt")) == "keep content"
    end

    test "excludes dirty files even in subdirectories" do
      repo = make_repo("dirty_sub")
      worktree_path = make_worktree_path("dirty_sub")
      branch = "cow-branch-dirty-sub"

      write_file(repo, "stable.txt", "stable")
      write_file(repo, "data/uncommitted.txt", "committed value")
      write_file(repo, "data/stable.txt", "also stable")
      target = commit_all(repo, "Initial commit")

      # Dirty a nested file.
      write_file(repo, "data/uncommitted.txt", "dirty override")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      # The dirty file should have committed content, not the dirty override.
      assert File.read!(Path.join(worktree_path, "data/uncommitted.txt")) ==
               "committed value"

      assert File.read!(Path.join(worktree_path, "data/stable.txt")) == "also stable"
    end
  end

  # -------------------------------------------------------------------------
  # create_worktree/5 — nested directories
  # -------------------------------------------------------------------------

  describe "create_worktree/5 nested directories" do
    test "handles deeply nested files" do
      repo = make_repo("nested")
      worktree_path = make_worktree_path("nested")
      branch = "cow-branch-nested"

      write_file(repo, "a/b/c/d/file.txt", "deeply nested content")
      write_file(repo, "top.txt", "top level")
      target = commit_all(repo, "Nested commit")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      assert File.read!(Path.join(worktree_path, "a/b/c/d/file.txt")) ==
               "deeply nested content"

      assert File.read!(Path.join(worktree_path, "top.txt")) == "top level"
    end

    test "handles many files in multiple directories" do
      repo = make_repo("many")
      worktree_path = make_worktree_path("many")
      branch = "cow-branch-many"

      # Create files across several directories.
      for i <- 1..10 do
        write_file(repo, "dir#{rem(i, 3)}/file#{i}.txt", "content #{i}")
      end

      target = commit_all(repo, "Many files commit")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      # Verify a few representative files.
      assert File.read!(Path.join(worktree_path, "dir0/file3.txt")) == "content 3"
      assert File.read!(Path.join(worktree_path, "dir1/file4.txt")) == "content 4"
      assert File.read!(Path.join(worktree_path, "dir2/file5.txt")) == "content 5"
    end
  end

  # -------------------------------------------------------------------------
  # create_worktree/5 — fallback scenarios
  # -------------------------------------------------------------------------

  describe "create_worktree/5 fallbacks" do
    test "falls back when source has no commits" do
      # Source repo: init only, no commits.
      source = make_repo("no_head_src")

      # Target repo: has commits.
      target_repo = make_repo("no_head_tgt")
      write_file(target_repo, "file.txt", "content")
      target_sha = commit_all(target_repo, "Initial")

      worktree_path = make_worktree_path("no_head")
      branch = "cow-branch-no-head"

      on_exit(fn -> cleanup_worktree(target_repo, worktree_path) end)

      result =
        CowWorktree.create_worktree(
          target_repo,
          worktree_path,
          target_sha,
          branch,
          source
        )

      assert result == {:fallback, :no_source_head}

      # The function calls disable() on this path.
      assert CowWorktree.flag() == :disabled

      # No worktree should have been created.
      refute File.dir?(worktree_path)
    end

    test "handles pre-existing branch by deleting and recreating" do
      repo = make_repo("exists_branch")
      worktree_path = make_worktree_path("exists_branch")
      branch = "cow-branch-exists"

      write_file(repo, "file.txt", "content")
      target = commit_all(repo, "Initial commit")

      # Pre-create the branch so create_worktree must delete it first.
      assert {:ok, _} = Git.create_branch(repo, branch, target)
      assert Git.branch_exists?(repo, branch)

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      result =
        CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      assert result == :ok
      assert File.read!(Path.join(worktree_path, "file.txt")) == "content"
    end

    test "leaves no leftover worktree on successful creation" do
      repo = make_repo("clean_ok")
      worktree_path = make_worktree_path("clean_ok")
      branch = "cow-branch-clean"

      write_file(repo, "file.txt", "content")
      target = commit_all(repo, "Initial")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      # Verify exactly one worktree was registered (the one we created).
      {:ok, worktree_list} = Git.run(["worktree", "list", "--porcelain"], repo)

      # The output should contain the worktree_path.
      assert String.contains?(worktree_list, worktree_path)
    end
  end

  # -------------------------------------------------------------------------
  # create_worktree/5 — worktree is a valid git repository
  # -------------------------------------------------------------------------

  describe "create_worktree/5 git validity" do
    test "resulting worktree has clean status" do
      repo = make_repo("status_clean")
      worktree_path = make_worktree_path("status_clean")
      branch = "cow-branch-status"

      write_file(repo, "a.txt", "content a")
      write_file(repo, "b/c.txt", "content c")
      target = commit_all(repo, "Files commit")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      # The worktree should have a clean status (no untracked or modified files).
      {:ok, porcelain} = Git.run(["status", "--porcelain"], worktree_path)
      assert porcelain == "", "worktree status was not clean: #{inspect(porcelain)}"
    end

    test "resulting worktree HEAD matches target commit" do
      repo = make_repo("head_match")
      worktree_path = make_worktree_path("head_match")
      branch = "cow-branch-head"

      write_file(repo, "file.txt", "content")
      target = commit_all(repo, "Initial")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      {:ok, wt_head} = Git.rev_parse(worktree_path, "HEAD")
      assert wt_head == target
    end

    test "resulting worktree is on the correct branch" do
      repo = make_repo("branch_check")
      worktree_path = make_worktree_path("branch_check")
      branch = "cow-branch-check"

      write_file(repo, "file.txt", "content")
      target = commit_all(repo, "Initial")

      on_exit(fn -> cleanup_worktree(repo, worktree_path) end)

      assert :ok =
               CowWorktree.create_worktree(repo, worktree_path, target, branch, repo)

      {:ok, current} = Git.current_branch(worktree_path)
      assert current == branch
    end
  end
end
