defmodule EvoGit.TaskControl.Messaging do
  @moduledoc """
  Queues a task-level message for its live root agent.

  The scheduler appends the message to the root's pending user-message queue;
  the runner drains that queue at the beginning of a subsequent turn. Queue
  acceptance is not acknowledgement or proof of consumption: the agent may
  finish before another turn. Subagents do not receive a broadcast.

  Root liveness is checked before enqueueing. Scheduler lifecycle changes may
  race this check, so a successful response describes queue acceptance only.
  """

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{AgentState, RemoteAPI, SchedMeta, Store}
  alias EvoGit.TaskRegistry

  @runnable_statuses [:running, :waiting, :ready, :blocked]

  @spec send(String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def send(task_id, message, agent_id \\ nil) do
    with :ok <- active_task(task_id),
         {:ok, root} <- recipient(task_id, agent_id) do
      message_id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      :ok = EvoGit.TaskProgress.record_message(task_id, message_id, root.id, "queued")
      payload = %{text: message, attachments: nil, progress_message_id: message_id}

      case AgentScheduler.send_user_message(root.id, payload) do
        :ok ->
          {:ok,
           %{
             task_id: task_id,
             message_id: message_id,
             delivery_state: "queued",
             recipient_agent_id: root.id,
             status: "queued_for_next_turn",
             acknowledged: false,
             message: "Queued for the root agent's next turn; the agent has not acknowledged it."
           }}

        {:error, :not_found} ->
          EvoGit.TaskProgress.record_message(task_id, message_id, root.id, "not_delivered")
          no_root()
      end
    end
  end

  defp recipient(task_id, nil), do: runnable_root(task_id)

  defp recipient(task_id, id) when is_integer(id) and id > 0 do
    case Store.get_sched_meta(id) do
      {:ok,
       %SchedMeta{
         task_id: ^task_id,
         status: status,
         task_ref: %Task{pid: pid},
         result_sent: false
       }}
      when status in @runnable_statuses ->
        if Process.alive?(pid),
          do: {:ok, %{id: id}},
          else: error("invalid_recipient", "Agent is no longer active.")

      _ ->
        error("invalid_recipient", "Select a live agent belonging to this task.")
    end
  end

  defp recipient(_, _), do: error("invalid_recipient", "agent_id must be a positive integer.")

  defp active_task(task_id) do
    case TaskRegistry.get_task_lite(task_id) do
      nil -> error("not_found", "Task not found: #{task_id}")
      %{status: :running} -> :ok
      _ -> error("task_not_active", "Messages require a running task.")
    end
  end

  defp runnable_root(task_id) do
    roots =
      RemoteAPI.list_agents()
      |> Enum.filter(fn agent ->
        agent.task_id == task_id and is_nil(agent.parent_id) and agent.depth == 0 and
          agent.status in @runnable_statuses and live_root?(agent.id, task_id)
      end)

    case roots do
      [root] -> {:ok, root}
      [] -> no_root()
      _ -> error("ambiguous_root", "Task has more than one runnable root agent.")
    end
  end

  defp live_root?(agent_id, task_id) do
    with {:ok,
          %SchedMeta{
            task_id: ^task_id,
            parent_id: nil,
            depth: 0,
            result_sent: false,
            status: status,
            task_ref: %Task{pid: pid}
          }} <- Store.get_sched_meta(agent_id),
         true <- status in @runnable_statuses and is_pid(pid) and Process.alive?(pid),
         %AgentState{cancel_requested: cancelled} <- RemoteAPI.get_agent_state(agent_id) do
      cancelled != true
    else
      _ -> false
    end
  end

  defp no_root, do: error("no_runnable_root", "Task has no runnable root agent.")
  defp error(code, message), do: {:error, %{code: code, message: message}}
end
