defmodule EvoGit.TaskRegistry.ResumeContextTest do
  @moduledoc """
  Tests for `EvoGit.TaskRegistry.ResumeContext` — the resume-context builder
  used by TaskExecutor when an evolve task resumes from a previous task
  (`:resume_from`).

  The pure `build_resume_context_block/1` + `extract_result_summary/1` tests
  now live in `EvoGit.TaskRegistry.ResumeContextBlockTest` (they need no git/DB
  fixture and run `async: true` there). What remains here is
  `apply_resume_context/3`, which calls `EvoGit.TaskRegistry.get_task/1` plus
  the Store-backed runtime-opts builder, so it runs on
  `EvoGit.TaskRegistryCase` — an isolated TaskRegistry + Store on a temporary
  SQLite database (mirroring the merge-context test fixture pattern).

  Runs `async: true`: the fixture's instances are UNIQUELY named and the test
  process resolves them through the process dictionary, so
  `EvoGit.TaskRegistry.get_task/1` and `store()` hit this test's own
  Store/registry and no BEAM-global state (app env, `:evogit_*` ETS, global
  scheduler config) is mutated. Task ids are per-test unique.
  """

  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskRegistry.ResumeContext

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
    EvoGit.Store.put_task(store(), task)
    task
  end

  defp insert_prev_task!(overrides \\ []) do
    build_task(overrides) |> persist_task!()
  end
end
