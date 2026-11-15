defmodule EvoDashWeb.HomeLive.TaskTracking do
  @moduledoc "Asynchronous, scoped projections of followed background tasks."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  use Gettext, backend: EvoDashWeb.Gettext
  alias EvoDash.SafeCall

  def scope(assigns) do
    target = assigns[:current_node] || node()

    target =
      if assigns[:current_node_id] not in [nil, ""] and target == node(),
        do: :unavailable,
        else: target

    {target, assigns[:assistant_conversation_id] || assigns[:chat_id]}
  end

  def refresh(socket) do
    if Phoenix.LiveView.connected?(socket), do: refresh_connected(socket), else: socket
  end

  defp refresh_connected(socket) do
    current_scope = scope(socket.assigns)

    if MapSet.member?(socket.assigns[:task_action_pending] || MapSet.new(), current_scope),
      do: Process.send_after(self(), {:assistant_action_reconcile, current_scope}, 3000)

    cond do
      socket.assigns[:task_tracking_loading] &&
          socket.assigns[:task_tracking_scope] == current_scope ->
        socket

      true ->
        if ref = socket.assigns[:task_tracking_timer], do: Process.cancel_timer(ref)

        socket =
          if socket.assigns[:task_tracking_scope] != current_scope,
            do: assign(socket, tracked_tasks: [], task_tracking_error: nil),
            else: socket

        seq = (socket.assigns[:task_tracking_seq] || 0) + 1

        case SafeCall.start(self(), {:assistant_tasks_loaded, seq, current_scope}, fn ->
               load(current_scope)
             end) do
          {:ok, _} ->
            assign(socket,
              task_tracking_seq: seq,
              task_tracking_scope: current_scope,
              task_tracking_loading: true,
              task_tracking_timer: nil
            )

          {:error, reason} ->
            assign(socket, task_tracking_loading: false, task_tracking_error: reason)
        end
    end
  end

  def load({:unavailable, _}), do: {:error, :not_connected}

  def load({target, conversation}) do
    with links when is_list(links) <-
           call(target, EvoGit.AssistantTaskLinks, :list, [target, conversation]) do
      Enum.map(links, fn previous ->
        id = previous[:id] || previous["id"]

        case call(target, EvoGit.TaskControl, :get, [
               %{"task_id" => id, "include_result" => false}
             ]) do
          {:ok, data} ->
            :ok = call(target, EvoGit.AssistantTaskLinks, :follow, [target, conversation, data])
            project(data, false)

          _ ->
            project(previous, true)
        end
      end)
    else
      error -> {:error, error}
    end
  end

  def project(data, error) do
    progress = data[:progress] || %{}

    %{
      id: data[:id] || data["id"],
      status: to_string(data[:status] || data["status"] || "unknown"),
      title: data[:objective_summary] || data["objective_summary"] || "",
      path: data[:project_path] || data["project_path"] || "",
      updated_at: progress[:observed_at],
      agent_count: progress[:registered_agent_count],
      has_result: get_in(progress, [:saved_state, :has_result]) == true,
      error: error
    }
  end

  def apply_result(socket, seq, incoming_scope, result) do
    if seq == socket.assigns[:task_tracking_seq] && incoming_scope == scope(socket.assigns) do
      socket =
        case result do
          {:ok, tasks} when is_list(tasks) ->
            assign(socket, tracked_tasks: tasks, task_tracking_error: nil)

          _ ->
            assign(socket, task_tracking_error: :unavailable)
        end

      active =
        Enum.any?(
          socket.assigns[:tracked_tasks] || [],
          &(&1.status in ~w(pending running finalizing cancelling))
        )

      timer =
        if active || socket.assigns[:task_tracking_error] ||
             socket.assigns[:chat_status] == :running,
           do: Process.send_after(self(), :assistant_tasks_tick, 3000)

      assign(socket, task_tracking_loading: false, task_tracking_timer: timer)
    else
      socket
    end
  end

  def follow(socket, id) do
    {target, conversation} = scope(socket.assigns)

    result =
      SafeCall.start(self(), {:assistant_follow_result, scope(socket.assigns)}, fn ->
        with {:ok, data} <-
               call(target, EvoGit.TaskControl, :get, [
                 %{"task_id" => id, "include_result" => false}
               ]),
             :ok <- call(target, EvoGit.AssistantTaskLinks, :follow, [target, conversation, data]) do
          {:ok, data}
        end
      end)

    case result do
      {:ok, _} ->
        {:noreply, socket}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not follow this task. Check the ID and connection.")
         )}
    end
  end

  def follow_result(socket, captured_scope, result) do
    if captured_scope == scope(socket.assigns) do
      socket =
        case result do
          {:ok, {:ok, _}} ->
            socket

          _ ->
            put_flash(
              socket,
              :error,
              gettext("Could not follow this task. Check the ID and connection.")
            )
        end

      refresh(socket)
    else
      socket
    end
  end

  def action(socket, name, args) do
    if MapSet.member?(socket.assigns[:task_action_pending] || MapSet.new(), scope(socket.assigns)) do
      {:noreply, socket}
    else
      {target, conversation} = scope(socket.assigns)
      operation_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      context = %{conversation_id: conversation, target_node: target, operation_id: operation_id}
      ids = Map.put(socket.assigns[:task_action_ids] || %{}, scope(socket.assigns), operation_id)
      socket = assign(socket, task_action_ids: ids)
      start_action(socket, fn -> action_call(target, name, args, context) end)
    end
  end

  defp start_action(socket, fun) do
    tag =
      {:assistant_task_action, scope(socket.assigns),
       (socket.assigns[:task_action_ids] || %{})[scope(socket.assigns)]}

    pending = socket.assigns[:task_action_pending] || MapSet.new()

    if MapSet.member?(pending, scope(socket.assigns)) do
      {:noreply, socket}
    else
      case SafeCall.start(self(), tag, fun) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(task_action_pending: MapSet.put(pending, scope(socket.assigns)))
           |> EvoDashWeb.HomeLive.ChatState.persist()
           |> put_flash(
             :info,
             gettext("Task action submitted. Review any approval request before it runs.")
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not submit task action."))}
      end
    end
  end

  def action_result(socket, incoming_scope, {:ok, {:error, %{code: code, operation_id: id}}})
      when code in ["action_pending", "action_uncertain"] do
    socket =
      assign(socket,
        task_action_ids: Map.put(socket.assigns[:task_action_ids] || %{}, incoming_scope, id)
      )

    socket = EvoDashWeb.HomeLive.ChatState.persist(socket)
    action_result(socket, incoming_scope, {:error, :uncertain})
  end

  def action_result(socket, incoming_scope, {:error, _}) do
    Process.send_after(self(), {:assistant_action_reconcile, incoming_scope}, 3000)

    put_flash(
      socket,
      :error,
      gettext(
        "The task action result is uncertain. Checking the original operation before allowing another request."
      )
    )
  end

  def action_result(socket, incoming_scope, result) do
    socket =
      assign(socket,
        task_action_pending:
          MapSet.delete(socket.assigns[:task_action_pending] || MapSet.new(), incoming_scope)
      )

    if incoming_scope == scope(socket.assigns) do
      socket =
        case result do
          {:ok, {:ok, _}} ->
            put_flash(
              socket,
              :info,
              gettext("Task request accepted. Current status will update below.")
            )

          {:ok, :ok} ->
            socket

          _ ->
            put_flash(
              socket,
              :error,
              gettext(
                "Task request did not succeed. Check its current state before trying again."
              )
            )
        end

      socket |> EvoDashWeb.HomeLive.ChatState.persist() |> refresh()
    else
      socket
    end
  end

  def reconcile(socket, {target, conversation} = captured_scope) do
    id = (socket.assigns[:task_action_ids] || %{})[captured_scope]
    key = {captured_scope, id}
    checking = socket.assigns[:task_action_checking] || MapSet.new()

    if is_nil(id) or captured_scope != scope(socket.assigns) or
         not MapSet.member?(socket.assigns[:task_action_pending] || MapSet.new(), captured_scope) or
         MapSet.member?(checking, key) do
      socket
    else
      case SafeCall.start(self(), {:assistant_action_status, captured_scope, id}, fn ->
             call(target, EvoGit.AssistantTaskLinks, :action_status, [conversation, id])
           end) do
        {:ok, _} ->
          assign(socket, task_action_checking: MapSet.put(checking, key))

        {:error, _} ->
          Process.send_after(self(), {:assistant_action_reconcile, captured_scope}, 5000)
          socket
      end
    end
  end

  def correlated_result(socket, captured_scope, id, result) do
    if (socket.assigns[:task_action_ids] || %{})[captured_scope] == id do
      action_result(socket, captured_scope, result)
    else
      socket
    end
  end

  def reconcile_result(socket, captured_scope, id, result) do
    checking = socket.assigns[:task_action_checking] || MapSet.new()

    socket =
      if MapSet.member?(checking, {captured_scope, id}),
        do: assign(socket, task_action_checking: MapSet.delete(checking, {captured_scope, id})),
        else: socket

    if (socket.assigns[:task_action_ids] || %{})[captured_scope] == id do
      reconcile_result(socket, captured_scope, result)
    else
      socket
    end
  end

  def reconcile_result(socket, captured_scope, {:ok, {:done, result}}),
    do: action_result(socket, captured_scope, {:ok, result})

  def reconcile_result(socket, captured_scope, {:ok, {:error, :not_found}}),
    do: reconcile_result(socket, captured_scope, {:ok, :unknown})

  def reconcile_result(socket, captured_scope, {:ok, :unknown}) do
    socket =
      assign(socket,
        task_action_pending:
          MapSet.delete(socket.assigns[:task_action_pending] || MapSet.new(), captured_scope)
      )

    socket = EvoDashWeb.HomeLive.ChatState.persist(socket)

    if captured_scope == scope(socket.assigns),
      do:
        put_flash(
          socket,
          :error,
          gettext(
            "The operation could not be confirmed. Inspect the task in task details before taking further action."
          )
        ),
      else: socket
  end

  def reconcile_result(socket, captured_scope, _) do
    if captured_scope == scope(socket.assigns) and
         MapSet.member?(socket.assigns[:task_action_pending] || MapSet.new(), captured_scope),
       do: Process.send_after(self(), {:assistant_action_reconcile, captured_scope}, 5000)

    socket
  end

  defp action_call(target, name, args, context) when target == node(),
    do: EvoGit.Agent.Tools.GenesisTools.request_action(name, args, context)

  defp action_call(target, name, args, context) do
    :erpc.call(
      target,
      EvoGit.Agent.Tools.GenesisTools,
      :request_action,
      [name, args, context],
      EvoGit.CommandApproval.timeout() + 30_000
    )
  end

  defp call(target, module, function, args) when target == node(),
    do: apply(module, function, args)

  defp call(target, module, function, args) do
    case EvoGit.RemoteNode.call_remote(target, module, function, args) do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end
end
