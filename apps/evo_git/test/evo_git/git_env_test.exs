defmodule EvoGit.GitEnvTest do
  use ExUnit.Case, async: true

  alias EvoGit.GitEnv

  describe "git_env/0" do
    test "returns a map with LC_ALL=C and GIT_EDITOR set" do
      env = GitEnv.git_env()

      assert is_map(env)
      assert Map.get(env, "LC_ALL") == "C"
      assert is_binary(Map.get(env, "GIT_EDITOR"))
    end

    test "GIT_EDITOR resolves to a path ending in 'true'" do
      # Clear the memoized cache so we exercise real resolution regardless of
      # test ordering (other tests may have populated it).
      :persistent_term.erase({GitEnv, :true_path})

      env = GitEnv.git_env()

      assert String.ends_with?(env["GIT_EDITOR"], "true")
    end

    test "memoizes the resolved true path in :persistent_term" do
      :persistent_term.erase({GitEnv, :true_path})

      env = GitEnv.git_env()

      cached = :persistent_term.get({GitEnv, :true_path}, nil)
      assert is_binary(cached)
      assert env["GIT_EDITOR"] == cached
    end
  end

  describe "git_env_list/0" do
    test "returns a list of {String, String} tuples matching git_env/0" do
      env = GitEnv.git_env()
      list = GitEnv.git_env_list()

      assert is_list(list)
      assert Enum.all?(list, fn {k, v} -> is_binary(k) and is_binary(v) end)
      assert Enum.sort(list) == Enum.sort(Map.to_list(env))
    end

    test "includes the LC_ALL and GIT_EDITOR keys" do
      list = GitEnv.git_env_list()

      keys = Enum.map(list, fn {k, _v} -> k end)
      assert "LC_ALL" in keys
      assert "GIT_EDITOR" in keys
    end
  end

  describe "git_command?/1" do
    test "returns true for the bare name 'git'" do
      assert GitEnv.git_command?("git") == true
    end

    test "returns true for an absolute git path" do
      assert GitEnv.git_command?("/usr/bin/git") == true
    end

    test "returns true for a relative git path" do
      assert GitEnv.git_command?("./bin/git") == true
    end

    test "returns true for git.exe (Windows bundled binary)" do
      assert GitEnv.git_command?("git.exe") == true
    end

    test "returns true for a bundled Windows git path" do
      assert GitEnv.git_command?("/app/priv/vendor/windows-x64/mingit/cmd/git.exe") == true
    end

    test "returns false for non-git executables" do
      refute GitEnv.git_command?("rg")
      refute GitEnv.git_command?("/usr/bin/rg")
      refute GitEnv.git_command?("mix")
      refute GitEnv.git_command?("bash")
      refute GitEnv.git_command?("echo")
    end

    test "returns false for names that merely contain 'git' as a substring" do
      refute GitEnv.git_command?("github-cli")
      refute GitEnv.git_command?("gitstatus")
      refute GitEnv.git_command?("/usr/bin/gitstatus")
    end
  end

  describe "resolve_true_executable/0" do
    test "returns a binary string" do
      :persistent_term.erase({GitEnv, :true_path})

      resolved = GitEnv.resolve_true_executable()

      assert is_binary(resolved)
    end

    test "returns the same value when called twice (memoization)" do
      :persistent_term.erase({GitEnv, :true_path})

      first = GitEnv.resolve_true_executable()
      second = GitEnv.resolve_true_executable()

      assert first == second
    end
  end
end
