defmodule EvoDashWeb.LiveHooks.NodeAware do
  @moduledoc """
  On-mount hook and helpers for node-aware navigation in the dashboard.

  This module provides the "spatial" glue for SSH Remote Development (Phase 2):
  it reads the `?node=` query param, resolves it to a saved connection target,
  and exposes the current node context (`@current_node`, `@current_node_name`,
  `@current_node_id`) to every LiveView and the shared layout.

  The domain foundation lives in `EvoDash.NodeContext` — this module only calls
  it, never modifies it.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  @remote_connections_topic "remote_connections"

  @doc """
  On-mount hook — sets initial node-context assigns and subscribes to
  connection-status broadcasts when the LiveView socket is connected.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign_new(:current_node, fn -> node() end)
      |> assign_new(:current_node_name, fn -> "Local" end)
      |> assign_new(:current_node_id, fn -> nil end)
      |> assign_new(:remote_targets, fn -> EvoDash.NodeContext.list_targets() end)
      |> assign_new(:connection_statuses, fn -> EvoDash.NodeContext.connection_status() end)

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @remote_connections_topic)
    end

    {:cont, socket}
  end

  @doc """
  Resolves the `?node=` query param into node-context assigns.

  Called by each LiveView at the top of `handle_params/3`. When `node` is nil
  or `"local"`, the context falls back to the local BEAM node. When a target id
  is given, it is looked up via `EvoDash.NodeContext.get_target/1`; if the
  target exists AND is currently connected, the context is set to that target.
  Otherwise it falls back to local.
  """
  def assign_node(socket, params) do
    node_param = params["node"]

    case resolve_node_context(node_param) do
      :local ->
        socket
        |> assign(:current_node, node())
        |> assign(:current_node_name, "Local")
        |> assign(:current_node_id, nil)

      {:remote, target, remote_node} ->
        # The remote BEAM node name is resolved from the connection manager's
        # status map (`:node` field, e.g. "genesis_remote@127.0.0.1"). We store
        # it as an atom so `EvoDash.NodeContext.list_agents(@current_node)`
        # routes `:erpc.call/5` to the correct node.
        socket
        |> assign(:current_node, remote_node)
        |> assign(:current_node_name, target.name)
        |> assign(:current_node_id, node_param)
    end
  end

  # Resolves a node param string into `:local` or
  # `{:remote, target_map, remote_node_atom}`.
  #
  # Falls back to `:local` for nil, "local", unknown ids, disconnected targets,
  # or connected targets whose connection manager has not yet reported a node
  # name (the `:node` field is nil until distribution completes).
  defp resolve_node_context(nil), do: :local
  defp resolve_node_context("local"), do: :local

  defp resolve_node_context(node_param) do
    case EvoDash.NodeContext.get_target(node_param) do
      {:ok, target} ->
        # `connection_status/1` returns `%{phase:, node:, ...}` when the
        # connection manager is running, or `:disconnected` (an atom) when the
        # connection subsystem is unavailable. Pattern match handles both.
        case EvoDash.NodeContext.connection_status(target.id) do
          %{phase: :connected, node: remote_node} when is_binary(remote_node) ->
            {:remote, target, String.to_atom(remote_node)}

          _ ->
            :local
        end

      {:error, :not_found} ->
        :local
    end
  end

  @doc """
  Returns the display name for the current node from a map of assigns.

  Falls back to `"Local"` when the assign is absent.
  """
  def current_node_display_name(assigns) do
    Map.get(assigns, :current_node_name) || "Local"
  end

  @doc """
  Builds the `?node=` query-string suffix for the current node context.

  Returns `""` when on the local node, otherwise `"?node=<id>"`.
  """
  def node_query_param(assigns) do
    case Map.get(assigns, :current_node_id) do
      nil -> ""
      id -> "?node=" <> id
    end
  end

  @doc """
  Handles a `{:remote_connection_status, _target_id, _status}` broadcast by
  refreshing the `@connection_statuses` assign. Returns `{:noreply, socket}`.
  """
  def handle_connection_status(socket, _message) do
    {:noreply, assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())}
  end

  @doc """
  Builds a `push_patch` to the current page path with the `?node=` param,
  triggering a re-render via `handle_params`.

  Each LiveView should set the `@current_path` assign (e.g. `~p"/"`,
  `~p"/agents"`) so this helper can build the correct URL.
  """
  def handle_node_selected(socket, node_id) do
    path = socket.assigns[:current_path] || "/"
    to = if node_id == "local", do: path, else: path <> "?node=" <> node_id
    {:noreply, Phoenix.LiveView.push_patch(socket, to: to)}
  end
end
