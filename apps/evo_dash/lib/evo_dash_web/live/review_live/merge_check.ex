defmodule EvoDashWeb.ReviewLive.MergeCheck do
  @moduledoc """
  Async dry-run merge check + auto-resolve support for `EvoDashWeb.ReviewLive`.

  Kept as a support module (same pattern as the `projects_live/` support
  modules) so the single-page LiveView stays lean. The check functions take and
  return a LiveView socket; `auto_resolve_payload/1` is PURE (it builds the
  payload the LiveView's off-process action layer executes).

  Multi-repo aware: operates on `socket.assigns.review_repos` (a list of repo
  maps, primary first), never on the flat per-repo assigns. Each async check
  is spawned per repo and results are routed back tagged with the repo's
  `repo_id`.

  Also hosts `repo_available?/2` — the shared repo-existence gate the review
  page uses for merge, resume, and branch checks.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

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
  Kicks off the async dry-run merge check for EVERY repo in
  `socket.assigns.review_repos`, under the same gates `action_buttons` uses to
  render the merge form (branch exists, merge targets known, repo available).
  Results arrive later as `{:merge_check_result, ...}` messages tagged with
  each repo's `repo_id`.
  """
  def maybe_start(socket) do
    Enum.reduce(socket.assigns.review_repos, socket, fn repo, socket ->
      maybe_start_repo(socket, repo)
    end)
  end

  @doc """
  Handles the merge form's `merge_target_change` event: updates the default
  target for the changed repo (params `repo_id`, defaulting to `"primary"`)
  and re-runs the async merge check against the new target.
  """
  def handle_target_change(socket, params) do
    target = params["target_branch"]
    repo_id = repo_id_param(params)

    %{current_node: current_node, task_id: task_id} = socket.assigns

    case find_repo(socket.assigns.review_repos, repo_id) do
      %{merge_targets: merge_targets, branch_name: branch_name, repo_path: repo_path} ->
        if is_binary(target) and target in merge_targets and is_binary(branch_name) and
             repo_available?(socket, repo_path) do
          socket =
            update_repo(socket, repo_id, fn repo -> %{repo | default_merge_target: target} end)

          start(socket, current_node, repo_path, branch_name, target, task_id, repo_id)
        else
          socket
        end

      nil ->
        socket
    end
  end

  @doc """
  Builds the merge-resolution task payload for the conflict-status block's
  `auto_resolve` event — `{:ok, %{opts: opts, to: to}}` when the PRIMARY repo
  currently reports a merge conflict with a known target branch, else
  `:unavailable`.

  Pure: it performs no I/O and mutates nothing, so `EvoDashWeb.ReviewLive`
  spawns the actual work (mark the task continued, start the `:evolve` task)
  off-process through `EvoDashWeb.ReviewLive.Actions.auto_resolve/3`.
  Primary-repo scoped — reads the `"primary"` entry from `@review_repos`.
  """
  def auto_resolve_payload(socket) do
    %{task_id: task_id} = socket.assigns

    case find_repo(socket.assigns.review_repos, "primary") do
      %{
        merge_status: %{state: :conflict, target: target},
        repo_path: repo_path,
        commit_sha: commit_sha
      }
      when is_binary(target) ->
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

        {:ok,
         %{
           opts: opts,
           to: Helpers.with_node_param("/projects", socket.assigns.current_node_id)
         }}

      _ ->
        :unavailable
    end
  end

  @doc """
  Applies an async merge-check result (tagged with `repo_id`) to that repo's
  `merge_status` inside `socket.assigns.review_repos`, ignoring stale results
  (different task/node, a repo_id no longer present in `@review_repos`, or a
  target that no longer matches the repo's current status — a nil status has
  no target to mismatch). Unrecognized result shapes are dropped.
  """
  def handle_result(socket, task_id, node, repo_id, target, result) do
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
      %{task_id: current_task_id, current_node: current_node} = socket.assigns

      stale? =
        task_id != current_task_id or node != current_node or
          stale_repo_target?(socket.assigns.review_repos, repo_id, target)

      if stale? do
        socket
      else
        update_repo(socket, repo_id, fn repo -> %{repo | merge_status: status} end)
      end
    end
  end

  # One repo entry's worth of `maybe_start` gating + spawn.
  defp maybe_start_repo(socket, repo) do
    %{task_id: task_id, current_node: current_node} = socket.assigns

    target = repo.default_merge_target || List.first(repo.merge_targets)

    if repo.branch_exists and repo.merge_targets != [] and is_binary(target) and
         repo_available?(socket, repo.repo_path) do
      case repo.merge_status do
        %{state: :checking, target: ^target} ->
          # Already checking this exact target — don't spawn a duplicate.
          socket

        _ ->
          start(
            socket,
            current_node,
            repo.repo_path,
            repo.branch_name,
            target,
            task_id,
            repo.repo_id
          )
      end
    else
      socket
    end
  end

  # Spawns the dry-run merge check for one repo's `target` in a supervised Task
  # (same async pattern as SettingsLive's LLM connection test), immediately
  # marks THAT repo's status as :checking, and reports the result tagged with
  # the repo's `repo_id`.
  defp start(socket, current_node, repo_path, branch_name, target, task_id, repo_id) do
    parent = self()

    # Test seam: the check runner is resolved from application env at spawn
    # time so tests can stub out the real (repo-touching) dry-run check. The
    # default is the real `EvoDash.NodeContext.check_merge/4`.
    check_fun =
      Application.get_env(:evo_dash, :merge_check_runner) ||
        (&EvoDash.NodeContext.check_merge/4)

    socket =
      update_repo(socket, repo_id, fn repo ->
        %{repo | merge_status: %{state: :checking, target: target, files: []}}
      end)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Exit-safe boundary: the check runs a cross-node RPC (`check_merge/4`),
      # whose target GenServer / remote daemon can be dead, busy, or slower
      # than the call timeout — and a `GenServer.call` timeout EXITS the
      # caller, which `rescue` cannot catch. Without the boundary the child
      # would die BEFORE sending its result, leaving this repo's status stuck
      # at :checking forever. `EvoDash.SafeCall.run/1` turns every failure mode
      # (exit, raise, throw) into `{:error, reason}`, so the result message is
      # ALWAYS sent and a failed check surfaces as the existing
      # `{:error, :check_failed}` → `%{state: :error}` path (e.g. when the repo
      # vanishes mid-check, like temp-repo teardown in tests).
      result =
        case EvoDash.SafeCall.run(fn ->
               check_fun.(current_node, repo_path, branch_name, target)
             end) do
          {:ok, value} -> value
          {:error, _reason} -> {:error, :check_failed}
        end

      send(parent, {:merge_check_result, task_id, current_node, repo_id, target, result})
    end)

    socket
  end

  defp find_repo(review_repos, repo_id) do
    Enum.find(review_repos, fn repo -> repo.repo_id == repo_id end)
  end

  defp repo_id_param(params) do
    case params["repo_id"] do
      repo_id when is_binary(repo_id) and repo_id != "" -> repo_id
      _ -> "primary"
    end
  end

  # In-place update of one repo entry's fields inside
  # `socket.assigns.review_repos` (the entry is guaranteed to exist at every
  # call site).
  @doc """
  In-place update of ONE repo entry's fields inside
  `socket.assigns.review_repos`, identified by `repo_id`. Public so
  `EvoDashWeb.ReviewLive`'s per-repo merge/reject handlers reuse the same
  single-entry update logic (no duplicated `Enum.map` update).
  """
  def update_repo(socket, repo_id, fun) do
    updated =
      Enum.map(socket.assigns.review_repos, fn
        %{repo_id: ^repo_id} = repo -> fun.(repo)
        repo -> repo
      end)

    assign(socket, :review_repos, updated)
  end

  # True when a result for `repo_id`/`target` should be dropped: the repo
  # entry is gone from `@review_repos`, or its current status targets a
  # different branch (a nil status has no target to mismatch).
  defp stale_repo_target?(review_repos, repo_id, target) do
    case find_repo(review_repos, repo_id) do
      nil ->
        true

      %{merge_status: merge_status} ->
        current_target = status_target(merge_status)
        current_target != nil and current_target != target
    end
  end

  defp status_target(%{target: target}) when is_binary(target), do: target
  defp status_target(_), do: nil
end
