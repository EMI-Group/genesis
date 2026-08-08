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
      |> assign_new(:tasks_reload_pending, fn -> false end)

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @remote_connections_topic)
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @tasks_topic)
    end

    # Load initial running/pending tasks for all live views
    socket = load_running_and_pending_tasks(socket)

    # Seed the node-context dedup guard with the local context so the first
    # `handle_params` → `assign_node/2` call doesn't double-fetch the sidebar
    # (kills the mount double-fetch: on_mount already loaded local tasks).
    socket = assign(socket, :tasks_node_loaded, {nil, node()})

    {:cont, socket}
  end

  @doc """
  Loads running/pending tasks plus the pad top bar's awaiting-review count
  and assigns them to the socket.

  Node-aware: when `@current_node` is the local BEAM node, tasks are read from
  the local `EvoGit.TaskRegistry`; when it is a remote node, tasks are fetched
  via `EvoDash.NodeContext.list_tasks_summary/2` (RPC). The filtering logic is
  identical either way — only the source of `all_tasks` changes.

  The fetch is statuses-filtered: only `[:running, :pending, :finalizing,
  :completed]` are loaded (`pending_tasks` review candidates are derived from
  `:completed`), so the SQL query skips finished tasks that can never appear.

  Uses lightweight summary queries that omit heavy JSON fields (logs, usage,
  archive_metadata) unnecessary for these displays.
  """
  def load_running_and_pending_tasks(socket) do
    current_node = socket.assigns[:current_node] || node()

    all_tasks =
      if current_node == node() do
        TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :completed])
      else
        EvoDash.NodeContext.list_tasks_summary(current_node, [
          :running,
          :pending,
          :finalizing,
          :completed
        ])
      end

    running_tasks =
      Enum.filter(all_tasks, &(&1.status in [:running, :pending, :finalizing]))

    pending_tasks =
      all_tasks
      |> Enum.filter(fn task ->
        task.status == :completed and is_nil(task.review_status) and
          show_review_button?(task)
      end)
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})

    # The pad top bar's awaiting-review badge — the same set ReviewsLive
    # shows as "Waiting for you" (completed + non-empty branch + no review
    # decision). Kept fresh on every debounced reload for every LiveView.
    review_count = Enum.count(all_tasks, &EvoDashWeb.PadComponents.awaiting_review?/1)

    socket
    |> Phoenix.Component.assign(:running_tasks, running_tasks)
    |> Phoenix.Component.assign(:pending_tasks, pending_tasks)
    |> Phoenix.Component.assign(:review_count, review_count)
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

    socket =
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

    # Reload sidebar tasks from the (possibly changed) node so the "Active
    # Tasks" section always reflects the node being viewed. This runs on every
    # `handle_params` call, including node switches.
    #
    # Dedup guard: skip the reload when the node context hasn't changed since
    # the last `handle_params` call (e.g. on_mount already loaded local tasks,
    # or a pagination push_patch re-runs with the same node). Node switches
    # (local↔remote, pending→connected) still reload since the context tuple
    # differs.
    context = {socket.assigns[:current_node_id], socket.assigns[:current_node]}

    if Map.get(socket.assigns, :tasks_node_loaded) == context do
      socket
    else
      socket
      |> load_running_and_pending_tasks()
      |> Phoenix.Component.assign(:tasks_node_loaded, context)
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
  the currently selected node AND represents a meaningful local↔remote
  transition, it triggers a `push_patch` to the current path (preserving the
  `?node=` param) so that `handle_params/3` re-runs and reloads all
  page-specific node data (remote agents, remote config, remote paused state,
  etc.). This is the DRYest solution: `handle_params` already contains all the
  node-specific data loading for every LiveView, so re-running it uniformly
  reloads everything correctly without per-page duplication.

  Only actual transitions trigger a `push_patch`:
    * `:connected` with a node name → local→remote (the node just became
      usable as remote). Only a transition when `@current_node` is currently
      local (`node()`), i.e. the page was showing pending/local data.
    * `:disconnected` / `:error` → remote→local (the node was remote but is
      now gone). Only a transition when `@current_node` is currently NOT
      local, i.e. the page was showing remote data.

  Non-transition statuses (`:connecting`, `:bootstrapping`, or a status for a
  node already in the correct state, or a status for a non-selected node) only
  refresh `@connection_statuses` and do NOT reload page data. Returns
  `{:noreply, socket}`.
  """
  def handle_connection_status(socket, {:remote_connection_status, target_id, status}) do
    socket = assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())

    current_node_id = socket.assigns[:current_node_id]
    current_node = socket.assigns[:current_node]

    transition? =
      current_node_id == target_id and
        case status do
          %{phase: :connected, node: remote_node} when is_binary(remote_node) ->
            # local → remote: only a transition when the page is currently
            # showing local/pending data (a duplicate :connected for a node
            # already in remote state is not a reload-worthy transition).
            current_node == node()

          %{phase: phase} when phase in [:disconnected, :error] ->
            # remote → local: only a transition when the page is currently
            # showing remote data (a disconnect/error for a node already
            # showing local/pending data is not a reload-worthy transition).
            current_node != node()

          # :connecting, :bootstrapping, and other phases are not reload-worthy
          # transitions — the page is already showing local/pending data.
          _ ->
            false
        end

    if transition? do
      # Re-invoke handle_params by patching the current path with the ?node=
      # param. handle_params calls assign_node → resolve_node_context, which
      # now resolves to {:remote, ...} (on :connected) or :local (on
      # disconnect/error), and then reloads all page-specific data.
      path = socket.assigns[:current_path] || "/"
      to = path <> "?node=" <> current_node_id
      {:noreply, Phoenix.LiveView.push_patch(socket, to: to)}
    else
      {:noreply, socket}
    end
  end

  # Fallback for unexpected message shapes — just refresh statuses.
  def handle_connection_status(socket, _message) do
    {:noreply, assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())}
  end

  @doc """
  Handles task-related PubSub messages by scheduling a debounced reload of
  running/pending tasks. Returns `{:noreply, socket}`.

  Uses a trailing-edge debounce (300ms via `:node_aware_reload_tasks`) to
  coalesce broadcast bursts into a single reload: intermediate broadcasts
  while a reload is already pending are dropped.
  """
  def handle_task_info(socket, _message) do
    {:noreply, debounce_task_reload(socket)}
  end

  @doc """
  Trailing-edge debounce for task reloads. When a reload is already scheduled
  (`:tasks_reload_pending` is truthy), intermediate broadcasts are dropped and
  the socket is returned unchanged. Otherwise schedules
  `:node_aware_reload_tasks` after 300ms and sets `:tasks_reload_pending`.
  LiveViews handle the `:node_aware_reload_tasks` message by calling
  `reload_tasks/1`. Returns the socket.
  """
  def debounce_task_reload(socket) do
    if Map.get(socket.assigns, :tasks_reload_pending, false) do
      # A reload is already scheduled — drop this intermediate broadcast.
      socket
    else
      Process.send_after(self(), :node_aware_reload_tasks, 300)
      Phoenix.Component.assign(socket, :tasks_reload_pending, true)
    end
  end

  @doc """
  Executes the debounced task reload: reloads running/pending tasks from the
  current node and clears the `:tasks_reload_pending` flag. Returns the socket.
  """
  def reload_tasks(socket) do
    socket
    |> load_running_and_pending_tasks()
    |> Phoenix.Component.assign(:tasks_reload_pending, false)
  end

  @doc """
  Clears the `:tasks_reload_pending` flag without reloading. Returns the
  socket. Used by LiveViews that perform their own custom reload instead of
  calling `reload_tasks/1`.
  """
  def clear_task_reload_pending(socket) do
    Phoenix.Component.assign(socket, :tasks_reload_pending, false)
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
