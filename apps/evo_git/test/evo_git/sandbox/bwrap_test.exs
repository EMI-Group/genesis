defmodule EvoGit.Sandbox.BwrapTest do
  # `async: false` because several tests mutate the global `$TMPDIR` and
  # `$XDG_CONFIG_HOME` env vars via System.put_env/1 (process-global, would
  # race under async), and the nix tests mutate the VM-global
  # `:evogit_nix_dev_env_state` persistent_term.
  use ExUnit.Case, async: false

  # Git-metadata fixtures for the linked-worktree describe use the per-test
  # temp dir provided by ExUnit.
  @moduletag :tmp_dir

  alias EvoGit.{Nix, Platform, Sandbox}
  alias EvoGit.Sandbox.Bwrap

  # The backend's built-in writable cache-dir list (mirrored from
  # lib/evo_git/sandbox/bwrap.ex — the default writable paths when the
  # [sandbox] write_paths config key is unset). Pinned here so a change to
  # the lib defaults fails loudly.
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

  # The backend's sensitive credential-store deny list (mirrored from
  # lib/evo_git/sandbox/bwrap.ex — each dir gets an empty --tmpfs overlay).
  @deny_list [
    ".ssh",
    ".gnupg",
    ".aws",
    ".kube",
    ".config/sops",
    ".git-credentials",
    ".netrc",
    ".password-store",
    ".docker",
    ".gem",
    ".npmrc",
    ".pypirc"
  ]

  defp build_args(cwd \\ System.tmp_dir!()) do
    Bwrap.args(cwd, "/usr/bin/env", [], nil)
  end

  # True when `pattern` appears as a consecutive subsequence of `args`
  # (bwrap emits separate `["--setenv", key, value]` / `["--bind-try", p, p]`
  # args, unlike linux.ex's joined `--setenv=K=V` strings — subsequence
  # matching keeps the assertions independent of exact env ordering).
  defp has_subsequence?(args, pattern) do
    args
    |> Enum.chunk_every(length(pattern), 1, :discard)
    |> Enum.any?(&(&1 == pattern))
  end

  # Returns the value of a `["--setenv", key, value]` triple, or nil when the
  # key is not set.
  defp setenv_value(args, key) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      ["--setenv", ^key, value] -> value
      _ -> nil
    end)
  end

  # Returns the paths bound via `["--bind-try", path, path]` triples.
  defp bind_paths(args) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.flat_map(fn
      ["--bind-try", path, path] -> [path]
      _ -> []
    end)
  end

  # Returns the subset of writable binds pointing into a `.git` metadata dir
  # (used to assert NO git bind is emitted for non-repo cwds).
  defp git_binds(args) do
    Enum.filter(bind_paths(args), &String.ends_with?(&1, ".git"))
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
        "evogit-bwrap-test-xdg-#{System.unique_integer([:positive])}"
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

  setup do
    original = Application.get_env(:evo_git, :nix_enabled)
    Application.put_env(:evo_git, :nix_enabled, false)
    on_exit(fn -> Application.put_env(:evo_git, :nix_enabled, original) end)
    :ok
  end

  describe "enabled?/0 and ensure_initialized/0" do
    test "enabled?/0 is false in the test env" do
      # The compile-time @mix_env == :test gate comes FIRST in enabled?/0 and
      # is unconditional — tests must NEVER invoke real bwrap (CI/worker
      # environments typically block mount(2) or lack user namespaces). The
      # args builders are exercised directly instead. Do not remove the gate.
      assert Bwrap.enabled?() == false
    end

    test "ensure_initialized/0 is a no-op" do
      # bwrap needs no systemd slice and no unit registry.
      assert Bwrap.ensure_initialized() == :ok
    end
  end

  describe "args/4 — namespace flags" do
    test "starts with the fixed namespace/root-bind flag sequence" do
      args = build_args()

      assert Enum.take(args, 9) == [
               "--die-with-parent",
               "--new-session",
               "--unshare-user-try",
               "--unshare-ipc",
               "--unshare-pid",
               "--unshare-uts",
               "--unshare-cgroup-try",
               "--ro-bind",
               "/"
             ]
    end

    test "never unshares the network namespace" do
      # Network is deliberately retained so git fetch/push, mix deps.get,
      # curl and web tools keep working.
      args = build_args()
      refute "--unshare-net" in args
    end

    test "contains the ro-bind / /, --dev /dev, --proc /proc blocks in that order" do
      args = build_args()
      ro_idx = Enum.find_index(args, &(&1 == "--ro-bind"))
      dev_idx = Enum.find_index(args, &(&1 == "--dev"))
      proc_idx = Enum.find_index(args, &(&1 == "--proc"))

      assert is_integer(ro_idx) and is_integer(dev_idx) and is_integer(proc_idx)
      assert has_subsequence?(args, ["--ro-bind", "/", "/"])
      assert has_subsequence?(args, ["--dev", "/dev"])
      assert has_subsequence?(args, ["--proc", "/proc"])
      assert ro_idx < dev_idx and dev_idx < proc_idx
    end
  end

  describe "args/4 — tmp binds" do
    test "binds every platform tmp path writable" do
      args = build_args()

      for path <- Platform.tmp_paths() do
        assert has_subsequence?(args, ["--bind-try", path, path]),
               "expected a writable bind for tmp path #{path}, got: #{inspect(args)}"
      end
    end
  end

  describe "args/4 — writable binds" do
    test "binds the cwd writable" do
      cwd =
        Path.join(
          System.tmp_dir!(),
          "evogit_bwrap_cwd_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)

      args = build_args(cwd)
      assert has_subsequence?(args, ["--bind-try", cwd, cwd])
    end

    test "with write_paths unset, binds every default cache dir" do
      redirect_xdg_config_home()
      args = build_args()
      home = System.user_home!()

      for dir <- @default_cache_dirs do
        path = Path.join(home, dir)

        assert has_subsequence?(args, ["--bind-try", path, path]),
               "expected default cache-dir bind for #{dir}, got: #{inspect(args)}"
      end
    end
  end

  describe "args/4 — write_paths configured" do
    setup do
      redirect_xdg_config_home()
      :ok
    end

    @custom_write_paths ["/custom/writable", "/another/path"]

    test "includes the configured write paths as writable binds" do
      write_config(@custom_write_paths)
      args = build_args()

      for path <- @custom_write_paths do
        assert has_subsequence?(args, ["--bind-try", path, path])
      end
    end

    test "replaces the default cache-dir binds when write_paths is set" do
      write_config(@custom_write_paths)
      args = build_args()
      home = System.user_home!()

      for dir <- @default_cache_dirs do
        path = Path.join(home, dir)

        refute has_subsequence?(args, ["--bind-try", path, path]),
               "did not expect default cache dir #{dir} in args, got: #{inspect(args)}"
      end
    end

    test "still includes structural paths (cwd, tmp) alongside configured write paths" do
      write_config(@custom_write_paths)

      cwd =
        Path.join(
          System.tmp_dir!(),
          "evogit_bwrap_cwd_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)

      args = build_args(cwd)

      for path <- Platform.tmp_paths() do
        assert has_subsequence?(args, ["--bind-try", path, path])
      end

      assert has_subsequence?(args, ["--bind-try", cwd, cwd])
    end
  end

  describe "args/4 — write_paths explicitly empty" do
    setup do
      redirect_xdg_config_home()
      :ok
    end

    test "an empty write_paths list removes all default cache-dir binds" do
      write_config([])
      args = build_args()
      home = System.user_home!()

      for dir <- @default_cache_dirs do
        path = Path.join(home, dir)

        refute has_subsequence?(args, ["--bind-try", path, path]),
               "did not expect default cache dir #{dir} in args, got: #{inspect(args)}"
      end
    end

    test "still includes structural tmp binds with write_paths = []" do
      write_config([])
      args = build_args()

      for path <- Platform.tmp_paths() do
        assert has_subsequence?(args, ["--bind-try", path, path])
      end
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

      path = Path.join(System.user_home!(), "mycache")
      assert has_subsequence?(args, ["--bind-try", path, path])
    end
  end

  describe "args/4 — git metadata dir" do
    # Fixtures mirror what `git worktree add` produces: the main repo has a
    # real `.git` DIRECTORY, and the linked worktree's `.git` is a pointer
    # FILE containing `gitdir: <absolute path>`. Built with plain
    # File.mkdir_p!/File.write! — git_metadata_dir/2 only does File.read and
    # File.dir?, so no `git init` is needed.
    setup %{tmp_dir: tmp_dir} do
      base = Path.join(tmp_dir, "git-#{System.unique_integer([:positive])}")

      main_root = Path.join(base, "main")
      File.mkdir_p!(Path.join(main_root, ".git/worktrees/wt1"))

      worktree = Path.join(main_root, ".genesis/workers/worker_T1_A1")
      File.mkdir_p!(worktree)

      File.write!(
        Path.join(worktree, ".git"),
        "gitdir: " <> Path.join(main_root, ".git/worktrees/wt1") <> "\n"
      )

      # A pointer WITHOUT a "/worktrees/" segment — resolves to itself.
      custom = Path.join(base, "custom")
      File.mkdir_p!(custom)
      custom_git = Path.join(base, "custom-git-dir")
      File.write!(Path.join(custom, ".git"), "gitdir: #{custom_git}\n")

      # A plain dir with no .git at all.
      plain = Path.join(base, "plain")
      File.mkdir_p!(plain)

      # A repo with a real .git DIRECTORY.
      repo = Path.join(base, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))

      on_exit(fn -> File.rm_rf!(base) end)

      %{
        main_root: main_root,
        worktree: worktree,
        custom: custom,
        custom_git: custom_git,
        plain: plain,
        repo: repo
      }
    end

    test "repo_root with a real .git dir binds repo_root/.git", %{repo: repo} do
      args = Bwrap.args(System.tmp_dir!(), "/usr/bin/env", [], repo)

      assert has_subsequence?(args, ["--bind-try", "#{repo}/.git", "#{repo}/.git"])
    end

    test "repo_root with a gitdir: pointer resolves to the common git dir", %{
      worktree: worktree,
      main_root: main_root
    } do
      args = Bwrap.args(worktree, "/usr/bin/env", [], worktree)

      # A writable bind on the COMMON dir covers the per-worktree dir inside it.
      assert has_subsequence?(args, ["--bind-try", "#{main_root}/.git", "#{main_root}/.git"])
      refute has_subsequence?(args, ["--bind-try", "#{worktree}/.git", "#{worktree}/.git"])
    end

    test "a pointer without a /worktrees/ segment resolves to itself", %{
      custom: custom,
      custom_git: custom_git
    } do
      args = Bwrap.args(custom, "/usr/bin/env", [], custom)

      assert has_subsequence?(args, ["--bind-try", custom_git, custom_git])
    end

    test "nil repo_root with a non-repo cwd emits no git bind", %{plain: plain} do
      args = Bwrap.args(plain, "/usr/bin/env", [], nil)

      assert git_binds(args) == [],
             "expected no git metadata bind, got: #{inspect(git_binds(args))}"
    end

    test "nil repo_root with a real .git dir binds cwd/.git", %{repo: repo} do
      args = Bwrap.args(repo, "/usr/bin/env", [], nil)

      assert has_subsequence?(args, ["--bind-try", "#{repo}/.git", "#{repo}/.git"])
    end

    test "nil repo_root with a .git pointer file binds the common git dir", %{
      worktree: worktree,
      main_root: main_root
    } do
      args = Bwrap.args(worktree, "/usr/bin/env", [], nil)

      assert has_subsequence?(args, ["--bind-try", "#{main_root}/.git", "#{main_root}/.git"])
    end
  end

  describe "args/4 — deny list" do
    test "hides every sensitive home dir behind an empty tmpfs AFTER the ro-bind" do
      args = build_args()
      home = System.user_home!()

      for dir <- @deny_list do
        path = Path.join(home, dir)

        assert has_subsequence?(args, ["--tmpfs", path]),
               "expected a tmpfs overlay for #{dir}, got: #{inspect(args)}"
      end

      ro_idx = Enum.find_index(args, &(&1 == "--ro-bind"))
      tmpfs_idx = Enum.find_index(args, &(&1 == "--tmpfs"))
      assert is_integer(ro_idx) and is_integer(tmpfs_idx)
      assert tmpfs_idx > ro_idx
    end
  end

  describe "args/4 — chdir and command separator" do
    test "chdirs into cwd and ends with the command after --" do
      cwd = System.tmp_dir!()
      args = build_args(cwd)

      assert has_subsequence?(args, ["--chdir", cwd])
      assert Enum.take(args, -2) == ["--", "/usr/bin/env"]
    end

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

  describe "args/4 — nix integration" do
    # The enabled-but-inactive trick: bwrap's args/4 emits the /nix/store and
    # /nix/var writable binds when `Nix.enabled?()` is true, but only wraps
    # the command when `Nix.active?()` is true. Pre-seeding the VM-global
    # `:evogit_nix_dev_env_state` with `{:failed, "test"}` makes active?()
    # false WITHOUT ever invoking `nix print-dev-env` (active?/0
    # short-circuits on the failed state before wrap_command), so the unique
    # nix-bind behavior is testable without a real nix install.

    test "emits /nix/store + /nix/var binds but does NOT nix-wrap when enabled-but-inactive" do
      original = Application.get_env(:evo_git, :nix_enabled)
      Application.put_env(:evo_git, :nix_enabled, true)
      :persistent_term.put(:evogit_nix_dev_env_state, {:failed, "test"})

      on_exit(fn ->
        Application.put_env(:evo_git, :nix_enabled, original)
        Nix.reset_state()
      end)

      args = build_args()

      assert has_subsequence?(args, ["--bind-try", "/nix/store", "/nix/store"])
      assert has_subsequence?(args, ["--bind-try", "/nix/var", "/nix/var"])
      # active?() is false → the original executable is preserved, no wrapping.
      assert Enum.take(args, -2) == ["--", "/usr/bin/env"]
      refute "develop" in args
      refute "--command" in args
    end

    test "disabled nix emits no nix store binds" do
      args = build_args()

      refute has_subsequence?(args, ["--bind-try", "/nix/store", "/nix/store"])
      refute has_subsequence?(args, ["--bind-try", "/nix/var", "/nix/var"])
    end
  end

  describe "args/4 — TMPDIR env" do
    test "always sets TMPDIR via a --setenv triple" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      args = build_args()
      assert has_subsequence?(args, ["--setenv", "TMPDIR", Sandbox.resolve_tmpdir()])
    end

    test "falls back to the first platform tmp path when TMPDIR is unset" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      assert setenv_value(build_args(), "TMPDIR") == hd(Platform.tmp_paths())
    end

    test "forwards a real TMPDIR subdir under a tmp path" do
      save_tmpdir()

      sub =
        Path.join(
          System.tmp_dir!(),
          "evogit_bwrap_tmp_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(sub)
      on_exit(fn -> File.rm_rf!(sub) end)
      System.put_env("TMPDIR", sub)

      assert setenv_value(build_args(), "TMPDIR") == sub
    end
  end

  describe "args/4 — git identity env" do
    test "injects the resolved git identity for /usr/bin/git" do
      args = Bwrap.args(System.tmp_dir!(), "/usr/bin/git", ["status"], nil)

      assert has_subsequence?(args, ["--setenv", "LC_ALL", "C"])

      editor_value = setenv_value(args, "GIT_EDITOR")
      assert is_binary(editor_value), "expected a GIT_EDITOR --setenv, got: #{inspect(args)}"
      assert String.ends_with?(editor_value, "true")

      for key <- [
            "GIT_AUTHOR_NAME",
            "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME",
            "GIT_COMMITTER_EMAIL"
          ] do
        assert is_binary(setenv_value(args, key)),
               "expected a --setenv for #{key}, got: #{inspect(args)}"
      end
    end

    test "injects git env for a bare 'git' executable name" do
      args = Bwrap.args(System.tmp_dir!(), "git", ["merge", "--continue"], nil)

      assert has_subsequence?(args, ["--setenv", "LC_ALL", "C"])
      assert is_binary(setenv_value(args, "GIT_EDITOR"))
      assert is_binary(setenv_value(args, "GIT_AUTHOR_NAME"))
    end

    test "does NOT inject git env for /usr/bin/rg" do
      args = Bwrap.args(System.tmp_dir!(), "/usr/bin/rg", ["pattern"], nil)

      refute has_subsequence?(args, ["--setenv", "LC_ALL", "C"])
      assert setenv_value(args, "GIT_EDITOR") == nil
      refute Enum.any?(args, &(&1 == "GIT_AUTHOR_NAME"))
    end

    test "does NOT inject git env for /usr/bin/env" do
      args = build_args()

      refute has_subsequence?(args, ["--setenv", "LC_ALL", "C"])
      assert setenv_value(args, "GIT_EDITOR") == nil
    end

    test "all --setenv args come BEFORE the -- separator" do
      args = Bwrap.args(System.tmp_dir!(), "/usr/bin/git", ["status"], nil)
      sep_idx = Enum.find_index(args, &(&1 == "--"))
      assert is_integer(sep_idx), "expected a -- separator, got: #{inspect(args)}"

      setenv_indices =
        args
        |> Enum.with_index()
        |> Enum.filter(fn {arg, _idx} -> arg == "--setenv" end)
        |> Enum.map(fn {_arg, idx} -> idx end)

      assert setenv_indices != []

      for idx <- setenv_indices,
          do: assert(idx < sep_idx, "setenv at #{idx} after -- at #{sep_idx}")
    end

    test "TMPDIR --setenv is present for non-git executables too" do
      save_tmpdir()
      System.delete_env("TMPDIR")

      args = Bwrap.args(System.tmp_dir!(), "/usr/bin/rg", ["pattern"], nil)
      assert has_subsequence?(args, ["--setenv", "TMPDIR", hd(Platform.tmp_paths())])
    end
  end

  describe "args/4 — bash wrapping pattern (run/4)" do
    test "passes bash -c with the wrapped stdin-redirected command through" do
      # run/4 wraps the command in bash with a stdin redirect and calls args/4
      # with "bash" as the executable. Verify args/4 passes these through
      # unchanged as the tail command.
      wrapped_cmd = "cmd < /dev/null"
      args = Bwrap.args(System.tmp_dir!(), "bash", ["-c", wrapped_cmd], nil)

      assert Enum.take(args, -4) == ["--", "bash", "-c", wrapped_cmd]
    end
  end
end
