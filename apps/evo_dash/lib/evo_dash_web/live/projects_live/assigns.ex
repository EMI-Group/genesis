defmodule EvoDashWeb.ProjectsLive.Assigns do
  @moduledoc """
  Assign-building helpers for the dashboard LiveView.

  `assign_form_defaults/1` resets the task-form assigns (pure). Nothing here
  touches the task store: notified-task-id seeding lives in
  `EvoDashWeb.ProjectsLive.Notifications` and runs in the async load batch,
  sidebar running/pending task loading lives in the unified NodeAware loader
  (`EvoDashWeb.LiveHooks.NodeAware` — `fetch_active_tasks/1`,
  `partition_active_tasks/1`, `assign_active_tasks/1`, column-based
  `show_review_button?/1`), and project activation lives in `ProjectsLive`.
  """

  alias EvoDashWeb.ProjectsLive.Project
  import Phoenix.Component, only: [assign: 2]

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
