defmodule EvoDashWeb.SettingsLive.AsyncResults do
  @moduledoc """
  Every async result and broadcast the `/settings` page consumes.

  `SettingsLive.handle_info/2` keeps the message shapes (so an unknown message
  still crashes the page exactly as before) and delegates the bodies here. Each
  handler re-checks its own ownership before touching the socket — the
  generation/scope guards are load-bearing:

    * node-data load — `settings_load_seq` + `ConfigSave.scope/1` + requested
      node, plus the pending-remote-target guard;
    * config save — `ConfigSave.complete/2` decides saved/failed/stale;
    * config status, credentials, custom tools, OAuth auth status and the LLM
      test — token/node/seq/scope matched;
    * `scheduler_config` / task broadcasts — node-identity filtered (through
      `EvoDashWeb.LiveHooks.NodeAware`), with the task reload debounced there;
    * remote connection / bootstrap — the per-target pending marker and the
      bootstrap progress model.

  Nothing here decides a flash message's shape: the shared config/credential
  flashes live in `CategoryEvents`, the remote lifecycle flashes in
  `RemoteEvents`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.SettingsLive.CategoryEvents
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ConfigSave
  alias EvoDashWeb.SettingsLive.LlmTestEvents
  alias EvoDashWeb.SettingsLive.Navigation
  alias EvoDashWeb.SettingsLive.NodeData
  alias EvoDashWeb.SettingsLive.PageState
  alias EvoDashWeb.SettingsLive.RemoteEvents

  @doc """
  The authoritative async node-data load result (see
  `EvoDashWeb.SettingsLive.NodeData`): applied only for the exact generation,
  scope and requested node, and never while the requested remote target is
  still pending.
  """
  def node_data_loaded(socket, seq, scope, requested_node, category_param, result) do
    # The request's node is compared against the LIVE target: a LOCAL context
    # follows `node()`, so a load that ran against this BEAM after a runtime
    # distribution change is applied instead of dropped as "another node".
    if seq == socket.assigns.settings_load_seq and scope == ConfigSave.scope(socket) and
         requested_node == PageState.target_node(socket) and
         not PageState.pending_remote_target?(socket) do
      {:noreply,
       apply_node_data_results(
         socket,
         category_param,
         node_data_results(result, requested_node, socket)
       )}
    else
      {:noreply, socket}
    end
  end

  @doc """
  The complete `{:settings_config_saved, token, scope}` message: ConfigSave
  decides whether it is the owner's receipt, a stale completion or a failure.
  """
  def config_saved(socket, message) do
    case ConfigSave.complete(socket, message) do
      {:saved, receipt, socket} ->
        {:noreply, CategoryEvents.apply_config_receipt(socket, receipt)}

      {:failed, receipt, socket} ->
        {:noreply, CategoryEvents.save_failed_flash(socket, receipt.reason)}

      {:stale, socket} ->
        {:noreply, socket}
    end
  end

  @doc """
  The config-completeness status re-fetched after a save (remote nodes only).
  """
  def saved_status_loaded(socket, token, scope, result) do
    if token == socket.assigns.config_status_token and scope == ConfigSave.scope(socket) do
      case result do
        {:ok, %{} = status} ->
          {:noreply, assign(socket, :config_status, status)}

        failed ->
          {:noreply,
           socket
           |> assign(:config_status, NodeData.degraded_config_status())
           |> CategoryEvents.saved_warning_flash({:config_status, failed})}
      end
    else
      {:noreply, socket}
    end
  end

  @doc """
  The result of an ASYNC (remote-node) credential save started by
  `CategoryEvents`.
  """
  def credentials_saved(socket, saved_node, result) do
    # Result of an ASYNC (remote-node) credential save started by
    # save_api_key_remote/4 — the SafeCall result envelope is nested:
    # `EvoDash.SafeCall.start/4` sends `{tag, SafeCall.run(fun)}`, so the
    # task's own `{:ok, map}` / `{:error, reason}` arrives one level deeper.
    # `config_saving` (the shared in-page "Saving configuration…" indicator) is
    # cleared on EVERY branch, including the stale one. A stale save belongs to
    # a node the user has since left and is dropped.
    socket = assign(socket, :config_saving, false)

    if saved_node != socket.assigns.current_node do
      {:noreply, socket}
    else
      case result do
        {:ok, {:ok, %{} = saved}} ->
          # A nil credentials value means the re-fetch failed — keep the current
          # assign instead of blanking the API-key card.
          {:noreply,
           socket
           |> CategoryEvents.apply_saved_credentials(saved)
           |> put_flash(:info, gettext("API key saved successfully."))}

        {:ok, {:error, reason}} ->
          # Keep the previously rendered state — nothing was persisted.
          {:noreply, CategoryEvents.credentials_failed_flash(socket, reason)}

        # The task itself exited / raised — SafeCall reports it here.
        {:error, reason} ->
          {:noreply, CategoryEvents.credentials_failed_flash(socket, reason)}

        other ->
          {:noreply,
           CategoryEvents.credentials_failed_flash(socket, {:unexpected_save_result, other})}
      end
    end
  end

  @doc """
  An invalidated writer has finished: only now fetch the next scope's candidate,
  so a reconnect cannot retain a pre-write snapshot.
  """
  def config_load_wait_down(socket) do
    socket = assign(socket, :config_load_wait_ref, nil)

    {:noreply,
     PageState.start_node_data_load(socket, Atom.to_string(socket.assigns.active_category))}
  end

  @doc """
  The async custom-agents status refresh (node stale-guarded; the loading flag
  is cleared on every branch so the agents editor's placeholder never sticks).

  A CONFIRMED load maps `{:ok, %{agents:, model_selection_script:,
  script_status:}}` into the editor assigns and degrades every other shape
  (`{:error, reason}`, an unexpected payload) exactly like the old synchronous
  loader: an empty agent list with no script and a healthy `:ok` status. The
  editor's transient state is deliberately NOT reset here — a stale refresh must
  never wipe what the user (or a just-completed save) is looking at.
  """
  def custom_agents_loaded(socket, requested_node, result) do
    socket = assign(socket, :custom_agents_loading, false)

    if requested_node != socket.assigns.current_node do
      {:noreply, socket}
    else
      {agents, script, script_status} =
        case result do
          {:ok, %{agents: agents, model_selection_script: script, script_status: status}} ->
            {agents, script, status}

          _error_or_unexpected ->
            {[], "", :ok}
        end

      {:noreply,
       assign(socket,
         custom_agents: agents,
         model_selection_script: script || "",
         script_status: script_status
       )}
    end
  end

  @doc """
  The async custom-tools status refresh (node stale-guarded; the loading flag is
  cleared on every branch so the panel's spinner never sticks).
  """
  def custom_tools_loaded(socket, requested_node, result) do
    if requested_node == socket.assigns.current_node do
      {:noreply, assign(socket, custom_tools_status: result, custom_tools_loading: false)}
    else
      {:noreply, assign(socket, :custom_tools_loading, false)}
    end
  end

  @doc """
  The async OAuth/subscription credential-status load (stale-guarded by node and
  seq — a mismatch keeps the map `:unknown` until the newer load lands).
  """
  def auth_status_loaded(socket, requested_node, seq, statuses) do
    # Two stale guards, no polling: the load was requested for `requested_node`
    # at spawn time (a node switch makes it describe another node's credentials)
    # and carries the `:auth_status_seq` it was spawned with (a newer load is
    # already in flight and will deliver fresher values). Either mismatch drops
    # the result — the map stays `:unknown` until the newer load lands.
    if requested_node != socket.assigns.current_node or seq != socket.assigns.auth_status_seq do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :auth_statuses, statuses)}
    end
  end

  @doc """
  An LLM connection-test result. Only the latest test of this exact persisted
  account/model on this target/BEAM node may settle the visible status.
  """
  def llm_test_result(socket, seq, scope, result) do
    # SafeCall's tag stays nested. Only the latest test of this exact persisted
    # account/model on this target/BEAM node may settle the visible status.
    if seq == socket.assigns[:llm_test_seq] and scope == LlmTestEvents.llm_test_scope(socket) and
         socket.assigns.llm_test_status == :testing and
         not PageState.pending_remote_target?(socket) do
      {:noreply,
       assign(socket, :llm_test_status, LlmTestEvents.normalize_llm_test_result(result))}
    else
      {:noreply, socket}
    end
  end

  @doc """
  A `"scheduler_config"` broadcast — node-filtered.

  NOTE — pre-existing gap, deliberately NOT fixed in the push-refactor: the
  reload still reads the LOCAL scheduler config (`ConfigIO.load_scheduler_config()`
  → `AgentScheduler.get_config()`) even while viewing a remote node — remote
  viewers never get a remote-refresh path for this assign today. Behavior kept
  exactly as before.
  """
  def scheduler_config_updated(socket, node) do
    # Node filter first: foreign-node events are ignored (socket unchanged).
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, assign(socket, :scheduler_config, ConfigIO.load_scheduler_config())}
    else
      # Foreign-node event — dropped, socket unchanged.
      {:noreply, socket}
    end
  end

  @doc """
  A node selection changed the config domain: the previous scope's drafts,
  writes and snapshots are detached before the new node's state is resolved.
  """
  def node_selected(socket, node_id) do
    socket =
      if node_id != (socket.assigns[:current_node_id] || "local"),
        do: PageState.reset_config_scope(socket),
        else: socket

    {:noreply, socket} = NodeAware.handle_node_selected(socket, node_id)
    socket = PageState.reconcile_config_scope(socket)

    socket =
      if socket.assigns.active_category == :remote_connections do
        socket
        |> assign(:remote_targets, PageState.safe_list_targets())
        |> assign(:remote_statuses, PageState.safe_connection_statuses())
      else
        socket
      end

    # A node switch changes the config domain — a draft picked on the previous
    # node's config must not leak onto the new node's appearance card.
    {:noreply,
     socket |> assign(:appearance_accent_draft, nil) |> LlmTestEvents.invalidate_llm_test()}
  end

  @doc """
  A `"remote_connections"` broadcast: connection phase, target statuses,
  bootstrap progress and (when the switch completed) the new scope's load.
  """
  def remote_connection_status(socket, message) do
    {target_id, status} = {elem(message, 1), elem(message, 2)}

    # Reconnects can keep both target id and BEAM identity. A phase transition
    # still invalidates drafts, pending writes and pre-disconnect snapshots.
    phase = if is_map(status), do: status[:phase], else: status

    socket =
      if target_id == socket.assigns[:current_node_id] and
           phase != socket.assigns[:settings_connection_phase],
         do: PageState.reset_config_scope(socket),
         else: socket

    {:noreply, socket} = NodeAware.handle_connection_status(socket, message)

    socket =
      if target_id == socket.assigns[:current_node_id] do
        NodeAware.assign_node(socket, %{"node" => target_id})
      else
        socket
      end

    socket = PageState.reconcile_config_scope(socket)

    socket =
      if socket.assigns.active_category == :remote_connections do
        assign(socket, :remote_statuses, PageState.safe_connection_statuses())
      else
        socket
      end

    bootstrap_progress =
      RemoteEvents.update_bootstrap_progress(socket.assigns.bootstrap_progress, target_id, status)

    socket = assign(socket, :bootstrap_progress, bootstrap_progress)

    socket =
      if target_id == socket.assigns[:current_node_id] and phase == :connected and
           is_nil(socket.assigns[:config_loaded_scope]) and not ConfigSave.busy?(socket),
         do:
           PageState.start_node_data_load(socket, Atom.to_string(socket.assigns.active_category)),
         else: socket

    {:noreply, RemoteEvents.consume_remote_connect_pending(socket, target_id, status)}
  end

  @doc """
  Sync-error fallback for an async connect: `connect/1` returned an error on an
  arm that never broadcasts (e.g. the remote-connection subsystem is
  unavailable) — the flash is the surfacing mechanism and the pending marker is
  cleared so the Connect button is not wedged by the duplicate guard.
  """
  def remote_connect_result(socket, target_id, {:error, reason}) do
    socket =
      socket
      |> assign(
        :remote_connect_pending,
        Map.delete(Map.get(socket.assigns, :remote_connect_pending, %{}), target_id)
      )
      |> RemoteEvents.flash_remote_lifecycle_result({:error, reason}, gettext("Connect"))

    {:noreply, socket}
  end

  @doc """
  The terminal result of a bootstrap install task
  (`{:bootstrap_complete, id, result}`).
  """
  def bootstrap_complete(socket, id, result) do
    socket =
      case result do
        {:error, {:daemon_running, details}} ->
          # The remote host already serves Erlang distribution to another
          # connection (refused bootstrap) — no staging happened. Drop the
          # transient active entry (the bar would otherwise sit on a
          # stage-less "active" state forever) and ask the user for permission
          # to detach that node and re-enable distribution with this
          # connection's identity (see confirm_bootstrap_restart). No generic
          # error flash — the dialog IS the feedback.
          socket
          |> RemoteEvents.reload_remote_statuses()
          |> RemoteEvents.clear_bootstrap_progress(id)
          |> assign(:bootstrap_restart_confirm, %{id: id, details: details})

        {:ok, _} ->
          socket
          |> RemoteEvents.reload_remote_statuses()
          |> RemoteEvents.freeze_bootstrap_progress(id, :success)
          |> RemoteEvents.flash_remote_lifecycle_result(result, gettext("Install"))

        :ok ->
          socket
          |> RemoteEvents.reload_remote_statuses()
          |> RemoteEvents.freeze_bootstrap_progress(id, :success)
          |> RemoteEvents.flash_remote_lifecycle_result(result, gettext("Install"))

        {:error, reason} ->
          socket
          |> RemoteEvents.reload_remote_statuses()
          |> RemoteEvents.freeze_bootstrap_progress(
            id,
            :error,
            RemoteEvents.bootstrap_error_text(reason)
          )
          |> RemoteEvents.flash_remote_lifecycle_result(result, gettext("Install"))
      end

    {:noreply, socket}
  end

  @doc """
  A node-identity task broadcast — node-filtered (foreign-node events are
  dropped BEFORE the debounce is scheduled) and debounced (300ms trailing
  edge) inside `EvoDashWeb.LiveHooks.NodeAware.handle_task_info/2`, which
  already returns `{:noreply, socket}`.
  """
  def task_info(socket, message), do: NodeAware.handle_task_info(socket, message)

  @doc """
  The debounce timer fired — reload the sidebar's running/pending tasks.
  """
  def reload_tasks(socket), do: {:noreply, NodeAware.reload_tasks(socket)}

  # Normalizes the three result shapes the async node-data load can deliver:
  #
  #   * `{:ok, results}` — the normal success map (NodeData.start/3);
  #   * `{:error, reason}` — the load EXITED or raised (e.g. a dead scheduler
  #     or an unreachable remote node). Degrade through NodeData.error_results/3
  #     so the page shows the "Remote Configuration Unavailable" banner and an
  #     empty config instead of crashing;
  #   * a BARE results map — the pre-`{:ok, _}` message shape, still delivered
  #     by tests that inject a hand-built results map.
  defp node_data_results({:ok, results}, _requested_node, _socket) when is_map(results),
    do: results

  defp node_data_results({:error, reason}, requested_node, socket) do
    NodeData.error_results(
      requested_node,
      socket.assigns.all_schemas_by_category,
      reason
    )
  end

  defp node_data_results(results, _requested_node, _socket) when is_map(results), do: results

  # Applies the results of the async node-data load (see
  # EvoDashWeb.SettingsLive.NodeData) to the socket: the platform assigns
  # (platform_os + the platform-filtered schemas map), the re-resolved active
  # category, and the config/agents assigns. The node-data load carries the
  # custom-agent data too, so it settles BOTH loading flags the mount seeds.
  # A `:remote_config_error` reason is gettext'd into the same
  # user-facing message the old synchronous path showed, so a remote fetch
  # failure still renders the error banner instead of a misleading "No LLM
  # Model Configured" box.
  defp apply_node_data_results(socket, category_param, results) do
    # The node's own filtered map becomes the persisted last-known map AND the
    # rendered one — a node switch replaces it wholesale, so a category gated on
    # the newly viewed node disappears from the nav (and from the active
    # selection) instead of leaking from the previous node.
    filtered_schemas =
      case Map.get(results, :filtered_schemas_by_category) do
        schemas when is_map(schemas) and map_size(schemas) > 0 -> schemas
        # A results map without a usable filtered nav (a hand-built one) keeps
        # the last-known nav rather than rendering an empty sidebar.
        _ -> socket.assigns[:known_schemas_by_category] || %{}
      end

    socket =
      socket
      |> assign(:platform_os, results.platform_os)
      |> assign(:known_schemas_by_category, filtered_schemas)
      |> assign(:schemas_by_category, filtered_schemas)
      |> LlmTestEvents.assign_test_config(results.file_config)
      |> assign(:config_status, results.config_status)
      |> assign(
        :config_loaded_scope,
        if(is_nil(results.remote_config_error), do: ConfigSave.scope(socket))
      )
      |> assign(:remote_config, false)
      # Node-data loads replace file_config with an authoritative snapshot
      # (navigation + node switches) — clear any pending appearance accent draft
      # so the accent card always reflects the loaded config.
      |> assign(:appearance_accent_draft, nil)

    socket =
      case results.remote_config_error do
        nil ->
          assign(socket, :remote_config_error, nil)

        reason ->
          assign(
            socket,
            :remote_config_error,
            gettext(
              "Could not load configuration from the remote node: %{reason} — the node may be unreachable.",
              reason: inspect(reason)
            )
          )
      end

    # Keep the category the user is already looking at as long as it is STILL
    # displayable on this node — a nav click made while this load was in flight
    # (or after it started) must not be undone by the captured `?category=`
    # param, which describes the request's start state. Only when the visible
    # category was filtered away for this node does the captured param (then the
    # `:llm`/first-category fallback) decide.
    category_param =
      if Navigation.visible?(socket.assigns.active_category, filtered_schemas),
        do: nil,
        else: category_param

    category =
      Navigation.resolve(category_param, socket.assigns.active_category, filtered_schemas)

    socket =
      if category != socket.assigns.active_category do
        assign(socket, :active_category, category)
      else
        socket
      end

    assign(socket,
      custom_agents: results.custom_agents.agents,
      model_selection_script: results.custom_agents.model_selection_script,
      script_status: results.custom_agents.script_status,
      # Tolerant: results maps built before the custom-tools panel lack this key
      # (several tests build them without it) — default to the empty status.
      custom_tools_status: Map.get(results, :custom_tools_status, %{ok: [], errors: []}),
      custom_tools_loading: false,
      custom_agents_loading: false,
      editing_agent_id: nil,
      script_save_error: nil,
      script_test_results: []
    )
    |> EvoDashWeb.SettingsLive.start_auth_status_load()
  end
end
