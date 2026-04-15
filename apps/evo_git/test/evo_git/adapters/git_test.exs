defmodule EvoGit.Adapters.GitTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_test_repo_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    Git.init(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  test "commit returns ok when there are no changes", %{tmp_dir: tmp_dir} do
    # Make an initial commit
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
    {:ok, _} = Git.add(tmp_dir, "test.txt")
    {:ok, _} = Git.commit(tmp_dir, "Initial commit")

    # Attempt to commit again with no changes
    assert {:ok, _} = Git.commit(tmp_dir, "Commit with no changes")
  end

  test "commit returns ok when there are changes", %{tmp_dir: tmp_dir} do
    # Make an initial commit
    File.write!(Path.join(tmp_dir, "test_with_changes.txt"), "initial content")
    {:ok, _} = Git.add(tmp_dir, "test_with_changes.txt")
    {:ok, _} = Git.commit(tmp_dir, "Initial commit for changes")

    # Make changes and commit again
    File.write!(Path.join(tmp_dir, "test_with_changes.txt"), "updated content")
    {:ok, _} = Git.add(tmp_dir, "test_with_changes.txt")
    assert {:ok, _} = Git.commit(tmp_dir, "Second commit with changes")
  end

  test "check_ignore returns ignored files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, ".gitignore"), "ignored.txt\n*.log")

    files = ["normal.txt", "ignored.txt", "some.log", "subdir/another.log"]
    {:ok, ignored} = Git.check_ignore(tmp_dir, files)

    assert "ignored.txt" in ignored
    assert "some.log" in ignored
    assert "subdir/another.log" in ignored
    assert length(ignored) == 3

    # Test with no ignored files
    {:ok, ignored} = Git.check_ignore(tmp_dir, ["normal.txt", "other.txt"])
    assert ignored == []
  end

  test "log and file_history", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    File.write!(Path.join(tmp_dir, "test.txt"), "updated content")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Updated commit")

    assert {:ok, log_output} = Git.log(tmp_dir, ["--oneline"])
    assert String.contains?(log_output, "Updated commit")
    assert String.contains?(log_output, "Initial commit")

    assert {:ok, history} = Git.file_history(tmp_dir, "test.txt", ["--oneline"])
    assert String.contains?(history, "Updated commit")
    assert String.contains?(history, "Initial commit")
  end

  test "show object", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    assert {:ok, show_output} = Git.show(tmp_dir, "HEAD:test.txt")
    assert show_output == "initial content"
  end

  test "diff and file_diff", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    {:ok, commit_a} = Git.rev_parse(tmp_dir, "HEAD")

    File.write!(Path.join(tmp_dir, "test.txt"), "updated content\n")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Updated commit")

    {:ok, commit_b} = Git.rev_parse(tmp_dir, "HEAD")

    assert {:ok, diff_output} = Git.diff(tmp_dir, commit_a, commit_b)
    assert String.contains?(diff_output, "-initial content")
    assert String.contains?(diff_output, "+updated content")

    assert {:ok, file_diff_output} = Git.file_diff(tmp_dir, "test.txt", commit_a, commit_b)
    assert String.contains?(file_diff_output, "-initial content")
    assert String.contains?(file_diff_output, "+updated content")
  end

  test "git notes", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

    # Add note
    assert {:ok, _} = Git.add_note(tmp_dir, commit_sha, "My test note")

    # Show note
    assert {:ok, note_content} = Git.show_note(tmp_dir, commit_sha)
    assert String.trim(note_content) == "My test note"

    # List notes
    assert {:ok, notes_list} = Git.list_notes(tmp_dir)
    assert String.contains?(notes_list, commit_sha)

    # Remove note
    assert {:ok, _} = Git.remove_note(tmp_dir, commit_sha)

    # Show note again, should fail because note doesn't exist
    assert {:conflict, _} = Git.show_note(tmp_dir, commit_sha)
  end
end
