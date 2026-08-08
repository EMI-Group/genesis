defmodule EvoGit.Sandbox.LinuxTest do
  # `async: false` because several tests mutate the global `$TMPDIR` env var
  # via System.put_env/1, which is process-global and would race under async.
  use ExUnit.Case, async: false

  alias EvoGit.Sandbox.Linux
  alias EvoGit.Platform

  @tmp_prefix "--setenv=TMPDIR="

  # The default cache-dir write list (joined with the user home) that
  # `args/4` emits when the `[sandbox] write_paths` config key is unset.
  # Pinned here so a change to the lib defaults fails loudly.
  @default_cache_dirs [
    ".cache",
    ".local/share",
    ".local/state",
    ".cargo",
    ".rustup",
    ".mix",
    ".hex",
    ".npm",
    ".yarn",
    ".bun",
    ".m2",
    ".gradle",
    "go"
  ]

  defp build_args(cwd \\ System.tmp_dir!()) do
    Linux.args(cwd, "/usr/bin/env", [], nil)
  end

  defp tmpdir_value(args) do
    Enum.find_value(args, fn
      @tmp_prefix <> value -> value
      _ -> nil
    end)
  end

  defp save_tmpdir do
    original = System.get_env("TMPDIR")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("TMPDIR")
        value -> System.put_env("TMPDIR", value)
      end
    end)

    original
  end

  # Redirects the user config dir ($XDG_CONFIG_HOME) to a fresh unique temp
  # dir. A fresh path per test avoids `Config.resolve/1`'s per-path
  # mtime+size-validated `:persistent_term` cache staleness.
  defp redirect_xdg_config_home do
    original = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(
        System.tmp_dir!(),
        "evogit-linux-test-xdg-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      case original do
        nil -> System.delete_env("XDG_CONFIG_HOME")
        value -> System.put_env("XDG_CONFIG_HOME", value)
      end

      File.rm_rf!(tmp_xdg)
    end)

    tmp_xdg
  end

  # Writes a config.toml with a `[sandbox] write_paths = <paths>` key into the
  # redirected XDG config dir. Call this inside the test (after the describe
  # setup redirected XDG_CONFIG_HOME).
  defp write_config(paths) do
    path = Path.join([System.get_env("XDG_CONFIG_HOME"), "genesis", "config.toml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[sandbox]\nwrite_paths = #{inspect(paths)}\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cache_write_arg(dir) do
    "ReadWritePaths=-#{Path.join(System.user_home!(), dir)}"
  end

  setup do
    original = Application.get_env(:evo_git, :nix_enabled)
    Application.put_env(:evo_git, :nix_enabled, false)
    on_exit(fn -> Application.put_env(:evo_git, :nix_enabled, original) end)
    :ok
  end

  describe "args/4 — TMPDIR forwarding (TMPDIR unset)" do
    test "always includes a --setenv=TMPDIR=... entry" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      args = build_args()

      assert Enum.any?(args, &String.starts_with?(&1, @tmp_prefix)),
             "expected a --setenv=TMPDIR=... entry in args, got: #{inspect(args)}"
    end

    test "falls back to hd(Platform.tmp_paths()) when TMPDIR is unset" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      assert tmpdir_value(build_args()) == hd(Platform.tmp_paths())
    end
  end

  describe "args/4 — TMPDIR forwarding (TMPDIR set)" do
    test "keeps a host TMPDIR that exists and is under /tmp" do
      save_tmpdir()

      # Create a real temp dir under /tmp (System.tmp_dir!() returns /tmp on Linux).
      sub =
        Path.join(System.tmp_dir!(), "evogit_linux_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(sub)
      on_exit(fn -> File.rm_rf!(sub) end)

      System.put_env("TMPDIR", sub)

      assert tmpdir_value(build_args()) == sub
    end

    test "falls back to default when TMPDIR points to a non-existent path not under allowed roots" do
      save_tmpdir()

      # A non-existent path not under /tmp or /var/tmp.
      System.put_env(
        "TMPDIR",
        Path.join(
          System.user_home!(),
          "evogit_does_not_exist_#{System.unique_integer([:positive])}"
        )
      )

      assert tmpdir_value(build_args()) == hd(Platform.tmp_paths())
    end

    test "falls back to default when TMPDIR is a relative/bogus path" do
      save_tmpdir()

      System.put_env("TMPDIR", "relative/bogus/tmp")

      # Path.expand resolves relative to cwd; it won't be under /tmp or /var/tmp,
      # and almost certainly won't exist → fallback.
      assert tmpdir_value(build_args()) == hd(Platform.tmp_paths())
    end

    test "guards against false prefix matches like /tmpfoo matching /tmp" do
      save_tmpdir()

      # /tmpfoo would be a false-positive prefix match for /tmp without the
      # trailing-slash guard. It almost certainly doesn't exist either, but this
      # test documents the intent. Create it so only the prefix-guard matters.
      maybe = "/tmpfoo_evogit_#{System.unique_integer([:positive])}"
      System.put_env("TMPDIR", maybe)

      try do
        File.mkdir_p!(maybe)
        on_exit(fn -> File.rm_rf!(maybe) end)
        # Even though it exists, it is NOT under /tmp (no trailing-slash match),
        # so it must fall back.
        assert tmpdir_value(build_args()) == hd(Platform.tmp_paths())
      rescue
        # If we can't create it (permissions), the path doesn't exist → still fallback.
        _ ->
          assert tmpdir_value(build_args()) == hd(Platform.tmp_paths())
      end
    end
  end

  describe "args/4 — ReadWritePaths unchanged" do
    test "still contains ReadWritePaths=-/tmp and ReadWritePaths=-/var/tmp" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      args = build_args()

      assert "ReadWritePaths=-/tmp" in args
      assert "ReadWritePaths=-/var/tmp" in args
    end
  end

  describe "args/4 — PATH and HOME still forwarded" do
    test "includes --setenv=PATH and --setenv=HOME entries" do
      args = build_args()

      assert Enum.any?(args, &String.starts_with?(&1, "--setenv=PATH="))
      assert Enum.any?(args, &String.starts_with?(&1, "--setenv=HOME="))
    end
  end

  describe "args/4 — Nix integration (nix disabled, default)" do
    # When nix is not active (the default — no config, no binary, or no flake,
    # or dev-env build failed), the args should run the original executable
    # directly without nix wrapping.

    test "does not contain nix develop or --command when nix is disabled" do
      args = build_args()

      refute "develop" in args,
             "expected no 'develop' arg when nix is disabled, got: #{inspect(args)}"

      refute "--command" in args,
             "expected no '--command' arg when nix is disabled, got: #{inspect(args)}"
    end

    test "still contains the original executable when nix is disabled" do
      args = build_args()

      assert "/usr/bin/env" in args,
             "expected original executable in args when nix is disabled, got: #{inspect(args)}"
    end

    # Note: the nix-ENABLEED path in args/4 can't be tested here without a
    # real nix install, because active?/0 gates on enabled?/0 (config + binary
    # + flake). The wrap_command/2 output itself is tested in nix_test.exs.
  end

  describe "args/4 — GIT_EDITOR injection for git commands" do
    test "includes --setenv=LC_ALL=C for a git executable" do
      args = Linux.args(System.tmp_dir!(), "/usr/bin/git", ["status"], nil)

      assert Enum.any?(args, &(&1 == "--setenv=LC_ALL=C")),
             "expected --setenv=LC_ALL=C for git, got: #{inspect(args)}"
    end

    test "includes --setenv=GIT_EDITOR=<true path> for a git executable" do
      args = Linux.args(System.tmp_dir!(), "/usr/bin/git", ["status"], nil)

      assert Enum.any?(args, &String.starts_with?(&1, "--setenv=GIT_EDITOR=")),
             "expected a --setenv=GIT_EDITOR=... entry for git, got: #{inspect(args)}"
    end

    test "GIT_EDITOR value ends in 'true'" do
      args = Linux.args(System.tmp_dir!(), "/usr/bin/git", ["status"], nil)

      editor_arg = Enum.find(args, &String.starts_with?(&1, "--setenv=GIT_EDITOR="))
      assert editor_arg != nil

      value = String.replace_prefix(editor_arg, "--setenv=GIT_EDITOR=", "")
      assert String.ends_with?(value, "true")
    end

    test "injects git env for a bare 'git' executable name" do
      args = Linux.args(System.tmp_dir!(), "git", ["merge", "--continue"], nil)

      assert Enum.any?(args, &(&1 == "--setenv=LC_ALL=C"))
      assert Enum.any?(args, &String.starts_with?(&1, "--setenv=GIT_EDITOR="))
    end

    test "does NOT inject git env for a non-git executable (rg)" do
      args = Linux.args(System.tmp_dir!(), "/usr/bin/rg", ["pattern"], nil)

      refute Enum.any?(args, &(&1 == "--setenv=LC_ALL=C")),
             "did not expect --setenv=LC_ALL=C for rg, got: #{inspect(args)}"

      refute Enum.any?(args, &String.starts_with?(&1, "--setenv=GIT_EDITOR=")),
             "did not expect --setenv=GIT_EDITOR for rg, got: #{inspect(args)}"
    end

    test "does NOT inject git env for /usr/bin/env" do
      args = Linux.args(System.tmp_dir!(), "/usr/bin/env", [], nil)

      refute Enum.any?(args, &(&1 == "--setenv=LC_ALL=C"))
      refute Enum.any?(args, &String.starts_with?(&1, "--setenv=GIT_EDITOR="))
    end

    test "still forwards PATH and HOME alongside git env for git commands" do
      args = Linux.args(System.tmp_dir!(), "/usr/bin/git", ["status"], nil)

      assert Enum.any?(args, &String.starts_with?(&1, "--setenv=PATH="))
      assert Enum.any?(args, &String.starts_with?(&1, "--setenv=HOME="))
      assert Enum.any?(args, &(&1 == "--setenv=LC_ALL=C"))
    end
  end

  describe "args/4 — bash wrapping for stdin redirection (run/4 pattern)" do
    test "wraps the command in bash -c when called via the run/4 pattern" do
      # When run/4 wraps the command in bash with stdin redirect, it calls
      # args/4 with "bash" as the executable and ["-c", wrapped_cmd] as args.
      # Verify args/4 passes these through correctly.
      inner_cmd = "'rg' 'pattern'"
      wrapped_cmd = inner_cmd <> " < /dev/null"
      args = Linux.args(System.tmp_dir!(), "bash", ["-c", wrapped_cmd], nil)

      assert "bash" in args, "expected 'bash' as the executable in args"
      assert "-c" in args, "expected '-c' flag in args"

      # The wrapped command string should be present and end with the stdin redirect
      wrapped_arg = Enum.find(args, &String.ends_with?(&1, " < /dev/null"))
      assert wrapped_arg != nil, "expected a wrapped command ending in ' < /dev/null'"
    end

    test "does not double-wrap bash in nix when nix is disabled" do
      inner_cmd = "'git' 'status'"
      wrapped_cmd = inner_cmd <> " < /dev/null"
      args = Linux.args(System.tmp_dir!(), "bash", ["-c", wrapped_cmd], nil)

      # With nix disabled, the executable should be plain "bash"
      assert "bash" in args
      # The -c and wrapped command should be passed as-is
      assert "-c" in args
    end
  end

  describe "args/4 — write_paths default cache dirs (unset)" do
    # XDG redirected to an empty dir, NO config.toml written: `write_paths`
    # is unset, so the default cache-dir write list applies. Deterministic
    # because the real user config is isolated away.
    setup do
      redirect_xdg_config_home()
      :ok
    end

    test "includes the default cache dirs as ReadWritePaths when write_paths is unset" do
      args = build_args()

      for dir <- @default_cache_dirs do
        assert cache_write_arg(dir) in args,
               "expected #{cache_write_arg(dir)} in args, got: #{inspect(args)}"
      end
    end
  end

  describe "args/4 — write_paths configured" do
    setup do
      redirect_xdg_config_home()
      :ok
    end

    @custom_write_paths ["/custom/writable", "/another/path"]

    test "includes the configured write paths as ReadWritePaths" do
      write_config(@custom_write_paths)
      args = build_args()

      assert "ReadWritePaths=-/custom/writable" in args
      assert "ReadWritePaths=-/another/path" in args
    end

    test "replaces the default cache-dir write paths when write_paths is set" do
      write_config(@custom_write_paths)
      args = build_args()

      for dir <- @default_cache_dirs do
        refute cache_write_arg(dir) in args,
               "did not expect default cache dir #{cache_write_arg(dir)} in args, got: #{inspect(args)}"
      end
    end

    test "still includes structural paths (cwd, tmp) alongside configured write paths" do
      write_config(@custom_write_paths)

      cwd =
        Path.join(
          System.tmp_dir!(),
          "evogit_linux_test_cwd_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)

      args = build_args(cwd)

      assert "ReadWritePaths=-/tmp" in args
      assert "ReadWritePaths=-/var/tmp" in args
      assert "ReadWritePaths=-#{cwd}" in args
    end
  end

  describe "args/4 — write_paths explicitly empty" do
    setup do
      redirect_xdg_config_home()
      :ok
    end

    test "an empty write_paths list removes all default cache-dir entries" do
      write_config([])
      args = build_args()

      for dir <- @default_cache_dirs do
        refute cache_write_arg(dir) in args,
               "did not expect default cache dir #{cache_write_arg(dir)} in args, got: #{inspect(args)}"
      end
    end

    test "still includes structural tmp paths with write_paths = []" do
      write_config([])
      args = build_args()

      assert "ReadWritePaths=-/tmp" in args
      assert "ReadWritePaths=-/var/tmp" in args
    end
  end

  describe "args/4 — write_paths ~ expansion" do
    setup do
      redirect_xdg_config_home()
      :ok
    end

    test "expands a ~-prefixed write path to the user home" do
      write_config(["~/mycache"])
      args = build_args()

      assert cache_write_arg("mycache") in args
    end
  end

  describe "inject_unit/2" do
    test "inserts --unit= immediately after --user" do
      args = ["--user", "--slice=evogit", "--wait", "--pipe"]
      result = Linux.inject_unit(args, "evogit-run-42")

      assert result == ["--user", "--unit=evogit-run-42", "--slice=evogit", "--wait", "--pipe"]
    end

    test "preserves all other arguments in order" do
      args = ["--user", "--collect", "-q", "-p", "WorkingDirectory=/tmp"]
      result = Linux.inject_unit(args, "my-unit")

      assert List.first(result) == "--user"
      assert Enum.at(result, 1) == "--unit=my-unit"
      assert Enum.drop(result, 2) == ["--collect", "-q", "-p", "WorkingDirectory=/tmp"]
    end

    test "handles a minimal args list" do
      assert Linux.inject_unit(["--user", "true"], "test-unit") ==
               ["--user", "--unit=test-unit", "true"]
    end
  end
end
