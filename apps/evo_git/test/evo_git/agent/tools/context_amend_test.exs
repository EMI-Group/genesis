defmodule EvoGit.Agent.Tools.ContextAmendTest do
  @moduledoc """
  Pins the "squash consecutive CONTEXT.md commits via amend" contract of
  `EvoGit.Agent.Tools.Shared.commit_files/5` (`amend: true`) — opted into by
  `write_context` / `edit_context` only.

  What must hold:
    * consecutive CONTEXT.md edits AMEND the previous auto context commit, so one
      agent batch stays ONE commit — and that includes edits at DIFFERENT
      directories: HEAD is amendable whenever EVERY path it changed is a
      CONTEXT.md path, so several `x/CONTEXT.md` / `y/CONTEXT.md` / … edits
      squash into one commit;
    * the amended message keeps the auto subject
      (`"Update CONTEXT.md for <raw dir_path>"`) and, once MORE than one file is
      in the commit, appends `Files in this commit:` plus one repo-relative
      path per line (sorted);
    * `amend_message_fun` is invoked ONCE on the amend path with HEAD's changed
      paths ∪ the new path (deduped, sorted), and only a non-empty binary return
      replaces the caller's message — it is never invoked on the plain path;
    * the amend is refused (plain commit instead) when HEAD is not this tool's
      own context commit (foreign subject, or any non-CONTEXT.md path in its
      diff), when HEAD is a merge commit, or when a shared/published ref contains
      HEAD — another branch, a remote-tracking ref or a tag (the base-commit
      protection the subagent/octopus-merge flow depends on); Genesis's own
      `refs/genesis/*` bookkeeping (e.g. an `agent-state` checkpoint anchor) does
      not block the amend;
    * `create_files` / `make_dir` keep one commit per call — no cross-call
      squashing.

  `async: true` — every test resolves config through the module's OWN config
  directory (`EvoGit.TestSupport.ConfigDir`), so `EvoGit.Config.config_path/0`
  never touches the real `~/.config/genesis/config.toml`; the `:persistent_term`
  config cache is keyed by FILE PATH, so a module-local directory cannot collide
  with another module's. The directory holds no `config.toml`, so
  `[:git, :co_authored_by_enabled]` keeps its `false` default and no co-author
  trailer lands in the commit bodies asserted below. Repositories are per-test
  copies of ONE `setup_all` template (as in `commit_files_test.exs`).
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

  test "a refs/genesis/agent-state anchor at HEAD does not block squashing", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    after_write = commit_count(repo)

    # Durable agent state anchors every commit-advancing checkpoint at
    # `refs/genesis/agent-state/<task_id>/<agent_id>`. That is the run's own
    # bookkeeping, not a shared/published ref, so it must not block the amend.
    git!(repo, ["update-ref", "refs/genesis/agent-state/task-1/agent-1", "HEAD"])

    assert git!(repo, ["for-each-ref", "--contains", "HEAD", "--format=%(refname)"]) =~
             "refs/genesis/agent-state/task-1/agent-1"

    assert_context_edit(repo, "./x", "first", "second edit")
    assert commit_count(repo) == after_write

    content = File.read!(Path.join(repo, "x/CONTEXT.md"))
    assert content =~ "second edit"
    refute content =~ "first\n"
    assert last_subject(repo) == @context_prefix <> "./x"
  end

  test "an identical-content amend is a git exit-0 no-op (no new commit)", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nsame\n")
    before = commit_count(repo)

    write_context!(repo, "./x", "# X\n\nsame\n")

    assert commit_count(repo) == before
    assert File.read!(Path.join(repo, "x/CONTEXT.md")) == "# X\n\nsame\n"
    assert last_subject(repo) == @context_prefix <> "./x"
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
  # Cross-directory squashing — several CONTEXT.md paths in ONE commit
  # ---------------------------------------------------------------------------

  test "two DIFFERENT directories squash into ONE commit that lists both files", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    write_context!(repo, "./y", "# Y\n\nfirst\n")

    # ONE context commit beyond the template's base commit: the second write
    # amended the first instead of stacking another commit.
    assert commit_count(repo) == 2
    assert git!(repo, ["log", "-1", "--pretty=%s", "HEAD~1"]) == "base"

    assert changed_paths(repo) == ["x/CONTEXT.md", "y/CONTEXT.md"]

    # The subject keeps the RAW dir_path argument of the write that ran last…
    assert last_subject(repo) == @context_prefix <> "./y"

    # …while the appended file list uses REPO-RELATIVE normalized paths.
    assert commit_body(repo) ==
             """
             Update CONTEXT.md for ./y

             Files in this commit:
             - x/CONTEXT.md
             - y/CONTEXT.md\
             """

    # Both files really are in the one commit, on top of the untouched base.
    tracked = git!(repo, ["ls-tree", "-r", "--name-only", "HEAD"])
    assert tracked =~ "README.md"
    assert tracked =~ "x/CONTEXT.md"
    assert tracked =~ "y/CONTEXT.md"
  end

  test "three different directories squash into ONE commit listing all three files", %{
    repo: repo
  } do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    write_context!(repo, "./a", "# A\n\nfirst\n")
    write_context!(repo, "./z", "# Z\n\nfirst\n")

    assert commit_count(repo) == 2
    assert git!(repo, ["log", "-1", "--pretty=%s", "HEAD~1"]) == "base"

    assert changed_paths(repo) == ["a/CONTEXT.md", "x/CONTEXT.md", "z/CONTEXT.md"]

    # The subject names the THIRD (last) write's raw dir_path; the body lists
    # every path in the commit, sorted.
    assert last_subject(repo) == @context_prefix <> "./z"

    assert commit_body(repo) ==
             """
             Update CONTEXT.md for ./z

             Files in this commit:
             - a/CONTEXT.md
             - x/CONTEXT.md
             - z/CONTEXT.md\
             """

    tracked = git!(repo, ["ls-tree", "-r", "--name-only", "HEAD"])
    assert tracked =~ "a/CONTEXT.md"
    assert tracked =~ "x/CONTEXT.md"
    assert tracked =~ "z/CONTEXT.md"
  end

  test "two DIFFERENT directories squash across an anchor ref into ONE commit listing both", %{
    repo: repo
  } do
    write_context!(repo, "./x", "# X\n\nfirst\n")

    # A checkpoint anchor at HEAD between the two edits (see the agent-state
    # regression test above) must not split the squash in two.
    git!(repo, ["update-ref", "refs/genesis/agent-state/task-2/agent-2", "HEAD"])

    write_context!(repo, "./y", "# Y\n\nfirst\n")

    # ONE context commit beyond the template's base commit.
    assert commit_count(repo) == 2
    assert git!(repo, ["log", "-1", "--pretty=%s", "HEAD~1"]) == "base"

    assert changed_paths(repo) == ["x/CONTEXT.md", "y/CONTEXT.md"]

    assert commit_body(repo) ==
             """
             Update CONTEXT.md for ./y

             Files in this commit:
             - x/CONTEXT.md
             - y/CONTEXT.md\
             """
  end

  # ---------------------------------------------------------------------------
  # Refusals — each creates a NEW commit and rewrites nothing
  # ---------------------------------------------------------------------------

  test "a HEAD that is not private to the branch is never amended (base-commit protection)",
       %{repo: repo} do
    # Mimic a subagent worktree: the base commit IS this tool's own context
    # commit and is reachable from a SECOND ref (`main`), so amending it would
    # rewrite the parent's history and diverge the child branch.
    context_commit!(repo, "x")

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

  test "HEAD shared with another branch is never amended", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    before = commit_count(repo)
    git!(repo, ["branch", "other"])

    assert_context_edit(repo, "./x", "first", "second")

    # A NEW commit was created; the shared commit is untouched.
    assert commit_count(repo) == before + 1
    assert git!(repo, ["rev-parse", "other"]) == git!(repo, ["rev-parse", "HEAD~1"])
  end

  test "HEAD shared with a remote-tracking ref is never amended", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    before = commit_count(repo)
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])

    assert_context_edit(repo, "./x", "first", "second")

    assert commit_count(repo) == before + 1

    assert git!(repo, ["rev-parse", "refs/remotes/origin/main"]) ==
             git!(repo, ["rev-parse", "HEAD~1"])
  end

  test "HEAD shared with a tag is never amended", %{repo: repo} do
    write_context!(repo, "./x", "# X\n\nfirst\n")
    before = commit_count(repo)
    git!(repo, ["tag", "v1"])

    assert_context_edit(repo, "./x", "first", "second")

    assert commit_count(repo) == before + 1
    assert git!(repo, ["rev-parse", "v1"]) == git!(repo, ["rev-parse", "HEAD~1"])
  end

  test "a HEAD touching only x/CONTEXT.md but with another subject is never amended", %{
    repo: repo
  } do
    context_commit!(repo, "x", "Fix something")
    base_sha = git!(repo, ["rev-parse", "HEAD"])

    assert_context_edit(repo, "./x", "base", "edited")

    assert commit_count(repo) == 3
    assert git!(repo, ["rev-parse", "HEAD~1"]) == base_sha
    assert last_subject(repo) == @context_prefix <> "./x"
  end

  test "a HEAD that also touches a non-CONTEXT.md file is never amended", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "x"))
    File.write!(Path.join(repo, "x/CONTEXT.md"), "# X\n\nbase\n")
    File.write!(Path.join(repo, "x/notes.txt"), "notes\n")
    git!(repo, ["add", "x/CONTEXT.md", "x/notes.txt"])
    # Deliberately the exact auto subject — only the mixed diff may refuse.
    git!(repo, ["commit", "-q", "-m", @context_prefix <> "./x"])

    prior_sha = git!(repo, ["rev-parse", "HEAD"])
    before = commit_count(repo)

    assert_context_edit(repo, "./x", "base", "edited")

    assert commit_count(repo) == before + 1
    # The earlier commit is untouched and still carries the auto subject…
    assert git!(repo, ["rev-parse", "HEAD~1"]) == prior_sha
    assert git!(repo, ["log", "-1", "--pretty=%s", prior_sha]) == @context_prefix <> "./x"

    # …and the new commit is a PLAIN single-file one: no file list body.
    assert last_subject(repo) == @context_prefix <> "./x"
    assert commit_body(repo) == @context_prefix <> "./x"
  end

  test "a merge-commit HEAD is never amended", %{repo: repo} do
    # Deliberately the exact auto subject — only the two-parent shape may refuse.
    context_commit!(repo, "x")

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
  # amend_message_fun — the caller-owned message spelling
  # ---------------------------------------------------------------------------

  describe "amend_message_fun (Shared.commit_files/5)" do
    test "receives the sorted HEAD-plus-new path set once and replaces the message", %{
      repo: repo
    } do
      context_commit!(repo, "x")
      before = commit_count(repo)

      File.mkdir_p!(Path.join(repo, "y"))
      File.write!(Path.join(repo, "y/CONTEXT.md"), "# Y\n\nfirst\n")

      test_pid = self()

      fun = fn paths ->
        send(test_pid, {:amend_paths, paths})
        "custom amend message"
      end

      assert {:ok, _out} =
               Shared.commit_files(repo, repo, ["y/CONTEXT.md"], @context_prefix <> "./y",
                 amend: true,
                 amend_message_fun: fun
               )

      # Invoked exactly ONCE, with HEAD's changed paths ∪ the new path.
      assert_received {:amend_paths, ["x/CONTEXT.md", "y/CONTEXT.md"]}
      refute_received {:amend_paths, _}

      # The amend squashed (no new commit) and the custom binary IS the message.
      assert commit_count(repo) == before
      assert commit_body(repo) == "custom amend message"

      # `--only` staged just the new file; the earlier one stayed in the commit.
      assert changed_paths(repo) == ["x/CONTEXT.md", "y/CONTEXT.md"]
    end

    test "is never invoked on the plain-commit path", %{repo: repo} do
      test_pid = self()

      fun = fn paths ->
        send(test_pid, {:amend_paths, paths})
        "custom amend message"
      end

      # HEAD is the template's "base" commit, which touches README.md — not an
      # amendable context commit, so this call takes the plain path.
      File.mkdir_p!(Path.join(repo, "x"))
      File.write!(Path.join(repo, "x/CONTEXT.md"), "one\n")
      before = commit_count(repo)

      assert {:ok, _out} =
               Shared.commit_files(repo, repo, ["x/CONTEXT.md"], @context_prefix <> "./x",
                 amend: true,
                 amend_message_fun: fun
               )

      refute_received {:amend_paths, _}
      assert commit_count(repo) == before + 1
      assert commit_body(repo) == @context_prefix <> "./x"
    end

    test "a non-binary or empty return keeps the caller's message", %{repo: repo} do
      context_commit!(repo, "x")

      File.mkdir_p!(Path.join(repo, "y"))
      File.write!(Path.join(repo, "y/CONTEXT.md"), "# Y\n\nfirst\n")

      assert {:ok, _out} =
               Shared.commit_files(repo, repo, ["y/CONTEXT.md"], @context_prefix <> "./y",
                 amend: true,
                 amend_message_fun: fn _paths -> "" end
               )

      assert commit_body(repo) == @context_prefix <> "./y"

      File.mkdir_p!(Path.join(repo, "z"))
      File.write!(Path.join(repo, "z/CONTEXT.md"), "# Z\n\nfirst\n")

      assert {:ok, _out} =
               Shared.commit_files(repo, repo, ["z/CONTEXT.md"], @context_prefix <> "./z",
                 amend: true,
                 amend_message_fun: fn _paths -> :not_a_message end
               )

      assert commit_body(repo) == @context_prefix <> "./z"
      assert changed_paths(repo) == ["x/CONTEXT.md", "y/CONTEXT.md", "z/CONTEXT.md"]
    end
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

  # A hand-built equivalent of the tool's own auto context commit: `<dir>/CONTEXT.md`
  # committed with the auto subject (or an explicit one), so HEAD is exactly the
  # shape `amendable_context_head/3` judges.
  defp context_commit!(repo, dir, message \\ nil) do
    File.mkdir_p!(Path.join(repo, dir))
    File.write!(Path.join([repo, dir, "CONTEXT.md"]), "# #{dir}\n\nbase\n")
    git!(repo, ["add", "#{dir}/CONTEXT.md"])
    git!(repo, ["commit", "-q", "-m", message || @context_prefix <> "./#{dir}"])
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

  # Raw subject + body of HEAD (the co-author trailer is absent — see @moduledoc).
  defp commit_body(repo), do: git!(repo, ["log", "-1", "--pretty=%B"])

  # Repo-relative paths changed by HEAD, sorted.
  defp changed_paths(repo) do
    repo
    |> git!(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
    |> String.split("\n", trim: true)
    |> Enum.sort()
  end

  defp commit_count(repo) do
    repo |> git!(["rev-list", "--count", "HEAD"]) |> String.to_integer()
  end
end
