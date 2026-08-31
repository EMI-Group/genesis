defmodule EvoGit.Agent.Tools.ForceKillTask do
  @moduledoc """
  Command handler for the `ForceKillTask.force_kill_task` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Force-kills a task by id.

  Delegates to `EvoGit.TaskRegistry.force_kill_task/1` — brutally kills every
  agent of the task plus the wrapper process and persists the task as `:failed`
  with no result. ALL progress is lost. Prefer `cancel_task` (graceful) unless
  the task is hung and must be stopped immediately.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the force_kill_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        case safe_force_kill(task_id) do
          :ok -> "Task #{task_id} force-killed."
          {:error, reason} -> "Error force-killing task #{task_id}: #{describe_error(reason)}"
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
  defp safe_force_kill(task_id) do
    try do
      EvoGit.TaskRegistry.force_kill_task(task_id)
    catch
      :exit, reason -> {:error, {:registry_unavailable, reason}}
    end
  end

  defp describe_error(:not_found), do: "task not found"
  defp describe_error(:not_running), do: "task is not in a killable state"

  defp describe_error({:registry_unavailable, reason}),
    do: "task registry unavailable: #{inspect(reason)}"

  defp describe_error(other), do: inspect(other)
end
