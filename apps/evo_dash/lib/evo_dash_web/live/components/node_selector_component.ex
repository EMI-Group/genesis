defmodule EvoDashWeb.NodeSelectorComponent do
  @moduledoc """
  Navbar node selector dropdown + connection manager modal.

  Renders a compact button showing the current node (local or remote) with a
  status dot, a dropdown for switching nodes, and a full connection-manager
  modal for adding/editing/connecting/disconnecting/deleting SSH remote targets.

  All domain operations delegate to `EvoDash.NodeContext`. When the user selects
  a node, this component sends `{:node_selected, node_id}` to the parent
  LiveView, which calls `NodeAware.handle_node_selected/2` to patch the URL.
  """

  use EvoDashWeb, :live_component

  import Phoenix.Component

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <details class="dropdown dropdown-start" id={"#{@id}-details"}>
      <summary
        class="btn btn-sm btn-ghost gap-2 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        title={gettext("Switch node")}
      >
        <span class={dot_color_class(@current_node_id, @connection_statuses)}></span>
        <span class="text-sm font-medium text-slate-700 dark:text-slate-300">
          {@current_node_name}
        </span>
      </summary>
      <div class="dropdown-content mt-2 z-50 w-72 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-2">
        <div class="flex flex-col gap-0.5">
          <button
            class={[
              "flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer",
              is_nil(@current_node_id) &&
                "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300",
              not is_nil(@current_node_id) &&
                "hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            ]}
            phx-click={JS.push("select_node", target: @myself, value: %{node: "local"})}
          >
            <span class="w-2 h-2 rounded-full bg-emerald-500 shrink-0"></span>
            <span class="flex-1 text-left">{gettext("Local")}</span>
            <.icon :if={is_nil(@current_node_id)} name="hero-check-solid" class="size-4 text-indigo-500 shrink-0" />
          </button>

          <div
            :if={@remote_targets != []}
            class="my-1 border-t border-base-200"
          >
          </div>

          <button
            :for={target <- @remote_targets}
            class={[
              "flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer",
              @current_node_id == target.id &&
                "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300",
              @current_node_id != target.id &&
                "hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            ]}
            phx-click={JS.push("select_node", target: @myself, value: %{node: target.id})}
          >
            <span class={["w-2 h-2 rounded-full shrink-0", target_dot_color(target.id, @connection_statuses)]}></span>
            <span class="flex-1 text-left">
              <span class="block">{target.name}</span>
              <span class="block text-xs text-base-content/50">
                {target.user}{maybe_at()}{target.host}{if(target.port && target.port != 22, do: ":#{target.port}", else: "")}
              </span>
            </span>
            <.icon :if={@current_node_id == target.id} name="hero-check-solid" class="size-4 text-indigo-500 shrink-0" />
          </button>

          <div class="my-1 border-t border-base-200"></div>

          <button
            class="flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            phx-click="toggle_manager"
            phx-target={@myself}
          >
            <.icon name="hero-server-stack" class="size-4 shrink-0" />
            <span class="flex-1 text-left">{gettext("Manage Connections...")}</span>
          </button>
        </div>
      </div>
    </details>

    <%= if @show_manager do %>
      <dialog
        class="modal"
        id={"#{@id}-manager-dialog"}
        phx-hook="DialogModal"
      >
        <div class="modal-box max-w-2xl rounded-xl">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-bold">{gettext("Remote Connections")}</h3>
            <button
              class="btn btn-sm btn-circle btn-ghost"
              phx-click="toggle_manager"
              phx-target={@myself}
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <div class="max-h-[60vh] overflow-y-auto space-y-4">
            <%!-- Existing targets --%>
            <div :if={@remote_targets != []} class="space-y-2">
              <div :for={target <- @remote_targets} class="border border-base-200 rounded-xl p-3">
                <div class="flex items-start justify-between gap-2">
                  <div class="flex items-center gap-2 min-w-0">
                    <span class={["w-2.5 h-2.5 rounded-full shrink-0", target_dot_color(target.id, @connection_statuses)]}></span>
                    <div class="min-w-0">
                      <p class="font-semibold text-sm truncate">{target.name}</p>
                      <p class="text-xs text-base-content/50 font-mono truncate">
                        {target.user}{maybe_at()}{target.host}{if(target.port && target.port != 22, do: ":#{target.port}", else: "")}
                      </p>
                    </div>
                  </div>
                  <span class={status_badge_class(target.id, @connection_statuses)}>
                    {status_label(target.id, @connection_statuses)}
                  </span>
                </div>

                <div class="flex items-center gap-1 mt-2 flex-wrap">
                  <button
                    class="btn btn-xs btn-ghost gap-1"
                    phx-click="edit_target"
                    phx-target={@myself}
                    phx-value-id={target.id}
                  >
                    <.icon name="hero-pencil-square" class="size-3.5" />
                    {gettext("Edit")}
                  </button>
                  <button
                    class="btn btn-xs btn-ghost gap-1"
                    phx-click="delete_target"
                    phx-target={@myself}
                    phx-value-id={target.id}
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                    {gettext("Delete")}
                  </button>
                  <div class="flex-1"></div>
                  <%= if connected?(target.id, @connection_statuses) do %>
                    <button
                      class="btn btn-xs btn-ghost gap-1 text-warning"
                      phx-click="disconnect_target"
                      phx-target={@myself}
                      phx-value-id={target.id}
                    >
                      <.icon name="hero-arrow-left-end-on-rectangle" class="size-3.5" />
                      {gettext("Disconnect")}
                    </button>
                  <% else %>
                    <button
                      class="btn btn-xs btn-ghost gap-1"
                      phx-click="bootstrap_target"
                      phx-target={@myself}
                      phx-value-id={target.id}
                    >
                      <.icon name="hero-rocket-launch" class="size-3.5" />
                      {gettext("Bootstrap")}
                    </button>
                    <button
                      class="btn btn-xs btn-primary gap-1"
                      phx-click="connect_target"
                      phx-target={@myself}
                      phx-value-id={target.id}
                    >
                      <.icon name="hero-arrow-right-end-on-rectangle" class="size-3.5" />
                      {gettext("Connect")}
                    </button>
                  <% end %>
                </div>
              </div>
            </div>

            <div :if={@remote_targets == []} class="text-center py-6 text-base-content/50">
              <.icon name="hero-server-stack" class="size-10 mx-auto mb-2 opacity-40" />
              <p class="text-sm">{gettext("No remote connections configured.")}</p>
            </div>

            <%!-- Add / Edit target form --%>
            <div class="border-t border-base-200 pt-4">
              <%= if @form_target do %>
                <h4 class="font-semibold text-sm mb-3">
                  <%= if @form_target[:id] do %>
                    {gettext("Edit Connection")}
                  <% else %>
                    {gettext("Add Connection")}
                  <% end %>
                </h4>
                <form phx-submit="save_target" phx-target={@myself} class="space-y-3">
                  <input type="hidden" name="_id" value={@form_target[:id]} />
                  <div class="grid grid-cols-2 gap-3">
                    <div class="form-control col-span-2">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("Name")}</span>
                      </label>
                      <input
                        type="text"
                        name="name"
                        value={@form_target[:name]}
                        placeholder={gettext("e.g. dev-server")}
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("Host")}</span>
                      </label>
                      <input
                        type="text"
                        name="host"
                        value={@form_target[:host]}
                        placeholder="192.168.1.10"
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("User")}</span>
                      </label>
                      <input
                        type="text"
                        name="user"
                        value={@form_target[:user]}
                        placeholder={gettext("e.g. ubuntu")}
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("SSH Port")}</span>
                      </label>
                      <input
                        type="number"
                        name="port"
                        value={@form_target[:port] || 22}
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("Dist Port")}</span>
                      </label>
                      <input
                        type="number"
                        name="dist_port"
                        value={@form_target[:dist_port]}
                        placeholder="9100"
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control col-span-2">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("Identity File")}</span>
                      </label>
                      <input
                        type="text"
                        name="identity_file"
                        value={@form_target[:identity_file]}
                        placeholder="~/.ssh/id_rsa"
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control col-span-2">
                      <label class="label">
                        <span class="label-text font-semibold text-xs">{gettext("Remote Path")}</span>
                      </label>
                      <input
                        type="text"
                        name="remote_path"
                        value={@form_target[:remote_path]}
                        placeholder="~/genesis"
                        class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                      />
                    </div>
                  </div>
                  <div class="flex items-center justify-end gap-2 pt-1">
                    <button
                      type="button"
                      class="btn btn-ghost btn-sm rounded-lg"
                      phx-click="cancel_edit"
                      phx-target={@myself}
                    >
                      {gettext("Cancel")}
                    </button>
                    <button type="submit" class="btn btn-primary btn-sm rounded-lg">
                      <%= if @form_target[:id] do %>
                        {gettext("Save")}
                      <% else %>
                        {gettext("Add")}
                      <% end %>
                    </button>
                  </div>
                </form>
              <% else %>
                <button
                  class="btn btn-ghost btn-sm gap-2 w-full border border-dashed border-base-300 rounded-lg"
                  phx-click="add_target"
                  phx-target={@myself}
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Add Connection")}
                </button>
              <% end %>
            </div>
          </div>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>{gettext("close")}</button>
        </form>
      </dialog>
    <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    targets = EvoDash.NodeContext.list_targets()
    statuses = EvoDash.NodeContext.connection_status()

    socket =
      socket
      |> assign(assigns)
      |> assign(:remote_targets, targets)
      |> assign(:connection_statuses, statuses)
      |> assign_new(:show_manager, fn -> false end)
      |> assign_new(:form_target, fn -> nil end)

    {:ok, socket}
  end

  # ── Event handlers ────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_manager", _params, socket) do
    {:noreply, assign(socket, :show_manager, not socket.assigns.show_manager)}
  end

  # Called by the DialogModal JS hook when the user dismisses the dialog
  # natively (ESC key or backdrop click). Syncs server state.
  def handle_event("dialog_closed", _params, socket) do
    {:noreply, assign(socket, :show_manager, false)}
  end

  def handle_event("select_node", %{"node" => node_id}, socket) do
    # The parent LiveView handles navigation via :node_selected, which triggers
    # push_patch → handle_params → re-render. The re-render closes the dropdown.
    send(self(), {:node_selected, node_id})
    {:noreply, socket}
  end

  def handle_event("add_target", _params, socket) do
    {:noreply, assign(socket, :form_target, empty_form_target())}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :form_target, nil)}
  end

  def handle_event("edit_target", %{"id" => id}, socket) do
    form_target =
      case EvoDash.NodeContext.get_target(id) do
        {:ok, target} -> target
        {:error, :not_found} -> nil
      end

    {:noreply, assign(socket, :form_target, form_target)}
  end

  def handle_event("save_target", params, socket) do
    target = build_target_from_params(params)

    case EvoDash.NodeContext.save_target(target) do
      {:ok, _saved} ->
        socket =
          socket
          |> assign(:form_target, nil)
          |> put_flash(:info, gettext("Connection saved."))
          |> reload_targets()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("delete_target", %{"id" => id}, socket) do
    case EvoDash.NodeContext.delete_target(id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, gettext("Connection deleted."))
          |> reload_targets()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Connection not found."))}
    end
  end

  def handle_event("bootstrap_target", %{"id" => id}, socket) do
    result = EvoDash.NodeContext.bootstrap(id)
    socket = socket |> reload_statuses() |> flash_lifecycle_result(result, gettext("Bootstrap"))
    {:noreply, socket}
  end

  def handle_event("connect_target", %{"id" => id}, socket) do
    result = EvoDash.NodeContext.connect(id)
    socket = socket |> reload_statuses() |> flash_lifecycle_result(result, gettext("Connect"))
    {:noreply, socket}
  end

  def handle_event("disconnect_target", %{"id" => id}, socket) do
    result = EvoDash.NodeContext.disconnect(id)
    socket = socket |> reload_statuses() |> flash_lifecycle_result(result, gettext("Disconnect"))
    {:noreply, socket}
  end

  # ── handle_info: connection status broadcasts ─────────────────────
  #
  # Note: LiveComponents do not have handle_info. Connection-status broadcasts
  # (subscribed to by the parent LiveView via the NodeAware on_mount hook) are
  # handled by the parent's handle_info, which re-assigns @connection_statuses.
  # That triggers a re-render of the parent, calling this component's update/1,
  # which reloads statuses from EvoDash.NodeContext.

  # ── Private helpers ───────────────────────────────────────────────

  defp reload_targets(socket) do
    assign(socket, :remote_targets, EvoDash.NodeContext.list_targets())
  end

  defp reload_statuses(socket) do
    assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())
  end

  defp empty_form_target do
    %{port: 22}
  end

  # Builds an atom-keyed target map from form params.
  # Generates a new id from the name when creating; preserves existing id when editing.
  defp build_target_from_params(params) do
    id = params["_id"]

    id =
      if id && id != "" do
        id
      else
        generate_id(params["name"])
      end

    %{
      id: id,
      name: params["name"] || "",
      host: params["host"] || "",
      user: params["user"] || "",
      port: parse_port(params["port"]),
      dist_port: parse_port(params["dist_port"]),
      identity_file: params["identity_file"] || "",
      remote_path: params["remote_path"] || ""
    }
  end

  defp parse_port(nil), do: nil
  defp parse_port(""), do: nil

  defp parse_port(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_port(num) when is_integer(num), do: num

  # Sanitizes a target name into a safe id slug (lowercase, hyphenated).
  # Falls back to a timestamp-based id when the name produces an empty slug.
  defp generate_id(nil), do: generate_id("")

  defp generate_id(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "" do
      "target-#{System.system_time(:second)}"
    else
      slug
    end
  end

  defp flash_lifecycle_result(socket, result, action) do
    case result do
      {:error, :remote_connection_unavailable} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} unavailable — the remote connection subsystem is not running.", action: action)
        )

      :ok ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:ok, _} ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:error, reason} ->
        put_flash(socket, :error, gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason)))

      _other ->
        put_flash(socket, :info, gettext("%{action} completed.", action: action))
    end
  end

  # ── View helpers ──────────────────────────────────────────────────

  defp dot_color_class(current_node_id, _statuses) when is_nil(current_node_id) do
    "w-2 h-2 rounded-full bg-emerald-500"
  end

  defp dot_color_class(current_node_id, statuses) do
    target_dot_color(current_node_id, statuses)
  end

  # Returns the Tailwind class for a target's status dot.
  defp target_dot_color(target_id, statuses) do
    status = Map.get(statuses, target_id, :disconnected)

    case status do
      :connected -> "bg-emerald-500"
      :connecting -> "bg-amber-500 animate-pulse"
      :disconnecting -> "bg-amber-500 animate-pulse"
      :error -> "bg-rose-500"
      :disconnected -> "bg-slate-400"
      _ -> "bg-slate-400"
    end
  end

  defp connected?(target_id, statuses) do
    Map.get(statuses, target_id, :disconnected) == :connected
  end

  defp status_badge_class(target_id, statuses) do
    status = Map.get(statuses, target_id, :disconnected)

    case status do
      :connected -> "badge badge-success badge-sm"
      :connecting -> "badge badge-warning badge-sm"
      :disconnecting -> "badge badge-warning badge-sm"
      :error -> "badge badge-error badge-sm"
      :disconnected -> "badge badge-ghost badge-sm"
      _ -> "badge badge-ghost badge-sm"
    end
  end

  defp status_label(target_id, statuses) do
    status = Map.get(statuses, target_id, :disconnected)

    case status do
      :connected -> gettext("Connected")
      :connecting -> gettext("Connecting...")
      :disconnecting -> gettext("Disconnecting...")
      :error -> gettext("Error")
      :disconnected -> gettext("Disconnected")
      _ -> gettext("Unknown")
    end
  end

  defp maybe_at, do: "@"
end
