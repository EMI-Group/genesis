defmodule EvoDashWeb.DashboardLive.Assigns do
  @moduledoc """
  Assign-building helpers for the dashboard LiveView.

  Functions that compute derived assigns: notified task IDs, running/pending
  task lists, review button visibility, form defaults, and current task list.
  """

  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.Project
  import Phoenix.Component, only: [assign: 2, assign: 3]

  @doc """
  Builds the set of notified task IDs by merging existing notified IDs with
  all finished tasks in the given list.
  """
  def build_notified_task_ids(tasks, existing_notified) do
    tasks
    |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
    |> Enum.map(& &1.id)
    |> MapSet.new()
    |> MapSet.union(existing_notified)
  end

  @doc """
  Assigns `:running_tasks` and `:pending_tasks` from `socket.assigns.tasks`.

  Uses lightweight summary queries that omit heavy JSON fields (logs, usage,
  archive_metadata) unnecessary for the sidebar task display.
  """
  def assign_running_and_pending_tasks(socket) do
    all_tasks = TaskRegistry.list_tasks_summary()

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
  Assigns `:running_tasks` and `:pending_tasks` from the given task list.
  Uses lightweight summary queries (same as the /1 variant).
  """
  def assign_running_and_pending_tasks(socket, _all_tasks) do
    all_tasks = TaskRegistry.list_tasks_summary()

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

  @doc """
  Returns the current task list for the socket, scoped to the active project
  path if one is set. Strips heavy fields (logs, usage, archive_metadata) for
  the main task card display. Task cards need the full `opts` field (objective,
  mode, etc.), so we use `list_tasks` + manual strip rather than the lightweight
  `list_tasks_summary` (which omits opts).
  """
  def current_tasks(socket) do
    tasks =
      if socket.assigns.active_project_path do
        TaskRegistry.list_tasks_by_path(socket.assigns.active_project_path)
      else
        TaskRegistry.list_tasks()
      end

    Enum.map(tasks, &strip_heavy_fields/1)
  end

  @doc """
  Strips heavy JSON fields (logs, usage, archive_metadata) from a task struct,
  returning a lightweight copy suitable for the main task card list.
  """
  def strip_heavy_fields(task) do
    %{task | logs: [], usage: nil, archive_metadata: nil}
  end
end
