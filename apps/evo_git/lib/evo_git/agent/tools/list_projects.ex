defmodule EvoGit.Agent.Tools.ListProjects do
  @moduledoc """
  Command handler for the `ListProjects.list_projects` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Lists the Virtual Context
  Tree project mounts of this node, newest first.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the list_projects handler.

  Reads the project mounts from `EvoGit.VCT` (a live read of its in-memory mount
  cache) and formats each project on one line. `EvoGit.VCT.projects/1` is a
  TOTAL read — it answers `[]` when the VCT server is absent or dead — so there
  is no boundary guard here and an empty list is the only degradation.
  """
  def execute(_args, _repo_path, _repo_root) do
    EvoGit.VCT.projects() |> format_projects()
  end

  # --- Formatting ---

  defp format_projects([]), do: "No projects found."

  defp format_projects(projects) do
    projects
    |> Enum.map(&format_project_line/1)
    |> Enum.join("\n")
  end

  defp format_project_line(project) do
    point = Map.get(project, :point) || "<unknown>"
    path = Map.get(project, :path) || "<unknown>"
    name = project_name(Map.get(project, :name), path)
    last_opened = Shared.format_datetime(Map.get(project, :last_opened_at))
    "- #{point} | name: #{name} | path: #{path} | last opened: #{last_opened}"
  end

  # `name` is optional; fall back to the path, then "<unknown>".
  defp project_name(name, _path) when is_binary(name) and name != "", do: name
  defp project_name(_name, path), do: path
end
