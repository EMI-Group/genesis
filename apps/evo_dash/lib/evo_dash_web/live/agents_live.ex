defmodule EvoDashWeb.AgentsLive do
  @moduledoc """
  Agent tree inspector.

  Renders the recursive agent hierarchy from the scheduler's runtime state with
  chat-history and token/cost usage viewers. Node-aware: reads scheduler state
  via `EvoDash.NodeContext` so it works for both the local BEAM node and a
  remote `genesis_remote` daemon (SSH Remote Development, Phase 3). For remote
  nodes it polls periodically since cross-node PubSub may be unreliable.
  """
  use EvoDashWeb, :live_view

  alias EvoGit.Platform

  @agent_state_table :evogit_agent_state
  @sched_meta_table :evogit_sched_meta

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "agents")
    end

    # current_node is set to node() by the NodeAware on_mount hook (runs before
    # mount). handle_params/3 runs assign_node/2 next, which may switch to a
    # remote node and trigger a reload there.
    current_node = socket.assigns[:current_node] || node()
    agents = load_agents(current_node)

    id_to_display =
      Map.new(agents, fn agent -> {agent.id, agent.task_local_id || agent.id} end)

    config_status = node_config_status(current_node)

    socket =
      assign(socket,
        selected_agent_id: nil,
        selected_history_entry: nil,
        selected_objective: nil,
        show_usage: false,
        agents: agents,
        id_to_display: id_to_display,
        repo_trees: build_repo_trees(agents),
        config_status: config_status,
        previous_agent_ids: MapSet.new(agents, & &1.id),
        previous_statuses: Map.new(agents, fn a -> {a.id, a.status} end),
        new_agent_ids: MapSet.new(),
        changed_status_ids: MapSet.new(),
        previous_node: current_node
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/agents")

    current_node = socket.assigns.current_node
    previous_node = socket.assigns[:previous_node] || current_node

    socket =
      if current_node != previous_node do
        # Node changed (e.g. user switched from Local to a remote target, or
        # vice versa). Reload agents from the new node and clear per-agent
        # selection state that no longer applies. Also refresh config_status so
        # the layout config banner reflects the new node's config (not stale
        # local status).
        agents = load_agents(current_node)
        id_to_display = Map.new(agents, fn a -> {a.id, a.task_local_id || a.id} end)

        socket
        |> assign(
          agents: agents,
          id_to_display: id_to_display,
          repo_trees: build_repo_trees(agents),
          config_status: node_config_status(current_node),
          previous_agent_ids: MapSet.new(agents, & &1.id),
          previous_statuses: Map.new(agents, fn a -> {a.id, a.status} end),
          new_agent_ids: MapSet.new(),
          changed_status_ids: MapSet.new(),
          selected_agent_id: nil,
          selected_history_entry: nil,
          selected_objective: nil,
          previous_node: current_node
        )
      else
        assign(socket, :previous_node, current_node)
      end

    # For remote nodes, cross-node PubSub may not deliver scheduler events
    # reliably. Start a periodic poll (reschedules itself in the handler only
    # while viewing a remote node). For the local node we rely on PubSub, so no
    # poll is scheduled. Guard with the :remote_poll_timer assign so we don't
    # schedule overlapping timers on repeated handle_params calls.
    socket =
      if current_node != node() and connected?(socket) and
           not socket.assigns[:remote_poll_timer] do
        Process.send_after(self(), :remote_poll, 3_000)
        assign(socket, :remote_poll_timer, true)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  # Backward-compatible fallback — enriched deltas (agent_registered/updated/removed) handle most updates
  def handle_info({:agents_updated}, socket) do
    agents = load_agents(socket.assigns.current_node)
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

    # Reload history for the selected agent (wiped by load_agents)
    agents =
      reload_selected_agent_history(
        agents,
        socket.assigns.selected_agent_id,
        socket.assigns.current_node
      )

    {:noreply,
     assign(socket,
       agents: agents,
       id_to_display: id_to_display,
       repo_trees: build_repo_trees(agents),
       previous_agent_ids: current_ids,
       previous_statuses: current_statuses,
       new_agent_ids: new_agent_ids,
       changed_status_ids: changed_status_ids
     )}
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:tasks_updated}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, :tasks_updated)
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, :task_status)
  end

  @impl true
  def handle_info(:remote_poll, socket) do
    current_node = socket.assigns.current_node

    if current_node != node() do
      # Still viewing a remote node — reload agents and reschedule the poll.
      agents = load_agents(current_node)
      current_ids = MapSet.new(agents, & &1.id)
      current_statuses = Map.new(agents, fn a -> {a.id, a.status} end)

      new_agent_ids = MapSet.difference(current_ids, socket.assigns.previous_agent_ids)

      changed_status_ids =
        current_ids
        |> MapSet.intersection(socket.assigns.previous_agent_ids)
        |> MapSet.filter(fn id ->
          current_statuses[id] != socket.assigns.previous_statuses[id]
        end)

      id_to_display = Map.new(agents, fn a -> {a.id, a.task_local_id || a.id} end)

      agents =
        reload_selected_agent_history(agents, socket.assigns.selected_agent_id, current_node)

      Process.send_after(self(), :remote_poll, 3_000)

      {:noreply,
       assign(socket,
         agents: agents,
         id_to_display: id_to_display,
         repo_trees: build_repo_trees(agents),
         previous_agent_ids: current_ids,
         previous_statuses: current_statuses,
         new_agent_ids: new_agent_ids,
         changed_status_ids: changed_status_ids
       )}
    else
      # Switched back to local — stop polling (PubSub handles local updates).
      {:noreply, assign(socket, :remote_poll_timer, false)}
    end
  end

  @impl true
  def handle_info({:agent_registered, agent_id, meta_summary}, socket) do
    # Check for duplicate (race with :agents_updated fallback)
    already_exists = Enum.any?(socket.assigns.agents, fn a -> a.id == agent_id end)

    if already_exists do
      {:noreply, socket}
    else
      if socket.assigns.current_node != node() do
        # Remote node — ETS tables are local; the incremental PubSub update
        # can't read remote ETS. Fall back to a full reload via RPC.
        {:noreply, full_reload(socket)}
      else
        # Local node — read ETS directly for the incremental update.
        # See handle_local_agent_registered/3 in the helpers section.
        {:noreply, handle_local_agent_registered(socket, agent_id, meta_summary)}
      end
    end
  end

  @impl true
  def handle_info({:agent_updated, agent_id, changed_fields}, socket) do
    agents = socket.assigns.agents
    agent_idx = Enum.find_index(agents, fn a -> a.id == agent_id end)

    if agent_idx == nil do
      # Race — agent not yet in our list, do a full reload
      agents = load_agents(socket.assigns.current_node)
      current_ids = MapSet.new(agents, & &1.id)
      current_statuses = Map.new(agents, fn a -> {a.id, a.status} end)

      # Reload history for the selected agent (wiped by load_agents)
      agents =
        reload_selected_agent_history(
          agents,
          socket.assigns.selected_agent_id,
          socket.assigns.current_node
        )

      {:noreply,
       assign(socket,
         agents: agents,
         id_to_display: Map.new(agents, fn a -> {a.id, a.task_local_id || a.id} end),
         repo_trees: build_repo_trees(agents),
         previous_agent_ids: current_ids,
         previous_statuses: current_statuses,
         new_agent_ids: MapSet.new(),
         changed_status_ids: MapSet.new()
       )}
    else
      agent = Enum.at(agents, agent_idx)

      # Track old parent_id for children recalculation
      old_parent_id = agent.parent_id

      # Convert changed_fields keyword list to a map for merging
      changed_map =
        changed_fields
        |> Enum.into(%{})
        |> handle_special_fields()

      # Merge changed fields into agent
      agent = Map.merge(agent, changed_map)

      # Recalculate compression_pct if total_tokens changed
      agent =
        if Keyword.has_key?(changed_fields, :total_tokens) do
          threshold = agent.compression_threshold
          pct = trunc(min(agent.total_tokens / max(threshold, 1) * 100, 100))
          %{agent | compression_pct: pct}
        else
          agent
        end

      agents = List.replace_at(agents, agent_idx, agent)

      # Recalculate children if parent_id changed
      agents =
        if Keyword.has_key?(changed_fields, :parent_id) do
          new_parent_id = agent.parent_id

          agents
          |> maybe_update_parent_children(old_parent_id)
          |> maybe_update_parent_children(new_parent_id)
        else
          agents
        end

      # Reload history if the updated agent is currently selected
      agents =
        if agent_id == socket.assigns.selected_agent_id do
          history = load_agent_history(socket.assigns.current_node, agent_id)
          update_agent_in_list(agents, agent_id, fn a -> %{a | history: history} end)
        else
          agents
        end

      # Detect status change
      old_status = socket.assigns.previous_statuses[agent_id]
      new_status = agent.status

      previous_statuses = socket.assigns.previous_statuses
      changed_status_ids = socket.assigns.changed_status_ids

      {previous_statuses, changed_status_ids} =
        if old_status != new_status do
          {Map.put(previous_statuses, agent_id, new_status),
           MapSet.put(changed_status_ids, agent_id)}
        else
          {previous_statuses, changed_status_ids}
        end

      # Update id_to_display if task_local_id changed
      id_to_display = socket.assigns.id_to_display

      id_to_display =
        if Keyword.has_key?(changed_fields, :task_local_id) do
          Map.put(id_to_display, agent_id, agent.task_local_id || agent_id)
        else
          id_to_display
        end

      # Rebuild repo_trees only if context_node or repo_root changed
      repo_trees =
        if Keyword.has_key?(changed_fields, :context_node) or
             Keyword.has_key?(changed_fields, :repo_root) do
          build_repo_trees(agents)
        else
          socket.assigns.repo_trees
        end

      {:noreply,
       assign(socket,
         agents: agents,
         id_to_display: id_to_display,
         repo_trees: repo_trees,
         previous_statuses: previous_statuses,
         changed_status_ids: changed_status_ids
       )}
    end
  end

  @impl true
  def handle_info({:agent_removed, agent_id}, socket) do
    agents = socket.assigns.agents
    removed_agent = Enum.find(agents, fn a -> a.id == agent_id end)

    if removed_agent == nil do
      {:noreply, socket}
    else
      parent_id = removed_agent.parent_id

      # Remove the agent
      agents = Enum.reject(agents, fn a -> a.id == agent_id end)

      # Set parent_id to nil for orphaned children
      agents =
        Enum.map(agents, fn a ->
          if a.parent_id == agent_id, do: %{a | parent_id: nil}, else: a
        end)

      # Recalculate children for the removed agent's parent
      agents = maybe_update_parent_children(agents, parent_id)

      # Remove from tracking sets
      id_to_display = Map.delete(socket.assigns.id_to_display, agent_id)
      previous_agent_ids = MapSet.delete(socket.assigns.previous_agent_ids, agent_id)
      new_agent_ids = MapSet.delete(socket.assigns.new_agent_ids, agent_id)
      previous_statuses = Map.delete(socket.assigns.previous_statuses, agent_id)

      # Clear selection if the removed agent was selected
      selected_agent_id =
        if socket.assigns.selected_agent_id == agent_id do
          nil
        else
          socket.assigns.selected_agent_id
        end

      repo_trees = build_repo_trees(agents)

      {:noreply,
       assign(socket,
         agents: agents,
         id_to_display: id_to_display,
         repo_trees: repo_trees,
         previous_agent_ids: previous_agent_ids,
         new_agent_ids: new_agent_ids,
         previous_statuses: previous_statuses,
         selected_agent_id: selected_agent_id
       )}
    end
  end

  @impl true
  def handle_info({:update_agent_history, agent_id, history}, socket) do
    agents = socket.assigns.agents
    agent_idx = Enum.find_index(agents, fn a -> a.id == agent_id end)

    if agent_idx do
      agent = Enum.at(agents, agent_idx)
      updated_agent = %{agent | history: history}
      updated_agents = List.replace_at(agents, agent_idx, updated_agent)
      {:noreply, assign(socket, :agents, updated_agents)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)

    socket = assign(socket, :selected_agent_id, agent_id) |> assign(:show_usage, false)

    # Lazy-load chat history for the selected agent
    agents = socket.assigns.agents
    agent_idx = Enum.find_index(agents, fn a -> a.id == agent_id end)

    socket =
      if agent_idx do
        agent = Enum.at(agents, agent_idx)
        history = load_agent_history(socket.assigns.current_node, agent_id)
        updated_agent = %{agent | history: history}
        updated_agents = List.replace_at(agents, agent_idx, updated_agent)
        assign(socket, :agents, updated_agents)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply,
     assign(socket,
       selected_agent_id: nil,
       selected_history_entry: nil,
       selected_objective: nil,
       show_usage: false
     )}
  end

  @impl true
  def handle_event("toggle_usage", _params, socket) do
    {:noreply, assign(socket, :show_usage, !socket.assigns.show_usage)}
  end

  @impl true
  def handle_event("view_full_message", %{"index" => index}, socket) do
    index = String.to_integer(index)

    agent = Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.selected_agent_id))

    # Safety net: if history is empty, lazy-load it first
    agent =
      if agent && agent.history == [] do
        history = load_agent_history(socket.assigns.current_node, agent.id)
        send(self(), {:update_agent_history, agent.id, history})
        %{agent | history: history}
      else
        agent
      end

    entry = agent && Enum.at(agent.history || [], index)

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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp handle_special_fields(changed_map) do
    changed_map =
      if Map.has_key?(changed_map, :context_node) do
        context_node = changed_map[:context_node]
        path = context_node && context_node.path

        changed_map
        |> Map.put(:context_path, path)
        |> Map.delete(:context_node)
      else
        changed_map
      end

    changed_map =
      if Map.has_key?(changed_map, :phylo_node) do
        phylo_node = changed_map[:phylo_node]
        current_commit = phylo_node && phylo_node.current_commit

        changed_map
        |> Map.put(:current_commit, current_commit)
        |> Map.delete(:phylo_node)
      else
        changed_map
      end

    if Map.has_key?(changed_map, :usage) && is_nil(changed_map[:usage]) do
      Map.put(changed_map, :usage, EvoGit.Agent.Usage.zero())
    else
      changed_map
    end
  end

  defp update_agent_in_list(agents, agent_id, updater_fn) do
    idx = Enum.find_index(agents, fn a -> a.id == agent_id end)

    if idx do
      List.replace_at(agents, idx, updater_fn.(Enum.at(agents, idx)))
    else
      agents
    end
  end

  # Full reload of the agent list from the current node, recomputing all the
  # tracking assigns. Used by the remote agent_registered path (where ETS is
  # not accessible) and any other path that needs a clean refresh.
  defp full_reload(socket) do
    current_node = socket.assigns.current_node
    agents = load_agents(current_node)
    current_ids = MapSet.new(agents, & &1.id)
    current_statuses = Map.new(agents, fn a -> {a.id, a.status} end)
    id_to_display = Map.new(agents, fn a -> {a.id, a.task_local_id || a.id} end)

    agents = reload_selected_agent_history(agents, socket.assigns.selected_agent_id, current_node)

    assign(socket,
      agents: agents,
      id_to_display: id_to_display,
      repo_trees: build_repo_trees(agents),
      previous_agent_ids: current_ids,
      previous_statuses: current_statuses,
      new_agent_ids: MapSet.new(),
      changed_status_ids: MapSet.new()
    )
  end

  # Incremental agent registration handler for the LOCAL node. Reads ETS
  # directly (the tables are local). Returns the updated socket.
  defp handle_local_agent_registered(socket, agent_id, meta_summary) do
    # Look up agent_state from ETS (may be nil for brand-new agents)
    agent_state =
      case :ets.lookup(@agent_state_table, agent_id) do
        [{^agent_id, state}] -> state
        [] -> nil
      end

    # Look up sched_meta from ETS for fields not in meta_summary
    sched_meta =
      case :ets.lookup(@sched_meta_table, agent_id) do
        [{^agent_id, meta}] -> meta
        [] -> nil
      end

    total_tokens = (agent_state && agent_state.total_tokens) || 0
    compression_count = (agent_state && agent_state.compression_count) || 0
    compression_threshold = safe_compression_threshold(socket.assigns.current_node)

    compression_pct =
      trunc(min(total_tokens / max(compression_threshold, 1) * 100, 100))

    new_agent = %{
      id: agent_id,
      task_local_id: (agent_state && agent_state.task_local_id) || agent_id,
      repo_id: (agent_state && agent_state.repo_id) || "primary",
      repo_root: agent_state && agent_state.repo_root,
      task_id: meta_summary[:task_id] || (sched_meta && sched_meta.task_id),
      task_number: meta_summary[:task_number] || (sched_meta && sched_meta.task_number),
      status: meta_summary[:status] || :pending,
      depth: meta_summary[:depth] || 0,
      parent_id: meta_summary[:parent_id] || (sched_meta && sched_meta.parent_id),
      worktree: sched_meta && sched_meta.worktree,
      retries: (sched_meta && sched_meta.retries) || 0,
      agent_module: sched_meta && sched_meta.spec.agent_module,
      objective: meta_summary[:objective] || (sched_meta && sched_meta.spec.objective),
      context_path: agent_state && agent_state.context_node && agent_state.context_node.path,
      current_commit:
        agent_state && agent_state.phylo_node && agent_state.phylo_node.current_commit,
      base_commit: sched_meta && sched_meta.spec.phylo_node.base_commit,
      children: [],
      has_children: false,
      pending_sub_agents: (sched_meta && MapSet.to_list(sched_meta.pending_sub_agents)) || [],
      sub_agent_results: (sched_meta && sched_meta.sub_agent_results) || %{},
      task_ref: sched_meta && sched_meta.task_ref,
      result_sent: (sched_meta && sched_meta.result_sent) || false,
      history: [],
      usage: (agent_state && agent_state.usage) || EvoGit.Agent.Usage.zero(),
      total_tokens: total_tokens,
      compression_count: compression_count,
      compression_threshold: compression_threshold,
      compression_pct: compression_pct
    }

    agents = socket.assigns.agents

    # Insert at correct sorted position (by {depth, id})
    insert_idx =
      Enum.find_index(agents, fn a -> {a.depth, a.id} > {new_agent.depth, new_agent.id} end)

    agents =
      if insert_idx do
        List.insert_at(agents, insert_idx, new_agent)
      else
        agents ++ [new_agent]
      end

    # Update parent's children if parent_id is set
    agents =
      if new_agent.parent_id do
        update_agent_in_list(agents, new_agent.parent_id, fn parent ->
          children = find_children_from_agents(parent.id, agents)
          %{parent | children: children, has_children: length(children) > 0}
        end)
      else
        agents
      end

    id_to_display =
      Map.put(socket.assigns.id_to_display, agent_id, new_agent.task_local_id || agent_id)

    previous_agent_ids = MapSet.put(socket.assigns.previous_agent_ids, agent_id)
    new_agent_ids = MapSet.put(socket.assigns.new_agent_ids, agent_id)
    repo_trees = build_repo_trees(agents)

    assign(socket,
      agents: agents,
      id_to_display: id_to_display,
      repo_trees: repo_trees,
      previous_agent_ids: previous_agent_ids,
      new_agent_ids: new_agent_ids
    )
  end

  defp maybe_update_parent_children(agents, nil), do: agents

  defp maybe_update_parent_children(agents, parent_id) do
    update_agent_in_list(agents, parent_id, fn parent ->
      children = find_children_from_agents(parent.id, agents)
      %{parent | children: children, has_children: length(children) > 0}
    end)
  end

  defp find_children_from_agents(parent_id, agents) do
    agents
    |> Enum.filter(fn a -> a.parent_id == parent_id end)
    |> Enum.map(fn a -> {a.id, a.status} end)
    |> Enum.sort_by(fn {id, _} -> id end)
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

  defp repo_display_name("primary"), do: gettext("Primary Repo")
  defp repo_display_name(:primary), do: gettext("Primary Repo")
  defp repo_display_name(nil), do: gettext("Primary Repo")

  # An absolute path on any platform (Unix /foo or Windows C:\foo) — use the basename.
  defp repo_display_name(key) when is_binary(key) do
    if Platform.absolute_path?(key) do
      Path.basename(key)
    else
      gettext("Repo: %{repo_id}", repo_id: key)
    end
  end

  # Backward compat / defensive: atom repo_ids from older ETS data.
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

  # Loads all agents for the given node. Reads scheduler state via
  # `EvoDash.NodeContext.list_agents/1`, which returns summary maps. On the
  # local node this reads the local ETS-backed RemoteAPI directly (no :erpc);
  # on a remote node it routes through :erpc.call/5, which transfers native
  # Elixir terms (atoms, structs) directly — no serialization boundary.
  #
  # The RPC summaries provide the fields the rendering code expects, including
  # the agent metadata fields (repo_root, context_path, current_commit,
  # base_commit, worktree, task_id, task_number, retries) which are now exposed
  # by the RemoteAPI summary layer. Fields not in the summary are read via
  # bracket access (summary[:field]) so they default to nil gracefully.
  defp load_agents(node) do
    summaries = EvoDash.NodeContext.list_agents(node)
    compression_threshold = safe_compression_threshold(node)
    # Minimal {id, parent_id, status} list used for children computation.
    parent_lookup = summaries_to_agents(summaries)

    summaries
    |> Enum.map(fn summary ->
      total_tokens = summary[:total_tokens] || 0
      compression_count = summary[:compression_count] || 0

      compression_pct =
        trunc(min(total_tokens / max(compression_threshold, 1) * 100, 100))

      %{
        id: summary[:id],
        task_local_id: summary[:task_local_id],
        repo_id: summary[:repo_id] || "primary",
        repo_root: summary[:repo_root],
        task_id: summary[:task_id],
        task_number: summary[:task_number],
        status: summary[:status] || :pending,
        depth: summary[:depth] || 0,
        parent_id: summary[:parent_id],
        worktree: summary[:worktree],
        retries: summary[:retries] || 0,
        agent_module: parse_agent_module(summary[:agent_module]),
        objective: summary[:objective] || "",
        context_path: summary[:context_path],
        current_commit: summary[:current_commit],
        base_commit: summary[:base_commit],
        # children/has_children are computed after the full list is built
        children: [],
        has_children: false,
        pending_sub_agents: [],
        sub_agent_results: %{},
        task_ref: nil,
        result_sent: false,
        history: [],
        usage: normalize_usage(summary[:usage]),
        total_tokens: total_tokens,
        compression_count: compression_count,
        compression_threshold: compression_threshold,
        compression_pct: compression_pct
      }
    end)
    # Compute children from the full list using parent_id relationships.
    |> Enum.map(fn agent ->
      children = find_children_from_agents(agent.id, parent_lookup)
      %{agent | children: children, has_children: length(children) > 0}
    end)
    |> Enum.sort_by(&{&1.depth, &1.id})
  end

  # Builds a minimal agent list (only id/parent_id/status) from the RPC
  # summaries, used by find_children_from_agents/2 which keys off parent_id.
  defp summaries_to_agents(summaries) do
    Enum.map(summaries, fn s ->
      %{id: s[:id], parent_id: s[:parent_id], status: s[:status] || :pending}
    end)
  end

  # RemoteAPI returns agent_module as a native module atom
  # (e.g. EvoGit.Agents.Manager), transferred directly by :erpc.call/5.
  # The rendering code calls inspect/1 on it; return the atom so it displays
  # correctly. Returns nil when absent.
  defp parse_agent_module(nil), do: nil
  defp parse_agent_module(module) when is_atom(module), do: module

  # Normalizes the usage value from an agent summary into a struct so the
  # rendering code (which reads usage.input_tokens etc.) works uniformly.
  # :erpc.call/5 transfers the native %EvoGit.Agent.Usage{} struct directly —
  # no serialization boundary — so we just return it (with a nil → zero
  # fallback for agents that have no usage yet).
  defp normalize_usage(nil), do: EvoGit.Agent.Usage.zero()

  defp normalize_usage(%EvoGit.Agent.Usage{} = usage), do: usage

  defp normalize_usage(_), do: EvoGit.Agent.Usage.zero()

  # Reads the compression threshold for the given node. On the local node this
  # resolves the local config directly; on a remote node it reads the remote
  # scheduler config. Falls back to 100_000 when unavailable.
  defp safe_compression_threshold(node) do
    if node == node() do
      EvoGit.Config.resolve([:llm, :compression_threshold_tokens]) || 100_000
    else
      config = EvoDash.NodeContext.get_remote_config(node)
      get_in(config, [:llm, :compression_threshold_tokens]) || 100_000
    end
  end

  # Reads the config health status for the given node. On the local node this
  # resolves the local config directly; on a remote node it fetches the remote
  # config status via RPC. The layout config banner uses this to show the
  # correct status for the node being viewed (not stale local status).
  defp node_config_status(node) do
    if node == node() do
      EvoGit.Config.config_status()
    else
      EvoDash.NodeContext.get_remote_config_status(node)
    end
  end

  # Loads the conversation history for an agent on the given node. RemoteAPI
  # returns native %ReqLLM.Message{} structs (transferred directly by
  # :erpc.call/5); we convert them to the %{turn, type, data} entry shape the
  # template expects via messages_to_history_entries/1. On the local node this
  # reads the local RemoteAPI (same format), so both local and remote paths are
  # unified.
  defp load_agent_history(node, agent_id) do
    EvoDash.NodeContext.get_agent_history(node, agent_id)
    |> messages_to_history_entries()
  end

  # Converts native %ReqLLM.Message{} structs into the %{turn, type, data}
  # entry format the template consumes. The only legitimate conversion here is
  # extracting display text from the ContentPart list → a single string; all
  # other fields are passed through as native terms.
  defp messages_to_history_entries(messages) when is_list(messages) do
    Enum.map(messages, &message_to_history_entry/1)
  end

  defp message_to_history_entry(%ReqLLM.Message{} = msg) do
    %{
      turn: Map.get(msg.metadata, :turn) || 0,
      type: Atom.to_string(msg.role),
      data: %{
        content:
          msg.content
          |> Enum.map(&Map.get(&1, :text))
          |> Enum.reject(&is_nil/1)
          |> Enum.join(),
        tool_calls: msg.tool_calls,
        reasoning_details: msg.reasoning_details,
        tool_name: Map.get(msg.metadata, :tool_name) || msg.name,
        metadata: msg.metadata
      }
    }
  end

  # Reloads history for the selected agent in the agents list.
  # Returns the updated agents list (no-op if selected_agent_id is nil or not found).
  defp reload_selected_agent_history(agents, nil, _node), do: agents

  defp reload_selected_agent_history(agents, selected_agent_id, node) do
    history = load_agent_history(node, selected_agent_id)
    update_agent_in_list(agents, selected_agent_id, fn agent -> %{agent | history: history} end)
  end
end
