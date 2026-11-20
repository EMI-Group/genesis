defmodule EvoDashWeb.HomeLive.ApprovalDialogState do
  @moduledoc """
  The APPROVAL SURFACE state of `EvoDashWeb.HomeLive`: recovery, live arrivals,
  decisions and the review dialog's local view state.
  `EvoDashWeb.HomeLive.ApprovalWorkflow` owns the requests themselves (their
  scoping to this chat/session and their off-process recovery); this module
  wires that workflow into the page's callbacks and keeps
  `approval_dialog_open` / `approval_dialog_index` sane:
    * `maybe_recover_approvals/1` — recover the core's live pending requests
      once per chat/node/task/agent scope (never against mount's local seed and
      never while an attach is pending), `recover_approvals/1` being the
      connected-only inner call;
    * the async results `{:approval_pending_loaded, …}` /
      `{:approval_workflow_response, …}` and the `"approvals"` broadcasts
      (a novel live request auto-opens the dialog exactly once, with its
      privacy-safe browser notification);
    * the dialog cursor (`open_approval_dialog/1`, `sync_approval_dialog/1`,
      `step_approval_dialog/2`, `clamp_dialog_index/2`) and the event bodies —
      every decision still travels as the request id plus a whitelisted
      decision, never as a dialog action;
    * `approval_strip_open?/1`, the render helper that decides whether the
      fixed-height strip reserves its height.
  Extracted verbatim; no scope rule, guard or cursor clamp changed.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]
  alias EvoDashWeb.HomeLive.ApprovalWorkflow

  @doc """
  Recovers the core's pending approval requests when the chat scope moved.
  """
  def maybe_recover_approvals(socket) do
    context =
      Map.take(socket.assigns, [
        :chat_id,
        :assistant_conversation_id,
        :current_node_id,
        :current_node,
        :chat_node,
        :chat_task_id,
        :chat_agent_id
      ])

    if connected?(socket) and !socket.assigns.session_attach_pending? and
         context != socket.assigns[:approval_context] do
      socket
      |> assign(approval_context: context)
      |> recover_approvals()
    else
      socket
    end
  end

  defp recover_approvals(socket) do
    if connected?(socket), do: ApprovalWorkflow.recover(socket), else: socket
  end

  ## Async results and broadcasts ----------------------------------------

  def pending_loaded(socket, tag, result) do
    # A recovery snapshot mutates `pending_approvals` too, so the dialog cursor
    # is re-derived: an empty result closes the dialog instead of leaving it
    # "open" with nothing to show.
    {:noreply, socket |> ApprovalWorkflow.recovered(tag, result) |> sync_approval_dialog()}
  end

  def workflow_response(socket, tag, result) do
    # Success / not-found removes the request: sync closes the dialog when it
    # was the last one and clamps the cursor to what remains.
    {:noreply, socket |> ApprovalWorkflow.responded(tag, result) |> sync_approval_dialog()}
  end

  def requested(socket, request) do
    # Live-arrival admission is shared with notification generation: duplicates,
    # recovered/resolved requests and foreign scopes must not open or notify.
    {socket, notification} = ApprovalWorkflow.requested_with_notification(socket, request)

    if notification do
      {:noreply,
       socket
       |> auto_open_approval_dialog()
       |> push_event("task_notification", notification)}
    else
      {:noreply, socket}
    end
  end

  def resolved(socket, request_id, source_node) do
    socket = ApprovalWorkflow.resolved(socket, request_id, source_node)
    {:noreply, sync_approval_dialog(socket)}
  end

  def resolved(socket, request_id) do
    socket = ApprovalWorkflow.resolved(socket, request_id)
    {:noreply, sync_approval_dialog(socket)}
  end

  ## Events --------------------------------------------------------------

  def respond(socket, %{"request_id" => request_id, "decision" => decision}) do
    # The decision payload stays exactly the request id plus the whitelisted
    # decision — ApprovalWorkflow re-validates both. The dialog cursor is
    # re-derived from the (possibly shorter) request list afterwards.
    socket = ApprovalWorkflow.respond(socket, request_id, decision)
    {:noreply, sync_approval_dialog(socket)}
  end

  def respond(socket, _params), do: {:noreply, socket}

  def retry(socket), do: {:noreply, recover_approvals(socket)}

  def notification_clicked(socket, %{"request_id" => request_id, "scope" => scope}) do
    # Notification clicks must match the captured chat scope as well as the exact
    # currently owned pending request; they never authorize or select a fallback.
    case ApprovalWorkflow.dialog_index(socket.assigns, request_id, scope) do
      index when is_integer(index) ->
        {:noreply, assign(socket, approval_dialog_open: true, approval_dialog_index: index)}

      nil ->
        {:noreply, socket}
    end
  end

  def notification_clicked(socket, _params), do: {:noreply, socket}

  def open_dialog(socket), do: {:noreply, open_approval_dialog(socket)}

  def dialog_closed(socket), do: {:noreply, assign(socket, approval_dialog_open: false)}

  def prev(socket), do: {:noreply, step_approval_dialog(socket, -1)}

  def next(socket), do: {:noreply, step_approval_dialog(socket, 1)}

  ## Render helper -------------------------------------------------------

  # The notification/approval strip is VISIBLE once the conversation has content
  # (or while a request is pending). It stays MOUNTED either way so the shared
  # `motion-collapse-grid` helper can animate both directions instead of the
  # transcript column snapping by 40 px when the strip un-hides.
  def approval_strip_open?(assigns) do
    not ((assigns[:transcript] == [] or assigns[:chat_status] == :ended) and
           (assigns[:pending_approvals] || []) == [])
  end

  ## Dialog cursor -------------------------------------------------------
  #
  # `approval_dialog_open` / `approval_dialog_index` are LOCAL VIEW state: the
  # requests themselves belong to ApprovalWorkflow, and every decision still
  # travels through it as the request id plus a whitelisted decision. The
  # helpers below only keep the cursor sane as the request list changes.

  defp pending_approvals(socket), do: socket.assigns[:pending_approvals] || []

  # A genuinely NEW live request (never a recovery snapshot) surfaces the review
  # dialog when it is not already open, so the user is asked in place instead of
  # having to notice a banner. When it IS open, only the cursor is re-synced.
  defp auto_open_approval_dialog(socket) do
    if socket.assigns[:approval_dialog_open] do
      sync_approval_dialog(socket)
    else
      open_approval_dialog(socket)
    end
  end

  defp open_approval_dialog(socket) do
    case pending_approvals(socket) do
      [] ->
        assign(socket, approval_dialog_open: false, approval_dialog_index: 0)

      _ ->
        assign(socket,
          approval_dialog_open: true,
          approval_dialog_index:
            clamp_dialog_index(socket.assigns[:approval_dialog_index], socket)
        )
    end
  end

  defp sync_approval_dialog(socket) do
    case pending_approvals(socket) do
      [] ->
        assign(socket, approval_dialog_open: false, approval_dialog_index: 0)

      _ ->
        assign(socket,
          approval_dialog_index:
            clamp_dialog_index(socket.assigns[:approval_dialog_index], socket)
        )
    end
  end

  defp step_approval_dialog(socket, step) do
    case pending_approvals(socket) do
      [] ->
        assign(socket, approval_dialog_open: false, approval_dialog_index: 0)

      requests ->
        count = length(requests)
        index = clamp_dialog_index(socket.assigns[:approval_dialog_index], socket)
        assign(socket, approval_dialog_index: integer_mod(index + step, count))
    end
  end

  defp clamp_dialog_index(index, socket) do
    count = length(pending_approvals(socket))

    cond do
      count == 0 -> 0
      not is_integer(index) or index < 0 -> 0
      index >= count -> count - 1
      true -> index
    end
  end

  defp integer_mod(value, count) when count > 0 do
    rem(rem(value, count) + count, count)
  end
end
