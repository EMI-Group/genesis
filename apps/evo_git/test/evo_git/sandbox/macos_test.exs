defmodule EvoGit.Sandbox.MacOSTest do
  # `async: false` because the tests mutate VM-global state that production
  # code reads: resolve_tmpdir/0 reads the process-global `$TMPDIR` env var,
  # the suite sets `$XDG_CONFIG_HOME`, flips the app env `:nix_enabled`, and
  # seeds the `{EvoGit.Sandbox.MacOS, :process_limit_rejected}` persistent_term.
  use ExUnit.Case, async: false

  alias EvoGit.{Platform, Sandbox, TaskTmpdir}
  alias EvoGit.Sandbox.MacOS

  # The backend's built-in build-cache dirs (mirrored from
  # lib/evo_git/sandbox/macos.ex — the default writable paths when the
  # [sandbox] write_paths config key is unset).
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

  # The canonical credential deny list (mirrored from
  # lib/evo_git/sandbox/spec.ex — `Spec.credential_paths/0`), in canonical
  # order. `Library/Keychains` is NOT part of it: it is macOS-only and the
  # renderer appends it itself.
  @canonical_credential_dirs [
    ".ssh",
    ".gnupg",
    ".aws",
    ".kube",
    ".config/sops",
    ".git-credentials",
    ".netrc",
    ".password-store",
    ".npmrc",
    ".pypirc",
    ".docker",
    ".gem"
  ]

  defp cache_rule(dir),
    do: ~s{(allow file-write* (subpath "#{Path.join(System.user_home!(), dir)}"))}

  # A credential carveout rule carries BOTH path filters in ONE rule: SBPL
  # OR-combines a rule's filters, so `literal` + `subpath` covers the path
  # itself even when it does not exist yet (a bare `subpath` leaves the
  # first-time-creation gap, e.g. `mkdir ~/.ssh`). System-level `deny_paths`
  # stay subpath-only — no first-time creation concern for root-owned paths.
  defp credential_deny_rule(operation, path),
    do: ~s{(deny #{operation} (literal "#{path}") (subpath "#{path}"))}

  # Extracts the paths of every credential deny-read carveout rule
  # (`(deny file-read* (literal "<p>") (subpath "<p>"))`) in EMISSION order —
  # so group membership AND ordering can be asserted on the extracted list
  # instead of a joined blob. The subpath-only system-level rules are matched
  # by their own literal assertions, never by this extractor.
  defp deny_read_subpaths(profile) do
    ~r/\(deny file-read\* \(literal "[^"]+"\) \(subpath "([^"]+)"\)\)/
    |> Regex.scan(profile, capture: :all_but_first)
    |> List.flatten()
  end

  # The profile's non-blank lines, indentation stripped (groups are joined with
  # `"\n    "`, so only the FIRST line of a group is unindented).
  defp profile_lines(profile) do
    profile
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Asserts `resolved` is emitted on the line IMMEDIATELY after `logical`.
  # The renderer emits a path's resolved spelling right after its logical one,
  # so the pair reads as a unit — that adjacency is what makes the resolved
  # rule land in the same group as the rule it mirrors.
  defp assert_emitted_right_after(profile, logical, resolved) do
    lines = profile_lines(profile)

    index =
      Enum.find_index(lines, &(&1 == logical)) ||
        flunk("expected the profile to emit #{inspect(logical)}")

    assert Enum.at(lines, index + 1) == resolved,
           "expected #{inspect(resolved)} immediately after #{inspect(logical)}, " <>
             "got #{inspect(Enum.at(lines, index + 1))}"
  end

  # Fake system-alias seam for the tmp pair every macOS host has (`/tmp` →
  # `/private/tmp`, `/var/tmp` → `/private/var/tmp`); anything else is
  # identity. Injected so the resolved-spelling pins never depend on the
  # HOST's real symlink layout (CI is Linux, where nothing resolves).
  defp tmp_alias("/tmp"), do: ["/tmp", "/private/tmp"]
  defp tmp_alias("/var/tmp"), do: ["/var/tmp", "/private/var/tmp"]
  defp tmp_alias(path), do: [path]

  # Writes a minimal `[sandbox] write_paths = ...` config.toml into the
  # XDG_CONFIG_HOME temp dir isolated by the global setup (each test gets a
  # fresh unique dir, so the Config persistent_term cache can never go
  # stale), runs `fun`, then removes the file.
  defp with_write_paths(paths, fun) do
    xdg = System.get_env("XDG_CONFIG_HOME")
    genesis_dir = Path.join(xdg, "genesis")
    File.mkdir_p!(genesis_dir)
    config_path = Path.join(genesis_dir, "config.toml")
    File.write!(config_path, "[sandbox]\nwrite_paths = #{inspect(paths)}\n")
    # Config reads come from the RAM snapshot; a direct write needs the reload.
    EvoGit.Config.Cache.reload()

    on_exit(fn -> File.rm_rf!(genesis_dir) end)

    fun.()
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

  # Installs a fresh, test-owned managed per-task tmpdir on the CURRENT test
  # process (the process-dictionary seam read in the SAME process by
  # `EvoGit.Sandbox.Helpers.task_tmpdir_path/0` and
  # `EvoGit.Sandbox.resolve_tmpdir/0`) and returns its path. ExUnit gives every
  # test a fresh process, so the pdict value never leaks and needs no cleanup.
  defp per_task_tmpdir! do
    path = Path.join(System.tmp_dir!(), "evogit_task_tmp_#{System.unique_integer([:positive])}")

    TaskTmpdir.put_current(path)
    path
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

        assert profile =~ credential_deny_rule("file-read*", path),
               "expected a deny-read rule for #{dir}"
      end
    end

    test "denies reads of system-level sensitive locations (both symlink spellings)" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      # Root-wide reads are allowed (see the root-rule test above), so these
      # deny-reads are what keep system credential stores and user databases
      # unreadable. Each location is pinned in both its real and /private
      # symlink spellings, matching the profile policy.
      for path <- [
            "/etc/ssh",
            "/private/etc/ssh",
            "/var/root",
            "/private/var/root",
            "/etc/master.passwd",
            "/private/etc/master.passwd",
            "/var/db/dslocal",
            "/private/var/db/dslocal",
            "/var/db/Keychains",
            "/private/var/db/Keychains"
          ] do
        assert profile =~ ~s{(deny file-read* (subpath "#{path}"))},
               "expected a deny-read rule for #{path}"
      end
    end

    test "denies WRITES to every canonical credential dir (deny-read parity)" do
      profile = MacOS.generate_profile("/some/cwd", nil)

      for dir <- @canonical_credential_dirs do
        path = Path.join(System.user_home!(), dir)

        assert profile =~ credential_deny_rule("file-write*", path),
               "expected a deny-write rule for #{dir}"
      end
    end

    test "writes each credential carveout as ONE rule carrying BOTH path filters" do
      profile = MacOS.generate_profile("/some/cwd", nil)
      home = System.user_home!()

      for dir <- @canonical_credential_dirs, operation <- ["file-read*", "file-write*"] do
        path = Path.join(home, dir)
        rule = credential_deny_rule(operation, path)

        # Exactly ONE rule per operation — the literal+subpath pair — never the
        # pair PLUS a legacy bare-subpath rule for the same path.
        assert length(Regex.scan(Regex.compile!(Regex.escape(rule)), profile)) == 1,
               "expected exactly one #{operation} carveout for #{dir}"

        # `literal` closes the first-time-creation gap (e.g. `mkdir ~/.ssh`)
        # that a subpath-only rule leaves open.
        refute profile =~ ~s{(deny #{operation} (subpath "#{path}"))},
               "expected no subpath-only #{operation} rule for #{dir}"
      end
    end

    test "emits the credential deny-read group in canonical order with Library/Keychains after .password-store" do
      profile = MacOS.generate_profile("/some/cwd", nil)
      home = System.user_home!()

      expected_dirs =
        Enum.flat_map(@canonical_credential_dirs, fn
          ".password-store" -> [".password-store", "Library/Keychains"]
          dir -> [dir]
        end)

      # Home-based deny-read rules, extracted in emission order: "deny" beats
      # "allow" in SBPL, so this list IS the protected credential set. On a
      # host where no home path has a symlinked component every path has ONE
      # spelling, so the extracted list must equal the canonical order.
      home_deny_reads =
        profile
        |> deny_read_subpaths()
        |> Enum.filter(&String.starts_with?(&1, home <> "/"))

      assert home_deny_reads == Enum.map(expected_dirs, &Path.join(home, &1))

      # The macOS-only keychain entry is IN the deny-read extraction list, at
      # its canonical position (immediately after `.password-store`).
      keychains_index = Enum.find_index(expected_dirs, &(&1 == "Library/Keychains"))

      assert Enum.at(home_deny_reads, keychains_index) == Path.join(home, "Library/Keychains")

      # Belt and braces on the emitted STRING: the macOS-only keychain entry
      # sits between `.password-store` and `.npmrc`.
      {password_store_at, _} = :binary.match(profile, "#{home}/.password-store")
      {keychains_at, _} = :binary.match(profile, "#{home}/Library/Keychains")
      {npmrc_at, _} = :binary.match(profile, "#{home}/.npmrc")

      assert password_store_at < keychains_at
      assert keychains_at < npmrc_at
    end

    test "denies Library/Keychains for READS only, never for writes" do
      profile = MacOS.generate_profile("/some/cwd", nil)
      keychains = Path.join(System.user_home!(), "Library/Keychains")

      assert profile =~ credential_deny_rule("file-read*", keychains)
      refute profile =~ credential_deny_rule("file-write*", keychains)
      refute profile =~ ~s{(deny file-write* (subpath "#{keychains}"))}

      # It is a macOS-only extra, never part of the shared canonical list.
      refute "Library/Keychains" in EvoGit.Sandbox.Spec.credential_paths()
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

  describe "generate_profile/2 — managed per-task tmpdir" do
    test "grants read+write to the managed per-task tmpdir when installed" do
      task_tmp = per_task_tmpdir!()

      profile = MacOS.generate_profile("/some/cwd", nil)

      assert profile =~ ~s{(allow file-read* (subpath "#{task_tmp}"))}
      assert profile =~ ~s{(allow file-write* (subpath "#{task_tmp}"))}
    end

    test "keeps the system tmp read/write rules when a per-task tmpdir is installed" do
      # The per-task dir is an ADDITIONAL writable path — the system tmp rules
      # (same paths asserted by the plain generate_profile/2 tests) must stay.
      per_task_tmpdir!()

      profile = MacOS.generate_profile("/some/cwd", nil)

      for path <- ["/tmp", "/var/tmp"] do
        assert profile =~ ~s{(allow file-read* (subpath "#{path}"))}
        assert profile =~ ~s{(allow file-write* (subpath "#{path}"))}
      end
    end

    test "emits no per-task tmpdir rules when none is installed" do
      TaskTmpdir.put_current(nil)

      profile = MacOS.generate_profile("/some/cwd", nil)

      # No rule may reference a managed per-task dir (`<root>/genesis/task_<id>`).
      # This matches the real per-task rule shape and cannot collide with the
      # genesis config/data dir rules (those end in `/genesis`).
      refute profile =~ ~r{subpath "[^"]*/genesis/task_\d+"},
             "expected no managed per-task tmpdir rules when none is installed"
    end
  end

  describe "linked-worktree git metadata resolution" do
    # Fixtures mirror what `git worktree add` produces: the main repo has a
    # real `.git` DIRECTORY, and the linked worktree's `.git` is a pointer
    # FILE containing `gitdir: <absolute path>`.
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "evogit-macos-git-#{System.unique_integer([:positive])}")

      main_root = Path.join(tmp, "main")
      File.mkdir_p!(Path.join(main_root, ".git/worktrees/wt1"))

      worktree = Path.join(main_root, ".genesis/workers/worker_T1_A1")
      File.mkdir_p!(worktree)

      File.write!(
        Path.join(worktree, ".git"),
        "gitdir: " <> Path.join(main_root, ".git/worktrees/wt1") <> "\n"
      )

      plain_dir = Path.join(tmp, "plain")
      File.mkdir_p!(plain_dir)

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{main_root: main_root, worktree: worktree, plain_dir: plain_dir}
    end

    test "normal repo: .git is a directory -> literal git dir rule", %{
      main_root: main_root,
      worktree: worktree
    } do
      profile = MacOS.generate_profile(worktree, main_root)

      assert profile =~ ~s{(allow file-read* (subpath "#{Path.join(main_root, ".git")}"))}
      assert profile =~ ~s{(allow file-write* (subpath "#{Path.join(main_root, ".git")}"))}
    end

    test "linked worktree: pointer .git file resolves to the common git dir", %{
      main_root: main_root,
      worktree: worktree
    } do
      profile = MacOS.generate_profile(worktree, worktree)

      assert profile =~ ~s{(allow file-read* (subpath "#{Path.join(main_root, ".git")}"))}
      assert profile =~ ~s{(allow file-write* (subpath "#{Path.join(main_root, ".git")}"))}
      refute profile =~ ~s{(subpath "#{Path.join(worktree, ".git")}")}
    end

    test "nil repo_root with a cwd .git pointer file resolves the common git dir", %{
      main_root: main_root,
      worktree: worktree
    } do
      profile = MacOS.generate_profile(worktree, nil)

      assert profile =~ ~s{(allow file-read* (subpath "#{Path.join(main_root, ".git")}"))}
      assert profile =~ ~s{(allow file-write* (subpath "#{Path.join(main_root, ".git")}"))}
      refute profile =~ ~s{(subpath "#{Path.join(worktree, ".git")}")}
    end

    test "nil repo_root without any .git emits no git metadata rule", %{
      plain_dir: plain_dir
    } do
      profile = MacOS.generate_profile(plain_dir, nil)

      # NOTE: a plain `String.contains?(profile, ".git")` can never be false —
      # the deny-read/write rules for `~/.git-credentials` always contain the
      # substring. Pin the intent instead: no subpath rule pointing INTO a
      # `.git` dir (the regex matches `.../.git"` and `.../.git/...` but not
      # `.../.git-credentials"`).
      refute profile =~ ~r{subpath "[^"]*/\.git(?:"|/)}
    end

    test "root filesystem is readable by default so user-installed tools work anywhere", %{
      main_root: main_root,
      worktree: worktree
    } do
      profile = MacOS.generate_profile(worktree, main_root)

      assert profile =~ ~s{(allow file-read* (subpath "/"))}
    end
  end

  describe "generate_profile/2 — write_paths default cache dirs (unset)" do
    test "emits write rules for all 13 default build-cache dirs when write_paths is unset" do
      # No config.toml is written — the global setup already isolated
      # XDG_CONFIG_HOME, so [:sandbox, :write_paths] resolves to nil and the
      # backend falls back to its built-in cache-dir list.
      profile = MacOS.generate_profile("/some/cwd", nil)

      for dir <- @default_cache_dirs do
        assert profile =~ cache_rule(dir),
               "expected default cache-dir write rule for #{dir}"
      end
    end
  end

  describe "generate_profile/2 — write_paths configured" do
    test "emits write rules for the user-configured write paths" do
      with_write_paths(["/custom/cache", "/opt/build-cache"], fn ->
        profile = MacOS.generate_profile("/some/cwd", nil)

        assert profile =~ ~s{(allow file-write* (subpath "/custom/cache"))}
        assert profile =~ ~s{(allow file-write* (subpath "/opt/build-cache"))}
      end)
    end

    test "drops all default cache-dir write rules when write_paths is set" do
      with_write_paths(["/custom/cache", "/opt/build-cache"], fn ->
        profile = MacOS.generate_profile("/some/cwd", nil)

        for dir <- @default_cache_dirs do
          refute profile =~ cache_rule(dir),
                 "expected no default cache-dir write rule for #{dir} when write_paths is set"
        end
      end)
    end

    test "keeps structural rules (/tmp, cwd) unchanged when write_paths is set" do
      with_write_paths(["/custom/cache", "/opt/build-cache"], fn ->
        profile = MacOS.generate_profile("/some/cwd", nil)

        assert profile =~ ~s{(allow file-write* (subpath "/tmp"))}
        assert profile =~ ~s{(allow file-write* (subpath "/some/cwd"))}
      end)
    end
  end

  describe "generate_profile/2 — write_paths explicitly empty" do
    test "emits no default cache-dir write rules when write_paths is []" do
      with_write_paths([], fn ->
        profile = MacOS.generate_profile("/some/cwd", nil)

        for dir <- @default_cache_dirs do
          refute profile =~ cache_rule(dir),
                 "expected no default cache-dir write rule for #{dir} when write_paths is []"
        end

        assert profile =~ ~s{(allow file-write* (subpath "/tmp"))}
      end)
    end
  end

  describe "generate_profile/2 — write_paths ~ expansion" do
    test "expands a ~-prefixed write path to the user home" do
      with_write_paths(["~/mycache"], fn ->
        profile = MacOS.generate_profile("/some/cwd", nil)

        assert profile =~ ~s{(allow file-write* (subpath "#{System.user_home!()}/mycache"))}
      end)
    end
  end

  # Seatbelt matches RESOLVED vnodes, so a rule written with a path's logical
  # spelling (`/tmp` → `/private/tmp`) never matches. Every rendered path is
  # emitted once per spelling, logical first, through the default-inert
  # `:alias_fun` seam — these pins inject a fake resolver so the expectation
  # never depends on the HOST's symlink layout (CI is Linux: nothing resolves).
  describe "generate_profile/3 — resolved alias spellings" do
    test "emits the tmp rules once per spelling, logical then resolved" do
      profile = MacOS.generate_profile("/some/cwd", nil, alias_fun: &tmp_alias/1)

      for path <- ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"] do
        assert profile =~ ~s{(allow file-read* (subpath "#{path}"))}
        assert profile =~ ~s{(allow file-write* (subpath "#{path}"))}
      end

      # The resolved pair follows the logical pair (a read+write pair per
      # spelling, so the two spellings read as one unit in the profile).
      assert_emitted_right_after(
        profile,
        ~s{(allow file-read* (subpath "/tmp"))},
        ~s{(allow file-write* (subpath "/tmp"))}
      )

      assert_emitted_right_after(
        profile,
        ~s{(allow file-write* (subpath "/tmp"))},
        ~s{(allow file-read* (subpath "/private/tmp"))}
      )

      assert_emitted_right_after(
        profile,
        ~s{(allow file-write* (subpath "/var/tmp"))},
        ~s{(allow file-read* (subpath "/private/var/tmp"))}
      )

      # The logical spellings are not replaced: /tmp stays a hard rule.
      assert profile =~ ~s{(allow file-write* (subpath "/tmp"))}
    end

    test "emits a DENY path's resolved spelling right after the logical one" do
      # A deny written only on the logical spelling misses the resolved vnode —
      # the bypass this wiring closes.
      home = System.user_home!()
      ssh = Path.join(home, ".ssh")
      resolved_ssh = "/resolved" <> ssh

      alias_fun = fn
        ^ssh -> [ssh, resolved_ssh]
        "/etc/ssh" -> ["/etc/ssh", "/resolved/etc/ssh"]
        path -> [path]
      end

      profile = MacOS.generate_profile("/some/cwd", nil, alias_fun: alias_fun)

      # Credential carveouts carry both filters for BOTH spellings, for reads…
      assert_emitted_right_after(
        profile,
        credential_deny_rule("file-read*", ssh),
        credential_deny_rule("file-read*", resolved_ssh)
      )

      # …and for writes.
      assert_emitted_right_after(
        profile,
        credential_deny_rule("file-write*", ssh),
        credential_deny_rule("file-write*", resolved_ssh)
      )

      # The system-level deny list follows the same wiring (subpath-only shape).
      assert_emitted_right_after(
        profile,
        ~s{(deny file-read* (subpath "/etc/ssh"))},
        ~s{(deny file-read* (subpath "/resolved/etc/ssh"))}
      )

      # The logical deny is still emitted, and the untouched sibling spelling is
      # not duplicated.
      assert profile =~ credential_deny_rule("file-read*", ssh)
      refute profile =~ credential_deny_rule("file-read*", "/private/resolved" <> ssh)
    end

    test "emits a read rule for an injected host_tmpdir" do
      profile = MacOS.generate_profile("/some/cwd", nil, host_tmpdir: "/var/folders/ab/T")

      assert profile =~ ~s{(allow file-read* (subpath "/var/folders/ab/T"))}
    end

    test "host_tmpdir: nil suppresses the host tmp read rule the ambient $TMPDIR would emit" do
      save_tmpdir()

      ambient =
        Path.join(System.tmp_dir!(), "evogit_host_tmp_#{System.unique_integer([:positive])}")

      File.mkdir_p!(ambient)
      on_exit(fn -> File.rm_rf!(ambient) end)
      System.put_env("TMPDIR", ambient)

      # The seam WINS over the environment: an explicit nil means "no rule".
      refute MacOS.generate_profile("/some/cwd", nil, host_tmpdir: nil) =~
               ~s{(allow file-read* (subpath "#{ambient}"))}

      # …and the default (absent option) reads the ambient $TMPDIR and emits it.
      assert MacOS.generate_profile("/some/cwd", nil) =~
               ~s{(allow file-read* (subpath "#{ambient}"))}
    end

    test "emits an injected host_tmpdir's resolved spelling too" do
      alias_fun = fn
        "/var/folders/ab/T" -> ["/var/folders/ab/T", "/private/var/folders/ab/T"]
        path -> [path]
      end

      profile =
        MacOS.generate_profile("/some/cwd", nil,
          host_tmpdir: "/var/folders/ab/T",
          alias_fun: alias_fun
        )

      assert profile =~ ~s{(allow file-read* (subpath "/private/var/folders/ab/T"))}

      assert_emitted_right_after(
        profile,
        ~s{(allow file-read* (subpath "/var/folders/ab/T"))},
        ~s{(allow file-read* (subpath "/private/var/folders/ab/T"))}
      )
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

    test "emits the fcntl deny rule exactly once, between the credential group and the limit" do
      profile = MacOS.generate_profile("/some/cwd", nil)
      fcntl = "(deny system-fcntl (fcntl-command 80 110))"

      assert length(Regex.scan(~r/\(deny system-fcntl \(fcntl-command 80 110\)\)/, profile)) ==
               1

      # Position: after the LAST deny-write credential rule and before the
      # process-count limit.
      last_credential_write =
        credential_deny_rule("file-write*", Path.join(System.user_home!(), ".gem"))

      assert_emitted_right_after(profile, last_credential_write, fcntl)
      assert_emitted_right_after(profile, fcntl, "(limit number 200)")
    end

    test "the cached rejection strips the fcntl deny AND the process-count limit" do
      :persistent_term.put({EvoGit.Sandbox.MacOS, :process_limit_rejected}, true)

      # The degraded retry path: both UNVERIFIED rules are gone, everything else
      # (the credential carveouts, the structural grants) is preserved verbatim.
      degraded = MacOS.effective_profile("/some/cwd", nil)

      refute degraded =~ "(deny system-fcntl"
      refute degraded =~ "(limit "
      refute degraded =~ "(limit number 200)"

      assert degraded =~
               credential_deny_rule("file-read*", Path.join(System.user_home!(), ".ssh"))

      assert degraded =~ ~s{(allow file-write* (subpath "/tmp"))}
      assert degraded =~ "(allow network*)"

      # The full profile keeps both: only `effective_profile/2` strips.
      full = MacOS.generate_profile("/some/cwd", nil)
      assert full =~ "(deny system-fcntl (fcntl-command 80 110))"
      assert full =~ "(limit number 200)"
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
      assert_tmpdir_falls_back(File.cwd!())
    end

    test "returns the installed per-task tmpdir directly, bypassing the legacy fallback" do
      save_tmpdir()
      # Point $TMPDIR at the repo worktree (outside every tmp path) so the
      # LEGACY resolution would return the first platform tmp path — proving
      # the installed per-task dir wins outright.
      System.put_env("TMPDIR", File.cwd!())
      task_tmp = per_task_tmpdir!()

      assert Sandbox.resolve_tmpdir() == task_tmp
    end

    test "falls back to the legacy resolution when no per-task tmpdir is installed" do
      save_tmpdir()
      System.delete_env("TMPDIR")
      TaskTmpdir.put_current(nil)

      assert Sandbox.resolve_tmpdir() == List.first(Platform.tmp_paths())
    end
  end

  describe "run/4 — disabled path exports the managed per-task tmpdir" do
    # Force the sandbox mode to `disabled` (via the isolated XDG config) so
    # `run/4` reliably takes the non-sandboxed `bash -c` path on EVERY host —
    # including real macOS, where the `:auto` mode would select sandbox-exec.
    setup do
      genesis_dir = Path.join(System.get_env("XDG_CONFIG_HOME"), "genesis")
      File.mkdir_p!(genesis_dir)
      File.write!(Path.join(genesis_dir, "config.toml"), "[sandbox]\nmode = \"disabled\"\n")
      EvoGit.Config.Cache.reload()
      on_exit(fn -> File.rm_rf!(genesis_dir) end)
      :ok
    end

    test "the spawned command sees TMPDIR/TMP/TEMP = the installed per-task dir" do
      assert MacOS.enabled?() == false

      dir = per_task_tmpdir!()
      on_exit(fn -> TaskTmpdir.put_current(nil) end)

      for var <- ["TMPDIR", "TMP", "TEMP"] do
        {output, 0} = MacOS.run(System.tmp_dir!(), "bash", ["-c", "printf %s \"$#{var}\""])

        assert output == dir
      end
    end

    test "no per-task dir installed → the managed dir is not injected" do
      assert TaskTmpdir.current() == nil

      {output, 0} = MacOS.run(System.tmp_dir!(), "bash", ["-c", "printf %s \"$TMPDIR\""])

      assert output == (System.get_env("TMPDIR") || "")
    end
  end

  # `System.put_env/2` mutates the VM-global OS env and
  # `EvoGit.Sandbox.resolve_tmpdir/0` reads $TMPDIR fresh at call time, so
  # under parallel load the put_env -> read pair can be observed
  # inconsistently. Re-establish TMPDIR and re-read on each attempt, with a
  # bounded retry (<= ~50 attempts, ~10 ms apart). The assertion stays exactly
  # as strong: the observed value must equal the first platform tmp path.
  defp assert_tmpdir_falls_back(tmpdir, attempts \\ 50) do
    System.put_env("TMPDIR", tmpdir)
    expected = List.first(Platform.tmp_paths())
    observed = Sandbox.resolve_tmpdir()

    cond do
      observed == expected ->
        :ok

      attempts <= 1 ->
        flunk(
          "resolve_tmpdir/0 did not fall back to the first platform tmp path " <>
            "(#{inspect(expected)}) for TMPDIR=#{inspect(tmpdir)} after 50 attempts; " <>
            "last observed value: #{inspect(observed)}"
        )

      true ->
        Process.sleep(10)
        assert_tmpdir_falls_back(tmpdir, attempts - 1)
    end
  end
end
