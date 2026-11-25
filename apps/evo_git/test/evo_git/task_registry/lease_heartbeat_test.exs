defmodule EvoGit.TaskRegistry.LeaseHeartbeatTest do
  @moduledoc """
  Runs `async: true`: each test gets its own isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase`, touches no BEAM-global
  state (no app-env key, no shared `:evogit_*` ETS table, no global scheduler
  config), and every task id is per-test unique.
  """

  use EvoGit.TaskRegistryCase, async: true

  describe "lease & heartbeat" do
    test "lease cleared when task completes via update_task_status" do
      unique = System.unique_integer([:positive])

      task = %TaskInfo{
        id: "lease_complete_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) + 300
      }

      EvoGit.Store.put_task(store(), task)

      # Transition to completed
      TaskRegistry.update_task_status("lease_complete_#{unique}", :completed, nil)

      # Sync
      tasks = TaskRegistry.list_tasks()
      found = Enum.find(tasks, &(&1.id == "lease_complete_#{unique}"))

      assert found != nil
      assert found.status == :completed

      assert found.lease_expires_at == nil,
             "completed task should have lease cleared"
    end

    test "heartbeat does NOT sweep expired-lease unowned tasks (renewal only)" do
      unique = System.unique_integer([:positive])

      # Insert a running task with an EXPIRED lease, no pid, not owned.
      expired = System.system_time(:second) - 300

      task = %TaskInfo{
        id: "lease_heartbeat_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: expired
      }

      EvoGit.Store.put_task(store(), task)

      # Send a heartbeat message directly to the registry process.
      # After the refactor, heartbeat ONLY renews owned leases — it does NOT
      # sweep. So even an expired-lease unowned task must remain :running.
      send(TaskRegistry.server(), :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), "lease_heartbeat_#{unique}")
      assert found != nil
      # Lease unchanged and task still :running (no sweep on heartbeat).
      assert found.status == :running,
             "heartbeat should NOT sweep expired-lease tasks (sweep is now :lease_sweep), got #{inspect(found.status)}"

      assert found.lease_expires_at == expired,
             "heartbeat should not modify unowned task's lease"
    end

    test "lease_sweep sweeps expired-lease running tasks we don't own" do
      unique = System.unique_integer([:positive])

      # Insert a running task with an expired lease, no pid, not owned.
      task = %TaskInfo{
        id: "lease_sweep_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) - 300
      }

      EvoGit.Store.put_task(store(), task)

      # Send a lease_sweep message directly to the registry process (one-shot).
      send(TaskRegistry.server(), :lease_sweep)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), "lease_sweep_#{unique}")
      assert found != nil

      assert found.status == :failed,
             "task with expired lease should be swept to :failed, got #{inspect(found.status)}"

      assert found.lease_expires_at == nil

      # The sweep records the canonical lease-expired error payload on the
      # full-struct put_task write.
      assert found.result == "Lease expired; owning instance no longer renewing"

      assert found.error == %{
               kind: :lease_expired,
               source: :lease_sweep,
               message: "Lease expired; owning instance no longer renewing",
               stacktrace: nil
             }
    end

    test "heartbeat renews the lease of an owned :cancelling task" do
      unique = System.unique_integer([:positive])
      task_id = "heartbeat_cancelling_#{unique}"
      expired = System.system_time(:second) - 300

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :cancelling,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: expired
      }

      EvoGit.Store.put_task(store(), task)

      # Make the task "owned" (in task_refs) so heartbeat renews its lease —
      # a long graceful cancel must keep its lease valid while the wrapper
      # is still alive. The %Task{} content is irrelevant to the heartbeat.
      :sys.replace_state(TaskRegistry.server(), fn state ->
        %{
          state
          | task_refs:
              Map.put(
                state.task_refs,
                task_id,
                %Task{
                  pid: self(),
                  ref: make_ref(),
                  owner: self(),
                  mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], task_id]}
                }
              )
        }
      end)

      send(TaskRegistry.server(), :heartbeat)

      # Sync
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), task_id)
      assert found != nil

      assert found.status == :cancelling,
             "heartbeat must not change the :cancelling status, got #{inspect(found.status)}"

      assert found.lease_expires_at > expired,
             "heartbeat should renew the lease of an owned :cancelling task, got #{inspect(found.lease_expires_at)}"
    end

    test "heartbeat renews the lease of an owned :pausing task" do
      unique = System.unique_integer([:positive])
      task_id = "heartbeat_pausing_#{unique}"
      expired = System.system_time(:second) - 300

      # A pause that is still FREEZING is a live task: its wrapper is alive and
      # its agents are walking to a turn boundary. If its lease were allowed to
      # expire the sweep would park (or fail) a freeze that is still running.
      task = seed_task!(task_id, :pausing, lease_expires_at: expired)
      assert task.status == :pausing

      own_task!(task_id, :genesis)

      send(TaskRegistry.server(), :heartbeat)
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), task_id)
      assert found.status == :pausing, "heartbeat must not change the :pausing status"

      assert found.lease_expires_at > expired,
             "heartbeat should renew the lease of an owned :pausing task, got #{inspect(found.lease_expires_at)}"

      assert found.pause_kind == nil, "a freezing pause is not a dirty pause"
    end

    test "heartbeat never renews a :paused row's lease (even when owned)" do
      unique = System.unique_integer([:positive])
      task_id = "heartbeat_paused_#{unique}"
      expired = System.system_time(:second) - 300

      # A paused row rests with NO wrapper and NO lease by design — it is the
      # paused resting state, never a live task. Seeded here with an OWNED ref
      # and an artificial lease so the refusal cannot be an artifact of the
      # "no lease, nothing to renew" shortcut.
      _task = seed_task!(task_id, :paused, lease_expires_at: expired, pause_kind: :clean)
      own_task!(task_id, :genesis)

      send(TaskRegistry.server(), :heartbeat)
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), task_id)
      assert found.status == :paused, "heartbeat must leave a :paused row alone"
      assert found.lease_expires_at == expired, "a :paused row must never be lease-renewed"
    end

    test "lease_sweep parks a RESUMABLE expired-lease :running row as a :paused dirty pause" do
      unique = System.unique_integer([:positive])
      task_id = "sweep_dirty_pause_#{unique}"

      seed_durable_run!(task_id)

      _task =
        seed_task!(task_id, :running,
          lease_expires_at: System.system_time(:second) - 300,
          result: "partial report",
          usage: %EvoGit.Agent.Usage{total_tokens: 42, input_tokens: 40, output_tokens: 2},
          opts: [path: "/tmp/test", mode: "simple", persistent_state: true]
        )

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      send(TaskRegistry.server(), :lease_sweep)
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), task_id)

      assert found.status == :paused,
             "a resumable leaked run must park as :paused, got #{inspect(found.status)}"

      assert found.pause_kind == :dirty, "a restart-produced pause is always :dirty"
      assert found.finished_at == nil, "a paused task is NOT finished"
      assert found.lease_expires_at == nil, "a paused task holds no lease"
      assert found.result == "partial report", "the pause must preserve the run's result"
      assert found.usage.total_tokens == 42, "the pause must preserve usage"
      assert found.error == nil, "a dirty pause is not a failure"

      # Exactly ONE broadcast, and it says :paused (never :failed).
      assert_receive {:task_updated, ^task_id, :paused, _node}, 200
      refute_receive {:task_updated, ^task_id, _other, _node}, 100
    end

    test "lease_sweep keeps today's :failed for a NON-resumable expired-lease :running row" do
      unique = System.unique_integer([:positive])
      task_id = "sweep_non_resumable_#{unique}"

      # Durable agent state EXISTS, but the task opted OUT of persistence — so
      # there is nothing to resume and the leak is failed exactly as before.
      seed_durable_run!(task_id)

      _task =
        seed_task!(task_id, :running,
          lease_expires_at: System.system_time(:second) - 300,
          opts: [path: "/tmp/test", mode: "simple", persistent_state: false]
        )

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      send(TaskRegistry.server(), :lease_sweep)
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), task_id)
      assert found.status == :failed
      assert found.pause_kind == nil
      assert found.error.kind == :lease_expired
      assert found.lease_expires_at == nil

      assert_receive {:task_updated, ^task_id, :failed, _node}, 200
    end

    test ":lease_sweep never sweeps a :paused row" do
      unique = System.unique_integer([:positive])
      task_id = "sweep_paused_#{unique}"

      _task = seed_task!(task_id, :paused, lease_expires_at: nil, pause_kind: :clean)

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      send(TaskRegistry.server(), :lease_sweep)
      TaskRegistry.list_tasks()

      found = EvoGit.Store.get_task(store(), task_id)
      assert found.status == :paused, "a paused row is the sweep's OUTPUT, never its input"
      assert found.pause_kind == :clean, "the pause kind is preserved across a sweep"
      refute_receive {:task_updated, ^task_id, _status, _node}, 100
    end
  end

  # --- helpers -------------------------------------------------------------

  # Seeds one narrow row (no wrapper) and returns the persisted struct.
  defp seed_task!(task_id, status, attrs) do
    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: status,
      opts: Keyword.get(attrs, :opts, path: "/tmp/test"),
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: Keyword.get(attrs, :finished_at),
      logs: [],
      result: Keyword.get(attrs, :result),
      usage: Keyword.get(attrs, :usage),
      pause_kind: Keyword.get(attrs, :pause_kind),
      lease_expires_at: Keyword.get(attrs, :lease_expires_at)
    }

    :ok = EvoGit.Store.put_task(store(), task)
    task
  end

  # Marks `task_id` as OWNED by this registry (a live `task_refs` entry), which
  # is what the heartbeat's renewal arm keys on. The `%Task{}` content is
  # irrelevant to renewal — only the map key is read.
  defp own_task!(task_id, type) do
    :sys.replace_state(TaskRegistry.server(), fn state ->
      %{
        state
        | task_refs:
            Map.put(state.task_refs, task_id, %Task{
              pid: self(),
              ref: make_ref(),
              owner: self(),
              mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [type, [], task_id]}
            })
      }
    end)

    :ok
  end

  # Seeds a resumable DURABLE run through the app-booted `EvoGit.AgentState`
  # writer (unique task id, deleted on exit — no shared state is observed).
  defp seed_durable_run!(task_id, agent_id \\ 1) do
    on_exit(fn -> EvoGit.AgentState.delete_task(task_id) end)

    :ok =
      EvoGit.AgentState.checkpoint(task_id, agent_id, %{
        kind: :rewrite,
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [ReqLLM.Message.ContentPart.text("leaked run #{task_id}")]
          }
        ],
        fields: %{phase: "running"}
      })

    :ok = EvoGit.AgentState.flush()
    assert {:ok, _record} = EvoGit.AgentState.load(task_id, agent_id)
    :ok
  end
end
