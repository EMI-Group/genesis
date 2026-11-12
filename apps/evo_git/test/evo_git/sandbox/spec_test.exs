defmodule EvoGit.Sandbox.SpecTest do
  # `async: true` because the module touches NO BEAM-global state: every input
  # goes through `Spec.build/2`'s injection seams (`:cwd`, `:repo_root`,
  # `:home`, `:tmp_paths`, `:task_tmpdir`, `:write_paths`, `:nix_enabled?`,
  # `:config_dir`, `:data_dir`, `:host_tmpdir`, `:network`, `:max_processes`,
  # `:git_metadata`), so nothing here mutates or depends on the OS env, the app
  # env, `:persistent_term` or the user's config.toml.
  use ExUnit.Case, async: true

  alias EvoGit.Sandbox.Spec

  @moduletag :tmp_dir

  # Injected home: every home-relative rule is anchored here, so no assertion
  # depends on the real user's home directory.
  @home "/spec/home"

  # THE canonical ordered credential deny list, mirrored from
  # `lib/evo_git/sandbox/spec.ex` so a change to it fails loudly.
  @canonical_credentials [
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

  # THE canonical ordered default cache dirs, mirrored from the same module.
  @canonical_cache_dirs [
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

  # Builds a spec from an explicitly injected baseline so no test ever reads
  # the ambient env/config, then applies `extra` (which always wins).
  defp build(backend, ctx, extra \\ []) do
    Spec.build(
      backend,
      Keyword.merge(
        [
          cwd: ctx.tmp_dir,
          home: @home,
          write_paths: nil,
          tmp_paths: ["/spec/tmp"],
          task_tmpdir: nil,
          nix_enabled?: false,
          config_dir: "/spec/config",
          data_dir: "/spec/data",
          host_tmpdir: nil
        ],
        extra
      )
    )
  end

  # Mirrors what `git worktree add` writes: the main repo carries a `.git`
  # DIRECTORY, the linked worktree's `.git` is a pointer FILE into
  # `<main>/.git/worktrees/<name>`.
  defp linked_worktree!(root) do
    main = Path.join(root, "main")
    worktree = Path.join(root, "wt1")

    File.mkdir_p!(Path.join(main, ".git/worktrees/wt1"))
    File.mkdir_p!(worktree)

    File.write!(
      Path.join(worktree, ".git"),
      "gitdir: #{Path.join(main, ".git/worktrees/wt1")}\n"
    )

    {main, worktree}
  end

  describe "build/2 — backend shapes" do
    test "builds a macOS spec", ctx do
      spec = build(:macos, ctx, host_tmpdir: "/var/folders/xy/T")

      assert %Spec{backend: :macos} = spec
      assert spec.cwd == ctx.tmp_dir
      assert spec.read_roots == ["/"]
      assert spec.write_roots == [ctx.tmp_dir]
      assert spec.max_processes == 200
      assert spec.host_tmpdir == "/var/folders/xy/T"

      # The vendored-git read rule exists only when git is NOT on PATH, so
      # only the SHAPE is pinned here — never the host-specific value.
      assert is_nil(spec.git_binary_dir) or is_binary(spec.git_binary_dir)

      # macOS-only content: system credential stores are denied for read, and
      # the two SSH host-verification files get read-only carveouts.
      assert spec.deny_paths != []

      assert spec.read_only_subpaths == [
               Path.join(@home, ".ssh/known_hosts"),
               Path.join(@home, ".ssh/config")
             ]

      assert spec.resources == %{}
    end

    test "builds a linux spec", ctx do
      spec = build(:linux, ctx)

      assert %Spec{backend: :linux} = spec
      assert spec.cwd == ctx.tmp_dir
      assert spec.read_roots == ["/"]
      assert spec.write_roots == [ctx.tmp_dir]
      assert spec.max_processes == 200
      assert spec.host_tmpdir == nil
      assert spec.git_binary_dir == nil
      assert spec.deny_paths == []
      assert spec.read_only_subpaths == []
      assert spec.resources == %{}
    end

    test "builds a bwrap spec", ctx do
      spec = build(:bwrap, ctx)

      assert %Spec{backend: :bwrap} = spec
      assert spec.max_processes == 200
      assert spec.host_tmpdir == nil
      assert spec.git_binary_dir == nil
      assert spec.deny_paths == []
      assert spec.read_only_subpaths == []
    end
  end

  describe "build/2 — inputs" do
    test ":cwd is required" do
      assert_raise KeyError, fn -> Spec.build(:linux, []) end
    end

    test "carries an explicit repo_root through unchanged", ctx do
      assert build(:bwrap, ctx, repo_root: "/spec/repo").repo_root == "/spec/repo"
      assert build(:bwrap, ctx).repo_root == nil
    end

    test "config_dir/data_dir are carried through verbatim", ctx do
      spec = build(:linux, ctx)

      assert spec.config_dir == "/spec/config"
      assert spec.data_dir == "/spec/data"
    end

    test "nix_enabled?: true yields the two nix paths", ctx do
      assert build(:macos, ctx, nix_enabled?: true).nix_paths == ["/nix/store", "/nix/var"]
      assert build(:bwrap, ctx, nix_enabled?: true).nix_paths == ["/nix/store", "/nix/var"]
    end

    test "nix_enabled?: false yields no nix paths", ctx do
      assert build(:linux, ctx, nix_enabled?: false).nix_paths == []
    end

    test "network defaults to :allow and can be injected", ctx do
      assert build(:linux, ctx).network == :allow
      assert build(:linux, ctx, network: :deny).network == :deny
    end

    test "max_processes defaults to 200 and can be injected", ctx do
      assert build(:macos, ctx).max_processes == 200
      assert build(:bwrap, ctx, max_processes: 42).max_processes == 42
    end
  end

  describe "build/2 — write_paths cache dirs" do
    test "write_paths: nil resolves to the 13 canonical default cache dirs under home", ctx do
      spec = build(:linux, ctx, write_paths: nil)

      assert spec.cache_write_paths == Enum.map(@canonical_cache_dirs, &Path.join(@home, &1))
    end

    test "write_paths: [] replaces the defaults with nothing", ctx do
      assert build(:linux, ctx, write_paths: []).cache_write_paths == []
    end

    test "write_paths expands ~ to the injected home and keeps absolute paths", ctx do
      spec = build(:linux, ctx, write_paths: ["~/mycache", "/abs/cache", "relative-cache"])

      assert spec.cache_write_paths == [
               Path.join(@home, "mycache"),
               "/abs/cache",
               Path.join(@home, "relative-cache")
             ]
    end

    test "a non-list write_paths never raises and degrades to the defaults", ctx do
      assert build(:linux, ctx, write_paths: "/not-a-list").cache_write_paths ==
               Enum.map(@canonical_cache_dirs, &Path.join(@home, &1))
    end
  end

  describe "canonical lists" do
    test "credential_paths/0 is the canonical 12, in canonical order" do
      assert Spec.credential_paths() == @canonical_credentials
      assert length(Spec.credential_paths()) == 12
    end

    test "credential_paths/0 excludes the macOS-only Library/Keychains entry" do
      refute "Library/Keychains" in Spec.credential_paths()
    end

    test "default_cache_dirs/0 is the canonical 13, in canonical order" do
      assert Spec.default_cache_dirs() == @canonical_cache_dirs
      assert length(Spec.default_cache_dirs()) == 13
    end

    test "backends/0 lists the three rendered backends" do
      assert Spec.backends() == [:macos, :linux, :bwrap]
    end
  end

  describe "build/2 — absolute path groups" do
    test "credential_deny_paths joins the canonical list to the INJECTED home", ctx do
      spec = build(:macos, ctx)

      assert spec.credential_paths == @canonical_credentials

      assert spec.credential_deny_paths ==
               Enum.map(@canonical_credentials, &Path.join(@home, &1))

      assert spec.deny_write_paths == spec.credential_deny_paths
    end

    test "every emitted path group is absolute", ctx do
      spec = build(:macos, ctx)

      groups = [
        spec.credential_deny_paths,
        spec.cache_write_paths,
        spec.deny_write_paths,
        spec.deny_paths,
        spec.read_roots,
        spec.write_roots,
        spec.tmp_paths
      ]

      for group <- groups, path <- group do
        assert Path.type(path) == :absolute, "expected an absolute path, got: #{inspect(path)}"
      end
    end
  end

  describe "build/2 — missing paths" do
    test "a non-existent tmp_paths/cache path passes through verbatim without raising", ctx do
      spec =
        build(:linux, ctx,
          tmp_paths: ["/spec/missing-tmp"],
          write_paths: ["/spec/missing-cache"]
        )

      refute File.exists?("/spec/missing-tmp")
      refute File.exists?("/spec/missing-cache")

      assert spec.tmp_paths == ["/spec/missing-tmp"]
      assert spec.cache_write_paths == ["/spec/missing-cache"]
    end

    test "task_tmpdir: nil stays nil", ctx do
      assert build(:linux, ctx, task_tmpdir: nil).task_tmpdir == nil
    end

    test "a non-existent task tmpdir passes through verbatim", ctx do
      assert build(:macos, ctx, task_tmpdir: "/spec/missing-task").task_tmpdir ==
               "/spec/missing-task"
    end

    for backend <- [:macos, :linux, :bwrap] do
      test "host_tmpdir: nil stays nil on #{backend}", ctx do
        assert build(unquote(backend), ctx, host_tmpdir: nil).host_tmpdir == nil
      end
    end
  end

  describe "build/2 — git metadata resolution" do
    test "resolves a linked-worktree pointer to the COMMON git dir (repo_root: nil)", ctx do
      {main, worktree} = linked_worktree!(ctx.tmp_dir)

      assert build(:bwrap, ctx, cwd: worktree).git_metadata_dir == Path.join(main, ".git")
    end

    test "resolves the COMMON git dir when repo_root is the worktree itself", ctx do
      {main, worktree} = linked_worktree!(ctx.tmp_dir)

      assert build(:linux, ctx, cwd: worktree, repo_root: worktree).git_metadata_dir ==
               Path.join(main, ".git")
    end

    test "resolves the COMMON git dir for a cwd nested inside the worktree", ctx do
      {main, worktree} = linked_worktree!(ctx.tmp_dir)
      nested = Path.join(worktree, "src/deep")

      assert build(:macos, ctx, cwd: nested, repo_root: worktree).git_metadata_dir ==
               Path.join(main, ".git")
    end

    test "a plain repo root resolves to <repo_root>/.git", ctx do
      main = Path.join(ctx.tmp_dir, "plain-repo")
      File.mkdir_p!(Path.join(main, ".git"))

      assert build(:bwrap, ctx, cwd: main, repo_root: main).git_metadata_dir ==
               Path.join(main, ".git")
    end

    test "repo_root: nil in a plain dir with no .git yields nil", ctx do
      plain = Path.join(ctx.tmp_dir, "plain-dir")
      File.mkdir_p!(plain)

      assert build(:macos, ctx, cwd: plain, repo_root: nil).git_metadata_dir == nil
    end

    test "git_metadata: overrides the default resolution", ctx do
      {_main, worktree} = linked_worktree!(ctx.tmp_dir)

      assert build(:linux, ctx, cwd: worktree, git_metadata: "/spec/pinned/gitdir").git_metadata_dir ==
               "/spec/pinned/gitdir"

      assert build(:linux, ctx, cwd: worktree, git_metadata: ["/spec/pinned/gitdir"]).git_metadata_dir ==
               "/spec/pinned/gitdir"

      assert build(:linux, ctx, cwd: worktree, git_metadata: nil).git_metadata_dir == nil
    end
  end

  describe "resolve_alias/2 — system aliases (root: fixture seam)" do
    # A fixture tree standing in for "/" (the documented `:root` TEST SEAM), so
    # the one-hop resolution is exercised without touching the host's own
    # symlinks: `/tmp` -> `private/tmp` (relative target), `/abs` -> an
    # absolute target, `/real` a plain dir and `/nested` -> `inner` where
    # `inner` is ITSELF a symlink (resolution would nest -> refused).
    setup %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      File.mkdir_p!(Path.join(root, "private/tmp"))
      File.mkdir_p!(Path.join(root, "real"))
      File.mkdir_p!(Path.join(root, "deep"))
      File.ln_s!("private/tmp", Path.join(root, "tmp"))
      File.ln_s!("/absolute/target", Path.join(root, "abs"))
      File.ln_s!("inner", Path.join(root, "nested"))
      File.ln_s!("deep", Path.join(root, "inner"))

      %{root: root}
    end

    test "resolves a RELATIVE link target and keeps the suffix", %{root: root} do
      assert Spec.resolve_alias("/tmp/agent", root: root) == Path.join(root, "private/tmp/agent")
    end

    test "resolves the top-level component alone (no suffix)", %{root: root} do
      assert Spec.resolve_alias("/tmp", root: root) == Path.join(root, "private/tmp")
    end

    test "keeps an ABSOLUTE link target as-is and appends the suffix", %{root: root} do
      assert Spec.resolve_alias("/abs/agent", root: root) == "/absolute/target/agent"
    end

    test "a non-symlink component yields nil", %{root: root} do
      assert is_nil(Spec.resolve_alias("/real/agent", root: root))
    end

    test "a missing component yields nil", %{root: root} do
      assert is_nil(Spec.resolve_alias("/missing/agent", root: root))
    end

    test "refuses a NESTED alias (the resolved component is itself a symlink)", %{root: root} do
      assert is_nil(Spec.resolve_alias("/nested/agent", root: root))
    end

    test "a relative input or the bare root yields nil", %{root: root} do
      assert is_nil(Spec.resolve_alias("tmp/agent", root: root))
      assert is_nil(Spec.resolve_alias("/", root: root))
    end

    test "is TOTAL: a non-binary path, a blank/nil/absent root never raise", %{root: root} do
      assert is_nil(Spec.resolve_alias(nil, root: root))
      assert is_nil(Spec.resolve_alias("/tmp/agent", root: ""))
      assert is_nil(Spec.resolve_alias("/tmp/agent", root: nil))
      # The default root is "/" — a fixture path never resolves through it.
      assert is_nil(Spec.resolve_alias("/evogit-spec-no-such-top/agent"))
    end
  end

  describe "aliases/1" do
    test "pairs every path with its resolved spelling, logical first" do
      # `aliases/1` always resolves against the REAL "/" (it has no root seam),
      # so the pin is expressed against `resolve_alias/2` itself: the logical
      # spelling first, then the resolved one — or the identity pair when the
      # top-level component is not a symlink. The probes cover a nonexistent
      # top level (always identity here) plus the host's own top-level
      # symlinks (macOS: /tmp, /var, /etc; merged-usr Linux: /bin, /lib).
      probes = [
        "/evogit-spec-no-such-top-#{System.unique_integer([:positive])}/file",
        "/tmp/evogit-spec-alias-probe",
        "/etc/evogit-spec-alias-probe",
        "/var/evogit-spec-alias-probe"
      ]

      for probe <- probes do
        case Spec.resolve_alias(probe) do
          nil -> assert Spec.aliases(probe) == [probe]
          resolved -> assert Spec.aliases(probe) == [probe, resolved]
        end
      end

      # Total for a non-binary input: the identity form, never a raise.
      assert Spec.aliases(nil) == [nil]
    end
  end
end
