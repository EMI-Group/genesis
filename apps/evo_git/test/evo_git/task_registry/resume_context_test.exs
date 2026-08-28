defmodule EvoGit.TaskRegistry.ResumeContextTest do
  @moduledoc """
  Tests for `EvoGit.TaskRegistry.ResumeContext` — the resume-context builder
  used by TaskExecutor when an evolve task resumes from a previous task
  (`:resume_from`).

  `build_resume_context_block/1` and `extract_result_summary/1` are pure
  functions over a `%TaskInfo{}` struct (no git/DB needed), so the tests
  construct structs directly. `apply_resume_context/3` calls
  `EvoGit.TaskRegistry.get_task/1` plus the Store-backed runtime-opts builder,
  so it runs on `EvoGit.TaskRegistryCase` — an isolated TaskRegistry + Store
  on a temporary SQLite database (mirroring the merge-context test fixture
  pattern).
  """

  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskRegistry.ResumeContext

  describe "build_resume_context_block/1" do
    test "builds a fully delimited block with commits, objective, and result" do
      task =
        build_task(
          opts: [path: "/tmp/prev", mode: "simple", objective: "Add feature X"],
          result: {:ok, %{result: "Implemented feature X.\nAll tests pass."}}
        )

      assert ResumeContext.build_resume_context_block(task) ==
               "--- Previous Task Context ---\n" <>
                 "Previous task commits: base111..commit222\n" <>
                 "\n" <>
                 "Previous task objective:\n" <>
                 "<<<BEGIN OBJECTIVE>>>\n" <>
                 "Add feature X\n" <>
                 "<<<END OBJECTIVE>>>\n" <>
                 "\n" <>
                 "Previous task result:\n" <>
                 "<<<BEGIN RESULT>>>\n" <>
                 "Implemented feature X.\n" <>
                 "All tests pass.\n" <>
                 "<<<END RESULT>>>\n" <>
                 "--- End Previous Task Context ---"
    end

    test "labels and delimiters are present in the block" do
      task =
        build_task(
          opts: [path: "/tmp/prev", mode: "simple", objective: "Add feature X"],
          result: {:ok, %{result: "Implemented feature X."}}
        )

      block = ResumeContext.build_resume_context_block(task)

      assert String.starts_with?(block, "--- Previous Task Context ---\n")
      assert String.ends_with?(block, "\n--- End Previous Task Context ---")
      assert block =~ "Previous task commits: base111..commit222"

      assert block =~
               "Previous task objective:\n<<<BEGIN OBJECTIVE>>>\nAdd feature X\n<<<END OBJECTIVE>>>"

      assert block =~
               "Previous task result:\n<<<BEGIN RESULT>>>\nImplemented feature X.\n<<<END RESULT>>>"
    end

    test "multi-line result content stays inside the delimiters" do
      result_text =
        "## Summary\n" <>
          "Added the parser and wired it into the CLI.\n\n" <>
          "--- End Previous Task Context ---\n" <>
          "This line looks like the outer fence but is result content."

      block =
        ResumeContext.build_resume_context_block(
          build_task(result: {:ok, %{result: result_text}})
        )

      # The entire result, including fence-adjacent and markdown-header lines,
      # sits between the BEGIN and END delimiters.
      assert block =~ "<<<BEGIN RESULT>>>\n" <> result_text <> "\n<<<END RESULT>>>"

      # The real outer end fence follows the END RESULT delimiter...
      assert block =~ "<<<END RESULT>>>\n--- End Previous Task Context ---"

      # ...and the outer fence appears exactly once more (the in-content
      # occurrence is inside the result delimiters).
      assert length(String.split(block, "--- End Previous Task Context ---")) == 3
    end

    test "multi-line objective content stays inside the delimiters" do
      objective = "Add feature X.\nInclude tests.\nHandle edge cases."

      task = build_task(opts: [path: "/tmp/prev", mode: "simple", objective: objective])

      block = ResumeContext.build_resume_context_block(task)

      assert block =~ "<<<BEGIN OBJECTIVE>>>\n" <> objective <> "\n<<<END OBJECTIVE>>>"
      refute block =~ "Previous task result:"
    end

    test "falls back to the :prompt key for the objective" do
      task = build_task(opts: [path: "/tmp/prev", mode: "simple", prompt: "Generate a parser"])

      block = ResumeContext.build_resume_context_block(task)

      assert block =~ "<<<BEGIN OBJECTIVE>>>\nGenerate a parser\n<<<END OBJECTIVE>>>"
    end

    test "omits the commits section when commit_sha is nil or empty" do
      block_nil = ResumeContext.build_resume_context_block(build_task(commit_sha: nil))
      refute block_nil =~ "Previous task commits:"

      block_empty = ResumeContext.build_resume_context_block(build_task(commit_sha: ""))
      refute block_empty =~ "Previous task commits:"
    end

    test "falls back to just commit_sha when base_sha is nil" do
      block = ResumeContext.build_resume_context_block(build_task(base_sha: nil))
      assert block =~ "Previous task commits: commit222"
    end

    test "omits the result section when the result is nil or empty" do
      block_nil = ResumeContext.build_resume_context_block(build_task(result: nil))
      refute block_nil =~ "Previous task result:"

      block_empty =
        ResumeContext.build_resume_context_block(build_task(result: {:ok, %{result: ""}}))

      refute block_empty =~ "Previous task result:"
    end

    test "omits the objective section when the objective is absent or empty" do
      block_absent =
        ResumeContext.build_resume_context_block(
          build_task(opts: [path: "/tmp/prev", mode: "simple"])
        )

      refute block_absent =~ "Previous task objective:"

      block_empty =
        ResumeContext.build_resume_context_block(
          build_task(opts: [path: "/tmp/prev", mode: "simple", objective: ""])
        )

      refute block_empty =~ "Previous task objective:"
    end

    test "returns an empty string when no useful context is available" do
      assert ResumeContext.build_resume_context_block(
               build_task(commit_sha: nil, opts: nil, result: nil)
             ) == ""

      assert ResumeContext.build_resume_context_block(
               build_task(commit_sha: nil, opts: [path: "/tmp/prev"], result: "")
             ) == ""
    end

    test "returns an empty string for non-TaskInfo input" do
      assert ResumeContext.build_resume_context_block(nil) == ""
      assert ResumeContext.build_resume_context_block("not-a-task") == ""
      assert ResumeContext.build_resume_context_block(%{id: "x"}) == ""
    end
  end

  describe "extract_result_summary/1" do
    test "extracts a binary result from {:ok, %{result: ...}}" do
      assert ResumeContext.extract_result_summary({:ok, %{result: "Done."}}) == "Done."
    end

    test "stringifies an atom result from {:ok, %{result: ...}}" do
      assert ResumeContext.extract_result_summary({:ok, %{result: :completed}}) == "completed"
    end

    test "formats {:error, reason}" do
      assert ResumeContext.extract_result_summary({:error, :merge_failed}) ==
               "Error: :merge_failed"

      assert ResumeContext.extract_result_summary({:error, "boom"}) == "Error: \"boom\""
    end

    test "formats {:exit, reason}" do
      assert ResumeContext.extract_result_summary({:exit, :killed}) == "Exited: :killed"
    end

    test "returns nil for anything else" do
      assert ResumeContext.extract_result_summary(nil) == nil
      assert ResumeContext.extract_result_summary(:ok) == nil
      assert ResumeContext.extract_result_summary({:ok, "plain"}) == nil
      assert ResumeContext.extract_result_summary({:ok, %{result: 42}}) == nil
      assert ResumeContext.extract_result_summary({:ok, %{other: "x"}}) == nil
      assert ResumeContext.extract_result_summary("string") == nil
    end
  end

  describe "apply_resume_context/3" do
    test "nil previous task: normalizes string-keyed caller foreign_repos into structs" do
      resume_from = "missing_task_#{System.unique_integer([:positive])}"

      {objective, runtime_opts} =
        ResumeContext.apply_resume_context(
          [
            path: "/tmp/resume-context-next",
            mode: "simple",
            objective: "Continue the work.",
            foreign_repos: [
              %{"id" => "orig", "root" => "/tmp/orig", "writable" => true, "base_sha" => "b1"}
            ],
            resume_from: resume_from
          ],
          "task_1",
          resume_from
        )

      # The caller's string-keyed map (a Codec round-trip shape) is normalized
      # back into a %ForeignRepo{} struct with writable/base_sha intact.
      assert [%ForeignRepo{id: "orig", root: "/tmp/orig", writable: true, base_sha: "b1"}] =
               Keyword.get(runtime_opts, :foreign_repos)

      # No previous task — the objective is not prepended with a context block.
      assert objective == "Continue the work."
    end

    test "found previous task: threads struct foreign_repos and overrides starting_commit" do
      prev = insert_prev_task!(result: {:ok, %{result: "Done."}})

      {objective, runtime_opts} =
        ResumeContext.apply_resume_context(
          [
            path: "/tmp/resume-context-next",
            mode: "simple",
            objective: "Continue the work.",
            foreign_repos: [
              %ForeignRepo{id: "orig", root: "/tmp/orig", writable: true, base_sha: "b1"}
            ],
            resume_from: prev.id
          ],
          "task_1",
          prev.id
        )

      # The previous task's end commit takes priority as :starting_commit.
      assert Keyword.get(runtime_opts, :starting_commit) == "commit222"

      # Struct inputs pass through normalized (writable/base_sha intact).
      assert [%ForeignRepo{id: "orig", root: "/tmp/orig", writable: true, base_sha: "b1"}] =
               Keyword.get(runtime_opts, :foreign_repos)

      # The previous task's context block is prepended to the objective.
      assert String.starts_with?(objective, "--- Previous Task Context ---")
    end

    test "overrides a caller repo's base_sha from the previous task's result repos map" do
      prev =
        insert_prev_task!(result: {:ok, %{"repos" => %{"orig" => %{"commit_sha" => "new_sha"}}}})

      {_objective, runtime_opts} =
        ResumeContext.apply_resume_context(
          [
            path: "/tmp/resume-context-next",
            mode: "simple",
            objective: "Continue the work.",
            foreign_repos: [
              %ForeignRepo{id: "orig", root: "/tmp/orig", writable: true, base_sha: "old_sha"}
            ],
            resume_from: prev.id
          ],
          "task_1",
          prev.id
        )

      assert [%ForeignRepo{id: "orig", writable: true, base_sha: "new_sha"}] =
               Keyword.get(runtime_opts, :foreign_repos)
    end

    test "does not add a :foreign_repos key when the caller has none (nil previous task)" do
      resume_from = "missing_task_#{System.unique_integer([:positive])}"

      {_objective, runtime_opts} =
        ResumeContext.apply_resume_context(
          [
            path: "/tmp/resume-context-next",
            mode: "simple",
            objective: "Continue the work.",
            resume_from: resume_from
          ],
          "task_1",
          resume_from
        )

      refute Keyword.has_key?(runtime_opts, :foreign_repos)
    end

    test "does not add a :foreign_repos key when the caller has none (previous task found)" do
      prev = insert_prev_task!()

      {_objective, runtime_opts} =
        ResumeContext.apply_resume_context(
          [
            path: "/tmp/resume-context-next",
            mode: "simple",
            objective: "Continue the work.",
            resume_from: prev.id
          ],
          "task_1",
          prev.id
        )

      refute Keyword.has_key?(runtime_opts, :foreign_repos)
    end
  end

  # --- fixtures ---

  defp build_task(overrides) do
    unique = System.unique_integer([:positive])

    base = %TaskInfo{
      id: "resume_ctx_prev_#{unique}",
      type: :evolve,
      status: :completed,
      opts: [path: "/tmp/resume-context-prev", mode: "simple"],
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

  defp insert_prev_task!(overrides \\ []) do
    build_task(overrides) |> persist_task!()
  end
end
