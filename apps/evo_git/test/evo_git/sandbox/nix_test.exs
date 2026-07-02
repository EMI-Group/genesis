defmodule EvoGit.NixTest do
  use ExUnit.Case, async: false

  alias EvoGit.Nix

  setup do
    Nix.reset_state()
    on_exit(fn -> Nix.reset_state() end)
    :ok
  end

  describe "dev_env_state/0" do
    test "returns :not_attempted by default" do
      Nix.reset_state()
      assert Nix.dev_env_state() == :not_attempted
    end
  end

  describe "active?/0" do
    test "returns false when dev_env_state is {:failed, reason}" do
      # Seed a failed state
      :persistent_term.put(:evogit_nix_dev_env_state, {:failed, "some error"})

      # active? should be false when the build failed, regardless of enabled?
      assert Nix.active?() == false
    after
      Nix.reset_state()
    end

    test "returns false when nix is not enabled (default state)" do
      Nix.reset_state()
      # In the test environment nix is almost certainly not enabled
      assert Nix.active?() == false
    end
  end

  describe "wrap_command/2 — shell escaping" do
    setup do
      # Seed the persistent_term so that dev_env_state is {:built, path}
      # and wrap_command uses the cached path without invoking nix.
      tmp = Path.join(System.tmp_dir!(), "evogit_nix_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      dev_env_path = Path.join(tmp, "fake-dev-env.sh")
      File.write!(dev_env_path, "# fake dev env script\n")

      :persistent_term.put(:evogit_nix_dev_env_state, {:built, dev_env_path})

      on_exit(fn ->
        Nix.reset_state()
        File.rm_rf!(tmp)
      end)

      {:ok, dev_env_path: dev_env_path}
    end

    test "returns {bash, [-c, cmd]} tuple shape" do
      {exec, args} = Nix.wrap_command("echo", ["hello"])

      assert exec == "bash"
      assert is_list(args)
      assert length(args) == 2
      assert hd(args) == "-c"
    end

    test "command string sources the dev-env script and execs the executable" do
      {exec, [_flag, cmd]} = Nix.wrap_command("echo", ["hello"])

      assert exec == "bash"
      assert String.contains?(cmd, "source ")
      assert String.contains?(cmd, "; exec ")
    end

    test "escapes an arg containing a single quote" do
      {_exec, [_flag, cmd]} = Nix.wrap_command("echo", ["it's a test"])

      # The single quote in "it's a test" should be escaped as '\''
      # The full arg becomes: 'it'\''s a test'
      assert cmd =~ "'it'\\''s a test'"
    end

    test "escapes an arg containing spaces" do
      {_exec, [_flag, cmd]} = Nix.wrap_command("echo", ["hello world"])

      # "hello world" should be wrapped in single quotes
      assert cmd =~ "'hello world'"
    end

    test "escapes both an executable and its args" do
      {_exec, [_flag, cmd]} = Nix.wrap_command("my exec", ["arg one", "arg'2"])

      # Executable escaped
      assert cmd =~ "'my exec'"
      # arg one escaped
      assert cmd =~ "'arg one'"
      # arg'2 → 'arg'\''2'
      assert cmd =~ "'arg'\\''2'"
    end
  end

  describe "wrap_command/2 — graceful fallback" do
    test "falls back to direct execution when dev_env_state is {:failed, _}" do
      :persistent_term.put(:evogit_nix_dev_env_state, {:failed, "build error"})

      {exec, args} = Nix.wrap_command("echo", ["hello"])

      assert exec == "echo"
      assert args == ["hello"]
    after
      Nix.reset_state()
    end

    # Note: the :not_attempted → ensure_dev_env path is environment-dependent
    # (depends on whether nix is installed and a valid cache exists). The
    # graceful fallback for build failure is covered by the {:failed, _} test
    # above, and the {:built, _} sourcing path is covered in the escaping tests.
  end

  describe "reset_state/0" do
    test "clears the persistent_term key" do
      :persistent_term.put(:evogit_nix_dev_env_state, {:built, "/some/path"})
      assert Nix.dev_env_state() == {:built, "/some/path"}

      Nix.reset_state()

      assert Nix.dev_env_state() == :not_attempted
    end

    test "is safe to call when key is not set" do
      Nix.reset_state()
      Nix.reset_state()
      assert Nix.dev_env_state() == :not_attempted
    end
  end

  describe "nix_env_vars/0" do
    test "returns a list of tuples" do
      vars = Nix.nix_env_vars()

      assert is_list(vars)

      for {key, value} <- vars do
        assert is_binary(key)
        assert is_binary(value)
        assert String.starts_with?(key, "NIX") or key == "SSL_CERT_FILE"
      end
    end
  end
end
