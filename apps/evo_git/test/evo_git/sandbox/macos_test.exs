defmodule EvoGit.Sandbox.MacOSTest do
  # `async: false` because resolve_tmpdir/0 reads the global $TMPDIR env var.
  use ExUnit.Case, async: false

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
      extra = Path.join([System.tmp_dir!(), "evogit_macos_profile_#{System.unique_integer([:positive])}"])
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
  end
end
