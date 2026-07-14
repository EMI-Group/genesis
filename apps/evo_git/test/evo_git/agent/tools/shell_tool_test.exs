defmodule EvoGit.Agent.Tools.ShellToolTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ShellTool

  @repo_root "/home/user/my-project"
  @repo_path "/home/user/my-project/.genesis/workers/worker_T1_A1"

  describe "detect_cd_warnings/3" do
    test "returns nil when no cd in command" do
      assert ShellTool.detect_cd_warnings("ls -la", @repo_path, @repo_root) == nil
      assert ShellTool.detect_cd_warnings("git status", @repo_path, @repo_root) == nil
      assert ShellTool.detect_cd_warnings("mix test", @repo_path, @repo_root) == nil
    end

    test "returns warning when cd to another agent's worktree" do
      other = "/home/user/my-project/.genesis/workers/worker_T2_A3"

      result =
        ShellTool.detect_cd_warnings("cd #{other}", @repo_path, @repo_root)

      assert result =~ "another agent's worktree"
      assert result =~ @repo_path
    end

    test "returns nil when cd to own worktree" do
      result =
        ShellTool.detect_cd_warnings("cd #{@repo_path} && mix test", @repo_path, @repo_root)

      assert result == nil
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
      other = "/home/user/my-project/.genesis/workers/worker_T2_A3"

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

  describe "redundant_cd?/3" do
    test "returns true when cd to own worktree" do
      assert ShellTool.redundant_cd?("cd #{@repo_path} && mix test", @repo_path, @repo_root) == true
    end

    test "returns false for other commands" do
      assert ShellTool.redundant_cd?("ls -la", @repo_path, @repo_root) == false
      assert ShellTool.redundant_cd?("cd #{@repo_root}", @repo_path, @repo_root) == false
      assert ShellTool.redundant_cd?("cd /tmp", @repo_path, @repo_root) == false
    end
  end

  describe "redundant_cd_warning/1" do
    test "returns the warning text with the path" do
      result = ShellTool.redundant_cd_warning(@repo_path)
      assert result =~ "You don't need to `cd` into your worktree"
      assert result =~ @repo_path
    end
  end

  describe "describe_exit_code/1" do
    test "returns nil for exit code 0" do
      assert ShellTool.describe_exit_code(0) == nil
    end

    test "returns nil for non-signal exit codes below 128" do
      assert ShellTool.describe_exit_code(1) == nil
      assert ShellTool.describe_exit_code(2) == nil
      assert ShellTool.describe_exit_code(127) == nil
    end

    test "detects SIGKILL (137) as OOM" do
      result = ShellTool.describe_exit_code(137)

      assert result.header =~ "exit code 137"
      assert result.header =~ "SIGKILL"
      assert result.description =~ "Out-Of-Memory"
      assert result.description =~ "OOM"
      assert result.description =~ "memory"
    end

    test "detects SIGSEGV (139) as segmentation fault" do
      result = ShellTool.describe_exit_code(139)

      assert result.header =~ "exit code 139"
      assert result.header =~ "SIGSEGV"
      assert result.description =~ "segmentation fault"
      assert result.description =~ "memory access violation"
    end

    test "detects SIGABRT (134) as abort" do
      result = ShellTool.describe_exit_code(134)

      assert result.header =~ "exit code 134"
      assert result.header =~ "SIGABRT"
      assert result.description =~ "assertion failure"
    end

    test "detects SIGFPE (136) as floating point exception" do
      result = ShellTool.describe_exit_code(136)

      assert result.header =~ "exit code 136"
      assert result.header =~ "SIGFPE"
      assert result.description =~ "floating point exception"
    end

    test "detects SIGBUS (135) as bus error" do
      result = ShellTool.describe_exit_code(135)

      assert result.header =~ "exit code 135"
      assert result.header =~ "SIGBUS"
      assert result.description =~ "bus error"
    end

    test "detects SIGTERM (143) as termination signal" do
      result = ShellTool.describe_exit_code(143)

      assert result.header =~ "exit code 143"
      assert result.header =~ "SIGTERM"
      assert result.description =~ "termination signal"
    end

    test "detects SIGINT (130) as interrupt" do
      result = ShellTool.describe_exit_code(130)

      assert result.header =~ "exit code 130"
      assert result.header =~ "SIGINT"
      assert result.description =~ "Ctrl+C"
    end

    test "detects SIGILL (132) as illegal instruction" do
      result = ShellTool.describe_exit_code(132)

      assert result.header =~ "exit code 132"
      assert result.header =~ "SIGILL"
      assert result.description =~ "illegal instruction"
    end

    test "provides generic message for unknown signals >= 128" do
      # 200 - 128 = 72 (a high/unknown signal number)
      result = ShellTool.describe_exit_code(200)

      assert result.header =~ "exit code 200"
      assert result.header =~ "signal 72"
      refute Map.has_key?(result, :signame)
      assert result.description =~ "signal 72"
      assert result.description =~ "abnormal termination"
    end

    test "result is a map with header and description keys" do
      result = ShellTool.describe_exit_code(137)

      assert is_map(result)
      assert Map.has_key?(result, :header)
      assert Map.has_key?(result, :description)
      assert is_binary(result.header)
      assert is_binary(result.description)
    end
  end
end
