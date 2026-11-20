defmodule EvoGit.Agent.Tools.ForceKillTask do
  @moduledoc """
  Command handler for the `ForceKillTask.force_kill_task` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Force-kills a task by id.

  Delegates to `EvoGit.TaskRegistry.force_kill_task/1` — brutally kills every
  agent of the task plus the wrapper process and persists the task as `:failed`
  with no result. ALL progress is lost. Prefer `cancel_task` (graceful) unless
  the task is hung and must be stopped immediately.
  """

  alias EvoGit.Agent.Tools.Boundary
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the force_kill_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        # Cross-GenServer boundary: see `EvoGit.Agent.Tools.Boundary`.
        case Boundary.run(
               fn -> EvoGit.TaskRegistry.force_kill_task(task_id) end,
               fn reason -> {:registry_unavailable, reason} end
             ) do
          :ok -> "Task #{task_id} force-killed."
          {:error, reason} -> "Error force-killing task #{task_id}: #{describe_error(reason)}"
        end

      {:error, message} ->
        message
    end
  end

  defp describe_error(reason) do
    Shared.describe_error(reason, "task is not in a killable state")
  end
end
