defmodule EvoGit.Agent.Tools.ShowWorkspace do
  @moduledoc """
  Command handler for the `ShowWorkspace.workspace_members` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Shows ONE Virtual Context
  Tree workspace and its members: the workspace header, every member that
  resolves against the current mount table, and one diagnostic line per member
  ref the VCT cannot use (missing, or nesting another workspace).

  ## Return contract

  A successful report is a plain `String.t()`; every handler-level failure is
  `{:error, String.t()}`, the shape `EvoGit.CommandShell` propagates as a shell
  error (see the `execute/3` doc). A runtime DEGRADATION inside a successful
  read still renders as a diagnostic line inside that string.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the show_workspace handler from `%{"workspace" => point_or_name}`.
  Accepts a workspace POINT (`vct:///workspaces/<slug>`) or a bare workspace
  name. Returns the formatted report binary, or `{:error, message}` for a
  handler-level failure the shell propagates: a blank/missing `workspace`
  argument, an unknown key (`:not_found`), a key naming a non-workspace mount
  (`:not_a_workspace`) or an unusable key (`:invalid_point`). Never raises:
  `EvoGit.VCT.workspace_members/1` answers its documented `{:error, reason}`
  instead of exiting when the VCT is unavailable.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, key} <- fetch_workspace_key(args) do
      case EvoGit.VCT.workspace_members(key) do
        {:ok, resolution} when is_map(resolution) -> format_resolution(resolution)
        {:error, :not_found} -> {:error, "Workspace not found: #{key}"}
        {:error, :not_a_workspace} -> {:error, not_a_workspace_message(key)}
        {:error, :invalid_point} -> {:error, "Invalid workspace point: #{key}"}
        {:error, reason} -> {:error, "workspace unavailable: #{Failure.format_reason(reason)}"}
      end
    end
  end

  # --- Arguments ---
  defp fetch_workspace_key(args) do
    with {:ok, key} <- Shared.fetch_string_arg(args, "workspace") do
      if String.trim(key) == "" do
        {:error, "Missing required argument 'workspace'. Please provide a valid value."}
      else
        {:ok, String.trim(key)}
      end
    end
  end

  defp not_a_workspace_message(key) do
    "Not a workspace: #{key} is a project or reserved mount, not a workspace. " <>
      "Run 'ListWorkspaces.list_workspaces' to list the workspace points."
  end

  # --- Formatting ---
  defp format_resolution(resolution) do
    workspace = Map.get(resolution, :workspace)
    members = Map.get(resolution, :members) || []
    missing = Map.get(resolution, :missing) || []
    nested = Map.get(resolution, :nested) || []

    ([format_header(workspace)] ++
       Enum.map(members, &format_member/1) ++
       Enum.map(missing, &format_diagnostic("MISSING", &1)) ++
       Enum.map(nested, &format_diagnostic("NESTED", &1)))
    |> Enum.join("\n")
  end

  defp format_header(workspace) do
    point = Map.get(workspace, :point) || "<unknown>"
    name = display_name(Map.get(workspace, :name))
    description = Map.get(workspace, :description)

    "#{point} | #{name} | #{description || "-"}"
  end

  defp display_name(name) when is_binary(name) and name != "", do: name
  defp display_name(_name), do: "<unknown>"

  defp format_member(member) do
    point = Map.get(member, :point) || "<unknown>"
    name = display_name(Map.get(member, :name))
    path = Map.get(member, :path) || "<unknown>"

    "#{point} | #{name} | #{path}"
  end

  # A diagnostic line reports the STORED ref exactly as the VCT kept it (an
  # unresolvable ref is never expanded or guessed at), through the ONE shared
  # member-ref renderer.
  defp format_diagnostic(label, ref) do
    "#{label}: #{Shared.format_member_ref(ref)}"
  end
end
