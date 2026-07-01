defmodule EvoGit.Sandbox.LinuxTest do
  # `async: false` because several tests mutate the global `$TMPDIR` env var
  # via System.put_env/1, which is process-global and would race under async.
  use ExUnit.Case, async: false

  alias EvoGit.Sandbox.Linux
  alias EvoGit.Platform

  @tmp_prefix "--setenv=TMPDIR="

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
    # When nix is not enabled (the default — no config, no binary, or no flake),
    # the args should run the original executable directly without nix wrapping.

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
  end
end
