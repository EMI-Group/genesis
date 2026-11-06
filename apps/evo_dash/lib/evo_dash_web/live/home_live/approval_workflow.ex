defmodule EvoDashWeb.HomeLive.ApprovalWorkflow do
  @moduledoc """
  Shared HomeLive approval recovery and response state machine.

  Call `init/1` on mount and chat/node reset; it invalidates outstanding work.
  After subscribing to approvals and restoring chat refs (and after root-agent
  lookup), call `recover/1` on a CONNECTED socket. No polling is needed.
  Forward requests to `requested/2`, source-stamped resolutions to `resolved/3`,
  and legacy resolutions to `resolved/2`; forward the nested
  SafeCall messages to `recovered/3` and `responded/3` respectively.

  `respond/3` requires a currently pending, chat-owned id and whitelisted
  decision. It keeps the card, disables repeat submissions via `busy?/2`, and
  removes it only on success, not-found (already resolved), or a resolution
  broadcast. Errors populate `:approval_error` for the parent to display/retry.
  Errors contain backend terms, not translated UI strings.

  Tags include a unique sequence and the full chat scope, so a reset, node
  switch, newer recovery, or newer response makes old results harmless.
  Resolution tombstones prevent an in-flight snapshot resurrecting a resolved
  card; requests arriving during recovery take precedence over snapshot data.

  Runners are captured at spawn time: `:approval_pending_runner` (node -> list
  or error) and the existing `:approval_responder` (node, id, decision -> result).
  All core/RPC work runs off the LiveView under SafeCall. The real pending API
  is `EvoGit.CommandApproval.pending/0`, routed through NodeContext.call_remote/4
  on the chat's node, NOT the evaluator's possibly different target_node.
  """

  import Phoenix.Component, only: [assign: 2]
  alias EvoDash.SafeCall

  def init(socket) do
    assign(socket,
      pending_approvals: [],
      approval_recovery_seq: nil,
      approval_recovering: false,
      approval_recovery_removed: MapSet.new(),
      approval_recovery_new: [],
      approval_responses: %{},
      approval_error: nil
    )
  end

  @doc "Starts a one-shot snapshot load when chat refs and a resolved node are available."
  def recover(socket) do
    if scoped?(socket.assigns) do
      seq = System.unique_integer([:positive, :monotonic])
      scope = scope(socket.assigns)
      runner = Application.get_env(:evo_dash, :approval_pending_runner, &pending/1)
      tag = {:approval_pending_loaded, seq, scope}
      node = chat_node(socket.assigns)
      start(tag, fn -> runner.(node) end)

      assign(socket,
        approval_recovery_seq: seq,
        approval_recovering: true,
        approval_recovery_removed: MapSet.new(),
        approval_recovery_new: [],
        approval_error: nil
      )
    else
      socket
    end
  end

  @doc "Applies the inner tag and SafeCall result from `{tag, result}`."
  def recovered(socket, {:approval_pending_loaded, seq, captured_scope}, result) do
    cond do
      seq != socket.assigns[:approval_recovery_seq] ->
        socket

      captured_scope != scope(socket.assigns) ->
        assign(socket, approval_recovering: false, approval_recovery_seq: nil)

      true ->
        apply_recovery(socket, result)
    end
  end

  defp apply_recovery(socket, result) do
    socket = assign(socket, approval_recovering: false, approval_recovery_seq: nil)

    case result do
      {:ok, requests} when is_list(requests) ->
        removed = socket.assigns[:approval_recovery_removed] || MapSet.new()

        fetched =
          Enum.filter(requests, fn request ->
            own_request?(socket.assigns, request) and
              not MapSet.member?(removed, request.request_id)
          end)

        # An absent snapshot row is not an acknowledgement of our response:
        # the backend may have consumed it before the responder returns. Keep
        # busy cards until that response or a resolution broadcast settles them.
        busy =
          Enum.filter(pending_list(socket), fn request ->
            own_request?(socket.assigns, request) and
              busy?(socket.assigns, request.request_id) and
              not MapSet.member?(removed, request.request_id)
          end)

        # Live broadcasts are newer than a snapshot and win on duplicate ids.
        live = socket.assigns[:approval_recovery_new] || []
        entries = Enum.reduce(Enum.reverse(busy), fetched, &upsert(&2, &1))
        entries = Enum.reduce(Enum.reverse(live), entries, &upsert(&2, &1))

        assign(socket,
          pending_approvals: entries,
          approval_recovery_new: [],
          approval_error: nil
        )

      other ->
        assign(socket, approval_error: {:recovery, failure(other)})
    end
  end

  def requested(socket, request) do
    if own_request?(socket.assigns, request) do
      live = socket.assigns[:approval_recovery_new] || []

      assign(socket,
        pending_approvals: upsert(pending_list(socket), request),
        approval_recovery_new:
          if(socket.assigns[:approval_recovering], do: upsert(live, request), else: live)
      )
    else
      socket
    end
  end

  @doc "Applies a resolution only from the chat's source node, never its evaluator target."
  def resolved(socket, request_id, source_node) do
    if scoped?(socket.assigns) and source_node == chat_node(socket.assigns) do
      resolved(socket, request_id)
    else
      socket
    end
  end

  @doc "Applies a legacy unstamped resolution or an acknowledged response."
  def resolved(socket, request_id) do
    removed = socket.assigns[:approval_recovery_removed] || MapSet.new()

    assign(socket,
      pending_approvals: drop(pending_list(socket), request_id),
      approval_recovery_new: drop(socket.assigns[:approval_recovery_new] || [], request_id),
      approval_responses: Map.delete(responses(socket.assigns), request_id),
      approval_recovery_removed:
        if(socket.assigns[:approval_recovering],
          do: MapSet.put(removed, request_id),
          else: removed
        )
    )
  end

  @doc "Submits only an existing, owned card; no optimistic removal on failure."
  def respond(socket, request_id, decision) when decision in ["approve", "deny"] do
    request = Enum.find(pending_list(socket), &(Map.get(&1, :request_id) == request_id))

    if own_request?(socket.assigns, request) and not busy?(socket.assigns, request_id) do
      seq = System.unique_integer([:positive, :monotonic])
      tag = {:approval_workflow_response, seq, scope(socket.assigns), request_id}

      runner =
        Application.get_env(
          :evo_dash,
          :approval_responder,
          &EvoDash.NodeContext.approval_response/3
        )

      node = chat_node(socket.assigns)
      start(tag, fn -> runner.(node, request_id, decision) end)

      assign(socket,
        approval_responses: Map.put(responses(socket.assigns), request_id, seq),
        approval_error: nil
      )
    else
      socket
    end
  end

  def respond(socket, _request_id, _decision), do: socket

  def responded(socket, {:approval_workflow_response, seq, captured_scope, id}, result) do
    cond do
      Map.get(responses(socket.assigns), id) != seq ->
        socket

      captured_scope != scope(socket.assigns) ->
        assign(socket, approval_responses: Map.delete(responses(socket.assigns), id))

      true ->
        socket = assign(socket, approval_responses: Map.delete(responses(socket.assigns), id))

        case result do
          {:ok, :ok} -> resolved(socket, id)
          {:ok, {:error, :not_found}} -> resolved(socket, id)
          other -> assign(socket, approval_error: {:response, id, failure(other)})
        end
    end
  end

  def busy?(assigns, id), do: Map.has_key?(responses(assigns), id)

  @doc "Chat ownership predicate shared by broadcasts and recovered snapshots."
  def own_request?(assigns, request) when is_map(request) do
    id = Map.get(request, :request_id)
    req_node = Map.get(request, :node)
    node_matches = req_node == chat_node(assigns)
    # Legacy producers may omit node; evaluator metadata must be node-stamped.
    legacy_node = req_node == nil and Map.get(request, :kind) != :elixir_eval

    is_binary(id) and String.trim(id) != "" and scoped?(assigns) and
      (node_matches or legacy_node) and
      (same_id?(Map.get(request, :task_id), assigns[:chat_task_id]) or
         same_id?(Map.get(request, :agent_id), assigns[:chat_agent_id]))
  end

  def own_request?(_assigns, _request), do: false

  defp same_id?(left, right) when is_binary(left) or is_integer(left) do
    (is_binary(right) or is_integer(right)) and to_string(left) == to_string(right)
  end

  defp same_id?(_left, _right), do: false

  defp scope(assigns),
    do:
      {assigns[:chat_id], assigns[:current_node_id], assigns[:current_node], chat_node(assigns),
       assigns[:chat_task_id], assigns[:chat_agent_id]}

  defp chat_node(assigns), do: assigns[:chat_node] || assigns[:current_node]

  defp scoped?(assigns) do
    target = chat_node(assigns)
    known_ref = usable_id?(assigns[:chat_task_id]) or usable_id?(assigns[:chat_agent_id])
    # A disconnected remote context falls back to local in NodeAware; never
    # recover or respond against the local service on behalf of that context.
    pending_remote = assigns[:current_node_id] != nil and assigns[:current_node] == node()
    is_atom(target) and not is_nil(target) and known_ref and not pending_remote
  end

  defp usable_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp usable_id?(id), do: is_integer(id)
  defp responses(assigns), do: assigns[:approval_responses] || %{}
  defp pending_list(socket), do: socket.assigns[:pending_approvals] || []
  defp drop(entries, id), do: Enum.reject(entries, &(Map.get(&1, :request_id) == id))
  defp upsert(entries, request), do: [request | drop(entries, request.request_id)]
  defp failure({:error, reason}), do: reason
  defp failure({:ok, {:error, reason}}), do: reason
  defp failure(other), do: {:unexpected_result, other}

  defp pending(node) do
    case EvoDash.NodeContext.call_remote(node, EvoGit.CommandApproval, :pending, []) do
      {:ok, requests} -> requests
      {:error, _reason} = error -> error
    end
  end

  defp start(tag, fun) do
    case SafeCall.start(self(), tag, fun) do
      {:ok, _pid} -> :ok
      {:error, reason} -> send(self(), {tag, {:error, reason}})
    end
  end
end
