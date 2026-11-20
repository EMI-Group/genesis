defmodule EvoDash.ProjectGitTest do
  use ExUnit.Case, async: true

  alias EvoDash.ProjectGit
  alias EvoGit.Adapters.Git

  setup do
    root = Path.join(System.tmp_dir!(), "workbench-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ~w(init -b main))
    File.write!(Path.join(root, "notes.txt"), "main version\n")
    git!(root, ~w(add notes.txt))
    git!(root, ["commit", "-m", "Initial version"])
    %{root: root}
  end

  test "parses index, worktree, untracked and renamed paths without splitting names", %{
    root: root
  } do
    path = " notes\nfrom git .txt "
    File.write!(Path.join(root, "notes.txt"), "staged line\n")
    git!(root, ~w(add notes.txt))
    File.write!(Path.join(root, "notes.txt"), "working line\n")
    File.write!(Path.join(root, path), "untracked line\n")

    assert {:ok, snapshot} = ProjectGit.snapshot(node(), root)
    assert snapshot.branch == "main"
    assert snapshot.subject == "Initial version"

    assert %{kind: :staged} = staged = Enum.find(snapshot.changes, &(&1.kind == :staged))
    assert %{kind: :unstaged} = unstaged = Enum.find(snapshot.changes, &(&1.kind == :unstaged))
    assert %{path: ^path} = untracked = Enum.find(snapshot.changes, &(&1.kind == :untracked))
    assert {:ok, %{text: text}} = ProjectGit.diff(node(), root, staged)
    assert text =~ "+staged line"
    assert {:ok, %{text: text}} = ProjectGit.diff(node(), root, unstaged)
    assert text =~ "+working line"
    assert {:ok, %{text: text}} = ProjectGit.diff(node(), root, untracked)
    assert text =~ "+untracked line"

    git!(root, ["restore", "--staged", "--worktree", "notes.txt"])
    git!(root, ["mv", "notes.txt", "new notes.txt"])
    assert {:ok, snapshot} = ProjectGit.snapshot(node(), root)

    assert %{path: "new notes.txt", from: "notes.txt", code: "R"} =
             Enum.find(snapshot.changes, &(&1.kind == :staged))
  end

  test "resolves a task commit without checking out the branch and preserves conflicting edits",
       %{root: root} do
    git!(root, ~w(switch -c feature))
    File.write!(Path.join(root, "notes.txt"), "feature version\n")
    git!(root, ["commit", "-am", "Feature version"])
    feature_sha = git!(root, ~w(rev-parse HEAD))
    git!(root, ~w(switch main))

    assert {:ok, snapshot} = ProjectGit.snapshot(node(), root)
    branch = Enum.find(snapshot.branches, &(&1.name == "feature"))
    assert {:ok, ^feature_sha} = ProjectGit.starting_commit(node(), root, branch)
    assert git!(root, ~w(branch --show-current)) == "main"

    File.write!(Path.join(root, "notes.txt"), "uncommitted version\n")
    assert {:error, {_code, detail}} = ProjectGit.switch_branch(node(), root, branch)
    assert detail =~ "would be overwritten"
    assert File.read!(Path.join(root, "notes.txt")) == "uncommitted version\n"
    assert git!(root, ~w(branch --show-current)) == "main"

    git!(root, ~w(restore notes.txt))
    assert {:ok, _} = ProjectGit.switch_branch(node(), root, branch)
    assert {:ok, %{branch: "feature", commit: ^feature_sha}} = ProjectGit.snapshot(node(), root)
  end

  test "checks out a remote-tracking branch and omits its symbolic HEAD", %{root: root} do
    git!(root, ["remote", "add", "origin", root])
    git!(root, ~w(update-ref refs/remotes/origin/feature HEAD))
    git!(root, ~w(symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feature))

    assert {:ok, %{branches: branches}} = ProjectGit.snapshot(node(), root)
    refute Enum.any?(branches, &(&1.name == "origin/HEAD"))
    assert %{kind: :remote} = branch = Enum.find(branches, &(&1.name == "origin/feature"))
    assert {:ok, _} = ProjectGit.switch_branch(node(), root, branch)

    assert {:ok, %{branch: "feature", upstream: "origin/feature", ahead: "0", behind: "0"}} =
             ProjectGit.snapshot(node(), root)
  end

  test "paginates a pinned branch history and previews committed changes independently of the worktree",
       %{root: root} do
    for sequence <- 1..31 do
      File.write!(Path.join(root, "notes.txt"), "revision #{sequence}\n")
      git!(root, ["commit", "-am", "Revision #{sequence}"])
    end

    tip = git!(root, ~w(rev-parse HEAD))
    File.write!(Path.join(root, "notes.txt"), "working copy change\n")
    assert {:ok, first} = ProjectGit.commits(node(), root, tip, 0)
    assert first.more?
    assert length(first.rows) == 30
    assert [%{sha: ^tip, subject: "Revision 31"} | _] = first.rows

    assert {:ok, %{rows: [_, initial], more?: false}} = ProjectGit.commits(node(), root, tip, 30)
    assert initial.subject == "Initial version"
    assert {:ok, %{text: patch}} = ProjectGit.commit_diff(node(), root, initial.sha)
    assert patch =~ "+main version"
    refute patch =~ "working copy change"
    assert File.read!(Path.join(root, "notes.txt")) == "working copy change\n"
  end

  defp git!(root, args) do
    assert {:ok, output} = Git.run(args, root)
    output
  end
end
