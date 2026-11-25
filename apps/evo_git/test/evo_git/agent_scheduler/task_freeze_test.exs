defmodule EvoGit.AgentScheduler.TaskFreezeTest do
  @moduledoc """
  The PURE task-freeze state machine (`EvoGit.AgentScheduler.TaskFreeze`).

  No scheduler, no ETS, no timers: every case here drives the record directly, so
  the whole task-pause accounting (who still owes a report, when the pause is
  complete, how the kind degrades to `:dirty`) is pinned without a GenServer.
  `async: true` — nothing global is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.TaskFreeze

  @task_id "task-freeze-pure"

  defp clean_report do
    %{
      agent_id: 1,
      task_id: @task_id,
      checkpoint: "c-sha",
      branch: "b",
      durable: true,
      clean_freeze: true,
      reason: :task_pause
    }
  end

  defp freeze(ids, opts \\ []), do: TaskFreeze.begin(@task_id, ids, List.first(ids), opts)

  describe "begin/4 + accessors" do
    test "opens a CLEAN freeze over the roster with every agent pending" do
      freeze = freeze([1, 2, 3])

      assert freeze.task_id == @task_id
      assert TaskFreeze.root_id(freeze) == 1
      assert TaskFreeze.pending(freeze) == [1, 2, 3]
      assert TaskFreeze.agents(freeze) == [1, 2, 3]
      assert TaskFreeze.kind(freeze) == :clean
      refute freeze.forced
      assert is_integer(freeze.started_at)

      assert TaskFreeze.root_info(freeze) == %{}
      refute TaskFreeze.complete?(freeze)
      assert TaskFreeze.complete?(:not_a_freeze) == false
      assert TaskFreeze.root_info(:not_a_freeze) == %{}
    end

    test "ignores ids that are not integers and tolerates an empty roster" do
      assert TaskFreeze.begin(@task_id, [1, nil, "2", :three], 1) |> TaskFreeze.pending() == [1]
      assert TaskFreeze.begin(@task_id, nil, nil) |> TaskFreeze.pending() == []
      assert TaskFreeze.begin(@task_id, nil, nil) |> TaskFreeze.root_id() == nil
    end

    test "the :now option pins started_at; the :kind option seeds the kind" do
      freeze = TaskFreeze.begin(@task_id, [1], 1, now: 42, kind: :dirty)

      assert freeze.started_at == 42
      assert TaskFreeze.kind(freeze) == :dirty
    end
  end

  describe "report/3" do
    test "the freeze completes only when EVERY agent reported" do
      freeze = freeze([1, 2])

      assert {:pending, freeze} = TaskFreeze.report(freeze, 1, clean_report())
      assert TaskFreeze.pending(freeze) == [2]
      refute TaskFreeze.complete?(freeze)
      assert TaskFreeze.root_info(freeze) == clean_report()

      assert {:complete, freeze} = TaskFreeze.report(freeze, 2, clean_report())
      assert TaskFreeze.pending(freeze) == []
      assert TaskFreeze.complete?(freeze)
      # Staying clean required EVERY report to be clean.
      assert TaskFreeze.kind(freeze) == :clean
      assert TaskFreeze.agents(freeze) == [1, 2]
    end

    test "a clean_freeze: false report makes the task pause dirty" do
      freeze = freeze([1, 2])
      {:pending, freeze} = TaskFreeze.report(freeze, 1, clean_report())

      {:complete, freeze} =
        TaskFreeze.report(freeze, 2, %{clean_report() | clean_freeze: false})

      assert TaskFreeze.kind(freeze) == :dirty
    end

    test "a durable: false report makes the task pause dirty" do
      freeze = freeze([1])
      {:complete, freeze} = TaskFreeze.report(freeze, 1, %{clean_report() | durable: false})

      assert TaskFreeze.kind(freeze) == :dirty
    end

    test "a report that omits clean_freeze is dirty (only a literal true is clean)" do
      freeze = freeze([1])
      {:complete, freeze} = TaskFreeze.report(freeze, 1, %{durable: true})

      assert TaskFreeze.kind(freeze) == :dirty
    end

    test "string-keyed info (the JSON shape) is read like the atom-keyed one" do
      freeze = freeze([1])

      {:complete, freeze} =
        TaskFreeze.report(freeze, 1, %{
          "clean_freeze" => true,
          "durable" => true,
          "checkpoint" => "c"
        })

      assert TaskFreeze.kind(freeze) == :clean
      assert TaskFreeze.root_info(freeze)["checkpoint"] == "c"
    end

    test "a late report from an already-completed agent is harmless" do
      freeze = freeze([1])
      {:complete, freeze} = TaskFreeze.report(freeze, 1, clean_report())

      # An agent the freeze no longer waits for: the outcome is stored, nothing
      # is re-opened and the freeze stays complete/clean.
      assert {:complete, freeze} = TaskFreeze.report(freeze, 7, clean_report())
      assert TaskFreeze.pending(freeze) == []
      assert TaskFreeze.kind(freeze) == :clean
      assert TaskFreeze.agents(freeze) == [1, 7]

      # A garbage info payload never raises either.
      assert {:complete, freeze} = TaskFreeze.report(freeze, 8, :nope)
      assert TaskFreeze.root_info(freeze) == clean_report()
    end

    test "a dirty report is sticky: a later clean one cannot clean it up" do
      freeze = freeze([1, 2])
      {:pending, freeze} = TaskFreeze.report(freeze, 1, %{clean_report() | durable: false})
      {:complete, freeze} = TaskFreeze.report(freeze, 2, clean_report())

      assert TaskFreeze.kind(freeze) == :dirty
    end
  end

  describe "add_agent/2" do
    test "admits an agent that joined the task AFTER the freeze opened" do
      freeze = freeze([1])
      freeze = TaskFreeze.add_agent(freeze, 2)

      assert TaskFreeze.pending(freeze) == [1, 2]

      {:pending, freeze} = TaskFreeze.report(freeze, 1, clean_report())
      assert {:complete, completed} = TaskFreeze.report(freeze, 2, clean_report())
      assert TaskFreeze.kind(completed) == :clean
    end

    test "is idempotent and never re-adds an agent that already reported" do
      freeze = freeze([1, 2])
      freeze = TaskFreeze.add_agent(freeze, 1)
      assert TaskFreeze.pending(freeze) == [1, 2]

      {:pending, freeze} = TaskFreeze.report(freeze, 1, clean_report())
      freeze = TaskFreeze.add_agent(freeze, 1)

      assert TaskFreeze.pending(freeze) == [2]
      assert freeze.reported |> Map.keys() == [1]

      # Non-integer ids are ignored.
      assert TaskFreeze.add_agent(freeze, nil) |> TaskFreeze.pending() == [2]
    end
  end

  describe "timeout/1 + complete_forced/1" do
    test "the timeout lists exactly the still-pending victims and forces dirty" do
      freeze = freeze([1, 2, 3])
      {:pending, freeze} = TaskFreeze.report(freeze, 2, clean_report())

      {freeze, victims} = TaskFreeze.timeout(freeze)

      assert victims == [1, 3]
      assert freeze.forced
      assert TaskFreeze.kind(freeze) == :dirty
      assert TaskFreeze.pending(freeze) == []
      assert TaskFreeze.complete?(freeze)
      # The one agent that DID report keeps its payload.
      assert TaskFreeze.agents(freeze) == [1, 2, 3]
    end

    test "a timeout with nothing pending still marks the pause forced and dirty" do
      freeze = freeze([1])
      {:complete, freeze} = TaskFreeze.report(freeze, 1, clean_report())

      {freeze, victims} = TaskFreeze.timeout(freeze)

      assert victims == []
      assert freeze.forced
      assert TaskFreeze.kind(freeze) == :dirty
    end

    test "complete_forced/1 completes whatever is left as dirty" do
      freeze = freeze([1, 2])
      {:pending, freeze} = TaskFreeze.report(freeze, 1, clean_report())

      freeze = TaskFreeze.complete_forced(freeze)

      assert freeze.forced
      assert TaskFreeze.kind(freeze) == :dirty
      assert TaskFreeze.pending(freeze) == []
      assert TaskFreeze.root_info(freeze) == clean_report()
    end
  end
end
