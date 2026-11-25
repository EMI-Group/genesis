defmodule EvoDashWeb.AgentsLive.Inspector do
  @moduledoc """
  Selected-agent inspector for the Agents page.
  It owns the selection, the push stream watch, checkpoint-history projection
  and the independent history-fetch fallback for unwatchable agents.
  Every entry point returns the updated socket (or the liveview callback's
  `{:noreply, socket}` tuple) and never renders.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias EvoDash.SafeCall

  alias EvoDashWeb.AgentsLive.{AgentList, HistoryGate, OptimisticMessages, Scope, StreamWatch}

  alias EvoDashWeb.ContentText

  @doc """
  Parses a positive agent id out of a string param, else `nil`.
  """
  @spec parse_agent_id(term()) :: pos_integer() | nil
  def parse_agent_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  def parse_agent_id(_value), do: nil

  @doc """
  Selects the pending `requested_agent_id` (consumed once), else no-op.
  """
  def select_requested(%{assigns: %{requested_agent_id: nil}} = socket), do: socket

  def select_requested(socket) do
    agent_id = socket.assigns.requested_agent_id
    socket = assign(socket, :requested_agent_id, nil)
    select_agent_impl(socket, agent_id)
  end

  @doc """
  Selects the agent named by a string id param (`nil` for unparsable input).
  """
  def select(socket, id_param) do
    case parse_agent_id(id_param) do
      nil -> socket
      agent_id -> select_agent_impl(socket, agent_id)
    end
  end

  @doc """
  Attaches the stream watch for the selected agent, if one is selected.
  """
  def maybe_attach(socket) do
    case socket.assigns.selected_agent_id do
      id when is_integer(id) and id > 0 -> StreamWatch.attach(socket, id)
      _ -> socket
    end
  end

  @doc """
  Detaches the stream watch when the selected agent is gone from the tree.
  """
  def detach_absent(socket) do
    id = socket.assigns.selected_agent_id

    if socket.assigns.inspector_stream != nil and not StreamWatch.owns?(socket, id) and
         not Enum.any?(socket.assigns.agents, &(&1.id == id)) do
      socket
      |> StreamWatch.detach()
      |> clear_history_loading_flags(id)
    else
      socket
    end
  end

  @doc """
  Whether the watched stream owns this agent's checkpoint history.
  """
  # Failed watches still own the last coherent checkpoint/live pair. Health is
  # not an ownership test: independent history must wait until detachment.
  def owns_checkpoint?(socket, agent_id), do: StreamWatch.owns?(socket, agent_id)

  @doc """
  The selected agent row, falling back to its retained terminal detail.
  """
  def selected_inspector_agent(assigns) do
    AgentList.find(assigns.agents, assigns.selected_agent_id) ||
      if StreamWatch.owns?(%{assigns: assigns}, assigns.selected_agent_id) do
        Map.get(assigns.retained_agents, assigns.selected_agent_id)
      end
  end

  @doc """
  Seals an agent row with the stream's terminal snapshot when it owns it.
  """
  # A sealed snapshot's explicit status outranks late summaries. Older snapshots
  # may omit it: let a terminal summary settle the row once, without inferring
  # success from :done or letting stale updates reopen it.
  def preserve_terminal(socket, agent) do
    if StreamWatch.terminal?(socket, agent.id) do
      snapshot = socket.assigns.inspector_stream.snapshot
      previous = selected_inspector_agent(socket.assigns)

      previous_status = previous && previous.status

      status =
        Map.get(snapshot, :status) ||
          if previous_status in [:completed, :failed, :cancelled],
            do: previous_status,
            else: agent.status

      agent
      |> Map.put(:status, status)
      |> Map.put(:history, messages_to_history_entries(snapshot.messages))
    else
      agent
    end
  end

  @doc """
  The render scope string binding node, selection, stream token and snapshot.
  """
  def inspector_scope(assigns) do
    snapshot_seq =
      case assigns.inspector_stream do
        %{snapshot: snapshot} when not is_nil(snapshot) -> Map.get(snapshot, :seq)
        _ -> nil
      end

    Enum.join(
      [
        assigns.current_node_id || "local",
        assigns.current_node,
        assigns.selected_agent_id,
        assigns.inspector_stream_token,
        snapshot_seq || "pending"
      ],
      ":"
    )
  end

  @doc """
  The stable DOM marker for one history entry (its `:key`, else the legacy hash).
  """
  def inspector_message_marker(entry, index) do
    key = if is_map(entry), do: Map.get(entry, :key)

    if is_binary(key) and key != "" do
      key
    else
      "#{index}-#{:erlang.phash2(entry)}"
    end
  end

  @doc """
  An agent's history merged with its pending optimistic user messages.
  """
  # Merges an agent's real history with its pending optimistic user messages
  # (see OptimisticMessages). Optimistic entries are appended AFTER the real
  # history (never interleaved), so indices into the base history are unchanged
  # — callers that look up history entries by index can keep using them.
  def merged_history(agent, optimistic_messages) do
    history = agent.history || []

    case Map.get(optimistic_messages || %{}, agent.id) do
      pending when pending in [nil, []] ->
        history

      pending ->
        # The key is stamped HERE, never in OptimisticMessages.to_history_entry/2
        # (whose exact entry map is pinned by tests): one stable key per
        # optimistic row, in a namespace distinct from the history keys.
        history
        |> OptimisticMessages.merge(pending)
        |> Enum.map(fn entry ->
          if Map.get(entry, :key) do
            entry
          else
            Map.put(entry, :key, "optimistic|#{:erlang.phash2(entry)}")
          end
        end)
    end
  end

  @doc """
  Converts native `%ReqLLM.Message{}` structs into the template's entries.
  """
  # Converts native %ReqLLM.Message{} structs into the %{turn, type, data}
  # entry format the template consumes. The only legitimate conversion here is
  # extracting display text from the ContentPart list → a single string; all
  # other fields are passed through as native terms.
  def messages_to_history_entries(messages) when is_list(messages) do
    messages
    |> Enum.map(&message_to_history_entry/1)
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      Map.put(entry, :key, "#{entry.turn}|#{index}|#{entry.type}")
    end)
  end

  @doc """
  Fetches the selected agent's history when the gate says it is stale.
  """
  # Triggers an async history fetch for the selected agent when the history
  # gate says the stored history (if any) no longer matches the agent's current
  # message count. No-op when nothing is selected, the agent is gone, the gate
  # says the history is current, or a fetch is already in flight.
  def maybe_fetch_selected_history(socket) do
    selected_agent_id = socket.assigns.selected_agent_id

    if selected_agent_id do
      agent = AgentList.find(socket.assigns.agents, selected_agent_id)

      if agent && not owns_checkpoint?(socket, selected_agent_id) &&
           HistoryGate.need_fetch?(
             socket.assigns.history_gate,
             selected_agent_id,
             agent.message_count
           ) &&
           socket.assigns.history_loading_agent_id != selected_agent_id do
        socket
        |> assign(history_loading_agent_id: selected_agent_id)
        |> spawn_history_fetch(selected_agent_id, nil)
      else
        socket
      end
    else
      socket
    end
  end

  @doc """
  Refetches the selected agent's history after its message count moved on.
  """
  # Triggers an async history fetch for the selected agent when the
  # :message_count carried by the {:agent_updated, ...} broadcast moved on vs
  # the gate's last-seen entry. Called ONLY when changed_fields contains
  # :message_count (the contract: it does whenever the agent's context
  # changed) — the merged agent's count is then the fresh one. No-op when
  # nothing is selected, the agent is gone, the gate says the history is
  # current, or a fetch is already in flight.
  def refetch_selected_history(socket) do
    selected_agent_id = socket.assigns.selected_agent_id

    if selected_agent_id do
      agent = AgentList.find(socket.assigns.agents, selected_agent_id)

      if agent && not owns_checkpoint?(socket, selected_agent_id) &&
           HistoryGate.need_fetch?(
             socket.assigns.history_gate,
             selected_agent_id,
             agent.message_count
           ) &&
           socket.assigns.history_loading_agent_id != selected_agent_id do
        socket
        |> assign(history_loading_agent_id: selected_agent_id)
        |> spawn_history_fetch(selected_agent_id, nil)
      else
        socket
      end
    else
      socket
    end
  end

  @doc """
  Releases the history loading flags held by this agent only.
  """
  # Releases the per-agent history loading flags for `agent_id`, but ONLY when
  # they still name THAT agent — a newer fetch for another agent keeps its own
  # flags. Called from the stale-guard of {:agent_history_loaded, ...}, so a
  # dropped result can never leave a spinner running or block every later
  # fetch through the overlap guard.
  def clear_history_loading_flags(socket, agent_id) do
    socket
    |> clear_flag_if_agent(:history_loading_agent_id, agent_id)
    |> clear_flag_if_agent(:full_message_pending_agent_id, agent_id)
  end

  @doc """
  Applies a `{:inspector_stream_ready, ...}` result and projects its checkpoint.
  """
  def stream_ready(socket, target, token, id, result) do
    previous = socket.assigns.inspector_stream

    socket
    |> StreamWatch.ready(target, token, id, result)
    |> project_inspector_checkpoint(previous)
  end

  @doc """
  Applies a `{:inspector_stream_reconciled, ...}` result and projects it.
  """
  def stream_reconciled(socket, target, token, id, request, result) do
    previous = socket.assigns.inspector_stream

    socket
    |> StreamWatch.reconciled(target, token, id, request, result)
    |> project_inspector_checkpoint(previous)
  end

  @doc """
  Applies an `{:agent_delta, ...}` batch and projects its checkpoint.
  """
  def stream_push(socket, id, seq, events) do
    previous = socket.assigns.inspector_stream

    socket
    |> StreamWatch.push(id, seq, events)
    |> project_inspector_checkpoint(previous)
  end

  @doc """
  Applies an `{:agent_stream_closed, ...}` handoff and projects it.
  """
  def stream_closed(socket, id, snapshot, seq) do
    previous = socket.assigns.inspector_stream

    socket
    |> StreamWatch.closed(id, snapshot, seq)
    |> project_inspector_checkpoint(previous)
  end

  @doc """
  Applies a watch-worker `:DOWN`, then re-checks the history gate.
  """
  def stream_down(socket, ref, pid, reason) do
    socket
    |> StreamWatch.down(ref, pid, reason)
    |> maybe_fetch_selected_history()
  end

  @doc """
  Applies an async history result (`{:noreply, socket}`).

  `index` is nil for the select/refresh flows and an integer for the
  view_full_message safety-net flow (the modal entry is set from the fetched
  history at that index).
  """
  def apply_history_result(socket, agent_id, node, seq, token, result, index) do
    # Both counters are monotonic: an old result cannot overwrite a snapshot,
    # a newer reconciliation, or an A→B→A selection on the same node.
    if seq != socket.assigns.inspector_history_seq or
         token != socket.assigns.inspector_stream_token or
         owns_checkpoint?(socket, agent_id) do
      {:noreply, socket}
    else
      apply_inspector_history(socket, agent_id, node, result, index)
    end
  end

  @doc """
  Re-attempts the stream watch for the selected agent.
  """
  def retry_stream(socket), do: maybe_attach(socket)

  @doc """
  Retries the agent's history through the stream watch, else independently.
  """
  def retry_history(socket) do
    id = socket.assigns.selected_agent_id

    cond do
      owns_checkpoint?(socket, id) ->
        StreamWatch.reconcile(socket)

      is_integer(id) and socket.assigns.inspector_history_error and
          socket.assigns.history_loading_agent_id != id ->
        socket
        |> assign(history_loading_agent_id: id)
        |> spawn_history_fetch(id, nil)

      true ->
        socket
    end
  end

  @doc """
  Closes the detail panel and detaches the stream watch.
  """
  def close_details(socket) do
    socket
    |> StreamWatch.detach()
    |> assign(
      inspector_history_error: false,
      history_loading_agent_id: nil,
      full_message_pending_index: nil,
      full_message_pending_agent_id: nil,
      selected_agent_id: nil,
      selected_history_entry: nil,
      selected_objective: nil,
      show_usage: false
    )
  end

  @doc """
  Toggles the token/cost usage panel.
  """
  def toggle_usage(socket) do
    assign(socket, :show_usage, !socket.assigns.show_usage)
  end

  @doc """
  Opens the full-message modal for the entry at `index_param`.
  """
  def view_full_message(socket, index_param) do
    index = String.to_integer(index_param)

    agent = selected_inspector_agent(socket.assigns)

    if agent && agent.history == [] do
      # Refresh through the watch's atomic snapshot when it owns this history;
      # only unwatchable agents use the independent history safety net.
      if owns_checkpoint?(socket, agent.id) do
        socket
        |> assign(full_message_pending_index: index)
        |> StreamWatch.reconcile()
      else
        socket
        |> assign(
          full_message_pending_agent_id: agent.id,
          history_loading_agent_id: agent.id
        )
        |> spawn_history_fetch(agent.id, index)
      end
    else
      entry =
        agent && Enum.at(merged_history(agent, socket.assigns.optimistic_messages), index)

      assign(socket, :selected_history_entry, entry)
    end
  end

  @doc """
  Closes the full-message modal.
  """
  def close_message_modal(socket) do
    assign(socket, selected_history_entry: nil, full_message_pending_index: nil)
  end

  @doc """
  Opens the objective modal for the selected agent.
  """
  def view_full_objective(socket) do
    agent = selected_inspector_agent(socket.assigns)

    if agent do
      assign(socket, :selected_objective, agent.objective)
    else
      socket
    end
  end

  @doc """
  Closes the objective modal.
  """
  def close_objective_modal(socket) do
    assign(socket, :selected_objective, nil)
  end

  # -- private -----------------------------------------------------------------

  defp select_agent_impl(socket, agent_id) do
    if Scope.selectable_agent?(socket.assigns, agent_id),
      do: select_known_agent(socket, agent_id),
      else: socket
  end

  defp select_known_agent(socket, agent_id) do
    socket =
      socket
      |> assign(
        selected_agent_id: agent_id,
        show_usage: false,
        selected_history_entry: nil,
        history_loading_agent_id: nil,
        full_message_pending_index: nil,
        full_message_pending_agent_id: nil,
        inspector_history_error: false
      )
      |> StreamWatch.attach(agent_id)

    # Lazy-load chat history for the selected agent — asynchronously so the
    # page never blocks on the (possibly cross-node) history RPC. First
    # selection always fetches (no last-seen entry in the gate); later
    # selections fetch only when the message count moved on.
    agent = AgentList.find(socket.assigns.agents, agent_id)

    if agent && not owns_checkpoint?(socket, agent_id) &&
         HistoryGate.need_fetch?(socket.assigns.history_gate, agent_id, agent.message_count) &&
         socket.assigns.history_loading_agent_id != agent_id do
      socket
      |> assign(history_loading_agent_id: agent_id)
      |> spawn_history_fetch(agent_id, nil)
    else
      socket
    end
  end

  defp apply_inspector_history(socket, agent_id, target_node, result, index) do
    if agent_id != socket.assigns.selected_agent_id or target_node != socket.assigns.current_node do
      {:noreply, handle_dropped_history_result(socket, agent_id, target_node)}
    else
      case result do
        {:ok, entries} ->
          {:noreply, put_inspector_history(socket, agent_id, entries, index)}

        {:error, _reason} ->
          {:noreply, fail_inspector_history(socket, agent_id)}
      end
    end
  end

  defp put_inspector_history(socket, agent_id, entries, index) do
    agents =
      AgentList.update(socket.assigns.agents, agent_id, fn agent ->
        %{agent | history: entries}
      end)

    retained_agents =
      Map.new(socket.assigns.retained_agents, fn
        {^agent_id, agent} -> {agent_id, %{agent | history: entries}}
        entry -> entry
      end)

    agent = AgentList.find(agents, agent_id) || Map.get(retained_agents, agent_id)
    count = (agent && agent.message_count) || length(entries)

    # Retain all roles/reasoning and prune only confirmed optimistic messages.
    optimistic_messages =
      OptimisticMessages.prune(
        socket.assigns.optimistic_messages,
        agent_id,
        entries,
        Map.get(socket.assigns.pending_user_messages || %{}, agent_id)
      )

    socket =
      assign(socket,
        agents: agents,
        retained_agents: retained_agents,
        history_gate: HistoryGate.record(socket.assigns.history_gate, agent_id, count),
        history_loading_agent_id: nil,
        full_message_pending_index: nil,
        full_message_pending_agent_id: nil,
        inspector_history_error: false,
        optimistic_messages: optimistic_messages
      )

    if is_integer(index),
      do: assign(socket, :selected_history_entry, Enum.at(entries, index)),
      else: socket
  end

  # StreamWatch admits checkpoint messages and activity atomically, including
  # buffered replay. Project the resulting state in the SAME callback, never
  # the raw RPC snapshot or an independently fetched history.
  defp project_inspector_checkpoint(socket, previous) do
    case socket.assigns.inspector_stream do
      %{agent_id: id, snapshot: snapshot, state: state, reconciling: reconciling, error: error}
      when not is_nil(snapshot) ->
        adopted? =
          snapshot != Map.get(previous || %{}, :snapshot) or
            (is_nil(error) and Map.get(previous || %{}, :reconciling, false) and not reconciling)

        if owns_checkpoint?(socket, id) and adopted? do
          socket
          |> assign(inspector_history_seq: socket.assigns.inspector_history_seq + 1)
          |> put_inspector_history(
            id,
            messages_to_history_entries(state.messages),
            socket.assigns.full_message_pending_index
          )
          |> project_terminal_inspector(id)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp project_terminal_inspector(socket, id) do
    if StreamWatch.terminal?(socket, id) do
      assign(socket,
        agents:
          AgentList.update(
            socket.assigns.agents,
            id,
            &preserve_terminal(socket, &1)
          ),
        retained_agents:
          Map.new(socket.assigns.retained_agents, fn
            {^id, agent} -> {id, preserve_terminal(socket, agent)}
            entry -> entry
          end)
      )
    else
      socket
    end
  end

  # Spawns an async history fetch for `agent_id` on the viewed node. `index`
  # is nil for select/refresh flows, or the clicked entry index for the
  # view_full_message safety net. The history runner is injectable via the
  # :agents_history_runner env seam, resolved AT SPAWN TIME (inside the task)
  # so tests can stub it.
  defp spawn_history_fetch(socket, agent_id, index) do
    parent = self()
    node = socket.assigns.current_node
    seq = socket.assigns.inspector_history_seq + 1
    token = socket.assigns.inspector_stream_token

    started =
      SafeCall.run(fn ->
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          runner =
            Application.get_env(
              :evo_dash,
              :agents_history_runner,
              &EvoDash.NodeContext.get_agent_history/2
            )

          # Exit-safe boundary: the history RPC targets a possibly-dead remote
          # daemon. `SafeCall.run/1` captures an exit (which `rescue` cannot catch)
          # as an error value, so the result message is always sent and the
          # history loading flags are always released — by the result handler.
          result =
            SafeCall.run(fn -> runner.(node, agent_id) |> messages_to_history_entries() end)

          send(parent, {:agent_history_loaded, agent_id, node, seq, token, result, index})
        end)
      end)

    socket = assign(socket, inspector_history_seq: seq)

    case started do
      {:ok, {:ok, _pid}} -> socket
      _ -> fail_inspector_history(socket, agent_id)
    end
  end

  # Independent fallback failures keep the last checkpoint and expose an
  # explicit Retry; stream transport errors remain owned by StreamWatch.
  defp fail_inspector_history(socket, agent_id) do
    socket = clear_history_loading_flags(socket, agent_id)

    if socket.assigns.selected_agent_id == agent_id do
      assign(socket, inspector_history_error: true)
    else
      socket
    end
  end

  # A history result dropped by the stale-guard still releases this agent's
  # loading flags when it came from the CURRENT node (the selection moved on
  # while the fetch was in flight). A cross-node result touches NOTHING: the
  # node-switch reset already cleared the flags, so any flag currently set
  # belongs to the new node's context and must not be cleared by a stale node's
  # (colliding per-node) agent id.
  defp handle_dropped_history_result(socket, agent_id, node) do
    if node == socket.assigns.current_node do
      clear_history_loading_flags(socket, agent_id)
    else
      socket
    end
  end

  defp clear_flag_if_agent(socket, key, agent_id) do
    if Map.get(socket.assigns, key) == agent_id do
      assign(socket, key, nil)
    else
      socket
    end
  end

  defp message_to_history_entry(%ReqLLM.Message{} = msg) do
    %{
      turn: Map.get(msg.metadata, :turn) || 0,
      # Wall-clock timestamp stamped by the :evo_git runtime at the source
      # (Unix-seconds integer or DateTime; absent on historical messages).
      timestamp: Map.get(msg.metadata, :timestamp),
      type: Atom.to_string(msg.role),
      data: %{
        content:
          msg.content
          |> Enum.map(fn part ->
            case content_part_label(part) do
              nil -> ContentText.text_of(part)
              label -> label
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(),
        tool_calls: msg.tool_calls,
        reasoning_details: msg.reasoning_details,
        tool_name: Map.get(msg.metadata, :tool_name) || msg.name,
        metadata: msg.metadata
      }
    }
  end

  # Renders a short metadata label for image/audio content parts so multimodal
  # history isn't blank, e.g. "[image: foo.png]" / "[audio: track.mp3]". Every
  # other part type (text/image_url/video_url/thinking/unknown) returns nil —
  # those contribute nothing here; the `nil` branch of the caller then extracts
  # the part's text via `EvoDashWeb.ContentText.text_of/1`, which yields text
  # ONLY for `:text` parts (reasoning lives in `:thinking` parts and is excluded
  # from the response text).
  # Handles %ReqLLM.Message.ContentPart{} structs and atom/string-keyed maps.
  # TOTAL: never raises, never touches the part's `data` binary.
  defp content_part_label(part) when is_map(part) do
    type = pget(part, :type)

    cond do
      type in [:image, "image"] -> "[image#{part_name_suffix(part)}]"
      audio_part?(part, type) -> "[audio#{part_name_suffix(part)}]"
      true -> nil
    end
  end

  defp content_part_label(_part), do: nil

  # Audio rides as type :audio or as type :file with an audio/* media_type
  # (is_binary guard keeps it total on non-string media_type values).
  defp audio_part?(_part, type) when type in [:audio, "audio"], do: true

  defp audio_part?(part, type) when type in [:file, "file"] do
    case pget(part, :media_type) do
      mt when is_binary(mt) -> String.starts_with?(mt, "audio/")
      _ -> false
    end
  end

  defp audio_part?(_part, _type), do: false

  # ": <filename>" when a filename is available, else "" — never a bare
  # binary; prefers the real schema `filename` field, falls back to a `name`
  # key (string or atom) for defensive map shapes.
  defp part_name_suffix(part) do
    case pget(part, :filename) || pget(part, :name) do
      name when is_binary(name) and name != "" -> ": " <> name
      _ -> ""
    end
  end

  # Atom-or-string-key tolerant getter (total on any map shape).
  defp pget(part, key), do: Map.get(part, key) || Map.get(part, to_string(key))
end
