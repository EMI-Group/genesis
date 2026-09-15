defmodule EvoGit.TaskRegistry.MergeContextBlockTest do
  @moduledoc """
  Pure-function coverage for `EvoGit.TaskRegistry.MergeContext.build_merge_context_block/2`
  — the merge-conflict-resolution context block rendered from a `%TaskInfo{}`.

  These tests build their `%TaskInfo{}` fixture locally and never touch the
  Store or the registry, so the module runs `async: true`. It was extracted
  from `EvoGit.TaskRegistry.MergeContextTest` (which uses the `async: false`
  `EvoGit.TaskRegistryCase` fixture, terminating + restarting the global
  `EvoGit.TaskRegistry` / `EvoGit.Store` app children) so that pure tests no
  longer pay for that heavy per-test setup.
  """

  use ExUnit.Case, async: true

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry.MergeContext

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
end
