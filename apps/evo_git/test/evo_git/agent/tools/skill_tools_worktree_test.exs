defmodule EvoGit.Agent.Tools.SkillToolsWorktreeTest do
  @moduledoc """
  Regression suite for the "skill tools operate on the agent WORKTREE + auto-commit
  skill-file writes" change.

  Every skill tool (`skill_add` / `skill_edit` / `skill_remove` / `skill_list` /
  `skill_read` / `skill_where` / `skill_enable` / `skill_disable`) now routes ALL
  skill-file reads AND writes through the agent's WORKTREE (`repo_path`) instead of
  the main repo root (`repo_root`), and the five file-mutating tools commit their
  own write via `EvoGit.Agent.Tools.Shared.maybe_commit_result/6`.

  It also pins two later lib fixes on this surface: `SkillWhere.execute/3`'s
  NON-EMPTY branch (which used to raise `ArgumentError: construction of binary
  failed` from a `binary <> list` precedence bug) and `SkillRemove`'s staging of
  a CASE-DIFFERING filename (which used to build a git pathspec from the argument
  alone — a non-matching pathspec → `git add` exit ≠ 0 → an error string and NO
  commit, even though the file had already been deleted).
  `async: true` — each test builds its own temp git repository + linked worktree
  under a unique `System.tmp_dir!()` path and removes them in `on_exit`. No BEAM
  global, shared ETS table, or app-env key is mutated: the tools are pure
  functions taking the roots as arguments, the module only READS `EvoGit.Config`
  (via the shared commit helper's co-author trailer), and the sole cross-process
  write is the per-repo-path `EvoGit.GitEnv` identity memo, which is keyed by the
  test's unique temp repo path. Mirrors the rationale in `make_dir_test.exs` and
  `test/evo_git/commit_graph_test.exs`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.{SkillAdd, SkillDisable, SkillEdit, SkillEnable, SkillList}
  alias EvoGit.Agent.Tools.{SkillRead, SkillRemove, SkillWhere}

  @skill_name "wt-skill"

  setup do
    setup_worktree()
  end

  describe "skill_add" do
    test "writes AND commits the skill file in the worktree, repo_root untouched", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      result = SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      assert result =~ "Skill created successfully"
      assert result =~ "Committed:"
      assert result =~ Path.join(repo_path, ".agents/skills/#{@skill_name}.md")

      # Written in the worktree only.
      assert File.exists?(Path.join(repo_path, ".agents/skills/#{@skill_name}.md"))
      refute File.exists?(Path.join(repo_root, ".agents/skills/#{@skill_name}.md"))
      refute File.exists?(Path.join(repo_root, ".agents"))

      # Committed in the worktree, with a clean tree there.
      assert git!(repo_path, ["log", "-1", "--pretty=%s"]) =~ "Add skill #{@skill_name}"
      assert git!(repo_path, ["status", "--porcelain"]) == ""

      # The main repo root is completely unaffected.
      assert git!(repo_root, ["status", "--porcelain"]) == ""
    end

    test "commit: false writes the file but leaves it uncommitted", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      before = head_sha(repo_path)

      result =
        SkillAdd.execute(
          %{"content" => skill_content(@skill_name), "commit" => false},
          repo_path,
          repo_root
        )

      refute result =~ "Committed:"
      assert File.exists?(Path.join(repo_path, ".agents/skills/#{@skill_name}.md"))
      assert head_sha(repo_path) == before

      assert git!(repo_path, ["status", "--porcelain", "--untracked-files=all"]) =~
               ".agents/skills/#{@skill_name}.md"
    end
  end

  describe "skill_edit" do
    test "edits the worktree file and commits by default; commit: false skips the commit", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      SkillAdd.execute(
        %{"content" => skill_content(@skill_name, "Original description")},
        repo_path,
        repo_root
      )

      skill_file = Path.join(repo_path, ".agents/skills/#{@skill_name}.md")

      result =
        SkillEdit.execute(
          %{
            "name" => @skill_name,
            "content" => skill_content(@skill_name, "Edited description")
          },
          repo_path,
          repo_root
        )

      assert result =~ "Skill edited successfully"
      assert result =~ "Committed:"
      assert result =~ skill_file
      assert File.read!(skill_file) =~ "Edited description"

      # Committed → clean tree.
      assert git!(repo_path, ["status", "--porcelain"]) == ""

      before = head_sha(repo_path)

      result2 =
        SkillEdit.execute(
          %{
            "name" => @skill_name,
            "content" => skill_content(@skill_name, "Second description"),
            "commit" => false
          },
          repo_path,
          repo_root
        )

      refute result2 =~ "Committed:"
      assert File.read!(skill_file) =~ "Second description"
      assert head_sha(repo_path) == before
    end
  end

  describe "skill_remove" do
    test "removes the worktree file AND commits the skill file + worktree CONTEXT.md in ONE commit",
         %{
           repo_root: repo_root,
           repo_path: repo_path
         } do
      SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      assert SkillEnable.execute(
               %{"skill_name" => @skill_name},
               repo_path,
               repo_root,
               "./"
             ) =~ "enabled at './'"

      context_file = Path.join(repo_path, "CONTEXT.md")
      assert File.exists?(context_file)

      commits_before = commit_count(repo_path)

      result = SkillRemove.execute(%{"name" => @skill_name}, repo_path, repo_root)

      assert result =~ "removed successfully"
      assert result =~ "Cleaned up references in 1 CONTEXT.md file(s)."
      assert result =~ "Committed:"

      refute File.exists?(Path.join(repo_path, ".agents/skills/#{@skill_name}.md"))
      refute File.read!(context_file) =~ @skill_name

      # Exactly one new commit.
      assert commit_count(repo_path) == commits_before + 1

      # BOTH paths are carried by that SINGLE HEAD commit.
      staged = git!(repo_path, ["show", "--name-only", "--pretty=format:", "HEAD"])
      assert staged =~ ".agents/skills/#{@skill_name}.md"
      assert staged =~ "CONTEXT.md"
    end

    test "removes a skill whose FILENAME case differs from the removal name, AND commits it",
         %{
           repo_root: repo_root,
           repo_path: repo_path
         } do
      # `SkillAdd` derives the filename from the frontmatter `name` VERBATIM, and
      # the name regex is case-insensitive, so this creates (and commits)
      # `.agents/skills/Deploy.md` — not a lowercased file.
      SkillAdd.execute(%{"content" => skill_content("Deploy")}, repo_path, repo_root)

      skill_file = Path.join(repo_path, ".agents/skills/Deploy.md")
      assert File.exists?(skill_file)
      assert git!(repo_path, ["ls-files", ".agents/skills/Deploy.md"]) =~ "Deploy.md"

      commits_before = commit_count(repo_path)

      # The removal name differs ONLY in case from the on-disk filename. The old
      # code staged a path built from the ARGUMENT (`deploy.md`), so `git add`
      # hit a non-matching pathspec and returned an "Error: git add failed ..."
      # string with NO commit — even though the file had already been deleted.
      result = SkillRemove.execute(%{"name" => "deploy"}, repo_path, repo_root)

      assert result =~ "removed successfully"
      refute result =~ "Error"
      refute result =~ "pathspec"
      assert result =~ "Committed:"

      # The case-insensitive deletion really happened...
      refute File.exists?(skill_file)
      # ...and it was committed (the deletion is what HEAD now carries).
      assert commit_count(repo_path) == commits_before + 1

      staged = git!(repo_path, ["show", "--name-only", "--pretty=format:", "HEAD"])
      assert staged =~ ".agents/skills/Deploy.md"

      # Consistent with the rest of the suite: the main repo root is untouched.
      assert git!(repo_root, ["status", "--porcelain"]) == ""
      refute File.exists?(Path.join(repo_root, ".agents"))
    end
  end

  describe "worktree visibility" do
    test "skill_list / skill_read / load_skills see the worktree, never repo_root", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      assert SkillList.execute(%{}, repo_path, repo_root) =~ @skill_name

      assert SkillRead.execute(%{"name" => @skill_name}, repo_path, repo_root) =~
               "name: #{@skill_name}"

      assert Enum.any?(EvoGit.Skills.load_skills(repo_path), &(&1.name == @skill_name))
      refute Enum.any?(EvoGit.Skills.load_skills(repo_root), &(&1.name == @skill_name))
    end

    test "skill_where reports WORKTREE enablement", %{repo_root: repo_root, repo_path: repo_path} do
      SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      # Enable at a NESTED worktree node (the root's `where_enabled/2` entry is
      # rendered as the odd-but-established "./.").
      File.mkdir_p!(Path.join(repo_path, "sub"))

      assert SkillEnable.execute(
               %{"skill_name" => @skill_name, "node_path" => "./sub"},
               repo_path,
               repo_root,
               "./"
             ) =~ "enabled at './sub'"

      # The worktree-scoped scan (the fix under test) sees the enablement...
      assert EvoGit.Skills.where_enabled(@skill_name, repo_path) == ["./sub"]
      # ...while the main repo root sees nothing.
      assert EvoGit.Skills.where_enabled(@skill_name, repo_root) == []

      # The TOOL must render the non-empty branch. Calling the tool (rather than
      # only the scan behind it) is the point of this assertion: the branch used
      # to raise `ArgumentError: construction of binary failed` from a
      # `binary <> list` precedence bug, so any regression there must fail here.
      rendered = SkillWhere.execute(%{"skill_name" => @skill_name}, repo_path, repo_root)

      assert rendered =~ "is enabled at the following nodes"
      assert rendered =~ "./sub"

      # A skill that was never enabled still renders the plain message.
      assert SkillWhere.execute(%{"skill_name" => "never-enabled"}, repo_path, repo_root) =~
               "is not enabled at any node"
    end
  end

  describe "skill_enable / skill_disable" do
    test "skill_enable writes the enabling CONTEXT.md into the WORKTREE, not repo_root", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      result =
        SkillEnable.execute(%{"skill_name" => @skill_name}, repo_path, repo_root, "./")

      assert result =~ "enabled at './'"
      assert result =~ "Committed:"

      context_file = Path.join(repo_path, "CONTEXT.md")
      assert File.exists?(context_file)
      assert File.read!(context_file) =~ @skill_name
      refute File.exists?(Path.join(repo_root, "CONTEXT.md"))
    end

    test "redundant enable and non-enabled disable produce NO commit", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      SkillEnable.execute(%{"skill_name" => @skill_name}, repo_path, repo_root, "./")

      before = head_sha(repo_path)

      again = SkillEnable.execute(%{"skill_name" => @skill_name}, repo_path, repo_root, "./")
      assert again =~ "already enabled"
      refute again =~ "Committed:"
      assert head_sha(repo_path) == before

      # A child node that never enabled the skill → nothing to disable, nothing to commit.
      File.mkdir_p!(Path.join(repo_path, "sub"))
      File.write!(Path.join(repo_path, "sub/CONTEXT.md"), "")

      before_disable = head_sha(repo_path)

      disabled =
        SkillDisable.execute(
          %{"skill_name" => @skill_name, "node_path" => "./sub"},
          repo_path,
          repo_root,
          "./"
        )

      assert disabled =~ "was not enabled"
      refute disabled =~ "Committed:"
      assert head_sha(repo_path) == before_disable
    end
  end

  # Every FAILURE return of the skill tools renders through
  # `EvoGit.Agent.Tools.Failure.error/1` — exactly one leading `Error: ` prefix,
  # no marker, no `inspect` quoting — while the non-failure notices stay
  # unprefixed. Pinned by exact equality so a re-shape cannot drift silently.
  describe "failure message shape" do
    test "argument validation failures gain the single Error: prefix", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      assert SkillRead.execute(%{}, repo_path, repo_root) ==
               "Error: Missing required argument 'name'. Please provide a valid value."

      assert SkillWhere.execute(%{}, repo_path, repo_root) ==
               "Error: Missing required argument 'skill_name'. Please provide a valid value."
    end

    test "skill-level failures render 'Error: <verb> skill: <reason>'", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      assert SkillEdit.execute(
               %{"name" => "missing", "content" => skill_content("missing")},
               repo_path,
               repo_root
             ) == "Error: editing skill: Skill 'missing' not found"

      assert SkillRemove.execute(%{"name" => "missing"}, repo_path, repo_root) ==
               "Error: removing skill: Skill 'missing' not found"

      assert SkillEnable.execute(%{"skill_name" => "missing"}, repo_path, repo_root, "./") ==
               "Error: Skill 'missing' does not exist in .agents/skills/. " <>
                 "Use skill_add to create it first, or use skill_list to see available skills."

      # The duplicate-add failure comes back through the same shape, with the
      # reason the CRUD layer produced.
      SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root)

      assert SkillAdd.execute(%{"content" => skill_content(@skill_name)}, repo_path, repo_root) ==
               "Error: creating skill: Skill '#{@skill_name}' already exists at " <>
                 Path.join(repo_path, ".agents/skills/#{@skill_name}.md")
    end

    test "a non-failure notice stays unprefixed", %{repo_root: repo_root, repo_path: repo_path} do
      # `skill_disable` on a node that never enabled the skill is informational,
      # NOT a failure — it must not gain an `Error:` prefix.
      disabled = SkillDisable.execute(%{"skill_name" => "missing"}, repo_path, repo_root, "./")

      refute String.starts_with?(disabled, "Error:")
      assert disabled =~ "was not enabled"
    end
  end

  # A NON-STRING failure reason — here the `%YamlElixir.ParsingError{}` struct the
  # skills layer returns for unparseable frontmatter — must never crash a tool
  # call. Every skill tool renders its reason through
  # `EvoGit.Agent.Tools.Failure.format_reason/1` (an exception → its
  # `Exception.message/1`), so the tool still answers with a plain `Error: ...`
  # string and mutates nothing.
  describe "non-string failure reasons" do
    test "skill_edit with invalid YAML frontmatter returns a readable error, no write and no commit",
         %{repo_root: repo_root, repo_path: repo_path} do
      SkillAdd.execute(
        %{"content" => skill_content(@skill_name, "Original description")},
        repo_path,
        repo_root
      )

      skill_file = Path.join(repo_path, ".agents/skills/#{@skill_name}.md")
      original_content = File.read!(skill_file)
      before_head = head_sha(repo_path)
      before_status = git!(repo_path, ["status", "--porcelain", "--untracked-files=all"])

      result =
        SkillEdit.execute(
          %{"name" => @skill_name, "content" => invalid_yaml_skill_content(@skill_name)},
          repo_path,
          repo_root
        )

      # A plain string, never a raise — and a HUMAN-READABLE reason (the
      # parser's own message locally; the point is that it is prose, never the
      # raw `%YamlElixir.ParsingError{}` struct).
      assert is_binary(result)
      assert result =~ "Error:"
      assert result =~ "editing skill:"
      assert result =~ "Block mapping value not allowed here" or result =~ "YAML"
      refute result =~ "%YamlElixir.ParsingError"

      # Nothing was written and nothing was committed.
      assert File.read!(skill_file) == original_content
      assert head_sha(repo_path) == before_head
      assert git!(repo_path, ["status", "--porcelain", "--untracked-files=all"]) == before_status
    end

    test "skill_add with invalid YAML frontmatter returns a readable error, writes no file and commits nothing",
         %{repo_root: repo_root, repo_path: repo_path} do
      before_head = head_sha(repo_path)

      result =
        SkillAdd.execute(
          %{"content" => invalid_yaml_skill_content(@skill_name)},
          repo_path,
          repo_root
        )

      assert is_binary(result)
      assert result =~ "Error:"
      assert result =~ "creating skill:"
      assert result =~ "Block mapping value not allowed here" or result =~ "YAML"
      refute result =~ "%YamlElixir.ParsingError"

      refute File.exists?(Path.join(repo_path, ".agents/skills/#{@skill_name}.md"))
      refute File.exists?(Path.join(repo_path, ".agents"))
      assert head_sha(repo_path) == before_head
      assert git!(repo_path, ["status", "--porcelain", "--untracked-files=all"]) == ""
    end

    test "a valid edit still succeeds and a STRING reason stays verbatim prose",
         %{repo_root: repo_root, repo_path: repo_path} do
      SkillAdd.execute(
        %{"content" => skill_content(@skill_name, "Original description")},
        repo_path,
        repo_root
      )

      skill_file = Path.join(repo_path, ".agents/skills/#{@skill_name}.md")

      edited =
        SkillEdit.execute(
          %{"name" => @skill_name, "content" => skill_content(@skill_name, "Edited description")},
          repo_path,
          repo_root
        )

      assert edited =~ "Skill edited successfully"
      assert edited =~ "Committed:"
      assert File.read!(skill_file) =~ "Edited description"

      # A binary reason is NOT inspected/quoted — exact rendering preserved.
      assert SkillEdit.execute(
               %{"name" => @skill_name, "content" => skill_content("other-name")},
               repo_path,
               repo_root
             ) ==
               "Error: editing skill: Skill name mismatch: content declares 'other-name' " <>
                 "but editing '#{@skill_name}'. The name in frontmatter must match."
    end
  end

  describe "commit argument validation" do
    test "a non-boolean commit is rejected before any write or commit", %{
      repo_root: repo_root,
      repo_path: repo_path
    } do
      before = head_sha(repo_path)

      result =
        SkillAdd.execute(
          %{"content" => skill_content(@skill_name), "commit" => "yes"},
          repo_path,
          repo_root
        )

      assert result == ~s(Error: Argument 'commit' must be a boolean, got: "yes")
      refute File.exists?(Path.join(repo_path, ".agents/skills/#{@skill_name}.md"))
      assert head_sha(repo_path) == before

      # Same shape (and same ordering: validation BEFORE the existence check)
      # for skill_enable.
      enable_result =
        SkillEnable.execute(
          %{"skill_name" => @skill_name, "commit" => "yes"},
          repo_path,
          repo_root,
          "./"
        )

      assert enable_result == ~s(Error: Argument 'commit' must be a boolean, got: "yes")
      refute File.exists?(Path.join(repo_path, "CONTEXT.md"))
      assert head_sha(repo_path) == before
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # ONE shared worktree-setup helper for the whole suite: a real git repo at
  # `repo_root` plus a linked worktree at `repo_path` (the agent's worktree).
  defp setup_worktree do
    base =
      Path.join(System.tmp_dir!(), "skill_wt_" <> to_string(System.unique_integer([:positive])))

    repo_root = Path.join(base, "main")
    repo_path = Path.join(base, "wt")

    File.mkdir_p!(repo_root)
    git!(repo_root, ["init"])
    git!(repo_root, ["config", "user.email", "test@example.com"])
    git!(repo_root, ["config", "user.name", "Test User"])
    File.write!(Path.join(repo_root, "README.md"), "init")
    git!(repo_root, ["add", "README.md"])
    git!(repo_root, ["commit", "-m", "init"])
    git!(repo_root, ["worktree", "add", repo_path, "-b", "wt"])

    on_exit(fn -> File.rm_rf!(base) end)

    %{repo_root: repo_root, repo_path: repo_path}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp head_sha(dir), do: String.trim(git!(dir, ["rev-parse", "HEAD"]))

  defp commit_count(dir) do
    dir |> git!(["rev-list", "--count", "HEAD"]) |> String.trim() |> String.to_integer()
  end

  defp skill_content(name, description \\ "Does something useful") do
    """
    ---
    name: #{name}
    description: #{description}
    ---

    Body.
    """
  end

  # Frontmatter yamerl genuinely REJECTS: `description: This is: invalid` is a
  # block mapping value in a block mapping value position, so the skills layer
  # returns `{:error, %YamlElixir.ParsingError{… "Block mapping value not
  # allowed here" …}}` — the non-string reason these tests exercise.
  defp invalid_yaml_skill_content(name) do
    """
    ---
    name: #{name}
    description: This is: invalid
    ---

    Body.
    """
  end
end
