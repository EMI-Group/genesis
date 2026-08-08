defmodule EvoDashWeb.RemoteGateComponents do
  @moduledoc """
  Remote-connection gate components for the SSH Remote Development workflow.

  `remote_connection_gate/1` renders a full-page gate that replaces page data
  while a remote connection is being established or has failed. Callers invoke
  it fully qualified (it is NOT imported into `EvoDashWeb`), passing the full
  LiveView assigns:

      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        <EvoDashWeb.RemoteGateComponents.remote_connection_gate assigns={assigns} />
      <% end %>

  `gate_active?/1` is a pure predicate deciding whether the gate should be
  shown for a given assigns map (see its docs for the truth table).
  """

  # zh_CN: Connection → "连接", Retry → "重试"

  use EvoDashWeb, :html

  @connecting_phases [:connecting, :bootstrapping, :disconnecting]
  @error_phases [:error, :disconnected]
  @gating_phases @connecting_phases ++ @error_phases

  @doc """
  Renders the remote-connection gate:

  - **Connecting state** — `remote_status` is nil (node param set but
    `handle_params` hasn't resolved a status yet) or the phase is
    `:connecting` / `:bootstrapping` / `:disconnecting`: a centered spinner
    and a "Connecting to <name>…" message. No page data.
  - **Error state** — phase is `:error` or `:disconnected`: a prominent
    `alert-error` alert with the target name, the last error detail (falls
    back when `last_error` is nil), and three actions: Retry
    (`phx-click="retry_remote_connection"`), Manage Connections (navigates to
    the LOCAL settings page — deliberately without the node param), and
    Switch to Local (`phx-click="switch_to_local"`).
  - **Connected or local** — any other phase (or no attrs): renders nothing.
  """
  attr(:remote_status, :map, default: nil)
  attr(:name, :string, default: "Local")

  def remote_connection_gate(assigns) do
    ~H"""
    <%= if connecting_state?(@remote_status) do %>
      <div class="flex flex-col items-center justify-center gap-4 py-16">
        <span class="loading loading-spinner loading-lg text-primary"></span>
        <p class="text-sm text-base-content/60">
          {gettext("Connecting to %{name}…", name: @name)}
        </p>
      </div>
    <% else %>
      <%= if error_state?(@remote_status) do %>
        <div class="alert alert-error rounded-lg shadow-sm items-start">
          <div class="flex flex-col gap-3 w-full">
            <div class="flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
              <div class="flex-1 min-w-0">
                <p class="font-semibold text-sm">
                  {gettext("Cannot connect to %{name}", name: @name)}
                </p>
                <p class="text-xs opacity-90 mt-0.5">
                  {@remote_status[:last_error] || gettext("Connection lost or failed")}
                </p>
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <button phx-click="retry_remote_connection" class="btn btn-primary btn-sm">
                <.icon name="hero-arrow-path" class="size-4 mr-1" /> {gettext("Retry")}
              </button>
              <.link
                navigate={~p"/settings?category=remote_connections"}
                class="link link-hover text-sm"
              >
                {gettext("Manage Connections")}
              </.link>
              <button phx-click="switch_to_local" class="btn btn-ghost btn-sm">
                {gettext("Switch to Local")}
              </button>
            </div>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end

  @doc """
  Pure predicate: should the remote-connection gate replace page data?

  Truth table (pattern-matched, no try/rescue — an absent `remote_status`
  key is treated as nil via `Map.get/2`):

    - `current_node_id` nil → `false` (local).
    - `current_node_id` set AND `remote_status` nil → `true` (GUARD: never
      show page data in this edge case; default to the connecting state).
    - `current_node_id` set AND `remote_status.phase` in
      `[:connecting, :bootstrapping, :disconnecting, :error, :disconnected]`
      → `true`.
    - `current_node_id` set AND phase `:connected` → `false`.
    - Any other shape → `false`.
  """
  def gate_active?(assigns) when is_map(assigns) do
    gate_active?(Map.get(assigns, :current_node_id), Map.get(assigns, :remote_status))
  end

  def gate_active?(_), do: false

  defp gate_active?(nil, _remote_status), do: false

  defp gate_active?(_node_id, nil), do: true

  defp gate_active?(_node_id, %{phase: phase}) when phase in @gating_phases, do: true

  defp gate_active?(_node_id, %{phase: :connected}), do: false

  defp gate_active?(_node_id, _remote_status), do: false

  defp connecting_state?(nil), do: true

  defp connecting_state?(%{phase: phase}) when phase in @connecting_phases, do: true

  defp connecting_state?(_), do: false

  defp error_state?(%{phase: phase}) when phase in @error_phases, do: true

  defp error_state?(_), do: false
end
