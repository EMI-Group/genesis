defmodule EvoGit.Agent.Tools.StartTask do
  @moduledoc """
  Command handler for the `StartTask.start_task` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Starts a new background
  task (genesis / evolve / reflect / extract_skills) in the task registry.
  """

  alias EvoGit.Agent.Tools.Shared

  @truncate_length 2000

  @doc """
  Executes the start_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case EvoGit.TaskRegistry.StartOptions.build(args) do
      {:ok, task_type, opts} ->
        case safe_start_task(task_type, opts) do
          {:ok, task} -> format_success(task, task_type, Keyword.get(opts, :objective, ""))
          {:error, reason} -> "Task could not be started: #{inspect(reason)}"
        end

      {:error, message} ->
        message
    end
  end

  # --- Task registry call ---

  defp safe_start_task(task_type, opts) do
    EvoGit.TaskRegistry.start_task(task_type, opts)
  rescue
    e ->
      # Tool boundary: the task system (TaskRegistry GenServer / SQLite store)
      # may be down, or the 30s GenServer.call timeout may fire. A crash must
      # never kill the agent loop — the LLM gets a readable error string it can
      # act on instead.
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end

  # --- Formatting ---

  defp format_success(task, task_type, objective) do
    base = "Task #{task.id} started (type: #{task_type})"

    case String.trim(objective) do
      "" -> base
      obj -> base <> ". Objective: #{Shared.truncate(obj, @truncate_length)}"
    end
  end
end
