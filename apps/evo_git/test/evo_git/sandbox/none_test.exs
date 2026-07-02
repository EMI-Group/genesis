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
end
