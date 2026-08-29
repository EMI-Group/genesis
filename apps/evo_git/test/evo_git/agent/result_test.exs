defmodule EvoGit.Agent.ResultTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Usage

  describe "new/3" do
    test "creates a struct with required fields only" do
      result = Result.new("Fixed the bug", "abc123")

      assert result.result == "Fixed the bug"
      assert result.commit_sha == "abc123"
    end

    test "required fields default optional fields to nil" do
      result = Result.new("Done", "sha1")

      assert result.tag == nil
      assert result.branch == nil
      assert result.base_commit == nil
      assert result.repo_id == nil
      assert result.usage == nil
      assert result.agent_count == nil
      assert result.archive_records == nil
    end

    test "foreign_repo_commits defaults to %{}" do
      result = Result.new("Fixed", "sha")
      assert result.foreign_repo_commits == %{}
    end

    test "accepts foreign_repo_commits option" do
      result = Result.new("Fixed", "sha", foreign_repo_commits: %{"orig" => "abc123"})
      assert result.foreign_repo_commits == %{"orig" => "abc123"}
    end

    test "accepts tag option" do
      result = Result.new("Fixed", "sha", tag: "fix")
      assert result.tag == "fix"
    end

    test "accepts branch option" do
      result = Result.new("Fixed", "sha", branch: "genesis/agent_abc")
      assert result.branch == "genesis/agent_abc"
    end

    test "accepts base_commit option" do
      result = Result.new("Fixed", "sha", base_commit: "base123")
      assert result.base_commit == "base123"
    end

    test "accepts repo_id option" do
      result = Result.new("Fixed", "sha", repo_id: "primary")
      assert result.repo_id == "primary"
    end

    test "accepts usage option with a Usage struct" do
      usage = Usage.zero()
      result = Result.new("Fixed", "sha", usage: usage)
      assert result.usage == usage
    end

    test "accepts agent_count option" do
      result = Result.new("Fixed", "sha", agent_count: 5)
      assert result.agent_count == 5
    end

    test "accepts archive_records option" do
      records = [%{path: "test.exs", summary: "added tests"}]
      result = Result.new("Fixed", "sha", archive_records: records)
      assert result.archive_records == records
    end

    test "accepts all options at once" do
      usage = Usage.zero()
      records = [%{path: "a", summary: "b"}]

      result =
        Result.new("Result text", "commit_sha",
          tag: "feature",
          branch: "genesis/agent_xyz",
          base_commit: "base",
          repo_id: "primary",
          usage: usage,
          agent_count: 3,
          archive_records: records,
          foreign_repo_commits: %{"orig" => "abc"}
        )

      assert result.result == "Result text"
      assert result.commit_sha == "commit_sha"
      assert result.tag == "feature"
      assert result.branch == "genesis/agent_xyz"
      assert result.base_commit == "base"
      assert result.repo_id == "primary"
      assert result.usage == usage
      assert result.agent_count == 3
      assert result.archive_records == records
      assert result.foreign_repo_commits == %{"orig" => "abc"}
    end

    test "ignores unknown options" do
      result = Result.new("Fixed", "sha", unknown_key: "value")
      assert result.result == "Fixed"
      assert result.commit_sha == "sha"
    end

    test "opts defaults to empty list" do
      result = Result.new("Done", "sha")
      # Works identically to passing []
      assert %Result{} = result
    end
  end

  describe "struct type" do
    test "is a Result struct" do
      assert %Result{} = Result.new("test", "sha")
    end

    test "enforce_keys requires result and commit_sha" do
      assert_raise ArgumentError,
                   ~r/the following keys must also be given when building struct/,
                   fn -> struct!(Result, []) end
    end
  end

  describe "doc example" do
    # This verifies the doctest example from the module documentation
    test "matches the documented example" do
      result = Result.new("Fixed the bug", "abc123", tag: "fix")

      assert result.result == "Fixed the bug"
      assert result.commit_sha == "abc123"
      assert result.tag == "fix"
    end
  end
end
