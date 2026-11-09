defmodule EvoGit.Agent.Tools.ListProjects do
  @moduledoc """
  Command handler for the `ListProjects.list_projects` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Lists the Virtual Context
  Tree project mounts of this node, newest first.
  """
  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the list_projects tool.
  Reads the project mounts from `EvoGit.VCT` (a live read of its in-memory
  mount cache) and formats each project on one line. Never raises: a VCT or
  store failure is reported as a readable error string.
  """
  def execute(_args, _repo_path, _repo_root) do
    case safe_list_projects() do
      projects when is_list(projects) -> format_projects(projects)
      {:error, reason} -> "project list unavailable: #{Failure.format_reason(reason)}"
    end
  end

  # --- VCT call ---
  defp safe_list_projects do
    EvoGit.VCT.projects()
  rescue
    e ->
      # Tool boundary: the VCT GenServer may be down. A crash must never kill
      # the agent loop — the LLM gets a readable error string it can act on.
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
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
