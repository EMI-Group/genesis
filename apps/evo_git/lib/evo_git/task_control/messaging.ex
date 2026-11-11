defmodule EvoGit.TaskControl.Messaging do
  @moduledoc """
  Adapts public task/agent queries to the existing user-message queue.
  Queue acceptance does not establish delivery or adoption. A task's root
  is the default recipient; optional targets must belong to the same task.
  """
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.TaskRegistry
  @runnable [:running, :waiting, :ready, :blocked]

  def send(task_id, message, agent_id \\ nil) do
    with :ok <- active_task(task_id),
         {:ok, agent} <- recipient(task_id, agent_id) do
      case RemoteAPI.send_agent_message(agent.id, message) do
        :ok ->
          {:ok,
           %{
             task_id: task_id,
             recipient_agent_id: agent.id,
             status: "queued_for_next_turn",
             acknowledged: false
           }}

        {:error, reason} ->
          error("message_not_queued", inspect(reason))
      end
    end
  end

  defp active_task(id) do
    case TaskRegistry.get_task_lite(id) do
      nil -> error("not_found", "Task not found: #{id}")
      %{status: :running} -> :ok
      _ -> error("task_not_active", "Messages require a running task.")
    end
  end

  defp recipient(task_id, nil) do
    case Enum.filter(agents(task_id), &(is_nil(&1.parent_id) and &1.depth == 0)) do
      [root] -> {:ok, root}
      [] -> error("no_runnable_root", "Task has no runnable root agent.")
      _ -> error("ambiguous_root", "Task has more than one runnable root agent.")
    end
  end

  defp recipient(task_id, id) when is_integer(id) and id > 0 do
    case Enum.find(agents(task_id), &(&1.id == id)) do
      nil -> error("invalid_recipient", "Select a runnable agent belonging to this task.")
      agent -> {:ok, agent}
    end
  end

  defp recipient(_, _), do: error("invalid_recipient", "agent_id must be a positive integer.")

  defp agents(task_id),
    do: Enum.filter(RemoteAPI.list_agents(), &(&1.task_id == task_id and &1.status in @runnable))

  defp error(code, message), do: {:error, %{code: code, message: message}}
end
