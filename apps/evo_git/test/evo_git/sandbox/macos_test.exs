defmodule EvoGit.Sandbox.MacOSTest do
  # `async: false` because resolve_tmpdir/0 reads the global $TMPDIR env var.
  use ExUnit.Case, async: false

  alias EvoGit.{Platform, Sandbox}
  alias EvoGit.Sandbox.MacOS

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

  setup do
    # Isolate from the user's ~/.config/genesis/config.toml so the sandbox
    # mode resolves to the built-in default (:auto) on every host — this
    # makes MacOS.enabled?/0 platform-determined (macOS + sandbox-exec
    # present) instead of user-config-determined.
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-macos-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    original = Application.get_env(:evo_git, :nix_enabled)
    Application.put_env(:evo_git, :nix_enabled, false)
    on_exit(fn -> Application.put_env(:evo_git, :nix_enabled, original) end)
    :ok
  end

  describe "generate_profile/2" do
    test "grants file-write to the default tmp paths" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ ~s{(allow file-write* (subpath "/tmp"))}
      assert profile =~ ~s{(allow file-write* (subpath "/var/tmp"))}
    end

    test "grants file-write to cwd" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ ~s{(allow file-write* (subpath "/some/cwd"))}
    end

    test "always grants write to /tmp and /var/tmp regardless of host TMPDIR" do
      save_tmpdir()

      # Simulate a macOS-style per-user TMPDIR that is NOT under /tmp or /var/tmp.
      # Since TMPDIR is now overridden at runtime via the :env option (not via
      # profile rules), the profile should always contain the /tmp and /var/tmp
      # write rules regardless of the host TMPDIR state.
      extra =
        Path.join([
          System.tmp_dir!(),
          "evogit_macos_profile_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(extra)
      on_exit(fn -> File.rm_rf!(extra) end)
      System.put_env("TMPDIR", extra)

      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ ~s{(allow file-write* (subpath "/tmp"))}
      assert profile =~ ~s{(allow file-write* (subpath "/var/tmp"))}
    end

    test "always contains the /tmp write rule" do
      save_tmpdir()

      # When TMPDIR is under /tmp, the /tmp parent rule always covers it.
      sub = Path.join(System.tmp_dir!(), "evogit_covered_#{System.unique_integer([:positive])}")
      File.mkdir_p!(sub)
      on_exit(fn -> File.rm_rf!(sub) end)
      System.put_env("TMPDIR", sub)

      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ ~s{(allow file-write* (subpath "/tmp"))}
    end

    test "does not include nix store paths when nix is not enabled" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      refute profile =~ "/nix/store"
      refute profile =~ "/nix/var"
    end

    test "still generates a valid profile without nix rules" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ "(version 1)"
      assert profile =~ "(deny default)"
      assert profile =~ ~s{(allow file-write* (subpath "/some/cwd"))}
    end

    test "is deny-by-default and denies reads of sensitive home dirs" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ "(deny default)"

      for dir <- [
            ".ssh",
            ".gnupg",
            ".aws",
            ".kube",
            ".git-credentials",
            ".netrc",
            ".password-store",
            ".docker"
          ] do
        path = Path.join(System.user_home!(), dir)

        assert profile =~ ~s{(deny file-read* (subpath "#{path}"))},
               "expected a deny-read rule for #{dir}"
      end
    end

    test "grants read-write to the repo worktree, .git, and tmp paths" do
      profile = MacOS.generate_profile("/repo/cwd", "/repo")

      assert profile =~ ~s{(allow file-read* (subpath "/repo/cwd"))}
      assert profile =~ ~s{(allow file-write* (subpath "/repo/cwd"))}
      assert profile =~ ~s{(allow file-read* (subpath "/repo/.git"))}
      assert profile =~ ~s{(allow file-write* (subpath "/repo/.git"))}

      for path <- ["/tmp", "/var/tmp"] do
        assert profile =~ ~s{(allow file-read* (subpath "#{path}"))}
        assert profile =~ ~s{(allow file-write* (subpath "#{path}"))}
      end
    end

    test "enforces the process-count limit exactly once" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ "(limit number 200)"
      assert length(Regex.scan(~r/\(limit number 200\)/, profile)) == 1
    end
  end

  describe "fail-safe process-limit handling" do
    # The rejection cache is VM-global persistent_term — start each test from
    # a clean slate and always clean up so no state leaks between tests.
    setup do
      :persistent_term.erase({EvoGit.Sandbox.MacOS, :process_limit_rejected})
      on_exit(fn -> :persistent_term.erase({EvoGit.Sandbox.MacOS, :process_limit_rejected}) end)
      :ok
    end

    test "the rejection cache defaults to false" do
      assert :persistent_term.get({EvoGit.Sandbox.MacOS, :process_limit_rejected}, false) == false
    end

    test "a cached rejection never breaks profile generation or execution" do
      :persistent_term.put({EvoGit.Sandbox.MacOS, :process_limit_rejected}, true)

      # The flag only affects run/4 (it strips the limit before execution) —
      # generate_profile/2 ignores it and still emits the full profile.
      profile = MacOS.generate_profile("/some/cwd", nil)
      assert profile =~ "(limit number 200)"

      # run/4 in test env: on Linux CI enabled?() is false (disabled bash
      # path); on a macOS host the cached rejection makes run/4 use the
      # stripped profile directly. Either way the command must succeed.
      assert {_output, 0} = MacOS.run(System.tmp_dir!(), "echo", ["hi"])
    end

    test "runs a real command through sandbox-exec when available (macOS only)" do
      # Guarded: on Linux CI (and any host without sandbox-exec) this test
      # passes without executing — the enabled path is genuinely exercised
      # only on macOS dev machines.
      if Platform.macos?() and System.find_executable("sandbox-exec") do
        # Erase any cached decision so the FULL profile (with the process
        # limit) is used. If this macOS rejects `(limit ...)`, the once-retry
        # with the stripped profile fires and caches the decision.
        :persistent_term.erase({EvoGit.Sandbox.MacOS, :process_limit_rejected})

        assert {_output, 0} = MacOS.run(System.tmp_dir!(), "echo", ["hi"])
      end
    end
  end

  describe "resolve_tmpdir/0" do
    test "returns the first platform tmp path when TMPDIR is unset" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      assert Sandbox.resolve_tmpdir() == List.first(Platform.tmp_paths())
    end

    test "keeps TMPDIR when it points to an existing dir under a tmp path" do
      save_tmpdir()
      sub = Path.join("/tmp", "evogit_tmpdir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(sub)
      on_exit(fn -> File.rm_rf!(sub) end)
      System.put_env("TMPDIR", sub)

      assert Sandbox.resolve_tmpdir() == sub
    end

    test "falls back to the first tmp path when TMPDIR points to a missing dir" do
      save_tmpdir()
      missing = Path.join("/tmp", "evogit_missing_#{System.unique_integer([:positive])}")
      File.rm_rf!(missing)
      System.put_env("TMPDIR", missing)

      assert Sandbox.resolve_tmpdir() == List.first(Platform.tmp_paths())
    end

    test "falls back when TMPDIR points outside every tmp path" do
      save_tmpdir()

      # The repo worktree (File.cwd!()) is not under /tmp or /var/tmp on CI
      # or dev machines.
      System.put_env("TMPDIR", File.cwd!())

      assert Sandbox.resolve_tmpdir() == List.first(Platform.tmp_paths())
    end
  end
end
