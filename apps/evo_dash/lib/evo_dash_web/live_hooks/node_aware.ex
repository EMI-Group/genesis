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

  alias EvoGit.TaskRegistry

  @remote_connections_topic "remote_connections"
  @tasks_topic "tasks"

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
      |> assign_new(:running_tasks, fn -> [] end)
      |> assign_new(:pending_tasks, fn -> [] end)

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @remote_connections_topic)
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @tasks_topic)
    end

    # Load initial running/pending tasks for all live views
    socket = load_running_and_pending_tasks(socket)

    {:cont, socket}
  end

  @doc """
  Loads all tasks from EvoGit.TaskRegistry and assigns running/pending task lists
  to the socket. Same logic as DashboardLive.Assigns.assign_running_and_pending_tasks/1.
  """
  def load_running_and_pending_tasks(socket) do
    all_tasks = TaskRegistry.list_tasks()

    running_tasks =
      Enum.filter(all_tasks, &(&1.status in [:running, :pending, :finalizing]))

    pending_tasks =
      all_tasks
      |> Enum.filter(fn task ->
        task.status == :completed and is_nil(task.review_status) and
          show_review_button?(task)
      end)
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})

    socket
    |> Phoenix.Component.assign(:running_tasks, running_tasks)
    |> Phoenix.Component.assign(:pending_tasks, pending_tasks)
  end

  defp show_review_button?(%{status: :completed, result: {:ok, %{branch_name: branch}}})
       when is_binary(branch) and branch != "",
       do: true

  defp show_review_button?(_), do: false

  @doc """
  Resolves the `?node=` query param into node-context assigns.

  Called by each LiveView at the top of `handle_params/3`. When `node` is nil
  or `"local"`, the context falls back to the local BEAM node. When a target id
  is given, it is looked up via `EvoDash.NodeContext.get_target/1`; if the
  target exists AND is currently connected, the context is set to that target.
  If the target exists but is not yet connected, the context is "pending" —
  data comes from the local node but `@current_node_id` is preserved so that
  `handle_connection_status/2` can re-resolve once the connection completes.
  Unknown ids fall back to local.
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

      {:pending, target} ->
        # A known target that exists but isn't connected yet (e.g. a
        # connection was just initiated). Data still comes from the local node
        # until the connection completes, but we MUST preserve the target id in
        # `@current_node_id` so that `handle_connection_status/2` can match it
        # later and re-resolve `@current_node` to the remote BEAM node.
        socket
        |> assign(:current_node, node())
        |> assign(:current_node_name, target.name)
        |> assign(:current_node_id, node_param)
    end
  end

  # Resolves a node param string into `:local`, `{:remote, target_map,
  # remote_node_atom}`, or `{:pending, target_map}`.
  #
  # Falls back to `:local` for nil, "local", and unknown ids.
  # Returns `{:pending, target}` for known-but-disconnected targets so the
  # caller can preserve the target id until the connection completes.
  # Returns `{:remote, ...}` for connected targets whose connection manager has
  # reported a node name (the `:node` field is nil until distribution completes).
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
            # Known target that isn't connected yet — keep the target id so
            # `handle_connection_status` can re-resolve once connected.
            {:pending, target}
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
  refreshing the `@connection_statuses` assign. When the status change is for
  the currently selected node, it also re-resolves the node context so
  `@current_node` updates: switching from local to the remote BEAM node when
  the connection reaches `:connected`, or falling back to local on
  disconnect/error. Returns `{:noreply, socket}`.
  """
  def handle_connection_status(socket, {:remote_connection_status, target_id, status}) do
    socket = assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())

    # If the status change is for the currently selected node, re-resolve the
    # node context so @current_node updates. When the connection reaches
    # :connected, @current_node switches from local to the remote BEAM node.
    # When it disconnects/errors, fall back to local.
    current_node_id = socket.assigns[:current_node_id]

    socket =
      if current_node_id == target_id do
        case status do
          %{phase: :connected, node: remote_node} when is_binary(remote_node) ->
            assign(socket, :current_node, String.to_atom(remote_node))

          _ ->
            # Disconnected, connecting, error — fall back to local node context
            # so the page doesn't show stale remote data.
            socket
            |> assign(:current_node, node())
            |> assign(:current_node_name, "Local")
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # Fallback for unexpected message shapes — just refresh statuses.
  def handle_connection_status(socket, _message) do
    {:noreply, assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())}
  end

  @doc """
  Handles task-related PubSub messages by reloading running/pending tasks.
  Returns `{:noreply, socket}`.
  """
  def handle_task_info(socket, _message) do
    {:noreply, load_running_and_pending_tasks(socket)}
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
