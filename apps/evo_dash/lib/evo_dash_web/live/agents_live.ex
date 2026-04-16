defmodule EvoDashWeb.AgentsLive do
  use EvoDashWeb, :live_view

  @agent_state_table :evogit_agent_state
  @sched_meta_table :evogit_sched_meta

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
        result_sent: meta.result_sent
      }
    end)
    |> Enum.sort_by(&{&1.depth, &1.id})
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
  defp status_color(:pending), do: "text-gray-500"
  defp status_color(:running), do: "text-green-500"
  defp status_color(:waiting), do: "text-yellow-500"
  defp status_color(_), do: "text-gray-500"

  defp status_bg(:pending), do: "bg-gray-100 dark:bg-gray-800"
  defp status_bg(:running), do: "bg-green-100 dark:bg-green-900"
  defp status_bg(:waiting), do: "bg-yellow-100 dark:bg-yellow-900"
  defp status_bg(_), do: "bg-gray-100 dark:bg-gray-800"

  defp status_border(:pending), do: "border-gray-300"
  defp status_border(:running), do: "border-green-500"
  defp status_border(:waiting), do: "border-yellow-500"
  defp status_border(_), do: "border-gray-300"

  defp status_icon(:pending), do: "hero-clock"
  defp status_icon(:running), do: "hero-play-circle"
  defp status_icon(:waiting), do: "hero-pause-circle"
  defp status_icon(_), do: "hero-question-mark-circle"
end
