defmodule EvoDashWeb.ProjectsLive.Palette do
  @moduledoc """
  Command-palette navigation for `EvoDashWeb.ProjectsLive`.

  The page owns the palette assigns (`:project_palette_open`, `:palette_mode`,
  `:palette_search`, `:palette_selected_index`) and the `phx-*` wiring; this
  module owns the pure index arithmetic plus the socket-in/socket-out keyboard
  handler the `"palette_keydown"` event delegates to.

  Palette item order (and therefore every index here): the filtered project
  rows first, then the actions — locally Open by Path (+0), Create New Project
  (+1) and New Workspace (+2); on a remote node Create New Project is hidden, so
  New Workspace is +1.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias EvoDash.NodeContext
  alias EvoDash.SafeCall
  alias EvoDashWeb.ProjectsLive.Project
  alias EvoDashWeb.ProjectsLive.ProjectFlow

  @doc """
  Normalizes the `"palette_mode"` event payload to a palette mode atom.
  """
  @spec mode_atom(term()) :: :open_path | :new_project | :new_workspace | :menu
  def mode_atom(mode_str) do
    case mode_str do
      "open_path" -> :open_path
      "new_project" -> :new_project
      "new_workspace" -> :new_workspace
      _ -> :menu
    end
  end

  @doc """
  Total number of items in the palette menu list: the filtered projects plus
  the actions (3 locally, 2 on a remote node).
  """
  @spec item_count([map()], String.t() | nil, boolean()) :: non_neg_integer()
  def item_count(projects, search, remote?) do
    length(EvoDashWeb.ProjectComponents.filter_projects(projects, search)) +
      if(remote?, do: 2, else: 3)
  end

  @doc """
  The next (clamped) palette index after ArrowDown.
  """
  @spec next_index(integer(), non_neg_integer()) :: non_neg_integer()
  def next_index(current, item_count) do
    max(min(current + 1, item_count - 1), 0)
  end

  @doc """
  The next (clamped) palette index after ArrowUp.
  """
  @spec prev_index(integer()) :: non_neg_integer()
  def prev_index(current), do: max(current - 1, 0)

  @doc """
  Index of the New Workspace action (after the project rows and the other
  actions).
  """
  @spec new_workspace_index(non_neg_integer(), boolean()) :: non_neg_integer()
  def new_workspace_index(action_base, remote?), do: action_base + if(remote?, do: 1, else: 2)

  @doc """
  Applies one palette keydown to the socket.

  In :open_path and :new_project modes, Escape is handled by the client-side
  phx-key binding on the input (which sends palette_keydown with
  key="Escape"); the Escape clause below matches any mode and closes the
  palette, so non-menu modes are safe no-ops for every other key.
  """
  @spec handle_key(Phoenix.LiveView.Socket.t(), String.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def handle_key(socket, "Escape", _mode) do
    socket
    |> assign(:project_palette_open, false)
    |> assign(:palette_mode, :menu)
    |> assign(:palette_search, "")
    |> assign(:palette_selected_index, 0)
  end

  def handle_key(socket, "ArrowDown", :menu) do
    count = item_count(socket.assigns.projects, socket.assigns.palette_search, remote?(socket))

    assign(
      socket,
      :palette_selected_index,
      next_index(socket.assigns.palette_selected_index, count)
    )
  end

  def handle_key(socket, "ArrowUp", :menu) do
    assign(socket, :palette_selected_index, prev_index(socket.assigns.palette_selected_index))
  end

  def handle_key(socket, "Enter", :menu) do
    filtered =
      EvoDashWeb.ProjectComponents.filter_projects(
        socket.assigns.projects,
        socket.assigns.palette_search
      )

    action_base = length(filtered)
    index = socket.assigns.palette_selected_index

    # The workspace action sits AFTER the existing actions: locally
    # Open by Path (+0), Create New Project (+1), New Workspace (+2); on a
    # remote node Create New Project is hidden, so New Workspace is +1.
    new_workspace_index = new_workspace_index(action_base, remote?(socket))

    cond do
      index < action_base and index < length(filtered) ->
        # Activate the selected project via push_patch (node-aware:
        # remote contexts validate/register on the remote node and carry the
        # `&node=` param so the node context survives the patch)
        project = Enum.at(filtered, index)

        # Never `Path.expand` against the VM cwd: registry projects are absolute-path
        # filtered at assignment, but a stale/relative entry would cwd-join
        # on Windows (Tauri install dir). A relative selection just doesn't
        # open — same UX as a failed open, without the cwd join.
        case ProjectFlow.normalize_project_path(project.path) do
          {:ok, expanded} ->
            if socket.assigns[:current_node_id] != nil do
              activate_remote_project(socket, expanded)
            else
              if File.dir?(expanded) do
                # Exit-safe write: a registry `GenServer.call` can time
                # out/exit and must never crash the page. The projects list
                # itself is reloaded by the AsyncLoad batch the push_patch
                # below spawns, so no synchronous re-read is needed here.
                SafeCall.run(fn ->
                  NodeContext.mount_project(node(), expanded, Path.basename(expanded))
                end)

                socket
                |> assign(:project_palette_open, false)
                |> assign(:palette_mode, :menu)
                |> push_patch(to: "/projects?project=#{URI.encode(expanded)}")
              else
                socket
                |> assign(:project_palette_open, false)
                |> put_flash(
                  :error,
                  gettext("Directory does not exist: %{path}", path: project.path)
                )
              end
            end

          {:error, _reason} ->
            socket
            |> assign(:project_palette_open, false)
            |> put_flash(:error, gettext("Directory does not exist: %{path}", path: project.path))
        end

      index == action_base ->
        socket
        |> assign(:palette_mode, :open_path)
        |> assign(
          :path_suggestions,
          Project.path_suggestions(
            socket.assigns.current_node,
            "",
            socket.assigns.projects
          )
        )

      index == new_workspace_index ->
        # A workspace is pure VCT metadata (no OS path), so this entry point is
        # available on LOCAL and REMOTE nodes alike. Entering the form always
        # starts from an empty member selection.
        socket
        |> assign(:palette_mode, :new_workspace)
        |> assign(:new_workspace_members, [])

      index == action_base + 1 ->
        # Unreachable when remote (remote indices land on the workspace action
        # above and item_count clamps at it)
        assign(socket, :palette_mode, :new_project)

      true ->
        socket
    end
  end

  def handle_key(socket, _key, _mode), do: socket

  # Remote palette selection — ASYNC. The synchronous part is only the gate
  # guard; the RPC-heavy sequence (remote dir? validation, project mount +
  # list reload, config/mode/foreign-repo loading) runs OUTSIDE the
  # LiveView process via ProjectFlow.spawn_remote_project_activation/2 so the
  # UI never blocks on the 6-7 cross-node round-trips per palette Enter. The
  # palette closes immediately at spawn; the result arrives as a
  # `{:async_remote_project, node, path, result}` message handled by
  # ProjectsLive.handle_info/2, which stale-guards it, applies the assigns,
  # resets the GitHub state when the project changed, and push_patches the
  # `&node=` URL so handle_params re-runs in the same remote context.
  @spec activate_remote_project(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def activate_remote_project(socket, expanded) do
    # Gate guard (defense in depth): while the selected remote target is
    # pending/failed, `@current_node` is still the LOCAL BEAM node — validating
    # or registering the path here would leak into the local filesystem and
    # the local VCT project registry. Close the palette and surface an error.
    if EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      socket
      |> assign(:project_palette_open, false)
      |> assign(:palette_mode, :menu)
      |> put_flash(
        :error,
        gettext(
          "Cannot open project: remote node %{name} is not connected. Retry the connection first.",
          name: socket.assigns[:current_node_name] || "remote"
        )
      )
    else
      ProjectFlow.spawn_remote_project_activation(socket, expanded)
    end
  end

  defp remote?(socket), do: socket.assigns[:current_node_id] != nil
end
