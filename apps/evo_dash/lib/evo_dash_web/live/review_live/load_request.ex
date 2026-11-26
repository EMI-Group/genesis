defmodule EvoDashWeb.ReviewLive.LoadRequest do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDash.{SafeCall, Seam}
  alias EvoDashWeb.RemoteGateComponents
  alias EvoDashWeb.ReviewLive.{ArchiveLoad, LoadData}
  alias EvoGit.Util.Strings

  def scope(assigns) do
    {assigns[:task_id], assigns[:current_node_id], assigns[:current_node], blocked?(assigns)}
  end

  def blocked?(assigns) do
    RemoteGateComponents.gate_active?(assigns) or
      (assigns[:workbench_remote_requested] == true and
         (is_nil(assigns[:current_node_id]) or assigns[:current_node] == node()))
  end

  def scope_ready?(assigns) do
    assigns[:page_ready?] == true and is_nil(assigns[:error]) and
      not blocked?(assigns) and assigns[:workbench_loaded_scope] == scope(assigns)
  end

  def history_scope_pending?(assigns) do
    assigns[:loading] == true and is_nil(assigns[:error]) and not blocked?(assigns) and
      not scope_ready?(assigns) and
      assigns[:history_scope_request] == {scope(assigns), assigns[:load_generation]}
  end

  # Called only for a result the page's task/node/generation guard accepted.
  def settle(socket, {:error, _reason}),
    do: assign(socket, history_scope_request: nil, workbench_loaded_scope: nil)

  def settle(socket, {:ok, _assigns}), do: assign(socket, :history_scope_request, nil)

  def start(socket, inspect_commit_sha) do
    scope = scope(socket.assigns)
    {task_id, _target, _node, blocked?} = scope
    generation = socket.assigns.load_generation + 1

    # A successful load with no project path is also settled; refreshing such
    # a review should not temporarily offer History for a repo-less task.
    resolving_scope? =
      is_binary(task_id) and Strings.present?(task_id) and not scope_ready?(socket.assigns)

    socket = assign(socket, load_generation: generation, history_scope_request: nil)

    if blocked? do
      assign(socket,
        loading: false,
        error: gettext("Task not found: the requested node is unavailable.")
      )
    else
      socket =
        socket
        |> ArchiveLoad.sync_context()
        |> assign(loading: true, error: nil)

      if connected?(socket) do
        spawn_load(socket, scope, inspect_commit_sha, generation, resolving_scope?)
      else
        socket
      end
    end
  end

  defp spawn_load(socket, {task_id, _target, node, false} = scope, sha, generation, resolving?) do
    parent = self()

    opts = [
      live_action: socket.assigns.live_action,
      inspect_commit_sha: sha,
      repo_id: socket.assigns.inspect_repo_id
    ]

    case SafeCall.run(fn ->
           Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
             result = load(node, task_id, opts, scope)
             send(parent, {:review_data_loaded, task_id, node, generation, result})
           end)
         end) do
      {:ok, {:ok, _pid}} ->
        if resolving?,
          do: assign(socket, :history_scope_request, {scope, generation}),
          else: socket

      _ ->
        # Use the ordinary error-result path so earlier metadata is cleared in
        # exactly the same way as on a failed read. No request was in flight.
        send(parent, {:review_data_loaded, task_id, node, generation, load_error()})
        socket
    end
  end

  defp load(node, task_id, opts, scope) do
    case SafeCall.run(fn ->
           Seam.get(:review_load_runner, &LoadData.load/3).(node, task_id, opts)
         end) do
      {:ok, {:ok, %{workbench_project: _} = assigns}} ->
        {:ok, Map.put(assigns, :workbench_loaded_scope, scope)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      _ ->
        load_error()
    end
  end

  defp load_error, do: {:error, gettext("Failed to load review data.")}
end
