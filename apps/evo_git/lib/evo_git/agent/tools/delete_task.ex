defmodule EvoGit.Agent.Tools.DeleteTask do
  @moduledoc """
  Tool for deleting a task by id.

  Delegates to `EvoGit.TaskRegistry.delete_task/1` — removes the task row
  (and its persisted history) from the task store. The deletion is a
  fire-and-forget cast; the task disappears from the dashboard and its
  reviewable branch/result history is gone.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "delete_task",
      description: """
      Permanently deletes a task by id. Removes the task row and its persisted history
      from the task store — the task disappears from the dashboard and is no longer
      reviewable. Use cancel_task or force_kill_task first to stop a running task before
      deleting it.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "The id of the task to delete"
          }
        },
        "required" => ["task_id"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the delete_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        case safe_delete(task_id) do
          :ok -> "Task #{task_id} deleted."
          {:error, reason} -> "Error deleting task #{task_id}: #{describe_error(reason)}"
        end

      {:error, message} ->
        message
    end
  end

  # Justified try/catch :exit — cross-GenServer boundary (defense-in-depth).
  # `delete_task/1` is a GenServer.cast (fire-and-forget, never raises even if
  # the registry is down), but the guard keeps this tool total if the API ever
  # changes to a call or the registry is unavailable — an exit here would
  # otherwise crash the agent.
  defp safe_delete(task_id) do
    try do
      EvoGit.TaskRegistry.delete_task(task_id)
    catch
      :exit, reason -> {:error, {:registry_unavailable, reason}}
    end
  end

  # The only error shape reachable here is the boundary guard's
  # {:registry_unavailable, _} (delete_task/1 is a cast and always returns
  # :ok), so a single clause is both total and warning-free.
  defp describe_error({:registry_unavailable, reason}),
    do: "task registry unavailable: #{inspect(reason)}"
end
