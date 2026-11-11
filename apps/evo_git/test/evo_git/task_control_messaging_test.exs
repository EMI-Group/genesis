defmodule EvoGit.TaskControl.MessagingTest do
  # `async: false`: drives the app-global `EvoGit.AgentScheduler` (the
  # `:send_user_message` GenServer call) and writes the app-owned
  # `:evogit_sched_meta` / `:evogit_agent_summary` ETS tables.
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.AgentScheduler.{AgentState, ControlPlane, SchedMeta, Store}
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

    assert ControlPlane.pending_messages(root) == ["Please prioritize the failing test."]
    assert ControlPlane.pending_messages(child) == []
    assert ControlPlane.pending_messages(other) == []

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

    assert ControlPlane.pending_messages(root) == ["Revise the plan."]
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
    assert ControlPlane.pending_messages(root_a) == []
    assert ControlPlane.pending_messages(root_b) == []
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
    session_pid = spawn(fn -> receive do: (:stop -> :ok) end)

    if overrides[:dead] do
      ref = Process.monitor(session_pid)
      Kernel.send(session_pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^session_pid, :normal}
    end

    context = %ContextNode{path: "./", repo: "/tmp/task-messaging"}

    spec = %AgentSpec{
      context_node: context,
      phylo_node: nil,
      agent_module: __MODULE__,
      objective: "test task messaging"
    }

    # The agent is ONE `EvoGit.Agent.Session`; the scheduler metadata records it
    # as `session_pid` (it replaced the old `%Task{}` wrapper ref).
    meta = %SchedMeta{
      id: id,
      depth: Keyword.get(overrides, :depth, 0),
      parent_id: overrides[:parent_id],
      task_id: task_id,
      status: Keyword.get(overrides, :status, :running),
      session_pid: session_pid,
      result_sent: Keyword.get(overrides, :result_sent, false),
      spec: spec
    }

    :ets.insert(:evogit_sched_meta, {id, meta})

    unless Keyword.has_key?(overrides, :state) do
      # The summary row is what makes the agent LIVE for the control plane:
      # `ControlPlane.append_message/2` refuses to queue for an agent without
      # one, and the injected-message queue itself lives in `ControlPlane`.
      state = %AgentState{
        context_node: context,
        llm_model: "test:model",
        max_retries: 1,
        max_depth: 1
      }

      :ets.insert(:evogit_agent_summary, {id, state})
    end

    on_exit(fn ->
      Kernel.send(session_pid, :stop)
      :ets.delete(:evogit_agent_summary, id)
      :ets.delete(:evogit_sched_meta, id)
    end)

    id
  end
end
