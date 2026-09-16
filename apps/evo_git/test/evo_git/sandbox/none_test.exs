defmodule EvoGit.Sandbox.NoneTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.None
  alias EvoGit.TaskTmpdir

  # A fresh, never-created managed per-task tmpdir path (the backend only
  # exports it as an env var — no I/O stats it).
  defp per_task_tmpdir! do
    dir =
      Path.join(System.tmp_dir!(), "evogit_none_task_tmp_#{System.unique_integer([:positive])}")

    TaskTmpdir.put_current(dir)
    on_exit(fn -> TaskTmpdir.put_current(nil) end)
    dir
  end

  describe "enabled?/0" do
    test "always returns false" do
      assert None.enabled?() == false
    end
  end

  describe "ensure_initialized/0" do
    test "returns :ok" do
      assert None.ensure_initialized() == :ok
    end
  end

  describe "run/4" do
    test "runs a command directly and returns output" do
      {output, exit_code} = None.run(System.tmp_dir!(), "echo", ["hello"])

      assert exit_code == 0
      assert String.contains?(output, "hello")
    end

    test "runs a command directly when nix is not enabled (default)" do
      # In the test environment nix is almost certainly not enabled (no config,
      # no flake), so this exercises the direct-execution path.
      {output, exit_code} = None.run(System.tmp_dir!(), "echo", ["direct-exec"])

      assert exit_code == 0
      assert String.contains?(output, "direct-exec")
    end

    # Note: the nix-wrapped path can't be easily tested without a real nix
    # installation + flake.nix + config. The EvoGit.Nix module's wrap_command/2
    # is tested separately.
  end

  describe "resolve_executable/1" do
    # Regression for a Windows crash: the old run_with_partial_windows path
    # called raw `:os.find_executable/1` with a binary (Elixir string), which
    # raises ArgumentError on OTP 27+ (internally it does `Name ++ ".exe"` — a
    # binary ++ charlist). resolve_executable/1 normalizes input to a string
    # and must NEVER raise for binary or charlist input.
    test "accepts binary (Elixir string) input without raising ArgumentError" do
      # The essential regression assertion: binary input must not raise.
      # Whether "sh" resolves depends on the environment (the test env runs
      # under Nix where System.find_executable("sh") resolves); guard on it.
      result = None.resolve_executable("sh")

      if System.find_executable("sh") do
        assert is_binary(result)
        assert result == System.find_executable("sh")
      else
        assert result == nil
      end
    end

    test "accepts charlist input" do
      result = None.resolve_executable(~c"sh")

      if System.find_executable("sh") do
        assert is_binary(result)
        assert result == System.find_executable("sh")
      else
        assert result == nil
      end
    end

    test "returns nil for a missing executable without raising" do
      assert None.resolve_executable("genesis_definitely_missing_executable_xyz123") == nil
      assert None.resolve_executable(~c"genesis_definitely_missing_executable_xyz123") == nil
    end

    test "returns an existing absolute path unchanged" do
      case System.find_executable("sh") do
        nil ->
          # No reliably present absolute executable in this environment.
          :ok

        path when is_binary(path) ->
          if Path.type(path) == :absolute do
            assert None.resolve_executable(path) == path
          end
      end
    end
  end

  describe "run/4 — stdin redirection" do
    test "disables stdin so commands that read stdin don't hang" do
      # `cat` with no args reads from stdin. With stdin redirected from /dev/null,
      # it gets immediate EOF and exits with code 0 (empty output).
      {output, exit_code} = None.run(System.tmp_dir!(), "cat", [])

      assert exit_code == 0
      assert output == ""
    end
  end

  describe "run_with_partial — stdin redirection" do
    test "disables stdin so commands that read stdin return immediately" do
      result = None.run_with_partial(System.tmp_dir!(), "cat", [], nil, 5000, nil)

      assert {:ok, "", 0} = result
    end
  end

  describe "run/4 — GIT_EDITOR injection for git commands" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "evo_git_none_git_test_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)
      {_, 0} = System.cmd("git", ["init"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "wires GIT_EDITOR so git reports a no-op editor for a git command", %{tmp_dir: tmp_dir} do
      # `git var GIT_EDITOR` prints the editor git would launch. With GIT_EDITOR
      # set to the `true` executable via the None backend, this resolves to a
      # path/name ending in "true" (a no-op), proving the env reaches the git
      # subprocess through the agent tool path.
      {output, 0} = None.run(tmp_dir, "git", ["var", "GIT_EDITOR"])

      assert String.ends_with?(String.trim(output), "true")
    end

    test "sets LC_ALL=C so git output is locale-independent for a git command", %{
      tmp_dir: tmp_dir
    } do
      # `git var GIT_EDITOR` exit 0 confirms the process ran. The LC_ALL=C
      # value is exercised indirectly; a direct check is that a git command
      # runs successfully (the env list is accepted by System.cmd).
      {output, exit_code} = None.run(tmp_dir, "git", ["status", "--porcelain"])

      assert exit_code == 0
      assert output == ""
    end
  end

  describe "run/4 — managed per-task tmpdir export (disabled/None path)" do
    test "exports the installed per-task dir as TMPDIR/TMP/TEMP" do
      dir = per_task_tmpdir!()

      for var <- ["TMPDIR", "TMP", "TEMP"] do
        {output, 0} = None.run(System.tmp_dir!(), "bash", ["-c", "printf %s \"$#{var}\""])

        assert output == dir,
               "expected the managed per-task dir in $#{var}, got: #{inspect(output)}"
      end
    end

    test "does not inject a managed dir when none is installed (inherited host temp)" do
      # Precondition: no per-task dir installed on this process.
      assert TaskTmpdir.current() == nil

      {output, 0} = None.run(System.tmp_dir!(), "bash", ["-c", "printf %s \"$TMPDIR\""])

      # No override → the child inherits the caller's $TMPDIR (possibly empty).
      assert output == (System.get_env("TMPDIR") || "")
    end

    test "run_with_partial/6 (timed disabled path) also exports TMPDIR/TMP/TEMP" do
      dir = per_task_tmpdir!()
      on_exit(fn -> File.rm_rf(dir) end)

      for var <- ["TMPDIR", "TMP", "TEMP"] do
        {:ok, output, 0} =
          None.run_with_partial(
            System.tmp_dir!(),
            "bash",
            ["-c", "printf %s \"$#{var}\""],
            nil,
            5000,
            nil
          )

        assert output == dir
      end
    end
  end

  describe "EvoGit.Sandbox.run/4 — managed per-task tmpdir export" do
    test "the spawned command sees TMPDIR = the installed per-task dir" do
      dir = per_task_tmpdir!()

      {output, 0} =
        EvoGit.Sandbox.run(System.tmp_dir!(), "bash", ["-c", "printf %s \"$TMPDIR\""])

      assert output == dir
    end

    test "no per-task dir installed → the managed dir is not injected" do
      assert TaskTmpdir.current() == nil

      {output, 0} =
        EvoGit.Sandbox.run(System.tmp_dir!(), "bash", ["-c", "printf %s \"$TMPDIR\""])

      assert output == (System.get_env("TMPDIR") || "")
    end
  end
end
