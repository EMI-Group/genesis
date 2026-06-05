defmodule EvoGit.Agent.SubagentProcessingTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.Core.ForeignRepo

  describe "resolve_subagent_path/3" do
    setup do
      foreign_repos = [
        ForeignRepo.new(:primary, "/home/user/primary-repo"),
        ForeignRepo.new(:original, "/home/user/original-proj"),
        ForeignRepo.new(:reference, "/home/user/reference-proj")
      ]

      parent_state = %{phylo_node: %{repo: "/home/user/primary-repo"}}

      %{foreign_repos: foreign_repos, parent_state: parent_state}
    end

    test "absolute path matching a foreign repo returns that repo's id, root, and relative path",
         %{foreign_repos: foreign_repos, parent_state: parent_state} do
      assert {:ok, :original, "/home/user/original-proj", "./src/main.py"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/original-proj/src/main.py",
                 parent_state,
                 foreign_repos
               )
    end

    test "absolute path matching the primary repo returns :primary with relative path",
         %{foreign_repos: foreign_repos, parent_state: parent_state} do
      assert {:ok, :primary, "/home/user/primary-repo", "./lib/app.ex"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/primary-repo/lib/app.ex",
                 parent_state,
                 foreign_repos
               )
    end

    test "absolute path not in any repo returns an error tuple with helpful message",
         %{foreign_repos: foreign_repos, parent_state: parent_state} do
      assert {:error, msg} =
               SubagentProcessing.resolve_subagent_path(
                 "/tmp/unknown/project",
                 parent_state,
                 foreign_repos
               )

      assert msg =~ "Absolute path"
      assert msg =~ "/tmp/unknown/project"
      assert msg =~ "not within"
    end

    test "absolute path not in any repo with empty foreign_repos still matches primary repo",
         %{parent_state: parent_state} do
      assert {:ok, :primary, "/home/user/primary-repo", "./lib/app.ex"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/primary-repo/lib/app.ex",
                 parent_state,
                 []
               )
    end

    test "relative path stays in primary repo as :primary",
         %{foreign_repos: foreign_repos, parent_state: parent_state} do
      assert {:ok, :primary, "/home/user/primary-repo", "./src/lib"} =
               SubagentProcessing.resolve_subagent_path(
                 "src/lib",
                 parent_state,
                 foreign_repos
               )
    end

    test "nil path raises because normalize_relpath does not accept nil",
         %{foreign_repos: foreign_repos, parent_state: parent_state} do
      assert_raise FunctionClauseError, fn ->
        SubagentProcessing.resolve_subagent_path(nil, parent_state, foreign_repos)
      end
    end

    test "dot-slash relative path stays in primary repo, normalized",
         %{foreign_repos: foreign_repos, parent_state: parent_state} do
      assert {:ok, :primary, "/home/user/primary-repo", "./src/lib"} =
               SubagentProcessing.resolve_subagent_path(
                 "./src/lib",
                 parent_state,
                 foreign_repos
               )
    end

    test "multiple foreign repos, path matches the correct one" do
      foreign_repos = [
        ForeignRepo.new(:primary, "/home/user/primary-repo"),
        ForeignRepo.new(:original, "/home/user/original-proj"),
        ForeignRepo.new(:reference, "/home/user/reference-proj")
      ]

      parent_state = %{phylo_node: %{repo: "/home/user/primary-repo"}}

      assert {:ok, :reference, "/home/user/reference-proj", "./docs/README.md"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/reference-proj/docs/README.md",
                 parent_state,
                 foreign_repos
               )
    end

    test "absolute path exactly at repo root returns relative path ./" do
      foreign_repos = [
        ForeignRepo.new(:primary, "/home/user/primary-repo"),
        ForeignRepo.new(:original, "/home/user/original-proj")
      ]

      parent_state = %{phylo_node: %{repo: "/home/user/primary-repo"}}

      assert {:ok, :original, "/home/user/original-proj", "./"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/original-proj",
                 parent_state,
                 foreign_repos
               )
    end
  end

  describe "format_subagent_result/1" do
    test "foreign_repo_read_only error returns the custom message" do
      msg = "Custom message"

      result = SubagentProcessing.format_subagent_result({:error, {:foreign_repo_read_only, msg}})

      assert result == "Error: Custom message"
    end

    test "foreign_repo_read_only error with real message mentions read-write restriction" do
      msg = "Read-write agents cannot be spawned in foreign repositories"

      result = SubagentProcessing.format_subagent_result({:error, {:foreign_repo_read_only, msg}})

      assert result =~ "Read-write agents cannot be spawned"
    end

    test "path_ignored error mentions ignored folder" do
      result = SubagentProcessing.format_subagent_result({:error, :path_ignored})

      assert result =~ "ignored folder"
    end

    test "path_not_exist error mentions does not exist" do
      result = SubagentProcessing.format_subagent_result({:error, :path_not_exist})

      assert result =~ "does not exist"
    end

    test "generic error includes Subagent failed" do
      result = SubagentProcessing.format_subagent_result({:error, :some_other_reason})

      assert result =~ "Subagent failed"
    end

    test "ok result with commit_sha includes result text and commit info" do
      agent_result = %Result{result: "Done successfully", commit_sha: "abc123def456"}

      result = SubagentProcessing.format_subagent_result({:ok, agent_result})

      assert result =~ "Done successfully"
      assert result =~ "abc123def456"
      assert result =~ "# Result"
      assert result =~ "# Final Commit"
    end

    test "ok result is properly trimmed" do
      agent_result = %Result{result: "Hello", commit_sha: "sha1"}

      result = SubagentProcessing.format_subagent_result({:ok, agent_result})

      refute String.ends_with?(result, "\n")
    end

    test "plain string returns the string as-is" do
      text = "Just a plain result string"

      assert SubagentProcessing.format_subagent_result(text) == text
    end

    test "non-standard value returns inspected representation" do
      result = SubagentProcessing.format_subagent_result(:atom)

      assert result == inspect(:atom)
    end
  end

  describe "format_subagent_result/1 with repo_id" do
    test "ok result with repo_id formats the same as without repo_id" do
      agent_result = %Result{result: "Foreign investigation done", commit_sha: "abc123", repo_id: :original}

      result = SubagentProcessing.format_subagent_result({:ok, agent_result})

      assert result =~ "Foreign investigation done"
      assert result =~ "abc123"
      assert result =~ "# Result"
      assert result =~ "# Final Commit"
    end
  end
end
