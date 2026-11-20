defmodule EvoGit.Agent.Tools.ListWorkspaces do
  @moduledoc """
  Command handler for the `ListWorkspaces.list_workspaces` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Lists the Virtual Context
  Tree WORKSPACE mounts of this node, newest first.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the list_workspaces handler.

  Reads the workspace mounts from `EvoGit.VCT` (a live read of its in-memory
  mount cache) and formats each workspace on one line with its canonical
  `vct:///workspaces/<slug>` point, display name, ordered member refs and
  description. `EvoGit.VCT.workspaces/1` is a TOTAL read — it answers `[]` when
  the VCT server is absent or dead — so there is no boundary guard here and an
  empty list is the only degradation.
  """
  def execute(_args, _repo_path, _repo_root) do
    EvoGit.VCT.workspaces() |> format_workspaces()
  end

  # --- Formatting ---
  defp format_workspaces([]), do: "No workspaces found."

  defp format_workspaces(workspaces) do
    workspaces
    |> Enum.map(&format_workspace_line/1)
    |> Enum.join("\n")
  end

  defp format_workspace_line(workspace) do
    point = Map.get(workspace, :point) || "<unknown>"
    name = workspace_name(Map.get(workspace, :name))
    members = format_members(Map.get(workspace, :members))
    description = Map.get(workspace, :description)

    "#{point} | name: #{name} | members: #{members} | description: #{description || "-"}"
  end

  # `name` is optional; a missing/blank name renders the placeholder.
  defp workspace_name(name) when is_binary(name) and name != "", do: name
  defp workspace_name(_name), do: "<unknown>"

  # Members stay in STORED order; each ref renders through the ONE shared
  # renderer (its point when non-nil, else its path, elsewhere "<invalid>").
  # A workspace with no members renders "-".
  defp format_members(members) when is_list(members) and members != [] do
    members
    |> Enum.map(&EvoGit.VCT.Mount.member/1)
    |> Enum.map(fn
      {:ok, ref} -> Shared.format_member_ref(ref)
      {:error, _reason} -> "<invalid>"
    end)
    |> Enum.join(", ")
  end

  defp format_members(_members), do: "-"
end
