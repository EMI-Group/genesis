defmodule EvoGit.TaskRegistry.UnknownStatusLivenessTest do
  @moduledoc """
  Liveness safety for a task row whose PERSISTED status text is outside
  `EvoGit.Store.Codec.known_statuses/0`.

  `EvoGit.Store.get_task_status/2` answers THREE shapes — `nil` (no row), a
  known status atom, or `{:unknown, raw}` (the row EXISTS, its status text is
  unreadable) — and `EvoGit.TaskRegistry.Lease` classifies them:
  `lease_renewable?/1` (heartbeat) renews `{:unknown, _}`, `leaked?/3` (sweep)
  never leaks it. These tests pin both, plus the conservative answers of the
  `cancel_task/1` / `force_kill_task/1` guards: an unreadable status must never
  let a LIVE task look leaked, and must never let a present row be treated as
  absent or be marked/killed.

  An unrecognized spelling is seeded by writing the status text STRAIGHT into
  the row (the raw `TaskRowRaw` schema, inside `RepoScope`), i.e. exactly what a
  whitelist gap produces — no codec validation can intervene.

  Runs `async: true`: each test gets its own isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase`, and every task id is
  per-test unique.
  """
  use EvoGit.TaskRegistryCase, async: true
  import Ecto.Query
  alias EvoGit.Store
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskRegistry.Lease

  # A status text that is deliberately NOT in `Store.Codec.known_statuses/0`.
  @raw_status "paused"

  describe "Lease classification of an unrecognized persisted status" do
    test "lease_renewable?/1 renews it and leaked?/3 never leaks it" do
      assert Lease.lease_renewable?({:unknown, @raw_status})
      refute Lease.leaked?({:unknown, @raw_status}, false, nil)
      refute Lease.leaked?({:unknown, @raw_status}, false, System.system_time(:second) - 600)
      # The known statuses keep their meaning.
      assert Lease.lease_renewable?(:running)
      assert Lease.leaked?(:running, false, nil)
      refute Lease.leaked?(:running, true, nil)
    end
  end

  describe "heartbeat" do
    test "renews the lease of an OWNED task whose persisted status is unrecognized" do
      unique = System.unique_integer([:positive])
      task_id = "unknown_heartbeat_#{unique}"
      expired = System.system_time(:second) - 300

      put_task!(task_id, :running, expired)
      write_raw_status!(task_id, @raw_status)
      # Pre-condition: the tri-state read sees an unreadable, PRESENT row.
      assert Store.get_task_status(store(), task_id) == {:unknown, @raw_status}

      own_task!(task_id)
      send(TaskRegistry.server(), :heartbeat)
      # Sync on the registry before reading the store.
      TaskRegistry.list_tasks()

      %{lease_expires_at: renewed} = Store.select_task_update_info(store(), task_id)

      assert renewed > expired,
             "heartbeat must renew an {:unknown, _} row's lease, got #{inspect(renewed)}"

      # Renewal never rewrites the status.
      assert Store.get_task_status(store(), task_id) == {:unknown, @raw_status}
    end
  end

  describe "lease sweep" do
    test "never marks an unrecognized-status row :failed, even with an expired lease" do
      unique = System.unique_integer([:positive])
      task_id = "unknown_sweep_#{unique}"
      expired = System.system_time(:second) - 300

      put_task!(task_id, :running, expired)
      write_raw_status!(task_id, @raw_status)
      assert Store.get_task_status(store(), task_id) == {:unknown, @raw_status}

      send(TaskRegistry.server(), :lease_sweep)
      TaskRegistry.list_tasks()

      # Status, lease, result and error are all untouched — the sweep skipped it
      # (an unreadable status is never "leaked").
      assert Store.get_task_status(store(), task_id) == {:unknown, @raw_status}
      task = Store.get_task(store(), task_id)
      assert task != nil, "the sweep must not delete the row"
      assert %{lease_expires_at: ^expired} = Store.select_task_update_info(store(), task_id)
      assert {task.finished_at, task.result, task.error} == {nil, nil, nil}
    end
  end

  describe "cancel / force kill guards" do
    test "cancel_task/1 refuses without marking the unrecognized-status row" do
      unique = System.unique_integer([:positive])
      task_id = "unknown_cancel_#{unique}"

      put_task!(task_id, :running, System.system_time(:second) + 300)
      write_raw_status!(task_id, @raw_status)

      assert TaskRegistry.cancel_task(task_id) == {:error, :not_running}
      assert Store.get_task_status(store(), task_id) == {:unknown, @raw_status}
      assert %{lease_expires_at: lease} = Store.select_task_update_info(store(), task_id)
      assert is_integer(lease), "the lease must be left as-is (nothing was marked)"
    end

    test "force_kill_task/1 refuses without marking the unrecognized-status row" do
      unique = System.unique_integer([:positive])
      task_id = "unknown_force_kill_#{unique}"

      put_task!(task_id, :running, System.system_time(:second) + 300)
      write_raw_status!(task_id, @raw_status)

      assert TaskRegistry.force_kill_task(task_id) == {:error, :not_running}
      assert Store.get_task_status(store(), task_id) == {:unknown, @raw_status}
      task = Store.get_task(store(), task_id)
      assert {task.status, task.finished_at, task.result} == {:pending, nil, nil}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp put_task!(task_id, status, lease_expires_at) do
    EvoGit.Store.put_task(store(), %TaskInfo{
      id: task_id,
      type: :genesis,
      status: status,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil,
      lease_expires_at: lease_expires_at
    })
  end

  # Writes a status text the codec would reject STRAIGHT into the row (the raw
  # wire twin inside `RepoScope`, which bypasses the codec's whitelist).
  defp write_raw_status!(task_id, raw) do
    RepoScope.with_repo(Store.__repo_pid__(store()), fn ->
      EvoGit.Repo.update_all(from(t in TaskRowRaw, where: t.id == ^task_id),
        set: [status: raw]
      )
    end)
  end

  # Registers the task as OWNED by this registry instance (`task_refs`) so the
  # heartbeat renews its lease — the `%Task{}` content is irrelevant to it.
  defp own_task!(task_id) do
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
  end
end
