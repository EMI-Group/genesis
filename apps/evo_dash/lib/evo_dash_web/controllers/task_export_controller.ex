defmodule EvoDashWeb.TaskExportController do
  use EvoDashWeb, :controller
  use Gettext, backend: EvoDashWeb.Gettext

  def export(conn, %{"task_id" => task_id}) do
    case EvoDash.TaskRegistry.get_task(task_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> send_resp(404, gettext("Task not found"))
        |> halt()

      task ->
        archive_metadata = Map.get(task, :archive_metadata) || []

        if archive_metadata == [] do
          conn
          |> put_status(:not_found)
          |> send_resp(404, gettext("No archive data available for this task"))
          |> halt()
        else
          data = normalize_for_json(archive_metadata)
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

  defp normalize_for_json(value), do: value
end
