defmodule EvoDashWeb.TaskExportController do
  use EvoDashWeb, :controller
  use Gettext, backend: EvoDashWeb.Gettext

  def export(conn, %{"task_id" => task_id}) do
    case EvoGit.TaskRegistry.get_task(task_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> send_resp(404, gettext("Task not found"))
        |> halt()

      task ->
        archive_metadata = task.archive_metadata || []

        if archive_metadata == [] do
          conn
          |> put_status(:not_found)
          |> send_resp(404, gettext("No archive data available for this task"))
          |> halt()
        else
          envelope = %{
            task_id: task.id,
            task_type: task.type,
            repo_path: task.opts[:path],
            status: task.status,
            started_at: task.started_at,
            finished_at: task.finished_at,
            agent_count: task.agent_count,
            usage: task.usage,
            archive_records: archive_metadata
          }

          data = normalize_for_json(envelope)
          json_binary = Jason.encode!(data)

          send_download(conn, {:binary, json_binary},
            filename: "archive-#{task_id}.json",
            content_type: "application/json"
          )
        end
    end
  end

  # Recursively normalize a structure into plain maps/lists/strings/numbers
  # so Jason can encode it. Handles structs (via Map.from_struct/1),
  # DateTimes (via DateTime.to_iso8601/1), and nested maps/lists.
  defp normalize_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_for_json(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp normalize_for_json(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> normalize_for_json()
  end

  defp normalize_for_json(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_for_json(v)} end)
  end

  defp normalize_for_json(list) when is_list(list) do
    Enum.map(list, &normalize_for_json/1)
  end

  # Tuples -> list (Jason cannot encode tuples directly)
  defp normalize_for_json(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> normalize_for_json()
  end

  # Un-serializable terms (PIDs, references, ports, functions) -> string fallback
  defp normalize_for_json(value) when is_pid(value) or is_reference(value) or is_port(value) or is_function(value) do
    inspect(value)
  end

  defp normalize_for_json(value), do: value
end
