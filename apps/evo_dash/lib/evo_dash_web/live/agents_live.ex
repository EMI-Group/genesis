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

    socket =
      socket
      |> assign(:selected_agent_id, nil)
      |> assign(:agents, load_agents())

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_agents, socket) do
    {:noreply, assign(socket, :agents, load_agents())}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    {:noreply, assign(socket, :selected_agent_id, agent_id)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :selected_agent_id, nil)}
  end

  defp load_agents do
    sched_metas =
      case :ets.whereis(@sched_meta_table) do
        :undefined -> []
        _ -> :ets.tab2list(@sched_meta_table)
      end

    agent_states =
      case :ets.whereis(@agent_state_table) do
        :undefined -> %{}
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
        current_commit: agent_state && agent_state.phylo_node && agent_state.phylo_node.current_commit,
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
  defp status_color(:pending), do: "text-gray-500 dark:text-gray-400"
  defp status_color(:running), do: "text-green-500 dark:text-green-400"
  defp status_color(:waiting), do: "text-yellow-500 dark:text-yellow-400"
  defp status_color(_), do: "text-gray-500 dark:text-gray-400"

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
  defp history_entry_icon(_), do: "hero-document-text"

  defp history_entry_color("USER_PROMPT"), do: "text-blue-600 dark:text-blue-400"
  defp history_entry_color("CONTEXT_TREE"), do: "text-purple-600 dark:text-purple-400"
  defp history_entry_color("THOUGHT_CHUNK"), do: "text-yellow-600 dark:text-yellow-400"
  defp history_entry_color("TOOL_CALL_START"), do: "text-orange-600 dark:text-orange-400"
  defp history_entry_color("TOOL_CALL_END"), do: "text-green-600 dark:text-green-400"
  defp history_entry_color("COMPLETE"), do: "text-emerald-600 dark:text-emerald-400"
  defp history_entry_color("ERROR"), do: "text-red-600 dark:text-red-400"
  defp history_entry_color(_), do: "text-gray-600 dark:text-gray-400"

  defp format_timestamp(timestamp_ms) do
    datetime = DateTime.from_unix!(timestamp_ms, :millisecond)
    Calendar.strftime(datetime, "%H:%M:%S")
  end
end
