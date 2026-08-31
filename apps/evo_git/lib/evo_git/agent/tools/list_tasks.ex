defmodule EvoGit.Agent.Tools.ListTasks do
  @moduledoc """
  Command handler for the `ListTasks.list_tasks` command, invoked by `EvoGit.CommandShell`
  via the `run_command` tool. Lists tasks from the task registry, optionally
  filtered by status.
  """

  alias EvoGit.Agent.Tools.Shared

  @valid_statuses ~w(pending running finalizing completed failed cancelled cancelling)

  @status_map %{
    "pending" => :pending,
    "running" => :running,
    "finalizing" => :finalizing,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "cancelling" => :cancelling
  }

  @objective_snippet_length 120

  @doc """
  Executes the list_tasks tool.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, statuses} <- fetch_statuses(args) do
      case safe_list_tasks(statuses) do
        tasks when is_list(tasks) -> format_tasks(tasks)
        {:error, reason} -> "task system unavailable: #{reason}"
      end
    else
      {:error, message} -> message
    end
  end

  # --- Argument handling ---

  # `statuses` is optional; absent means "all statuses" ([]). When present it
  # must be a list of status strings (with the same JSON-string double-encode
  # recovery as Shared.fetch_array_arg/2).
  defp fetch_statuses(args) do
    if Map.has_key?(args, "statuses") do
      with {:ok, raw} <- Shared.fetch_array_arg(args, "statuses") do
        normalize_statuses(raw)
      end
    else
      {:ok, []}
    end
  end

  # Normalizes status strings to atoms, validating against the known set via a
  # lookup map (never String.to_atom on LLM input — avoids arbitrary atom
  # creation). Any unknown entry is a hard error listing the valid statuses.
  defp normalize_statuses(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case Shared.to_string_binary(entry) do
        {:ok, str} ->
          case Map.fetch(@status_map, str) do
            {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
            :error -> {:halt, {:error, unknown_status_error(str)}}
          end

        :error ->
          {:halt, {:error, "Status entries must be strings, got: #{inspect(entry)}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  defp unknown_status_error(status) do
    "Unknown status #{inspect(status)}; valid statuses: #{Enum.join(@valid_statuses, ", ")}"
  end

  # --- Task registry call ---

  defp safe_list_tasks(statuses) do
    EvoGit.TaskRegistry.list_tasks_summary(statuses)
  rescue
    e ->
      # Tool boundary: the task system (TaskRegistry GenServer / SQLite store /
      # scheduler) may be down, or the 30s GenServer.call timeout may fire
      # (handler delegates to a Task; a crashed Task leaves the caller waiting
      # until timeout). A crash must never kill the agent loop — the LLM gets a
      # readable error string it can act on (retry or report) instead.
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end

  # --- Formatting ---

  defp format_tasks([]), do: "No tasks found."

  defp format_tasks(tasks) do
    tasks
    |> Enum.map(&format_task_line/1)
    |> Enum.join("\n")
  end

  defp format_task_line(task) do
    id = Map.get(task, :id, "?")
    status = Map.get(task, :status, :unknown)
    type = Map.get(task, :type) || "unknown"
    project = Map.get(task, :project_path) || "<system>"
    objective = objective_snippet(Map.get(task, :opts))
    started_at = format_datetime(Map.get(task, :started_at))

    "- #{id} | status: #{status} | type: #{type} | project: #{project} | " <>
      "objective: #{objective} | started: #{started_at}"
  end

  defp objective_snippet(opts) do
    case objective_from_opts(opts) do
      nil ->
        "(no objective)"

      obj when is_binary(obj) ->
        case String.trim(obj) do
          "" -> "(no objective)"
          trimmed -> truncate(trimmed, @objective_snippet_length)
        end

      obj ->
        truncate(inspect(obj), @objective_snippet_length)
    end
  end

  # `opts` comes from the store as a STRING-keyed map (JSON object); a keyword
  # list form is handled too. Checks both key shapes defensively.
  defp objective_from_opts(opts) when is_map(opts),
    do: Map.get(opts, "objective") || Map.get(opts, :objective)

  defp objective_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :objective)
  defp objective_from_opts(_opts), do: nil

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
