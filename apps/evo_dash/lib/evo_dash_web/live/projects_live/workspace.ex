defmodule EvoDashWeb.ProjectsLive.Workspace do
  @moduledoc """
  Pure VCT-workspace helpers for the `EvoDashWeb.ProjectsLive` command palette.

  A workspace is a pure GROUPING point (`path: nil`): it is never activated,
  never becomes a task path and never reaches path suggestions or the persisted
  form state. Only its name/members/description are managed here — the page
  keeps the palette assigns and the event wiring.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  @doc """
  Builds the ordered member refs submitted with a new workspace.

  Every chosen POINT resolves to the currently loaded project mount, so the
  stored ref carries that mount's OS path as this node knows it. A project that
  vanished from the registry since it was picked is skipped instead of being
  stored as a dangling ref.
  """
  @spec member_refs([String.t()], [map()]) :: [%{String.t() => term()}]
  def member_refs(points, projects) do
    Enum.flat_map(points, fn point ->
      case Enum.find(projects, &(Map.get(&1, :point) == point)) do
        %{} = project -> [%{"point" => point, "path" => Map.get(project, :path)}]
        _ -> []
      end
    end)
  end

  @doc """
  The optional workspace description from the create form (absent/non-string →
  an empty string).
  """
  @spec description_param(map()) :: String.t()
  def description_param(params) do
    case Map.get(params, "description") do
      description when is_binary(description) -> description
      _ -> ""
    end
  end

  @doc """
  Toggles `value` in an ordered list, APPENDING on add so the click order of
  the New Workspace member picker is preserved (the workspace stores it).
  """
  @spec toggle_member([String.t()], String.t()) :: [String.t()]
  def toggle_member(list, value) do
    if value in list, do: List.delete(list, value), else: list ++ [value]
  end

  @doc """
  The workspace points of the loaded workspace view maps (non-points dropped).
  """
  @spec points([map()]) :: [String.t()]
  def points(workspaces) do
    workspaces
    |> Enum.map(fn
      %{workspace: %{point: point}} -> point
      %{point: point} -> point
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Maps a workspace registry error to its user-facing flash line.
  """
  @spec error_message(term()) :: String.t()
  def error_message(:invalid_name),
    do: gettext("Workspace name is required.")

  def error_message({:member_is_workspace, ref}),
    do:
      gettext("A workspace cannot contain another workspace: %{ref}",
        ref: ref_text(ref)
      )

  def error_message({:invalid_member, ref}),
    do: gettext("Invalid workspace member: %{ref}", ref: ref_text(ref))

  def error_message(:invalid_members),
    do: gettext("The workspace members are invalid.")

  def error_message(:vct_unavailable),
    do: gettext("The workspace registry is unavailable. Please try again.")

  def error_message(reason),
    do: gettext("Could not save the workspace: %{reason}", reason: ref_text(reason))

  @doc """
  Renders a workspace member ref (binary, point/path map, or anything else).
  """
  @spec ref_text(term()) :: String.t()
  def ref_text(ref) when is_binary(ref), do: ref

  def ref_text(ref) when is_map(ref) do
    point = Map.get(ref, "point") || Map.get(ref, :point)
    path = Map.get(ref, "path") || Map.get(ref, :path)

    cond do
      is_binary(point) -> point
      is_binary(path) -> path
      true -> inspect(ref)
    end
  end

  def ref_text(ref), do: inspect(ref)
end
