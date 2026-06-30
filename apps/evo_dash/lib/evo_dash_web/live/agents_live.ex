defmodule EvoDashWeb.AgentsLive do
  @moduledoc """
  Agent tree inspector.

  Renders the recursive agent hierarchy from the scheduler's runtime state
  (ETS tables), with chat-history and token/cost usage viewers.
  """
  use EvoDashWeb, :live_view

  @agent_state_table :evogit_agent_state
  @sched_meta_table :evogit_sched_meta

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "agents")
    end

    agents = load_agents()

    id_to_display =
      Map.new(agents, fn agent -> {agent.id, agent.task_local_id || agent.id} end)

    config_status = safe_config_status()

    socket =
      socket
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_history_entry, nil)
      |> assign(:selected_objective, nil)
      |> assign(:show_usage, false)
      |> assign(:agents, agents)
      |> assign(:id_to_display, id_to_display)
      |> assign(:repo_trees, build_repo_trees(agents))
      |> assign(:config_status, config_status)
      |> assign(:previous_agent_ids, MapSet.new(agents, & &1.id))
      |> assign(:previous_statuses, Map.new(agents, fn a -> {a.id, a.status} end))
      |> assign(:new_agent_ids, MapSet.new())
      |> assign(:changed_status_ids, MapSet.new())

    {:ok, socket}
  end

  @impl true
  def handle_info({:agents_updated}, socket) do
    agents = load_agents()
    current_ids = MapSet.new(agents, & &1.id)
    current_statuses = Map.new(agents, fn a -> {a.id, a.status} end)

    # Detect new agents
    new_agent_ids = MapSet.difference(current_ids, socket.assigns.previous_agent_ids)

    # Detect status changes (agents that exist in both but have different status)
    changed_status_ids =
      current_ids
      |> MapSet.intersection(socket.assigns.previous_agent_ids)
      |> MapSet.filter(fn id ->
        current_statuses[id] != socket.assigns.previous_statuses[id]
      end)

    id_to_display =
      Map.new(agents, fn agent -> {agent.id, agent.task_local_id || agent.id} end)

    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:id_to_display, id_to_display)
     |> assign(:repo_trees, build_repo_trees(agents))
     |> assign(:previous_agent_ids, current_ids)
     |> assign(:previous_statuses, current_statuses)
     |> assign(:new_agent_ids, new_agent_ids)
     |> assign(:changed_status_ids, changed_status_ids)}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    {:noreply, assign(socket, :selected_agent_id, agent_id) |> assign(:show_usage, false)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent_id, nil)
     |> assign(:selected_history_entry, nil)
     |> assign(:selected_objective, nil)
     |> assign(:show_usage, false)}
  end

  @impl true
  def handle_event("toggle_usage", _params, socket) do
    {:noreply, assign(socket, :show_usage, !socket.assigns.show_usage)}
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
    |> Enum.group_by(&grouping_key/1)
    |> Enum.map(fn {key, repo_agents} ->
      display_name = repo_display_name(key)
      tree = build_path_tree(repo_agents)
      # Rename the "." root node to the repo display name so each repo has a distinct root
      tree = rename_root(tree, display_name)
      {display_name, tree}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp grouping_key(agent) do
    agent.repo_root || agent.repo_id
  end

  defp rename_root(nodes, new_name) do
    Enum.map(nodes, fn
      %{name: "."} = node -> %{node | name: new_name}
      node -> node
    end)
  end

  defp repo_display_name(key) when is_binary(key) do
    # key is a repo root path; use the basename for display
    Path.basename(key)
  end

  defp repo_display_name(:primary), do: gettext("Primary Repo")
  defp repo_display_name(nil), do: gettext("Primary Repo")

  defp repo_display_name(repo_id) when is_atom(repo_id),
    do: gettext("Repo: %{repo_id}", repo_id: Atom.to_string(repo_id))

  defp repo_display_name(_), do: gettext("Unknown Repo")

  defp commit_bg_class(agent) do
    if agent.current_commit != agent.base_commit do
      "bg-warning/20"
    else
      "bg-base-200"
    end
  end

  defp shorten_sha(sha) when is_binary(sha) do
    if String.length(sha) > 8 do
      String.slice(sha, 0, 8) <> "…"
    else
      sha
    end
  end

  defp shorten_sha(other), do: other

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
        repo_root: agent_state && agent_state.repo_root,
        task_id: meta.task_id,
        task_number: meta.task_number,
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
        history: history,
        usage: agent_state && agent_state.usage,
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
    |> Enum.map(fn msg ->
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

      metadata = Map.get(msg, :metadata, %{})
      turn = Map.get(metadata, :turn, 0)

      base_data = %{
        content: content_text,
        tool_calls: Map.get(msg, :tool_calls),
        metadata: metadata
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
        turn: turn,
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
