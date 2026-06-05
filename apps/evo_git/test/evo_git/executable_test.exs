defmodule EvoGit.ExecutableTest do
  use ExUnit.Case, async: true

  alias EvoGit.Executable

  describe "resolve/1" do
    test "returns the name unchanged when found on system PATH" do
      # git is installed in CI/dev environments
      assert Executable.resolve("git") == "git"
    end

    test "falls back to priv/vendor path for nonexistent binary" do
      result = Executable.resolve("nonexistent_binary_xyz")
      # Should NOT return the name unchanged (not on PATH)
      refute result == "nonexistent_binary_xyz"
      # Should return a path under priv/vendor
      assert result =~ "priv/vendor"
    end

    test "returns 'rg' when rg is on PATH, or a bundled path" do
      result = Executable.resolve("rg")
      # Either it's found on PATH and returned as "rg", or it falls back to bundled
      if result == "rg" do
        assert true
      else
        assert result =~ "priv/vendor"
      end
    end
  end
end
