defmodule EvoGit.TaskProgressTest do
  use ExUnit.Case, async: false
  alias EvoGit.{Store, TaskInfo, TaskProgress}

  test "the progress tool can be constructed and exposed with the locked LLM dependency" do
    tool = EvoGit.Agent.Tools.ReportProgress.schema()
    assert tool.name == "report_progress"
    assert {:ok, _} = Jason.encode(tool.parameter_schema)
    assert tool.parameter_schema["properties"]["summary"]["type"] == "string"
  end

  setup do
    id = "progress-#{System.unique_integer([:positive])}"
    :ok = Store.put_task(%TaskInfo{id: id, status: :running, type: :evolve, opts: []})
    on_exit(fn -> Store.delete_task(id) end)
    %{id: id}
  end

  test "an agent without a registry task cannot write task progress" do
    agent_id = System.unique_integer([:positive])

    :ets.insert(
      :evogit_sched_meta,
      {agent_id,
       %EvoGit.AgentScheduler.SchedMeta{
         id: agent_id,
         depth: 0,
         spec: nil,
         task_id: nil
       }}
    )

    on_exit(fn -> :ets.delete(:evogit_sched_meta, agent_id) end)

    writer = EvoGit.Store.__writer__()

    assert {:error, :no_task} =
             TaskProgress.note_agent(agent_id, %{summary: "Standalone run complete"})

    assert Process.alive?(writer)
  end

  test "root plan and child outcomes form a durable report while root waits", %{id: id} do
    assert {:ok, root} =
             TaskProgress.publish(
               id,
               1,
               %{
                 summary: "Implement assistant",
                 current_work: ["Backend"],
                 remaining: ["UI"],
                 next_steps: ["Test"]
               },
               parent_id: nil,
               sequence: 1
             )

    assert {:ok, child} =
             TaskProgress.publish(
               id,
               2,
               %{
                 summary: "Backend ready",
                 completed: ["Shared tool catalog"],
                 blockers: ["Need fixture"]
               },
               parent_id: 1,
               sequence: 1
             )

    assert child["revision"] > root["revision"]
    assert child["summary"] == "Implement assistant"
    assert "Shared tool catalog" in child["completed"]
    assert "Need fixture" in child["blockers"]
    assert TaskProgress.get(id) == child
  end

  test "repeated and older reports cannot replace newer progress", %{id: id} do
    {:ok, first} = TaskProgress.publish(id, 1, %{summary: "Tests complete"}, sequence: 3)
    assert {:ok, ^first} = TaskProgress.publish(id, 1, %{summary: "Tests complete"}, sequence: 3)
    assert {:ok, ^first} = TaskProgress.publish(id, 1, %{summary: "Starting"}, sequence: 2)
  end

  test "the root can resolve earlier child blockers without losing outcomes", %{id: id} do
    {:ok, _} =
      TaskProgress.publish(id, 1, %{summary: "Implementing", blockers: [], remaining: ["Verify"]})

    {:ok, child} =
      TaskProgress.publish(
        id,
        2,
        %{completed: ["Backend"], blockers: ["Fixture missing"], remaining: ["Fixture"]},
        parent_id: 1
      )

    assert "Fixture missing" in child["blockers"]
    {:ok, still_blocked} = TaskProgress.publish(id, 1, %{summary: "Integrating"})
    assert "Fixture missing" in still_blocked["blockers"]
    {:ok, resolved} = TaskProgress.publish(id, 1, %{blockers: [], remaining: ["Verify"]})
    assert resolved["blockers"] == []
    assert resolved["remaining"] == ["Verify"]
    assert "Backend" in resolved["completed"]
    {:ok, new_blocker} = TaskProgress.publish(id, 2, %{blockers: ["New failure"]}, parent_id: 1)
    assert "New failure" in new_blocker["blockers"]
    refute "Fixture" in new_blocker["remaining"]
  end

  test "a root summary alone does not acknowledge a field it never reported", %{id: id} do
    {:ok, _} = TaskProgress.publish(id, 1, %{summary: "Plan"})
    {:ok, _} = TaskProgress.publish(id, 2, %{blockers: ["Need input"]}, parent_id: 1)
    {:ok, report} = TaskProgress.publish(id, 1, %{summary: "Working"})
    assert report["blockers"] == ["Need input"]
  end

  test "an unchanged newer report still fences out stale work", %{id: id} do
    {:ok, first} = TaskProgress.publish(id, 1, %{summary: "Ready"}, sequence: 3)
    {:ok, ^first} = TaskProgress.publish(id, 1, %{summary: "Ready"}, sequence: 5)
    assert {:ok, ^first} = TaskProgress.publish(id, 1, %{summary: "Old plan"}, sequence: 4)
  end

  test "MCP reads the same report as task details without repeating the full objective", %{id: id} do
    objective = String.duplicate("requirement ", 1000)
    :ok = Store.update_task_columns(id, opts: [objective: objective])
    {:ok, first} = EvoGit.TaskControl.get(%{"task_id" => id})
    refute Map.has_key?(first, :objective)
    {:ok, report} = TaskProgress.publish(id, 1, %{summary: "Backend ready"}, sequence: 1)

    {:ok, current} =
      EvoGit.TaskControl.get(%{"task_id" => id, "since" => first.progress.change_token})

    assert current.changed
    assert current.progress.report == report
    assert Store.get_task_lite(id).progress == report
    {:ok, detail} = EvoGit.TaskControl.get(%{"task_id" => id, "include_objective" => true})
    assert detail.objective == objective
  end

  test "terminal tasks retain their progress and reject late reports", %{id: id} do
    {:ok, first} =
      TaskProgress.publish(id, 1, %{summary: "Partial result", remaining: ["UI"]}, sequence: 1)

    :ok = Store.update_task_columns(id, status: :cancelled)

    assert {:error, :task_not_active} =
             TaskProgress.publish(id, 1, %{summary: "Still running"}, sequence: 2)

    assert TaskProgress.get(id) == first
  end

  test "rejects arbitrary report fields and oversized messages", %{id: id} do
    assert {:error, :invalid_progress} = TaskProgress.publish(id, 1, %{credentials: "secret"})

    assert {:error, :invalid_progress} =
             TaskProgress.publish(id, 1, %{summary: String.duplicate("x", 2401)})
  end

  test "progress reports preserve message receipts", %{id: id} do
    :ok = TaskProgress.record_message(id, "receipt", 1, "delivered")
    assert {:ok, report} = TaskProgress.publish(id, 1, %{summary: "Work continues"})
    assert [%{"id" => "receipt", "state" => "delivered"}] = report["messages"]
  end

  test "bounded reports keep the current root and disclose omitted history", %{id: id} do
    {:ok, _} = TaskProgress.publish(id, 1, %{summary: "Overall plan"})

    for agent <- 2..40 do
      assert {:ok, _} =
               TaskProgress.publish(id, agent, %{completed: ["Step #{agent}"]}, parent_id: 1)
    end

    {:ok, report} = TaskProgress.publish(id, 41, %{summary: "Verification phase"})
    assert report["summary"] == "Verification phase"
    assert "Step 40" in report["completed"]
    assert report["truncated"]
    assert report["omitted_agent_reports"] > 0
  end

  @tag :tmp_dir
  test "progress survives a store restart", %{tmp_dir: root} do
    name = :"progress_restart_#{System.unique_integer([:positive])}"
    options = [data_dir: Path.join(root, "tasks.sqlite"), name: name]
    {:ok, first} = Store.start_link(options)

    :ok =
      Store.put_task(name, %TaskInfo{id: "durable", status: :running, type: :evolve, opts: []})

    {:ok, report} =
      TaskProgress.publish("durable", 1, %{summary: "Saved", completed: ["Backend"]}, store: name)

    :ok = GenServer.stop(first)
    {:ok, second} = Store.start_link(options)

    try do
      assert TaskProgress.get("durable", name) == report
      assert Store.get_task_lite(name, "durable").progress == report
    after
      GenServer.stop(second)
    end
  end
end
