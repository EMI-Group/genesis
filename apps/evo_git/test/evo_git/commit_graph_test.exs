defmodule EvoGit.CommitGraphTest do
  @moduledoc """
  Exercises the read-only commit-graph data API (`EvoGit.CommitGraph.for_ranges/3`
  and its `EvoGit.RemoteNode.list_commit_graph/4` delegation) against REAL git
  repositories created on throwaway temp dirs (no mocks, no Mox/Meck).

  Fixture idiom: each test gets a unique `@moduletag :tmp_dir` directory, in
  which a real repo is created and committed to through `EvoGit.Adapters.Git`.
  The deterministic commit identity is written to the repo's OWN git config via
  raw `git config` BEFORE the first adapter call, so `EvoGit.GitEnv` (which
  prefers the repo-configured identity over its placeholder) memoizes exactly
  that identity for that repo path.

  `async: true` because each test touches only its own temp repo and mutates no
  BEAM-global state another module observes: the sole cross-process write is the
  per-repo-path `EvoGit.GitEnv` identity memo (a `:persistent_term` entry keyed
  by the unique temp repo path, whose re-resolution yields the same value),
  exactly as `EvoGit.Adapters.GitTest` documents. No `PATH`/`XDG_*`/app-env
  rewrites, no shared ETS tables, no global scheduler, no pubsub.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.CommitGraph

  @moduletag :tmp_dir

  @author_name "Test Author"
  @author_email "author@example.com"

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)

    # Raw git (not the adapter) so no `EvoGit.GitEnv` resolution — and thus no
    # memoized identity — happens before the repo-local identity is configured.
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", @author_name])
    git!(repo, ["config", "user.email", @author_email])

    {:ok, %{repo: repo}}
  end

  test "parses the pretty-format fields of real commits", %{repo: repo} do
    base = commit!(repo, "a.txt", "a\n", "First commit")
    mid = commit!(repo, "b.txt", "b\n", "Second commit subject line")
    tip = commit!(repo, "c.txt", "c\n", "Third commit\n\nA body paragraph.")

    assert {:ok, %{commits: commits}} = CommitGraph.for_ranges(repo, [{base, tip}], [])

    assert [third, second] = commits
    assert third.sha == tip
    assert second.sha == mid

    # `:sha` is the full object name git reports for the tip.
    assert Regex.match?(~r/\A[0-9a-f]{40}\z/, third.sha)
    assert git!(repo, ["rev-parse", "main"]) == third.sha

    # `:short_sha` is a non-empty abbreviation of `:sha`.
    assert third.short_sha != ""
    assert String.starts_with?(third.sha, third.short_sha)

    # `:message` is the subject line only.
    assert third.message == "Third commit"
    assert second.message == "Second commit subject line"
    refute String.contains?(second.message, "\n")

    assert third.author_name == @author_name
    assert third.author_email == @author_email
    assert %DateTime{} = third.date

    # Exactly the seven documented keys.
    assert Enum.sort(Map.keys(third)) ==
             Enum.sort([
               :sha,
               :short_sha,
               :message,
               :author_name,
               :author_email,
               :date,
               :parents
             ])
  end

  test "records the exact parents of merge and root commits", %{repo: repo} do
    root = commit!(repo, "root.txt", "root\n", "Root commit")

    git!(repo, ["checkout", "-b", "feature"])
    feature = commit!(repo, "feature.txt", "feature\n", "Feature work")

    git!(repo, ["checkout", "main"])
    main_tip = commit!(repo, "main.txt", "main\n", "Main work")

    git!(repo, ["merge", "--no-ff", "-m", "Merge feature", "feature"])
    merge = git!(repo, ["rev-parse", "HEAD"])

    assert {:ok, %{commits: commits}} = CommitGraph.for_ranges(repo, [{root, merge}], [])

    merged = Enum.find(commits, &(&1.sha == merge))
    assert [^main_tip, ^feature] = merged.parents

    # A root commit has no parents. `git log base..tip` only excludes a commit
    # reachable FROM the base, so an unrelated (disjoint) root commit used as
    # the base keeps the target branch's own root commit inside the range.
    unrelated = unrelated_root!(repo)

    assert {:ok, %{commits: [root_commit]}} =
             CommitGraph.for_ranges(repo, [{unrelated, root}], [])

    assert root_commit.sha == root
    assert root_commit.parents == []
  end

  test "deduplicates commits shared by overlapping ranges", %{repo: repo} do
    c1 = commit!(repo, "f1.txt", "1\n", "one")
    c2 = commit!(repo, "f2.txt", "2\n", "two")
    c3 = commit!(repo, "f3.txt", "3\n", "three")
    c4 = commit!(repo, "f4.txt", "4\n", "four")

    assert {:ok, %{commits: commits}} = CommitGraph.for_ranges(repo, [{c1, c4}, {c2, c4}], [])

    shas = Enum.map(commits, & &1.sha)
    assert shas == Enum.uniq(shas)
    assert MapSet.new(shas) == MapSet.new([c4, c3, c2])
  end

  test "caps commits per range at opts[:limit]", %{repo: repo} do
    shas = for i <- 1..5, do: commit!(repo, "f#{i}.txt", "#{i}\n", "commit #{i}")
    [base | _] = shas
    tip = List.last(shas)

    assert {:ok, %{commits: capped}} = CommitGraph.for_ranges(repo, [{base, tip}], limit: 3)
    assert Enum.map(capped, & &1.sha) == Enum.take(Enum.reverse(shas), 3)

    # The default cap (100) is not reached by a small fixture, and a
    # non-positive limit falls back to that same default.
    assert {:ok, %{commits: all}} = CommitGraph.for_ranges(repo, [{base, tip}], [])
    assert Enum.map(all, & &1.sha) == Enum.take(Enum.reverse(shas), 4)

    assert {:ok, %{commits: zero_limit}} =
             CommitGraph.for_ranges(repo, [{base, tip}], limit: 0)

    assert length(zero_limit) == length(all)
  end

  test "skips invalid and unresolvable ranges without raising", %{repo: repo} do
    c1 = commit!(repo, "f1.txt", "1\n", "one")
    c2 = commit!(repo, "f2.txt", "2\n", "two")
    c3 = commit!(repo, "f3.txt", "3\n", "three")

    assert {:ok, %{commits: commits}} =
             CommitGraph.for_ranges(
               repo,
               [
                 {"nope-nope", "HEAD"},
                 {123, "HEAD"},
                 {"", c3},
                 :bogus,
                 {c1, c3}
               ],
               []
             )

    assert Enum.map(commits, & &1.sha) == [c3, c2]
  end

  test "an empty range (base == tip) yields no commits", %{repo: repo} do
    c1 = commit!(repo, "f1.txt", "1\n", "one")
    c2 = commit!(repo, "f2.txt", "2\n", "two")

    assert {:ok, %{commits: [], refs: refs}} = CommitGraph.for_ranges(repo, [{c2, c2}], [])
    assert refs == %{}

    assert {:ok, %{commits: []}} = CommitGraph.for_ranges(repo, [{c1, c1}], [])
  end

  test "labels returned commits with the branches and tags pointing at them", %{repo: repo} do
    c1 = commit!(repo, "f1.txt", "1\n", "one")
    c2 = commit!(repo, "f2.txt", "2\n", "two")
    c3 = commit!(repo, "f3.txt", "3\n", "three")

    {:ok, _} = Git.create_branch(repo, "feature", c2)
    {:ok, _} = Git.tag(repo, "v1.0", c3)
    # A branch whose target is OUTSIDE the returned range (it is the base).
    {:ok, _} = Git.create_branch(repo, "at-base", c1)

    assert {:ok, %{commits: commits, refs: refs}} = CommitGraph.for_ranges(repo, [{c1, c3}], [])

    assert Enum.map(commits, & &1.sha) == [c3, c2]

    assert refs[c2] == ["feature"]
    assert refs[c3] == ["main", "v1.0"]
    refute Map.has_key?(refs, c1)
  end

  test "a non-git directory yields empty commits and refs" do
    # Deliberately OUTSIDE the project checkout: git discovery walks up parent
    # directories, so a plain subdir of the repo tree would still resolve the
    # enclosing repository.
    plain =
      Path.join(
        System.tmp_dir!(),
        "evogit_commit_graph_plain_" <> to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)

    assert CommitGraph.for_ranges(plain, [{"HEAD~1", "HEAD"}], []) ==
             {:ok, %{commits: [], refs: %{}}}
  end

  test "RemoteNode.list_commit_graph/4 unwraps the local call", %{repo: repo} do
    c1 = commit!(repo, "f1.txt", "1\n", "one")
    c2 = commit!(repo, "f2.txt", "2\n", "two")
    {:ok, _} = Git.create_branch(repo, "feature", c2)

    assert {:ok, %{commits: commits, refs: refs}} = CommitGraph.for_ranges(repo, [{c1, c2}], [])

    assert EvoGit.RemoteNode.list_commit_graph(node(), repo, [{c1, c2}], []) ==
             {:ok, %{commits: commits, refs: refs}}
  end

  describe "for_task/4" do
    test "unions every tip, dedupes, and appends the base commit node", %{repo: repo} do
      # c1 is the pre-base commit that must NOT appear in the task graph.
      c1 = commit!(repo, "f1.txt", "1\n", "one")
      c2 = commit!(repo, "f2.txt", "2\n", "two (base)")
      {:ok, _} = Git.tag(repo, "base-tag", c2)

      # Branch `a` from the base.
      git!(repo, ["checkout", "-b", "a"])
      c3 = commit!(repo, "a1.txt", "a1\n", "a1")
      c4 = commit!(repo, "a2.txt", "a2\n", "a2")

      # Branch `b` from the base.
      git!(repo, ["checkout", "main"])
      git!(repo, ["checkout", "-b", "b"])
      c5 = commit!(repo, "b1.txt", "b1\n", "b1")
      c6 = commit!(repo, "b2.txt", "b2\n", "b2")

      # tips intentionally include nil/blank/duplicate entries.
      assert {:ok, %{commits: commits, refs: refs}} =
               CommitGraph.for_task(repo, c2, [c4, c6, c4, nil, "", "", c3], [])

      # Range commits newest-first per range, then the base appended last.
      assert Enum.map(commits, & &1.sha) == [c4, c3, c6, c5, c2]

      # The base commit itself is a node with its REAL parents (c1 is NOT
      # fetched — it marks the graph boundary).
      base_node = Enum.find(commits, &(&1.sha == c2))
      assert base_node.parents == [c1]
      refute Enum.any?(commits, &(&1.sha == c1))

      # The base node carries the branch/tag labels pointing at it.
      assert "base-tag" in refs[c2]
      assert "main" in refs[c2]
      assert refs[c4] == ["a"]
      assert refs[c6] == ["b"]
    end

    test "a nil/blank base yields an empty graph", %{repo: repo} do
      c1 = commit!(repo, "f1.txt", "1\n", "one")

      assert CommitGraph.for_task(repo, nil, [c1], []) == {:ok, %{commits: [], refs: %{}}}
      assert CommitGraph.for_task(repo, "", [c1], []) == {:ok, %{commits: [], refs: %{}}}
      assert CommitGraph.for_task(repo, "   ", [c1], []) == {:ok, %{commits: [], refs: %{}}}
    end

    test "no usable tips yields only the base node", %{repo: repo} do
      _c1 = commit!(repo, "f1.txt", "1\n", "one")
      c2 = commit!(repo, "f2.txt", "2\n", "two (base)")

      assert {:ok, %{commits: [node], refs: refs}} = CommitGraph.for_task(repo, c2, [], [])
      assert node.sha == c2
      assert refs[c2] == ["main"]

      assert CommitGraph.for_task(repo, c2, [nil, "", 123, :nope], []) ==
               {:ok, %{commits: [node], refs: refs}}
    end

    test "caps range commits at opts[:limit] while always keeping the base", %{repo: repo} do
      shas = for i <- 1..5, do: commit!(repo, "f#{i}.txt", "#{i}\n", "commit #{i}")
      [base | _] = shas
      tip = List.last(shas)

      assert {:ok, %{commits: commits}} = CommitGraph.for_task(repo, base, [tip], limit: 2)
      assert Enum.map(commits, & &1.sha) == [tip, Enum.at(shas, 3), base]
    end

    test "degrades to empty for an unresolvable base or a non-git directory", %{repo: repo} do
      c1 = commit!(repo, "f1.txt", "1\n", "one")
      c2 = commit!(repo, "f2.txt", "2\n", "two")

      # Unresolvable base ref → no range commits, no base node.
      assert CommitGraph.for_task(repo, "no-such-ref", [c2], []) ==
               {:ok, %{commits: [], refs: %{}}}

      # Unresolvable tips drop, but the base node still resolves.
      assert {:ok, %{commits: [node]}} = CommitGraph.for_task(repo, c1, ["nope-ref", 42], [])
      assert node.sha == c1

      plain =
        Path.join(
          System.tmp_dir!(),
          "evogit_commit_graph_task_plain_" <> to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf!(plain) end)

      assert CommitGraph.for_task(plain, "HEAD", ["HEAD"], []) ==
               {:ok, %{commits: [], refs: %{}}}
    end
  end

  # Writes/overwrites a file, stages it, commits, and returns the full SHA.
  defp commit!(repo, filename, content, message) do
    File.write!(Path.join(repo, filename), content)
    {:ok, _} = Git.add(repo, filename)
    {:ok, _} = Git.commit(repo, message)
    {:ok, sha} = Git.rev_parse(repo, "HEAD")
    sha
  end

  # Creates an unrelated root commit (same tree, no parents) and returns its
  # SHA. `git log <unrelated>..<tip>` then contains every commit reachable from
  # `tip`, the tip branch's own root commit included.
  defp unrelated_root!(repo) do
    tree = git!(repo, ["rev-parse", "HEAD^{tree}"])
    git!(repo, ["commit-tree", tree, "-m", "Unrelated root"])
  end

  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    if status != 0 do
      flunk("git #{Enum.join(args, " ")} failed in #{dir}: #{output}")
    end

    String.trim(output)
  end
end
