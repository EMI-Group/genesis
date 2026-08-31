defmodule EvoGit.Agent.Tools.CancelTask do
  @moduledoc """
  Command handler for the `CancelTask.cancel_task` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Gracefully cancels a task
  by id.

  Delegates to `EvoGit.TaskRegistry.cancel_task/1` — sets the task status to
  `:cancelling` and informs all running agents to save their work and exit
  cleanly (up to 3 grace turns). Intermediate results are preserved and the
  task remains reviewable as `:cancelled`. Use `force_kill_task` instead when a
  task is hung and must be stopped immediately (all progress lost).
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the cancel_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        case safe_cancel(task_id) do
          :ok -> "Task #{task_id} cancellation requested (graceful)."
          {:error, reason} -> "Error cancelling task #{task_id}: #{describe_error(reason)}"
        end

      {:error, message} ->
        message
    end
  end

  # Justified try/catch :exit — cross-GenServer boundary. TaskRegistry is a
  # supervised GenServer; calling it while it is down (or not yet started)
  # exits the caller with :noproc, which is an exit, not a rescue-able
  # exception. Catch it and return a descriptive error string so the agent
  # never crashes on an unavailable registry.
  defp safe_cancel(task_id) do
    try do
      EvoGit.TaskRegistry.cancel_task(task_id)
    catch
      :exit, reason -> {:error, {:registry_unavailable, reason}}
    end
  end

  defp describe_error(:not_found), do: "task not found"

  defp describe_error(:not_running),
    do: "task is not in a cancellable state (already terminal or finalizing)"

  defp describe_error({:registry_unavailable, reason}),
    do: "task registry unavailable: #{inspect(reason)}"

  defp describe_error(other), do: inspect(other)
end
