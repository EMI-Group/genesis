defmodule EvoDashWeb.AgentsLive do
  use EvoDashWeb, :live_view

  @agent_state_table :evogit_agent_state
  @sched_meta_table :evogit_sched_meta
  @history_table :evogit_agent_history

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :refresh_agents)
    end

    agents = load_agents()

    socket =
      socket
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_history_entry, nil)
      |> assign(:agents, agents)
      |> assign(:path_tree, build_path_tree(agents))

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_agents, socket) do
    agents = load_agents()
    {:noreply, socket |> assign(:agents, agents) |> assign(:path_tree, build_path_tree(agents))}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    {:noreply, assign(socket, :selected_agent_id, agent_id)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, socket |> assign(:selected_agent_id, nil) |> assign(:selected_history_entry, nil)}
  end

  @impl true
  def handle_event("view_full_message", %{"index" => index}, socket) do
    index = String.to_integer(index)

    agent = Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.selected_agent_id))
    entry = Enum.at(agent.history || [], index)

    {:noreply, assign(socket, :selected_history_entry, entry)}
  end

  @impl true
  def handle_event("close_message_modal", _params, socket) do
    {:noreply, assign(socket, :selected_history_entry, nil)}
  end

  defp build_path_tree(agents) do
    tree =
      Enum.reduce(agents, %{}, fn agent, acc ->
        path = agent.context_path || "/"
        segments = if path == "/", do: ["/"], else: String.split(path, "/", trim: true)
        insert_into_tree(acc, segments, [], agent)
      end)

    sort_tree(tree)
  end

  defp insert_into_tree(tree, [], _acc_segments, _agent), do: tree

  defp insert_into_tree(tree, [segment | rest], acc_segments, agent) do
    current_segments = acc_segments ++ [segment]
    current_path = if segment == "/", do: "/", else: Enum.join(current_segments, "/")

    node = Map.get(tree, segment, %{name: segment, path: current_path, agents: [], children: %{}})

    if rest == [] do
      node = %{node | agents: [agent | node.agents]}
      Map.put(tree, segment, node)
    else
      node = %{node | children: insert_into_tree(node.children, rest, current_segments, agent)}
      Map.put(tree, segment, node)
    end
  end

  defp sort_tree(tree) do
    tree
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn node ->
      %{node | children: sort_tree(node.children), agents: Enum.sort_by(node.agents, & &1.id)}
    end)
  end

  defp load_agents do
    sched_metas =
      case :ets.whereis(@sched_meta_table) do
        :undefined -> []
        _ -> :ets.tab2list(@sched_meta_table)
      end

    agent_states =
      case :ets.whereis(@agent_state_table) do
        :undefined ->
          %{}

        _ ->
          :ets.tab2list(@agent_state_table)
          |> Enum.into(%{})
      end

    sched_metas
    |> Enum.map(fn {id, meta} ->
      agent_state = Map.get(agent_states, id)
      children = find_children(id, sched_metas)
      history = load_agent_history(id)

      %{
        id: id,
        status: meta.status,
        depth: meta.depth,
        parent_id: meta.parent_id,
        worktree: meta.worktree,
        retries: meta.retries,
        agent_module: meta.spec.agent_module,
        objective: meta.spec.objective,
        context_path: agent_state && agent_state.context_node && agent_state.context_node.path,
        current_commit:
          agent_state && agent_state.phylo_node && agent_state.phylo_node.current_commit,
        base_commit: meta.spec.phylo_node.base_commit,
        children: children,
        has_children: length(children) > 0,
        pending_sub_agents: MapSet.to_list(meta.pending_sub_agents),
        sub_agent_results: meta.sub_agent_results,
        task_ref: meta.task_ref,
        result_sent: meta.result_sent,
        history: history
      }
    end)
    |> Enum.sort_by(&{&1.depth, &1.id})
  end

  defp load_agent_history(agent_id) do
    case :ets.whereis(@history_table) do
      :undefined -> []
      _ -> :ets.tab2list(@history_table)
    end
    |> Enum.filter(fn {id, _entry} -> id == agent_id end)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(& &1.timestamp)
  end

  defp find_children(parent_id, sched_metas) do
    Enum.filter(sched_metas, fn {_, meta} ->
      meta.parent_id == parent_id
    end)
    |> Enum.map(fn {id, meta} ->
      {id, meta.status}
    end)
    |> Enum.sort_by(fn {id, _} -> id end)
  end

  # Helper functions for the template
  defp status_color(:pending), do: "badge-ghost"
  defp status_color(:running), do: "badge-success badge-outline border-success/30 bg-success/10"
  defp status_color(:waiting), do: "badge-warning badge-outline border-warning/30 bg-warning/10"
  defp status_color(_), do: "badge-ghost"

  defp status_icon(:pending), do: "hero-clock"
  defp status_icon(:running), do: "hero-play-circle"
  defp status_icon(:waiting), do: "hero-pause-circle"
  defp status_icon(_), do: "hero-question-mark-circle"

  defp history_entry_icon("USER_PROMPT"), do: "hero-chat-bubble-left-ellipsis"
  defp history_entry_icon("CONTEXT_TREE"), do: "hero-squares-2x2"
  defp history_entry_icon("THOUGHT_CHUNK"), do: "hero-light-bulb"
  defp history_entry_icon("TOOL_CALL_START"), do: "hero-cog-6-tooth"
  defp history_entry_icon("TOOL_CALL_END"), do: "hero-check-circle"
  defp history_entry_icon("COMPLETE"), do: "hero-flag-checkered"
  defp history_entry_icon("ERROR"), do: "hero-exclamation-triangle"
  defp history_entry_icon("RETRY"), do: "hero-arrow-path"
  defp history_entry_icon("RETRY_DISPATCH"), do: "hero-arrow-clockwise"
  defp history_entry_icon("QUEUED"), do: "hero-clock"
  defp history_entry_icon(_), do: "hero-document-text"

  defp history_entry_color("USER_PROMPT"), do: "text-info"
  defp history_entry_color("CONTEXT_TREE"), do: "text-secondary"
  defp history_entry_color("THOUGHT_CHUNK"), do: "text-warning"
  defp history_entry_color("TOOL_CALL_START"), do: "text-accent"
  defp history_entry_color("TOOL_CALL_END"), do: "text-success"
  defp history_entry_color("COMPLETE"), do: "text-success"
  defp history_entry_color("ERROR"), do: "text-error"
  defp history_entry_color("RETRY"), do: "text-warning"
  defp history_entry_color("RETRY_DISPATCH"), do: "text-warning"
  defp history_entry_color("QUEUED"), do: "text-base-content/50"
  defp history_entry_color(_), do: "text-base-content/50"

  defp format_timestamp(timestamp_ms) do
    datetime = DateTime.from_unix!(timestamp_ms, :millisecond)
    Calendar.strftime(datetime, "%H:%M:%S")
  end
end
