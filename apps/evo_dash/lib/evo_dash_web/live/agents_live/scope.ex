defmodule EvoDashWeb.AgentsLive.Scope do
  @moduledoc """
  Owns the Agents page's `{target_id, beam_node, task_id}` identity and invalidates
  its data whenever that identity or the target's availability changes.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias EvoDashWeb.AgentsLive.{AgentMerge, Inspector, PendingEvents, StreamWatch}
  alias EvoDashWeb.LiveHooks.NodeAware

  def task_id(value) when is_binary(value) do
    if String.trim(value) != "", do: value
  end

  def task_id(_value), do: nil

  def identity(assigns),
    do: {assigns[:current_node_id], assigns[:current_node], assigns[:task_scope_id]}

  # A pending target can carry node() as a placeholder. A connected alias of
  # node() is different: its status must name the actual serving BEAM.
  def available?(%{current_node_id: id} = assigns) when not is_nil(id) do
    case {assigns[:current_node], assigns[:remote_status]} do
      {beam, %{phase: :connected, node: advertised}}
      when is_atom(beam) and not is_nil(beam) and is_binary(advertised) ->
        Atom.to_string(beam) == advertised

      _ ->
        false
    end
  end

  def available?(_assigns), do: true

  def event_from_scope?(assigns, node) do
    available?(assigns) and NodeAware.event_from_current_node?(assigns, node)
  end

  def member?(_row, nil), do: true
  def member?(%{task_id: id}, id), do: true
  def member?(_row, _id), do: false

  def filter(rows, nil), do: rows
  def filter(rows, task_id), do: Enum.filter(rows, &member?(&1, task_id))

  def selectable_agent?(assigns, agent_id) do
    available?(assigns) and
      case assigns[:task_scope_id] do
        nil -> true
        task_id -> Enum.any?(assigns.agents, &(&1.id == agent_id and member?(&1, task_id)))
      end
  end

  @doc "Builds Agents URLs for deep links, reconnects and the All agents link."
  def path(task_id, target_id \\ nil, agent_id \\ nil) do
    query =
      [{"task", task_id}, {"agent_id", agent_id}, {"node", target_id}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    if query == "", do: "/agents", else: "/agents?" <> query
  end

  @doc "After NodeAware.assign_node/3, bind URL state and discard an obsolete scope."
  def prepare(socket, params) do
    task_id = task_id(params["task"])
    agent_id = Inspector.parse_agent_id(params["agent_id"])

    socket
    |> assign(
      task_scope_id: task_id,
      requested_agent_id: agent_id,
      current_path: path(task_id, socket.assigns[:current_node_id], agent_id)
    )
    |> sync()
  end

  @doc "Node switches keep the task filter, but never the old node's selected agent."
  def node_selected(socket, node_id) do
    socket
    |> assign(:current_path, path(socket.assigns[:task_scope_id]))
    |> NodeAware.handle_node_selected(node_id)
  end

  @doc "Drop disconnected data before any patch; re-resolve changed BEAM identities."
  def connection_status(socket, {:remote_connection_status, target_id, status} = msg) do
    {:noreply, socket} = NodeAware.handle_connection_status(socket, msg)

    if target_id == socket.assigns[:current_node_id] do
      previous = socket.assigns[:agents_scope]
      socket = sync(socket)

      if is_nil(socket.redirected) and
           match?(%{phase: :connected, node: n} when is_binary(n), status) and
           (previous != socket.assigns.agents_scope or not available?(socket.assigns)) do
        {:noreply, Phoenix.LiveView.push_patch(socket, to: socket.assigns.current_path)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @doc "Refresh the focused task only for its own events; sidebar updates are independent."
  def task_event(socket, {:task_updated, id, _status, node} = msg) do
    socket =
      if owns_task_event?(socket.assigns, id, node),
        do: AgentMerge.buffer_refresh(socket),
        else: socket

    sidebar_task_event(socket, msg, node)
  end

  def task_event(socket, {:task_deleted, id, node} = msg) do
    socket =
      if owns_task_event?(socket.assigns, id, node), do: missing_task(socket), else: socket

    sidebar_task_event(socket, msg, node)
  end

  def missing_task(socket) do
    socket
    |> reset()
    |> assign(
      scoped_task_state: :missing,
      agents_loading: false,
      config_status: socket.assigns.config_status,
      threshold_cache: socket.assigns.threshold_cache
    )
  end

  defp owns_task_event?(assigns, id, node),
    do: is_binary(id) and id == assigns[:task_scope_id] and event_from_scope?(assigns, node)

  defp sidebar_task_event(socket, msg, node) do
    if event_from_scope?(socket.assigns, node),
      do: NodeAware.handle_task_info(socket, msg),
      else: {:noreply, socket}
  end

  defp sync(socket) do
    assigns = socket.assigns
    key = {identity(assigns), available?(assigns)}
    previous = assigns[:agents_scope]

    socket =
      cond do
        previous == key and assigns[:previous_node] == assigns[:current_node] ->
          socket

        # The original bare local mount is already empty. Keep its first load
        # generation (and its dead-render loading state) unchanged.
        is_nil(previous) and key == {{nil, assigns[:previous_node], nil}, true} ->
          assign(socket, scoped_task: nil, scoped_task_state: nil)

        true ->
          reset(socket)
      end

    assign(socket, agents_scope: key, previous_node: assigns[:current_node])
  end

  defp reset(socket) do
    assigns = socket.assigns
    available? = available?(assigns)

    # Detach advances the watch token even without a watch, fencing old history
    # results on the same BEAM without counting a reset as a history operation.
    socket
    |> StreamWatch.detach()
    |> assign(
      scoped_task: nil,
      scoped_page_load: nil,
      scoped_task_state:
        if(assigns[:task_scope_id], do: if(available?, do: :loading, else: :unavailable)),
      agents_loading: available?,
      agents_error: nil,
      agents: [],
      repo_trees: [],
      id_to_display: %{},
      previous_agent_ids: MapSet.new(),
      previous_statuses: %{},
      agents_initialized: false,
      new_agent_ids: MapSet.new(),
      changed_status_ids: MapSet.new(),
      config_status: nil,
      threshold_cache: nil,
      retained_agents: %{},
      optimistic_messages: %{},
      pending_user_messages: %{},
      history_gate: %{},
      selected_agent_id: nil,
      selected_history_entry: nil,
      selected_objective: nil,
      show_usage: false,
      send_message_agent_id: nil,
      send_message_text: "",
      inspector_history_error: false,
      history_loading_agent_id: nil,
      full_message_pending_index: nil,
      full_message_pending_agent_id: nil,
      pending_agent_events: PendingEvents.new(),
      pending_agent_registration_ids: MapSet.new(),
      agent_flush_scheduled: false,
      agent_flush_token: nil,
      pending_agents_refresh: false,
      commit_graph: [],
      commit_graph_raw: %{},
      commit_graph_loaded: false,
      commit_graph_loading: false,
      commit_graph_error: nil,
      commit_graph_fingerprint: nil,
      commit_graph_fetched_at: nil,
      commit_graph_tick_scheduled: false,
      commit_graph_tick_token: nil,
      commit_fold_expanded: MapSet.new(),
      load_generation: (assigns[:load_generation] || 0) + 1,
      refresh_seq: (assigns[:refresh_seq] || 0) + 1,
      commit_graph_seq: (assigns[:commit_graph_seq] || 0) + 1
    )
  end
end
