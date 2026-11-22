defmodule EvoDashWeb.ProjectWindow do
  @moduledoc false
  use EvoDashWeb, :live_component

  alias EvoDash.ProjectDirectories
  alias EvoDashWeb.WorkbenchComponent

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       mode: "create",
       location: "",
       directory: nil,
       target: nil,
       prepared: false,
       loading: false,
       busy: false,
       name: "",
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.prepared do
      {:ok, resolve_location(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        project_form: to_form(%{"name" => assigns.name}),
        location_form: to_form(%{"location" => assigns.location}),
        path_form: to_form(%{"path" => ""})
      )

    ~H"""
    <div id={@id}>
      <dialog
        id="workbench-project-window"
        class="workbench-window workbench-project-window"
        aria-labelledby="workbench-project-window-title"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <header class="workbench-window-header">
          <h2 id="workbench-project-window-title">
            {if @mode == "create",
              do: gettext("Create New Project"),
              else: gettext("Open Existing Project")}
          </h2>
          <button
            type="button"
            class="workbench-icon-button"
            data-workbench-close-window
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>
        <div class="workbench-window-body project-picker">
          <div class={["project-picker-fields", @mode == "create" && "has-name"]}>
            <.form
              :if={@mode == "create"}
              for={@project_form}
              id="workbench-project-form"
              phx-change="name_project"
              phx-submit="submit"
              phx-target={@myself}
            >
              <.input
                field={@project_form[:name]}
                id="workbench-project-name"
                type="text"
                label={gettext("Project name")}
                class="input w-full"
                maxlength="120"
                autocomplete="off"
                required
                disabled={@busy}
              />
            </.form>
            <.form
              for={@location_form}
              id="project-location-form"
              phx-change="select_location"
              phx-target={@myself}
            >
              <.input
                field={@location_form[:location]}
                id="project-location"
                label={gettext("Run on")}
                type="select"
                options={[{gettext("Local"), ""}] ++ Enum.map(@targets, &{&1.name, &1.id})}
                class="select w-full"
                disabled={@busy}
              />
            </.form>
          </div>

          <p :if={!@target && @prepared} class="project-picker-message">
            {gettext("Connect this Genesis server to browse its directories.")}
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="connect_location"
              phx-target={@myself}
              disabled={get_in(@statuses, [@location, :phase]) in [:connecting, :bootstrapping]}
            >
              {if get_in(@statuses, [@location, :phase]) in [:connecting, :bootstrapping],
                do: gettext("Connecting…"),
                else: gettext("Connect")}
            </button>
          </p>
          <div :if={@target} class="project-picker-directories">
            <label>{if @mode == "create",
              do: gettext("Parent directory"),
              else: gettext("Project directory")}</label>
            <div class="project-picker-path">
              <button
                type="button"
                phx-click="home"
                phx-target={@myself}
                class="workbench-icon-button"
                title={gettext("Home directory")}
                aria-label={gettext("Home directory")}
                disabled={@busy}
              >
                <.icon name="hero-home" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="up"
                phx-target={@myself}
                class="workbench-icon-button"
                title={gettext("Parent directory")}
                aria-label={gettext("Parent directory")}
                disabled={@busy || !(@directory && @directory.parent)}
              >
                <.icon name="hero-arrow-up" class="size-4" />
              </button>
              <span class="truncate text-xs font-mono" title={@directory && @directory.path}>
                {cond do
                  @directory -> @directory.path
                  @loading -> gettext("Loading…")
                  true -> gettext("No directory selected")
                end}
              </span>
            </div>
            <ul class="project-picker-list" role="list" aria-busy={@loading}>
              <li :if={@loading} class="project-picker-empty">{gettext("Loading…")}</li>
              <li
                :if={@directory && @directory.entries == [] && !@loading}
                class="project-picker-empty"
              >
                {gettext("No subdirectories")}
              </li>
              <li :for={entry <- (@directory && @directory.entries) || []} :if={!@loading}>
                <button
                  type="button"
                  phx-click="browse"
                  phx-value-path={entry.path}
                  phx-target={@myself}
                  class="workbench-row min-h-[var(--row-h)] text-sm"
                  disabled={@busy}
                >
                  <.icon name="hero-folder" class="size-4 shrink-0" />
                  <span class="truncate">{entry.name}</span>
                  <.icon name="hero-chevron-right" class="size-3 shrink-0 ml-auto" />
                </button>
              </li>
            </ul>
            <details class="project-picker-manual">
              <summary>{gettext("Enter a path")}</summary>
              <.form
                for={@path_form}
                id="project-picker-path-form"
                phx-submit="browse_path"
                phx-target={@myself}
              >
                <.input
                  field={@path_form[:path]}
                  id="project-picker-path"
                  type="text"
                  aria-label={gettext("Project path")}
                  class="input"
                  maxlength="4096"
                  required
                  disabled={@busy}
                />
                <button type="submit" class="btn btn-ghost btn-sm" disabled={@busy}>{gettext("Go")}</button>
              </.form>
            </details>
          </div>
          <p :if={@error} role="alert" class="workbench-window-error">{error_label(@error)}</p>
          <footer class="workbench-window-actions">
            <button type="button" class="btn btn-ghost btn-sm" data-workbench-close-window>{gettext(
              "Cancel"
            )}</button>
            <button
              :if={@mode == "create"}
              form="workbench-project-form"
              type="submit"
              class="btn btn-primary"
              disabled={!@directory || @busy || @loading}
            >
              {if @busy, do: gettext("Working…"), else: gettext("Create")}
            </button>
            <button
              :if={@mode == "open"}
              type="button"
              phx-click="open"
              phx-target={@myself}
              class="btn btn-primary"
              disabled={!@directory || @busy || @loading}
            >
              {if @busy, do: gettext("Working…"), else: gettext("Open project")}
            </button>
          </footer>
        </div>
      </dialog>
    </div>
    """
  end

  @impl true
  def handle_event("prepare", %{"mode" => mode}, socket) when mode in ["create", "open"] do
    if socket.assigns.busy do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> cancel_async(:browse)
       |> assign(
         mode: mode,
         location: socket.assigns.node_id || "",
         target: nil,
         prepared: true,
         directory: nil,
         name: "",
         error: nil,
         loading: false
       )
       |> resolve_location()}
    end
  end

  def handle_event("select_location", %{"location" => location}, socket) do
    if !socket.assigns.busy and
         (location == "" or Enum.any?(socket.assigns.targets, &(&1.id == location))) do
      {:noreply,
       socket
       |> cancel_async(:browse)
       |> assign(location: location, target: nil, loading: false, directory: nil, error: nil)
       |> resolve_location()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("connect_location", _, %{assigns: %{location: location, target: nil}} = socket)
      when location != "" do
    if Enum.any?(socket.assigns.targets, &(&1.id == location)) do
      {:noreply, EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, location)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("home", _, socket), do: {:noreply, browse(socket, :home)}

  def handle_event("up", _, socket) do
    case socket.assigns.directory do
      %{parent: parent} when is_binary(parent) -> {:noreply, browse(socket, parent)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("browse", %{"path" => path}, socket) do
    entries = (socket.assigns.directory && socket.assigns.directory.entries) || []
    {:noreply, if(Enum.any?(entries, &(&1.path == path)), do: browse(socket, path), else: socket)}
  end

  def handle_event("browse_path", %{"path" => path}, socket)
      when is_binary(path) and byte_size(path) <= 16_384,
      do: {:noreply, browse(socket, path)}

  def handle_event("name_project", %{"name" => name}, socket) when is_binary(name) do
    {:noreply, assign(socket, name: String.slice(name, 0, 120), error: nil)}
  end

  def handle_event("submit", %{"name" => name}, %{assigns: %{mode: "create"}} = socket)
      when is_binary(name) and byte_size(name) <= 480,
      do: {:noreply, submit(socket, name)}

  def handle_event("open", _, %{assigns: %{mode: "open"}} = socket),
    do: {:noreply, submit(socket, "")}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:browse, {:ok, {:ok, directory}}, socket),
    do: {:noreply, assign(socket, directory: directory, loading: false)}

  def handle_async(:browse, result, socket),
    do: {:noreply, assign(socket, loading: false, error: error_reason(result))}

  def handle_async(:project, {:ok, {:ok, project}}, socket) do
    path =
      WorkbenchComponent.navigation_path("/projects", project.node_id,
        project: project.path,
        wb_home: "1"
      )

    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_async(:project, result, socket),
    do: {:noreply, assign(socket, busy: false, error: error_reason(result))}

  defp resolve_location(socket) do
    %{location: location, statuses: statuses, target: previous} = socket.assigns
    target = WorkbenchComponent.target(node_id(location), statuses)

    cond do
      is_nil(target) and not is_nil(previous) ->
        socket |> cancel_async(:browse) |> assign(target: nil, directory: nil, loading: false)

      target && target != previous ->
        socket |> assign(:target, target) |> browse(:home)

      true ->
        socket
    end
  end

  defp node_id(""), do: nil
  defp node_id(id), do: id

  defp browse(%{assigns: %{target: target, busy: false}} = socket, path)
       when not is_nil(target) do
    socket
    |> cancel_async(:browse)
    |> assign(loading: true, error: nil)
    |> start_async(:browse, fn -> ProjectDirectories.browse(target, path) end)
  end

  defp browse(socket, _), do: socket

  defp submit(
         %{
           assigns: %{
             target: target,
             directory: %{path: path},
             busy: false,
             loading: false,
             location: location,
             mode: mode
           }
         } = socket,
         name
       )
       when not is_nil(target) do
    socket
    |> assign(busy: true, error: nil, name: name)
    |> start_async(:project, fn ->
      ProjectDirectories.mount(target, node_id(location), mode, path, name)
    end)
  end

  defp submit(socket, _), do: socket

  defp error_reason({:ok, {:error, reason}}), do: reason
  defp error_reason(_), do: :directory_unavailable

  defp error_label(:absolute_path_required), do: gettext("Enter a full directory path.")
  defp error_label(:invalid_name), do: gettext("Enter a project name without path separators.")

  defp error_label(:eexist),
    do: gettext("A directory with this name already exists. Open it as an existing project.")

  defp error_label(:eacces), do: gettext("Permission denied for this directory.")
  defp error_label(:mount_failed), do: gettext("Could not add project. Try again.")
  defp error_label(_), do: gettext("Could not read this directory on the selected server.")
end
