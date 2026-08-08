defmodule EvoDashWeb.DashboardLive.ProjectFlow do
  @moduledoc """
  Event handlers for project creation/opening on the dashboard.

  Extracted from DashboardLive to keep the main module focused on task
  lifecycle management and state persistence.

  All project-opening paths are node-aware: in a remote context
  (`socket.assigns[:current_node_id] != nil`) directory checks, recent-project
  registration, and recents reload go through `EvoDash.NodeContext` so they run
  on the remote daemon's filesystem/store. In pending contexts `@current_node`
  is still the local BEAM node, where NodeContext delegates to the local
  TaskRegistry/filesystem — the safe degradation path.
  """

  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.Project

  # ───────────────────────────────────────────────────────────────────────────
  # Project creation
  # ───────────────────────────────────────────────────────────────────────────

  def create_project(socket, %{"location" => location, "name" => name}) do
    location = Path.expand(location)

    cond do
      not File.dir?(location) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Parent directory does not exist: %{path}", path: location)
         )}

      true ->
        case Project.validate_project_name(name) do
          {:error, :invalid_name} ->
            {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

          {:ok, sanitized} ->
            full_path = Path.join(location, sanitized)
            File.mkdir!(full_path)

            TaskRegistry.add_recent_project(full_path, sanitized)
            recent_projects = TaskRegistry.list_recent_projects()

            socket =
              socket
              |> assign(:recent_projects, recent_projects)
              |> assign(:project_palette_open, false)
              |> assign(:palette_mode, :menu)
              |> put_flash(:info, gettext("Project created: %{path}", path: full_path))

            {:noreply, push_patch(socket, to: project_url(socket, full_path))}
        end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Project opening / selection
  # ───────────────────────────────────────────────────────────────────────────

  def open_project(socket, %{"path" => path}) do
    if socket.assigns[:current_node_id] != nil do
      activate_remote_project(socket, path)
    else
      expanded = Path.expand(path)

      if File.dir?(expanded) do
        TaskRegistry.add_recent_project(expanded, Path.basename(expanded))
        recent_projects = TaskRegistry.list_recent_projects()

        socket =
          socket
          |> assign(:recent_projects, recent_projects)
          |> assign(:project_palette_open, false)
          |> assign(:palette_mode, :menu)

        # Push URL params to persist project across navigation
        {:noreply, push_patch(socket, to: project_url(socket, expanded))}
      else
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Directory does not exist: %{path}. Create a new project instead?",
             path: path
           )
         )}
      end
    end
  end

  def select_project(socket, %{"path" => path}) do
    if socket.assigns[:current_node_id] != nil do
      activate_remote_project(socket, path)
    else
      expanded = Path.expand(path)

      if File.dir?(expanded) do
        TaskRegistry.add_recent_project(expanded, Path.basename(expanded))
        recent_projects = TaskRegistry.list_recent_projects()

        socket =
          socket
          |> assign(:recent_projects, recent_projects)
          |> assign(:project_palette_open, false)
          |> assign(:palette_mode, :menu)

        {:noreply, push_patch(socket, to: project_url(socket, expanded))}
      else
        {:noreply,
         put_flash(socket, :error, gettext("Directory does not exist: %{path}", path: path))}
      end
    end
  end

  # Remote project activation — shared by open_project/select_project. Validates
  # the directory on the remote node, registers it in the remote node's recent
  # projects, and sets a DISPLAY-ONLY active project (no local project config /
  # mode detection — those are local concerns). The push_patch URL carries the
  # `&node=` param so handle_params re-runs in the same remote context.
  defp activate_remote_project(socket, path) do
    # Gate guard (defense in depth): while the selected remote target is
    # pending/failed, `@current_node` is still the LOCAL BEAM node — validating
    # or registering the path here would leak into the local filesystem and
    # local TaskRegistry recents. Reject the event with a flash error.
    if EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "Cannot open project: remote node %{name} is not connected. Retry the connection first.",
           name: socket.assigns[:current_node_name] || "remote"
         )
       )}
    else
      expanded = Path.expand(path)
      node = socket.assigns[:current_node]

      if EvoDash.NodeContext.dir?(node, expanded) do
        EvoDash.NodeContext.add_recent_project(node, expanded, Path.basename(expanded))
        recent_projects = EvoDash.NodeContext.list_recent_projects(node)

        socket =
          socket
          |> assign(:recent_projects, recent_projects)
          |> assign(:project_palette_open, false)
          |> assign(:palette_mode, :menu)
          |> assign(:active_project, %{path: expanded, name: Path.basename(expanded)})
          |> assign(:active_project_path, expanded)

        {:noreply, push_patch(socket, to: project_url(socket, expanded))}
      else
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Directory does not exist on the remote node: %{path}", path: path)
         )}
      end
    end
  end

  # Builds the dashboard URL for a project path. In a remote context the
  # `&node=` param is appended so the node context survives the push_patch —
  # NOTE: deliberately NOT `EvoDashWeb.Helpers.with_node_param/2`, which
  # appends with `?` and would corrupt the existing `?project=` query.
  defp project_url(socket, path) do
    case socket.assigns[:current_node_id] do
      nil -> "/?project=#{URI.encode(path)}"
      node_id -> "/?project=#{URI.encode(path)}&node=#{node_id}"
    end
  end
end
