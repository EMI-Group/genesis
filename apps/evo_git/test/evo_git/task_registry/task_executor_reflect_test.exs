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

  `async: false` is required: `without_model_profiles/1` MUTATES the
  app-global `EvoGit.AgentScheduler`'s `:model_profiles` config (via
  `EvoGit.AgentScheduler.update_config/1`) for the duration of each test, and
  the `:reflect` runtime routes through that same global scheduler
  (`AgentScheduler.run_agent/1`). A concurrently running module that reads the
  scheduler's model profiles would observe the emptied list, so this module must
  stay serialized. The `EvoGit.TaskRegistryCase` fixture itself is already
  isolated (uniquely-named Store + registry), so the only forcing global is the
  scheduler config.
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
        # Subscribe BEFORE starting the task so the registry's `{:task_updated,
        # id, :running, node}` and terminal broadcasts cannot be missed. The wait
        # is then driven by the PubSub event instead of polling.
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

        assert {:ok, %TaskInfo{} = task} =
                 TaskRegistry.start_task(:reflect, objective: "introspect")

        assert :ok = await_terminal_status(task.id)

        task = TaskRegistry.get_task(task.id)
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

  # Waits for the registry's terminal `"tasks"` broadcast for `task_id`
  # (:completed/:failed/:cancelled), bounded to 5s. The registry also emits a
  # non-terminal `{:task_updated, id, :running, node}` first, so non-terminal
  # statuses for the SAME task id are ignored; broadcasts for other task ids
  # cannot match the pinned `^task_id`. Must be called from a process already
  # subscribed to `"tasks"` and INSIDE without_model_profiles/1 so the profiles
  # are only restored after the wrapper has finished.
  defp await_terminal_status(task_id) do
    receive do
      {:task_updated, ^task_id, status, _node} when status in [:completed, :failed, :cancelled] ->
        :ok

      {:task_updated, ^task_id, _status, _node} ->
        await_terminal_status(task_id)
    after
      5_000 -> flunk("task #{task_id} did not reach a terminal status in time")
    end
  end
end
