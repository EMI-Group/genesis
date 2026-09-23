defmodule EvoGit.TaskCommitGraphTest do
  @moduledoc """
  Exercises `EvoGit.TaskCommitGraph` (`resolve_refs/1`, `resolve/1`,
  `for_task/4` and the `EvoGit.RemoteNode.list_task_commit_graph/5` delegation)
  against REAL git repositories created on throwaway temp dirs plus an ISOLATED
  `EvoGit.Store` + `EvoGit.TaskRegistry` pair (`EvoGit.TaskRegistryCase`).

  Isolation: `EvoGit.TaskRegistryCase` starts uniquely-named Store/Registry
  instances and points `EvoGit.TaskRegistry.server/0` at them via the
  `:evogit_task_registry_server` process-dictionary key — `async: true` is safe
  because nothing app-global is touched. The git fixture follows
  `commit_graph_test.exs`: a REAL repo per test, deterministic repo-local
  identity written via raw `git config` BEFORE the first adapter call.
  """

  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskCommitGraph

  @author_name "Test Author"
  @author_email "author@example.com"

  setup do
    unique = System.unique_integer([:positive])
    repo = Path.join(System.tmp_dir!(), "evogit_task_commit_graph_#{unique}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)

    # Raw git so no `EvoGit.GitEnv` identity resolution is memoized before the
    # repo-local identity is configured.
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", @author_name])
    git!(repo, ["config", "user.email", @author_email])

    {:ok, %{repo: repo}}
  end

  describe "resolve_refs/1 (pure)" do
    test "a nil task yields the empty ref map" do
      assert TaskCommitGraph.resolve_refs(nil) ==
               %{base_sha: nil, tips: [], project_path: nil}
    end

    test "gathers commit_sha, branch_name and the result's repos entries" do
      task = %TaskInfo{
        id: "t1",
        type: :evolve,
        project_path: "/repo",
        base_sha: "base-1",
        commit_sha: "durable-commit",
        branch_name: "genesis/agent_deadbeef",
        result: %{
          "repos" => %{
            "primary" => %{"commit_sha" => "primary-sha", "branch_name" => "b1"},
            "original" => %{"commit_sha" => "foreign-sha", "branch_name" => "b2"}
          }
        }
      }

      refs = TaskCommitGraph.resolve_refs(task)

      assert refs.base_sha == "base-1"
      assert refs.project_path == "/repo"

      assert Enum.sort(refs.tips) ==
               Enum.sort([
                 "durable-commit",
                 "genesis/agent_deadbeef",
                 "primary-sha",
                 "b1",
                 "foreign-sha",
                 "b2"
               ])
    end

    test "drops blanks, nils, and duplicate tips; a legacy/nil result never crashes" do
      task = %TaskInfo{
        id: "t2",
        type: :evolve,
        project_path: "/repo",
        base_sha: "   ",
        commit_sha: "dup",
        branch_name: "dup",
        result: %{"repos" => %{"primary" => %{"commit_sha" => nil, "branch_name" => ""}}}
      }

      refs = TaskCommitGraph.resolve_refs(task)

      assert refs.base_sha == nil
      assert refs.tips == ["dup"]

      legacy = %TaskInfo{id: "t3", type: :genesis, result: nil}

      assert TaskCommitGraph.resolve_refs(legacy) ==
               %{base_sha: nil, tips: [], project_path: nil}

      no_repos = %TaskInfo{id: "t4", type: :genesis, commit_sha: "c", result: %{"other" => 1}}
      assert TaskCommitGraph.resolve_refs(no_repos).tips == ["c"]
    end
  end

  describe "resolve/1 (isolated registry)" do
    test "reads the durable refs off the persisted task row" do
      task_id = "resolve_#{System.unique_integer([:positive])}"

      EvoGit.Store.put_task(store(), %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        project_path: "/repo",
        opts: [path: "/repo"],
        result:
          {:ok, %{"repos" => %{"primary" => %{"commit_sha" => "p-sha", "branch_name" => "p-b"}}}}
      })

      EvoGit.TaskRegistry.set_review_metadata(task_id, "the-base", "the-commit")
      # Sync so the cast has been processed.
      EvoGit.TaskRegistry.list_tasks()

      refs = TaskCommitGraph.resolve(task_id)

      assert refs.base_sha == "the-base"
      assert refs.project_path == "/repo"
      assert Enum.sort(refs.tips) == ["p-b", "p-sha", "the-commit"]
    end

    test "a nil/unknown task degrades to the empty ref map" do
      assert TaskCommitGraph.resolve("does-not-exist") ==
               %{base_sha: nil, tips: [], project_path: nil}

      assert TaskCommitGraph.resolve(nil) == %{base_sha: nil, tips: [], project_path: nil}
    end
  end

  describe "for_task/4" do
    test "live-agent tips alone drive the graph when no durable task ref exists", %{repo: repo} do
      c1 = commit!(repo, "f1.txt", "1\n", "one")
      c2 = commit!(repo, "f2.txt", "2\n", "two (base)")

      # The live agent commits on its own branch, so HEAD (main) stays at the
      # task base.
      git!(repo, ["checkout", "-b", "agent"])
      c3 = commit!(repo, "f3.txt", "3\n", "three (agent tip)")
      git!(repo, ["checkout", "main"])

      # Unknown task id -> no durable refs; the merge-base of HEAD (at the base)
      # and the live tip recovers the task base.
      assert {:ok, %{commits: commits, refs: refs}} =
               TaskCommitGraph.for_task("no-such-task", repo, [c3], [])

      assert Enum.map(commits, & &1.sha) == [c3, c2]
      refute Enum.any?(commits, &(&1.sha == c1))
      assert "main" in refs[c2]
      assert refs[c3] == ["agent"]
    end

    test "a durable task commit alone drives the graph with no live agents", %{repo: repo} do
      c1 = commit!(repo, "f1.txt", "1\n", "one")
      c2 = commit!(repo, "f2.txt", "2\n", "two (base)")
      c3 = commit!(repo, "f3.txt", "3\n", "three (durable result commit)")

      task_id = "durable_#{System.unique_integer([:positive])}"

      EvoGit.Store.put_task(store(), %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        project_path: repo,
        opts: [path: repo]
      })

      EvoGit.TaskRegistry.set_review_metadata(task_id, c2, c3)
      EvoGit.TaskRegistry.list_tasks()

      assert {:ok, %{commits: commits}} = TaskCommitGraph.for_task(task_id, repo, [], [])

      assert Enum.map(commits, & &1.sha) == [c3, c2]
      refute Enum.any?(commits, &(&1.sha == c1))
    end

    test "opts[:base_sha] overrides every other base source", %{repo: repo} do
      c1 = commit!(repo, "f1.txt", "1\n", "one")
      c2 = commit!(repo, "f2.txt", "2\n", "two")
      c3 = commit!(repo, "f3.txt", "3\n", "three")

      assert {:ok, %{commits: commits}} =
               TaskCommitGraph.for_task("no-such-task", repo, [c3], base_sha: c1)

      # base = c1 (override), not the merge-base with HEAD (which is c3).
      assert Enum.map(commits, & &1.sha) == [c3, c2, c1]
    end

    test "a matching foreign repo entry supplies the base (STRING-keyed round-trip shape)",
         %{repo: repo} do
      c1 = commit!(repo, "f1.txt", "1\n", "one")
      _c2 = commit!(repo, "f2.txt", "2\n", "two")

      task_id = "foreign_#{System.unique_integer([:positive])}"

      # project_path deliberately does NOT match `repo`, so the base must come
      # from the foreign-repo entry.
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        project_path: "/some/other/path",
        opts: [path: "/some/other/path"]
      })

      foreign = %{"id" => "original", "root" => repo, "base_sha" => c1}

      assert {:ok, %{commits: [node]}} =
               TaskCommitGraph.for_task(task_id, repo, [], foreign_repos: [foreign])

      assert node.sha == c1

      # The struct form works identically.
      assert {:ok, %{commits: [node]}} =
               TaskCommitGraph.for_task(task_id, repo, [],
                 foreign_repos: [ForeignRepo.new("original", repo, base_sha: c1)]
               )

      assert node.sha == c1
    end

    test "degrades to an empty graph for an unresolvable everything", %{repo: repo} do
      _c1 = commit!(repo, "f1.txt", "1\n", "one")

      assert TaskCommitGraph.for_task("no-such-task", repo, [], []) ==
               {:ok, %{commits: [], refs: %{}}}
    end
  end

  test "RemoteNode.list_task_commit_graph/5 unwraps the local call", %{repo: repo} do
    _c1 = commit!(repo, "f1.txt", "1\n", "one")
    _c2 = commit!(repo, "f2.txt", "2\n", "two (base)")
    c3 = commit!(repo, "f3.txt", "3\n", "three")

    assert EvoGit.RemoteNode.list_task_commit_graph(node(), "no-such-task", repo, [c3], []) ==
             TaskCommitGraph.for_task("no-such-task", repo, [c3], [])
  end

  # Writes/overwrites a file, stages it, commits, and returns the full SHA.
  defp commit!(repo, filename, content, message) do
    File.write!(Path.join(repo, filename), content)
    {:ok, _} = Git.add(repo, filename)
    {:ok, _} = Git.commit(repo, message)
    {:ok, sha} = Git.rev_parse(repo, "HEAD")
    sha
  end

  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    if status != 0 do
      flunk("git #{Enum.join(args, " ")} failed in #{dir}: #{output}")
    end

    String.trim(output)
  end
end
