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

  alias EvoGit.Agent.Tools.Boundary
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the cancel_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        # Cross-GenServer boundary: see `EvoGit.Agent.Tools.Boundary`.
        case Boundary.run(
               fn -> EvoGit.TaskRegistry.cancel_task(task_id) end,
               fn reason -> {:registry_unavailable, reason} end
             ) do
          :ok -> "Task #{task_id} cancellation requested (graceful)."
          {:error, reason} -> "Error cancelling task #{task_id}: #{describe_error(reason)}"
        end

      {:error, message} ->
        message
    end
  end

  defp describe_error(reason) do
    Shared.describe_error(
      reason,
      "task is not in a cancellable state (already terminal or finalizing)"
    )
  end
end
