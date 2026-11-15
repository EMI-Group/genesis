defmodule EvoDashWeb.HomeLive.WorkspaceComponent do
  @moduledoc false
  use EvoDashWeb, :html
  alias EvoDashWeb.HomeLive.Workspace

  def selector(assigns) do
    assigns =
      assigns
      |> assign_new(:workspace, fn -> nil end)
      |> assign_new(:workspace_open, fn -> false end)
      |> assign_new(:workspace_path, fn -> "" end)
      |> assign_new(:workspace_projects, fn -> [] end)
      |> assign_new(:workspace_loading, fn -> false end)
      |> assign_new(:workspace_error, fn -> nil end)

    assigns = assign(assigns, :workspace_locked, Workspace.locked?(assigns))

    assigns =
      assign(
        assigns,
        :workspace_form,
        to_form(%{"path" => assigns.workspace_path}, as: :workspace)
      )

    ~H"""
    <div id="assistant-workspace" class="assistant-project-control">
      <button
        id="workspace-toggle"
        type="button"
        phx-click="workspace_toggle"
        aria-expanded={to_string(@workspace_open)}
        aria-controls="workspace-panel"
        aria-haspopup="dialog"
        disabled={@workspace_locked}
        title={
          if @workspace_locked,
            do: gettext("Project locked while replying"),
            else: @workspace && @workspace.path
        }
        class="assistant-context-button"
      >
        <.icon name="hero-folder" class="size-4" />
        <span class="truncate">{if @workspace, do: @workspace.name, else: gettext("Select project")}</span>
        <.icon name="hero-chevron-down" class="size-3" />
      </button>
      <div
        :if={@workspace_open}
        id="workspace-panel"
        role="dialog"
        aria-label={gettext("Select project")}
        phx-mounted={JS.focus(to: "#workspace-path")}
        phx-click-away={JS.push("workspace_toggle") |> JS.focus(to: "#workspace-toggle")}
        phx-window-keydown={JS.push("workspace_toggle") |> JS.focus(to: "#workspace-toggle")}
        phx-key="Escape"
        class="assistant-menu-panel assistant-project-panel"
      >
        <div :if={@workspace} class="assistant-project-current">
          <p class="assistant-project-path">{@workspace.path}</p>
          <button
            id="workspace-clear"
            type="button"
            phx-click="workspace_clear"
            disabled={@workspace_locked or @workspace_loading}
            class="assistant-menu-item"
          >{gettext("Clear project")}</button>
        </div>
        <div :if={@workspace_projects != []} id="workspace-recent" class="assistant-project-recent">
          <p class="assistant-menu-label">{gettext("Recent projects")}</p>
          <button
            :for={project <- @workspace_projects}
            type="button"
            phx-click="workspace_select"
            phx-value-path={project.path}
            disabled={@workspace_locked or @workspace_loading}
            title={project.path}
            class="assistant-menu-item"
          >
            <.icon name="hero-folder" class="size-4" /><span class="truncate">{project.name ||
              project.path}</span>
          </button>
        </div>
        <.form
          for={@workspace_form}
          id="workspace-form"
          phx-change="workspace_path"
          phx-submit="workspace_open"
          class="assistant-project-form"
        >
          <.input
            field={@workspace_form[:path]}
            id="workspace-path"
            type="text"
            placeholder={gettext("Full directory path")}
            aria-label={gettext("Project directory")}
            disabled={@workspace_locked or @workspace_loading}
            class="assistant-path-input"
          />
          <button
            id="workspace-open"
            type="submit"
            disabled={@workspace_locked or @workspace_loading}
            class="assistant-menu-submit"
          >{if @workspace_loading, do: gettext("Loading…"), else: gettext("Select project")}</button>
        </.form>
        <p :if={@workspace_error} id="workspace-error" role="alert" class="assistant-compose-error">
          {@workspace_error}
        </p>
      </div>
    </div>
    """
  end
end
