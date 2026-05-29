defmodule EvoDashWeb.AgentsLive do
  use EvoDashWeb, :live_view

  @agent_state_table :evogit_agent_state
  @sched_meta_table :evogit_sched_meta

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :refresh_agents)
    end

    agents = load_agents()

    id_to_display =
      Map.new(agents, fn agent -> {agent.id, agent.task_local_id || agent.id} end)

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    socket =
      socket
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_history_entry, nil)
      |> assign(:selected_objective, nil)
      |> assign(:agents, agents)
      |> assign(:id_to_display, id_to_display)
      |> assign(:repo_trees, build_repo_trees(agents))
      |> assign(:config_status, config_status)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_agents, socket) do
    agents = load_agents()

    id_to_display =
      Map.new(agents, fn agent -> {agent.id, agent.task_local_id || agent.id} end)

    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:id_to_display, id_to_display)
     |> assign(:repo_trees, build_repo_trees(agents))}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    {:noreply, assign(socket, :selected_agent_id, agent_id)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent_id, nil)
     |> assign(:selected_history_entry, nil)
     |> assign(:selected_objective, nil)}
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

  @impl true
  def handle_event("view_full_objective", _params, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.selected_agent_id))

    if agent do
      {:noreply, assign(socket, :selected_objective, agent.objective)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_objective_modal", _params, socket) do
    {:noreply, assign(socket, :selected_objective, nil)}
  end

  defp build_repo_trees(agents) do
    agents
    |> Enum.group_by(& &1.repo_id)
    |> Enum.map(fn {repo_id, repo_agents} ->
      display_name = repo_display_name(repo_id)
      tree = build_path_tree(repo_agents)
      # Rename the "." root node to the repo display name so each repo has a distinct root
      tree = rename_root(tree, display_name)
      {display_name, tree}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp rename_root(nodes, new_name) do
    Enum.map(nodes, fn
      %{name: "."} = node -> %{node | name: new_name}
      node -> node
    end)
  end

  defp repo_display_name(:primary), do: "Primary Repo"
  defp repo_display_name(nil), do: "Primary Repo"

  defp repo_display_name(repo_id) when is_atom(repo_id),
    do: "Repo: #{Atom.to_string(repo_id)}"

  defp repo_display_name(_), do: "Unknown Repo"

  defp build_path_tree(agents) do
    tree =
      Enum.reduce(agents, %{}, fn agent, acc ->
        path = agent.context_path || "./"
        path = if path == "/", do: "./", else: path

        segments =
          path
          |> Path.split()
          |> case do
            ["." | rest] -> ["." | rest]
            other -> ["." | other]
          end

        insert_into_tree(acc, segments, [], agent)
      end)

    sort_tree(tree)
  end

  defp insert_into_tree(tree, [], _acc_segments, _agent), do: tree

  defp insert_into_tree(tree, [segment | rest], acc_segments, agent) do
    current_segments = acc_segments ++ [segment]
    current_path = Path.join(current_segments)

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
        task_local_id: agent_state && agent_state.task_local_id,
        repo_id: agent_state && agent_state.repo_id,
        task_id: meta.task_id,
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
    case :ets.lookup(@agent_state_table, agent_id) do
      [{^agent_id, agent_state}] ->
        case Map.get(agent_state, :context) do
          nil -> []
          %ReqLLM.Context{messages: messages} -> convert_messages_to_history(messages)
          _ -> []
        end

      [] ->
        []
    end
  end

  # Converts ReqLLM.Message structs to history entry format
  defp convert_messages_to_history(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, index} ->
      content_text =
        case msg.content do
          parts when is_list(parts) ->
            parts
            |> Enum.map(fn
              %{type: :thinking} -> ""
              %{text: text} when is_binary(text) -> text
              _ -> ""
            end)
            |> Enum.join("")

          _ ->
            ""
        end

      base_data = %{
        content: content_text,
        tool_calls: Map.get(msg, :tool_calls),
        metadata: Map.get(msg, :metadata, %{})
      }

      data =
        case msg.role do
          :tool ->
            Map.put(base_data, :tool_name, Map.get(msg, :name))

          :assistant ->
            Map.put(base_data, :reasoning_details, Map.get(msg, :reasoning_details))

          _ ->
            base_data
        end

      %{
        turn: index + 1,
        type: Atom.to_string(msg.role),
        data: data
      }
    end)
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
end
