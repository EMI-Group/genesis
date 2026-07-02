defmodule EvoGitTest do
  use ExUnit.Case

  setup do
    original = Application.get_env(:evo_git, :nix_enabled)
    Application.put_env(:evo_git, :nix_enabled, false)
    on_exit(fn -> Application.put_env(:evo_git, :nix_enabled, original) end)
    :ok
  end

  describe "sandbox_args/4" do
    test "generates correct systemd-run args" do
      cwd = "/my/project"
      args = EvoGit.sandbox_args(cwd, "bash", ["-c", "ls"])
      assert Enum.take(args, 3) == ["--user", "--slice=evogit", "--wait"]
      assert "-p" in args
      assert "PrivatePIDs=yes" in args
      assert "ProtectProc=invisible" in args
      assert "--slice=evogit" in args
      # Per-process resource limits are applied per-command; slice-level limits are separate
      refute "CPUWeight=30" in args
      refute "MemoryMax=16G" in args
      refute "TasksMax=8196" in args
      assert "LimitNOFILE=65536" in args
      assert "OOMScoreAdjust=1000" in args
      assert List.last(args) == "ls"
    end

    test "uses platform tmp paths in ReadWritePaths" do
      cwd = "/my/project"
      args = EvoGit.sandbox_args(cwd, "bash", ["-c", "ls"])

      # Check that tmp paths are present in ReadWritePaths
      tmp_paths = EvoGit.Platform.tmp_paths()
      for tmp_path <- tmp_paths do
        assert "ReadWritePaths=-#{tmp_path}" in args
      end
    end
  end

  describe "sandbox_run/4" do
    test "runs command directly when sandbox is disabled" do
      # Temporarily disable sandbox
      original = Application.get_env(:evo_git, :sandbox, :auto)
      Application.put_env(:evo_git, :sandbox, :disabled)

      {output, exit_code} = EvoGit.sandbox_run("/tmp", "echo", ["hello"])
      assert exit_code == 0
      assert output =~ "hello"

      # Restore original config
      Application.put_env(:evo_git, :sandbox, original)
    end
  end

  describe "EvoGit.Sandbox" do
    test "backend/0 returns a valid module" do
      assert EvoGit.Sandbox.backend() in [
               EvoGit.Sandbox.Linux,
               EvoGit.Sandbox.MacOS,
               EvoGit.Sandbox.None
             ]
    end

    test "capabilities/0 returns expected structure" do
      caps = EvoGit.Sandbox.capabilities()
      assert Map.has_key?(caps, :filesystem_isolation)
      assert Map.has_key?(caps, :resource_limits)
      assert Map.has_key?(caps, :backend)
      assert caps.backend in [:systemd_run, :sandbox_exec, :none]
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(EvoGit.Sandbox.enabled?())
    end

    test "ensure_initialized/0 returns :ok or error tuple" do
      result = EvoGit.Sandbox.ensure_initialized()
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "EvoGit.Platform" do
    test "os/0 returns a known platform" do
      assert EvoGit.Platform.os() in [:linux, :macos, :windows, :unknown]
    end

    test "shell/0 returns a string" do
      assert is_binary(EvoGit.Platform.shell())
    end

    test "shell_args/1 returns a list with the command" do
      args = EvoGit.Platform.shell_args("echo hello")
      assert is_list(args)
      assert "echo hello" in args
    end

    test "tmp_paths/0 returns a non-empty list of strings" do
      paths = EvoGit.Platform.tmp_paths()
      assert is_list(paths)
      assert length(paths) > 0
      for p <- paths, do: assert is_binary(p)
    end

    test "boolean helpers return booleans" do
      assert is_boolean(EvoGit.Platform.linux?())
      assert is_boolean(EvoGit.Platform.macos?())
      assert is_boolean(EvoGit.Platform.windows?())
      assert is_boolean(EvoGit.Platform.systemd_available?())
    end

    test "sandbox_backend/0 returns a valid backend atom" do
      assert EvoGit.Platform.sandbox_backend() in [:systemd_run, :sandbox_exec, :none]
    end

    test "sandbox_exec_available?/0 returns a boolean" do
      assert is_boolean(EvoGit.Platform.sandbox_exec_available?())
    end
  end
end
