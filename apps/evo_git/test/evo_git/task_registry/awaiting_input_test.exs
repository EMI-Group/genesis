defmodule EvoGit.TaskRegistry.AwaitingInputTest do
  @moduledoc """
  `:awaiting_input` at the `EvoGit.TaskRegistry` boundary — the NON-TERMINAL
  status of an idle interactive session whose wrapper Task is still alive.

  A waiting session is LIVE but IDLE: its lease must be renewed, the one-shot
  sweep must never fail it while its owner lives, `clear_finished_tasks` must
  never delete it, a boot restart must fail it (sessions are in-memory only),
  it is force-killable and immediately cancellable, and `:running ↔
  :awaiting_input` is an ordinary legal status flip.

  Runs `async: true`: each test gets its own isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase` and every task id is
  per-test unique. The only global touches are `clear_cancelling_marker/1`'s
  ETS delete keyed by this test's OWN unique task id and read-only
  `EvoGit.AgentScheduler` lookups for a wrapper pid that belongs to this test,
  so no concurrently running module can observe a change.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Store
  alias EvoGit.TaskRegistry.Lease

  @restart_message "Runtime restarted during interactive session"

  describe "lease and heartbeat" do
    test "heartbeat renews an :awaiting_input row's lease and never rewrites its status" do
      unique = System.unique_integer([:positive])
      task_id = "awaiting_heartbeat_#{unique}"
      expired = System.system_time(:second) - 300
      wrapper = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> cleanup_process(wrapper) end)

      put_task!(task_id, :awaiting_input, expired)
      own_task!(task_id, wrapper)
      assert Store.get_task_status(store(), task_id) == :awaiting_input

      send(TaskRegistry.server(), :heartbeat)
      # Sync on the registry before reading the store.
      TaskRegistry.list_tasks()

      %{lease_expires_at: renewed} = Store.select_task_update_info(store(), task_id)

      assert renewed > expired,
             "heartbeat must renew an :awaiting_input lease, got #{inspect(renewed)}"

      # Renewal is lease-only: an idle session stays :awaiting_input.
      assert Store.get_task_status(store(), task_id) == :awaiting_input
    end

    test "Lease.leaked?/3 is true only for an un-owned, lease-lapsed :awaiting_input row" do
      expired = System.system_time(:second) - 300
      future = System.system_time(:second) + 300

      # Renewable exactly like :running (the wrapper is alive while it idles).
      assert Lease.lease_renewable?(:awaiting_input)

      # Owned → never leaked, even with an expired/missing lease.
      refute Lease.leaked?(:awaiting_input, true, nil)
      refute Lease.leaked?(:awaiting_input, true, expired)

      # Lease still valid → never leaked, even un-owned (multi-VM case).
      refute Lease.leaked?(:awaiting_input, false, future)

      # Un-owned AND lease-lapsed → the owning wrapper is gone: sweepable.
      assert Lease.leaked?(:awaiting_input, false, expired)
      assert Lease.leaked?(:awaiting_input, false, nil)

      # A known terminal status is never leaked.
      refute Lease.leaked?(:completed, false, expired)
    end

    test "the one-shot lease sweep never fails a LIVE :awaiting_input row" do
      unique = System.unique_integer([:positive])
      expired = System.system_time(:second) - 300
      future = System.system_time(:second) + 300

      # (1) OWNED by this registry instance with an expired lease: the heartbeat
      #     is the owner, so the sweep leaves it alone.
      owned_id = "awaiting_sweep_owned_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> cleanup_process(wrapper) end)

      put_task!(owned_id, :awaiting_input, expired)
      own_task!(owned_id, wrapper)

      # (2) Un-owned but with a VALID lease: another live instance owns it.
      leased_id = "awaiting_sweep_leased_#{unique}"
      put_task!(leased_id, :awaiting_input, future)

      send(TaskRegistry.server(), :lease_sweep)
      TaskRegistry.list_tasks()

      assert %{lease_expires_at: ^expired} = Store.select_task_update_info(store(), owned_id)
      assert Store.get_task_status(store(), owned_id) == :awaiting_input

      assert %{lease_expires_at: ^future} = Store.select_task_update_info(store(), leased_id)
      assert Store.get_task_status(store(), leased_id) == :awaiting_input

      for id <- [owned_id, leased_id] do
        task = Store.get_task(store(), id)
        assert task != nil, "the sweep must never delete the row"
        assert {task.finished_at, task.error} == {nil, nil}
      end
    end
  end

  describe "clear_finished_tasks" do
    test "never deletes an :awaiting_input row but does delete a completed one" do
      unique = System.unique_integer([:positive])
      waiting_id = "awaiting_clear_waiting_#{unique}"
      completed_id = "awaiting_clear_completed_#{unique}"

      put_task!(waiting_id, :awaiting_input, System.system_time(:second) + 300)

      :ok =
        Store.put_task(store(), %TaskInfo{
          id: completed_id,
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        })

      assert :ok = TaskRegistry.clear_finished_tasks()

      assert Store.get_task(store(), waiting_id) != nil,
             "a waiting session must never be reaped as a finished task"

      assert Store.get_task(store(), completed_id) == nil,
             "a completed task is still cleared"
    end
  end

  describe "boot reconciliation" do
    test "restart marks an orphaned :awaiting_input row :failed (sessions never survive a restart)",
         %{data_dir: data_dir, store: store, registry: registry} do
      unique = System.unique_integer([:positive])
      waiting_id = "boot_awaiting_#{unique}"
      running_id = "boot_running_#{unique}"
      future_lease = System.system_time(:second) + 300

      # A fresh registry booting against a DB that still holds an idle session.
      stop_supervised(registry)

      :ok = put_task!(waiting_id, :awaiting_input, future_lease)
      :ok = put_task!(running_id, :running, future_lease)

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, name: registry},
          id: registry
        )
      )

      fetched = Store.get_task(store(), waiting_id)
      assert fetched != nil
      assert fetched.status == :failed
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil

      # Same message in `result` and in the canonical error payload.
      assert fetched.result == @restart_message

      assert fetched.error == %{
               kind: :restart,
               source: :startup_reconcile,
               message: @restart_message,
               stacktrace: nil
             }

      # Control: a :running row with a valid lease is NOT touched at init (the
      # one-shot :lease_sweep owns orphaned running tasks).
      running = Store.get_task(store(), running_id)
      assert running.status == :running
      assert running.lease_expires_at == future_lease
    end
  end

  describe "force_kill_task/1" do
    test "kills a waiting session and persists :failed with result nil" do
      unique = System.unique_integer([:positive])
      task_id = "awaiting_forcekill_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      put_task!(task_id, :awaiting_input, System.system_time(:second) + 300)
      own_task!(task_id, wrapper)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :failed
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      # A force-killed task keeps result nil (review semantics unchanged).
      assert fetched.result == nil

      assert fetched.error == %{
               kind: :force_kill,
               source: :force_kill_task,
               message: "Task force-killed by user",
               stacktrace: nil
             }

      refute Process.alive?(wrapper), "the session wrapper must be brutal-killed"

      refute Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)
    end
  end

  describe "cancel_task/1" do
    test "cancels a waiting session immediately, preserving the transcript/result" do
      unique = System.unique_integer([:positive])
      task_id = "awaiting_cancel_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      # A session that already wrote something durable must keep it.
      put_task!(task_id, :awaiting_input, System.system_time(:second) + 300,
        result: "session transcript"
      )

      own_task!(task_id, wrapper)

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      assert :ok = TaskRegistry.cancel_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil

      assert fetched.result == "session transcript",
             "cancelling a waiting session must never clobber its result, got #{inspect(fetched.result)}"

      # No error payload rides a cancelled row.
      assert fetched.error == nil

      # Exactly ONE broadcast (the :cancelled transition) — `cancel_task/1` is a
      # synchronous call and the handler emits every broadcast inline before
      # replying, so a zero-wait refute is complete evidence.
      assert_receive {:task_updated, ^task_id, :cancelled, _}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0

      refute Process.alive?(wrapper), "the idle session wrapper must be stopped"

      refute Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)

      # Nothing is left behind in the graceful-cancel marker.
      refute :ets.member(:evogit_cancelling_tasks, task_id)
    end

    test "a second cancel on the now-terminal row answers {:error, :not_running}" do
      unique = System.unique_integer([:positive])
      task_id = "awaiting_cancel_twice_#{unique}"

      put_task!(task_id, :awaiting_input, System.system_time(:second) + 300)

      assert :ok = TaskRegistry.cancel_task(task_id)
      assert {:error, :not_running} = TaskRegistry.cancel_task(task_id)
      assert Store.get_task_status(store(), task_id) == :cancelled
    end
  end

  describe "update_status/2" do
    test "flips :running → :awaiting_input → :running, persists and broadcasts each change, no-ops a repeat" do
      unique = System.unique_integer([:positive])
      task_id = "awaiting_flip_#{unique}"
      future_lease = System.system_time(:second) + 300

      put_task!(task_id, :running, future_lease)

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      drain_tasks_mailbox()

      # YIELD: running → awaiting_input is an ordinary non-terminal transition.
      assert :ok = TaskRegistry.update_status(task_id, :awaiting_input)
      # Sync on the registry (casts and calls from this process are ordered).
      TaskRegistry.list_tasks()

      yielded = TaskRegistry.get_task(task_id)
      assert yielded.status == :awaiting_input
      # Non-terminal: finished_at stays nil and the lease is untouched.
      assert yielded.finished_at == nil
      assert yielded.lease_expires_at == future_lease

      assert_receive {:task_updated, ^task_id, :awaiting_input, _}, 1_000

      # REPEAT: the same status is a no-op — the write is harmless and NO
      # broadcast fires.
      assert :ok = TaskRegistry.update_status(task_id, :awaiting_input)
      TaskRegistry.list_tasks()
      refute_receive {:task_updated, ^task_id, _, _}, 0
      assert Store.get_task_status(store(), task_id) == :awaiting_input

      # RESUME: awaiting_input → running.
      assert :ok = TaskRegistry.update_status(task_id, :running)
      TaskRegistry.list_tasks()

      resumed = TaskRegistry.get_task(task_id)
      assert resumed.status == :running
      assert resumed.finished_at == nil

      assert_receive {:task_updated, ^task_id, :running, _}, 1_000
    end

    test "a waiting session closing normally persists its terminal status with the lease cleared" do
      unique = System.unique_integer([:positive])
      task_id = "awaiting_close_#{unique}"

      put_task!(task_id, :awaiting_input, System.system_time(:second) + 300)

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      drain_tasks_mailbox()

      # `{:close, reason}` / a finished exchange: the terminal write is the
      # ordinary `update_task_status/4` path, result included.
      TaskRegistry.update_task_status(
        task_id,
        :completed,
        {:ok, %{branch_name: "genesis/session"}}
      )

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :completed
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      assert fetched.branch_name == "genesis/session"

      assert_receive {:task_updated, ^task_id, :completed, _}, 1_000
    end
  end

  describe "status enumeration totality" do
    test "every exposed status set is pinned and contains :awaiting_input wherever it contains :running" do
      # `:total` — the set must contain :awaiting_input whenever it contains
      # :running. `:exempt` — the ONE pinned exemption: the `:finalizing`
      # ignore-list must NOT contain :awaiting_input, because closing an idle
      # session legitimately moves it to :finalizing.
      sets = [
        {:killable_statuses, TaskRegistry.killable_statuses(),
         [:running, :awaiting_input, :cancelling], :total},
        {:gracefully_cancellable_statuses, TaskRegistry.gracefully_cancellable_statuses(),
         [:running, :awaiting_input], :total},
        {:unstartable_statuses, TaskRegistry.unstartable_statuses(),
         [:cancelled, :cancelling, :awaiting_input], :total},
        {:active_statuses, TaskRegistry.active_statuses(),
         [:running, :pending, :finalizing, :cancelling, :awaiting_input], :total},
        {:terminal_statuses, TaskRegistry.terminal_statuses(), [:completed, :failed, :cancelled],
         :total},
        {:finalizing_ignored_statuses, TaskRegistry.finalizing_ignored_statuses(),
         [:completed, :cancelled, :cancelling], :exempt},
        {:renewed_statuses, Lease.renewed_statuses(),
         [:running, :pending, :cancelling, :awaiting_input], :total},
        {:leaked_statuses, Lease.leaked_statuses(), [:running, :awaiting_input], :total}
      ]

      for {name, actual, expected, rule} <- sets do
        assert actual == expected,
               "#{name}/0 is #{inspect(actual)}, expected #{inspect(expected)}"

        if rule == :total and :running in actual do
          assert :awaiting_input in actual,
                 "#{name}/0 contains :running but not :awaiting_input: #{inspect(actual)}"
        end
      end

      # The pinned exemption, stated positively: an idle session is allowed to
      # move to :finalizing, so it must never be in the ignore-list.
      refute :awaiting_input in TaskRegistry.finalizing_ignored_statuses()
      assert :running not in TaskRegistry.finalizing_ignored_statuses()

      # :awaiting_input is NON-terminal everywhere it matters.
      refute :awaiting_input in TaskRegistry.terminal_statuses()

      # The store-side halves of the same admission (strings, SQL pushdowns):
      # the NOT-finished set (`clear_finished_tasks`) and the lease set (boot
      # reconciliation + the sweep) must both include it.
      for {name, list} <- [
            {:live_statuses, EvoGit.Store.Operations.Lightweight.live_statuses()},
            {:lease_statuses, EvoGit.Store.Operations.Lightweight.lease_statuses()}
          ] do
        assert "running" in list
        assert "awaiting_input" in list, "#{name}/0 is missing awaiting_input: #{inspect(list)}"
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp put_task!(task_id, status, lease_expires_at, opts \\ []) do
    Store.put_task(store(), %TaskInfo{
      id: task_id,
      type: :genesis,
      status: status,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: Keyword.get(opts, :result),
      lease_expires_at: lease_expires_at
    })
  end

  # Registers the task as OWNED by this registry instance (`task_refs`) with a
  # LIVE wrapper pid — the state a session occupies while it idles. `%Task{}` is
  # built INSIDE the registry (via :sys.replace_state), so its `owner` is the
  # registry, exactly like a real `Task.Supervisor.async_nolink/4` entry, which
  # is what makes the cancel/force-kill `Task.shutdown/2` legal.
  defp own_task!(task_id, pid) do
    :sys.replace_state(TaskRegistry.server(), fn state ->
      task_ref = %Task{
        pid: pid,
        ref: make_ref(),
        owner: self(),
        mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], task_id]}
      }

      %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}
    end)
  end

  defp drain_tasks_mailbox do
    receive do
      _msg -> drain_tasks_mailbox()
    after
      0 -> :ok
    end
  end
end
