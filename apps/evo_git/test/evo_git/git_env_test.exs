defmodule EvoGit.GitEnvTest do
  use ExUnit.Case, async: false

  # async: false because several tests manipulate global VM state via
  # System.put_env (GIT_AUTHOR_* / GIT_CONFIG_*), which is visible to all
  # processes. Serializing this file avoids cross-test interference.
  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.GitEnv

  # The four identity env vars injected into every git invocation.
  @identity_keys [
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL"
  ]

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

    test "git_env/1 with nil repo path matches git_env/0" do
      assert GitEnv.git_env(nil) == GitEnv.git_env()
    end
  end

  describe "git_env/1 — commit identity resolution" do
    test "uses the repo-configured identity when no identity env vars are set", %{
      tmp_dir: tmp_dir
    } do
      git!(tmp_dir, ["init"])
      git!(tmp_dir, ["config", "user.name", "Real User"])
      git!(tmp_dir, ["config", "user.email", "real@example.com"])

      env = GitEnv.git_env(tmp_dir)

      assert env["GIT_AUTHOR_NAME"] == "Real User"
      assert env["GIT_AUTHOR_EMAIL"] == "real@example.com"
      assert env["GIT_COMMITTER_NAME"] == "Real User"
      assert env["GIT_COMMITTER_EMAIL"] == "real@example.com"
    end

    test "a git commit is authored by the repo-configured identity", %{tmp_dir: tmp_dir} do
      git!(tmp_dir, ["init"])
      git!(tmp_dir, ["config", "user.name", "Real User"])
      git!(tmp_dir, ["config", "user.email", "real@example.com"])

      File.write!(Path.join(tmp_dir, "hello.txt"), "hello\n")
      assert {:ok, _} = Git.add(tmp_dir, "hello.txt")
      assert {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      assert {:ok, identity} = Git.run(["log", "-1", "--format=%an|%ae|%cn|%ce"], tmp_dir)
      assert identity == "Real User|real@example.com|Real User|real@example.com"
    end

    test "identity is resolved per repo (repo-local config differs)", %{tmp_dir: tmp_dir} do
      repo_a = Path.join(tmp_dir, "repo_a")
      repo_b = Path.join(tmp_dir, "repo_b")
      File.mkdir_p!(repo_a)
      File.mkdir_p!(repo_b)

      git!(repo_a, ["init"])
      git!(repo_b, ["init"])
      git!(repo_a, ["config", "user.name", "Repo A User"])
      git!(repo_a, ["config", "user.email", "a@example.com"])
      git!(repo_b, ["config", "user.name", "Repo B User"])
      git!(repo_b, ["config", "user.email", "b@example.com"])

      env_a = GitEnv.git_env(repo_a)
      env_b = GitEnv.git_env(repo_b)

      assert env_a["GIT_AUTHOR_NAME"] == "Repo A User"
      assert env_a["GIT_AUTHOR_EMAIL"] == "a@example.com"
      assert env_b["GIT_AUTHOR_NAME"] == "Repo B User"
      assert env_b["GIT_AUTHOR_EMAIL"] == "b@example.com"
      assert env_a["GIT_AUTHOR_NAME"] != env_b["GIT_AUTHOR_NAME"]
    end

    test "global git config identity is honored when the repo has none", %{tmp_dir: tmp_dir} do
      git!(tmp_dir, ["init"])

      global_cfg = Path.join(tmp_dir, "global-gitconfig")
      File.write!(global_cfg, "[user]\n\tname = Global User\n\temail = global@example.com\n")

      with_env("GIT_CONFIG_GLOBAL", global_cfg, fn ->
        with_env("GIT_CONFIG_NOSYSTEM", "1", fn ->
          env = GitEnv.git_env(tmp_dir)

          assert env["GIT_AUTHOR_NAME"] == "Global User"
          assert env["GIT_AUTHOR_EMAIL"] == "global@example.com"
        end)
      end)
    end

    test "fallback placeholder is used only when no env var and no config value exists", %{
      tmp_dir: tmp_dir
    } do
      # A fresh repo with NO user.name/user.email configured.
      git!(tmp_dir, ["init"])

      # Hermetic: point git at an empty global config and disable the system
      # config so an ambient machine-wide git identity can't leak in.
      with_isolated_git_config(fn ->
        env = GitEnv.git_env(tmp_dir)

        assert env["GIT_AUTHOR_NAME"] == "Genesis Test"
        assert env["GIT_AUTHOR_EMAIL"] == "test@genesis.local"
        assert env["GIT_COMMITTER_NAME"] == "Genesis Test"
        assert env["GIT_COMMITTER_EMAIL"] == "test@genesis.local"
      end)
    end

    test "inherited GIT_AUTHOR_NAME env is not clobbered (env wins over config)", %{
      tmp_dir: tmp_dir
    } do
      git!(tmp_dir, ["init"])
      git!(tmp_dir, ["config", "user.name", "Config User"])
      git!(tmp_dir, ["config", "user.email", "config@example.com"])

      with_env("GIT_AUTHOR_NAME", "Env Author", fn ->
        env = GitEnv.git_env(tmp_dir)

        assert env["GIT_AUTHOR_NAME"] == "Env Author"
        assert env["GIT_AUTHOR_EMAIL"] == "config@example.com"
        assert env["GIT_COMMITTER_NAME"] == "Config User"
        assert env["GIT_COMMITTER_EMAIL"] == "config@example.com"

        # A real commit must be authored by the inherited env identity while
        # the committer still comes from config.
        File.write!(Path.join(tmp_dir, "hello.txt"), "hello\n")
        assert {:ok, _} = Git.add(tmp_dir, "hello.txt")
        assert {:ok, _} = Git.commit(tmp_dir, "Env-authored commit")

        assert {:ok, identity} = Git.run(["log", "-1", "--format=%an|%ae|%cn|%ce"], tmp_dir)
        assert identity == "Env Author|config@example.com|Config User|config@example.com"
      end)
    end

    test "inherited GIT_COMMITTER_NAME env is honored independently", %{tmp_dir: tmp_dir} do
      git!(tmp_dir, ["init"])
      git!(tmp_dir, ["config", "user.name", "Config User"])
      git!(tmp_dir, ["config", "user.email", "config@example.com"])

      with_env("GIT_COMMITTER_NAME", "Env Committer", fn ->
        env = GitEnv.git_env(tmp_dir)

        assert env["GIT_AUTHOR_NAME"] == "Config User"
        assert env["GIT_COMMITTER_NAME"] == "Env Committer"
        assert env["GIT_COMMITTER_EMAIL"] == "config@example.com"
      end)
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

    test "git_env_list/1 returns tuples matching git_env/1 for a repo", %{tmp_dir: tmp_dir} do
      git!(tmp_dir, ["init"])
      git!(tmp_dir, ["config", "user.name", "List User"])
      git!(tmp_dir, ["config", "user.email", "list@example.com"])

      assert Enum.sort(GitEnv.git_env_list(tmp_dir)) ==
               Enum.sort(Map.to_list(GitEnv.git_env(tmp_dir)))
    end

    test "carries the effective commit identity for sandbox re-export", %{tmp_dir: tmp_dir} do
      git!(tmp_dir, ["init"])
      git!(tmp_dir, ["config", "user.name", "Sandbox User"])
      git!(tmp_dir, ["config", "user.email", "sandbox@example.com"])

      list = GitEnv.git_env_list(tmp_dir)
      env = Map.new(list)

      # systemd-run --user does not inherit the caller's full environment, so
      # the resolved identity must be explicitly present in the env list.
      assert env["GIT_AUTHOR_NAME"] == "Sandbox User"
      assert env["GIT_AUTHOR_EMAIL"] == "sandbox@example.com"
      assert env["GIT_COMMITTER_NAME"] == "Sandbox User"
      assert env["GIT_COMMITTER_EMAIL"] == "sandbox@example.com"
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

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Runs a raw git command in `dir` for test setup (init/config — deliberately
  # NOT via EvoGit.Adapters.Git, which injects the env map under test).
  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed in #{dir}: #{output}"
    output
  end

  # Runs `fun` with `key` set to `value`, restoring the previous value (or
  # deleting the key) afterwards.
  defp with_env(key, value, fun) do
    old = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      restore_env(key, old)
    end
  end

  # Runs `fun` with git config fully isolated from the ambient machine config:
  # GIT_CONFIG_GLOBAL points at an empty temp file, GIT_CONFIG_NOSYSTEM=1, and
  # all four GIT_AUTHOR_*/GIT_COMMITTER_* env vars are removed. Everything is
  # restored afterwards.
  defp with_isolated_git_config(fun) do
    old_global = System.get_env("GIT_CONFIG_GLOBAL")
    old_nosystem = System.get_env("GIT_CONFIG_NOSYSTEM")
    old_identity = Map.new(@identity_keys, fn k -> {k, System.get_env(k)} end)

    empty_config =
      Path.join(
        System.tmp_dir!(),
        "genesis_empty_gitconfig_#{System.unique_integer([:positive])}"
      )

    File.write!(empty_config, "")

    System.put_env("GIT_CONFIG_GLOBAL", empty_config)
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")
    Enum.each(@identity_keys, &System.delete_env/1)

    try do
      fun.()
    after
      restore_env("GIT_CONFIG_GLOBAL", old_global)
      restore_env("GIT_CONFIG_NOSYSTEM", old_nosystem)
      Enum.each(@identity_keys, fn k -> restore_env(k, old_identity[k]) end)
      File.rm(empty_config)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
