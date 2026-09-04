defmodule EvoDashWeb.LiveHooks.NodeAware do
  @moduledoc """
  On-mount hook and helpers for node-aware navigation in the dashboard.

  This module provides the "spatial" glue for SSH Remote Development (Phase 2):
  it reads the `?node=` query param, resolves it to a saved connection target,
  and exposes the current node context (`@current_node`, `@current_node_name`,
  `@current_node_id`, `@remote_status`) to every LiveView and the shared layout.

  The domain foundation lives in `EvoDash.NodeContext` — this module only calls
  it, never modifies it.

  ## Unified sidebar "Active Tasks" loader (ASYNC + hub-seeded)

  This module is the SINGLE implementation of the sidebar Active Tasks loading
  for the whole dashboard (ProjectsLive's old `Assigns.assign_running_and_pending_tasks/1`
  duplicate was removed). The load is ASYNC so a remote node's `:erpc`-routed
  fetch (up to 30s) never blocks the LiveView process, and the in-memory
  `EvoDash.ActiveTasks` hub (keyed `{node_id, node}` per node context) makes
  page navigation blink-free: every remounting LiveView seeds
  `:running_tasks`/`:pending_tasks` synchronously from the hub's last-known
  snapshot for its node context instead of flashing empty.

  On mount (`on_mount/4`), the lists are seeded from the hub for the node
  context the page WILL have once `handle_params` → `assign_node/2` runs
  (on_mount runs BEFORE handle_params, so mount-time assigns would otherwise
  default to the local context). The context is resolved from `params["node"]`
  via `resolve_node_context/1` and keyed exactly like hub snapshots: local →
  `{nil, node()}`, remote → `{node_param, remote_node}`, pending →
  `{node_param, node()}`. A remote page therefore seeds the REMOTE hub key (or
  `[]` when cold) — never the local key, so local tasks cannot leak into a
  remote view.

  The connected-mount fetch is CONDITIONAL: it fires only for a cold LOCAL
  context (`{nil, node()}` with no hub snapshot). The mount-time fetch spawns
  with the socket's default LOCAL assigns (`assign_node/2` hasn't run yet), so
  it is only meaningful for local pages; remote/pending pages NEVER fetch on
  mount — `assign_node/2`'s existing context-change reload (dedup-guard seeded
  `{nil, node()}` on both mount paths) is guaranteed to fire the correct remote
  fetch on the first `handle_params`, and a warm remote hub makes that first
  render instant (the reload heals any gap). A warm local page skips the mount
  query too — it renders last-known state and the push-based PubSub cycle keeps
  it fresh.

  The fetch machinery: `load_running_and_pending_tasks/1` / `assign_active_tasks/1` /
  `reload_tasks/1` capture the view pid, the node context, and the next
  `:tasks_load_seq` value, bump the `:tasks_load_seq` assign, and spawn a
  supervised fetch on `EvoDash.TaskSupervisor` — returning the socket
  UNCHANGED (the previous sidebar content stays visible until the fresh result
  arrives; no loading indicator). The spawned task runs
  `fetch_active_tasks/2` (node-aware fetch with the pending-remote empty-list
  guard) → `partition_active_tasks/1` (pure) and sends
  `{:node_aware_active_tasks, seq, node_id, node, {running, pending}}` back to
  the view. The attached `:handle_info` hook (installed by `on_mount/4` via
  `attach_hook(:node_aware_active_tasks, :handle_info, &handle_info/2)`) routes
  the message through the stale-guard `handle_tasks_result/2`, which DROPS the
  result when the node context or the seq no longer matches (the user switched
  nodes mid-flight, or a newer load was spawned — only the latest request's
  result is ever applied). Every APPLIED result also writes the hub
  (`EvoDash.ActiveTasks.put/4`, keyed by the message's own node context — the
  message values, not the socket assigns, are the authoritative context of the
  fetch) before assigning `:running_tasks`/`:pending_tasks`; stale/dropped
  results never write. The list stays push-based end to end: task PubSub events
  → 300ms trailing-edge debounce → fetch → apply (→ hub write).

  `load_running_and_pending_tasks/1` is the delegating public entry point used
  by `on_mount/4`, `assign_node/2`, `reload_tasks/1`, and ProjectsLive's
  task-mutation event handlers. `show_review_button?/1` is public and
  column-based (`branch_name`), so summary maps are NEVER read for `result`.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias EvoGit.TaskRegistry

  @remote_connections_topic "remote_connections"
  @tasks_topic "tasks"

  # The only statuses that can appear in the sidebar: running/pending/finalizing/
  # cancelling tasks (cancelling tasks stay visible while they wind down) and
  # completed tasks (the source of review candidates).
  @active_statuses [:running, :pending, :finalizing, :cancelling, :completed]

  @doc """
  On-mount hook — sets initial node-context assigns, seeds the sidebar Active
  Tasks lists synchronously from the `EvoDash.ActiveTasks` hub (keyed by the
  node context the page will have after `assign_node/2` — see the moduledoc),
  attaches the async sidebar-load `:handle_info` hook, and subscribes to
  connection-status broadcasts when the LiveView socket is connected.

  The sidebar Active Tasks load is gated behind `connected?/1` (dead-render
  skip): on the dead HTTP render the hub-seeded assigns are kept and NO query
  fires; on the connected mount a fetch fires only when the resolved context
  is a cold LOCAL one (`{nil, node()}` with no hub snapshot) — warm pages and
  all remote/pending pages render the hub's last-known state and rely on
  `assign_node/2`'s context-change reload + the push-based PubSub cycle to
  refresh. The load itself is async — it spawns on `EvoDash.TaskSupervisor` and
  returns the socket unchanged; the fresh result arrives later via the attached
  `:handle_info` hook (see `handle_info/2` + `handle_tasks_result/2`).
  """
  def on_mount(:default, params, _session, socket) do
    # Resolve the node context the page WILL have after the first `handle_params`
    # → `assign_node/2` run (on_mount runs BEFORE handle_params, so mount-time
    # assigns would otherwise default to the local context). The tuple is keyed
    # exactly like `EvoDash.ActiveTasks` snapshots ({node_id, node}), so the
    # seeds below read the SAME hub key that applied fetch results write for
    # this page's context — a local page can never seed from a remote key (and
    # vice versa).
    {seed_node_id, seed_node} = node_context_from_params(params)
    {seed_running, seed_pending} = hub_snapshot(seed_node_id, seed_node)

    socket =
      socket
      |> assign_new(:current_node, fn -> node() end)
      |> assign_new(:current_node_name, fn -> "Local" end)
      |> assign_new(:current_node_id, fn -> nil end)
      |> assign_new(:remote_status, fn -> nil end)
      |> assign_new(:remote_targets, fn -> EvoDash.NodeContext.list_targets() end)
      |> assign_new(:connection_statuses, fn -> EvoDash.NodeContext.connection_status() end)
      |> assign_new(:running_tasks, fn -> seed_running end)
      |> assign_new(:pending_tasks, fn -> seed_pending end)
      |> assign_new(:tasks_reload_pending, fn -> false end)
      |> assign_new(:tasks_load_seq, fn -> 0 end)
      # Attached `:handle_info` hook — intercepts async sidebar-load results
      # (`{:node_aware_active_tasks, ...}`) before the LiveView's own
      # handle_info; every other message passes through (catch-all
      # `{:cont, socket}`). Attached on BOTH the dead-render and connected
      # paths (same pattern as `EvoDashWeb.LiveHooks.DesktopQuit`).
      |> attach_hook(:node_aware_active_tasks, :handle_info, &handle_info/2)

    socket =
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.PubSub.subscribe(EvoGit.PubSub, @remote_connections_topic)
        Phoenix.PubSub.subscribe(EvoGit.PubSub, @tasks_topic)

        # Connected-mount sidebar fetch — CONDITIONAL on a cold LOCAL context
        # (see the dead-render skip note in the doc above). The mount fetch
        # spawns with the socket's default LOCAL assigns (`assign_node/2`
        # hasn't run yet — request_tasks_load reads `:current_node`/`:current_node_id`
        # from the assigns seeded above), so it is only meaningful for local
        # pages: for remote/pending pages it would fetch the WRONG node's data
        # (the pre-assign_node local assigns) AND double-fetch, because
        # `assign_node/2`'s existing context-change reload (guard seeded
        # `{nil, node()}` below) is guaranteed to fire the correct remote fetch
        # once `handle_params` runs. When the local hub already has a snapshot
        # (seeded above), the page renders last-known state and the push-based
        # PubSub cycle (task events → 300ms debounce → fetch → apply) keeps it
        # fresh — no redundant mount query. Async: the socket is returned
        # unchanged and the result arrives via the attached `:handle_info` hook.
        if seed_node_id == nil and EvoDash.ActiveTasks.get(nil, node()) == :empty do
          load_running_and_pending_tasks(socket)
        else
          socket
        end
      else
        socket
      end

    # Seed the node-context dedup guard with the local context so the first
    # `handle_params` → `assign_node/2` call doesn't double-fetch the sidebar
    # (kills the mount double-fetch: on_mount already loaded local tasks on the
    # connected mount when the local hub was cold, and on the dead render the
    # skip keeps it query-free). For a REMOTE/pending page this guard seed
    # differs from the resolved remote context, so `assign_node/2`'s existing
    # context-change reload fires the page's one correct remote fetch.
    # Seeded on BOTH paths.
    socket = assign(socket, :tasks_node_loaded, {nil, node()})

    {:cont, socket}
  end

  @doc """
  Loads active tasks from the current node ASYNCHRONOUSLY.

  The single unified entry point for the sidebar "Active Tasks" loading, used
  by `on_mount/4`, `assign_node/2`, `reload_tasks/1`, and ProjectsLive's
  task-mutation event handlers. Spawns a supervised fetch on
  `EvoDash.TaskSupervisor` and returns the socket unchanged — the previous
  sidebar content stays visible until the fresh result arrives via the
  attached `:handle_info` hook + `handle_tasks_result/2` stale-guard. The
  spawned fetch is `fetch_active_tasks/2` → `partition_active_tasks/1` (see
  their docs for the node-aware fetch semantics).
  """
  def load_running_and_pending_tasks(socket), do: request_tasks_load(socket)

  @doc """
  Fetches the active-task summaries from the given node context as
  `{running, pending}`. Context-based (no socket I/O) so it can run inside the
  spawned async load task.

  Node-aware: `current_node` is the BEAM node to query, `current_node_id` is
  the selected connection-target id. Local node →
  `TaskRegistry.list_tasks_summary(@active_statuses)`; remote node →
  `EvoDash.NodeContext.list_tasks_summary(current_node, @active_statuses)`
  (RPC).

  Pending-remote guard: when a remote context was requested
  (`current_node_id != nil`) but `current_node` still points at the local BEAM
  node (connection pending/connecting/error), returns `{[], []}` — local tasks
  must NEVER appear in the sidebar while the user is in a remote context.

  The summaries are passed through `partition_active_tasks/1`.
  """
  def fetch_active_tasks(current_node, current_node_id) do
    if current_node_id != nil and current_node == node() do
      {[], []}
    else
      summaries =
        if current_node == node() do
          TaskRegistry.list_tasks_summary(@active_statuses)
        else
          EvoDash.NodeContext.list_tasks_summary(current_node, @active_statuses)
        end

      partition_active_tasks(summaries)
    end
  end

  @doc """
  Socket-based wrapper of `fetch_active_tasks/2` — reads `current_node`
  (falling back to `node()`) and `current_node_id` from the socket assigns.
  Kept for API compatibility.
  """
  def fetch_active_tasks(socket) do
    fetch_active_tasks(socket.assigns[:current_node] || node(), socket.assigns[:current_node_id])
  end

  @doc """
  Partitions active-task summaries into `{running, pending}` (PURE — no I/O).

  Running = status in `[:running, :pending, :finalizing, :cancelling]`. Pending
  (review candidates) = status `:completed`, `review_status` nil, and
  `show_review_button?/1` true, sorted `{:desc, DateTime}` by
  `finished_at || started_at` (nil-safe: both-nil timestamps fall back to the
  Unix epoch so the DateTime module sorter never compares nil).
  """
  def partition_active_tasks(summaries) do
    running_tasks =
      Enum.filter(summaries, &(&1.status in [:running, :pending, :finalizing, :cancelling]))

    pending_tasks =
      summaries
      |> Enum.filter(fn task ->
        task.status == :completed and is_nil(task.review_status) and show_review_button?(task)
      end)
      |> Enum.sort_by(
        &(&1.finished_at || &1.started_at || ~U[1970-01-01 00:00:00Z]),
        {:desc, DateTime}
      )

    {running_tasks, pending_tasks}
  end

  @doc """
  Async sidebar reload used by ProjectsLive's task-mutation event handlers
  (task_submit, cancel_task, clear_task_history, delete_task, GitHub-issue
  fix). Spawns the same supervised fetch as `load_running_and_pending_tasks/1`
  and returns the socket unchanged; the fresh `:running_tasks`/`:pending_tasks`
  arrive via the attached `:handle_info` hook.
  """
  def assign_active_tasks(socket), do: request_tasks_load(socket)

  # Shared async sidebar-load spawner for `load_running_and_pending_tasks/1`,
  # `assign_active_tasks/1`, and `reload_tasks/1` (via the former). Captures
  # the view pid, node context, and the next `:tasks_load_seq` BEFORE spawning,
  # bumps the seq assign (so only the latest request's result is ever applied),
  # then spawns a supervised fetch on `EvoDash.TaskSupervisor` (same pattern as
  # SettingsLive's LLM test / ReviewLive.MergeCheck's check_merge). Returns the
  # socket unchanged — the previous sidebar content stays visible until the
  # fresh result arrives via the attached `:handle_info` hook.
  defp request_tasks_load(socket) do
    view_pid = self()
    current_node = socket.assigns[:current_node] || node()
    current_node_id = socket.assigns[:current_node_id]
    seq = Map.get(socket.assigns, :tasks_load_seq, 0) + 1

    socket = assign(socket, :tasks_load_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      {running, pending} =
        try do
          fetch_active_tasks(current_node, current_node_id)
        rescue
          # (1) Do we expect this error? Any unexpected failure inside a
          # fire-and-forget supervised task (e.g. a crashed TaskRegistry) — the
          # spawned fn must NEVER raise, or the result message would never be
          # sent and the sidebar refresh would be silently lost.
          # (2) Is try/rescue the cleanest approach? Yes — this is a deliberate
          # async-boundary rescue (same pattern as MergeCheck's spawned
          # check_merge task); the sync path's defensive mode for fetch
          # failures is empty lists (NodeContext returns [] on RPC failure),
          # so `{[], []}` mirrors it.
          _ -> {[], []}
        end

      send(
        view_pid,
        {:node_aware_active_tasks, seq, current_node_id, current_node, {running, pending}}
      )
    end)

    socket
  end

  @doc """
  Stale-guarded application of an async sidebar-load result (PURE socket
  in/out — the testable seam of the attached `:handle_info` hook).

  Drops the result (returns the socket unchanged) when ANY of the following
  holds:
    * `node_id` != the current `:current_node_id` assign (the user switched
      nodes while the fetch was in flight), or
    * `node` != the current `:current_node` assign (same), or
    * `seq` != the current `:tasks_load_seq` assign (a newer load was spawned
      since — only the latest request's result is ever applied).

  Otherwise assigns `:running_tasks`/`:pending_tasks` from the payload AND
  records the lists in the `EvoDash.ActiveTasks` hub (keyed by the message's
  own `node_id`/`node` — the authoritative context of the fetch, which matched
  the socket assigns per the guard) so a remounting LiveView on that node
  context renders last-known state instantly instead of flashing empty. Stale/
  dropped results never write the hub.
  """
  def handle_tasks_result(
        socket,
        {:node_aware_active_tasks, seq, node_id, node, {running, pending}}
      ) do
    if node_id != socket.assigns[:current_node_id] or
         node != socket.assigns[:current_node] or
         seq != Map.get(socket.assigns, :tasks_load_seq, 0) do
      # Stale — a node switch or a newer load superseded this result. Never
      # writes the hub: only successfully applied results are last-known state.
      socket
    else
      # Applied. Record the snapshot in the hub FIRST (keyed by the message's
      # own node context — the authoritative context of the fetch) so a
      # remounting LiveView for this node context seeds instantly; then assign.
      EvoDash.ActiveTasks.put(node_id, node, running, pending)

      socket
      |> assign(:running_tasks, running)
      |> assign(:pending_tasks, pending)
    end
  end

  @doc """
  Attached `:handle_info` hook (installed by `on_mount/4` via
  `attach_hook(:node_aware_active_tasks, :handle_info, &handle_info/2)`).

  Intercepts async sidebar-load results and routes them through the stale-guard
  `handle_tasks_result/2`, returning `{:halt, socket}` so the LiveView's own
  `handle_info` never sees them. All other messages pass through with
  `{:cont, socket}` (the LiveView's own `handle_info` runs as usual — e.g.
  `:node_aware_reload_tasks`).
  """
  def handle_info({:node_aware_active_tasks, _seq, _node_id, _node, _tasks} = message, socket) do
    {:halt, handle_tasks_result(socket, message)}
  end

  def handle_info(_message, socket) do
    {:cont, socket}
  end

  @doc """
  Returns `true` when the completed task has a branch ready for review.

  Column-based: reads the denormalized `branch_name` summary column (populated
  at write time from `result.branch_name` by `EvoGit.Store.Codec`). Must NEVER
  read `result` from summary maps — the summary projection drops it.
  """
  def show_review_button?(%{status: :completed, branch_name: branch})
      when is_binary(branch) and branch != "",
      do: true

  def show_review_button?(_), do: false

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

  The sidebar reload this triggers is ASYNC (spawn → `:node_aware_active_tasks`
  message → `handle_tasks_result/2` stale-guard — see
  `load_running_and_pending_tasks/1`); the node-context assigns themselves are
  set synchronously.
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
          |> assign(:remote_status, nil)

        {:remote, target, remote_node} ->
          # The remote BEAM node name is resolved from the connection manager's
          # status map (`:node` field, e.g. "genesis_remote@127.0.0.1"). We store
          # it as an atom so `EvoDash.NodeContext.list_agents(@current_node)`
          # routes `:erpc.call/5` to the correct node.
          socket
          |> assign(:current_node, remote_node)
          |> assign(:current_node_name, target.name)
          |> assign(:current_node_id, node_param)
          |> assign(:remote_status, remote_status(node_param))

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
          |> assign(:remote_status, remote_status(node_param))
      end

    # Reload sidebar tasks from the (possibly changed) node so the "Active
    # Tasks" section always reflects the node being viewed. This runs on every
    # `handle_params` call, including node switches. The load itself is async
    # (see `load_running_and_pending_tasks/1`) — the guard below is set
    # synchronously and the fresh result arrives later via the attached
    # `:handle_info` hook (the stale-guard drops results from a previous node
    # context if the user switches again mid-flight).
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

  # Resolves the node context (`{node_id, node}`) the page WILL have after
  # `assign_node/2` runs for the given `?node=` params — mirrors the case in
  # `assign_node/2` exactly and keys the tuple like `EvoDash.ActiveTasks`
  # snapshots so mount-time seeds read the same hub key that applied fetch
  # results write for this page's context:
  #   * `:local` → `{nil, node()}`
  #   * `{:remote, _target, remote_node}` → `{node_param, remote_node}`
  #   * `{:pending, _target}` → `{node_param, node()}` (data comes from the
  #     local node until the connection completes, but the target id is
  #     preserved so the hub key never collides with the pure-local key)
  defp node_context_from_params(params) do
    node_param = params["node"]

    case resolve_node_context(node_param) do
      :local -> {nil, node()}
      {:remote, _target, remote_node} -> {node_param, remote_node}
      {:pending, _target} -> {node_param, node()}
    end
  end

  # Reads the hub's last-known `{running, pending}` snapshot for a node
  # context, defaulting to `{[], []}` when the context has never been written
  # (`:empty`). Used by the mount seeds — synchronous GenServer.call, same
  # precedent as `EvoDashWeb.LiveHooks.UpdateStatus`'s `initial_assign/2`
  # (the hub is a supervised child of `EvoDash.Application`, always up in prod
  # and under `mix test`).
  defp hub_snapshot(node_id, node) do
    case EvoDash.ActiveTasks.get(node_id, node) do
      {:ok, {running, pending}} -> {running, pending}
      :empty -> {[], []}
    end
  end

  # Derives the `:remote_status` assign for a remote node param from the
  # connection manager's current status. `EvoDash.NodeContext.connection_status/1`
  # returns a `%{phase: ...}` map when the connection subsystem is available;
  # any other result (the `:disconnected` atom when the subsystem is
  # unavailable, or an empty `%{}` fallback) maps to a well-formed disconnected
  # status map so callers always receive a map with a `:phase` key.
  defp remote_status(node_param) do
    case EvoDash.NodeContext.connection_status(node_param) do
      %{phase: _} = status -> status
      _ -> %{phase: :disconnected, last_error: nil}
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

    # Recompute `:remote_status` from the live connection manager so a
    # connecting→error (or any other phase) change updates the gate immediately,
    # without waiting for a push_patch-triggered `handle_params` re-run.
    socket =
      if current_node_id != nil do
        assign(socket, :remote_status, remote_status(current_node_id))
      else
        socket
      end

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

  # Fallback for unexpected message shapes — just refresh statuses (and the
  # `:remote_status` gate when a remote context is selected).
  def handle_connection_status(socket, _message) do
    socket = assign(socket, :connection_statuses, EvoDash.NodeContext.connection_status())

    socket =
      if socket.assigns[:current_node_id] != nil do
        assign(socket, :remote_status, remote_status(socket.assigns[:current_node_id]))
      else
        socket
      end

    {:noreply, socket}
  end

  @doc """
  Handles task-related PubSub messages by scheduling a debounced reload of
  running/pending tasks. Returns `{:noreply, socket}`.

  The `:evo_git` app emits the node-identity contract on the `"tasks"` topic:
  `{:task_updated, task_id, status, node}` (status = the task status atom
  `:pending|:running|:finalizing|:cancelling|:completed|:failed|:cancelled`,
  or `nil` for review-only mutations) and `{:task_deleted, task_id, node}`.
  Every event carries the BEAM node atom of the publishing node.

  Node filtering: an event only schedules a reload when its `node` matches the
  currently-viewed node identity (`event_from_current_node?/2` — local viewing
  → `node()`, remote viewing → the remote daemon's BEAM node atom). Foreign-
  node events are dropped BEFORE the debounce is scheduled, so they can never
  leak into another node's UI updates (page reloads, ProjectsLive's browser-
  notification diff).

  Uses a trailing-edge debounce (300ms via `:node_aware_reload_tasks`) to
  coalesce broadcast bursts into a single reload: intermediate broadcasts
  while a reload is already pending are dropped.
  """
  def handle_task_info(socket, {:task_updated, _task_id, _status, node}) do
    if event_from_current_node?(socket.assigns, node) do
      {:noreply, debounce_task_reload(socket)}
    else
      # Foreign-node event — dropped before the debounce is scheduled so it
      # never triggers a UI update on the currently-viewed node.
      {:noreply, socket}
    end
  end

  def handle_task_info(socket, {:task_deleted, _task_id, node}) do
    if event_from_current_node?(socket.assigns, node) do
      {:noreply, debounce_task_reload(socket)}
    else
      # Foreign-node event — dropped before the debounce is scheduled so it
      # never triggers a UI update on the currently-viewed node.
      {:noreply, socket}
    end
  end

  @doc """
  Returns `true` when a PubSub event's `node` matches the currently-viewed node
  identity.

  `@current_node` is resolved by `assign_node/2` (see `resolve_node_context/1`):
  local viewing → `node()` (the dashboard's own BEAM node atom); remote viewing
  → the remote daemon's BEAM node atom (the third element of the
  `{:remote, target, remote_node}` tuple, flattened into the assign); a
  pending/disconnected target → `node()`. The helper therefore compares the
  event's publishing node with the node identity the user is currently viewing.

  Used by EVERY consumer of the `"tasks"` PubSub topic (NodeAware, AgentsLive,
  SystemLive, ReviewLive, SettingsLive) to drop foreign-node events before any
  UI update. Falls back to `node()` when the `:current_node` assign is absent.
  """
  def event_from_current_node?(assigns, event_node) when is_atom(event_node) do
    event_node == Map.get(assigns, :current_node, node())
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
  Executes the debounced task reload: spawns the async sidebar load for the
  current node and clears the `:tasks_reload_pending` flag. Returns the socket
  unchanged — the previous sidebar content stays visible until the fresh
  result arrives via the attached `:handle_info` hook. LiveViews call this
  from their `handle_info(:node_aware_reload_tasks, socket)` clause.
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

  Each LiveView should set the `@current_path` assign (e.g. `~p"/projects"`,
  `~p"/agents"`) so this helper can build the correct URL.
  """
  def handle_node_selected(socket, node_id) do
    path = socket.assigns[:current_path] || "/"
    to = if node_id == "local", do: path, else: path <> "?node=" <> node_id
    {:noreply, Phoenix.LiveView.push_patch(socket, to: to)}
  end
end
