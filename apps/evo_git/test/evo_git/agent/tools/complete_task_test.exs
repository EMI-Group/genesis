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
      # check_git_status default is in the description, not necessarily in the JSON schema
      assert Map.has_key?(props, "check_git_status")
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

      # Ensure ETS tables exist for task-scoped naming lookups (create if not exist)
      unless :ets.whereis(:evogit_sched_meta) != :undefined do
        :ets.new(:evogit_sched_meta, [:set, :public, :named_table])
      end

      unless :ets.whereis(:evogit_agent_state) != :undefined do
        :ets.new(:evogit_agent_state, [:set, :public, :named_table])
      end

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir, base_commit: base_commit}}
    end

    test "returns a branch name evogit-agent-T<task_id>-A<task_local_id> for the agent", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      # Insert ETS entries for task-scoped naming
      :ets.insert(:evogit_sched_meta, {"agent_123", %{task_id: "1"}})
      :ets.insert(:evogit_agent_state, {"agent_123", %{task_local_id: 1}})

      result =
        CompleteTask.complete("agent_123", "Task done", base_commit,
          base_commit: base_commit
        )

      assert %{result: "Task done", commit_sha: ^base_commit, branch: "evogit-agent-T1-A1"} = result

      :ets.delete(:evogit_sched_meta, "agent_123")
      :ets.delete(:evogit_agent_state, "agent_123")
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

    test "returns a map with :result, :commit_sha, and :branch", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit
    } do
      Process.put(:repo_path, tmp_dir)

      # Insert ETS entries for task-scoped naming
      :ets.insert(:evogit_sched_meta, {"agent_ret", %{task_id: "2"}})
      :ets.insert(:evogit_agent_state, {"agent_ret", %{task_local_id: 3}})

      result =
        CompleteTask.complete("agent_ret", "My findings", base_commit,
          base_commit: base_commit
        )

      assert is_map(result)
      assert Map.has_key?(result, :result)
      assert Map.has_key?(result, :commit_sha)
      assert Map.has_key?(result, :branch)
      assert result.result == "My findings"
      assert result.commit_sha == base_commit
      assert result.branch == "evogit-agent-T2-A3"

      :ets.delete(:evogit_sched_meta, "agent_ret")
      :ets.delete(:evogit_agent_state, "agent_ret")
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

      # Insert ETS entries for task-scoped naming
      :ets.insert(:evogit_sched_meta, {"agent_defaults", %{task_id: "5"}})
      :ets.insert(:evogit_agent_state, {"agent_defaults", %{task_local_id: 7}})

      result = CompleteTask.complete("agent_defaults", "Simple result", base_commit)

      assert result.branch == "evogit-agent-T5-A7"
      assert result.result == "Simple result"

      # No base_commit in opts, so no metadata note
      assert :error = Git.get_note(tmp_dir, base_commit, ["--ref=evogit"])

      :ets.delete(:evogit_sched_meta, "agent_defaults")
      :ets.delete(:evogit_agent_state, "agent_defaults")
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

  describe "archive functionality" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "complete_task_archive_test_" <> to_string(System.unique_integer())
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

      # Make a second commit so we have a distinct final commit
      File.write!(Path.join(tmp_dir, "test.txt"), "updated content")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Updated commit")
      {:ok, final_commit} = Git.rev_parse(tmp_dir, "HEAD")

      # Ensure ETS tables exist for task-scoped naming lookups
      unless :ets.whereis(:evogit_sched_meta) != :undefined do
        :ets.new(:evogit_sched_meta, [:set, :public, :named_table])
      end

      unless :ets.whereis(:evogit_agent_state) != :undefined do
        :ets.new(:evogit_agent_state, [:set, :public, :named_table])
      end

      # Create the archive records ETS table (duplicate_bag for multiple records per task)
      if :ets.whereis(:evogit_archive_records) != :undefined do
        :ets.delete(:evogit_archive_records)
      end

      :ets.new(:evogit_archive_records, [:named_table, :public, :duplicate_bag])

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        # Clean up the archive table if it still exists
        if :ets.whereis(:evogit_archive_records) != :undefined do
          :ets.delete(:evogit_archive_records)
        end
      end)

      {:ok, %{tmp_dir: tmp_dir, base_commit: base_commit, final_commit: final_commit}}
    end

    test "creates archive refs when archive is enabled", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)

      :ets.insert(:evogit_sched_meta, {"agent_arc1", %{task_id: "1"}})
      :ets.insert(:evogit_agent_state, {"agent_arc1", %{task_local_id: 1}})

      CompleteTask.complete("agent_arc1", "Archive result", final_commit,
        base_commit: base_commit,
        archive: true,
        objective: "Test archive",
        parent_id: nil,
        depth: 0
      )

      ref_start = "refs/genesis/archive/T1-A1-start"
      ref_final = "refs/genesis/archive/T1-A1-final"

      assert {:ok, ^base_commit} = Git.rev_parse(tmp_dir, ref_start)
      assert {:ok, ^final_commit} = Git.rev_parse(tmp_dir, ref_final)

      # Verify the archive record was written to ETS
      records = :ets.lookup(:evogit_archive_records, "1")
      assert length(records) == 1

      {_task_id, record} = hd(records)
      assert record.agent_id == "agent_arc1"
      assert record.base_commit == base_commit
      assert record.final_commit == final_commit

      :ets.delete(:evogit_sched_meta, "agent_arc1")
      :ets.delete(:evogit_agent_state, "agent_arc1")
      Process.delete(:repo_path)
    end

    test "does NOT create archive refs when archive is disabled (default)", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)

      :ets.insert(:evogit_sched_meta, {"agent_arc2", %{task_id: "2"}})
      :ets.insert(:evogit_agent_state, {"agent_arc2", %{task_local_id: 2}})

      # No archive: true
      CompleteTask.complete("agent_arc2", "No archive result", final_commit,
        base_commit: base_commit
      )

      ref_start = "refs/genesis/archive/T2-A2-start"
      ref_final = "refs/genesis/archive/T2-A2-final"

      # These refs should not exist
      assert {:error, _, _} = Git.rev_parse(tmp_dir, ref_start)
      assert {:error, _, _} = Git.rev_parse(tmp_dir, ref_final)

      # No archive records should be written
      assert :ets.lookup(:evogit_archive_records, "2") == []

      :ets.delete(:evogit_sched_meta, "agent_arc2")
      :ets.delete(:evogit_agent_state, "agent_arc2")
      Process.delete(:repo_path)
    end

    test "includes usage in git note metadata", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)

      :ets.insert(:evogit_sched_meta, {"agent_arc3", %{task_id: "3"}})
      :ets.insert(:evogit_agent_state, {"agent_arc3", %{task_local_id: 3}})

      usage = %EvoGit.Agent.Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        total_cost: 0.015
      }

      CompleteTask.complete("agent_arc3", "Usage result", final_commit,
        base_commit: base_commit,
        usage: usage
      )

      # Read back the note
      assert {:ok, metadata} = Git.get_note(tmp_dir, final_commit, ["--ref=evogit"])

      assert metadata["usage"] != nil
      assert metadata["usage"]["input_tokens"] == 100
      assert metadata["usage"]["output_tokens"] == 50
      assert metadata["usage"]["total_tokens"] == 150
      assert metadata["usage"]["cost"] == 0.015

      :ets.delete(:evogit_sched_meta, "agent_arc3")
      :ets.delete(:evogit_agent_state, "agent_arc3")
      Process.delete(:repo_path)
    end

    test "archive record has all required keys", %{
      tmp_dir: tmp_dir,
      base_commit: base_commit,
      final_commit: final_commit
    } do
      Process.put(:repo_path, tmp_dir)
      Process.put(:evogit_started_at, DateTime.utc_now() |> DateTime.to_iso8601())

      :ets.insert(:evogit_sched_meta, {"agent_arc4", %{task_id: "4"}})
      :ets.insert(:evogit_agent_state, {"agent_arc4", %{task_local_id: 4}})

      CompleteTask.complete("agent_arc4", "Full record test", final_commit,
        base_commit: base_commit,
        archive: true,
        objective: "Test record shape",
        parent_id: "parent_99",
        depth: 3
      )

      records = :ets.lookup(:evogit_archive_records, "4")
      assert length(records) == 1

      {_task_id, record} = hd(records)

      # Verify all required keys are present
      assert Map.has_key?(record, :agent_id)
      assert Map.has_key?(record, :parent_id)
      assert Map.has_key?(record, :depth)
      assert Map.has_key?(record, :objective)
      assert Map.has_key?(record, :result)
      assert Map.has_key?(record, :base_commit)
      assert Map.has_key?(record, :final_commit)
      assert Map.has_key?(record, :archive_ref_start)
      assert Map.has_key?(record, :archive_ref_final)
      assert Map.has_key?(record, :branch_name)
      assert Map.has_key?(record, :usage)
      assert Map.has_key?(record, :completed_at)

      # Verify values
      assert record.agent_id == "agent_arc4"
      assert record.parent_id == "parent_99"
      assert record.depth == 3
      assert record.objective == "Test record shape"
      assert record.result == "Full record test"
      assert record.base_commit == base_commit
      assert record.final_commit == final_commit
      assert record.archive_ref_start == "refs/genesis/archive/T4-A4-start"
      assert record.archive_ref_final == "refs/genesis/archive/T4-A4-final"
      assert record.branch_name == "evogit-agent-T4-A4"
      assert record.completed_at != nil

      :ets.delete(:evogit_sched_meta, "agent_arc4")
      :ets.delete(:evogit_agent_state, "agent_arc4")
      Process.delete(:repo_path)
      Process.delete(:evogit_started_at)
    end
  end
end
