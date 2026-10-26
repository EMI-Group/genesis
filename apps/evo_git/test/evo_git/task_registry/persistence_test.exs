defmodule EvoGit.TaskRegistry.PersistenceTest do
  @moduledoc """
  `async: false` is required: several tests here reach BEYOND the isolated
  `EvoGit.TaskRegistryCase` fixture into APP-GLOBAL state, so a concurrently
  running module would observe it.

  - the `describe "recheck_task resolution"` `setup` does an app-global
    `:ets.delete_all_objects(:evogit_sched_meta)` (and creates the table when
    the scheduler ETS table is absent), and one test seeds the literal
    `:evogit_sched_meta` id `1` — an id the already-`async: true` sibling
    `agent_scheduler/subagents_test.exs` deletes in its own setup.
  - the `describe "graceful cancel_task / force_kill_task"` tests seed the
    app-global `:evogit_sched_meta` / `:evogit_agent_state` /
    `:evogit_cancelling_tasks` tables and drive the GLOBAL
    `EvoGit.AgentScheduler` (`begin_graceful_cancel/1`,
    `force_kill_task_agents/1`, the `:evogit_cancelling_tasks` marker) through
    the isolated registry's cancel/force-kill handlers.
  """

  use EvoGit.TaskRegistryCase, async: false

  describe "set_review_metadata/3" do
    test "updates a task's base_sha and commit_sha in the store" do
      unique = System.unique_integer([:positive])
      task_id = "review_meta_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), task)

      TaskRegistry.set_review_metadata(task_id, "abc123", "def456")

      # Sync with a call to ensure the cast (which writes directly to the
      # store) has been processed, then read the row through BOTH surfaces:
      # the registry's `get_task/1` and the raw store read. `get_task/1` is
      # itself a store read, so the two agree by construction — one test pins
      # both call surfaces for the same row effect.
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "abc123"
      assert fetched.commit_sha == "def456"

      stored_task = EvoGit.Store.get_task(store(), task_id)
      assert stored_task.base_sha == "abc123"
      assert stored_task.commit_sha == "def456"
    end

    test "does nothing for a non-existent task" do
      # Should not raise; task simply not found
      TaskRegistry.set_review_metadata("nonexistent_task", "base", "commit")

      # Sync
      TaskRegistry.list_tasks()

      # Ensure no crash occurred — registry is still responsive
      assert is_list(TaskRegistry.list_tasks())
    end

    test "can overwrite previously set metadata" do
      unique = System.unique_integer([:positive])
      task_id = "review_meta_overwrite_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), task)

      TaskRegistry.set_review_metadata(task_id, "base1", "commit1")
      TaskRegistry.list_tasks()

      TaskRegistry.set_review_metadata(task_id, "base2", "commit2")
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.base_sha == "base2"
      assert fetched.commit_sha == "commit2"
    end
  end

  describe "TaskInfo field backfill" do
    test "normalize_tasks backfills base_sha and commit_sha as nil for old entries",
         %{data_dir: data_dir, store: store, registry: registry} do
      unique = System.unique_integer([:positive])
      task_id = "backfill_#{unique}"

      # Simulate an old persisted entry. In production, when a new column is
      # added via ALTER TABLE, existing rows get NULL. The decoder always
      # produces a complete struct (nil for NULL columns). normalize_tasks
      # then calls Map.merge(%TaskInfo{}, task) to ensure struct defaults.
      # We write a task with explicit nil values for the newer fields and
      # verify they survive a restart round-trip.
      old_task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        base_sha: nil,
        commit_sha: nil,
        model_id: nil
      }

      EvoGit.Store.put_task(store(), old_task)

      # Stop the supervised registry, then restart it so normalize_tasks runs.
      # KEEP the same store running so the backfilled data persists.
      stop_supervised(registry)

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, name: registry},
          id: registry
        )
      )

      # The backfilled task should exist with nil for the new fields
      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.base_sha == nil
      assert fetched.commit_sha == nil
      assert fetched.model_id == nil
    end
  end

  describe "persistence" do
    test "get_task retrieves a task seeded directly into the store" do
      unique = System.unique_integer([:positive])
      task_id = "persistence_crud_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = EvoGit.Store.put_task(store(), task)

      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.id == task_id
      assert fetched.type == :genesis
      assert fetched.status == :completed
      assert fetched.opts == [path: "/tmp/test"]
      assert fetched.result == nil
    end

    test "task persists across a registry restart with the same store", %{
      data_dir: data_dir,
      store: store,
      registry: registry
    } do
      unique = System.unique_integer([:positive])
      task_id = "persistence_durable_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test", objective: "durability check"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = EvoGit.Store.put_task(store(), task)

      # Confirm the task is visible before restart.
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # Stop the registry but KEEP the same store running (store is durable on disk).
      stop_supervised(registry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, name: registry},
          id: registry
        )
      )

      # The task persisted in the store must survive the registry restart.
      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{} = fetched
      assert fetched.id == task_id
      assert fetched.type == :evolve
      assert fetched.status == :completed
      assert fetched.opts[:objective] == "durability check"
    end
  end

  describe "recent projects persistence" do
    test "recent project persists across a registry restart with the same store",
         %{data_dir: data_dir, store: store, registry: registry} do
      path = "/some/path"
      name = "My Project"

      :ok = TaskRegistry.add_recent_project(path, name)

      # Confirm the project is listed before the restart.
      projects_before = TaskRegistry.list_recent_projects()
      assert Enum.any?(projects_before, &(&1.path == path and &1.name == name))

      # Stop the registry but KEEP the same store running (store is durable on disk).
      stop_supervised(registry)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, name: registry},
          id: registry
        )
      )

      # The project must survive the registry restart.
      projects_after = TaskRegistry.list_recent_projects()
      matching = Enum.filter(projects_after, &(&1.path == path))
      assert length(matching) == 1
      assert hd(matching).name == name
    end
  end

  describe "GenServer resilience and state preservation" do
    test "registry stays responsive across insert / read / delete mutations" do
      unique = System.unique_integer([:positive])
      task_id = "resilient_#{unique}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), task)

      pid = GenServer.whereis(TaskRegistry.server())
      assert is_pid(pid)
      assert Process.alive?(pid)

      # list_tasks returns the inserted task (the store is the source of truth)
      tasks = TaskRegistry.list_tasks()
      assert Enum.any?(tasks, &(&1.id == task_id))

      # get_task retrieves it individually
      assert %TaskInfo{} = TaskRegistry.get_task(task_id)

      # The process stays alive after reads
      assert Process.alive?(pid)

      # Each delete_task cast mutates the store.
      for i <- 1..5 do
        id = "survive_#{unique}_#{i}"

        EvoGit.Store.put_task(store(), %TaskInfo{
          id: id,
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        })

        TaskRegistry.delete_task(id)
      end

      # Synchronize (list_tasks is a call that flushes pending casts).
      remaining = TaskRegistry.list_tasks()
      remaining_ids = Enum.map(remaining, & &1.id)

      # The process survived every mutation without crashing OR restarting.
      assert Process.alive?(pid)
      assert GenServer.whereis(TaskRegistry.server()) == pid

      # The five deleted rows are gone; the earlier insert is untouched.
      for i <- 1..5 do
        refute "survive_#{unique}_#{i}" in remaining_ids
      end

      assert task_id in remaining_ids
      assert is_list(TaskRegistry.get_unique_paths())
    end
  end

  describe "corruption resilience — structural" do
    test "registry reads, cleanup and completion all survive structurally corrupt rows", %{
      sqlite_path: sqlite_path
    } do
      unique = System.unique_integer([:positive])

      # Good tasks
      good1 = %TaskInfo{
        id: "good1_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      good2 = %TaskInfo{
        id: "good2_#{unique}",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), good1)
      EvoGit.Store.put_task(store(), good2)

      # Structurally corrupt entries (valid keys, wrong-shape values).
      # Inject corrupt rows via raw SQL (bypassing put_task validation).
      # The new typed API rejects non-struct input, so we go under the hood.
      {:ok, raw_conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(
        raw_conn,
        "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
        ["bad_string_#{unique}", "completed", "<<invalid json>>"]
      )

      XqliteNIF.execute(
        raw_conn,
        "INSERT OR REPLACE INTO tasks (id, status, type) VALUES (?1, ?2, ?3)",
        ["bad_map_#{unique}", "completed", "invalid_type_atom_xyz"]
      )

      XqliteNIF.close(raw_conn)

      EvoGit.Store.put_project(
        store(),
        %EvoGit.RecentProject{
          path: "/some/path",
          name: "test",
          last_opened_at: DateTime.utc_now()
        }
      )

      # A corrupt row ELSEWHERE must not block a new task's completion cycle
      # (the cast also runs the internal cleanup pass).
      new_id = "new_task_#{unique}"

      EvoGit.Store.put_task(store(), %TaskInfo{
        id: new_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      })

      TaskRegistry.update_task_status(new_id, :completed, {:ok, %{usage: nil, agent_count: 1}})

      # An explicit cleanup cycle must survive too (it reads only ids).
      trigger_cleanup!()

      pid = GenServer.whereis(TaskRegistry.server())
      assert is_pid(pid)
      assert Process.alive?(pid)

      # list_tasks must NOT crash — it should return only valid TaskInfo structs
      tasks = TaskRegistry.list_tasks()
      assert is_list(tasks)

      ids = Enum.map(tasks, & &1.id)
      assert "good1_#{unique}" in ids
      assert "good2_#{unique}" in ids
      # Note: with JSON encoding, rows with invalid opts still decode
      # (opts becomes nil). They appear as valid TaskInfo structs.
      # The registry stays alive regardless.

      # The task that completed while corrupt rows existed is persisted.
      fetched = TaskRegistry.get_task(new_id)
      assert %TaskInfo{} = fetched
      assert fetched.status == :completed

      # Registry still alive after reads
      assert Process.alive?(pid)

      # get_unique_paths works
      paths = TaskRegistry.get_unique_paths()
      assert is_list(paths)

      # list_recent_projects works
      projects = TaskRegistry.list_recent_projects()
      assert is_list(projects)
    end
  end

  describe "status recovery from spurious :failed" do
    test "a :failed task can recover to :completed via update_task_status" do
      task_id = "recover_completed_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :failed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), task)

      usage = %EvoGit.Agent.Usage{input_tokens: 100, total_tokens: 100}

      # update_task_status is a cast; list_tasks() syncs to ensure it's processed.
      TaskRegistry.update_task_status(task_id, :completed, nil,
        usage: usage,
        commit_sha: "abc123"
      )

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      # The spurious :failed was overwritten by the legitimate :completed.
      assert fetched.status == :completed
      # Recovery should persist metadata, not just flip status.
      assert fetched.commit_sha == "abc123"
      assert fetched.usage == %EvoGit.Agent.Usage{input_tokens: 100, total_tokens: 100}
    end

    test "a :finalizing status update is accepted for a :failed task (recovery before completion)" do
      task_id = "recover_finalizing_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :failed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), task)

      # The registry subscribes to the "tasks" PubSub topic on init. The
      # emitter broadcasts the task_updated shape with the emitting node; a
      # local-node broadcast passes the node filter and is applied.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :finalizing, node()}
      )

      # Sync with a call so the info message is processed before we assert.
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      # :failed should accept :finalizing (was previously blocked).
      assert fetched.status == :finalizing
    end

    test "terminal rows reject stale updates on both the cast and PubSub paths (guard integrity)" do
      unique = System.unique_integer([:positive])
      completed_id = "completed_guard_#{unique}"
      cancelled_id = "cancelled_guard_#{unique}"

      for {id, status} <- [{completed_id, :completed}, {cancelled_id, :cancelled}] do
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: id,
          type: :genesis,
          status: status,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        })
      end

      # A late :failed update must NOT overwrite a terminal :completed (cast path).
      TaskRegistry.update_task_status(completed_id, :failed, "late error")

      # A late :finalizing PubSub update must NOT overwrite a terminal :cancelled.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, cancelled_id, :finalizing, node()}
      )

      TaskRegistry.list_tasks()

      completed = TaskRegistry.get_task(completed_id)
      assert completed != nil
      assert completed.status == :completed

      cancelled = TaskRegistry.get_task(cancelled_id)
      assert cancelled != nil
      assert cancelled.status == :cancelled
    end
  end

  describe "cross-node PubSub filtering" do
    test "a :finalizing broadcast from another node is not applied locally" do
      unique = System.unique_integer([:positive])
      task_id = "cross_node_finalizing_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      drain_tasks_mailbox()

      # A broadcast emitted on a remote node (node != node()) must be filtered
      # out by the handler's node guard — the local store is untouched.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :finalizing, :other_node@host}
      )

      # Sync with a call so any (wrongly) accepted info message is processed.
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched != nil
      assert fetched.status == :running

      # The same filter applies to an unknown id: no row is ever created.
      unknown_id = "cross_node_unknown_#{unique}"

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, unknown_id, :finalizing, :other_node@host}
      )

      TaskRegistry.list_tasks()
      assert TaskRegistry.get_task(unknown_id) == nil
    end
  end

  describe "startup reconciliation of orphaned :finalizing tasks" do
    test "restart marks an orphaned :finalizing row :failed (with the canonical payload) but leaves a :running row untouched",
         %{data_dir: data_dir, store: store, registry: registry} do
      unique = System.unique_integer([:positive])
      finalizing_id = "startup_finalizing_#{unique}"
      running_id = "startup_running_#{unique}"
      future_lease = System.system_time(:second) + 300

      # Stop the initial registry FIRST so the seeded rows exist in the Store
      # before the fresh registry boots — literally "fresh registry against a
      # DB containing :finalizing rows". The Store stays running (durable on
      # disk); it is NOT stopped/restarted.
      stop_supervised(registry)

      finalizing_task = %TaskInfo{
        id: finalizing_id,
        type: :genesis,
        status: :finalizing,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: future_lease
      }

      running_task = %TaskInfo{
        id: running_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: future_lease
      }

      :ok = EvoGit.Store.put_task(store(), finalizing_task)
      :ok = EvoGit.Store.put_task(store(), running_task)

      # Restart the registry pointing at the same store and data_dir.
      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, name: registry},
          id: registry
        )
      )

      # The Store is the durable source of truth; the registry's init
      # reconciliation must have marked the orphaned :finalizing row :failed,
      # recording the exact lib result literal and the canonical error payload.
      finalizing = EvoGit.Store.get_task(store(), finalizing_id)
      assert finalizing != nil
      assert finalizing.status == :failed
      assert finalizing.finished_at != nil
      assert finalizing.lease_expires_at == nil
      assert finalizing.result == "Runtime restarted during task finalization"

      assert finalizing.error == %{
               kind: :restart,
               source: :startup_reconcile,
               message: "Runtime restarted during task finalization",
               stacktrace: nil
             }

      # Control row: a :running task with a valid (future) lease must NOT be
      # touched at init — sweeping orphaned :running tasks is the :lease_sweep
      # path (covered in lease_heartbeat_test.exs).
      running = EvoGit.Store.get_task(store(), running_id)
      assert running != nil
      assert running.status == :running
      assert running.lease_expires_at == future_lease
    end

    test "restart marks an orphaned :cancelling row :cancelled", %{
      data_dir: data_dir,
      store: store,
      registry: registry
    } do
      unique = System.unique_integer([:positive])
      cancelling_id = "startup_cancelling_#{unique}"
      future_lease = System.system_time(:second) + 300

      stop_supervised(registry)

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: cancelling_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: future_lease
        })

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, name: registry},
          id: registry
        )
      )

      # The runtime died mid-cancel — the orphaned :cancelling row must resolve
      # to :cancelled (never stay :cancelling forever).
      fetched = EvoGit.Store.get_task(store(), cancelling_id)
      assert fetched != nil
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      assert is_binary(fetched.result)
    end
  end

  describe "list_tasks_summary / by_path / changed_since — since filter semantics" do
    test "list_tasks_summary/2 since returns only strictly-newer rows; boundary-equal excluded; nil since returns all",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "summary_since_a_#{unique}"
      t2 = "summary_since_b_#{unique}"
      t3 = "summary_since_c_#{unique}"

      for {id, status} <- [{t1, :completed}, {t2, :running}, {t3, :completed}] do
        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-since"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      # Control the store-internal updated_at column directly via raw SQL so
      # the string-comparison semantics of the `since` filter are deterministic.
      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")

      # Strictly-newer only: the boundary-equal row (t2) is excluded.
      ids =
        TaskRegistry.list_tasks_summary([], "2024-01-02T00:00:00.000Z")
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == [t3]

      # nil since → no time filter.
      ids_all =
        TaskRegistry.list_tasks_summary([], nil)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids_all == Enum.sort([t1, t2, t3])

      # statuses + since combined.
      assert TaskRegistry.list_tasks_summary([:completed], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id)
             |> Enum.sort() == [t3]

      assert TaskRegistry.list_tasks_summary([:running], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id) == [t2]
    end

    test "list_tasks_summary_by_path/3 combines path + since (+ statuses)", %{
      sqlite_path: sqlite_path
    } do
      unique = System.unique_integer([:positive])
      a1 = "summary_path_a_#{unique}"
      a2 = "summary_path_b_#{unique}"
      b1 = "summary_path_c_#{unique}"

      for {id, path, status} <- [
            {a1, "/proj-a", :completed},
            {a2, "/proj-a", :running},
            {b1, "/proj-b", :completed}
          ] do
        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: path],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      set_updated_at(sqlite_path, a1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, a2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, b1, "2024-01-03T00:00:00.000Z")

      assert TaskRegistry.list_tasks_summary_by_path("/proj-a", [], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id) == [a2]

      assert TaskRegistry.list_tasks_summary_by_path("/proj-a", [], nil)
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([a1, a2])

      assert TaskRegistry.list_tasks_summary_by_path("/proj-b", [], "2024-01-01T00:00:00.000Z")
             |> Enum.map(& &1.id) == [b1]

      # path + statuses + since: a2 is :running, so no :completed matches.
      assert TaskRegistry.list_tasks_summary_by_path(
               "/proj-a",
               [:completed],
               "2024-01-01T00:00:00.000Z"
             ) ==
               []

      # path + statuses, no since.
      assert TaskRegistry.list_tasks_summary_by_path("/proj-a", [:completed], nil)
             |> Enum.map(& &1.id) == [a1]
    end

    test "list_tasks_changed_since/1 returns only newer rows with the 16-key projection",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "changed_a_#{unique}"
      t2 = "changed_b_#{unique}"
      t3 = "changed_c_#{unique}"

      for {id, status} <- [{t1, :completed}, {t2, :running}, {t3, :pending}] do
        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-changed"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")

      results = TaskRegistry.list_tasks_changed_since("2024-01-02T00:00:00.000Z")
      assert Enum.map(results, & &1.id) |> Enum.sort() == [t3]

      # Future since → nothing.
      assert TaskRegistry.list_tasks_changed_since("2099-01-01T00:00:00.000Z") == []

      # 16-key projection; updated_at passed through as the raw ISO string.
      [row] = TaskRegistry.list_tasks_changed_since("2024-01-02T00:00:00.000Z")

      expected_keys =
        [
          :id,
          :status,
          :review_status,
          :started_at,
          :finished_at,
          :type,
          :project_path,
          :opts,
          :branch_name,
          :model_id,
          :agent_count,
          :base_sha,
          :commit_sha,
          :lease_expires_at,
          :updated_at,
          :error
        ]
        |> Enum.sort()

      assert Map.keys(row) |> Enum.sort() == expected_keys
      assert row.id == t3
      assert row.status == :pending
      assert row.updated_at == "2024-01-03T00:00:00.000Z"
      assert row.project_path == "/proj-changed"
    end
  end

  describe "list_task_ids/1 — minimal id/status/updated_at projection" do
    test "returns ALL tasks (one seeded fixture) and filters by single or multiple statuses",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      t1 = "task_ids_a_#{unique}"
      t2 = "task_ids_b_#{unique}"
      t3 = "task_ids_c_#{unique}"
      t4 = "task_ids_d_#{unique}"

      # One seeded fixture spanning the whole status matrix: every filter case
      # below (all / single status / union) reads THIS fixture.
      for {id, status} <- [
            {t1, :completed},
            {t2, :running},
            {t3, :pending},
            {t4, :failed}
          ] do
        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/proj-task-ids"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil
          })
      end

      # Control the store-internal updated_at column so the raw string
      # pass-through is deterministic.
      set_updated_at(sqlite_path, t1, "2024-01-01T00:00:00.000Z")
      set_updated_at(sqlite_path, t2, "2024-01-02T00:00:00.000Z")
      set_updated_at(sqlite_path, t3, "2024-01-03T00:00:00.000Z")
      set_updated_at(sqlite_path, t4, "2024-01-04T00:00:00.000Z")

      # list_task_ids/0 → every row.
      rows = TaskRegistry.list_task_ids()

      assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([t1, t2, t3, t4])

      # Every row is a minimal projection — exactly id/status/updated_at, no
      # heavy JSON fields decoded.
      for row <- rows do
        assert Map.keys(row) |> Enum.sort() == [:id, :status, :updated_at]
        assert is_atom(row.status)
        # Raw fixed-precision ISO binary, NOT a decoded DateTime.
        assert is_binary(row.updated_at)
      end

      by_id = Map.new(rows, &{&1.id, &1})
      assert by_id[t1].status == :completed
      assert by_id[t1].updated_at == "2024-01-01T00:00:00.000Z"
      assert by_id[t2].status == :running
      assert by_id[t2].updated_at == "2024-01-02T00:00:00.000Z"
      assert by_id[t3].status == :pending
      assert by_id[t3].updated_at == "2024-01-03T00:00:00.000Z"
      assert by_id[t4].status == :failed
      assert by_id[t4].updated_at == "2024-01-04T00:00:00.000Z"

      # Single status → only matching rows.
      single = TaskRegistry.list_task_ids([:completed])
      assert Enum.map(single, & &1.id) == [t1]
      assert Enum.all?(single, &(&1.status == :completed))

      assert TaskRegistry.list_task_ids([:running]) |> Enum.map(& &1.id) == [t2]

      # Multiple statuses → the union of matches.
      union = TaskRegistry.list_task_ids([:completed, :failed])
      assert Enum.map(union, & &1.id) |> Enum.sort() == Enum.sort([t1, t4])
      assert Enum.all?(union, &(&1.status in [:completed, :failed]))
    end
  end

  describe "recheck_task resolution" do
    setup do
      # The :evogit_sched_meta table is normally owned by AgentScheduler; in
      # this test env it may or may not be running. Create it if missing and
      # start each test from a clean table (no agents are active in tests).
      if :ets.whereis(:evogit_sched_meta) == :undefined do
        :ets.new(:evogit_sched_meta, [:set, :named_table, :public])
      end

      :ets.delete_all_objects(:evogit_sched_meta)

      on_exit(fn ->
        :ets.delete_all_objects(:evogit_sched_meta)
      end)

      :ok
    end

    test "resolves :running tasks to :completed when no sched_meta entries remain (preserving a pre-existing branch_name)" do
      unique = System.unique_integer([:positive])
      plain_id = "recheck_resolve_#{unique}"
      named_id = "recheck_preserve_#{unique}"

      # Two rows, one without and one WITH a pre-existing branch_name — the
      # "no result found" resolution must clear the lease for both and must
      # never clobber an existing branch_name.
      for {id, branch_name} <- [{plain_id, nil}, {named_id, "evogit/orig"}] do
        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
            id: id,
            type: :genesis,
            status: :running,
            opts: [path: "/tmp/test"],
            ref: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil,
            branch_name: branch_name,
            lease_expires_at: System.system_time(:second) + 300
          })
      end

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      send(TaskRegistry.server(), {:recheck_task, plain_id})
      send(TaskRegistry.server(), {:recheck_task, named_id})
      assert_receive {:task_updated, ^plain_id, :completed, _}, 1_000
      assert_receive {:task_updated, ^named_id, :completed, _}, 1_000

      fetched = EvoGit.Store.get_task(store(), plain_id)
      assert fetched.status == :completed
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      assert fetched.branch_name == nil

      preserved = EvoGit.Store.get_task(store(), named_id)
      assert preserved.status == :completed
      assert preserved.branch_name == "evogit/orig"
    end

    test "reschedules while any sched_meta entry remains; resolves after cleanup" do
      unique = System.unique_integer([:positive])
      task_id = "recheck_active_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      # Seed an entry carrying a tagged-ok result (as the scheduler might leave
      # before recycling the entry). ANY remaining entry for the task means
      # "agents still active" (Lease.sched_meta_has_active_agents?/1) → the
      # recheck must reschedule, not resolve.
      meta = %EvoGit.AgentScheduler.SchedMeta{
        id: 1,
        depth: 0,
        spec: recheck_agent_spec(),
        task_id: task_id,
        parent_id: nil,
        status: :completed,
        sub_agent_results: %{"agent-1" => {:ok, %{branch_name: "feat/x", commit_sha: "abc"}}}
      }

      :ets.insert(:evogit_sched_meta, {1, meta})

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      send(TaskRegistry.server(), {:recheck_task, task_id})

      # The recheck handler RESCHEDULES when any sched_meta entry remains, so it
      # must not emit a broadcast. Sync against the SAME registry with a call
      # (queued strictly AFTER the recheck message, so once it returns the recheck
      # handler has fully run); any broadcast that handler emitted was sent
      # registry→test-process BEFORE the call reply, and same-sender→same-receiver
      # signal order is guaranteed — so it is already in the mailbox and a
      # zero-window refute is sufficient (no blind 200ms timeout needed). The
      # refute is pinned to THIS task id so a broadcast about another task (the
      # "tasks" topic is process-global) can never fail it.
      TaskRegistry.list_tasks()
      refute_receive {:task_updated, ^task_id, _, _}, 0

      fetched = EvoGit.Store.get_task(store(), task_id)
      assert fetched.status == :running
      assert fetched.branch_name == nil

      # Once the entry is recycled (deleted), the next recheck resolves. The
      # result was lost with the entry, so the task is marked :completed with a
      # nil result and no branch_name.
      :ets.delete(:evogit_sched_meta, 1)
      send(TaskRegistry.server(), {:recheck_task, task_id})
      assert_receive {:task_updated, ^task_id, :completed, _}, 1_000

      resolved = EvoGit.Store.get_task(store(), task_id)
      assert resolved.status == :completed
      assert resolved.result == nil
      assert resolved.branch_name == nil
    end

    test "branch_name is extracted from {:ok, %{branch_name: _}} results on the cast path" do
      unique = System.unique_integer([:positive])
      task_id = "recheck_cast_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      TaskRegistry.update_task_status(task_id, :completed, {:ok, %{branch_name: "feat/x"}},
        commit_sha: "abc"
      )

      # Sync with a call to ensure the cast was processed.
      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :completed
      assert fetched.branch_name == "feat/x"
      assert fetched.commit_sha == "abc"
    end
  end

  describe "recent projects — nil last_opened_at handling" do
    test "nil last_opened_at rows are sorted last and never crash add/list", %{
      sqlite_path: sqlite_path
    } do
      unique = System.unique_integer([:positive])
      insert_project_row(sqlite_path, "/nil-proj-#{unique}", "Nil Proj", nil)

      :ok = TaskRegistry.add_recent_project("/fresh-#{unique}", "Fresh")

      projects = TaskRegistry.list_recent_projects()
      paths = Enum.map(projects, & &1.path)

      assert "/fresh-#{unique}" in paths
      assert "/nil-proj-#{unique}" in paths
      assert hd(projects).path == "/fresh-#{unique}"
      assert List.last(projects).path == "/nil-proj-#{unique}"
    end

    test "trim removes oldest dated rows (and nil rows) first, never crashes on nil",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      now = DateTime.utc_now()

      # @max_recent_projects is 10 (task_registry.ex); seed 10 dated rows plus
      # one nil row, then add one more → 12 rows → trim keeps the 10 newest.
      insert_project_row(sqlite_path, "/nil-proj-#{unique}", "Nil Proj", nil)

      for i <- 1..10 do
        :ok =
          EvoGit.Store.put_project(store(), %EvoGit.RecentProject{
            path: "/dated-#{unique}-#{i}",
            name: "D#{i}",
            last_opened_at: DateTime.add(now, -i * 86_400, :second)
          })
      end

      :ok = TaskRegistry.add_recent_project("/newest-#{unique}", "Newest")

      projects = TaskRegistry.list_recent_projects()
      assert length(projects) == 10

      # Sorted descending: newest first, then /dated-1..9. The oldest dated row
      # (/dated-10) and the nil row (sorts last = oldest) are trimmed.
      assert Enum.map(projects, & &1.path) ==
               ["/newest-#{unique}"] ++ Enum.map(1..9, &"/dated-#{unique}-#{&1}")
    end
  end

  describe "graceful cancel_task / force_kill_task" do
    test "graceful cancel from :running → :cancelling, agents notified, marker registered" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_running_#{unique}"
      agent_id = System.unique_integer([:positive])

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      # Register one live agent for the task (scheduler ETS) so we can verify
      # the cancel notification + cancel_requested flag injection.
      :ets.insert(:evogit_sched_meta, {agent_id, cancel_test_sched_meta(agent_id, task_id)})
      :ets.insert(:evogit_agent_state, {agent_id, cancel_test_agent_state()})

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, agent_id)
        :ets.delete(:evogit_agent_state, agent_id)
        :ets.delete(:evogit_cancelling_tasks, task_id)
      end)

      assert :ok = TaskRegistry.cancel_task(task_id)

      # Status transitioned to :cancelling — non-terminal (finished_at stays nil).
      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelling
      assert fetched.finished_at == nil

      # Agent received the cancel message + cancel_requested flag.
      [{^agent_id, st}] = :ets.lookup(:evogit_agent_state, agent_id)
      assert st.cancel_requested == true
      assert Enum.any?(st.pending_user_messages, &String.contains?(&1, "being cancelled"))

      # Task registered in the graceful-cancel marker.
      assert :ets.member(:evogit_cancelling_tasks, task_id)
    end

    test "graceful cancel emits exactly one tasks-topic broadcast" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_single_broadcast_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      drain_tasks_mailbox()

      assert :ok = TaskRegistry.cancel_task(task_id)

      # The emitter must broadcast exactly one :task_updated per cancel — the
      # :cancelling transition — never a second one from the internal
      # status-update path (double-broadcast elimination).
      assert_receive {:task_updated, ^task_id, :cancelling, _}, 1_000

      # Exactly one broadcast (the :cancelling one) may be emitted FOR THIS TASK.
      # ZERO-WAIT, on ordering rather than a quiet window: `cancel_task/1` is a
      # synchronous `GenServer.call` and the handler emits EVERY broadcast it
      # makes INLINE before replying (the :cancelling transition comes from the
      # `handle_update_status/6` call at task_registry.ex, the pending-arm
      # :cancelled one from the branch itself, and the agent notification from
      # `AgentScheduler.begin_graceful_cancel/1` — all inside the same handler).
      # Broadcasts are registry → test and the reply is registry → test too, so
      # signal order guarantees anything the handler broadcast is ALREADY in
      # this mailbox once the call returns; a `0`-timeout refute is therefore
      # complete evidence that no second broadcast was emitted, at no wall-clock
      # cost. Both shapes are pinned to this task's id, so another registry
      # instance's traffic on the process-global "tasks" topic is ignored.
      refute_receive {:task_updated, ^task_id, _, _}, 0
      refute_receive {:task_deleted, ^task_id, _}, 0

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelling
    end

    test "cancel_task is idempotent on :cancelling — no duplicate messages" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_idem_#{unique}"
      agent_id = System.unique_integer([:positive])

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      :ets.insert(:evogit_sched_meta, {agent_id, cancel_test_sched_meta(agent_id, task_id)})
      # Simulate the ORIGINAL graceful cancel (performed while the task was
      # :running): the agent already holds the cancel_requested flag. The
      # idempotent path must preserve it without re-sending any messages.
      :ets.insert(
        :evogit_agent_state,
        {agent_id, %{cancel_test_agent_state() | cancel_requested: true}}
      )

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, agent_id)
        :ets.delete(:evogit_agent_state, agent_id)
        :ets.delete(:evogit_cancelling_tasks, task_id)
      end)

      # First cancel on an already-:cancelling task is a no-op (:ok, no message
      # re-send since the agents already hold the cancel message from the
      # original graceful-cancel request).
      assert :ok = TaskRegistry.cancel_task(task_id)
      assert :ok = TaskRegistry.cancel_task(task_id)

      [{^agent_id, st}] = :ets.lookup(:evogit_agent_state, agent_id)
      assert st.cancel_requested == true

      assert length(st.pending_user_messages) == 0,
             "idempotent cancel must NOT append the cancel message again, got #{inspect(st.pending_user_messages)}"

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelling
    end

    test ":pending task is marked :cancelled immediately and start_task refuses it" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_pending_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :pending,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      assert :ok = TaskRegistry.cancel_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil

      # start_task guard: a :cancelled (or :cancelling) task must never start.
      state = :sys.get_state(TaskRegistry.server())

      assert {:reply, {:error, :cancelled}, ^state} =
               TaskRegistry.handle_call(
                 {:start_task, task_id, :genesis, [path: "/tmp/test"]},
                 {self(), make_ref()},
                 state
               )

      # Same guard for a :cancelling task.
      cancelling_id = "cancel_start_guard_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: cancelling_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      assert {:reply, {:error, :cancelled}, ^state} =
               TaskRegistry.handle_call(
                 {:start_task, cancelling_id, :genesis, [path: "/tmp/test"]},
                 {self(), make_ref()},
                 state
               )
    end

    test "cancel_task returns {:error, :not_running} for terminal/:finalizing states and {:error, :not_found} for missing" do
      unique = System.unique_integer([:positive])

      for {status, idx} <- Enum.with_index([:completed, :failed, :cancelled, :finalizing]) do
        task_id = "cancel_invalid_#{unique}_#{idx}"

        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
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

        assert {:error, :not_running} = TaskRegistry.cancel_task(task_id),
               "expected :not_running for #{status}"
      end

      assert {:error, :not_found} = TaskRegistry.cancel_task("cancel_missing_#{unique}")
    end

    test "a :cancelling task reaching a terminal phase persists :cancelled with the result preserved and no error (both arms)" do
      unique = System.unique_integer([:positive])

      # The wrapper completes (:completed arm) or fails (:failed arm) during the
      # grace period — `handle_update_status` must force-map BOTH to :cancelled,
      # PRESERVE the intermediate result, and never persist an error payload
      # (a graceful cancel is never a failure).
      cases = [
        {:completed, {:ok, %{branch_name: "feat/x"}}},
        {:failed, {:error, "boom during grace"}}
      ]

      ids =
        for {idx, {terminal_status, result}} <- Enum.with_index(cases) do
          task_id = "cancel_final_map_#{unique}_#{idx}"

          :ok =
            EvoGit.Store.put_task(store(), %TaskInfo{
              id: task_id,
              type: :genesis,
              status: :cancelling,
              opts: [path: "/tmp/test"],
              ref: nil,
              started_at: DateTime.utc_now(),
              finished_at: nil,
              logs: [],
              result: nil,
              lease_expires_at: System.system_time(:second) + 300
            })

          # Simulate the marker being registered by the earlier graceful cancel.
          :ets.insert(:evogit_cancelling_tasks, {task_id})
          on_exit(fn -> :ets.delete(:evogit_cancelling_tasks, task_id) end)

          TaskRegistry.update_task_status(task_id, terminal_status, result,
            error: %{
              kind: :error,
              source: :result_handler,
              message: "Task failed: #{inspect(result)}",
              stacktrace: ["(elixir) lib/foo.ex:1: Foo.bar/0"]
            }
          )

          task_id
        end

      TaskRegistry.list_tasks()

      for {task_id, {_terminal_status, result}} <- Enum.zip(ids, cases) do
        fetched = TaskRegistry.get_task(task_id)

        assert fetched.status == :cancelled,
               "cancelling task must end :cancelled, got #{inspect(fetched.status)}"

        assert fetched.finished_at != nil
        assert fetched.lease_expires_at == nil

        assert fetched.result == result,
               "result must be preserved, got #{inspect(fetched.result)}"

        # The guard: no error payload rides a :cancelled row.
        assert fetched.error == nil

        # Column round-trip via the raw Store read agrees.
        store_fetched = EvoGit.Store.get_task(store(), task_id)
        assert store_fetched.status == :cancelled
        assert store_fetched.result == result
        assert store_fetched.error == nil

        # Terminal state cleaned up the marker.
        refute :ets.member(:evogit_cancelling_tasks, task_id)
      end
    end

    test "a :finalizing broadcast does not clobber :cancelling" do
      unique = System.unique_integer([:positive])
      task_id = "cancel_finalizing_guard_#{unique}"

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil
        })

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, task_id, :finalizing, node()}
      )

      TaskRegistry.list_tasks()

      fetched = TaskRegistry.get_task(task_id)

      assert fetched.status == :cancelling,
             "a cancelling task reaching phase finalization must keep :cancelling, got #{inspect(fetched.status)}"
    end

    test "force_kill_task works from :running and records the force-kill error payload with result nil" do
      unique = System.unique_integer([:positive])
      task_id = "forcekill_error_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      # Make the task "owned": inject a live wrapper into task_refs.
      :sys.replace_state(TaskRegistry.server(), fn state ->
        %{
          state
          | task_refs: Map.put(state.task_refs, task_id, cancel_test_task(wrapper))
        }
      end)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      assert fetched.status == :failed
      assert fetched.finished_at != nil
      assert fetched.lease_expires_at == nil
      # Force-killed tasks keep result nil (review semantics unchanged).
      assert fetched.result == nil

      # The canonical force-kill error payload is persisted (no stacktrace).
      assert fetched.error == %{
               kind: :force_kill,
               source: :force_kill_task,
               message: "Task force-killed by user",
               stacktrace: nil
             }

      # Column round-trip via the raw Store read agrees.
      store_fetched = EvoGit.Store.get_task(store(), task_id)
      assert store_fetched.status == :failed
      assert store_fetched.result == nil
      assert store_fetched.error == fetched.error

      state = :sys.get_state(TaskRegistry.server())
      refute Map.has_key?(state.task_refs, task_id)
    end

    test "force_kill_task works from :cancelling (escalation path) and clears the marker" do
      unique = System.unique_integer([:positive])
      task_id = "forcekill_cancelling_#{unique}"
      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      :ok =
        EvoGit.Store.put_task(store(), %TaskInfo{
          id: task_id,
          type: :genesis,
          status: :cancelling,
          opts: [path: "/tmp/test"],
          ref: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + 300
        })

      :ets.insert(:evogit_cancelling_tasks, {task_id})
      on_exit(fn -> :ets.delete(:evogit_cancelling_tasks, task_id) end)

      :sys.replace_state(TaskRegistry.server(), fn state ->
        %{
          state
          | task_refs: Map.put(state.task_refs, task_id, cancel_test_task(wrapper))
        }
      end)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      fetched = TaskRegistry.get_task(task_id)
      # Force-kill persists :failed (NOT :cancelled) with no result — a
      # force-killed task is never "cancelled" (that is reserved for the
      # graceful :cancelling → :cancelled path).
      assert fetched.status == :failed
      assert fetched.finished_at != nil
      assert fetched.result == nil

      # The brutal path cleans up the graceful-cancel marker.
      refute :ets.member(:evogit_cancelling_tasks, task_id)

      state = :sys.get_state(TaskRegistry.server())
      refute Map.has_key?(state.task_refs, task_id)
    end

    test "force_kill_task returns {:error, :not_found} for an unknown task" do
      assert {:error, :not_found} =
               TaskRegistry.force_kill_task(
                 "forcekill_missing_#{System.unique_integer([:positive])}"
               )
    end
  end

  # --- Helpers ---

  # Drains the test-process mailbox of any messages broadcast before the
  # measurement window (PubSub delivery is async).
  defp drain_tasks_mailbox do
    receive do
      _msg -> drain_tasks_mailbox()
    after
      0 -> :ok
    end
  end

  # AgentSpec for the graceful-cancel agent-notification tests.
  defp cancel_test_agent_spec do
    %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %EvoGit.Core.PhyloGraphNode{
        repo: "/tmp/test",
        base_commit: "abc",
        current_commit: "abc"
      },
      agent_module: __MODULE__,
      objective: "test"
    }
  end

  # SchedMeta entry for a live agent of the given task.
  defp cancel_test_sched_meta(agent_id, task_id) do
    %EvoGit.AgentScheduler.SchedMeta{
      id: agent_id,
      depth: 0,
      spec: cancel_test_agent_spec(),
      retries: 0,
      task_id: task_id,
      from: {self(), make_ref()}
    }
  end

  # AgentState entry for a live agent.
  defp cancel_test_agent_state do
    %EvoGit.AgentScheduler.AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "/tmp/test"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8
    }
  end

  # A %Task{} wrapper entry for the task_refs map (content beyond pid is
  # irrelevant to the force-kill/heartbeat paths).
  defp cancel_test_task(pid) do
    %Task{
      pid: pid,
      ref: make_ref(),
      owner: self(),
      mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], "test"]}
    }
  end

  # Overwrites the store-internal updated_at column with a fixed-precision ISO
  # string via a raw connection (the summary `since` filters compare strings).
  defp set_updated_at(sqlite_path, task_id, iso) do
    {:ok, raw_conn} = Xqlite.open(sqlite_path)

    {:ok, _} =
      XqliteNIF.execute(raw_conn, "UPDATE tasks SET updated_at = ?1 WHERE id = ?2", [
        iso,
        task_id
      ])

    XqliteNIF.close(raw_conn)
  end

  defp insert_project_row(sqlite_path, path, name, last_opened_at) do
    {:ok, raw_conn} = Xqlite.open(sqlite_path)

    {:ok, _} =
      XqliteNIF.execute(
        raw_conn,
        "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
        [path, name, last_opened_at]
      )

    XqliteNIF.close(raw_conn)
  end

  defp recheck_agent_spec do
    %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %EvoGit.Core.PhyloGraphNode{
        repo: "/tmp/test",
        base_commit: "abc",
        current_commit: "abc"
      },
      agent_module: __MODULE__,
      objective: "test"
    }
  end
end
