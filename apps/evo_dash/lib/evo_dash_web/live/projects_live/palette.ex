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
  import Phoenix.Component, only: [assign: 3]

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
      index < action_base ->
        # Use the same node-aware validation and query encoding as a row click.
        project = Enum.at(filtered, index)
        socket = assign(socket, :project_palette_open, false)
        {:noreply, socket} = ProjectFlow.select_project(socket, %{"path" => project.path})
        socket

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

  defp remote?(socket), do: socket.assigns[:current_node_id] != nil
end
