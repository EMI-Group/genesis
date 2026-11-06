defmodule EvoGit.Agent.Tools.ContextAmendTest do
  @moduledoc """
  Pins the "squash consecutive CONTEXT.md commits via amend" contract of
  `EvoGit.Agent.Tools.Shared.commit_files/5` (`amend: true`) — opted into by
  `write_context` / `edit_context` only.

  What must hold:
    * consecutive same-file CONTEXT.md edits AMEND the previous auto context
      commit, so one agent batch stays ONE commit;
    * the amend is refused (plain commit instead) when HEAD is not this tool's
      own one-file context commit for that exact path, when HEAD is a merge
      commit, or when HEAD is not PRIVATE to the current branch (the
      base-commit protection the subagent/octopus-merge flow depends on);
    * `create_files` / `make_dir` keep one commit per call — no cross-call
      squashing.

  `async: true` — every test resolves config through the module's OWN config
  directory (`EvoGit.TestSupport.ConfigDir`), so `EvoGit.Config.config_path/0`
  never touches the real `~/.config/genesis/config.toml`; the `:persistent_term`
  config cache is keyed by FILE PATH, so a module-local directory cannot collide
  with another module's. Repositories are per-test copies of ONE `setup_all`
  template (as in `commit_files_test.exs`).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.Context
  alias EvoGit.Agent.Tools.FileCreate
  alias EvoGit.Agent.Tools.MakeDir
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.TestSupport.ConfigDir

  @context_prefix "Update CONTEXT.md for "

  setup_all do
    {:ok,
     config_dir: ConfigDir.isolate_module!("evogit-context-amend"), template: git_template!()}
  end

  setup %{config_dir: config_dir, template: template} do
    ConfigDir.activate(config_dir)
    repo = new_repo!(template)
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  # ---------------------------------------------------------------------------
  # Squashing (the whole point)
  # ---------------------------------------------------------------------------

  test "two edit_context calls on the same dir produce ONE commit", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    # The write created the first auto context commit (HEAD was still the plain
    # base commit); the edit squashes into it.
    after_write = commit_count(repo)

    assert_context_edit(repo, "./x", "first", "second edit")
    assert commit_count(repo) == after_write

    content = File.read!(Path.join(repo, "x/CONTEXT.md"))
    assert content =~ "second edit"
    refute content =~ "first\n"
    assert last_subject(repo) == @context_prefix <> "./x"
  end

  test "write_context then edit_context on the same dir produce ONE commit", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nalpha\n")
    before = commit_count(repo)

    assert_context_edit(repo, "./x", "alpha", "beta")
    assert commit_count(repo) == before

    content = File.read!(Path.join(repo, "x/CONTEXT.md"))
    assert content =~ "beta"
    refute content =~ "alpha"
  end

  test "edit_context then write_context on the same dir produce ONE commit", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nalpha\n")
    assert_context_edit(repo, "./x", "alpha", "beta")
    before = commit_count(repo)

    write_context!(repo, "./x", "# X\n\nrewritten\n")
    assert commit_count(repo) == before
    assert File.read!(Path.join(repo, "x/CONTEXT.md")) == "# X\n\nrewritten\n"
  end

  test "a dir path spelled './x' or 'x' still squashes", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\none\n")
    assert_context_edit(repo, "x", "one", "two")
    before = commit_count(repo)

    # Same directory, different spelling: the amend check compares REPO-RELATIVE
    # normalized paths, never the model's raw argument.
    write_context!(repo, "x", "# X\n\nthree\n")
    assert commit_count(repo) == before
    assert File.read!(Path.join(repo, "x/CONTEXT.md")) == "# X\n\nthree\n"
  end

  test "unrelated staged content is never folded into the amended commit", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\none\n")
    before = commit_count(repo)

    File.write!(Path.join(repo, "staged.txt"), "s\n")
    assert {_out, 0} = System.cmd("git", ["add", "staged.txt"], cd: repo, stderr_to_stdout: true)

    write_context!(repo, "./x", "# X\n\ntwo\n")
    assert commit_count(repo) == before

    committed_files = git!(repo, ["ls-tree", "-r", "--name-only", "HEAD"])
    assert committed_files =~ "x/CONTEXT.md"
    refute committed_files =~ "staged.txt"
    # `--only` leaves the unrelated staged file staged.
    assert git!(repo, ["diff", "--cached", "--name-only"]) == "staged.txt"
  end

  test "Shared.commit_files/5 with amend: true squashes, while /4 never does", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "x"))
    msg = @context_prefix <> "./x"

    File.write!(Path.join(repo, "x/CONTEXT.md"), "one\n")
    assert {:ok, _} = Shared.commit_files(repo, repo, ["x/CONTEXT.md"], msg, amend: true)
    before = commit_count(repo)

    File.write!(Path.join(repo, "x/CONTEXT.md"), "two\n")
    assert {:ok, out} = Shared.commit_files(repo, repo, ["x/CONTEXT.md"], msg, amend: true)
    assert commit_count(repo) == before
    assert out =~ "CONTEXT.md"

    # The plain arity keeps its per-call behaviour: one new commit every call.
    File.write!(Path.join(repo, "x/CONTEXT.md"), "three\n")
    assert {:ok, _} = Shared.commit_files(repo, repo, ["x/CONTEXT.md"], msg)
    assert commit_count(repo) == before + 1
  end

  test "amend: true with MORE than one path stays a plain commit", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "x"))
    msg = @context_prefix <> "./x"

    File.write!(Path.join(repo, "x/CONTEXT.md"), "one\n")
    assert {:ok, _} = Shared.commit_files(repo, repo, ["x/CONTEXT.md"], msg, amend: true)
    before = commit_count(repo)

    File.write!(Path.join(repo, "x/CONTEXT.md"), "two\n")
    File.write!(Path.join(repo, "y.txt"), "y\n")
    assert {:ok, _} = Shared.commit_files(repo, repo, ["x/CONTEXT.md", "y.txt"], msg, amend: true)
    assert commit_count(repo) == before + 1
  end

  # ---------------------------------------------------------------------------
  # Refusals — each creates a NEW commit and rewrites nothing
  # ---------------------------------------------------------------------------

  test "two DIFFERENT directories produce two commits", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    write_context!(repo, "./y", "# Y\n\nfirst\n")

    # One commit ("base" has no commit of its own for these files) per call.
    assert commit_count(repo) == 3
    assert git!(repo, ["show", "--pretty=%s", "--name-only", "HEAD"]) =~ "y/CONTEXT.md"
    assert git!(repo, ["show", "--pretty=%s", "--name-only", "HEAD~1"]) =~ "x/CONTEXT.md"
  end

  test "a HEAD that is not private to the branch is never amended (base-commit protection)",
       %{repo: repo} do
    # Mimic a subagent worktree: the base commit IS this tool's own one-file
    # context commit and is reachable from a SECOND ref (`main`), so amending it
    # would rewrite the parent's history and diverge the child branch.
    File.mkdir_p!(Path.join(repo, "x"))
    File.write!(Path.join(repo, "x/CONTEXT.md"), "# X\n\nbase\n")
    git!(repo, ["add", "x/CONTEXT.md"])
    git!(repo, ["commit", "-q", "-m", @context_prefix <> "./x"])

    base_sha = git!(repo, ["rev-parse", "HEAD"])
    assert git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"]) == "main"
    git!(repo, ["checkout", "-q", "-b", "agent"])

    assert_context_edit(repo, "./x", "base", "edited")

    # A NEW commit was created on top of the untouched base.
    assert commit_count(repo) == 3
    assert git!(repo, ["rev-parse", "HEAD~1"]) == base_sha
    assert git!(repo, ["rev-parse", "main"]) == base_sha

    assert {_out, 0} =
             System.cmd("git", ["cat-file", "-e", base_sha], cd: repo, stderr_to_stdout: true)

    assert File.read!(Path.join(repo, "x/CONTEXT.md")) =~ "edited"

    # Once HEAD is the agent's own private commit, the next same-file edit DOES
    # squash into it.
    before = commit_count(repo)
    assert_context_edit(repo, "./x", "edited", "edited+again")
    assert commit_count(repo) == before
    assert git!(repo, ["rev-parse", "main"]) == base_sha
  end

  test "a HEAD touching only x/CONTEXT.md but with another subject is never amended", %{
    repo: repo
  } do
    File.mkdir_p!(Path.join(repo, "x"))
    File.write!(Path.join(repo, "x/CONTEXT.md"), "# X\n\nbase\n")
    git!(repo, ["add", "x/CONTEXT.md"])
    git!(repo, ["commit", "-q", "-m", "Fix something"])
    base_sha = git!(repo, ["rev-parse", "HEAD"])

    assert_context_edit(repo, "./x", "base", "edited")

    assert commit_count(repo) == 3
    assert git!(repo, ["rev-parse", "HEAD~1"]) == base_sha
    assert last_subject(repo) == @context_prefix <> "./x"
  end

  test "a merge-commit HEAD is never amended", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "x"))
    File.write!(Path.join(repo, "x/CONTEXT.md"), "# X\n\nbase\n")
    git!(repo, ["add", "x/CONTEXT.md"])
    # Deliberately the exact auto subject — only the two-parent shape may refuse.
    git!(repo, ["commit", "-q", "-m", @context_prefix <> "./x"])

    git!(repo, ["checkout", "-q", "-b", "side"])
    File.write!(Path.join(repo, "side.txt"), "side\n")
    git!(repo, ["add", "side.txt"])
    git!(repo, ["commit", "-q", "-m", "side work"])

    git!(repo, ["checkout", "-q", "main"])
    File.write!(Path.join(repo, "main.txt"), "main\n")
    git!(repo, ["add", "main.txt"])
    git!(repo, ["commit", "-q", "-m", "main work"])
    git!(repo, ["merge", "-q", "--no-ff", "-m", @context_prefix <> "./x", "side"])

    merge_sha = git!(repo, ["rev-parse", "HEAD"])
    assert length(String.split(git!(repo, ["rev-list", "--parents", "-n", "1", "HEAD"]))) == 3

    assert_context_edit(repo, "./x", "base", "edited")

    assert commit_count(repo) == 6
    assert git!(repo, ["rev-parse", "HEAD~1"]) == merge_sha
    assert git!(repo, ["cat-file", "-t", merge_sha]) == "commit"
    assert git!(repo, ["log", "-1", "--pretty=%s", merge_sha]) == @context_prefix <> "./x"
  end

  test "commit: false makes no commit at all", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\none\n")
    before = commit_count(repo)

    assert "Successfully updated CONTEXT.md for directory './x'" ==
             Context.execute_write(
               %{"dir_path" => "./x", "content" => "# X\n\ntwo\n", "commit" => false},
               repo,
               repo
             )

    assert Context.execute_edit(
             %{
               "dir_path" => "./x",
               "old_string" => "two",
               "new_string" => "three",
               "commit" => false
             },
             repo,
             repo
           ) =~ "has been updated successfully"

    assert commit_count(repo) == before
    assert File.read!(Path.join(repo, "x/CONTEXT.md")) == "# X\n\nthree\n"
    assert git!(repo, ["status", "--porcelain"]) =~ "M x/CONTEXT.md"
  end

  # ---------------------------------------------------------------------------
  # Non-opted-in tools keep one commit per call
  # ---------------------------------------------------------------------------

  test "create_files and make_dir are never squashed", %{repo: repo} do
    before = commit_count(repo)

    assert FileCreate.execute(%{"paths" => ["./a.txt"]}, repo, repo) =~ "Successfully created"

    assert MakeDir.execute(%{"paths" => ["./d1"]}, repo, repo) =~
             "Successfully created 1 directory"

    assert commit_count(repo) == before + 2

    FileCreate.execute(%{"paths" => ["./b.txt"]}, repo, repo)
    MakeDir.execute(%{"paths" => ["./d2"]}, repo, repo)

    # Two more calls, two more commits — neither tool amends, not even when the
    # commits touch a CONTEXT.md (make_dir's keep file).
    assert commit_count(repo) == before + 4
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_context!(repo, dir_path, content) do
    assert Context.execute_write(
             %{"dir_path" => dir_path, "content" => content, "commit" => true},
             repo,
             repo
           ) =~ "Successfully updated CONTEXT.md for directory"
  end

  defp assert_context_edit(repo, dir_path, old_string, new_string, commit \\ true) do
    result =
      Context.execute_edit(
        %{
          "dir_path" => dir_path,
          "old_string" => old_string,
          "new_string" => new_string,
          "commit" => commit
        },
        repo,
        repo
      )

    assert result =~ "has been updated successfully"
    if commit, do: assert(result =~ "Committed:")
    result
  end

  # One module-unique git TEMPLATE (one initial commit, repo-local identity).
  defp git_template! do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit-context-amend-tpl-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    empty_template = Path.join(root, "empty_template")
    File.mkdir_p!(empty_template)
    repo = Path.join(root, "seed")

    {_out, 0} =
      System.cmd(
        "git",
        ["-c", "init.defaultBranch=main", "init", "-q", "--template=#{empty_template}", repo],
        stderr_to_stdout: true
      )

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"},
          {"core.abbrev", "40"}
        ] do
      {_out, 0} = System.cmd("git", ["config", key, value], cd: repo, stderr_to_stdout: true)
    end

    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_out, 0} = System.cmd("git", ["add", "README.md"], cd: repo, stderr_to_stdout: true)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "base"], cd: repo, stderr_to_stdout: true)

    on_exit(fn -> File.rm_rf!(root) end)
    repo
  end

  defp new_repo!(template) do
    repo =
      Path.join(
        System.tmp_dir!(),
        "evogit-context-amend-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(template, repo)
    repo
  end

  defp git!(repo, args) do
    {out, code} =
      System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    assert code == 0, "git #{Enum.join(args, " ")} exited #{code}:\n#{out}"
    String.trim(out)
  end

  defp last_subject(repo), do: git!(repo, ["log", "-1", "--pretty=%s"])

  defp commit_count(repo) do
    repo |> git!(["rev-list", "--count", "HEAD"]) |> String.to_integer()
  end
end
