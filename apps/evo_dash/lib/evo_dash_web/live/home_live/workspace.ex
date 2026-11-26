defmodule EvoDashWeb.HomeLive.Workspace do
  @moduledoc """
  Optional, node-scoped project or VCT-workspace selection.

  Selecting a directory reads no project files. The selection is ONE plain,
  term-safe map persisted into `EvoDash.ChatHistory`:

      %{
        kind: :project | :workspace,
        point: String.t() | nil,      # the VCT point (draft-scope identity)
        path: String.t(),             # the EXECUTION path, always an OS path
        name: String.t(),
        node: node(),
        node_id: String.t() | nil,
        members: [%{point: _, path: _, name: _}],
        missing: [%{point: _, path: _}]
      }

  A PROJECT selection carries its own mount point and path. A WORKSPACE
  selection is a pure GROUPING point (`vct:///workspaces/<slug>`, no OS path),
  so `path` is its FIRST RESOLVED MEMBER's path — the concrete project a task
  or agent session executes in — while `point` stays the workspace point. A
  workspace with no resolvable member yields NO selection at all: the missing
  refs are reported instead of silently substituting another project.

  `point` is a SCOPE identity only. Everything that reaches `mount_project`,
  `start_task` or an agent-session start takes `path`, never `point`.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2]
  alias EvoDash.{NodeContext, SafeCall}
  alias EvoDashWeb.DraftScope
  alias EvoDashWeb.HomeLive.ChatState
  alias EvoDashWeb.ProjectsLive.ProjectFlow

  @workspace_prefix "vct:///workspaces/"

  def scope(assigns), do: {assigns[:current_node_id], assigns[:current_node] || node()}

  def picker_context(%{chat_id: chat_id} = assigns) when not is_nil(chat_id),
    do: if(!locked?(assigns), do: {assigns[:current_node_id], chat_id})

  def picker_context(_assigns), do: nil

  def locked?(assigns),
    do:
      assigns[:session_attach_pending?] == true or
        assigns[:chat_status] in [:running, :cancelling]

  @doc """
  The workbench link label: the EXECUTION path of the open workbench draft.

  The workbench client compares this value with its active project path, so it
  is always an OS path — a VCT point is never returned. Before the mount
  resolves, a legacy path-keyed draft key still names the project; a
  point-keyed one does not (nil).
  """
  def draft_project(%{workspace: %{path: path}}) when is_binary(path), do: path

  def draft_project(assigns) do
    case assigns[:workbench_draft_key] do
      {_, _, token, _} when is_binary(token) -> if(DraftScope.point?(token), do: nil, else: token)
      _ -> nil
    end
  end

  @doc "The draft-scope token the open workbench draft is keyed by (nil when none)."
  def draft_scope(%{workbench_draft_key: {_, _, token, _}}) when is_binary(token), do: token
  def draft_scope(_assigns), do: nil

  @doc """
  The draft-scope token a selection contributes: its project point, its
  workspace point, else its raw absolute path (the legacy identity).
  """
  def draft_token(selection) do
    DraftScope.project(selection) || DraftScope.workspace(selection)
  end

  @doc """
  Re-settles the open workbench draft key onto the RESOLVED VCT identity.

  Returns `{settled_key, legacy_keys}`. `settled_key` is
  `{node_id, node, token, draft_id}` with the selection's draft token, and
  `legacy_keys` are the OTHER spellings the same tab may already be stored
  under (the raw path a `?wb_project=` link carries).

  Nothing is re-keyed unless the current key already names the resolved
  selection (by point or by path), so picking a DIFFERENT project in the
  picker never re-scopes an open workbench tab.
  """
  def settle_workbench_key(assigns, selection) do
    case assigns[:workbench_draft_key] do
      {node_id, node, token, draft} = key when is_binary(token) and is_binary(draft) ->
        settled = draft_token(selection)
        aliases = draft_aliases(selection)

        if is_nil(settled) or token not in aliases do
          {key, []}
        else
          legacy =
            for alias_token <- aliases,
                alias_token != settled,
                do: {node_id, node, alias_token, draft}

          {{node_id, node, settled, draft}, legacy}
        end

      _ ->
        {nil, []}
    end
  end

  @doc """
  True when the open workbench tab already addresses `project` + `draft`.

  `project` is the URL path or point. A project path aliases its resolved
  project point, never a workspace point whose first member shares that path.
  """
  def open_tab?(assigns, project, draft) do
    case assigns[:workbench_draft_key] do
      {node_id, node, token, ^draft} ->
        scope(assigns) == {node_id, node} and is_binary(token) and
          same_project?(token, project, assigns[:workspace])

      _ ->
        false
    end
  end

  def missing_draft_project?(assigns),
    do: is_nil(assigns[:workspace]) and not is_nil(assigns[:workbench_draft_key])

  @doc """
  Normalizes a persisted selection (total; nil for anything unusable).

  A map persisted BEFORE VCT points existed carries neither `:kind` nor
  `:point` and restores as a plain project selection (path token). The path
  must be absolute for the node, and `members`/`missing` are rebuilt into
  their stable plain shapes.
  """
  def normalize(%{path: path, node: target} = workspace)
      when is_binary(path) and is_atom(target) and target not in [nil, true, false] do
    if ProjectFlow.absolute_path_for_node?(target, path) do
      point = normalize_point(workspace[:point])

      %{
        kind: normalize_kind(workspace[:kind], point),
        point: point,
        path: path,
        node: target,
        node_id: workspace[:node_id],
        name: normalize_name(workspace[:name], path),
        members: normalize_members(workspace[:members]),
        missing: normalize_missing(workspace[:missing])
      }
    end
  end

  def normalize(_), do: nil

  def restore(workspace, {node_id, target}) do
    case normalize(workspace) do
      %{node: ^target, node_id: ^node_id} = workspace -> workspace
      _ -> nil
    end
  end

  @doc """
  Lists the node's project mounts and its VCT workspaces with members resolved.

  Returns `%{projects: [mount], workspaces: [%{workspace: mount, members:
  [%{point: point, name: name, path: path}], missing: [ref]}]}` — the whole
  workspace roster in ONE batched read
  (`EvoDash.NodeContext.workspace_entries/1`). A workspace without resolved
  members keeps `members: []` and reports every stored member ref as missing
  — it is never substituted with another project.
  """
  def list(node_id, target) do
    with :ok <- ready_target(node_id, target),
         {:ok, projects} <- project_mounts(target) do
      {:ok, %{projects: projects, workspaces: workspace_entries(target)}}
    else
      _ -> {:error, gettext("Connect to the selected node before choosing a project.")}
    end
  end

  def open(node_id, target, input) when is_binary(input) do
    with :ok <- ready_target(node_id, target),
         {:ok, path} <- normalize_path(node_id, target, input),
         true <- ProjectFlow.absolute_path_for_node?(target, path),
         {:ok, true} <- SafeCall.run(fn -> NodeContext.dir?(target, path) end),
         {:ok, {:ok, mount}} <-
           SafeCall.run(fn -> NodeContext.mount_project(target, path, nil) end),
         %{} = selection <- normalize(project_selection(node_id, target, mount)) do
      {:ok, selection}
    else
      {:error, :unavailable} ->
        {:error, gettext("Connect to the selected node before choosing a project.")}

      {:error, reason} when reason in [:blank, :relative] ->
        {:error, gettext("Enter a full directory path.")}

      _ ->
        {:error,
         gettext(
           "This directory is unavailable on the selected node. Check the path and try again."
         )}
    end
  end

  def open(_, _, _), do: {:error, gettext("Enter a full directory path.")}

  def toggle(socket) do
    socket = assign(socket, workspace_open: !socket.assigns.workspace_open, workspace_error: nil)
    if socket.assigns.workspace_open, do: load(socket, :list), else: socket
  end

  @doc """
  Closes the picker — the idempotent close of a click-away or an Escape.

  The panel now stays MOUNTED (so the `MotionPanel` hook can fade it out), so
  `phx-window-keydown` still fires while it is closed. An Escape or a click-away
  therefore pushes THIS event instead of `workspace_toggle`: closing an already
  closed panel does nothing, while a toggle would open it from anywhere on the
  page.
  """
  def close(socket) do
    if socket.assigns.workspace_open, do: assign(socket, workspace_open: false), else: socket
  end

  def select(socket, path, kind \\ :open) do
    if locked?(socket.assigns) or socket.assigns.workspace_loading do
      socket
    else
      load(assign(socket, workspace_path: path), {kind, path})
    end
  end

  @doc "Selects a VCT WORKSPACE: its first resolved member becomes the execution path."
  def select_workspace(socket, point) do
    if locked?(socket.assigns) or socket.assigns.workspace_loading or not is_binary(point) do
      socket
    else
      load(socket, {:workspace, point})
    end
  end

  @doc "Toggles one workspace row's expanded member list (pure view state)."
  def toggle_expanded(socket, point) when is_binary(point) do
    expanded = socket.assigns[:workspace_expanded] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, point),
        do: MapSet.delete(expanded, point),
        else: MapSet.put(expanded, point)

    assign(socket, workspace_expanded: expanded)
  end

  def toggle_expanded(socket, _point), do: socket

  def clear(socket) do
    if locked?(socket.assigns) or socket.assigns.workspace_loading do
      socket
    else
      socket
      |> assign(workspace: nil, workspace_error: nil, workspace_open: false, workspace_path: "")
      |> ChatState.persist()
    end
  end

  @doc """
  Resolves a mounted project or workspace by PATH or by VCT POINT.

  An absolute path resolves against the project mounts (a vanished project
  keeps the "no longer open" error); a project point resolves to that mount; a
  workspace point resolves to the workspace selection.
  """
  def select_mounted(socket, key) do
    if locked?(socket.assigns) do
      assign(socket, workspace: restore(socket.assigns[:workspace], scope(socket.assigns)))
    else
      # The URL's identity wins over a cached selection that may have changed
      # mounts or workspace members since the draft was last opened.
      socket |> assign(workspace: nil) |> load({:mounted, key})
    end
  end

  def apply_result(socket, seq, request_scope, chat_id, kind, result) do
    if seq == socket.assigns.workspace_seq and request_scope == scope(socket.assigns) and
         chat_id == socket.assigns.chat_id do
      socket = assign(socket, workspace_loading: false)

      case {kind, result} do
        {:list, {:ok, {:ok, %{projects: projects} = bundle}}} ->
          assign(socket,
            workspace_projects: projects,
            workspace_workspaces: Map.get(bundle, :workspaces) || []
          )

        {loaded, {:ok, {:ok, workspace}}} when loaded in [:open, :browse, :mounted, :workspace] ->
          if locked?(socket.assigns) do
            socket
          else
            assign(socket, workspace: workspace, workspace_open: false, workspace_error: nil)
          end

        {_, {:ok, {:error, message}}} ->
          selection_error(socket, kind, message)

        _ ->
          selection_error(socket, kind, gettext("Could not load the project. Try again."))
      end
    else
      socket
    end
  end

  defp selection_error(socket, kind, message) do
    assign(socket,
      workspace_error: message,
      workspace_open: kind == :browse or socket.assigns.workspace_open
    )
  end

  @doc "The display label of a member mount or an unresolved member ref."
  def member_label(ref) when is_map(ref) do
    Map.get(ref, :point) || Map.get(ref, "point") ||
      (Map.get(ref, :path) || Map.get(ref, "path")) || gettext("Unknown project")
  end

  def member_label(ref) when is_binary(ref) and ref != "", do: ref
  def member_label(_ref), do: gettext("Unknown project")

  defp same_project?(token, project, selection) do
    aliases = draft_aliases(selection)
    token == project or (token in aliases and project in aliases)
  end

  defp draft_aliases(selection) do
    if point = DraftScope.workspace(selection) do
      [point]
    else
      Enum.uniq(
        Enum.reject([DraftScope.project(selection), DraftScope.path(selection)], &is_nil/1)
      )
    end
  end

  defp load(socket, operation) do
    {node_id, target} = request_scope = scope(socket.assigns)
    seq = socket.assigns.workspace_seq + 1
    kind = operation_kind(operation)
    tag = {:assistant_workspace_loaded, seq, request_scope, socket.assigns.chat_id, kind}

    result = SafeCall.start(self(), tag, fn -> run_operation(operation, node_id, target) end)

    case result do
      {:ok, _} ->
        assign(socket, workspace_seq: seq, workspace_loading: true, workspace_error: nil)

      _ ->
        selection_error(socket, kind, gettext("Could not load the project. Try again."))
    end
  end

  defp run_operation(:list, node_id, target), do: list(node_id, target)

  defp run_operation({kind, path}, node_id, target) when kind in [:open, :browse],
    do: open(node_id, target, path)

  defp run_operation({:mounted, key}, node_id, target), do: mounted(node_id, target, key)

  defp run_operation({:workspace, point}, node_id, target),
    do: workspace_scope(node_id, target, point)

  defp operation_kind(:list), do: :list
  defp operation_kind({kind, _argument}), do: kind

  defp mounted(node_id, target, key) when is_binary(key) do
    if workspace_point?(key),
      do: workspace_scope(node_id, target, key),
      else: mounted_project(node_id, target, key)
  end

  defp mounted(_node_id, _target, _key), do: no_longer_open()

  defp mounted_project(node_id, target, key) do
    point? = DraftScope.point?(key)

    with :ok <- ready_target(node_id, target),
         true <- point? or ProjectFlow.absolute_path_for_node?(target, key),
         {:ok, projects} <- project_mounts(target),
         %{} = mount <- Enum.find(projects, &matches_mount?(&1, key, point?)) do
      {:ok, project_selection(node_id, target, mount)}
    else
      _ -> no_longer_open()
    end
  end

  defp matches_mount?(mount, key, true), do: mount_point(mount) == key
  defp matches_mount?(mount, key, false), do: mount.path == key

  defp workspace_scope(node_id, target, point) do
    with :ok <- ready_target(node_id, target),
         true <- workspace_point?(point),
         {:ok, {:ok, resolution}} when is_map(resolution) <-
           SafeCall.run(fn -> NodeContext.workspace_members(target, point) end) do
      build_workspace_selection(node_id, target, resolve_workspace(target, nil, resolution))
    else
      _ -> no_longer_available()
    end
  end

  defp build_workspace_selection(node_id, target, entry) do
    point = mount_point(Map.get(entry, :workspace))

    with true <- is_binary(point) do
      case entry.members do
        [first | _] ->
          {:ok,
           %{
             kind: :workspace,
             point: point,
             path: first.path,
             name: mount_name(Map.get(entry, :workspace)),
             node: target,
             node_id: node_id,
             members: entry.members,
             missing: entry.missing
           }}

        [] ->
          {:error, no_member_message(entry.missing)}
      end
    else
      _ -> no_longer_available()
    end
  end

  defp project_mounts(target) do
    with {:ok, projects} when is_list(projects) <-
           SafeCall.run(fn -> NodeContext.projects(target) end) do
      {:ok, Enum.filter(projects, &valid_project?(&1, target))}
    else
      _ -> {:error, :unavailable}
    end
  end

  # ONE batched read for the whole roster — every workspace with its members
  # already resolved — so the picker never pays one resolution call per
  # workspace. Each entry is mapped onto the SAME resolution shape
  # `resolve_workspace/3` already understands.
  defp workspace_entries(target) do
    entries =
      case SafeCall.run(fn -> NodeContext.workspace_entries(target) end) do
        {:ok, entries} when is_list(entries) -> Enum.filter(entries, &is_map/1)
        _ -> []
      end

    Enum.map(entries, fn entry ->
      resolve_workspace(target, Map.get(entry, :workspace) || entry, entry)
    end)
  end

  # Members resolve IN STORED ORDER; anything the core could not resolve — or
  # that names a path this node cannot use — is reported, never dropped
  # silently and never replaced by another project.
  defp resolve_workspace(target, workspace, %{members: members} = resolution)
       when is_list(members) do
    {resolved, unusable} = Enum.split_with(members, &valid_project?(&1, target))

    %{
      workspace: Map.get(resolution, :workspace) || workspace,
      members: normalize_members(resolved),
      missing:
        normalize_missing(
          List.wrap(Map.get(resolution, :missing)) ++
            List.wrap(Map.get(resolution, :nested)) ++ unusable
        )
    }
  end

  defp resolve_workspace(_target, workspace, _resolution) do
    %{
      workspace: workspace,
      members: [],
      missing: normalize_missing(List.wrap(Map.get(workspace, :members)))
    }
  end

  defp no_member_message([]), do: gettext("This workspace has no projects.")

  defp no_member_message(missing) do
    gettext("This workspace has no available project on the selected node. Missing: %{refs}",
      refs: Enum.map_join(missing, ", ", &member_label/1)
    )
  end

  defp no_longer_open(),
    do: {:error, gettext("This project is no longer open on the selected node.")}

  defp no_longer_available(),
    do: {:error, gettext("This workspace is no longer available on the selected node.")}

  defp ready_target(nil, target) when target == node(), do: :ok

  defp ready_target(id, target)
       when is_binary(id) and id != "" and is_atom(target) and target not in [nil, true, false] do
    if target != node() and target in Node.list(:connected), do: :ok, else: {:error, :unavailable}
  end

  defp ready_target(_, _), do: {:error, :unavailable}
  defp normalize_path(nil, _, input), do: ProjectFlow.normalize_project_path(input)

  defp normalize_path(_, target, input),
    do: ProjectFlow.normalize_remote_project_path(target, input)

  defp valid_project?(%{path: path}, target) when is_binary(path),
    do: ProjectFlow.absolute_path_for_node?(target, path)

  defp valid_project?(_, _), do: false

  defp project_selection(node_id, target, mount) when is_map(mount) do
    path = Map.get(mount, :path) || Map.get(mount, "path")

    %{
      kind: :project,
      point: mount_point(mount),
      path: path,
      name: mount_name(mount),
      node: target,
      node_id: node_id,
      members: [],
      missing: []
    }
  end

  defp project_selection(_node_id, _target, _mount), do: %{}

  defp mount_point(mount) when is_map(mount) do
    case Map.get(mount, :point) || Map.get(mount, "point") do
      point when is_binary(point) and point != "" -> point
      _ -> nil
    end
  end

  defp mount_point(_mount), do: nil

  defp mount_name(mount) when is_map(mount) do
    case Map.get(mount, :name) || Map.get(mount, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> mount_point(mount) |> file_name(gettext("Workspace"))
    end
  end

  defp mount_name(_mount), do: gettext("Workspace")

  defp file_name(nil, fallback), do: fallback
  defp file_name(path, _fallback), do: Path.basename(path)

  defp workspace_point?(point),
    do: is_binary(point) and String.starts_with?(point, @workspace_prefix)

  defp normalize_point(point) when is_binary(point) and point != "", do: point
  defp normalize_point(_point), do: nil

  defp normalize_kind(kind, _point) when kind in [:workspace, "workspace"], do: :workspace
  defp normalize_kind(:project, _point), do: :project

  defp normalize_kind(_kind, point),
    do: if(workspace_point?(point), do: :workspace, else: :project)

  defp normalize_name(name, _path) when is_binary(name) and name != "", do: name
  defp normalize_name(_name, path), do: Path.basename(path)

  defp normalize_members(members) when is_list(members) do
    members |> Enum.map(&member_entry/1) |> Enum.reject(&is_nil/1)
  end

  defp normalize_members(_members), do: []

  defp member_entry(ref) do
    case normalize_ref(ref) do
      %{path: path} = entry when is_binary(path) ->
        Map.put(entry, :name, ref_name(ref) || Path.basename(path))

      _ ->
        nil
    end
  end

  defp normalize_missing(refs) when is_list(refs) do
    refs
    |> Enum.map(&normalize_ref/1)
    |> Enum.reject(&(is_nil(&1) or (is_nil(&1.point) and is_nil(&1.path))))
  end

  defp normalize_missing(_refs), do: []

  defp normalize_ref(ref) when is_map(ref) do
    %{
      point: normalize_point(Map.get(ref, :point) || Map.get(ref, "point")),
      path: normalize_point(Map.get(ref, :path) || Map.get(ref, "path"))
    }
  end

  defp normalize_ref(ref) when is_binary(ref) and ref != "", do: %{point: nil, path: ref}
  defp normalize_ref(_ref), do: nil

  defp ref_name(ref) when is_map(ref) do
    case Map.get(ref, :name) || Map.get(ref, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp ref_name(_ref), do: nil
end
