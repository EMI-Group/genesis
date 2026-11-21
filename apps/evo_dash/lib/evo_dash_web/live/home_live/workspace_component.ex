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
      |> assign_new(:workspace_workspaces, fn -> [] end)
      |> assign_new(:workspace_expanded, fn -> MapSet.new() end)
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
        id="workspace-panel"
        role="dialog"
        aria-label={gettext("Select project")}
        phx-hook="MotionPanel"
        data-motion-want={to_string(@workspace_open)}
        hidden={!@workspace_open}
        phx-mounted={JS.focus(to: "#workspace-path")}
        phx-click-away={JS.push("workspace_close") |> JS.focus(to: "#workspace-toggle")}
        phx-window-keydown={JS.push("workspace_close") |> JS.focus(to: "#workspace-toggle")}
        phx-key="Escape"
        class="motion-panel assistant-menu-panel assistant-project-panel"
      >
        <div :if={@workspace} id="workspace-current" class="assistant-project-current">
          <p class="assistant-menu-label">{current_label(@workspace)}</p>
          <p id="workspace-current-path" class="assistant-project-path">{@workspace.path}</p>
          <ul
            :if={@workspace.missing != []}
            id="workspace-current-missing"
            class="assistant-project-path"
          >
            <li :for={ref <- @workspace.missing}>
              {Workspace.member_label(ref)} — {gettext("missing on this node")}
            </li>
          </ul>
          <button
            id="workspace-clear"
            type="button"
            phx-click="workspace_clear"
            disabled={@workspace_locked or @workspace_loading}
            class="assistant-menu-item"
          >{gettext("Clear project")}</button>
        </div>
        <div :if={@workspace_projects != []} id="workspace-recent" class="assistant-project-recent">
          <p class="assistant-menu-label">{gettext("Projects")}</p>
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
        <div
          :if={@workspace_workspaces != []}
          id="workspace-workspaces"
          class="assistant-project-recent"
        >
          <p class="assistant-menu-label">{gettext("Workspaces")}</p>
          <div
            :for={entry <- @workspace_workspaces}
            id={"workspace-ws-" <> dom_id(entry.workspace.point)}
            data-workspace-point={entry.workspace.point}
            class="border-t border-base-200 py-1 first:border-0 first:py-0"
          >
            <div class="flex items-center gap-1">
              <button
                type="button"
                phx-click="workspace_pick"
                phx-value-point={entry.workspace.point}
                disabled={@workspace_locked or @workspace_loading}
                title={gettext("Use this workspace's first available project")}
                class="assistant-menu-item min-w-0 flex-1"
              >
                <.icon name="hero-rectangle-stack" class="size-4" />
                <span class="truncate">{entry.workspace.name}</span>
                <span class="shrink-0 text-xs text-base-content/60">
                  {gettext("%{count} projects", count: length(entry.members))}
                </span>
                <span
                  :if={entry.missing != []}
                  class="shrink-0 text-xs text-warning"
                  title={Enum.map_join(entry.missing, ", ", &Workspace.member_label/1)}
                >{gettext("missing")}</span>
              </button>
              <button
                type="button"
                phx-click="workspace_expand"
                phx-value-point={entry.workspace.point}
                aria-expanded={to_string(expanded?(@workspace_expanded, entry.workspace.point))}
                aria-controls={"workspace-ws-members-" <> dom_id(entry.workspace.point)}
                title={gettext("Show projects")}
                class="assistant-menu-item shrink-0"
              >
                <.icon
                  name={
                    if expanded?(@workspace_expanded, entry.workspace.point),
                      do: "hero-chevron-up",
                      else: "hero-chevron-down"
                  }
                  class="size-4"
                />
              </button>
            </div>
            <ul
              :if={expanded?(@workspace_expanded, entry.workspace.point)}
              id={"workspace-ws-members-" <> dom_id(entry.workspace.point)}
              class="assistant-project-recent"
            >
              <li :for={member <- entry.members}>
                <button
                  type="button"
                  phx-click="workspace_select"
                  phx-value-path={member.path}
                  disabled={@workspace_locked or @workspace_loading}
                  title={member.path}
                  class="assistant-menu-item"
                >
                  <.icon name="hero-folder" class="size-4" /><span class="truncate">{member.name ||
                    member.path}</span>
                </button>
              </li>
              <li :for={ref <- entry.missing} class="assistant-project-path">
                {Workspace.member_label(ref)} — {gettext("missing on this node")}
              </li>
            </ul>
          </div>
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

  # A workspace selection shows BOTH identities: the workspace it is scoped to
  # and the concrete project it executes in (its first resolved member).
  defp current_label(%{kind: :workspace, name: name} = workspace) do
    gettext("Workspace %{workspace} · %{project}",
      workspace: name,
      project: workspace.members |> List.first() |> member_name(workspace.path)
    )
  end

  defp current_label(_workspace), do: gettext("Current project")

  defp member_name(%{name: name}, _path) when is_binary(name) and name != "", do: name
  defp member_name(_member, path), do: Path.basename(path)

  defp expanded?(%MapSet{} = expanded, point), do: MapSet.member?(expanded, point)
  defp expanded?(_expanded, _point), do: false

  # DOM-safe point spelling: no atom creation, no escaping surprises.
  defp dom_id(point) when is_binary(point),
    do: String.replace(point, ~r/[^A-Za-z0-9_-]+/, "-")

  defp dom_id(_point), do: "unknown"
end
