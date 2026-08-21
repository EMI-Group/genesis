defmodule EvoGit.SelfReflectiveSourceTest do
  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.State
  alias EvoGit.Core.ContextNode
  alias EvoGit.Runtime.SelfReflective
  alias EvoGit.SelfReflectiveSource

  # The four env knobs (:self_reflective_source_root / :self_reflective_source_dir /
  # :self_reflective_source_url app env + GENESIS_SOURCE_ROOT OS env) are global
  # state; the setup hook restores them after every test so nothing leaks into
  # the real data dir or other tests.
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
      fixture = genesis_fixture!("chain-app")
      set_app_env(:self_reflective_source_dir, fixture.work)
      set_os_env("/tmp/from-env-var")
      set_app_env(:self_reflective_source_root, "/tmp/from-app-env")

      assert SelfReflectiveSource.reference_path() == "/tmp/from-app-env"
    end

    test "GENESIS_SOURCE_ROOT wins over the managed dir" do
      fixture = genesis_fixture!("chain-env")
      set_app_env(:self_reflective_source_dir, fixture.work)
      set_os_env("/tmp/from-env-var")

      assert SelfReflectiveSource.reference_path() == "/tmp/from-env-var"
    end

    test "managed dir is auto-selected when present and valid" do
      fixture = genesis_fixture!("chain-managed")
      set_app_env(:self_reflective_source_dir, fixture.work)

      assert SelfReflectiveSource.reference_path() == fixture.work
    end

    test "managed dir is NOT auto-selected when present but invalid (no CONTEXT.md)" do
      dir = tmp_path!("invalid")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, _} = Git.init(dir)
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

  # --- Helpers -------------------------------------------------------------

  defp tmp_path!(label) do
    Path.join(System.tmp_dir!(), "selfref-src-#{label}-#{System.unique_integer([:positive])}")
  end

  # Builds a "mini Genesis-like" fixture: a working repo with CONTEXT.md +
  # VERSION committed and pushed to a BARE origin (so updates can push). The
  # bare repo's HEAD is pinned to the pushed branch so clones resolve
  # origin/HEAD deterministically regardless of the machine's default branch.
  defp genesis_fixture!(label) do
    work = tmp_path!(label <> "-work")
    origin = tmp_path!(label <> "-origin")
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
