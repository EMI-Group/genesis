defmodule EvoGit.ExecutableTest do
  @moduledoc """
  Tests for `EvoGit.Executable`, which resolves executable paths with a
  system-first, bundled-fallback strategy.

  The public `resolve/1` contract is exercised directly. The bundled-fallback
  logic is exercised through the pure `candidates/3` and `bundled_path/3`
  helpers, which take an explicit `vendor_dir` and `os_type` so both the
  Windows (MinGit) and Unix vendor layouts are testable on Linux CI.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Executable

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_executable_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, vendor_dir: dir}
  end

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

    test "returns the original name when neither on PATH nor bundled" do
      # The name is returned unchanged (never a fabricated vendor path) so that
      # PATH search / System.find_executable / known-location fallbacks apply.
      name = "evogit_nonexistent_binary_xyz"

      assert System.find_executable(name) == nil
      assert Executable.resolve(name) == name
    end

    test "never returns a non-existent absolute path" do
      # The invariant that used to break: a fabricated absolute vendor path
      # defeats every downstream resolution mechanism. An absolute result must
      # always be an existing regular file.
      for name <- [
            "evogit_nonexistent_binary_a",
            "evogit_nonexistent_binary_b",
            "powershell_that_is_not_there",
            "weird/name"
          ] do
        result = Executable.resolve(name)
        assert result == name or File.regular?(result)
      end
    end

    test "returns 'rg' unchanged, or an existing bundled path" do
      # rg is the one binary that MAY be bundled; either the bare name comes
      # back (found on PATH or nothing bundled) or a real file is returned.
      result = Executable.resolve("rg")

      assert result == "rg" or File.regular?(result)
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
  end

  describe "candidates/3" do
    test "uses the MinGit layout for git on Windows", %{vendor_dir: dir} do
      assert Executable.candidates("git", dir, {:win32, :nt}) ==
               [Path.join([dir, "mingit", "cmd", "git.exe"])]
    end

    test "uses <name>.exe for other executables on Windows", %{vendor_dir: dir} do
      assert Executable.candidates("powershell", dir, {:win32, :nt}) ==
               [Path.join(dir, "powershell.exe")]
    end

    test "uses the bare name on non-Windows platforms", %{vendor_dir: dir} do
      assert Executable.candidates("rg", dir, {:unix, :linux}) == [Path.join(dir, "rg")]
      assert Executable.candidates("git", dir, {:unix, :darwin}) == [Path.join(dir, "git")]
    end

    test "always yields absolute candidate paths inside the vendor dir", %{vendor_dir: dir} do
      for {name, os} <- [{"git", {:win32, :nt}}, {"rg", {:win32, :nt}}, {"rg", {:unix, :linux}}] do
        [candidate] = Executable.candidates(name, dir, os)
        assert Path.type(candidate) == :absolute
        assert String.starts_with?(candidate, dir)
      end
    end
  end

  describe "bundled_path/3" do
    test "returns the bundled absolute path when the file exists", %{vendor_dir: dir} do
      bundled = Path.join(dir, "mybin")
      File.write!(bundled, "")

      assert Executable.bundled_path("mybin", dir, {:unix, :linux}) == bundled
    end

    test "returns nil when the bundled file does not exist", %{vendor_dir: dir} do
      assert Executable.bundled_path("missing_binary", dir, {:unix, :linux}) == nil
    end

    test "returns nil when the candidate is a directory, not a regular file", %{vendor_dir: dir} do
      File.mkdir_p!(Path.join(dir, "somedir"))

      assert Executable.bundled_path("somedir", dir, {:unix, :linux}) == nil
    end

    test "resolves the Windows MinGit git.exe layout when present", %{vendor_dir: dir} do
      git = Path.join([dir, "mingit", "cmd", "git.exe"])
      File.mkdir_p!(Path.dirname(git))
      File.write!(git, "")

      assert Executable.bundled_path("git", dir, {:win32, :nt}) == git
    end

    test "returns nil for git on Windows when MinGit is not bundled", %{vendor_dir: dir} do
      assert Executable.bundled_path("git", dir, {:win32, :nt}) == nil
    end

    test "does not fall back to a bare <name>.exe candidate on Windows for git", %{
      vendor_dir: dir
    } do
      # A `<vendor>/git.exe` (no mingit/ prefix) is not the bundled git layout.
      File.write!(Path.join(dir, "git.exe"), "")

      assert Executable.bundled_path("git", dir, {:win32, :nt}) == nil
    end

    test "returns the <name>.exe candidate on Windows when present", %{vendor_dir: dir} do
      rg = Path.join(dir, "rg.exe")
      File.write!(rg, "")

      assert Executable.bundled_path("rg", dir, {:win32, :nt}) == rg
    end
  end
end
