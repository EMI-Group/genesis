defmodule EvoGit.TaskRegistry.MergeContextBlockTest do
  @moduledoc """
  Pure-function coverage for `EvoGit.TaskRegistry.MergeContext.build_merge_context_block/2`
  — the merge-conflict-resolution context block rendered from a `%TaskInfo{}`.

  These tests build their `%TaskInfo{}` fixture locally and never touch the
  Store or the registry, so the module runs `async: true`. It was extracted
  from `EvoGit.TaskRegistry.MergeContextTest` (whose `EvoGit.TaskRegistryCase`
  fixture starts an isolated per-test `EvoGit.Store` + `EvoGit.TaskRegistry`
  pair for its real database round trips) so that pure tests no longer pay for
  that heavier per-test setup.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry.MergeContext

  # Hint fragments that predate the CONTEXT.md merge-conflict policy — they must
  # keep rendering unchanged.
  @preexisting_hint_fragments [
    "Hints:",
    "Commit conflict resolutions before delegating",
    "inspect `git log/diff",
    "incremental milestone merges"
  ]

  # The CONTEXT.md-specific merge-conflict policy hints appended after the
  # pre-existing hints.
  @context_md_policy_fragments [
    "CONTEXT.md conflicts are ownership conflicts, not text conflicts",
    "keep that side's version",
    "do NOT pick one side wholesale",
    "`edit_context`",
    "routing entry for a child subdirectory must survive",
    "note the ambiguity"
  ]

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

    test "keeps every pre-existing hint fragment" do
      block = MergeContext.build_merge_context_block(build_task(), "main")

      for fragment <- @preexisting_hint_fragments do
        assert block =~ fragment, "missing pre-existing hint fragment: #{fragment}"
      end
    end

    test "includes the CONTEXT.md merge-conflict policy hints" do
      block = MergeContext.build_merge_context_block(build_task(), "main")

      for fragment <- @context_md_policy_fragments do
        assert block =~ fragment, "missing CONTEXT.md policy fragment: #{fragment}"
      end
    end

    test "starts and ends with the context block delimiters" do
      block = MergeContext.build_merge_context_block(build_task(), "main")

      assert String.starts_with?(block, "--- Merge Conflict Resolution Context ---")
      assert String.ends_with?(block, "--- End Merge Conflict Resolution Context ---")
    end

    test "appends the policy hints before the closing delimiter" do
      block = MergeContext.build_merge_context_block(build_task(), "main")

      closing = "--- End Merge Conflict Resolution Context ---"
      [before_closing, after_closing] = String.split(block, closing)

      assert before_closing =~ "CONTEXT.md conflicts are ownership conflicts"
      assert after_closing == ""
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

    test "derives foreign repos from the previous task's opts and keeps the policy hints" do
      task =
        build_task(
          opts: [
            path: "/tmp/merge-context-prev",
            mode: "simple",
            foreign_repos: [
              %ForeignRepo{id: "orig", root: "/tmp/orig", writable: true, base_sha: "abc123"}
            ]
          ]
        )

      block = MergeContext.build_merge_context_block(task, "main")

      assert block =~ "Writable foreign repos: orig@abc123"

      for fragment <- @preexisting_hint_fragments ++ @context_md_policy_fragments do
        assert block =~ fragment, "missing hint fragment: #{fragment}"
      end
    end

    test "returns an empty string for non-TaskInfo input" do
      assert MergeContext.build_merge_context_block(nil, "main") == ""
      assert MergeContext.build_merge_context_block("not-a-task", "main") == ""
      assert MergeContext.build_merge_context_block(%{id: "x"}, "main") == ""
    end
  end

  describe "build_merge_context_block/3" do
    test "includes the pre-existing and CONTEXT.md policy hints with explicit foreign repos" do
      foreign_repos = [
        %ForeignRepo{id: "orig", root: "/tmp/orig", writable: true, base_sha: "abc123"}
      ]

      block = MergeContext.build_merge_context_block(build_task(), "main", foreign_repos)

      assert block =~ "--- Merge Conflict Resolution Context ---"
      assert block =~ "Writable foreign repos: orig@abc123"
      assert block =~ "--- End Merge Conflict Resolution Context ---"

      for fragment <- @preexisting_hint_fragments ++ @context_md_policy_fragments do
        assert block =~ fragment, "missing hint fragment: #{fragment}"
      end

      assert String.ends_with?(block, "--- End Merge Conflict Resolution Context ---")
    end

    test "returns an empty string for non-TaskInfo input" do
      assert MergeContext.build_merge_context_block(nil, "main", []) == ""
      assert MergeContext.build_merge_context_block("not-a-task", "main", []) == ""
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
end
