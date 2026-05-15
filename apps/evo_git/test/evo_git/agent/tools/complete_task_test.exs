defmodule EvoGit.Agent.Tools.CompleteTaskTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Tools.CompleteTask

  describe "schema/0" do
    test "returns a valid tool schema with correct name and description" do
      schema = CompleteTask.schema()

      assert schema.name == "complete_task"
      assert is_binary(schema.description)
      assert schema.description =~ "report your findings"
    end

    test "schema has result as required parameter" do
      schema = CompleteTask.schema()
      props = schema.parameter_schema["properties"]
      required = schema.parameter_schema["required"]

      assert "result" in Map.keys(props)
      assert "check_git_status" in Map.keys(props)
      assert "result" in required
      assert props["check_git_status"]["default"] == true
    end
  end

  describe "check_workspace_dirty/1" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "complete_task_dirty_test_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)
      Git.init(tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "returns clean when workspace has no changes", %{tmp_dir: tmp_dir} do
      # Create and commit a file so the repo has history
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      assert {:clean, nil} = CompleteTask.check_workspace_dirty(tmp_dir)
    end

    test "returns dirty when workspace has uncommitted modifications", %{tmp_dir: tmp_dir} do
      # Create and commit a file
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      # Modify the file without committing
      File.write!(Path.join(tmp_dir, "test.txt"), "modified content")

      assert {:dirty, warning_msg} = CompleteTask.check_workspace_dirty(tmp_dir)
      assert warning_msg =~ "uncommitted changes"
      assert warning_msg =~ "modified"
      assert warning_msg =~ "test.txt"
    end

    test "returns dirty when workspace has untracked files", %{tmp_dir: tmp_dir} do
      # Create and commit a file
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      # Create an untracked file
      File.write!(Path.join(tmp_dir, "untracked.txt"), "new file")

      assert {:dirty, warning_msg} = CompleteTask.check_workspace_dirty(tmp_dir)
      assert warning_msg =~ "uncommitted changes"
      assert warning_msg =~ "untracked"
      assert warning_msg =~ "untracked.txt"
    end

    test "returns dirty when workspace has staged changes", %{tmp_dir: tmp_dir} do
      # Create and commit a file
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      # Stage a new file
      File.write!(Path.join(tmp_dir, "staged.txt"), "staged content")
      {:ok, _} = Git.add(tmp_dir, "staged.txt")

      assert {:dirty, warning_msg} = CompleteTask.check_workspace_dirty(tmp_dir)
      assert warning_msg =~ "uncommitted changes"
      assert warning_msg =~ "staged.txt"
    end

    test "returns clean for an empty repo with no commits", %{tmp_dir: tmp_dir} do
      # A freshly initialized repo with nothing staged should be clean
      assert {:clean, nil} = CompleteTask.check_workspace_dirty(tmp_dir)
    end
  end

  describe "format_git_status_porcelain/1" do
    test "formats modified files" do
      output = CompleteTask.format_git_status_porcelain(" M lib/foo.ex")
      assert output =~ "modified  lib/foo.ex"
    end

    test "formats staged files" do
      output = CompleteTask.format_git_status_porcelain("M  lib/bar.ex")
      assert output =~ "staged  lib/bar.ex"
    end

    test "formats staged and modified files" do
      output = CompleteTask.format_git_status_porcelain("MM lib/baz.ex")
      assert output =~ "staged, modified  lib/baz.ex"
    end

    test "formats staged new files" do
      output = CompleteTask.format_git_status_porcelain("A  new_file.ex")
      assert output =~ "staged (new)  new_file.ex"
    end

    test "formats deleted files" do
      output = CompleteTask.format_git_status_porcelain(" D deleted_file.ex")
      assert output =~ "deleted  deleted_file.ex"
    end

    test "formats staged deleted files" do
      output = CompleteTask.format_git_status_porcelain("D  staged_del.ex")
      assert output =~ "staged (deleted)  staged_del.ex"
    end

    test "formats staged and deleted files" do
      output = CompleteTask.format_git_status_porcelain("DD both_del.ex")
      assert output =~ "staged, deleted  both_del.ex"
    end

    test "formats staged renamed files" do
      output = CompleteTask.format_git_status_porcelain("R  renamed.ex")
      assert output =~ "staged (renamed)  renamed.ex"
    end

    test "formats untracked files (single ?)" do
      output = CompleteTask.format_git_status_porcelain("?? untracked.ex")
      assert output =~ "untracked  untracked.ex"
    end

    test "formats multiple files on separate lines" do
      porcelain = " M modified.ex\nA  added.ex\n?? untracked.ex"
      output = CompleteTask.format_git_status_porcelain(porcelain)

      assert output =~ "modified  modified.ex"
      assert output =~ "staged (new)  added.ex"
      assert output =~ "untracked  untracked.ex"
    end

    test "passes through unknown status codes as-is" do
      output = CompleteTask.format_git_status_porcelain("XY weird.ex")
      assert output =~ "XY  weird.ex"
    end

    test "handles empty string" do
      assert CompleteTask.format_git_status_porcelain("") == ""
    end

    test "passes through short lines unchanged" do
      output = CompleteTask.format_git_status_porcelain("ab")
      assert output == "ab "
    end
  end

  describe "complete/5" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "complete_task_complete_test_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)
      Git.init(tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create an initial commit
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")
      {:ok, base_commit} = Git.rev_parse(tmp_dir, "HEAD")

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir, base_commit: base_commit}}
    end

    test "creates a git tag subagent_<agent_id> on the commit", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      result =
        CompleteTask.complete("agent_123", "Task done", base_commit,
          base_commit: base_commit
        )

      assert %{result: "Task done", commit_sha: ^base_commit, tag: "subagent_agent_123"} = result

      # Verify the tag exists and points to the correct commit
      {:ok, tagged_commit} = Git.rev_parse(tmp_dir, "subagent_agent_123^{}")
      assert tagged_commit == base_commit

      Process.delete(:repo_path)
    end

    test "writes a JSON metadata note with --ref=evogit when base_commit is provided", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      CompleteTask.complete("agent_meta", "Result text", base_commit,
        base_commit: base_commit,
        parent_id: "parent_1",
        depth: 2,
        objective: "Investigate the codebase"
      )

      # Verify the note is readable via Git.get_note
      assert {:ok, metadata} = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      assert metadata["agent_id"] == "agent_meta"
      assert metadata["base_commit"] == base_commit
      assert metadata["final_commit"] == base_commit
      assert metadata["parent_id"] == "parent_1"
      assert metadata["depth"] == 2
      assert metadata["objective"] == "Investigate the codebase"
      assert metadata["completed_at"] != nil

      # Verify completed_at is a valid ISO8601 timestamp
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(metadata["completed_at"])

      Process.delete(:repo_path)
    end

    test "skips metadata note when base_commit is nil", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      CompleteTask.complete("agent_no_base", "Result text", base_commit,
        base_commit: nil
      )

      # Verify no note was created
      assert :error = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      Process.delete(:repo_path)
    end

    test "returns a map with :result, :commit_sha, and :tag", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      result =
        CompleteTask.complete("agent_ret", "My findings", base_commit,
          base_commit: base_commit
        )

      assert is_map(result)
      assert Map.has_key?(result, :result)
      assert Map.has_key?(result, :commit_sha)
      assert Map.has_key?(result, :tag)
      assert result.result == "My findings"
      assert result.commit_sha == base_commit
      assert result.tag == "subagent_agent_ret"

      Process.delete(:repo_path)
    end

    test "note is round-trippable via Git.get_note", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      CompleteTask.complete("agent_rt", "Round trip result", base_commit,
        base_commit: base_commit,
        parent_id: "root_agent",
        depth: 1,
        objective: "Check round-trip"
      )

      # Use the higher-level Git.get_note which parses JSON
      assert {:ok, metadata} = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])
      assert is_map(metadata)
      assert metadata["agent_id"] == "agent_rt"
      assert metadata["final_commit"] == base_commit

      Process.delete(:repo_path)
    end

    test "uses default opts when not provided", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      result = CompleteTask.complete("agent_defaults", "Simple result", base_commit)

      assert result.tag == "subagent_agent_defaults"
      assert result.result == "Simple result"

      # No base_commit in opts, so no metadata note
      assert :error = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      Process.delete(:repo_path)
    end
  end

  describe "get_agent_metadata/2" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "complete_task_metadata_test_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)
      Git.init(tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_dir)

      # Create an initial commit
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")
      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir, commit_sha: commit_sha}}
    end

    test "returns ok with metadata map when a note exists", %{
      tmp_dir: tmp_dir,
      commit_sha: commit_sha
    } do
      Process.put(:repo_path, tmp_dir)

      # First, create completion with metadata
      CompleteTask.complete("agent_gm", "Some result", commit_sha,
        base_commit: commit_sha,
        parent_id: "root",
        depth: 3,
        objective: "Test metadata retrieval"
      )

      # Now retrieve the metadata
      assert {:ok, metadata} = CompleteTask.get_agent_metadata(tmp_dir, commit_sha)
      assert metadata["agent_id"] == "agent_gm"
      assert metadata["base_commit"] == commit_sha
      assert metadata["final_commit"] == commit_sha
      assert metadata["parent_id"] == "root"
      assert metadata["depth"] == 3
      assert metadata["objective"] == "Test metadata retrieval"

      Process.delete(:repo_path)
    end

    test "returns error when no note exists", %{
      tmp_dir: tmp_dir,
      commit_sha: commit_sha
    } do
      # No note was added, so it should return :error
      assert :error = CompleteTask.get_agent_metadata(tmp_dir, commit_sha)
    end

    test "returns error for a commit that doesn't exist" do
      assert :error = CompleteTask.get_agent_metadata("/nonexistent/path", "abc123")
    end
  end
end
