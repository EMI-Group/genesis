defmodule EvoGit.TaskRegistry.TaskExecutorReflectTest do
  @moduledoc """
  Tests for the `:reflect` clause of `EvoGit.TaskRegistry.TaskExecutor`
  (`task_executor.ex`) — the repo-less self-reflective task type.

  The point: prove that `execute_task(:reflect, opts, task_id)` tolerates opts
  WITHOUT a `:path` key — the genesis/evolve/`extract_skills` clauses all need a
  repo, and the `:reflect` clause deliberately skips
  `RuntimeOpts.build_common_runtime_opts/3` (which `Keyword.fetch!`s `:path`
  and would raise KeyError) — and routes into
  `EvoGit.Runtime.SelfReflective.run`, which calls `AgentScheduler.run_agent/1`
  on a repo-less spec.

  No mocking library is used — the established no-real-LLM idiom
  `without_model_profiles/1` is copied from
  `test/evo_git/runtime/evolution_test.exs`: with the scheduler's model
  profiles emptied, `AgentScheduler.run_agent/1` replies
  `{:error, :llm_not_configured}` immediately instead of dispatching a real
  LLM-backed agent.
  """

  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.TaskRegistry.TaskExecutor

  describe "execute_task/3 with :reflect" do
    test "tolerates opts without :path and routes into SelfReflective.run" do
      result =
        without_model_profiles(fn ->
          guarded_call(fn ->
            TaskExecutor.execute_task(
              :reflect,
              [objective: "hi", model_id: "m1"],
              reflect_id("a")
            )
          end)
        end)

      assert_reflect_result(result)
    end

    test "does not crash on unexpected opts keys" do
      result =
        without_model_profiles(fn ->
          guarded_call(fn ->
            TaskExecutor.execute_task(:reflect, [some_unexpected_key: 42], reflect_id("b"))
          end)
        end)

      assert_reflect_result(result)
    end
  end

  describe "end-to-end :reflect task via TaskRegistry" do
    test "start_task(:reflect, opts) without :path completes :failed with llm_not_configured" do
      without_model_profiles(fn ->
        assert {:ok, %TaskInfo{} = task} =
                 TaskRegistry.start_task(:reflect, objective: "introspect")

        task = wait_for_terminal(task.id)
        assert task.status == :failed
        assert task.result == {:error, :llm_not_configured}
      end)
    end
  end

  # --- helpers -------------------------------------------------------------

  defp reflect_id(tag) do
    "reflect-test-#{tag}-#{System.unique_integer([:positive])}"
  end

  # Runs execute_task defensively: if the scheduler is unavailable the
  # GenServer.call exits with :noproc, which we normalize instead of crashing
  # the test (same pattern as evolution_test's guarded_run/2).
  defp guarded_call(fun) do
    try do
      {:returned, fun.()}
    catch
      :exit, reason -> {:exit, reason}
    end
  end

  defp assert_reflect_result({:returned, result}) do
    if Process.whereis(EvoGit.AgentScheduler) do
      # SelfReflective.run reached the scheduler, which fails fast on empty
      # model profiles — proves the routing happened and no KeyError was
      # raised for the missing :path.
      assert result == {:error, :llm_not_configured}
    else
      # No scheduler running: run_agent exits with :noproc.
      assert match?({:exit, _}, result)
    end
  end

  defp assert_reflect_result({:exit, reason}) do
    # Without a scheduler the GenServer.call exits — acceptable only when the
    # scheduler is truly absent in this environment.
    refute Process.whereis(EvoGit.AgentScheduler)
    assert is_list(reason) or is_atom(reason)
  end

  # The scheduler is running in tests (started with the :evo_git app), so
  # AgentScheduler.run_agent/1 reaches the GenServer instead of exiting. With
  # model profiles configured it would dispatch a real LLM-backed agent; force
  # an empty profile list so run_agent replies {:error, :llm_not_configured}
  # immediately. The original profiles are restored afterwards.
  defp without_model_profiles(fun) do
    scheduler = Process.whereis(EvoGit.AgentScheduler)

    if scheduler do
      original = GenServer.call(scheduler, {:get_config, :model_profiles})
      :ok = EvoGit.AgentScheduler.update_config(model_profiles: [])

      try do
        fun.()
      after
        EvoGit.AgentScheduler.update_config(model_profiles: original)
      end
    else
      fun.()
    end
  end

  # Polls TaskRegistry.get_task/1 until the task reaches a terminal status
  # (:completed/:failed/:cancelled), bounded to ~5s. The :reflect wrapper
  # completes almost instantly once the scheduler replies (empty model
  # profiles), so this is reliable. The poll runs INSIDE
  # without_model_profiles/1 so the profiles are only restored after the
  # wrapper has finished.
  defp wait_for_terminal(task_id, attempts \\ 100) do
    case TaskRegistry.get_task(task_id) do
      %TaskInfo{status: status} when status in [:completed, :failed, :cancelled] ->
        TaskRegistry.get_task(task_id)

      _ when attempts > 0 ->
        Process.sleep(50)
        wait_for_terminal(task_id, attempts - 1)

      _ ->
        flunk("task #{task_id} did not reach a terminal status in time")
    end
  end
end
