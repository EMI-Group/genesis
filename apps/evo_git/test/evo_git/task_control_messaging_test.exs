defmodule EvoGit.TaskControl.MessagingTest do
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.AgentScheduler.{AgentState, SchedMeta, Store}
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.TaskControl.Messaging

  setup do
    assert Process.whereis(EvoGit.AgentScheduler)
    :ok
  end

  test "queues only to the task root and reports no acknowledgement" do
    task_id = put_task(:running)
    root = put_agent(task_id)
    child = put_agent(task_id, parent_id: root, depth: 1)
    other = put_agent(put_task(:running))

    assert {:ok,
            %{
              task_id: ^task_id,
              recipient_agent_id: ^root,
              status: "queued_for_next_turn",
              acknowledged: false
            }} = Messaging.send(task_id, "Please prioritize the failing test.")

    assert {:ok, %{pending_user_messages: ["Please prioritize the failing test."]}} =
             Store.get_agent_state(root)

    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(child)
    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(other)

    assert {:ok, _} = Messaging.send(task_id, "Keep the current public API.")

    assert Store.drain_pending_user_messages(root) == [
             "Please prioritize the failing test.",
             "Keep the current public API."
           ]

    assert Store.drain_pending_user_messages(root) == []
  end

  test "a waiting root can receive a message without broadcasting to its children" do
    task_id = put_task(:running)
    root = put_agent(task_id, status: :waiting)

    assert {:ok, %{recipient_agent_id: ^root}} = Messaging.send(task_id, "Revise the plan.")

    assert {:ok, %{pending_user_messages: ["Revise the plan."]}} =
             Store.get_agent_state(root)
  end

  test "targets a task's child through the existing queue and rejects cross-task recipients" do
    task_id = put_task(:running)
    root = put_agent(task_id, status: :waiting)
    child = put_agent(task_id, parent_id: root, depth: 1)

    assert {:ok, %{recipient_agent_id: ^child, acknowledged: false}} =
             Messaging.send(task_id, "Fix the fixture", child)

    assert Store.drain_pending_user_messages(child) == ["Fix the fixture"]
    assert Store.drain_pending_user_messages(root) == []
    other = put_agent(put_task(:running))
    assert {:error, %{code: "invalid_recipient"}} = Messaging.send(task_id, "cross task", other)
  end

  test "rejects finished or missing tasks without queueing a message" do
    assert {:error, %{code: "not_found"}} = Messaging.send("missing-task", "hello")
    assert {:error, %{code: "task_not_active"}} = Messaging.send(put_task(:completed), "hello")
  end

  test "multiple live roots are rejected rather than choosing an arbitrary recipient" do
    task_id = put_task(:running)
    root_a = put_agent(task_id)
    root_b = put_agent(task_id)

    assert {:error, %{code: "ambiguous_root"}} = Messaging.send(task_id, "hello")
    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(root_a)
    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(root_b)
  end

  defp put_task(status) do
    id = "task-message-#{System.unique_integer([:positive])}"

    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :code,
        status: status,
        opts: [],
        started_at: DateTime.utc_now()
      })

    id
  end

  defp put_agent(task_id, overrides \\ []) do
    id = System.unique_integer([:positive]) + 10_000_000
    pid = spawn(fn -> receive do: (:stop -> :ok) end)

    if overrides[:dead] do
      ref = Process.monitor(pid)
      Kernel.send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    context = %ContextNode{path: "./", repo: "/tmp/task-messaging"}

    spec = %AgentSpec{
      context_node: context,
      phylo_node: nil,
      agent_module: __MODULE__,
      objective: "test task messaging"
    }

    meta = %SchedMeta{
      id: id,
      depth: Keyword.get(overrides, :depth, 0),
      parent_id: overrides[:parent_id],
      task_id: task_id,
      status: Keyword.get(overrides, :status, :running),
      task_ref:
        Keyword.get(overrides, :task_ref, %Task{
          pid: pid,
          owner: self(),
          ref: make_ref(),
          mfa: {__MODULE__, :put_agent, 2}
        }),
      result_sent: Keyword.get(overrides, :result_sent, false),
      spec: spec
    }

    :ets.insert(:evogit_sched_meta, {id, meta})

    unless Keyword.has_key?(overrides, :state) do
      state = %AgentState{
        context_node: context,
        llm_model: "test:model",
        max_retries: 1,
        max_depth: 1,
        cancel_requested: overrides[:cancel_requested]
      }

      :ets.insert(:evogit_agent_state, {id, state})
    end

    on_exit(fn ->
      Kernel.send(pid, :stop)
      :ets.delete(:evogit_agent_state, id)
      :ets.delete(:evogit_sched_meta, id)
    end)

    id
  end
end
