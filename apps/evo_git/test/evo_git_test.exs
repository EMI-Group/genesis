defmodule EvoGitTest do
  @moduledoc """
  Top-level tests for `EvoGit` (sandbox args/run), `EvoGit.Sandbox` and
  `EvoGit.Platform`.

  `async: true` — each test's config dir is isolated PER PROCESS through the
  `EvoGit.TestSupport.ConfigDir` seam (`EvoGit.Platform.config_dir/1`), so the
  user's real `~/.config/genesis/config.toml` is never read. No process-wide env
  var or app-env key is mutated: nix integration is pinned OFF once suite-wide by
  `test/test_helper.exs`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.TestSupport.ConfigDir

  setup do
    # Isolate from the user's ~/.config/genesis/config.toml (a per-process
    # config-dir override, never a process-wide env var) so tests use only
    # built-in defaults.
    ConfigDir.isolate!("evogit-test")
    :ok
  end

  describe "sandbox_args/4" do
    test "generates correct systemd-run args" do
      cwd = "/my/project"
      args = EvoGit.sandbox_args(cwd, "bash", ["-c", "ls"])
      assert Enum.take(args, 3) == ["--user", "--slice=evogit", "--wait"]
      assert "-p" in args
      refute "PrivatePIDs=yes" in args
      refute "ProtectProc=invisible" in args
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
    test "runs command when sandbox is disabled (test env bypasses systemd-run)" do
      # In test env, EvoGit.Sandbox.Linux.enabled?/0 returns false (via the
      # compile-time @mix_env gate), so sandbox_run falls through to the
      # disabled path which wraps commands in bash -c. This ensures tests
      # never depend on a live systemd user session bus.
      {output, exit_code} = EvoGit.sandbox_run("/tmp", "echo", ["hello"])
      assert exit_code == 0
      assert output =~ "hello"
    end
  end

  describe "EvoGit.Sandbox" do
    test "backend/0 returns a valid module" do
      assert EvoGit.Sandbox.backend() in [
               EvoGit.Sandbox.Linux,
               EvoGit.Sandbox.Bwrap,
               EvoGit.Sandbox.MacOS,
               EvoGit.Sandbox.None
             ]
    end

    test "capabilities/0 returns expected structure" do
      caps = EvoGit.Sandbox.capabilities()
      assert Map.has_key?(caps, :filesystem_isolation)
      assert Map.has_key?(caps, :resource_limits)
      assert Map.has_key?(caps, :backend)
      assert caps.backend in [:systemd_run, :bwrap, :sandbox_exec, :none]
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

      case EvoGit.Platform.os() do
        :windows -> assert args == EvoGit.Powershell.invoke_args("echo hello")
        _ -> assert args == ["-c", "echo hello"]
      end
    end

    test "tmp_paths/0 returns a non-empty list of strings" do
      paths = EvoGit.Platform.tmp_paths()
      assert is_list(paths)
      assert length(paths) > 0
      for p <- paths, do: assert(is_binary(p))
    end

    test "boolean helpers return booleans" do
      assert is_boolean(EvoGit.Platform.linux?())
      assert is_boolean(EvoGit.Platform.macos?())
      assert is_boolean(EvoGit.Platform.windows?())
      assert is_boolean(EvoGit.Platform.systemd_available?())
      assert is_boolean(EvoGit.Platform.bwrap_available?())
    end

    test "sandbox_backend/0 returns a valid backend atom" do
      assert EvoGit.Platform.sandbox_backend() in [:systemd_run, :bwrap, :sandbox_exec, :none]
    end

    test "sandbox_exec_available?/0 returns a boolean" do
      assert is_boolean(EvoGit.Platform.sandbox_exec_available?())
    end

    test "shell/0 honors the [tools] shell config override" do
      # Each test gets a fresh config dir (unique path), so the config.toml path
      # differs per test — EvoGit.Config's mtime+size file cache can never
      # collide across tests. The dir is removed by the seam's on_exit.
      write_config_toml("shell = \"sh\"")

      assert EvoGit.Platform.shell() == "sh"
      assert EvoGit.Platform.shell_args("echo hi") == ["-c", "echo hi"]
    end

    test "shell_args/1 uses PowerShell invocation args when the configured shell is pwsh" do
      write_config_toml("shell = \"pwsh\"")

      assert EvoGit.Platform.shell() == "pwsh"
      assert EvoGit.Platform.shell_args("echo hi") == EvoGit.Powershell.invoke_args("echo hi")
    end

    test "shell/0 falls back to the platform default for an empty config value" do
      write_config_toml("shell = \"\"")

      expected = if EvoGit.Platform.os() == :windows, do: "powershell", else: "bash"

      args =
        if EvoGit.Platform.os() == :windows do
          EvoGit.Powershell.invoke_args("echo hi")
        else
          ["-c", "echo hi"]
        end

      assert EvoGit.Platform.shell() == expected
      assert EvoGit.Platform.shell_args("echo hi") == args
    end
  end

  # Writes a config.toml into this test's isolated config dir.
  defp write_config_toml(tools_body) do
    File.mkdir_p!(Config.config_dir())
    File.write!(Config.config_path(), "[tools]\n#{tools_body}\n")
  end
end
