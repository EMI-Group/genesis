defmodule EvoDashWeb.ReviewLive.MergeCheck do
  @moduledoc """
  Async dry-run merge check + auto-resolve support for `EvoDashWeb.ReviewLive`.

  Kept as a support module (same pattern as the `projects_live/` support
  modules) so the single-page LiveView stays lean. Every function takes and
  returns a LiveView socket; ReviewLive's handle_event/handle_info clauses are
  thin wrappers.

  Also hosts `repo_available?/2` — the shared repo-existence gate the review
  page uses for merge, resume, and branch checks.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  alias EvoDashWeb.Helpers

  @doc """
  Whether the reviewed repo at `repo_path` is accessible on the socket's node.

  Mirrors the gate the merge form uses to render itself: on the local node the
  path must be an existing directory; on remote nodes availability is derived
  from RPC results (a bare path is enough to attempt the check).
  """
  def repo_available?(socket, repo_path) do
    if socket.assigns.current_node == node() do
      repo_path != nil && File.dir?(repo_path)
    else
      repo_path != nil
    end
  end

  @doc """
  Kicks off the async dry-run merge check after a successful task-data load,
  under the same gates `action_buttons` uses to render the merge form (branch
  exists, merge targets known, repo available). The result arrives later as a
  `{:merge_check_result, ...}` message.
  """
  def maybe_start(socket) do
    %{
      task_id: task_id,
      current_node: current_node,
      repo_path: repo_path,
      branch_name: branch_name,
      branch_exists: branch_exists,
      merge_targets: merge_targets,
      default_merge_target: default_target,
      merge_status: merge_status
    } = socket.assigns

    target = default_target || List.first(merge_targets)

    if branch_exists and merge_targets != [] and is_binary(target) and
         repo_available?(socket, repo_path) do
      case merge_status do
        %{state: :checking, target: ^target} ->
          # Already checking this exact target — don't spawn a duplicate.
          socket

        _ ->
          start(socket, current_node, repo_path, branch_name, target, task_id)
      end
    else
      socket
    end
  end

  @doc """
  Handles the merge form's `merge_target_change` event: updates the default
  target and re-runs the async merge check against the new target.
  """
  def handle_target_change(socket, params) do
    target = params["target_branch"]

    %{
      merge_targets: merge_targets,
      branch_name: branch_name,
      repo_path: repo_path,
      current_node: current_node,
      task_id: task_id
    } = socket.assigns

    if is_binary(target) and target in merge_targets and is_binary(branch_name) and
         repo_available?(socket, repo_path) do
      socket = assign(socket, :default_merge_target, target)

      start(socket, current_node, repo_path, branch_name, target, task_id)
    else
      socket
    end
  end

  @doc """
  Handles the conflict-status block's `auto_resolve` event: marks the original
  task continued (mirroring the resume flow) and starts a merge-resolution
  `:evolve` task. Redirects to the projects page on success.
  """
  def handle_auto_resolve(socket) do
    %{
      merge_status: merge_status,
      repo_path: repo_path,
      commit_sha: commit_sha,
      task_id: task_id,
      current_node: current_node
    } = socket.assigns

    case merge_status do
      %{state: :conflict, target: target} when is_binary(target) ->
        # Mirror the resume flow: mark the original task continued before
        # spawning the merge-resolution task.
        EvoDash.NodeContext.set_review_status(current_node, task_id, :continued)

        opts = [
          path: repo_path,
          mode: "simple",
          # The objective is an agent prompt — plain string interpolation,
          # NOT gettext.
          objective:
            "Merge the completed task's changes into the #{target} branch and resolve all merge conflicts, producing a fully integrated result.",
          starting_commit: commit_sha,
          merge_from: task_id,
          merge_target: target
        ]

        case EvoDash.NodeContext.start_task(current_node, :evolve, opts) do
          {:ok, _task} ->
            socket
            |> put_flash(
              :success,
              gettext(
                "Auto-resolve task started. It will merge the changes and resolve conflicts; review its result when done."
              )
            )
            |> push_navigate(to: Helpers.with_node_param("/", socket.assigns.current_node_id))

          {:error, reason} ->
            put_flash(
              socket,
              :error,
              gettext("Failed to start auto-resolve: %{reason}", reason: inspect(reason))
            )
        end

      _ ->
        put_flash(
          socket,
          :error,
          gettext("Auto-resolve unavailable — no merge conflict detected.")
        )
    end
  end

  @doc """
  Applies an async merge-check result to the socket's `merge_status`,
  ignoring stale results (different task/node, or a target that no longer
  matches the current status — a nil status has no target to mismatch).
  Unrecognized result shapes are dropped.
  """
  def handle_result(socket, task_id, node, target, result) do
    status =
      case result do
        {:ok, :clean} ->
          %{state: :clean, target: target, files: []}

        {:ok, {:conflict, files}} when is_list(files) ->
          %{state: :conflict, target: target, files: files}

        {:error, _reason} ->
          %{state: :error, target: target}

        _ ->
          nil
      end

    if status == nil do
      socket
    else
      %{task_id: current_task_id, current_node: current_node, merge_status: merge_status} =
        socket.assigns

      current_target = status_target(merge_status)

      stale? =
        task_id != current_task_id or node != current_node or
          (current_target != nil and current_target != target)

      if stale?, do: socket, else: assign(socket, :merge_status, status)
    end
  end

  # Spawns the dry-run merge check for `target` in a supervised Task (same
  # async pattern as SettingsLive's LLM connection test) and immediately marks
  # the status as :checking.
  defp start(socket, current_node, repo_path, branch_name, target, task_id) do
    parent = self()

    # Test seam: the check runner is resolved from application env at spawn
    # time so tests can stub out the real (repo-touching) dry-run check. The
    # default is the real `EvoDash.NodeContext.check_merge/4`.
    check_fun =
      Application.get_env(:evo_dash, :merge_check_runner) ||
        (&EvoDash.NodeContext.check_merge/4)

    socket = assign(socket, :merge_status, %{state: :checking, target: target, files: []})

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        try do
          check_fun.(current_node, repo_path, branch_name, target)
        rescue
          # The repo can vanish mid-check (e.g. temp-repo teardown in tests) —
          # report a failed check instead of crashing silently and leaving the
          # status stuck at :checking.
          _ -> {:error, :check_failed}
        end

      send(parent, {:merge_check_result, task_id, current_node, target, result})
    end)

    socket
  end

  defp status_target(%{target: target}) when is_binary(target), do: target
  defp status_target(_), do: nil
end
