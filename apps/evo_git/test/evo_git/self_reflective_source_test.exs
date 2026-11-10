defmodule EvoGit.SelfReflectiveSourceTest do
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.State
  alias EvoGit.Core.ContextNode
  alias EvoGit.Runtime.SelfReflective
  alias EvoGit.SelfReflectiveSource
  alias EvoGit.VCT
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Table

  import EvoGit.VCTTest.Helpers

  # The BEAM-global knobs this module writes are the `:self_reflective_source_root`
  # / `:self_reflective_source_dir` / `:self_reflective_source_url` app env, the
  # `GENESIS_SOURCE_ROOT` OS env, and the `:evogit_vct_server` process-dictionary
  # VCT seam (each test points at its OWN isolated VCT stack, so the app-global
  # singleton is never relied on). The setup hook restores the env knobs after
  # every test so nothing leaks into the real data dir or other tests; the
  # process dictionary dies with each test process.
  setup do
    original = %{
      source_root: Application.get_env(:evo_git, :self_reflective_source_root),
      source_dir: Application.get_env(:evo_git, :self_reflective_source_dir),
      source_url: Application.get_env(:evo_git, :self_reflective_source_url),
      env_var: System.get_env("GENESIS_SOURCE_ROOT")
    }

    on_exit(fn ->
      restore_app_env(:self_reflective_source_root, original.source_root)
      restore_app_env(:self_reflective_source_dir, original.source_dir)
      restore_app_env(:self_reflective_source_url, original.source_url)
      restore_os_env(original.env_var)
    end)

    :ok
  end

  describe "status/0" do
    test "never raises on a missing dir" do
      set_app_env(:self_reflective_source_dir, tmp_path!("missing"))

      status = SelfReflectiveSource.status()

      refute status.exists
      refute status.is_git_repo
      refute status.valid
      assert status.commit == nil
      assert status.branch == nil
      assert status.version == nil
      assert status.remote_url == nil
      assert status.reference == nil
      refute status.is_reference
    end

    test "never raises on a non-git dir" do
      dir = tmp_path!("plain")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      set_app_env(:self_reflective_source_dir, dir)

      status = SelfReflectiveSource.status()

      assert status.exists
      refute status.is_git_repo
      refute status.valid
      assert status.commit == nil
      assert status.branch == nil
      assert status.version == nil
      assert status.remote_url == nil
      assert status.reference == nil
      refute status.is_reference
    end

    test "never raises on a git dir without CONTEXT.md (partial checkout)" do
      dir = tmp_path!("partial")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, _} = Git.init(dir)
      File.write!(Path.join(dir, "VERSION"), "9.9.9\n")
      {:ok, _} = Git.add(dir, ".")
      {:ok, _} = Git.commit(dir, "commit")
      set_app_env(:self_reflective_source_dir, dir)

      status = SelfReflectiveSource.status()

      assert status.exists
      assert status.is_git_repo
      refute status.valid
      assert is_binary(status.commit)
      assert is_binary(status.branch)
      assert status.version == "9.9.9"
      assert status.reference == nil
      refute status.is_reference
    end
  end

  describe "clone/0" do
    test "shallow-clones the fixture and reports a full status" do
      fixture = genesis_fixture!("clone")
      clone_dir = tmp_path!("clone-dir")
      set_app_env(:self_reflective_source_dir, clone_dir)
      set_app_env(:self_reflective_source_url, fixture.origin)
      on_exit(fn -> File.rm_rf!(clone_dir) end)

      assert {:ok, status} = SelfReflectiveSource.clone()

      assert status.dir == clone_dir
      assert status.exists
      assert status.is_git_repo
      assert status.valid
      assert status.commit == short_sha(fixture.work)
      assert status.branch == fixture.branch
      assert status.version == "0.0.0"
      assert status.remote_url == fixture.origin
      assert status.reference == clone_dir
      assert status.is_reference
    end

    test "returns {:error, :already_cloned} when the dir already exists" do
      dir = tmp_path!("exists")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      set_app_env(:self_reflective_source_dir, dir)

      assert {:error, :already_cloned} = SelfReflectiveSource.clone()
    end
  end

  describe "update/0" do
    test "fast-forwards the clone after a new commit is pushed to origin" do
      fixture = genesis_fixture!("update")
      clone_dir = tmp_path!("update-dir")
      set_app_env(:self_reflective_source_dir, clone_dir)
      set_app_env(:self_reflective_source_url, fixture.origin)
      on_exit(fn -> File.rm_rf!(clone_dir) end)

      assert {:ok, _} = SelfReflectiveSource.clone()

      # New commit pushed to the bare origin.
      File.write!(Path.join(fixture.work, "VERSION"), "0.1.0\n")
      {:ok, _} = Git.add(fixture.work, "VERSION")
      {:ok, _} = Git.commit(fixture.work, "Second commit")
      {:ok, _} = Git.push_branch(fixture.work, fixture.branch)

      assert {:ok, status} = SelfReflectiveSource.update()

      assert status.commit == short_sha(fixture.work)
      assert status.version == "0.1.0"
      assert status.valid
      assert status.is_reference
    end

    test "returns {:error, :not_cloned} when the dir is missing" do
      set_app_env(:self_reflective_source_dir, tmp_path!("missing"))

      assert {:error, :not_cloned} = SelfReflectiveSource.update()
    end

    test "returns {:error, :not_a_git_repo} when the dir exists but is not git" do
      dir = tmp_path!("plain")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      set_app_env(:self_reflective_source_dir, dir)

      assert {:error, :not_a_git_repo} = SelfReflectiveSource.update()
    end
  end

  describe "reference_path/0 chain precedence" do
    test "app env wins over the env var and a valid managed dir" do
      dir = managed_dir_fixture!("chain-app")
      set_app_env(:self_reflective_source_dir, dir)
      set_os_env("/tmp/from-env-var")
      set_app_env(:self_reflective_source_root, "/tmp/from-app-env")

      assert SelfReflectiveSource.reference_path() == "/tmp/from-app-env"
    end

    test "GENESIS_SOURCE_ROOT wins over the managed dir" do
      dir = managed_dir_fixture!("chain-env")
      set_app_env(:self_reflective_source_dir, dir)
      set_os_env("/tmp/from-env-var")

      assert SelfReflectiveSource.reference_path() == "/tmp/from-env-var"
    end

    test "managed dir is auto-selected when present and valid" do
      dir = managed_dir_fixture!("chain-managed")
      set_app_env(:self_reflective_source_dir, dir)

      assert SelfReflectiveSource.reference_path() == dir
    end

    test "managed dir is NOT auto-selected when present but invalid (no CONTEXT.md)" do
      dir = tmp_path!("invalid")
      File.mkdir_p!(Path.join(dir, ".git"))
      on_exit(fn -> File.rm_rf!(dir) end)
      set_app_env(:self_reflective_source_dir, dir)

      assert SelfReflectiveSource.reference_path() == nil
    end

    test "nil when nothing else is set" do
      set_app_env(:self_reflective_source_dir, tmp_path!("nothing"))

      assert SelfReflectiveSource.reference_path() == nil
    end
  end

  describe "chain delegate equivalence" do
    test "Runtime.SelfReflective.source_root/0 returns the reference path when set" do
      set_app_env(:self_reflective_source_root, "/tmp/from-app-env")

      assert SelfReflective.source_root() == SelfReflectiveSource.reference_path()
      assert SelfReflective.source_root() == "/tmp/from-app-env"
    end

    test "Runtime.SelfReflective.source_root/0 falls back to File.cwd!() when reference is nil" do
      set_app_env(:self_reflective_source_dir, tmp_path!("nothing"))

      assert SelfReflectiveSource.reference_path() == nil
      assert SelfReflective.source_root() == File.cwd!()
    end

    test "Dispatch.resolve_agent_repo_root/2 mirrors the reference path" do
      set_app_env(:self_reflective_source_root, "/tmp/from-app-env")

      assert Dispatch.resolve_agent_repo_root(repo_less_spec(), %State{}) == "/tmp/from-app-env"
    end

    test "Dispatch.resolve_agent_repo_root/2 returns a binary when all knobs are absent" do
      # The "[system]" fallback only triggers when File.cwd!() itself returns
      # nil, which never happens in tests — assert the practical File.cwd!()
      # middle step instead.
      set_app_env(:self_reflective_source_dir, tmp_path!("nothing"))

      assert SelfReflectiveSource.reference_path() == nil
      assert Dispatch.resolve_agent_repo_root(repo_less_spec(), %State{}) == File.cwd!()
    end
  end

  describe "available?/0" do
    test "true when the app-env override points at a valid checkout" do
      dir = managed_dir_fixture!("avail-app")
      set_app_env(:self_reflective_source_root, dir)

      assert SelfReflectiveSource.available?()
    end

    test "false when the app-env override points at a non-existent dir" do
      set_app_env(:self_reflective_source_root, tmp_path!("avail-missing"))

      refute SelfReflectiveSource.available?()
    end

    test "false when the OS-env override points at a dir without CONTEXT.md" do
      dir = tmp_path!("avail-env-plain")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      set_os_env(dir)

      refute SelfReflectiveSource.available?()
    end

    test "true when a valid managed clone is present" do
      dir = managed_dir_fixture!("avail-managed")
      set_app_env(:self_reflective_source_dir, dir)

      assert SelfReflectiveSource.reference_path() == dir
      assert SelfReflectiveSource.available?()
    end

    test "falls back to cwd when no source is configured" do
      set_app_env(:self_reflective_source_dir, tmp_path!("avail-nothing"))

      assert SelfReflectiveSource.reference_path() == nil
      # Under `mix test` the cwd is the umbrella repo root, which carries a
      # CONTEXT.md — the File.cwd!() fallback therefore resolves to `true`.
      assert File.regular?(Path.join(File.cwd!(), "CONTEXT.md"))
      assert SelfReflectiveSource.available?()
    end
  end

  describe "VCT integration" do
    test "point/0 is the canonical reserved point" do
      assert SelfReflectiveSource.point() == "vct:///genesis-source"

      assert {:ok, %VctPath{segments: ["genesis-source"]}} =
               VctPath.parse(SelfReflectiveSource.point())

      assert VctPath.format(VctPath.parse!(SelfReflectiveSource.point())) ==
               "vct:///genesis-source"
    end

    test "system_mounts/0 declares the reserved mount for source_dir/0" do
      dir = tmp_path!("system-mount")
      set_app_env(:self_reflective_source_dir, dir)

      assert SelfReflectiveSource.system_mounts() == [
               %{point: "vct:///genesis-source", path: dir, name: "genesis-source"}
             ]
    end

    test "ensure_mount/0 registers the reserved mount on a fresh isolated VCT" do
      dir = tmp_path!("ensure-mount")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      set_app_env(:self_reflective_source_dir, dir)
      stack = start_vct_stack!("ensure-mount")

      assert {:ok, mount} = SelfReflectiveSource.ensure_mount()
      assert mount.point == "vct:///genesis-source"
      assert mount.name == "genesis-source"
      assert Table.comparison_form(mount.path) == Table.comparison_form(dir)
      assert_test_mount(stack, dir)
    end

    test "ensure_mount/0 is idempotent (one mount row, same point)" do
      dir = tmp_path!("ensure-idempotent")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      set_app_env(:self_reflective_source_dir, dir)
      stack = start_vct_stack!("ensure-idempotent")

      assert {:ok, first} = SelfReflectiveSource.ensure_mount()
      assert {:ok, second} = SelfReflectiveSource.ensure_mount()

      assert second.point == first.point
      assert Table.comparison_form(second.path) == Table.comparison_form(dir)
      assert_test_mount(stack, dir)
    end

    test "ensure_mount/0 returns an error (never raises) when no VCT is reachable" do
      set_app_env(:self_reflective_source_dir, tmp_path!("ensure-no-vct"))
      # The app-global VCT may be running in this suite: deleting the seam then
      # falls back to it, so only totality is required here.
      Process.delete(:evogit_vct_server)

      result = SelfReflectiveSource.ensure_mount()

      if Process.whereis(EvoGit.VCT) do
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      else
        assert {:error, :vct_unavailable} = result
      end

      # A deterministic unreachable server: the PDA seam wins over the
      # registered singleton, so the VCT call must degrade, not raise.
      Process.put(:evogit_vct_server, :evogit_vct_absent_server)
      assert {:error, :vct_unavailable} = SelfReflectiveSource.ensure_mount()
      refute SelfReflectiveSource.status().mounted
    end

    test "clone/0 ensures the VCT mount after a successful clone" do
      fixture = genesis_fixture!("mount-clone")
      clone_dir = tmp_path!("mount-clone-dir")
      set_app_env(:self_reflective_source_dir, clone_dir)
      set_app_env(:self_reflective_source_url, fixture.origin)
      on_exit(fn -> File.rm_rf!(clone_dir) end)
      stack = start_vct_stack!("mount-clone")

      assert {:ok, _status} = SelfReflectiveSource.clone()

      assert_test_mount(stack, clone_dir)
      assert SelfReflectiveSource.status().mounted
    end

    test "update/0 ensures the VCT mount after a successful update" do
      fixture = genesis_fixture!("mount-update")
      clone_dir = tmp_path!("mount-update-dir")
      set_app_env(:self_reflective_source_dir, clone_dir)
      set_app_env(:self_reflective_source_url, fixture.origin)
      on_exit(fn -> File.rm_rf!(clone_dir) end)
      stack = start_vct_stack!("mount-update")

      assert {:ok, _} = SelfReflectiveSource.clone()

      File.write!(Path.join(fixture.work, "VERSION"), "0.2.0\n")
      {:ok, _} = Git.add(fixture.work, "VERSION")
      {:ok, _} = Git.commit(fixture.work, "Second commit")
      {:ok, _} = Git.push_branch(fixture.work, fixture.branch)

      assert {:ok, status} = SelfReflectiveSource.update()
      assert status.version == "0.2.0"

      assert_test_mount(stack, clone_dir)
    end

    test "status/0 exposes point/0 and the mounted flag" do
      dir = tmp_path!("status-mounted")
      File.mkdir_p!(dir)
      other = tmp_path!("status-other")
      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(dir) end)
      on_exit(fn -> File.rm_rf!(other) end)
      set_app_env(:self_reflective_source_dir, dir)
      start_vct_stack!("status-mounted")

      status = SelfReflectiveSource.status()
      assert status.point == "vct:///genesis-source"
      refute status.mounted

      assert {:ok, _} = SelfReflectiveSource.ensure_mount()
      assert SelfReflectiveSource.status().mounted

      # Re-pointing the mount elsewhere makes it no longer the managed dir.
      assert {:ok, _} = VCT.ensure_mount(SelfReflectiveSource.point(), other)
      refute SelfReflectiveSource.status().mounted
    end

    test "status/0 reports mounted: false and never raises without a VCT" do
      set_app_env(:self_reflective_source_dir, tmp_path!("status-no-vct"))
      Process.put(:evogit_vct_server, :evogit_vct_absent_server)

      status = SelfReflectiveSource.status()
      assert status.point == "vct:///genesis-source"
      refute status.mounted
    end

    test "a VCT mount pointing at a valid checkout wins over the managed dir" do
      # No `:self_reflective_source_dir` seam: `source_dir/0` is the default
      # managed dir, so the VCT step of the chain is active.
      managed = default_managed_dir_fixture!()
      checkout = valid_checkout_fixture!("vct-wins-checkout")
      start_vct_stack!("vct-wins")

      # No mount yet: the managed dir is the reference.
      assert SelfReflectiveSource.reference_path() == managed
      assert SelfReflectiveSource.status().is_reference

      assert {:ok, _} = VCT.ensure_mount(SelfReflectiveSource.point(), checkout)
      assert SelfReflectiveSource.reference_path() == checkout
      refute SelfReflectiveSource.status().is_reference

      # Re-pointing the mount back at the managed dir restores the reference.
      assert {:ok, _} = VCT.ensure_mount(SelfReflectiveSource.point(), managed)
      assert SelfReflectiveSource.reference_path() == managed
      assert SelfReflectiveSource.status().is_reference
    end

    test "the :self_reflective_source_dir seam bypasses the VCT step" do
      checkout = valid_checkout_fixture!("vct-bypass-checkout")
      start_vct_stack!("vct-bypass")
      assert {:ok, _} = VCT.ensure_mount(SelfReflectiveSource.point(), checkout)

      # Seam set to an INVALID managed dir: the VCT mount is ignored, so the
      # chain falls through to the managed dir and resolves to nil.
      invalid = tmp_path!("vct-bypass-invalid")
      File.mkdir_p!(invalid)
      on_exit(fn -> File.rm_rf!(invalid) end)
      set_app_env(:self_reflective_source_dir, invalid)
      assert SelfReflectiveSource.reference_path() == nil

      # Seam set to a VALID managed dir: it wins over the VCT mount.
      managed = managed_dir_fixture!("vct-bypass-managed")
      set_app_env(:self_reflective_source_dir, managed)
      assert SelfReflectiveSource.reference_path() == managed
    end
  end

  # --- Helpers -------------------------------------------------------------
  defp tmp_path!(label) do
    Path.join(System.tmp_dir!(), "selfref-src-#{label}-#{System.unique_integer([:positive])}")
  end

  # Boots an isolated Store + VCT pair (the shared `EvoGit.VCTTest.Helpers`
  # fixture) and removes its temp root on exit. `start_stack/2` points this
  # process at that VCT via the `:evogit_vct_server` seam.
  defp start_vct_stack!(label) do
    root = tmp_path!(label)
    stack = start_stack(root)
    on_exit(fn -> File.rm_rf!(root) end)
    stack
  end

  # Asserts the isolated stack holds EXACTLY ONE mount at the reserved point and
  # that it binds `dir` (both through the VCT and through the persisted table).
  defp assert_test_mount(stack, dir) do
    assert {:ok, resolved} = VCT.resolve(SelfReflectiveSource.point())
    assert resolved.point == "vct:///genesis-source"
    assert Table.comparison_form(resolved.path) == Table.comparison_form(dir)

    rows = EvoGit.Store.list_vct_mounts(stack.store)
    assert [row] = Enum.filter(rows, &(&1["point"] == "vct:///genesis-source"))
    assert Table.comparison_form(row["path"]) == Table.comparison_form(dir)
  end

  # The default managed dir (`Platform.data_dir()/genesis-source`) as a valid
  # checkout. Used by the VCT-precedence test, which must NOT set the
  # `:self_reflective_source_dir` seam (the seam skips the VCT step).
  defp default_managed_dir_fixture! do
    dir = Path.join(EvoGit.Platform.data_dir(), "genesis-source")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, "CONTEXT.md"), "# Fixture Genesis\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A real git checkout (git init + CONTEXT.md + one commit) — the validity rule
  # the VCT step applies is `.git` directory + root CONTEXT.md.
  defp valid_checkout_fixture!(label) do
    dir = tmp_path!(label)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {:ok, _} = Git.init(dir)
    File.write!(Path.join(dir, "CONTEXT.md"), "# Fixture Genesis\n")
    {:ok, _} = Git.add(dir, ".")
    {:ok, _} = Git.commit(dir, "Initial fixture commit")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Builds the MINIMUM "valid managed dir" the production resolution chain
  # recognizes: a plain temp dir carrying an empty `.git` DIRECTORY (all
  # `EvoGit.SelfReflectiveSource`'s private `git_repo?/1` checks) plus a
  # `CONTEXT.md` at the root (what `genesis_checkout?/1` checks). No git
  # subprocesses — real git fixtures are reserved for the clone/update/status
  # paths that actually shell out.
  defp managed_dir_fixture!(label) do
    dir = tmp_path!(label)
    # Defense-in-depth against crashed-run leaks (System.unique_integer/1 is
    # only unique per-VM): start from a known-empty dir.
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, "CONTEXT.md"), "# Fixture Genesis\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Builds a "mini Genesis-like" fixture: a working repo with CONTEXT.md +
  # VERSION committed and pushed to a BARE origin (so updates can push). The
  # bare repo's HEAD is pinned to the pushed branch so clones resolve
  # origin/HEAD deterministically regardless of the machine's default branch.
  defp genesis_fixture!(label) do
    work = tmp_path!(label <> "-work")
    origin = tmp_path!(label <> "-origin")
    # Defense-in-depth against crashed-run leaks: System.unique_integer/1 is
    # only unique per-VM, so a stale dir from an earlier run could collide with
    # this tmp_path — a stale origin holding old commits would reject the push.
    File.rm_rf!(work)
    File.rm_rf!(origin)
    File.mkdir_p!(work)
    {:ok, _} = Git.init(work)
    # The default branch name before any commit: `git symbolic-ref --short HEAD`
    # works on a fresh (commit-less) repo, unlike `current_branch/1` which
    # needs at least one commit.
    {:ok, branch} = Git.run(["symbolic-ref", "--short", "HEAD"], work)
    File.write!(Path.join(work, "CONTEXT.md"), "# Fixture Genesis\n")
    File.write!(Path.join(work, "VERSION"), "0.0.0\n")
    {:ok, _} = Git.add(work, ".")
    {:ok, _} = Git.commit(work, "Initial fixture commit")

    File.mkdir_p!(origin)
    {:ok, _} = Git.run(["init", "--bare"], origin)
    {:ok, _} = Git.run(["symbolic-ref", "HEAD", "refs/heads/#{branch}"], origin)
    {:ok, _} = Git.run(["remote", "add", "origin", origin], work)
    {:ok, _} = Git.push_branch(work, branch)

    on_exit(fn ->
      File.rm_rf!(work)
      File.rm_rf!(origin)
    end)

    %{work: work, origin: origin, branch: branch}
  end

  defp short_sha(repo) do
    {:ok, sha} = Git.rev_parse_short(repo, "HEAD")
    sha
  end

  defp repo_less_spec do
    AgentSpec.new(
      %ContextNode{path: "./", repo: "/tmp"},
      nil,
      EvoGit.Agents.SelfReflective,
      "x",
      repo_less: true
    )
  end

  defp set_app_env(key, value) do
    Application.put_env(:evo_git, key, value)
  end

  defp restore_app_env(key, value) do
    if value do
      Application.put_env(:evo_git, key, value)
    else
      Application.delete_env(:evo_git, key)
    end
  end

  defp set_os_env(value) do
    System.put_env("GENESIS_SOURCE_ROOT", value)
  end

  defp restore_os_env(value) do
    if value do
      System.put_env("GENESIS_SOURCE_ROOT", value)
    else
      System.delete_env("GENESIS_SOURCE_ROOT")
    end
  end
end
