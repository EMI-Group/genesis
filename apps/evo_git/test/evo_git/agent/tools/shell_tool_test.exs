defmodule EvoGit.Agent.Tools.ShellToolTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ShellTool
  alias EvoGit.Adapters.Git

  @repo_root "/home/user/my-project"
  @repo_path "/home/user/my-project/.genesis/workers/worker_T1_A1"

  describe "format_duration/1" do
    test "0 ms" do
      assert ShellTool.format_duration(0) == "0 ms"
    end

    test "sub-second values in milliseconds" do
      assert ShellTool.format_duration(1) == "1 ms"
      assert ShellTool.format_duration(456) == "456 ms"
      assert ShellTool.format_duration(999) == "999 ms"
    end

    test "values in seconds (2 decimal places)" do
      assert ShellTool.format_duration(1000) == "1.00 s"
      assert ShellTool.format_duration(1234) == "1.23 s"
      assert ShellTool.format_duration(1500) == "1.50 s"
    end

    test "values in minutes and seconds" do
      assert ShellTool.format_duration(60000) == "1m 0s"
      assert ShellTool.format_duration(65000) == "1m 5s"
      assert ShellTool.format_duration(125_000) == "2m 5s"
    end

    test "values in hours, minutes, and seconds" do
      assert ShellTool.format_duration(3_600_000) == "1h 0m 0s"
      assert ShellTool.format_duration(3_723_000) == "1h 2m 3s"
      assert ShellTool.format_duration(7_384_000) == "2h 3m 4s"
    end

    test "large value" do
      # 25 hours, 30 minutes, 15 seconds
      ms = 25 * 3_600_000 + 30 * 60_000 + 15_000
      assert ShellTool.format_duration(ms) == "25h 30m 15s"
    end
  end

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

    test "detects relative cd reaching the repository root" do
      result =
        ShellTool.detect_cd_warnings("cd ../../../ && mix test", @repo_path, @repo_root)

      assert result =~ "repository root"
      assert result =~ @repo_root
    end

    test "detects relative cd into another agent's worktree" do
      result =
        ShellTool.detect_cd_warnings("cd ../worker_T2_A3", @repo_path, @repo_root)

      assert result =~ "another agent's worktree"
      assert result =~ @repo_path
    end

    test "returns nil for relative cd staying inside own worktree" do
      assert ShellTool.detect_cd_warnings("cd src && mix test", @repo_path, @repo_root) ==
               nil

      assert ShellTool.detect_cd_warnings("cd ./src && mix test", @repo_path, @repo_root) ==
               nil
    end
  end

  describe "redundant_cd?/3" do
    test "returns true when cd to own worktree" do
      assert ShellTool.redundant_cd?("cd #{@repo_path} && mix test", @repo_path, @repo_root) ==
               true
    end

    test "returns true for a redundant `cd .`" do
      assert ShellTool.redundant_cd?("cd . && mix test", @repo_path, @repo_root) == true
    end

    test "returns false for other commands" do
      assert ShellTool.redundant_cd?("ls -la", @repo_path, @repo_root) == false
      assert ShellTool.redundant_cd?("cd #{@repo_root}", @repo_path, @repo_root) == false
      assert ShellTool.redundant_cd?("cd /tmp", @repo_path, @repo_root) == false
      assert ShellTool.redundant_cd?("cd ../../../", @repo_path, @repo_root) == false
      assert ShellTool.redundant_cd?("cd src && mix test", @repo_path, @repo_root) == false
    end
  end

  describe "redundant_cd_warning/1" do
    test "returns the warning text with the path" do
      result = ShellTool.redundant_cd_warning(@repo_path)
      assert result =~ "You don't need to `cd` into your worktree"
      assert result =~ @repo_path
    end
  end

  describe "detect_redundant_shell/2" do
    # shell_name is passed explicitly so the tests are config-independent.
    test "flags absolute shell paths with a -c flag" do
      assert ShellTool.detect_redundant_shell("/bin/sh -c 'ls'", "bash") =~
               "You don't need to invoke `/bin/sh -c`"

      assert ShellTool.detect_redundant_shell("/bin/bash -c 'ls'", "bash") =~
               "You don't need to invoke `/bin/bash -c`"

      assert ShellTool.detect_redundant_shell("/usr/bin/sh -c 'ls'", "bash") =~
               "You don't need to invoke `/usr/bin/sh -c`"
    end

    test "flags bare shell names with a -c flag" do
      assert ShellTool.detect_redundant_shell("sh -c 'ls'", "bash") =~
               "You don't need to invoke `sh -c`"

      assert ShellTool.detect_redundant_shell("bash -c 'ls'", "bash") =~
               "You don't need to invoke `bash -c`"
    end

    test "flags a bare absolute shell path" do
      result = ShellTool.detect_redundant_shell("/bin/sh", "bash")
      assert result =~ "You don't need to invoke `/bin/sh`"
      assert result =~ "(`bash`)"
    end

    test "hint references the effective shell name argument" do
      result = ShellTool.detect_redundant_shell("/bin/sh -c 'ls'", "zsh")
      assert result =~ "(`zsh`)"
    end

    test "ignores leading whitespace before the shell invocation" do
      assert ShellTool.detect_redundant_shell("  /bin/sh -c 'ls'", "bash") =~
               "You don't need to invoke `/bin/sh -c`"
    end

    test "returns nil for normal commands" do
      assert ShellTool.detect_redundant_shell("ls -la", "bash") == nil
      assert ShellTool.detect_redundant_shell("mix test", "bash") == nil
      assert ShellTool.detect_redundant_shell("git status", "bash") == nil
    end

    test "returns nil when a shell path/name is followed by a non-flag argument" do
      assert ShellTool.detect_redundant_shell("/bin/bash script.sh", "bash") == nil
      assert ShellTool.detect_redundant_shell("sh script.sh", "bash") == nil
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

  describe "execute/3 result formatting" do
    @describetag :tmp_dir

    test "success includes [Exit Code: 0] in the status prefix", %{tmp_dir: tmp_dir} do
      result = ShellTool.execute(%{"command" => "echo hello"}, tmp_dir, tmp_dir)

      assert result =~ ~S"[Exit Code: 0]"
      assert result =~ "Command executed successfully"
      assert result =~ "hello"
    end

    test "general failure includes [Exit Code: N] in the status prefix", %{tmp_dir: tmp_dir} do
      # `exit 42` produces a non-zero, non-signal exit code.
      result = ShellTool.execute(%{"command" => "exit 42"}, tmp_dir, tmp_dir)

      assert result =~ ~S"[Exit Code: 42]"
      assert result =~ "Command failed."
    end

    test "exit code appears immediately after the [Took: ...] prefix", %{tmp_dir: tmp_dir} do
      result = ShellTool.execute(%{"command" => "echo hi"}, tmp_dir, tmp_dir)

      assert result =~ ~r/^\[Took: [^\]]+\] \[Exit Code: 0\]/
    end

    test "signal-kill exit code (>= 128) is shown in the prefix", %{tmp_dir: tmp_dir} do
      # `kill -TERM $$` sends SIGTERM to the shell → exit code 143.
      result = ShellTool.execute(%{"command" => "kill -TERM $$"}, tmp_dir, tmp_dir)

      assert result =~ ~S"[Exit Code: 143]"
      assert result =~ "was killed by signal"
    end

    test "timeout does not include an [Exit Code:] prefix", %{tmp_dir: tmp_dir} do
      # `sleep` exceeds a 1ms timeout, hitting the timeout branch (no exit code).
      result =
        ShellTool.execute(
          %{"command" => "sleep 30", "timeout" => 1},
          tmp_dir,
          tmp_dir
        )

      refute result =~ ~S"[Exit Code:"
      assert result =~ "Command timed out"
    end

    test "redundant nested shell invocation appends a hint to the output", %{tmp_dir: tmp_dir} do
      # Sandbox is disabled in test env (plain bash path). The command may fail
      # on systems without /bin/sh (e.g. NixOS, exit 127) — assert on the hint
      # text, not the exit code.
      result = ShellTool.execute(%{"command" => "/bin/sh -c 'echo hi'"}, tmp_dir, tmp_dir)

      assert result =~ "You don't need to invoke `/bin/sh -c`"
      assert result =~ "this tool already runs your command in a shell"
    end
  end

  describe "main-copy mutation hard block (cd into repo root + mutating git)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      # A real git repo with at least one commit so NOT-blocked git commands
      # behave deterministically (they run and fail on the missing branch).
      Git.init(tmp_dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "test repo\n")
      Git.add(tmp_dir, "README.md")
      Git.commit(tmp_dir, "initial commit")

      # A FAKE worktree path inside the repo — a plain directory, not a real
      # linked worktree.
      wt = Path.join([tmp_dir, ".genesis", "workers", "worker_T1_A1"])
      File.mkdir_p!(wt)

      {:ok, wt: wt, repo_root: tmp_dir}
    end

    test "cd into repo root + git checkout is hard-blocked", %{wt: wt, repo_root: repo_root} do
      result =
        ShellTool.execute(
          %{"command" => "cd ../../../ && git checkout evogit-agent-T1-A1"},
          wt,
          repo_root
        )

      assert result =~ "MAIN working copy"
      assert result =~ "blocked"
      assert String.contains?(result, repo_root)
    end

    test "cd into repo root + any mutating git subcommand is hard-blocked", %{
      wt: wt,
      repo_root: repo_root
    } do
      for sub <- ["switch", "reset", "merge", "pull"] do
        result =
          ShellTool.execute(
            %{"command" => "cd ../../../ && git #{sub} evogit-agent-T1-A1"},
            wt,
            repo_root
          )

        assert result =~ "MAIN working copy", "expected git #{sub} to be blocked"
        assert result =~ "blocked", "expected git #{sub} to be blocked"
      end
    end

    test "cd to own worktree + git checkout is NOT hard-blocked", %{
      wt: wt,
      repo_root: repo_root
    } do
      # The command runs and git fails on its own (branch does not exist) —
      # the point is that the hard block is NOT triggered.
      result =
        ShellTool.execute(
          %{"command" => "cd . && git checkout evogit-agent-T1-A1"},
          wt,
          repo_root
        )

      refute result =~ "MAIN working copy"
    end

    test "cd partway into .genesis + git checkout is NOT hard-blocked", %{
      wt: wt,
      repo_root: repo_root
    } do
      # `cd ../..` lands in `.genesis`, NOT the repo root — not blocked.
      result =
        ShellTool.execute(
          %{"command" => "cd ../.. && git checkout evogit-agent-T1-A1"},
          wt,
          repo_root
        )

      refute result =~ "MAIN working copy"
    end

    test "cd into repo root without a mutating git command is NOT hard-blocked", %{
      wt: wt,
      repo_root: repo_root
    } do
      result = ShellTool.execute(%{"command" => "cd ../../../ && ls"}, wt, repo_root)

      refute result =~ "MAIN working copy"
    end
  end
end
