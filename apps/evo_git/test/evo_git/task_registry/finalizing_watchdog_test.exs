defmodule EvoGit.TaskRegistry.FinalizingWatchdogTest do
  use EvoGit.TaskRegistryCase, async: false

  @moduledoc """
  Pins the stuck-`:finalizing` GRACE WATCHDOG in `EvoGit.TaskRegistry`
  (lib `task_registry.ex`, "Stuck-:finalizing grace watchdog" section, helpers at
  1131-1195): a local-node `:finalizing` PubSub broadcast schedules a ONE-SHOT
  `{:recheck_task, task_id}` timer; when it fires while the task is STILL
  `:finalizing`, the task is resolved to `:failed` with the exact result
  `"Finalization did not complete within N minutes"` (env seam
  `:finalizing_watchdog_grace_minutes` — nil/unset → 60, numeric ≥ 0 → minutes,
  `false` → disabled).

  Coverage:
  - the scheduled-timer path end-to-end (0-minute grace → resolves WITHOUT a
    manual recheck send),
  - the resolution arm driven by hand with a non-zero grace (exact message),
  - terminal rows are untouched by a recheck (no crash),
  - a late wrapper `{ref, result}` / `{:DOWN, ...}` after resolution is a NO-OP
    (the task_refs entry is gone → row preserved, no `:completed` broadcast),
  - `false` disables the watchdog entirely (the row stays `:finalizing`).
  """

  @env_key :finalizing_watchdog_grace_minutes

  describe "stuck-:finalizing grace watchdog" do
    test "past-grace resolution via the scheduled one-shot timer (grace 0)" do
      set_grace(0)
      task_id = "watchdog_timer_#{System.unique_integer([:positive])}"
      seed_task(task_id, :running)

      # The local-node broadcast both flips the row to :finalizing AND schedules
      # the one-shot watchdog (delay 0 → fires immediately).
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :finalizing, node()}
      )

      # No manual recheck send — this proves the scheduled timer fired.
      wait_until(fn ->
        fetched = TaskRegistry.get_task(task_id)
        fetched != nil and fetched.status == :failed
      end)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :failed
      assert fetched.result == "Finalization did not complete within 0 minutes"
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
    end

    test "resolution arm resolves a stuck :finalizing row with the exact N-minute message" do
      set_grace(2)
      task_id = "watchdog_resolve_#{System.unique_integer([:positive])}"
      seed_task(task_id, :finalizing)

      # Drive the resolution arm by hand (no broadcast, no timer wait).
      send(EvoGit.TaskRegistry, {:recheck_task, task_id})
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :failed
      assert fetched.result == "Finalization did not complete within 2 minutes"
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
    end

    test "terminal tasks (:completed/:failed) are left untouched by a recheck" do
      # Explicit 0-minute grace: even an immediate-fire watchdog must not touch
      # terminal rows (the recheck handler no-ops on completed/failed/cancelled).
      set_grace(0)
      completed_id = "watchdog_terminal_completed_#{System.unique_integer([:positive])}"
      failed_id = "watchdog_terminal_failed_#{System.unique_integer([:positive])}"

      seed_task(completed_id, :completed, result: "done")
      seed_task(failed_id, :failed, result: "boom")

      # Reference values AFTER the Store round-trip (Codec truncates datetimes
      # to milliseconds, so compare against the persisted decode, not utc_now).
      completed_before = TaskRegistry.get_task(completed_id)
      failed_before = TaskRegistry.get_task(failed_id)

      send(EvoGit.TaskRegistry, {:recheck_task, completed_id})
      send(EvoGit.TaskRegistry, {:recheck_task, failed_id})
      TaskRegistry.list_tasks()

      # The registry survives — still serving calls.
      assert is_list(TaskRegistry.list_tasks())

      completed_after = TaskRegistry.get_task(completed_id)
      assert completed_after.status == :completed
      assert completed_after.result == "done"
      assert completed_after.finished_at == completed_before.finished_at

      failed_after = TaskRegistry.get_task(failed_id)
      assert failed_after.status == :failed
      assert failed_after.result == "boom"
      assert failed_after.finished_at == failed_before.finished_at
    end

    test "a late wrapper result after watchdog resolution is a no-op" do
      set_grace(0)
      task_id = "watchdog_late_#{System.unique_integer([:positive])}"
      seed_task(task_id, :finalizing)

      # Fake an "owned" wrapper: inject a live process + ref into task_refs so
      # the {ref, result} / {:DOWN, ...} handlers have something to look up
      # after the watchdog resolved the row (mirrors persistence_test.exs's
      # cancel_test_task/1 entry shape).
      wrapper_pid = spawn(fn -> Process.sleep(:infinity) end)
      ref = make_ref()

      :sys.replace_state(EvoGit.TaskRegistry, fn state ->
        %{
          state
          | task_refs:
              Map.put(
                state.task_refs,
                task_id,
                %Task{
                  pid: wrapper_pid,
                  ref: ref,
                  owner: self(),
                  mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], "test"]}
                }
              )
        }
      end)

      send(EvoGit.TaskRegistry, {:recheck_task, task_id})

      wait_until(fn ->
        fetched = TaskRegistry.get_task(task_id)
        fetched != nil and fetched.status == :failed
      end)

      resolved = TaskRegistry.get_task(task_id)
      watchdog_result = resolved.result
      finished_at = resolved.finished_at

      # The terminal write removed the task from task_refs — nothing is left for
      # the late messages to match.
      state = :sys.get_state(EvoGit.TaskRegistry)
      refute Map.has_key?(state.task_refs, task_id)

      # Drain anything already in the mailbox BEFORE subscribing, so only
      # late-message broadcasts (there should be none) can be observed below.
      flush_mailbox()
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      # The blocked wrapper eventually returns / exits — both late messages must
      # be complete no-ops (no DB write, no broadcast).
      send(
        EvoGit.TaskRegistry,
        {ref, {:ok, %{result: "late result", commit_sha: nil, branch_name: nil, tag: nil}}}
      )

      send(EvoGit.TaskRegistry, {:DOWN, ref, :process, wrapper_pid, :normal})
      TaskRegistry.list_tasks()

      after_late = TaskRegistry.get_task(task_id)
      assert after_late.status == :failed
      assert after_late.result == watchdog_result
      assert after_late.finished_at == finished_at

      # The late result must never surface as a :completed broadcast.
      refute_receive {:task_updated, ^task_id, :completed, _}, 150

      cleanup_process(wrapper_pid)
    end

    test "disabled grace (false) never schedules the watchdog — task stays :finalizing" do
      set_grace(false)
      task_id = "watchdog_disabled_#{System.unique_integer([:positive])}"
      seed_task(task_id, :running)

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :finalizing, node()}
      )

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :finalizing

      # Comfortably longer than an immediate-fire watchdog would need; with the
      # feature disabled the row must remain :finalizing (this distinguishes
      # `false` from the default-60-min timer).
      Process.sleep(300)
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :finalizing
    end
  end

  # --- helpers ---

  # Seats a task row directly through the store (mirrors persistence_test.exs).
  # Terminal statuses get a finished_at unless one is passed via opts.
  defp seed_task(task_id, status, opts \\ []) do
    finished_at =
      if status in [:completed, :failed, :cancelled] do
        Keyword.get(opts, :finished_at, DateTime.utc_now())
      end

    :ok =
      EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
        id: task_id,
        type: :genesis,
        status: status,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: finished_at,
        logs: [],
        result: Keyword.get(opts, :result)
      })
  end

  # The app-env seam is GLOBAL across the whole test BEAM — snapshot the prior
  # value, set the new one, and always restore it on exit (delete when the prior
  # was nil) so no test leaks its env value into the next.
  defp set_grace(minutes) do
    prior = Application.get_env(:evo_git, @env_key)
    Application.put_env(:evo_git, @env_key, minutes)

    on_exit(fn ->
      if prior == nil do
        Application.delete_env(:evo_git, @env_key)
      else
        Application.put_env(:evo_git, @env_key, prior)
      end
    end)

    :ok
  end

  # Polls until `fun` returns a truthy value (10ms interval, 3s timeout) — used
  # for the timer-driven watchdog paths where there is no manual recheck send to
  # sync on.
  defp wait_until(fun, interval \\ 10, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, interval, deadline, timeout)
  end

  defp do_wait_until(fun, interval, deadline, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within #{timeout}ms")
      else
        Process.sleep(interval)
        do_wait_until(fun, interval, deadline, timeout)
      end
    end
  end

  # Drains every message currently in the test process mailbox.
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
