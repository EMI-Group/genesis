defmodule EvoDashWeb.DashboardLive.ProjectFlow do
  @moduledoc """
  Event handlers for project creation/opening on the dashboard.

  Extracted from DashboardLive to keep the main module focused on task
  lifecycle management and state persistence.
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

            {:noreply, push_patch(socket, to: "/?project=#{URI.encode(full_path)}")}
        end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Project opening / selection
  # ───────────────────────────────────────────────────────────────────────────

  def open_project(socket, %{"path" => path}) do
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
      {:noreply, push_patch(socket, to: "/?project=#{URI.encode(expanded)}")}
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

  def select_project(socket, %{"path" => path}) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      TaskRegistry.add_recent_project(expanded, Path.basename(expanded))
      recent_projects = TaskRegistry.list_recent_projects()

      socket =
        socket
        |> assign(:recent_projects, recent_projects)
        |> assign(:project_palette_open, false)
        |> assign(:palette_mode, :menu)

      {:noreply, push_patch(socket, to: "/?project=#{URI.encode(expanded)}")}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Directory does not exist: %{path}", path: path))}
    end
  end
end
