defmodule EvoGit.Agent.Tools.ShellToolTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ShellTool

  @repo_root "/home/user/my-project"
  @repo_path "/home/user/my-project/.evogit/workers/worker_T1_A1"

  describe "detect_cd_warnings/3" do
    test "returns nil when no cd in command" do
      assert ShellTool.detect_cd_warnings("ls -la", @repo_path, @repo_root) == nil
      assert ShellTool.detect_cd_warnings("git status", @repo_path, @repo_root) == nil
      assert ShellTool.detect_cd_warnings("mix test", @repo_path, @repo_root) == nil
    end

    test "returns warning when cd to own worktree" do
      result =
        ShellTool.detect_cd_warnings("cd #{@repo_path} && mix test", @repo_path, @repo_root)

      assert result =~ "You don't need to `cd` into your worktree"
      assert result =~ @repo_path
    end

    test "returns warning when cd to another agent's worktree" do
      other = "/home/user/my-project/.evogit/workers/worker_T2_A3"

      result =
        ShellTool.detect_cd_warnings("cd #{other}", @repo_path, @repo_root)

      assert result =~ "another agent's worktree"
      assert result =~ @repo_path
    end

    test "returns warning when cd to repo root" do
      result =
        ShellTool.detect_cd_warnings("cd #{@repo_root}", @repo_path, @repo_root)

      assert result =~ "repository root"
      assert result =~ @repo_root
      assert result =~ @repo_path
    end

    test "returns nil when cd to unrelated path" do
      assert ShellTool.detect_cd_warnings("cd /tmp", @repo_path, @repo_root) == nil
      assert ShellTool.detect_cd_warnings("cd /usr/local/bin", @repo_path, @repo_root) == nil
    end

    test "returns combined warning for multiple problematic cd commands" do
      other = "/home/user/my-project/.evogit/workers/worker_T2_A3"

      result =
        ShellTool.detect_cd_warnings(
          "cd #{@repo_root} && cd #{other}",
          @repo_path,
          @repo_root
        )

      assert result =~ "repository root"
      assert result =~ "another agent's worktree"
    end

    test "detects cd with quoted paths" do
      result =
        ShellTool.detect_cd_warnings("cd \"#{@repo_root}\"", @repo_path, @repo_root)

      assert result =~ "repository root"

      result =
        ShellTool.detect_cd_warnings("cd '#{@repo_root}'", @repo_path, @repo_root)

      assert result =~ "repository root"
    end

    test "deduplicates identical warnings" do
      result =
        ShellTool.detect_cd_warnings(
          "cd #{@repo_root} && cd #{@repo_root}",
          @repo_path,
          @repo_root
        )

      # Should only contain one copy of the repo root warning
      assert result =~ "repository root"
      occurrences = :binary.matches(result, "repository root")
      assert length(occurrences) == 1
    end
  end
end
