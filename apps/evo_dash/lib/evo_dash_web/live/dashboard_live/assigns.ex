defmodule EvoDashWeb.DashboardLive.Assigns do
  @moduledoc """
  Assign-building helpers for the dashboard LiveView.

  Functions that compute derived assigns: notified task IDs, running/pending
  task lists, review button visibility, and form defaults.
  """

  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.Project
  import Phoenix.Component, only: [assign: 2, assign: 3]

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
  Assigns `:running_tasks` and `:pending_tasks` from `socket.assigns.tasks`.

  Uses a statuses-filtered lightweight summary query (SQL-side WHERE) that
  omits heavy JSON fields (logs, usage, archive_metadata) unnecessary for the
  sidebar task display.
  """
  def assign_running_and_pending_tasks(socket) do
    all_tasks = TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :completed])

    running_tasks =
      Enum.filter(all_tasks, &(&1.status in [:running, :pending, :finalizing]))

    pending_tasks =
      all_tasks
      |> Enum.filter(fn task ->
        task.status == :completed and is_nil(task.review_status) and
          show_review_button?(task)
      end)
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})

    socket
    |> assign(:running_tasks, running_tasks)
    |> assign(:pending_tasks, pending_tasks)
  end

  @doc """
  Returns `true` if the completed task has a branch ready for review.
  """
  def show_review_button?(%{status: :completed, result: {:ok, %{branch_name: branch}}})
      when is_binary(branch) and branch != "",
      do: true

  def show_review_button?(_), do: false

  @doc """
  Sets form assigns to their default values, auto-detecting the task mode
  from the active project path if one is set.
  """
  def assign_form_defaults(socket) do
    mode =
      if socket.assigns[:active_project_path] do
        Project.detect_mode(socket.assigns.active_project_path)
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
