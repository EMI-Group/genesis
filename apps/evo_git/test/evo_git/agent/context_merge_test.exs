defmodule EvoGit.Agent.ContextMergeTest do
  @moduledoc """
  `async: true` — every test builds its own real git repositories under the
  ExUnit `:tmp_dir`; no ETS / global process state is touched.

  Repository fixtures start from ONE per-module template (`setup_all`) whose
  `.git` is copied per test instead of re-running `git init` + the identity
  config (4 subprocesses) for every test; see `git_template!/0`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.ContextMerge
  alias EvoGit.Agent.ContextMerge.Report

  setup_all do
    template = git_template!()
    on_exit(fn -> File.rm_rf!(template) end)
    %{git_template: template}
  end

  describe "file_node_path/1" do
    test "root-level file maps to ./" do
      assert ContextMerge.file_node_path("CONTEXT.md") == "./"
    end

    test "one level deep" do
      assert ContextMerge.file_node_path("src/CONTEXT.md") == "./src"
    end

    test "nested" do
      assert ContextMerge.file_node_path("src/a/b/CONTEXT.md") == "./src/a/b"
    end

    test "already dot-slash prefixed" do
      assert ContextMerge.file_node_path("./src/CONTEXT.md") == "./src"
    end

    test "windows separators are normalized" do
      assert ContextMerge.file_node_path("src\\a\\b\\CONTEXT.md") == "./src/a/b"
    end

    test "non-binary input degrades to ./" do
      assert ContextMerge.file_node_path(nil) == "./"
    end
  end

  describe "ownership_strength/2" do
    test "the node dir itself is the owner (3)" do
      assert ContextMerge.ownership_strength("src/CONTEXT.md", "./src") == 3
      assert ContextMerge.ownership_strength("CONTEXT.md", "./") == 3
      assert ContextMerge.ownership_strength("src/a/CONTEXT.md", "./src/a") == 3
    end

    test "a strict ancestor gets 2, including the root" do
      assert ContextMerge.ownership_strength("src/CONTEXT.md", "./") == 2
      assert ContextMerge.ownership_strength("src/a/CONTEXT.md", "./src") == 2
    end

    test "segment-wise ancestor check — ./src is not an ancestor of ./src2" do
      assert ContextMerge.ownership_strength("src2/CONTEXT.md", "./src") == 1
    end

    test "a node below the file's dir is unrelated (1)" do
      assert ContextMerge.ownership_strength("src/CONTEXT.md", "./src/a") == 1
    end

    test "an unrelated node is 1" do
      assert ContextMerge.ownership_strength("src/CONTEXT.md", "./doc") == 1
    end
  end

  describe "decide/3" do
    test "out of scope child edit keeps ours" do
      assert ContextMerge.decide("src/CONTEXT.md", "./doc", ["./src"]) ==
               {:keep, :ours, :out_of_scope}
    end

    test "deeper owner wins over an ancestor" do
      assert ContextMerge.decide("src/CONTEXT.md", "./src", ["./"]) ==
               {:keep, :theirs, :deeper_owner}
    end

    test "ancestor owner wins over an out-of-scope child" do
      assert ContextMerge.decide("src/CONTEXT.md", "./", ["./src"]) ==
               {:keep, :ours, :ancestor_owner}
    end

    test "equal owner strength is a genuine conflict (3 vs 3)" do
      assert ContextMerge.decide("src/CONTEXT.md", "./src", ["./src"]) ==
               {:conflict, :unresolved, :same_ownership}
    end

    test "equal ancestor strength is a genuine conflict (2 vs 2)" do
      assert ContextMerge.decide("src/a/CONTEXT.md", "./src", ["./src", "./other"]) ==
               {:conflict, :unresolved, :same_ownership}
    end

    test "empty ours list keeps theirs when theirs >= 2" do
      assert ContextMerge.decide("src/CONTEXT.md", "./src", []) ==
               {:keep, :theirs, :deeper_owner}
    end

    test "never raises on malformed input" do
      assert {:keep, :ours, :out_of_scope} = ContextMerge.decide("src/CONTEXT.md", nil, [nil])
    end
  end

  describe "merge_children/3" do
    test "multi-child clean octopus merge", %{tmp_dir: tmp_dir, git_template: template} do
      dir = init_repo(template, Path.join(tmp_dir, "octopus"))

      base =
        commit_files(
          dir,
          [{"CONTEXT.md", "# Root\n"}, {"src/a.ex", "defmodule A do\nend\n"}],
          "base"
        )

      on_branch(dir, "child_one", base)
      child_one = commit_files(dir, [{"src/b.ex", "defmodule B do\nend\n"}], "child one")

      on_branch(dir, "child_two", base)
      child_two = commit_files(dir, [{"doc/x.md", "# Doc\n"}], "child two")

      on_branch(dir, "parent", base)

      report =
        ContextMerge.merge_children(
          dir,
          [child(0, child_one, "./src"), child(1, child_two, "./doc")],
          parent_node_path: "./"
        )

      assert report.status == :clean
      assert Enum.map(report.entries, & &1.status) == [:merged, :merged]
      assert report.auto_resolutions == []
      assert report.genuine_conflicts == []
      assert report.starting_sha == base
      assert report.head_sha == short_sha(dir)
      {:ok, head} = Git.rev_parse(dir)
      assert head != base
      assert File.read!(Path.join(dir, "src/b.ex")) =~ "defmodule B"
      assert File.read!(Path.join(dir, "doc/x.md")) == "# Doc\n"
      assert clean_worktree?(dir)
    end

    test "out-of-scope CONTEXT.md edit is dropped in favour of the owner", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "out_of_scope"))

      base =
        commit_files(
          dir,
          [
            {"src/CONTEXT.md", "base src context\n"},
            {"src/a.ex", "defmodule A do\nend\n"}
          ],
          "base"
        )

      # A manager spawned at ./doc edits ./src/CONTEXT.md (out of scope).
      on_branch(dir, "child_doc", base)

      child_sha =
        commit_files(
          dir,
          [{"src/CONTEXT.md", "doc manager src context\n"}, {"doc/x.md", "# Doc\n"}],
          "doc work"
        )

      # The parent (./src owner) also edited src/CONTEXT.md.
      on_branch(dir, "parent", base)
      commit_files(dir, [{"src/CONTEXT.md", "parent src context\n"}], "parent work")

      report =
        ContextMerge.merge_children(
          dir,
          [child(0, child_sha, "./doc", branch: "evogit-agent-T1-A0")],
          parent_node_path: "./src"
        )

      assert report.status == :clean

      assert [%{status: :auto_resolved, node_path: "./doc", commit_sha: ^child_sha}] =
               report.entries

      assert report.head_sha == short_sha(dir)

      assert report.auto_resolutions == [
               %{
                 file: "src/CONTEXT.md",
                 direction: :ours,
                 child_node_path: "./doc",
                 reason: :out_of_scope
               }
             ]

      assert [%{file: "src/CONTEXT.md", child_node_path: "./doc", diff: diff}] =
               report.dropped_edits

      assert diff =~ "doc manager src context"

      assert File.read!(Path.join(dir, "src/CONTEXT.md")) == "parent src context\n"
      assert File.read!(Path.join(dir, "doc/x.md")) == "# Doc\n"
      assert clean_worktree?(dir)
    end

    test "in-scope child beats an ancestor-level edit", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "in_scope"))

      base = commit_files(dir, [{"src/CONTEXT.md", "base src context\n"}], "base")

      on_branch(dir, "child_src", base)

      child_sha =
        commit_files(dir, [{"src/CONTEXT.md", "child src context\n"}], "child src work")

      on_branch(dir, "parent", base)
      commit_files(dir, [{"src/CONTEXT.md", "root parent context\n"}], "parent work")

      report =
        ContextMerge.merge_children(
          dir,
          [child(0, child_sha, "./src")],
          parent_node_path: "./"
        )

      assert report.status == :clean
      assert [%{status: :auto_resolved}] = report.entries

      assert [%{file: "src/CONTEXT.md", direction: :theirs, reason: :deeper_owner}] =
               report.auto_resolutions

      assert report.dropped_edits == []
      assert File.read!(Path.join(dir, "src/CONTEXT.md")) == "child src context\n"
      assert clean_worktree?(dir)
    end

    test "two children owning the same CONTEXT.md are a genuine conflict", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "same_owner"))

      base =
        commit_files(
          dir,
          [{"src/CONTEXT.md", "shared line\n"}, {"src/a.ex", "defmodule A do\nend\n"}],
          "base"
        )

      on_branch(dir, "child_one", base)
      child_one = commit_files(dir, [{"src/CONTEXT.md", "child one\n"}], "child one")

      on_branch(dir, "child_two", base)
      child_two = commit_files(dir, [{"src/CONTEXT.md", "child two\n"}], "child two")

      on_branch(dir, "parent", base)

      report =
        ContextMerge.merge_children(
          dir,
          [child(0, child_one, "./src"), child(1, child_two, "./src")],
          parent_node_path: "./"
        )

      assert report.status == :conflict
      assert [%{status: :merged}, %{status: :conflict}] = report.entries
      assert report.auto_resolutions == []
      assert clean_worktree?(dir)

      assert [conflict] = report.genuine_conflicts
      assert conflict.file == "src/CONTEXT.md"
      assert conflict.theirs_node_path == "./src"
      assert conflict.ours_node_path == "./src"
      assert conflict.theirs_strength == 3
      assert conflict.ours_strength == 3

      note = ContextMerge.format_note(report, "")
      assert note =~ "The merge was aborted"
      assert note =~ child_one
      assert note =~ child_two
      assert note =~ "theirs: ./src"
      assert note =~ "ours: ./src"
      assert note =~ "unresolved: both sides own this node"
      assert note =~ "Preserved (NOT deleted — the merge did not complete"
      assert note =~ "evogit-agent-T1-A0 (node ./src, merged)"
      assert note =~ "evogit-agent-T1-A1 (node ./src, conflict)"
      assert note =~ "git branch -D"
      refute note =~ "Branches of merged children were deleted"
    end

    test "a non-CONTEXT.md conflict is never auto-resolved", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "source_conflict"))

      base =
        commit_files(
          dir,
          [{"CONTEXT.md", "# Root\n"}, {"src/a.ex", "line\n"}],
          "base"
        )

      on_branch(dir, "child_one", base)
      child_one = commit_files(dir, [{"src/a.ex", "one\n"}], "child one")

      on_branch(dir, "child_two", base)
      child_two = commit_files(dir, [{"src/a.ex", "two\n"}], "child two")

      on_branch(dir, "parent", base)

      report =
        ContextMerge.merge_children(
          dir,
          [child(0, child_one, "./src"), child(1, child_two, "./src")],
          parent_node_path: "./"
        )

      assert report.status == :conflict
      assert [%{status: :merged}, %{status: :conflict}] = report.entries
      assert report.auto_resolutions == []
      assert clean_worktree?(dir)

      assert [conflict] = report.genuine_conflicts
      assert conflict.file == "src/a.ex"
      assert conflict.theirs_node_path == "./src"

      note = ContextMerge.format_note(report, "")
      assert note =~ "src/a.ex"
      assert note =~ child_two
      refute note =~ "Auto-resolutions applied"
    end

    test "no changes yields :no_changes and no note", %{tmp_dir: tmp_dir, git_template: template} do
      dir = init_repo(template, Path.join(tmp_dir, "no_changes"))
      head = commit_files(dir, [{"CONTEXT.md", "# Root\n"}], "base")

      report = ContextMerge.merge_children(dir, [child(0, head, "./")])

      assert report.status == :no_changes
      assert report.starting_sha == head
      assert [%{status: :merged}] = report.entries
      assert ContextMerge.format_note(report, "") == nil

      assert ContextMerge.merge_children(dir, []).status == :no_changes
      assert ContextMerge.format_note(%Report{status: :no_changes}, "") == nil
      assert is_binary(ContextMerge.format_note(%Report{}, ""))
      assert clean_worktree?(dir)
    end

    test "success note carries the sentence, resolutions and dropped diff", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "note"))

      base =
        commit_files(
          dir,
          [{"src/CONTEXT.md", "base src context\n"}, {"src/a.ex", "defmodule A do\nend\n"}],
          "base"
        )

      on_branch(dir, "child_doc", base)

      child_sha =
        commit_files(
          dir,
          [{"src/CONTEXT.md", "doc manager src context\n"}, {"doc/x.md", "# Doc\n"}],
          "doc work"
        )

      on_branch(dir, "parent", base)
      commit_files(dir, [{"src/CONTEXT.md", "parent src context\n"}], "parent work")

      report =
        ContextMerge.merge_children(
          dir,
          [child(0, child_sha, "./doc")],
          parent_node_path: "./src"
        )

      note = ContextMerge.format_note(report, "\nSystem Note: 1 cross-repo subagent(s).")

      assert note =~ "System Note: Successfully auto-merged changes from subagents."
      assert note =~ "System Note: 1 cross-repo subagent(s)."
      assert note =~ "  - src/CONTEXT.md: kept ours (node ./doc) — out_of_scope"
      assert note =~ "Dropped out-of-scope edit"
      assert note =~ "child node: ./doc"
      assert note =~ "doc manager src context"
      assert note =~ "Preserved: none."

      assert note =~
               "Branches of merged children were deleted (their changes are already in HEAD)."
    end

    test "format_note/2 never raises on a partially populated report" do
      report = %Report{status: :conflict}

      note = ContextMerge.format_note(report, nil)

      assert is_binary(note)
      assert note =~ "System Note: Auto-merging subagent changes hit conflicts."
      assert note =~ "HEAD unknown"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds the per-module repository template ONCE (paid 4 `git` subprocesses
  # per module instead of per test): `git init` with an EMPTY template dir (no
  # hook samples / description boilerplate, so the copied `.git` is a handful of
  # files), the fixture commit identity + `commit.gpgsign=false`, and
  # `core.abbrev=40` so `git commit` prints the new commit's FULL sha (see
  # `commit_files/3` — that removes one `git rev-parse` per commit).
  defp git_template! do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_git_template_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    empty_template = Path.join(root, "empty_template")
    File.mkdir_p!(empty_template)
    seed = Path.join(root, "seed")

    {_output, 0} =
      System.cmd("git", ["init", "-q", "--template=#{empty_template}", seed],
        stderr_to_stdout: true
      )

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"},
          {"core.abbrev", "40"}
        ] do
      {_output, 0} =
        System.cmd("git", ["config", key, value], cd: seed, stderr_to_stdout: true)
    end

    seed
  end

  # Copies the template's `.git` into `dir`: a fresh, isolated repository whose
  # every ref is created by this test.
  defp init_repo(template, dir) do
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(template, ".git"), Path.join(dir, ".git"))
    dir
  end

  defp commit_files(dir, files, message) do
    Enum.each(files, fn {path, content} ->
      full_path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)

    {:ok, _output} = Git.add(dir, ".")
    {:ok, output} = Git.commit(dir, message)
    committed_sha(dir, output)
  end

  # `git commit` prints "[<branch> <sha>] <subject>" — the template pins
  # `core.abbrev=40`, so that sha is complete and usable as a merge target
  # without an extra `rev-parse` spawn. If the output shape ever changes, fall
  # back to resolving HEAD (correct, only slower).
  defp committed_sha(dir, commit_output) do
    case Regex.run(~r/^\[[^\]]* ([0-9a-f]{40})\]/m, commit_output) do
      [_, sha] -> sha
      _ -> rev_parse!(dir)
    end
  end

  defp rev_parse!(dir) do
    {:ok, sha} = Git.rev_parse(dir)
    sha
  end

  defp on_branch(dir, branch, from_sha) do
    {:ok, _output} = Git.run(["checkout", "-q", "-B", branch, from_sha], dir)
    :ok
  end

  defp clean_worktree?(dir) do
    case Git.status(dir) do
      {:ok, output} -> output == ""
      _ -> false
    end
  end

  defp short_sha(dir) do
    {:ok, sha} = Git.rev_parse_short(dir)
    sha
  end

  defp child(index, commit_sha, node_path, opts \\ []) do
    %{
      index: index,
      commit_sha: commit_sha,
      branch: Keyword.get(opts, :branch, "evogit-agent-T1-A#{index}"),
      node_path: node_path,
      agent_module: Keyword.get(opts, :agent_module, EvoGit.Agents.Executor),
      objective: Keyword.get(opts, :objective, "test child")
    }
  end
end
