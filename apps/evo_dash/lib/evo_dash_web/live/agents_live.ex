defmodule EvoDashWeb.AgentsLive do
  @moduledoc """
  Node-aware inspector for agent trees, live activity and commit history.

  `Scope` owns the optional task filter and target identity. `Loader` handles
  async snapshots and coalesced push refreshes, `Inspector` owns the selected
  agent's history and stream, and `CommitGraphState` owns the temporal view.
  """
  use EvoDashWeb, :live_view

  alias EvoDashWeb.AgentsLive.{
    AgentMerge,
    CommitGraphState,
    Inspector,
    Loader,
    PendingEvents,
    Scope,
    SendMessage,
    StreamWatch
  }

  alias EvoDashWeb.LiveHooks.NodeAware

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "agents")
    end

    socket =
      assign(socket,
        page_title: gettext("Agents"),
        selected_agent_id: nil,
        requested_agent_id: nil,
        inspector_stream: nil,
        inspector_stream_token: 0,
        inspector_stream_worker: nil,
        inspector_stream_worker_monitor: nil,
        inspector_history_seq: 0,
        inspector_history_error: false,
        selected_history_entry: nil,
        selected_objective: nil,
        show_usage: false,
        send_message_agent_id: nil,
        send_message_text: "",
        agents: [],
        id_to_display: %{},
        repo_trees: [],
        config_status: nil,
        previous_agent_ids: MapSet.new(),
        agents_initialized: false,
        previous_statuses: %{},
        new_agent_ids: MapSet.new(),
        changed_status_ids: MapSet.new(),
        previous_node: socket.assigns[:current_node] || node(),
        optimistic_messages: %{},
        pending_user_messages: %{},
        agents_loading: true,
        load_generation: 0,
        agents_error: nil,
        refresh_seq: 0,
        history_gate: %{},
        threshold_cache: nil,
        history_loading_agent_id: nil,
        full_message_pending_index: nil,
        full_message_pending_agent_id: nil,
        pending_agent_events: PendingEvents.new(),
        agent_flush_scheduled: false,
        pending_agents_refresh: false,
        left_view: :tree,
        commit_graph: [],
        commit_graph_raw: %{},
        commit_graph_loaded: false,
        commit_graph_loading: false,
        commit_graph_error: nil,
        commit_graph_seq: 0,
        commit_graph_fetched_at: nil,
        commit_graph_tick_scheduled: false,
        commit_graph_fingerprint: nil,
        commit_fold_expanded: MapSet.new(),
        retained_agents: %{}
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> NodeAware.assign_node(params, preserve_unresolved?: true)
     |> Scope.prepare(params)
     |> Loader.start_page_load()}
  end

  @impl true
  def handle_info({{:agents_data_loaded, scope, generation}, result}, socket),
    do: Loader.loaded(socket, scope, generation, result)

  def handle_info({{:agents_refresh_result, scope, seq}, result}, socket),
    do: Loader.refreshed(socket, scope, seq, result)

  def handle_info({:agents_data_loaded, node, generation, result}, socket),
    do: Loader.legacy_loaded(socket, node, generation, result)

  def handle_info({:agents_refresh_result, seq, node, result}, socket),
    do: Loader.legacy_refreshed(socket, node, seq, result)

  def handle_info({:agents_updated, node}, socket),
    do: {:noreply, AgentMerge.buffer_node_refresh(socket, node)}

  def handle_info({:node_selected, node_id}, socket), do: Scope.node_selected(socket, node_id)

  def handle_info({:remote_connection_status, _, _} = msg, socket),
    do: Scope.connection_status(socket, msg)

  # Some connect failures never broadcast. Only surface a failure for the still-viewed target.
  def handle_info(
        {:remote_connect_result, target_id, {:error, reason}},
        %{assigns: %{current_node_id: target_id}} = socket
      ) do
    message =
      case reason do
        :remote_connection_unavailable ->
          gettext("Remote connect unavailable — the remote connection subsystem is not running.")

        _ ->
          gettext("Remote connect failed: %{reason}", reason: format_remote_reason(reason))
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_info({:remote_connect_result, _, {:error, _}}, socket), do: {:noreply, socket}

  def handle_info({:task_updated, _, _, _} = msg, socket), do: Scope.task_event(socket, msg)
  def handle_info({:task_deleted, _, _} = msg, socket), do: Scope.task_event(socket, msg)

  def handle_info(:node_aware_reload_tasks, socket),
    do: {:noreply, NodeAware.reload_tasks(socket)}

  def handle_info({:agent_registered, _, _, _} = event, socket),
    do: {:noreply, AgentMerge.buffer_event(socket, event)}

  def handle_info({:agent_updated, _, _, _} = event, socket),
    do: {:noreply, AgentMerge.buffer_event(socket, event)}

  def handle_info({:agent_removed, _, _} = event, socket),
    do: {:noreply, AgentMerge.buffer_event(socket, event)}

  def handle_info({:flush_agent_events, token}, socket), do: Loader.flush(socket, token)
  def handle_info(:flush_agent_events, socket), do: Loader.flush(socket, :manual)

  def handle_info({:inspector_stream_ready, target, token, id, result}, socket),
    do: {:noreply, Inspector.stream_ready(socket, target, token, id, result)}

  def handle_info({:inspector_stream_reconciled, target, token, id, request, result}, socket),
    do: {:noreply, Inspector.stream_reconciled(socket, target, token, id, request, result)}

  def handle_info({:agent_delta, id, seq, events}, socket),
    do: {:noreply, Inspector.stream_push(socket, id, seq, events)}

  def handle_info({:agent_stream_closed, id, snapshot, seq}, socket),
    do: {:noreply, Inspector.stream_closed(socket, id, snapshot, seq)}

  def handle_info({:DOWN, ref, :process, pid, reason}, socket),
    do: {:noreply, Inspector.stream_down(socket, ref, pid, reason)}

  def handle_info({:agent_history_loaded, agent_id, node, seq, token, result, index}, socket),
    do: Inspector.apply_history_result(socket, agent_id, node, seq, token, result, index)

  # Old unscoped history responses have no ownership proof.
  def handle_info({:agent_history_loaded, _, _, _, _}, socket), do: {:noreply, socket}

  def handle_info({:commit_graph_loaded, scope, seq, result}, socket),
    do: CommitGraphState.loaded(socket, scope, seq, result)

  def handle_info({:commit_graph_tick, token}, socket), do: CommitGraphState.tick(socket, token)
  def handle_info(:commit_graph_tick, socket), do: CommitGraphState.tick(socket)

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket),
    do: {:noreply, Inspector.select(socket, id)}

  def handle_event("switch_left_view", params, socket),
    do: {:noreply, CommitGraphState.switch_left_view(socket, params["view"])}

  def handle_event("toggle_commit_fold", params, socket),
    do: {:noreply, CommitGraphState.toggle_fold(socket, params)}

  def handle_event("expand_all_commit_folds", _params, socket),
    do: {:noreply, CommitGraphState.expand_all(socket)}

  def handle_event("collapse_all_commit_folds", _params, socket),
    do: {:noreply, CommitGraphState.collapse_all(socket)}

  def handle_event("retry_inspector_stream", _params, socket),
    do: {:noreply, Inspector.retry_stream(socket)}

  def handle_event("retry_inspector_history", _params, socket),
    do: {:noreply, Inspector.retry_history(socket)}

  def handle_event("close_details", _params, socket),
    do: {:noreply, Inspector.close_details(socket)}

  def handle_event("toggle_usage", _params, socket),
    do: {:noreply, Inspector.toggle_usage(socket)}

  def handle_event("view_full_message", %{"index" => index}, socket),
    do: {:noreply, Inspector.view_full_message(socket, index)}

  def handle_event("close_message_modal", _params, socket),
    do: {:noreply, Inspector.close_message_modal(socket)}

  def handle_event("view_full_objective", _params, socket),
    do: {:noreply, Inspector.view_full_objective(socket)}

  def handle_event("close_objective_modal", _params, socket),
    do: {:noreply, Inspector.close_objective_modal(socket)}

  def handle_event("retry_remote_connection", _params, socket),
    do: {:noreply, NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)}

  def handle_event("switch_to_local", _params, socket), do: Scope.node_selected(socket, "local")

  def handle_event("open_send_message", %{"id" => id}, socket), do: SendMessage.open(socket, id)

  def handle_event("close_send_message", _params, socket), do: SendMessage.close(socket)

  def handle_event("validate_send_message", %{"message" => message}, socket),
    do: SendMessage.validate(socket, message)

  def handle_event("send_agent_message", %{"agent_id" => id, "message" => message}, socket),
    do: SendMessage.send(socket, id, message)

  def handle_event("retry_agents_load", _params, socket),
    do: {:noreply, Loader.start_page_load(socket)}

  @impl true
  def terminate(_reason, socket) do
    StreamWatch.detach(socket)
    :ok
  end
end
