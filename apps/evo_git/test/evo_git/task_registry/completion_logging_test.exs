defmodule EvoGit.TaskRegistry.CompletionLoggingTest do
  use EvoGit.TaskRegistryCase, async: false

  @moduledoc """
  Pins the observability + lost-result-guard logging added to
  `EvoGit.TaskRegistry` (lib `task_registry.ex`):

  - the wrapper `{ref, result}` handler logs
    `"... wrapper returned — persisting terminal status ..."` right before the
    terminal status cast, and logs a WARNING for an unknown ref (no matching
    task_refs entry — e.g. after a registry restart) instead of silently
    dropping the result;
  - the `{:DOWN, ...}` handler likewise warns for an unknown ref;
  - `handle_update_status/6`'s `:ok` arm logs
    `"... terminal status persisted: ..."` for every terminal write, closing
    the silent window between the wrapper's last log and the terminal SQLite
    write/broadcast.

  NOTE on log capture: `config/test.exs` sets `config :logger, level: :warning`,
  and ExUnit.CaptureLog does NOT override the primary Logger level — so the
  `:info` messages under test are invisible unless the test first lowers
  `Logger.level()`. The `capture_info_logs/1` helper below does exactly that
  (snapshot + restore), which is safe because all these tests are
  `async: false`.
  """

  # --- wrapper {ref, result} → terminal status logging ---

  test "a normally-completing wrapper task logs wrapper-return + terminal-persisted info lines and lands :completed" do
    task_id = "completion_log_#{System.unique_integer([:positive])}"
    seed_task(task_id, :running)

    # Make the task "owned": inject a live wrapper + ref into task_refs (the
    # established harness pattern — mirrors finalizing_watchdog_test.exs).
    wrapper_pid = spawn(fn -> Process.sleep(:infinity) end)
    ref = make_ref()
    inject_task_ref(task_id, wrapper_pid, ref)

    log =
      capture_info_logs(fn ->
        send(
          EvoGit.TaskRegistry,
          {ref, {:ok, %{result: "done", commit_sha: nil, branch_name: nil, tag: nil}}}
        )

        # Mailbox flush: the {ref, result} handler self-casts the terminal status
        # update, but that self-cast is queued AFTER the list_tasks call already
        # in the mailbox — so the first call returns before the update is
        # processed. A second call (queued after the self-cast) guarantees the
        # terminal write — and its logs — happen inside the capture window.
        TaskRegistry.list_tasks()
        TaskRegistry.get_task(task_id)
      end)

    # Both new info lines fire in the normal-completion flow.
    assert log =~ "wrapper returned — persisting terminal status :completed"
    assert log =~ "terminal status persisted: :completed"

    fetched = TaskRegistry.get_task(task_id)
    assert fetched.status == :completed
    assert {:ok, %{result: "done"}} = fetched.result

    # The terminal write removed the task_refs entry.
    state = :sys.get_state(EvoGit.TaskRegistry)
    refute Map.has_key?(state.task_refs, task_id)

    cleanup_process(wrapper_pid)
  end

  test "a direct terminal update_task_status write emits the terminal-status-persisted info log" do
    task_id = "terminal_persist_log_#{System.unique_integer([:positive])}"
    seed_task(task_id, :running)

    log =
      capture_info_logs(fn ->
        TaskRegistry.update_task_status(task_id, :completed, {:ok, %{result: "direct done"}})
        TaskRegistry.list_tasks()
      end)

    assert log =~ "terminal status persisted: :completed"
    assert log =~ "Task #{task_id} terminal status persisted"

    fetched = TaskRegistry.get_task(task_id)
    assert fetched.status == :completed
  end

  # --- lost-result guards (unknown refs) ---

  test "an unknown-ref {ref, result} message logs a warning and does not crash the registry" do
    log =
      capture_info_logs(fn ->
        # A ref that is not in task_refs (e.g. the registry restarted after the
        # wrapper finished) — the result cannot be persisted.
        send(EvoGit.TaskRegistry, {make_ref(), {:ok, %{result: "orphaned"}}})
        TaskRegistry.list_tasks()
      end)

    assert log =~ "received task result for unknown ref"
    assert log =~ "no matching task_refs entry"
    assert log =~ "result dropped"

    # The registry survives and still serves calls.
    assert is_list(TaskRegistry.list_tasks())

    assert TaskRegistry.get_task("completion_log_missing_#{System.unique_integer([:positive])}") ==
             nil
  end

  test "an unknown-ref :DOWN message logs a warning and does not crash the registry" do
    log =
      capture_info_logs(fn ->
        send(EvoGit.TaskRegistry, {:DOWN, make_ref(), :process, self(), :normal})
        TaskRegistry.list_tasks()
      end)

    assert log =~ "received :DOWN for unknown ref"
    assert log =~ "no matching task_refs entry"
    assert log =~ "ignoring"

    assert is_list(TaskRegistry.list_tasks())
  end

  # --- helpers ---

  # Seats a task row directly through the store (mirrors
  # finalizing_watchdog_test.exs's seed_task/2).
  defp seed_task(task_id, status) do
    :ok =
      EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
        id: task_id,
        type: :genesis,
        status: status,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      })
  end

  # Injects a fake %Task{} wrapper entry into the registry's task_refs so the
  # {ref, result} / {:DOWN, ...} handlers have a matching entry to look up.
  defp inject_task_ref(task_id, pid, ref) do
    :sys.replace_state(EvoGit.TaskRegistry, fn state ->
      %{
        state
        | task_refs:
            Map.put(
              state.task_refs,
              task_id,
              %Task{
                pid: pid,
                ref: ref,
                owner: self(),
                mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], "test"]}
              }
            )
      }
    end)
  end

  # The :info logs under test are filtered out at the primary Logger level
  # (config/test.exs sets :warning), so lower the level for the capture and
  # restore it afterwards. All tests here are async: false, so the global level
  # change cannot leak into a concurrent test.
  defp capture_info_logs(fun) do
    prior = Logger.level()
    Logger.configure(level: :debug)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: prior)
    end
  end
end
