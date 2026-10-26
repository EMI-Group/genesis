defmodule EvoGit.TaskRegistry.CleanupTest do
  @moduledoc """
  Runs `async: true`: each test gets its own isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase`, touches no BEAM-global
  state (no app-env key, no shared `:evogit_*` ETS table, no global scheduler
  config), and every task id is per-test unique.
  """

  use EvoGit.TaskRegistryCase, async: true

  describe "task_history_config/0 defaults" do
    test "returns default max_tasks and max_age_days when no config set" do
      # `Cleanup.task_history_config/0` merges `%{max_tasks: 100, max_age_days: 14}`
      # with `EvoGit.Config.resolve()[:task_history]`, so a developer's real
      # `~/.config/genesis/config.toml` may override the values — assert only the
      # guaranteed shape (both keys present, positive integers), never 100/14.
      config = EvoGit.TaskRegistry.Cleanup.task_history_config()

      assert is_map(config)
      assert Map.has_key?(config, :max_tasks)
      assert Map.has_key?(config, :max_age_days)
      assert is_integer(config.max_tasks) and config.max_tasks > 0
      assert is_integer(config.max_age_days) and config.max_age_days > 0
    end
  end

  describe "cleanup_expired_tasks/0" do
    test "removes only old FINISHED tasks — recent and non-terminal rows survive" do
      unique = System.unique_integer([:positive])
      now = DateTime.utc_now()

      # Ages read from the LIVE config, so the fixtures are correct whatever
      # `max_age_days` a developer's real config.toml carries.
      over_limit = old_age_days()
      within_limit = within_age_days()

      days_ago = fn days -> DateTime.add(now, -days * 24 * 60 * 60, :second) end

      # ONE seeded fixture spanning every case: over-age finished (cleaned), a
      # finished row inside the age window, three "today" rows, and an over-age
      # :running / :pending pair (never cleaned). The count limit is NOT
      # exercised here — `max_tasks` defaults to 100, so seeding past it is not
      # worth the wall clock; both limits are OR'ed in SQL by
      # `Store.select_cleanup_info/3`.
      over_age = %TaskInfo{
        id: "test_over_age_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: days_ago.(over_limit),
        finished_at: days_ago.(over_limit),
        logs: [],
        result: nil
      }

      within_window = %TaskInfo{
        id: "test_within_window_#{unique}",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: days_ago.(within_limit),
        finished_at: days_ago.(within_limit),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), over_age)
      EvoGit.Store.put_task(store(), within_window)

      for i <- 1..3 do
        :ok =
          EvoGit.Store.put_task(store(), %TaskInfo{
            id: "test_recent_#{unique}_#{i}",
            type: :genesis,
            status: :completed,
            opts: [path: "/tmp/test"],
            ref: nil,
            started_at: days_ago.(0),
            finished_at: DateTime.add(now, -i * 60, :second),
            logs: [],
            result: nil
          })
      end

      old_running = %TaskInfo{
        id: "test_old_running_#{unique}",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: days_ago.(over_limit),
        finished_at: nil,
        logs: [],
        result: nil
      }

      old_pending = %TaskInfo{
        id: "test_old_pending_#{unique}",
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: days_ago.(over_limit),
        finished_at: nil,
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(store(), old_running)
      EvoGit.Store.put_task(store(), old_pending)

      # Everything is really there before the cleanup runs.
      before_ids = TaskRegistry.list_tasks() |> Enum.map(& &1.id)
      assert "test_over_age_#{unique}" in before_ids
      assert "test_within_window_#{unique}" in before_ids

      trigger_cleanup!()

      task_ids = TaskRegistry.list_tasks() |> Enum.map(& &1.id)

      # Over-age FINISHED row removed.
      refute "test_over_age_#{unique}" in task_ids

      # Finished rows inside the age window are preserved.
      assert "test_within_window_#{unique}" in task_ids
      assert "test_recent_#{unique}_1" in task_ids
      assert "test_recent_#{unique}_2" in task_ids
      assert "test_recent_#{unique}_3" in task_ids

      # Non-terminal rows are never cleaned, however old.
      assert "test_old_running_#{unique}" in task_ids
      assert "test_old_pending_#{unique}" in task_ids
    end
  end
end
