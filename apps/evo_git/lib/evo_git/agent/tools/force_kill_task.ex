defmodule EvoGit.Agent.Tools.ForceKillTask do
  @moduledoc """
  Tool for force-killing a task by id.

  Delegates to `EvoGit.TaskRegistry.force_kill_task/1` — brutally kills every
  agent of the task plus the wrapper process and persists the task as `:failed`
  with no result. ALL progress is lost. Prefer `cancel_task` (graceful) unless
  the task is hung and must be stopped immediately.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "force_kill_task",
      description: """
      Force-kills a task by id — the brutal cancellation path. Kills every agent of the
      task and the wrapper process, persisting the task as :failed with no result. ALL
      progress is lost; prefer cancel_task (graceful, results preserved) unless the task
      is hung and must be stopped immediately.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "The id of the task to force-kill"
          }
        },
        "required" => ["task_id"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

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
