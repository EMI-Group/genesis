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
        <span class="text-sm font-medium text-slate-700 dark:text-slate-300 sidebar-label">
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
                {target[:ssh_target] || "#{target[:user]}#{maybe_at()}#{target[:host]}#{if(target[:port] && target[:port] != 22, do: ":#{target[:port]}", else: "")}"}
              </span>
            </span>
            <.icon :if={@current_node_id == target.id} name="hero-check-solid" class="size-4 text-indigo-500 shrink-0" />
          </button>

          <div class="my-1 border-t border-base-200"></div>

          <.link
            navigate={~p"/settings?category=remote_connections#{if @current_node_id, do: "&node=#{@current_node_id}", else: ""}"}
            class="flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
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

  defp dot_color_class(current_node_id, _statuses) when is_nil(current_node_id) do
    "w-2 h-2 rounded-full bg-emerald-500"
  end

  defp dot_color_class(current_node_id, statuses) do
    target_dot_color(current_node_id, statuses)
  end

  # Returns the Tailwind class for a target's status dot.
  defp target_dot_color(target_id, statuses) do
    status_map = Map.get(statuses, target_id, %{})
    phase = Map.get(status_map, :phase, :disconnected)

    case phase do
      :connected -> "bg-blue-500"
      :connecting -> "bg-amber-500 animate-pulse"
      :disconnecting -> "bg-amber-500 animate-pulse"
      :error -> "bg-rose-500"
      :disconnected -> "bg-slate-400"
      _ -> "bg-slate-400"
    end
  end

  defp maybe_at, do: "@"
end
