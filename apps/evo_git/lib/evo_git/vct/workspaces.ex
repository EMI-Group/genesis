defmodule EvoGit.VCT.Workspaces do
  @moduledoc """
  Internal workspace read logic for `EvoGit.VCT`.

  This module is an internal helper of `EvoGit.VCT`: it resolves a workspace
  POINT or a BARE workspace name against the CURRENT mount table and turns the
  ONE member-resolution pass into every public shape — `workspace_members/1`'s
  mount structs and `workspace_entries/1,2`'s flat `member_entry` maps — so
  those reads can never disagree.
  It owns the roster/entry builders, the `workspaces_for/1` matching and the
  workspace-name lookup; the mount-table rules stay in `EvoGit.VCT.Table`, the
  mount value object in `EvoGit.VCT.Mount`, and the persist-plus-broadcast
  funnel in `EvoGit.VCT.Mounts`.
  """

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Mounts
  alias EvoGit.VCT.Table
  alias EvoGit.VCT.Path, as: VctPath

  ## Mutations

  @doc false
  @spec handle_create(map(), term(), term(), keyword()) :: {:reply, term(), map()}
  def handle_create(state, name, members, opts) do
    with {:ok, workspace_name} <- workspace_name(name),
         {:ok, point} <- workspace_point_for(workspace_name),
         {:ok, mounts, mount} <-
           Table.upsert_workspace(
             state.mounts,
             point,
             workspace_name,
             members,
             Keyword.get(opts, :description),
             DateTime.utc_now()
           ) do
      # A workspace never counts against the project cap, so `enforce_cap/2` is
      # deliberately NOT applied here.
      Mounts.commit(state, mounts, {:ok, mount})
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc false
  @spec forget_by_name([Mount.t()], String.t()) ::
          {:ok, [Mount.t()], Mount.t()} | {:error, :not_found}
  def forget_by_name(mounts, key) do
    case find_by_name(mounts, String.trim(key)) do
      nil -> {:error, :not_found}
      %Mount{point: point} -> Table.remove_by_point(mounts, point)
    end
  end

  ## Reads

  @doc false
  @spec list([Mount.t()], keyword()) :: [Mount.t()]
  def list(mounts, opts) do
    mounts
    |> Table.workspace_mounts()
    |> Table.sort_by_recency()
    |> Mounts.apply_limit(Keyword.get(opts, :limit))
  end

  # ONE call answers the whole roster: every workspace's members are resolved
  # against the same in-memory table, so the caller pays no per-workspace round
  # trip.
  @doc false
  @spec entries([Mount.t()], keyword()) :: [map()]
  def entries(mounts, opts) do
    mounts
    |> Table.workspace_mounts()
    |> Table.sort_by_recency()
    |> Mounts.apply_limit(Keyword.get(opts, :limit))
    |> Enum.map(&entry_for(mounts, &1))
  end

  @doc false
  @spec entry([Mount.t()], term()) ::
          {:ok, map()} | {:error, :not_found | :not_a_workspace | :invalid_point}
  def entry(mounts, key) do
    case resolve(mounts, key) do
      {:ok, resolution} -> {:ok, to_workspace_entry(resolution)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec resolve([Mount.t()], term()) ::
          {:ok, map()} | {:error, :not_found | :not_a_workspace | :invalid_point}
  def resolve(mounts, %VctPath{} = point), do: resolve(mounts, VctPath.format(point))

  def resolve(mounts, key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error, :invalid_point}

      Mounts.point_string?(trimmed) ->
        with {:ok, point} <- VctPath.canonical(trimmed) do
          workspace_row(mounts, point)
        end

      path_like?(trimmed) ->
        {:error, :invalid_point}

      true ->
        case find_by_name(mounts, trimmed) do
          nil -> {:error, :not_found}
          %Mount{point: point} -> workspace_row(mounts, point)
        end
    end
  end

  def resolve(_mounts, _key), do: {:error, :invalid_point}

  @doc false
  @spec containing([Mount.t()], term()) :: [Mount.t()]
  def containing(mounts, project) do
    case workspace_target(mounts, project) do
      {point, os_path} ->
        mounts
        |> Table.workspaces_containing(point, os_path)
        |> Table.sort_by_recency()

      :error ->
        []
    end
  end

  @doc false
  @spec find_by_name([Mount.t()], String.t()) :: Mount.t() | nil
  def find_by_name(mounts, name) do
    mounts
    |> Table.workspace_mounts()
    |> Enum.filter(&name_match?(&1, name))
    |> Table.sort_by_recency()
    |> List.first()
  end

  ## Entry builders

  # ONE member-resolution pass feeds every public shape, so `workspace_members/1`
  # (mount structs), `workspace_entries/1` and `workspace_entries/2` (flat
  # `member_entry` maps) can never disagree.
  @doc false
  @spec entry_for([Mount.t()], Mount.t()) :: map()
  def entry_for(mounts, %Mount{} = workspace) do
    mounts
    |> resolve_members(workspace)
    |> to_workspace_entry()
  end

  # A workspace is resolved through its POINT (canonicalized), never through an
  # OS path it does not have.
  defp workspace_row(mounts, point) do
    case Table.find_by_point(mounts, point) do
      nil ->
        {:error, :not_found}

      %Mount{} = mount ->
        if Mount.workspace?(mount),
          do: {:ok, resolve_members(mounts, mount)},
          else: {:error, :not_a_workspace}
    end
  end

  defp to_workspace_entry(%{members: members} = resolution) do
    %{resolution | members: Enum.map(members, &member_entry/1)}
  end

  defp member_entry(%Mount{} = mount),
    do: %{point: mount.point, name: mount.name, path: mount.path}

  # Every member is resolved IN STORED ORDER; an unresolvable ref keeps its
  # STORED form (it is metadata, not a filesystem probe) and a ref naming
  # another workspace is reported as `nested` instead of being expanded.
  defp resolve_members(mounts, %Mount{members: members} = workspace) do
    {resolved, missing, nested} =
      members
      |> workspace_member_refs()
      |> Enum.reduce({[], [], []}, fn ref, {resolved, missing, nested} ->
        case Table.member_mount(mounts, ref) do
          {:ok, mount} -> {[mount | resolved], missing, nested}
          :missing -> {resolved, [ref | missing], nested}
          :nested -> {resolved, missing, [ref | nested]}
        end
      end)

    %{
      workspace: workspace,
      members: Enum.reverse(resolved),
      missing: Enum.reverse(missing),
      nested: Enum.reverse(nested)
    }
  end

  # A stored row is normally already normalized; a hand-written one is read
  # LENIENTLY so a single unusable ref reports itself as `missing` instead of
  # hiding the whole workspace.
  defp workspace_member_refs(members) when is_list(members) do
    case Mount.normalize_members(members) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> members
    end
  end

  defp workspace_member_refs(_members), do: []

  ## Names and points

  defp workspace_name(name) do
    case Table.normalize_name(name) do
      nil -> {:error, :invalid_name}
      normalized -> {:ok, normalized}
    end
  end

  # The point derives from the SLUGIFIED name, so the display name is free text
  # while the point stays one valid segment. `point_segment/1` already maps
  # separators and control characters, so `format/1` cannot reject it; the
  # rescue keeps this total anyway (a raise would kill the caller's call).
  defp workspace_point_for(name) do
    {:ok, VctPath.format(VctPath.join(VctPath.workspaces(), [Table.point_segment(name)]))}
  rescue
    ArgumentError -> {:error, :invalid_name}
  end

  defp name_match?(%Mount{point: point, name: display}, name),
    do: VctPath.last_segment(point) == name or display == name

  defp path_like?(key), do: String.contains?(key, ["/", "\\"])

  ## `workspaces_for/1` matching

  # The `{point, os_path}` pair a `workspaces_for/1` argument names, enriched
  # from the mount table: a project's point contributes its OS path and an OS
  # path contributes its point, so a member naming EITHER form matches.
  defp workspace_target(mounts, project) do
    case workspace_project_key(project) do
      {:ok, point, os_path} -> enrich_workspace_target(mounts, point, os_path)
      :error -> :error
    end
  end

  defp workspace_project_key(%VctPath{} = point), do: {:ok, VctPath.format(point), nil}

  defp workspace_project_key(project) when is_binary(project) do
    trimmed = String.trim(project)

    cond do
      trimmed == "" ->
        :error

      Mounts.point_string?(trimmed) ->
        case VctPath.parse(trimmed) do
          {:ok, point} -> {:ok, VctPath.format(point), nil}
          {:error, _reason} -> :error
        end

      EvoGit.Platform.absolute_path?(trimmed) ->
        {:ok, nil, Table.normalize_os_path(trimmed)}

      true ->
        {:ok, project_point(trimmed), nil}
    end
  rescue
    ArgumentError -> :error
  end

  defp workspace_project_key(_project), do: :error

  defp project_point(name),
    do: VctPath.format(VctPath.join(VctPath.projects(), [Table.point_segment(name)]))

  defp enrich_workspace_target(mounts, point, os_path) do
    {point, os_path} = enrich_target_point(mounts, point, os_path)
    enrich_target_path(mounts, point, os_path)
  end

  defp enrich_target_point(_mounts, nil, os_path), do: {nil, os_path}

  defp enrich_target_point(mounts, point, os_path) do
    case Table.find_by_point(mounts, point) do
      %Mount{path: path} when is_binary(path) -> {point, os_path || path}
      _missing -> {point, os_path}
    end
  end

  defp enrich_target_path(_mounts, point, nil), do: {point, nil}

  defp enrich_target_path(mounts, point, os_path) do
    case Table.find_by_os_path(mounts, os_path) do
      %Mount{point: mounted_point} -> {point || mounted_point, os_path}
      nil -> {point, os_path}
    end
  end
end
