defmodule EvoGit.Agent.Tools.GetTask do
  @moduledoc """
  Tool for fetching a single task's details from the task registry by id.
  """

  alias EvoGit.Agent.Tools.Shared

  @truncate_length 2000

  @doc """
  Executes the get_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "task_id") do
      {:ok, task_id} ->
        case safe_get_task(task_id) do
          nil -> "Task #{task_id} not found."
          {:error, reason} -> "task system unavailable: #{reason}"
          task -> format_task(task)
        end

      {:error, message} ->
        message
    end
  end

  # --- Task registry call ---

  defp safe_get_task(task_id) do
    EvoGit.TaskRegistry.get_task(task_id)
  rescue
    e ->
      # Tool boundary: the task system (TaskRegistry GenServer / SQLite store /
      # scheduler) may be down, or the 30s GenServer.call timeout may fire. A
      # crash must never kill the agent loop — the LLM gets a readable error
      # string it can act on instead.
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end

  # --- Formatting ---

  defp format_task(task) do
    """
    Task #{task.id}
    - status: #{task.status}
    - type: #{task.type}
    - objective: #{objective_snippet(task.opts)}
    - started_at: #{format_datetime(task.started_at)}
    - finished_at: #{format_datetime(task.finished_at)}
    - result: #{format_result(task.result)}
    """
    |> String.trim_trailing()
  end

  defp objective_snippet(opts) do
    case objective_from_opts(opts) do
      nil ->
        "(no objective)"

      obj when is_binary(obj) ->
        case String.trim(obj) do
          "" -> "(no objective)"
          trimmed -> truncate(trimmed, @truncate_length)
        end

      obj ->
        truncate(inspect(obj), @truncate_length)
    end
  end

  # `opts` on %TaskInfo{} is a keyword list; a string-keyed map form is handled
  # too. Checks both key shapes defensively.
  defp objective_from_opts(opts) when is_map(opts),
    do: Map.get(opts, "objective") || Map.get(opts, :objective)

  defp objective_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :objective)
  defp objective_from_opts(_opts), do: nil

  # `result` may be nil, a plain string, or a map with a "result"/:result key
  # containing a string — format defensively and truncate long strings.
  defp format_result(nil), do: "none"

  defp format_result(result) when is_binary(result), do: truncate(result, @truncate_length)

  defp format_result(result) when is_map(result) do
    case Map.get(result, "result") || Map.get(result, :result) do
      nil -> truncate(inspect(result), @truncate_length)
      value when is_binary(value) -> truncate(value, @truncate_length)
      value -> truncate(inspect(value), @truncate_length)
    end
  end

  defp format_result(result), do: truncate(inspect(result), @truncate_length)

  defp format_datetime(nil), do: "unknown"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)

  defp truncate(string, max) when is_binary(string) do
    if String.length(string) <= max do
      string
    else
      String.slice(string, 0, max) <> "...[truncated]"
    end
  end
end
