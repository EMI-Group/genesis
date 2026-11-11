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

    assert {:ok, %{pending_user_messages: [%{text: "Please prioritize the failing test."}]}} =
             Store.get_agent_state(root)

    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(child)
    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(other)

    assert {:ok, _} = Messaging.send(task_id, "Keep the current public API.")

    assert Enum.map(Store.drain_pending_user_messages(root), & &1.text) == [
             "Please prioritize the failing test.",
             "Keep the current public API."
           ]

    assert Store.drain_pending_user_messages(root) == []
  end

  test "a waiting root can receive a message without broadcasting to its children" do
    task_id = put_task(:running)
    root = put_agent(task_id, status: :waiting)

    assert {:ok, %{recipient_agent_id: ^root}} = Messaging.send(task_id, "Revise the plan.")

    assert {:ok, %{pending_user_messages: [%{text: "Revise the plan."}]}} =
             Store.get_agent_state(root)
  end

  test "targets a task's child and records delivery after context injection" do
    task_id = put_task(:running)
    root = put_agent(task_id, status: :waiting)
    child = put_agent(task_id, parent_id: root, depth: 1)
    assert {:ok, receipt} = Messaging.send(task_id, "Fix the fixture", child)
    assert receipt.recipient_agent_id == child
    assert is_binary(receipt.message_id)
    assert EvoGit.TaskProgress.get(task_id)["messages"] |> Enum.any?(&(&1["state"] == "queued"))

    state = %EvoGit.Agent.LoopState{
      agent_id: child,
      agent_module: EvoGit.Agents.Executor,
      depth: 1,
      node_path: ".",
      context: ReqLLM.Context.new([]),
      turn: 1
    }

    _ = EvoGit.Agent.Runner.drain_and_inject_user_messages(state)

    assert EvoGit.TaskProgress.get(task_id)["messages"]
           |> Enum.any?(&(&1["state"] == "delivered"))

    other = put_agent(put_task(:running))
    assert {:error, %{code: "invalid_recipient"}} = Messaging.send(task_id, "cross task", other)
  end

  test "the internal reporting tool updates the shared report for its own task" do
    task_id = put_task(:running)
    root = put_agent(task_id)
    Process.put(:evogit_agent_id, root)

    result =
      EvoGit.Agent.Tools.execute("report_progress", %{"summary" => "Implementing backend"}, nil)

    assert Jason.decode!(result)["status"] == "recorded"
    assert EvoGit.TaskProgress.get(task_id)["summary"] == "Implementing backend"
  end

  test "concurrent context updates cannot overwrite accepted messages" do
    task_id = put_task(:running)
    root = put_agent(task_id)

    updates =
      Task.async(fn ->
        for n <- 1..200, do: Store.batch_update_agent(root, total_tokens: n)
      end)

    for n <- 1..40 do
      assert {:ok, _} = Messaging.send(task_id, "message #{n}")
    end

    Task.await(updates)
    messages = Store.drain_pending_user_messages(root)
    assert Enum.map(messages, & &1.text) == Enum.map(1..40, &"message #{&1}")
  end

  test "missing tasks and inactive task states do not enqueue messages" do
    assert {:error, %{code: "not_found"}} = Messaging.send("missing-task", "hello")

    for status <- [:pending, :cancelling, :finalizing, :completed, :failed, :cancelled] do
      task_id = put_task(status)
      root = put_agent(task_id)

      assert {:error, %{code: "task_not_active"}} = Messaging.send(task_id, "hello")
      assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(root)
    end
  end

  test "active tasks require a runnable root, never a remaining child" do
    task_id = put_task(:running)
    child = put_agent(task_id, parent_id: 123, depth: 1)

    assert {:error, %{code: "no_runnable_root"}} = Messaging.send(task_id, "hello")
    assert {:ok, %{pending_user_messages: []}} = Store.get_agent_state(child)
  end

  test "stale roots, retry entries, cancellation, and finished results are rejected" do
    for overrides <- [
          [state: nil],
          [task_ref: nil, status: :pending],
          [dead: true],
          [cancel_requested: true],
          [result_sent: true],
          [status: :pending]
        ] do
      task_id = put_task(:running)
      root = put_agent(task_id, overrides)

      assert {:error, %{code: "no_runnable_root"}} = Messaging.send(task_id, "hello")

      case Store.get_agent_state(root) do
        {:ok, state} -> assert state.pending_user_messages == []
        :error -> :ok
      end
    end
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
