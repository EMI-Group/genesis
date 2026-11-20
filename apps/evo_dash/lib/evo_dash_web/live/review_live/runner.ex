defmodule EvoDashWeb.ReviewLive.Runner do
  @moduledoc """
  The async action plumbing of `EvoDashWeb.ReviewLive`.

  Review actions never run in the LiveView process: a store/registry/Git call
  can take many seconds and a `GenServer.call` timeout EXITS the caller. Each
  handler computes a cheap plan, marks the in-progress state, and spawns the
  work through `spawn/4`; the outcome arrives as
  `{:review_action_result, task_id, node, action, action_ref, result}` and is
  applied by the page's `apply_action_result/4`, after the in-progress state is
  cleared by `clear/3`.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  # Runs `fun` in `EvoDash.TaskSupervisor` behind `EvoDash.SafeCall.run/1` and
  # reports `{:review_action_result, task_id, node, action, ref, result}` back to
  # this LiveView. The boundary guarantees a result message is ALWAYS sent (an
  # exit inside the child would otherwise leave the in-progress state stuck).
  # When the child cannot even be started, the in-progress state is cleared
  # here and the failure surfaces as an error flash.
  def spawn(socket, action, ref, fun) do
    parent = self()
    node = socket.assigns.current_node
    task_id = socket.assigns.task_id

    case Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
           result = EvoDash.SafeCall.run(fun)
           send(parent, {:review_action_result, task_id, node, action, ref, result})
         end) do
      {:ok, _pid} ->
        socket

      {:error, reason} ->
        socket
        |> clear(action, ref)
        |> put_flash(
          :error,
          gettext("Failed to start action: %{reason}", reason: inspect(reason))
        )
    end
  end

  # Clears the in-progress state an action set, for the action's shape:
  # diff loads release their `{scope, path}` entry (only when this result still
  # owns it — a newer request for the same file keeps its own marker), the
  # background completion write owns none, and every other action clears the
  # marker (plus its repo's busy flag) and the task-level spinner.
  def clear(socket, action, ref) when action in [:diff, :expand_context] do
    key = {Map.get(ref, :repo_id), Map.get(ref, :path)}
    seq = Map.get(ref, :seq)

    case Map.get(socket.assigns.diff_in_flight, key) do
      ^seq -> assign(socket, :diff_in_flight, Map.delete(socket.assigns.diff_in_flight, key))
      _superseded -> socket
    end
  end

  def clear(socket, :completion, _ref), do: socket

  def clear(socket, action, ref) do
    busy_repos =
      case action do
        :merge_all ->
          MapSet.difference(
            socket.assigns.busy_repos,
            MapSet.new(Map.get(ref, :repo_ids, []))
          )

        _ ->
          case Map.get(ref, :repo_id) do
            nil -> socket.assigns.busy_repos
            repo_id -> MapSet.delete(socket.assigns.busy_repos, repo_id)
          end
      end

    socket
    |> assign(:review_action, nil)
    |> assign(:busy_repos, busy_repos)
    |> clear_loading(action)
  end

  # The spinner feeds the primary/aggregate action bar — only the task-level
  # actions set it.
  defp clear_loading(socket, action)
       when action in [:resume, :ignore, :create_pr, :extract_skills, :auto_resolve] do
    assign(socket, :action_loading, false)
  end

  defp clear_loading(socket, _action), do: socket
end
