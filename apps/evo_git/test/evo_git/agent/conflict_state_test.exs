defmodule EvoGit.Agent.ConflictStateTest do
  @moduledoc """
  `async: true` — the snapshot lives in the CALLING process's dictionary, so
  every test owns its state; the only shared state is real git repositories
  built under the ExUnit `:tmp_dir`.

  Repository fixtures start from ONE per-module template (`setup_all`) whose
  `.git` is copied per test, the same convention as
  `EvoGit.Agent.ContextMergeTest`. Commits/merges additionally pass an explicit
  author/committer env so the results never depend on the host git identity.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.ConflictState

  @identity_env [
    {"GIT_AUTHOR_NAME", "Test User"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test User"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"}
  ]

  setup_all do
    template = git_template!()
    on_exit(fn -> File.rm_rf!(template) end)
    %{git_template: template}
  end

  setup do
    # Never let a snapshot from another test (or the ExUnit process itself)
    # leak into this process's dictionary.
    Process.delete(:conflict_files)
    Process.delete(:repo_less)

    on_exit(fn ->
      Process.delete(:conflict_files)
      Process.delete(:repo_less)
    end)

    :ok
  end

  describe "defaults and clean repositories" do
    test "before any refresh the snapshot defaults to empty" do
      assert ConflictState.files() == []
      refute ConflictState.in_conflict?()
    end

    test "a clean repository reports no conflicts", %{tmp_dir: tmp_dir, git_template: template} do
      dir = init_repo(template, Path.join(tmp_dir, "clean"))
      commit_file!(dir, "file.txt", "hello\n", "base")

      assert ConflictState.refresh(dir) == []
      assert ConflictState.files() == []
      refute ConflictState.in_conflict?()
    end
  end

  describe "a repository left mid-merge" do
    test "refresh/1 returns and caches the conflicted relative path", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "conflicted"))
      build_conflicted_repo!(dir)

      assert ConflictState.refresh(dir) == ["conflict.txt"]
      assert ConflictState.files() == ["conflict.txt"]
      assert ConflictState.in_conflict?()

      # The adapter's own primitive agrees with the snapshot.
      assert Git.conflict_files(dir) == {:ok, ["conflict.txt"]}
    end

    test "in_conflict?/0 reads the CACHE, never a fresh git read", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "cached"))
      build_conflicted_repo!(dir)

      assert ConflictState.refresh(dir) == ["conflict.txt"]
      assert ConflictState.in_conflict?()

      # Abort the merge WITHOUT refreshing: the cached snapshot stays stale.
      assert {_output, 0} = git(dir, ["merge", "--abort"])
      assert ConflictState.files() == ["conflict.txt"]
      assert ConflictState.in_conflict?()

      # Only an explicit refresh observes the clean worktree.
      assert ConflictState.refresh(dir) == []
      refute ConflictState.in_conflict?()
    end
  end

  describe "best-effort tolerance" do
    test "a non-existent repository path degrades to empty without raising", %{tmp_dir: tmp_dir} do
      assert ConflictState.refresh(Path.join(tmp_dir, "does-not-exist")) == []
      assert ConflictState.files() == []
      refute ConflictState.in_conflict?()
    end

    test "non-binary paths degrade to empty without raising" do
      assert ConflictState.refresh(nil) == []
      assert ConflictState.refresh(:"not a path") == []
      assert ConflictState.files() == []
      refute ConflictState.in_conflict?()
    end

    test "a repo-less agent never shells out, even for a conflicted repository", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "repo_less"))
      build_conflicted_repo!(dir)

      Process.put(:repo_less, true)

      assert ConflictState.refresh(dir) == []
      assert ConflictState.files() == []
      refute ConflictState.in_conflict?()
    end
  end

  # --- fixtures -------------------------------------------------------------

  # One minimal repository whose `.git` is copied per test (avoids re-running
  # `git init` + the identity config for every test).
  defp git_template! do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_conflict_state_template_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    empty_template = Path.join(root, "empty_template")
    File.mkdir_p!(empty_template)
    seed = Path.join(root, "seed")

    {_output, 0} =
      System.cmd("git", ["init", "-q", "--template=#{empty_template}", seed],
        stderr_to_stdout: true
      )

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"}
        ] do
      {_output, 0} =
        System.cmd("git", ["config", key, value], cd: seed, stderr_to_stdout: true)
    end

    seed
  end

  defp init_repo(template, dir) do
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(template, ".git"), Path.join(dir, ".git"))
    dir
  end

  defp git(dir, args) do
    System.cmd("git", args, cd: dir, env: @identity_env, stderr_to_stdout: true)
  end

  defp commit_file!(dir, path, content, message) do
    full_path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)

    {_output, 0} = git(dir, ["add", "--", path])
    {_output, 0} = git(dir, ["commit", "-q", "-m", message])
    :ok
  end

  # Two branches editing the same line of one file, merged so the merge stops
  # with an unresolved conflict (the merge command exits non-zero by design).
  defp build_conflicted_repo!(dir) do
    commit_file!(dir, "conflict.txt", "base\n", "base")

    {base_output, 0} = git(dir, ["rev-parse", "HEAD"])
    base_sha = String.trim(base_output)

    {_output, 0} = git(dir, ["checkout", "-q", "-B", "branch-a"])
    commit_file!(dir, "conflict.txt", "ours\n", "ours")

    {_output, 0} = git(dir, ["checkout", "-q", "-B", "branch-b", base_sha])
    commit_file!(dir, "conflict.txt", "theirs\n", "theirs")

    {_output, 0} = git(dir, ["checkout", "-q", "branch-a"])

    # A conflicting merge exits 1 and leaves the unmerged path in the index.
    assert {_output, status} = git(dir, ["merge", "--no-edit", "branch-b"])
    assert status != 0
  end
end
