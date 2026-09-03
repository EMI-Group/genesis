defmodule EvoDashWeb.NodeSelectorComponent do
  @moduledoc """
  Navbar node selector dropdown.

  Renders a compact button showing the current node (local or remote) with a
  status dot and a dropdown for switching nodes. A "Manage Connections..." link
  navigates to the Settings page's Remote Connections category for full
  connection management (add/edit/connect/disconnect/delete SSH remote targets).

  All domain operations delegate to `EvoDash.NodeContext`. When the user selects
  a node, this component sends `{:node_selected, node_id}` to the parent
  LiveView, which calls `NodeAware.handle_node_selected/2` to patch the URL.
  """

  use EvoDashWeb, :live_component

  import Phoenix.Component

  attr(:drop_up, :boolean, default: false)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <details class={["dropdown dropdown-start", @drop_up && "dropdown-top"]} id={"#{@id}-details"}>
      <summary
        class="btn btn-sm btn-ghost gap-2 rounded-lg hover:bg-base-200 transition-colors"
        title={gettext("Switch node")}
      >
        <span class={dot_color_class(@current_node_id, @connection_statuses)}></span>
        <span class="text-sm font-medium text-base-content/70 sidebar-label">
          {@current_node_name}
        </span>
      </summary>
      <div class={["dropdown-content z-50 w-72 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-2", (@drop_up && "mb-2") || "mt-2"]}>
        <div class="flex flex-col gap-0.5">
          <button
            class={[
              "flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer",
              is_nil(@current_node_id) && "bg-primary/10 text-primary",
              not is_nil(@current_node_id) && "hover:bg-base-200 text-base-content/70"
            ]}
            phx-click={JS.push("select_node", target: @myself, value: %{node: "local"})}
          >
            <span class={dot_color_class(nil, @connection_statuses)}></span>
            <span class="flex-1 text-left">{gettext("Local")}</span>
            <.icon :if={is_nil(@current_node_id)} name="hero-check-solid" class="size-4 text-primary shrink-0" />
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
              @current_node_id == target.id && "bg-primary/10 text-primary",
              @current_node_id != target.id && "hover:bg-base-200 text-base-content/70"
            ]}
            phx-click={JS.push("select_node", target: @myself, value: %{node: target.id})}
          >
            <span class={dot_color_class(target.id, @connection_statuses)}></span>
            <span class="flex-1 text-left">
              <span class="block">{target.name}</span>
              <span class="block text-xs text-base-content/50">
                {target[:ssh_target] || "#{target[:user]}#{maybe_at()}#{target[:host]}#{if(target[:port] && target[:port] != 22, do: ":#{target[:port]}", else: "")}"}
              </span>
            </span>
            <.icon :if={@current_node_id == target.id} name="hero-check-solid" class="size-4 text-primary shrink-0" />
          </button>

          <div class="my-1 border-t border-base-200"></div>

          <.link
            navigate={~p"/settings?category=remote_connections" <> (if @current_node_id, do: "&node=#{@current_node_id}", else: "")}
            class="flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-base-200 text-base-content/70"
          >
            <.icon name="hero-server-stack" class="size-4 shrink-0" />
            <span class="flex-1 text-left"><%= gettext("Manage Connections...") %></span>
          </.link>
        </div>
      </div>
    </details>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:remote_targets, EvoDash.NodeContext.list_targets())
      |> assign(:connection_statuses, EvoDash.NodeContext.connection_status())

    {:ok, socket}
  end

  # ── Event handlers ────────────────────────────────────────────────

  @impl true
  def handle_event("select_node", %{"node" => node_id}, socket) do
    # For a remote target that isn't connected yet, initiate the connection
    # asynchronously. The GenServer handles it in the background; the page
    # shows "connecting" status until the status broadcast triggers re-resolution.
    if node_id != "local" do
      unless EvoDash.NodeContext.connected?(node_id) do
        EvoDash.NodeContext.connect(node_id)
      end
    end

    # The parent LiveView handles navigation via :node_selected, which triggers
    # push_patch → handle_params → re-render. The re-render closes the dropdown.
    send(self(), {:node_selected, node_id})
    {:noreply, socket}
  end

  # ── handle_info: connection status broadcasts ─────────────────────
  #
  # Note: LiveComponents do not have handle_info. Connection-status broadcasts
  # (subscribed to by the parent LiveView via the NodeAware on_mount hook) are
  # handled by the parent's handle_info, which re-assigns @connection_statuses.
  # That triggers a re-render of the parent, calling this component's update/1,
  # which reloads statuses from EvoDash.NodeContext.

  # ── View helpers ──────────────────────────────────────────────────

  # Single shared dot renderer for the trigger AND the dropdown items: always
  # returns the full shape classes plus the shared phase-appropriate color
  # (`EvoDashWeb.Helpers.connection_status_dot_class/1` owns the phase → color
  # mapping), so the trigger dot is never reduced to a color-only (invisible)
  # span. Pulse is applied here for the connecting phases.
  defp dot_color_class(nil, _statuses), do: dot_shape(:local)

  defp dot_color_class(target_id, statuses) do
    dot_shape(remote_phase(target_id, statuses))
  end

  defp dot_shape(phase) do
    pulse = if phase in [:connecting, :disconnecting], do: " animate-pulse", else: ""
    "w-2 h-2 rounded-full shrink-0 " <> connection_status_dot_class(phase) <> pulse
  end

  defp remote_phase(target_id, statuses) do
    statuses |> Map.get(target_id, %{}) |> Map.get(:phase, :disconnected)
  end

  defp maybe_at, do: "@"
end
