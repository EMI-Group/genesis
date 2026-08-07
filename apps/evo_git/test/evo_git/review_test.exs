defmodule EvoGit.ReviewTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Review

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_review_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    Git.init(tmp_dir)

    # Configure git identity before committing
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  # Writes a file (creating parent dirs), stages, and commits it.
  defp commit_file(tmp_dir, path, content, message) do
    full_path = Path.join(tmp_dir, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    Git.add(tmp_dir, path)
    Git.commit(tmp_dir, message)
    Git.rev_parse(tmp_dir, "HEAD")
  end

  # Counts context lines in a diff (lines not starting with +/-, @@, diff, index).
  defp context_line_count(diff) do
    diff
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      not String.starts_with?(line, "+") and
        not String.starts_with?(line, "-") and
        not String.starts_with?(line, "@@") and
        not String.starts_with?(line, "diff") and
        not String.starts_with?(line, "index") and
        not String.starts_with?(line, "---") and
        not String.starts_with?(line, "+++")
    end)
  end

  test "load_review_metadata/2 returns accurate additions and deletions", %{tmp_dir: tmp_dir} do
    # Initial commit with a file that has a long path
    long_path = "src/a/very/long/directory/path/to/the/source/file.ex"

    {:ok, base_sha} =
      commit_file(tmp_dir, long_path, String.duplicate("line\n", 50), "Initial commit")

    # Create a branch and make changes
    Git.create_branch(tmp_dir, "feature", base_sha)
    Git.checkout(tmp_dir, "feature")

    # Modify the file: remove 20 lines, add 10 lines
    new_content =
      String.duplicate("new line\n", 10) <> String.duplicate("line\n", 30)

    commit_file(tmp_dir, long_path, new_content, "Modify long path file")

    # Checkout back to base so merge-base(HEAD, feature) = base
    Git.checkout(tmp_dir, base_sha)

    assert {:ok, metadata} = Review.load_review_metadata(tmp_dir, "feature")

    assert metadata.total_additions == 10
    assert metadata.total_deletions == 20
    assert metadata.changed_files_count == 1

    [file] = metadata.files
    assert file.path == long_path
    assert file.additions == 10
    assert file.deletions == 20
    assert file.status == "modified"
    assert file.language == "elixir"
  end

  test "load_review_metadata/2 handles added and deleted files", %{tmp_dir: tmp_dir} do
    {:ok, base_sha} = commit_file(tmp_dir, "keep.txt", "keep\n", "Initial commit")

    Git.create_branch(tmp_dir, "feature", base_sha)
    Git.checkout(tmp_dir, "feature")

    # Add a new file
    File.write!(Path.join(tmp_dir, "new_file.ex"), "defmodule Foo do\nend\n")
    Git.add(tmp_dir, "new_file.ex")
    Git.commit(tmp_dir, "Add new file")

    # Delete the original file
    File.rm!(Path.join(tmp_dir, "keep.txt"))
    Git.add(tmp_dir, "keep.txt")
    Git.commit(tmp_dir, "Delete keep.txt")

    # Checkout back to base so merge-base(HEAD, feature) = base
    Git.checkout(tmp_dir, base_sha)

    assert {:ok, metadata} = Review.load_review_metadata(tmp_dir, "feature")

    files_by_path = Map.new(metadata.files, &{&1.path, &1})

    assert Map.has_key?(files_by_path, "new_file.ex")
    assert files_by_path["new_file.ex"].status == "added"
    assert files_by_path["new_file.ex"].additions == 2
    assert files_by_path["new_file.ex"].deletions == 0

    assert Map.has_key?(files_by_path, "keep.txt")
    assert files_by_path["keep.txt"].status == "deleted"
    assert files_by_path["keep.txt"].additions == 0
    assert files_by_path["keep.txt"].deletions == 1
  end

  test "load_review_metadata_from_shas/3 works after branch deletion", %{tmp_dir: tmp_dir} do
    {:ok, base_sha} =
      commit_file(tmp_dir, "original.txt", "line1\nline2\nline3\n", "Initial commit")

    Git.create_branch(tmp_dir, "feature", base_sha)
    Git.checkout(tmp_dir, "feature")

    commit_file(tmp_dir, "original.txt", "line1\nmodified\nline3\nadded\n", "Modify file")

    # Add another file on the branch
    File.write!(Path.join(tmp_dir, "extra.ex"), "defmodule Bar do\nend\n")
    Git.add(tmp_dir, "extra.ex")
    Git.commit(tmp_dir, "Add extra")
    {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

    # Capture SHAs, then delete the branch (objects remain reachable)
    captured_base = base_sha
    captured_commit = commit_sha

    Git.checkout(tmp_dir, captured_base)
    Git.delete_branch(tmp_dir, "feature")

    # The branch is gone, but commit objects still exist
    assert {:ok, metadata} =
             Review.load_review_metadata_from_shas(tmp_dir, captured_base, captured_commit)

    files_by_path = Map.new(metadata.files, &{&1.path, &1})

    assert Map.has_key?(files_by_path, "original.txt")
    assert files_by_path["original.txt"].additions == 2
    assert files_by_path["original.txt"].deletions == 1

    assert Map.has_key?(files_by_path, "extra.ex")
    assert files_by_path["extra.ex"].status == "added"
    assert files_by_path["extra.ex"].additions == 2
  end

  test "load_file_diff/5 with context: 10 shows more context than default", %{tmp_dir: tmp_dir} do
    # Create a file with ~20 lines
    lines = for i <- 1..20, do: "line #{i}"

    {:ok, base_sha} =
      commit_file(tmp_dir, "multiline.txt", Enum.join(lines, "\n") <> "\n", "Initial commit")

    Git.create_branch(tmp_dir, "feature", base_sha)
    Git.checkout(tmp_dir, "feature")

    # Modify a line near the middle
    new_lines = List.replace_at(lines, 10, "CHANGED line 11")

    commit_file(
      tmp_dir,
      "multiline.txt",
      Enum.join(new_lines, "\n") <> "\n",
      "Change middle line"
    )

    # Use the feature tip for the actual diff
    {:ok, feature_tip} = Git.rev_parse(tmp_dir, "feature")

    assert {:ok, default_diff} =
             Review.load_file_diff(tmp_dir, base_sha, feature_tip, "multiline.txt")

    assert {:ok, context_diff} =
             Review.load_file_diff(tmp_dir, base_sha, feature_tip, "multiline.txt", context: 10)

    default_context = context_line_count(default_diff)
    wide_context = context_line_count(context_diff)

    assert wide_context > default_context
  end

  test "load_file_diff/5 with context: :all shows entire file", %{tmp_dir: tmp_dir} do
    lines = for i <- 1..20, do: "line #{i}"

    {:ok, base_sha} =
      commit_file(tmp_dir, "full.txt", Enum.join(lines, "\n") <> "\n", "Initial commit")

    Git.create_branch(tmp_dir, "feature", base_sha)
    Git.checkout(tmp_dir, "feature")

    # Change the last line so default 3-line context wouldn't reach the beginning
    new_lines = List.replace_at(lines, 19, "CHANGED final line")

    commit_file(tmp_dir, "full.txt", Enum.join(new_lines, "\n") <> "\n", "Change last line")

    {:ok, feature_tip} = Git.rev_parse(tmp_dir, "feature")

    assert {:ok, all_diff} =
             Review.load_file_diff(tmp_dir, base_sha, feature_tip, "full.txt", context: :all)

    assert {:ok, default_diff} =
             Review.load_file_diff(tmp_dir, base_sha, feature_tip, "full.txt")

    # The :all context diff should have many more context lines than the default
    all_context = context_line_count(all_diff)
    default_context = context_line_count(default_diff)

    assert all_context > default_context
    # The full-file diff should show the very first content line as a context line
    assert all_context >= 19
    # The default 3-line context should only show a few context lines
    assert default_context <= 5
  end

  test "list_commits_from_shas/3 returns correct commits", %{tmp_dir: tmp_dir} do
    {:ok, base_sha} = commit_file(tmp_dir, "file.txt", "initial\n", "Base commit")

    Git.create_branch(tmp_dir, "feature", base_sha)
    Git.checkout(tmp_dir, "feature")

    commit_file(tmp_dir, "file.txt", "second\n", "Second commit")
    {:ok, commit_sha} = commit_file(tmp_dir, "file.txt", "third\n", "Third commit")

    assert {:ok, commits} = Review.list_commits_from_shas(tmp_dir, base_sha, commit_sha)

    assert length(commits) == 2

    # Commits are in reverse chronological order (newest first)
    assert List.first(commits).message == "Third commit"
    assert List.last(commits).message == "Second commit"

    # Each commit should have populated fields
    Enum.each(commits, fn commit ->
      assert is_binary(commit.sha)
      assert is_binary(commit.short_sha)
      assert byte_size(commit.sha) == 40
      assert is_binary(commit.author_name)
      assert is_binary(commit.author_email)
    end)
  end

  test "list_commits_from_shas/3 returns empty list when no commits in range", %{tmp_dir: tmp_dir} do
    {:ok, base_sha} = commit_file(tmp_dir, "file.txt", "initial\n", "Base commit")
    {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

    assert {:ok, []} = Review.list_commits_from_shas(tmp_dir, base_sha, commit_sha)
  end

  test "load_commit_files/2 returns files changed in a single commit", %{tmp_dir: tmp_dir} do
    # First commit
    commit_file(tmp_dir, "existing.txt", "old content\n", "First commit")

    # Second commit modifies existing (both add and delete) and adds a new file
    File.write!(Path.join(tmp_dir, "existing.txt"), "new content\n")
    File.write!(Path.join(tmp_dir, "added.ex"), "defmodule New do\nend\n")
    Git.add(tmp_dir, ".")
    Git.commit(tmp_dir, "Second commit")
    {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

    assert {:ok, metadata} = Review.load_commit_files(tmp_dir, commit_sha)

    assert metadata.commit_sha == commit_sha
    assert String.ends_with?(metadata.base_sha, "~1")

    files_by_path = Map.new(metadata.files, &{&1.path, &1})

    # existing.txt: 1 add + 1 del → modified
    assert files_by_path["existing.txt"].additions == 1
    assert files_by_path["existing.txt"].deletions == 1
    assert files_by_path["existing.txt"].status == "modified"

    assert files_by_path["added.ex"].status == "added"
    assert files_by_path["added.ex"].additions == 2
    assert files_by_path["added.ex"].deletions == 0

    assert metadata.changed_files_count == 2
    assert metadata.total_additions == 3
    assert metadata.total_deletions == 1
  end

  test "load_commit_file_diff/3 returns diff for a single file in a commit", %{tmp_dir: tmp_dir} do
    commit_file(tmp_dir, "file.txt", "line1\nline2\n", "First commit")

    File.write!(Path.join(tmp_dir, "file.txt"), "line1\nCHANGED\n")
    Git.add(tmp_dir, "file.txt")
    Git.commit(tmp_dir, "Second commit")
    {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

    assert {:ok, diff} = Review.load_commit_file_diff(tmp_dir, commit_sha, "file.txt")

    assert String.contains?(diff, "-line2")
    assert String.contains?(diff, "+CHANGED")
  end

  # Renames the current branch to `new_name` (no-op if it already has that
  # name), so tests don't depend on the machine's `init.defaultBranch`.
  defp rename_current_branch(tmp_dir, new_name) do
    case Git.current_branch(tmp_dir) do
      {:ok, ^new_name} -> :ok
      {:ok, _other} -> System.cmd("git", ["branch", "-m", new_name], cd: tmp_dir)
    end
  end

  defp is_ancestor?(tmp_dir, ancestor_sha, descendant_ref) do
    {_output, 0} =
      System.cmd(
        "git",
        ["merge-base", "--is-ancestor", ancestor_sha, descendant_ref],
        cd: tmp_dir,
        stderr_to_stdout: true
      )

    true
  end

  test "merge_branch/2 merges into the default target (current branch)", %{tmp_dir: tmp_dir} do
    {:ok, base_sha} = commit_file(tmp_dir, "base.txt", "base\n", "Initial commit")
    rename_current_branch(tmp_dir, "main")

    Git.create_branch(tmp_dir, "agent_branch", base_sha)
    Git.checkout(tmp_dir, "agent_branch")
    {:ok, feature_sha} = commit_file(tmp_dir, "feature.txt", "feature\n", "Feature commit")
    Git.checkout(tmp_dir, "main")

    assert {:ok, ^feature_sha} = Review.merge_branch(tmp_dir, "agent_branch")

    assert is_ancestor?(tmp_dir, feature_sha, "main")
    refute Git.branch_exists?(tmp_dir, "agent_branch")
    assert {:ok, "main"} = Git.current_branch(tmp_dir)
  end

  test "merge_branch/3 merges into a non-default target branch and restores the original branch",
       %{tmp_dir: tmp_dir} do
    {:ok, base_sha} = commit_file(tmp_dir, "base.txt", "base\n", "Initial commit")
    rename_current_branch(tmp_dir, "main")

    # Target branch that is not checked out
    System.cmd("git", ["branch", "dev"], cd: tmp_dir)

    # Agent branch with a feature commit
    Git.create_branch(tmp_dir, "agent_branch", base_sha)
    Git.checkout(tmp_dir, "agent_branch")
    {:ok, feature_sha} = commit_file(tmp_dir, "feature.txt", "feature\n", "Feature commit")
    Git.checkout(tmp_dir, "main")
    assert {:ok, "main"} = Git.current_branch(tmp_dir)

    assert {:ok, ^feature_sha} = Review.merge_branch(tmp_dir, "agent_branch", "dev")

    # The change landed on dev
    assert is_ancestor?(tmp_dir, feature_sha, "dev")

    # Agent branch deleted
    refute Git.branch_exists?(tmp_dir, "agent_branch")

    # Repo is back on main after the merge
    assert {:ok, "main"} = Git.current_branch(tmp_dir)
  end

  test "merge_branch/3 returns conflict, keeps the agent branch, and restores the original branch",
       %{tmp_dir: tmp_dir} do
    {:ok, base_sha} = commit_file(tmp_dir, "file.txt", "base\n", "Initial commit")
    rename_current_branch(tmp_dir, "main")

    # dev diverges: modifies file.txt
    System.cmd("git", ["branch", "dev"], cd: tmp_dir)
    Git.checkout(tmp_dir, "dev")
    commit_file(tmp_dir, "file.txt", "dev change\n", "Dev change")
    Git.checkout(tmp_dir, "main")

    # Agent branch modifies the same file → merging into dev conflicts
    Git.create_branch(tmp_dir, "agent_branch", base_sha)
    Git.checkout(tmp_dir, "agent_branch")
    commit_file(tmp_dir, "file.txt", "agent change\n", "Agent change")
    Git.checkout(tmp_dir, "main")

    assert {:conflict, details} = Review.merge_branch(tmp_dir, "agent_branch", "dev")
    assert is_binary(details)

    # Agent branch NOT deleted on conflict
    assert Git.branch_exists?(tmp_dir, "agent_branch")

    # Repo is back on main despite the conflicted index
    assert {:ok, "main"} = Git.current_branch(tmp_dir)
  end

  test "default_merge_target/1 prefers dev over prod when main and master are absent",
       %{tmp_dir: tmp_dir} do
    {:ok, _base_sha} = commit_file(tmp_dir, "file.txt", "x\n", "Initial commit")
    rename_current_branch(tmp_dir, "feature/x")
    System.cmd("git", ["branch", "dev"], cd: tmp_dir)
    System.cmd("git", ["branch", "prod"], cd: tmp_dir)

    assert {:ok, "dev"} = Review.default_merge_target(tmp_dir)
  end

  test "default_merge_target/1 resolves master when it is the only candidate", %{tmp_dir: tmp_dir} do
    {:ok, _base_sha} = commit_file(tmp_dir, "file.txt", "x\n", "Initial commit")
    rename_current_branch(tmp_dir, "feature/x")
    System.cmd("git", ["branch", "master"], cd: tmp_dir)

    assert {:ok, "master"} = Review.default_merge_target(tmp_dir)
  end

  test "default_merge_target/1 falls back to the current branch when no candidates exist",
       %{tmp_dir: tmp_dir} do
    {:ok, _base_sha} = commit_file(tmp_dir, "file.txt", "x\n", "Initial commit")
    rename_current_branch(tmp_dir, "feature/x")

    assert {:ok, "feature/x"} = Review.default_merge_target(tmp_dir)
  end

  test "default_merge_target/1 returns no_branch_found on an empty repo", %{tmp_dir: tmp_dir} do
    # No commits — unborn HEAD, no branches
    assert {:error, :no_branch_found} = Review.default_merge_target(tmp_dir)
  end

  test "list_branches/1 returns all local branches", %{tmp_dir: tmp_dir} do
    {:ok, _base_sha} = commit_file(tmp_dir, "file.txt", "x\n", "Initial commit")
    System.cmd("git", ["branch", "alpha"], cd: tmp_dir)
    System.cmd("git", ["branch", "beta"], cd: tmp_dir)

    assert {:ok, branches} = Git.list_branches(tmp_dir)
    {:ok, current} = Git.current_branch(tmp_dir)
    assert current in branches
    assert "alpha" in branches
    assert "beta" in branches

    assert {:ok, branches} = Review.list_branches(tmp_dir)
    assert "alpha" in branches
    assert "beta" in branches
  end
end
