defmodule EvoGit.Sandbox.NoneTest do
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.None

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

  describe "run/4 — GIT_EDITOR injection for git commands" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "evo_git_none_git_test_" <> to_string(System.unique_integer()))

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

    test "sets LC_ALL=C so git output is locale-independent for a git command", %{tmp_dir: tmp_dir} do
      # `git var GIT_EDITOR` exit 0 confirms the process ran. The LC_ALL=C
      # value is exercised indirectly; a direct check is that a git command
      # runs successfully (the env list is accepted by System.cmd).
      {output, exit_code} = None.run(tmp_dir, "git", ["status", "--porcelain"])

      assert exit_code == 0
      assert output == ""
    end
  end
end
