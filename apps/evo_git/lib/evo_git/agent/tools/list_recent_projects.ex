defmodule EvoGit.Agent.Tools.ListRecentProjects do
  @moduledoc """
  Tool for listing the user's recently opened projects from the task registry.
  """

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "list_recent_projects",
      description:
        "Lists the user's recently opened projects (name, path, last opened time), " <>
          "most recent first. Use this to see which project the user is referring to.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the list_recent_projects tool.

  Reads the recent-projects list from `EvoGit.TaskRegistry` (a live store
  read via GenServer.call) and formats each project on one line. Never
  raises: a registry failure (GenServer down / 30s call timeout) is
  reported as a readable error string.
  """
  def execute(_args, _repo_path, _repo_root) do
    case safe_list_recent_projects() do
      projects when is_list(projects) -> format_projects(projects)
      {:error, reason} -> "task system unavailable: #{reason}"
    end
  end

  # --- Task registry call ---

  defp safe_list_recent_projects do
    EvoGit.TaskRegistry.list_recent_projects()
  rescue
    e ->
      # Tool boundary: the task system (TaskRegistry GenServer / SQLite store)
      # may be down, or the 30s GenServer.call timeout may fire. A crash must
      # never kill the agent loop — the LLM gets a readable error string it can
      # act on (retry or report) instead.
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end

  # --- Formatting ---

  defp format_projects([]), do: "No recent projects found."

  defp format_projects(projects) do
    projects
    |> Enum.map(&format_project_line/1)
    |> Enum.join("\n")
  end

  defp format_project_line(project) do
    path = Map.get(project, :path) || "<unknown>"
    name = project_name(Map.get(project, :name), path)
    last_opened = format_datetime(Map.get(project, :last_opened_at))

    "- #{name} | path: #{path} | last opened: #{last_opened}"
  end

  # `name` is optional; fall back to the path, then "<unknown>".
  defp project_name(name, _path) when is_binary(name) and name != "", do: name
  defp project_name(_name, path), do: path

  defp format_datetime(nil), do: "unknown"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)
end
