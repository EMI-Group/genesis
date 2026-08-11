defmodule EvoDashWeb.ProjectsLive.Assigns do
  @moduledoc """
  Assign-building helpers for the dashboard LiveView.

  Functions that compute derived assigns: notified task IDs and form defaults.
  Sidebar running/pending task loading lives in the unified NodeAware loader
  (`EvoDashWeb.LiveHooks.NodeAware` — `fetch_active_tasks/1`,
  `partition_active_tasks/1`, `assign_active_tasks/1`, column-based
  `show_review_button?/1`); the old local-only `assign_running_and_pending_tasks/1`
  and `show_review_button?/1` duplicates were removed in the unification.
  """

  alias EvoGit.TaskRegistry
  alias EvoDashWeb.ProjectsLive.Project
  import Phoenix.Component, only: [assign: 2]

  @doc """
  Builds the set of notified task IDs by merging existing notified IDs with
  all terminal tasks (completed/failed/cancelled) currently in the store.

  Uses the minimal id+status projection (`TaskRegistry.list_task_ids/1`), so
  no result/opts JSON decode happens — cheap enough for mount, `handle_params`
  fallbacks, and task mutations.
  """
  def build_notified_task_ids(existing_notified) do
    TaskRegistry.list_task_ids([:completed, :failed, :cancelled])
    |> Enum.map(& &1.id)
    |> MapSet.new()
    |> MapSet.union(existing_notified)
  end

  @doc """
  Sets form assigns to their default values, auto-detecting the task mode
  from the active project path if one is set.
  """
  def assign_form_defaults(socket) do
    mode =
      if socket.assigns[:active_project_path] do
        if socket.assigns[:remote?] do
          Project.detect_mode(socket.assigns.current_node, socket.assigns.active_project_path)
        else
          Project.detect_mode(socket.assigns.active_project_path)
        end
      else
        "genesis_new"
      end

    assign(socket,
      task_prompt: "",
      task_mode: mode,
      task_mode_info: "",
      task_node_path: "",
      task_starting_commit: "",
      task_resume_from: "",
      task_archive: false,
      task_build_system: nil,
      show_advanced: false
    )
  end
end
