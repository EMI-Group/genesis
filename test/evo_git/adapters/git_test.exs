defmodule EvoGit.Adapters.GitTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "evo_git_test_repo_" <> to_string(System.unique_integer()))
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
end
