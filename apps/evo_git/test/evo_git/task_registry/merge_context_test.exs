defmodule EvoGit.TaskRegistry.MergeContextTest do
  @moduledoc """
  Tests for `EvoGit.TaskRegistry.MergeContext` — the merge-conflict-resolution
  context builder used by TaskExecutor when an evolve task is created with
  `:merge_from`/`:merge_target` opts.

  Uses `EvoGit.TaskRegistryCase` for an isolated Store + TaskRegistry on a
  temporary SQLite database, mirroring the persistence-test fixture pattern, so
  `EvoGit.TaskRegistry.get_task/1` returns persisted `%TaskInfo{}` fixtures.

  The TaskExecutor integration hook (`execute_task(:evolve, ...)`) is
  deliberately NOT tested here — it would invoke the full Evolution runtime
  (LLM). The pure `MergeContext` functions are the coverage.
  """

  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskRegistry.MergeContext

  describe "apply_merge_context/4" do
    test "strips merge keys, overrides starting_commit, carries foreign_repos, and prepends the block" do
      foreign_repos = [
        %ForeignRepo{
          id: "reference",
          root: "/tmp/reference-proj",
          description: "Reference implementation"
        }
      ]

      prev =
        insert_prev_task!(
          opts: [
            path: "/tmp/merge-context-prev",
            mode: "simple",
            foreign_repos: foreign_repos
          ]
        )

      # Persisted round trip: structs in opts decode as string-keyed maps.
      fetched = TaskRegistry.get_task(prev.id)
      assert %TaskInfo{} = fetched
      fetched_repos = Keyword.get(fetched.opts, :foreign_repos)
      assert is_list(fetched_repos)

      assert [
               %{
                 "id" => "reference",
                 "root" => "/tmp/reference-proj",
                 "description" => "Reference implementation"
               }
             ] = fetched_repos

      result =
        MergeContext.apply_merge_context(caller_opts(prev.id), "next_task_id", prev.id, "main")

      refute Keyword.has_key?(result, :merge_from)
      refute Keyword.has_key?(result, :merge_target)

      # Unrelated caller opts pass through untouched.
      assert Keyword.get(result, :path) == "/tmp/merge-context-next"
      assert Keyword.get(result, :mode) == "simple"

      # The previous task's end commit overrides the caller's starting_commit.
      assert Keyword.get(result, :starting_commit) == "commit222"
      assert Keyword.get(result, :starting_commit) == fetched.commit_sha

      # The previous task's foreign repos are carried over as %ForeignRepo{}
      # structs — the string-keyed maps from the store must be normalized back
      # (carrying them raw would crash downstream dot-access in Runtime.Helpers).
      assert Keyword.get(result, :foreign_repos) == foreign_repos

      # Objective = context block + blank line + original objective.
      block = MergeContext.build_merge_context_block(fetched, "main")
      objective = Keyword.get(result, :objective)
      assert String.starts_with?(objective, block)
      assert objective == block <> "\n\n" <> "Resolve the conflict on the merged code."
    end

    test "normalizes persisted string-keyed foreign repo maps and drops unparseable entries" do
      persisted_repos = [
        %{"id" => "x", "root" => "/abs/path", "description" => nil},
        %{"id" => "bad"}
      ]

      prev =
        insert_prev_task!(
          opts: [
            path: "/tmp/merge-context-prev",
            mode: "simple",
            foreign_repos: persisted_repos
          ]
        )

      result =
        MergeContext.apply_merge_context(caller_opts(prev.id), "task_1", prev.id, "main")

      assert Keyword.get(result, :foreign_repos) == [
               %ForeignRepo{id: "x", root: "/abs/path", description: nil}
             ]
    end

    test "preserves the caller's starting_commit when the previous task's commit_sha is nil or empty" do
      prev_nil = insert_prev_task!(commit_sha: nil)

      result_nil =
        MergeContext.apply_merge_context(caller_opts(prev_nil.id), "task_1", prev_nil.id, "main")

      assert Keyword.get(result_nil, :starting_commit) == "caller_start"

      prev_empty = insert_prev_task!(commit_sha: "")

      result_empty =
        MergeContext.apply_merge_context(
          caller_opts(prev_empty.id),
          "task_2",
          prev_empty.id,
          "main"
        )

      assert Keyword.get(result_empty, :starting_commit) == "caller_start"
    end

    test "does not add a :foreign_repos key when the previous task has none" do
      prev = insert_prev_task!(opts: [path: "/tmp/merge-context-prev", mode: "simple"])

      result =
        MergeContext.apply_merge_context(caller_opts(prev.id), "task_1", prev.id, "main")

      refute Keyword.has_key?(result, :foreign_repos)
    end

    test "returns the stripped opts unchanged when the previous task is not found" do
      merge_from = "missing_task_#{System.unique_integer([:positive])}"
      opts = caller_opts(merge_from)

      result = MergeContext.apply_merge_context(opts, "task_1", merge_from, "main")

      assert result == Keyword.drop(opts, [:merge_from, :merge_target])
      refute Keyword.has_key?(result, :merge_from)
      refute Keyword.has_key?(result, :merge_target)
      # No block was prepended.
      assert Keyword.get(result, :objective) == "Resolve the conflict on the merged code."
    end
  end

  describe "build_merge_context_block/2" do
    test "includes task id, shas, branch, merge target, goal, and hints" do
      task = build_task()
      block = MergeContext.build_merge_context_block(task, "main")

      assert block =~ "--- Merge Conflict Resolution Context ---"
      assert block =~ "Previous task id: #{task.id}"
      assert block =~ "Base sha: base111"
      assert block =~ "End (commit) sha: commit222"
      assert block =~ "Task branch name: genesis/agent_prev"
      assert block =~ "Merge target branch: main"
      assert block =~ "Goal:"
      assert block =~ "incremental milestone merges"
      assert block =~ "uncommitted"
      assert block =~ "`git log/diff"
      assert block =~ "--- End Merge Conflict Resolution Context ---"
    end

    test "omits the base sha line when base_sha is nil" do
      task = build_task(base_sha: nil)
      block = MergeContext.build_merge_context_block(task, "main")

      refute block =~ "Base sha:"
      assert block =~ "End (commit) sha: commit222"
    end

    test "uses unknown for a nil branch name" do
      task = build_task(branch_name: nil)
      block = MergeContext.build_merge_context_block(task, "main")

      assert block =~ "Task branch name: unknown"
    end

    test "uses unknown for a nil merge target" do
      task = build_task()
      block = MergeContext.build_merge_context_block(task, nil)

      assert block =~ "Merge target branch: unknown"
    end

    test "returns an empty string for non-TaskInfo input" do
      assert MergeContext.build_merge_context_block(nil, "main") == ""
      assert MergeContext.build_merge_context_block("not-a-task", "main") == ""
      assert MergeContext.build_merge_context_block(%{id: "x"}, "main") == ""
    end
  end

  # --- fixtures ---

  defp build_task(overrides \\ []) do
    unique = System.unique_integer([:positive])

    base = %TaskInfo{
      id: "merge_ctx_prev_#{unique}",
      type: :evolve,
      status: :completed,
      opts: [path: "/tmp/merge-context-prev", mode: "simple"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      result: nil,
      base_sha: "base111",
      commit_sha: "commit222",
      branch_name: "genesis/agent_prev"
    }

    struct!(base, overrides)
  end

  defp persist_task!(%TaskInfo{} = task) do
    EvoGit.Store.put_task(EvoGit.Store, task)
    task
  end

  defp insert_prev_task!(overrides) do
    build_task(overrides) |> persist_task!()
  end

  defp caller_opts(prev_id) do
    [
      path: "/tmp/merge-context-next",
      mode: "simple",
      objective: "Resolve the conflict on the merged code.",
      starting_commit: "caller_start",
      merge_from: prev_id,
      merge_target: "main"
    ]
  end
end
