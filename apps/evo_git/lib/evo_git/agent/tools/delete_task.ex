defmodule EvoGit.Agent.Tools.DeleteTask do
  @moduledoc """
  Command handler for the `DeleteTask.delete_task` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Deletes a task by id.

  Delegates to `EvoGit.TaskRegistry.delete_task/1` — removes the task row
  (and its persisted history) from the task store. The deletion is a
  fire-and-forget cast; the task disappears from the dashboard and its
  reviewable branch/result history is gone.
  """

  alias EvoGit.Agent.Tools.Boundary
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the delete_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        # Cross-GenServer boundary: see `EvoGit.Agent.Tools.Boundary`.
        case Boundary.run(
               fn -> EvoGit.TaskRegistry.delete_task(task_id) end,
               fn reason -> {:registry_unavailable, reason} end
             ) do
          :ok -> "Task #{task_id} deleted."
          {:error, reason} -> "Error deleting task #{task_id}: #{describe_error(reason)}"
        end

      {:error, message} ->
        message
    end
  end

  # The only error shape reachable here is the boundary guard's
  # {:registry_unavailable, _} (delete_task/1 is a cast and always returns
  # :ok), so the :not_running literal is never reached — any value is inert.
  defp describe_error(reason) do
    Shared.describe_error(reason, "task is not in a deletable state")
  end
end
