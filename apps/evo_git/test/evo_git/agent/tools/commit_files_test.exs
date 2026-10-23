defmodule EvoGit.Agent.Tools.CommitFilesTest do
  @moduledoc """
  Regression tests for `EvoGit.Agent.Tools.Shared.commit_files/4` — the single
  stage+commit helper the tools now share (replacing the private
  `maybe_commit_context/5` + `commit_with_message_file/3` mechanisms).

  Pins the helper's contract:
    * stages ONLY the filtered paths it was given (never `git add --all`), so a
      dirty/untracked sibling stays out of the commit;
    * commits via `git commit -F <tmpfile>` and appends the co-author trailer
      only when `[:git, :co_authored_by_enabled] != false`;
    * names that tmpfile with the OS pid (`Shared.commit_message_file_path/0`)
      so concurrent BEAMs sharing one resolved tmpdir cannot collide;
    * treats an empty/blank file list and a nothing-staged commit as graceful
      no-ops (`{:ok, output}`), while a failed `git add` is `{:error, message}`.

  `async: false` — the tests redirect the process-wide `XDG_CONFIG_HOME`
  (read LIVE by `EvoGit.Config.config_path/0` → `EvoGit.Platform.config_dir/1`,
  with no app-env seam) and write config.toml through `EvoGit.Config`, which
  serializes this module against every other config reader.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Tools.Shared

  setup_all do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(
        System.tmp_dir!(),
        "evogit-commit-files-xdg-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)
    File.mkdir_p!(EvoGit.Config.config_dir())

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  setup do
    repo = new_repo!()
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  # ---------------------------------------------------------------------------
  # Stage-only-given-paths + success
  # ---------------------------------------------------------------------------

  test "stages only the given path and commits it, leaving the sibling untracked", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "a\n")
    File.write!(Path.join(repo, "b.txt"), "b\n")
    before = commit_count(repo)

    assert {:ok, _out} = Shared.commit_files(repo, repo, ["a.txt"], "Add a")

    assert commit_count(repo) == before + 1
    assert git!(repo, ["log", "-1", "--pretty=%s"]) == "Add a"
    assert git!(repo, ["ls-files", "a.txt"]) == "a.txt"
    # The untracked sibling was NOT swept into the commit.
    assert git!(repo, ["ls-files", "b.txt"]) == ""
    assert git!(repo, ["status", "--porcelain"]) =~ "?? b.txt"
    # Nothing was left staged.
    assert git!(repo, ["diff", "--cached", "--name-only"]) == ""
  end

  test "commits multiple given paths in one commit", %{repo: repo} do
    File.write!(Path.join(repo, "c.txt"), "c\n")
    File.write!(Path.join(repo, "d.txt"), "d\n")
    before = commit_count(repo)

    assert {:ok, _out} = Shared.commit_files(repo, repo, ["c.txt", "d.txt"], "Add c and d")

    assert commit_count(repo) == before + 1
    tracked = git!(repo, ["ls-files", "c.txt", "d.txt"]) |> String.split("\n", trim: true)
    assert Enum.sort(tracked) == ["c.txt", "d.txt"]
  end

  test "commits fine with a nil repo_root", %{repo: repo} do
    File.write!(Path.join(repo, "n.txt"), "n\n")
    before = commit_count(repo)

    assert {:ok, _out} = Shared.commit_files(repo, nil, ["n.txt"], "Add n")

    assert commit_count(repo) == before + 1
    assert git!(repo, ["ls-files", "n.txt"]) == "n.txt"
  end

  # ---------------------------------------------------------------------------
  # Graceful no-ops
  # ---------------------------------------------------------------------------

  test "an empty file list is a graceful no-op", %{repo: repo} do
    before = commit_count(repo)

    assert Shared.commit_files(repo, repo, [], "nothing") == {:ok, "No files to commit"}
    assert commit_count(repo) == before
  end

  test "blank/nil/non-binary entries filter down to a graceful no-op", %{repo: repo} do
    before = commit_count(repo)

    assert Shared.commit_files(repo, repo, ["", nil, :nope], "nothing") ==
             {:ok, "No files to commit"}

    assert commit_count(repo) == before
  end

  test "an unchanged file alongside an untracked sibling is a graceful no-op", %{repo: repo} do
    # README.md is tracked and unchanged; the untracked sibling makes
    # `git commit` exit 1 with "nothing added to commit but untracked files
    # present" — the wording added by the fix.
    File.write!(Path.join(repo, "sibling.txt"), "s\n")
    before = commit_count(repo)

    assert {:ok, out} = Shared.commit_files(repo, repo, ["README.md"], "No change")
    assert out =~ "nothing added to commit"
    assert commit_count(repo) == before
  end

  test "an unchanged file in a clean tree is a graceful no-op", %{repo: repo} do
    before = commit_count(repo)

    assert {:ok, out} = Shared.commit_files(repo, repo, ["README.md"], "No change")
    assert out =~ "nothing to commit, working tree clean"
    assert commit_count(repo) == before
  end

  # ---------------------------------------------------------------------------
  # Failure
  # ---------------------------------------------------------------------------

  test "a nonexistent path fails the git add and reports the path", %{repo: repo} do
    before = commit_count(repo)
    missing = "missing-#{System.unique_integer([:positive])}.txt"

    assert {:error, msg} = Shared.commit_files(repo, repo, [missing], "Add missing")
    assert msg =~ "Error: git add failed (exit"
    assert msg =~ missing
    assert commit_count(repo) == before
  end

  # ---------------------------------------------------------------------------
  # Co-author trailer
  # ---------------------------------------------------------------------------

  test "appends the co-author trailer when enabled", %{repo: repo} do
    assert :ok = EvoGit.Config.save_user_config(%{git: %{co_authored_by_enabled: true}})
    assert EvoGit.Config.resolve([:git, :co_authored_by_enabled]) == true

    File.write!(Path.join(repo, "trailer.txt"), "x\n")
    assert {:ok, _out} = Shared.commit_files(repo, repo, ["trailer.txt"], "Add trailer")

    body = git!(repo, ["log", "-1", "--pretty=%B"])
    assert body =~ "Co-Authored-By: Genesis <noreply@evogit.ai>"
  end

  test "omits the co-author trailer when disabled", %{repo: repo} do
    assert :ok = EvoGit.Config.save_user_config(%{git: %{co_authored_by_enabled: false}})
    assert EvoGit.Config.resolve([:git, :co_authored_by_enabled]) == false

    File.write!(Path.join(repo, "no-trailer.txt"), "x\n")
    assert {:ok, _out} = Shared.commit_files(repo, repo, ["no-trailer.txt"], "Add no trailer")

    body = git!(repo, ["log", "-1", "--pretty=%B"])
    refute body =~ "Co-Authored-By"
  end

  test "omits the co-author trailer when no config exists", %{repo: repo} do
    # There is NO config.toml — the schema default (false) applies. Deleting via
    # save_user_config would be a no-op; remove the file directly so the cached
    # read falls back to the defaults.
    File.rm(EvoGit.Config.config_path())
    assert EvoGit.Config.resolve([:git, :co_authored_by_enabled]) == false

    File.write!(Path.join(repo, "default-trailer.txt"), "x\n")

    assert {:ok, _out} =
             Shared.commit_files(repo, repo, ["default-trailer.txt"], "Add default trailer")

    body = git!(repo, ["log", "-1", "--pretty=%B"])
    refute body =~ "Co-Authored-By"
  end

  # ---------------------------------------------------------------------------
  # commit_message_file_path/0 (`-F` message files)
  # ---------------------------------------------------------------------------

  describe "commit_message_file_path/0" do
    test "embeds the OS pid so concurrent BEAMs sharing one tmpdir cannot collide" do
      # `System.unique_integer/1` is unique only WITHIN one BEAM: a fresh VM
      # restarts the monotonic counter at 1, while `resolve_tmpdir/0` resolves to
      # the SHARED managed per-task tmpdir whenever one is installed — so the
      # pid-less naming scheme (`genesis_git_commit_msg_<n>.txt`) handed two VMs
      # the SAME path: the loser's `after File.rm/1` then deleted the winner's
      # `-F` file while its `git commit` was still reading it ("fatal: could not
      # read log file '...'"), and cross-contaminated commit messages when it
      # merely overwrote it.
      path = Shared.commit_message_file_path()
      basename = Path.basename(path)

      assert Path.dirname(path) == EvoGit.Sandbox.resolve_tmpdir()
      assert basename =~ ~r/\Agenesis_git_commit_msg_#{System.pid()}_\d+\.txt\z/
      # The identity-free (pid-less) shape must never come back.
      refute basename =~ ~r/\Agenesis_git_commit_msg_\d+\.txt\z/
    end

    test "is unique per call and keeps the .txt extension" do
      paths = for _ <- 1..50, do: Shared.commit_message_file_path()

      assert length(Enum.uniq(paths)) == 50
      assert Enum.all?(paths, &String.ends_with?(&1, ".txt"))
    end

    test "a commit leaves another OS process's message file untouched", %{repo: repo} do
      # Simulate a concurrent BEAM's in-flight `-F` file: same tmpdir, name
      # differing only by the pid segment. Deterministic (no randomness) — the
      # "foreign" pid is simply our pid + 1.
      foreign_pid = System.pid() |> String.to_integer() |> Kernel.+(1) |> Integer.to_string()

      foreign =
        Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_git_commit_msg_#{foreign_pid}_1.txt")

      File.write!(foreign, "SENTINEL OWNED BY ANOTHER BEAM\n")
      on_exit(fn -> File.rm(foreign) end)

      File.write!(Path.join(repo, "sentinel.txt"), "s\n")
      assert {:ok, _out} = Shared.commit_files(repo, repo, ["sentinel.txt"], "Add sentinel")

      # Neither overwritten nor deleted by our commit's try/after cleanup.
      assert File.read(foreign) == {:ok, "SENTINEL OWNED BY ANOTHER BEAM\n"}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  # Fresh temp git repo with one committed README.md and a deterministic commit
  # identity (repo-local, so it also works inside the test sandbox path).
  defp new_repo! do
    repo =
      Path.join(System.tmp_dir!(), "evogit-commit-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(repo)
    {:ok, _} = Git.init(repo)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], repo)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {:ok, _} = Git.add(repo, "README.md")
    {:ok, _} = Git.commit(repo, "Initial commit")
    repo
  end

  # Raw git invocation used purely for assertions/verification. Forces LC_ALL=C
  # so the parsed messages are locale-stable regardless of the host locale.
  defp git!(repo, args) do
    {out, code} =
      System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    assert code == 0, "git #{Enum.join(args, " ")} exited #{code}:\n#{out}"
    String.trim(out)
  end

  defp commit_count(repo) do
    repo |> git!(["rev-list", "--count", "HEAD"]) |> String.to_integer()
  end
end
