defmodule EvoGit.ApplicationTest do
  @moduledoc """
  Regression tests for ETS table ownership.

  The three global ETS tables (`:evogit_agent_state`, `:evogit_sched_meta`,
  `:evogit_archive_records`) must be created by `EvoGit.Application.start/2`
  (owned by the application process) — NOT by `AgentScheduler.init/1`. This
  ensures they survive an `AgentScheduler` crash/restart.

  Previously the tables were created in `AgentScheduler.init/1`, which meant a
  scheduler crash destroyed them. On restart they were recreated empty, causing
  the dashboard's `TaskRegistry` to see no sched_meta entries and spuriously
  mark tasks as `:failed`.

  Uses `async: false` because the tests manipulate the global named ETS tables
  and the global `EvoGit.Supervisor` supervision tree.
  """

  use ExUnit.Case, async: false

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta
  @archive_table :evogit_archive_records
  @tables [@agent_table, @sched_table, @archive_table]
  # A key unlikely to collide with real agent IDs (positive integers).
  @sentinel_key 9_999_999

  # Table type per create spec (mirrors EvoGit.Application.ensure_ets_table/2).
  @table_specs %{
    @agent_table => [:named_table, :public, :set, read_concurrency: true],
    @sched_table => [:named_table, :public, :set, read_concurrency: true],
    @archive_table => [:named_table, :public, :duplicate_bag, read_concurrency: true]
  }

  setup do
    # The :evo_git app and its supervision tree (EvoGit.Supervisor) are started
    # automatically by Mix before the test suite runs, so the scheduler and ETS
    # tables already exist. However, other async tests (e.g. CompleteTaskTest)
    # may delete a table in their on_exit cleanup, leaving it undefined by the
    # time this serial test runs. Recreate any missing table so we can reliably
    # exercise the crash/restart survival behaviour below.
    ensure_tables()

    on_exit(fn ->
      if :ets.whereis(@sched_table) != :undefined do
        :ets.delete(@sched_table, @sentinel_key)
      end
    end)

    :ok
  end

  describe "ETS table creation" do
    test "all three tables exist after Application.start/2" do
      for table <- @tables do
        assert :ets.whereis(table) != :undefined,
               "ETS table #{inspect(table)} should be created by EvoGit.Application.start/2"
      end
    end
  end

  describe "ETS table survival across AgentScheduler crash/restart" do
    test "tables and their contents survive a scheduler terminate/restart" do
      # 1. All three tables must exist before the crash.
      for table <- @tables do
        assert :ets.whereis(table) != :undefined
      end

      # 2. Insert a sentinel value into sched_meta.
      :ets.insert(@sched_table, {@sentinel_key, %{sentinel: true}})

      # 3. Record the current scheduler pid so we can prove a restart occurred.
      old_pid = GenServer.whereis(EvoGit.AgentScheduler)
      assert is_pid(old_pid), "AgentScheduler should be running under the supervisor"

      # 4. Terminate the scheduler child via its group supervisor.
      #    (AgentScheduler is a child of the one_for_all AgentGroupSupervisor)
      assert :ok = Supervisor.terminate_child(EvoGit.AgentGroupSupervisor, EvoGit.AgentScheduler)

      # While terminated, the scheduler process must be gone.
      assert GenServer.whereis(EvoGit.AgentScheduler) == nil

      # 5. Restart the scheduler child.
      assert {:ok, new_pid} = Supervisor.restart_child(EvoGit.AgentGroupSupervisor, EvoGit.AgentScheduler)
      assert is_pid(new_pid)
      assert new_pid != old_pid, "scheduler should be a new process after restart"

      # 6. All three tables must STILL exist after the restart.
      for table <- @tables do
        assert :ets.whereis(table) != :undefined,
               "ETS table #{inspect(table)} should survive a scheduler restart"
      end

      # 7. The sentinel must STILL be present — proving the table was NOT
      #    destroyed and recreated empty by the scheduler restart.
      assert :ets.lookup(@sched_table, @sentinel_key) ==
               [{@sentinel_key, %{sentinel: true}}],
             "sentinel entry should survive scheduler restart (table not recreated empty)"
    end
  end

  # --- Helpers ---

  defp ensure_tables do
    for {table, opts} <- @table_specs do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, opts)
      end
    end
  end
end
