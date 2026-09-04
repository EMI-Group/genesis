defmodule EvoGit.ExecutableTest do
  @moduledoc """
  Tests for `EvoGit.Executable`, which resolves executable paths with a
  system-first, bundled-fallback strategy.

  The private helpers (`bundled_path/1`, `resolve_vendor_dir/0`,
  `vendor_platform/0`, `arch_string/0`) are exercised indirectly through the
  public `resolve/1` function.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Executable

  describe "resolve/1" do
    test "returns the name unchanged when found on system PATH" do
      # git is installed in all dev/CI environments
      assert Executable.resolve("git") == "git"
    end

    test "returns the bare name for any executable present on PATH" do
      # The contract: a found executable returns its name unchanged so that
      # System.cmd (which searches PATH) can locate it. Verify with `git`,
      # which is guaranteed available in the test environment.
      assert System.find_executable("git") != nil
      assert Executable.resolve("git") == "git"
    end

    test "returns 'rg' when rg is on PATH, or a bundled fallback path" do
      result = Executable.resolve("rg")

      if result == "rg" do
        assert System.find_executable("rg") != nil
      else
        # Not on PATH → must be the bundled path under priv/vendor
        assert result =~ "vendor"
        assert result =~ "rg"
      end
    end

    test "falls back to priv/vendor path for nonexistent binary" do
      result = Executable.resolve("nonexistent_binary_xyz")

      # Should NOT return the name unchanged (not on PATH)
      refute result == "nonexistent_binary_xyz"
      # Should return a path under priv/vendor
      assert result =~ "priv/vendor"
    end

    test "the bundled fallback path contains the binary name" do
      result = Executable.resolve("definitely_not_on_path_xyz")

      assert is_binary(result)
      assert result =~ "definitely_not_on_path_xyz"
    end

    test "the bundled path ends with the binary name (or .exe on Windows)" do
      result = Executable.resolve("no_such_binary_abc")
      last_segment = Path.basename(result)

      case :os.type() do
        {:win32, _} -> assert last_segment == "no_such_binary_abc.exe"
        _ -> assert last_segment == "no_such_binary_abc"
      end
    end

    test "the bundled path is an absolute path" do
      result = Executable.resolve("no_such_binary_abs")
      # resolve_vendor_dir builds via Application.app_dir / :code.priv_dir,
      # both of which yield absolute paths.
      assert Path.type(result) == :absolute
    end

    test "always returns a binary string, never raises" do
      # Should always return a path string, never raise, for any input.
      for name <- ["definitely_not_on_path_xyz", "git", "", "rg", "weird/name"] do
        assert is_binary(Executable.resolve(name))
      end
    end

    test "is deterministic: same input always returns the same output" do
      nonexistent = "deterministic_nonexistent_xyz"
      first = Executable.resolve(nonexistent)
      second = Executable.resolve(nonexistent)
      assert first == second
    end

    test "different nonexistent binaries share the same vendor directory" do
      # The vendor dir is platform-specific, not executable-specific; only the
      # terminal segment should differ between two bundled paths.
      path_a = Executable.resolve("no_such_binary_aaa")
      path_b = Executable.resolve("no_such_binary_bbb")

      # Same parent directory (the vendor dir)…
      assert Path.dirname(path_a) == Path.dirname(path_b)
      # …but different terminal segments.
      refute path_a == path_b
    end

    test "the bundled path encodes the current platform" do
      # vendor_platform/1 produces macos-<arch> / linux-<arch> / windows-x64.
      # We can't assert the exact segment (arch is host-dependent) but the
      # platform family must appear.
      result = Executable.resolve("no_such_binary_platform")

      case :os.type() do
        {:unix, :darwin} -> assert result =~ "macos"
        {:win32, _} -> assert result =~ "windows"
        {:unix, _} -> assert result =~ "linux"
      end
    end

    test "the bundled path includes a recognized architecture segment" do
      result = Executable.resolve("no_such_binary_arch")

      # arch_string/0 classifies into arm64, x86_64, or unknown (unix/macos),
      # or hardcodes x64 on Windows.
      arch_segment =
        case :os.type() do
          {:win32, _} ->
            "x64"

          _ ->
            sys_arch = List.to_string(:erlang.system_info(:system_architecture))

            cond do
              String.starts_with?(sys_arch, "aarch64") or String.starts_with?(sys_arch, "arm64") ->
                "arm64"

              String.starts_with?(sys_arch, "x86_64") or String.starts_with?(sys_arch, "amd64") ->
                "x86_64"

              true ->
                "unknown"
            end
        end

      assert result =~ arch_segment
    end
  end
end
