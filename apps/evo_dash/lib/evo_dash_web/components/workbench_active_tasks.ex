defmodule EvoDashWeb.WorkbenchActiveTasks do
  @moduledoc false

  use EvoDashWeb, :html

  attr(:running_tasks, :list, default: [])
  attr(:pending_tasks, :list, default: [])
  attr(:current_node_id, :string, default: nil)

  def active_tasks(assigns) do
    ~H"""
    <section
      :if={@running_tasks != [] or @pending_tasks != []}
      id="workbench-active-tasks"
      class="workbench-active-tasks"
      aria-label={gettext("Active Tasks")}
    >
      <div class="workbench-section-heading">
        <%!-- zh_CN: 活动任务 --%>
        <span class="sidebar-label">{gettext("Active Tasks")}</span>
      </div>
      <div class="space-y-1">
        <%!-- Interactive agent sessions live in their OWN group, above
           the per-project one-shot task groups (design record
           docs/agent-runtime-refactor.md §4.9 — sessions never fall
           into "Other"). `session_tasks/2` is fed by the same Active
           Tasks feed as the project rows. --%>
        <% sessions = session_tasks(@running_tasks, @pending_tasks) %>
        <%= if sessions != [] do %>
          <%!-- Sessions group header --%>
          <div class="px-3 pt-2 pb-1 first:pt-0">
            <span class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-base-content/70 sidebar-label">
              <%!-- zh_CN: 会话 — 指可交互的智能体会话（等待用户输入），不是一次性任务 --%>
              <.icon name="hero-chat-bubble-left-right" class="w-3 h-3 shrink-0" />
              {gettext("Sessions")}
            </span>
          </div>
          <%!-- Interactive sessions in this group --%>
          <%= for task <- sessions do %>
            <% awaiting = Map.get(task, :status) == :awaiting_input %>
            <% session_sub_line =
              if awaiting,
                do: gettext("Waiting for you"),
                else: format_elapsed(Map.get(task, :started_at)) %>
            <.link
              navigate={with_node_param(~p"/tasks", @current_node_id)}
              data-sidebar-task-link
              title={task_label(task) <> " — " <> session_sub_line}
              class="flex items-center gap-2 px-3 py-2.5 rounded-lg text-sm text-base-content/80 hover:bg-base-300/70 hover:text-base-content transition-colors group"
            >
              <span class={[
                "w-2.5 h-2.5 rounded-full shrink-0",
                task_status_dot_class(Map.get(task, :status)),
                "animate-pulse"
              ]}></span>
              <div class="min-w-0 flex-1 sidebar-label">
                <span class="block truncate group-hover:text-base-content transition-colors">
                  {task_label(task)}
                </span>
                <span class="block text-xs text-base-content/60 mt-0.5">
                  {session_sub_line}
                </span>
              </div>
            </.link>
          <% end %>
        <% end %>
        <%= for {project_name, tasks} <- group_tasks_by_project(@running_tasks, @pending_tasks) do %>
          <%!-- Project group header --%>
          <div class="px-3 pt-2 pb-1 first:pt-0">
            <span class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-base-content/70 sidebar-label">
              <.icon name="hero-folder" class="w-3 h-3 shrink-0" />
              {project_name}
            </span>
          </div>
          <%!-- Tasks in this group --%>
          <%= for task <- tasks do %>
            <%!-- `is_running` = LIVE (not finished) and therefore links to
               the agent inspector; it covers the pause pair because
               `:paused`/`:pausing` are NON-terminal, so they must NEVER
               be titled or routed like a reviewable finished task. --%>
            <% is_running =
              task.status in [
                :running,
                :pending,
                :finalizing,
                :cancelling,
                :pausing,
                :paused
              ] %>
            <.link
              navigate={
                if is_running,
                  do: with_node_param(~p"/agents", @current_node_id),
                  else: with_node_param(~p"/review/#{task.id}", @current_node_id)
              }
              data-sidebar-task-link
              title={task_label(task) <> " — " <> (if is_running, do: format_elapsed(task.started_at), else: gettext("completed") <> " " <> format_elapsed(task.finished_at))}
              class="flex items-center gap-2 px-3 py-2.5 rounded-lg text-sm text-base-content/80 hover:bg-base-300/70 hover:text-base-content transition-colors group"
            >
              <span
                class={[
                  "w-2.5 h-2.5 rounded-full shrink-0",
                  task_status_dot_class(task.status),
                  pulsing_status?(task.status) && "animate-pulse"
                ]}
                title={
                  if is_running,
                    do: active_status_title(task.status),
                    else: gettext("Pending Review")
                }
              ></span>
              <div class="min-w-0 flex-1 sidebar-label">
                <span class="block truncate group-hover:text-base-content transition-colors">
                  {task_label(task)}
                </span>
                <span class="block text-xs text-base-content/60 mt-0.5">
                  <%= if is_running do %>
                    {format_elapsed(task.started_at)}
                  <% else %>
                    {gettext("completed")} {format_elapsed(task.finished_at)}
                  <% end %>
                </span>
              </div>
            </.link>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # Extract a display label for a task: objective > prompt > truncated task ID
  defp task_label(task) do
    opts = Map.get(task, :opts, []) || []
    label = opts[:objective] || opts[:prompt] || String.slice(task.id, 0, 8)

    if String.length(label) > 30 do
      String.slice(label, 0, 30) <> "..."
    else
      label
    end
  end

  # Statuses whose sidebar dot may ANIMATE: only states that can still make
  # progress on their own. `:paused` is deliberately absent — the task is
  # stopped, so a pulse would claim activity that is not happening (it keeps the
  # family colour `task_status_dot_class/1` gives it, rendered static).
  defp pulsing_status?(status),
    do: status in [:running, :pending, :finalizing, :cancelling, :pausing]

  # Tooltip text for a LIVE row's status dot. The COLOUR still comes from
  # `EvoDashWeb.Helpers.task_status_dot_class/1` (one source of truth); only the
  # wording differs, because the pause pair is live-but-not-running and calling a
  # paused task "Running" would misreport it.
  # zh_CN: 已暂停(可恢复)
  defp active_status_title(:paused), do: gettext("Paused")
  # zh_CN: 暂停中(等待工具调用结束)
  defp active_status_title(:pausing), do: gettext("Pausing")
  defp active_status_title(_status), do: gettext("Running")

  # Format a DateTime as a relative elapsed string like "2m ago", "1h ago"
  defp format_elapsed(nil), do: ""

  defp format_elapsed(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 30 -> gettext("just now")
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  # Interactive agent sessions from the Active Tasks feed, in feed order
  # (running then pending). A summary map without a `:session_mode` key is a
  # one-shot task, so only an explicit "interactive" entry is a session.
  # Defense-in-depth: skip non-map entries instead of crashing the layout.
  defp session_tasks(running_tasks, pending_tasks) do
    (running_tasks ++ pending_tasks)
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(Map.get(&1, :session_mode, "oneshot") == "interactive"))
  end

  # Groups running and pending tasks by project name for sidebar display.
  # Returns a list of {project_name, tasks} tuples sorted alphabetically by
  # project name, with unpathed tasks at the top as "Other". Interactive
  # sessions are excluded: they render in their own "Sessions" group.
  defp group_tasks_by_project(running_tasks, pending_tasks) do
    # Defense-in-depth: the sidebar lists are seeded from the shape-agnostic
    # ActiveTasks hub, so skip any non-map entry instead of crashing the page.
    all =
      (running_tasks ++ pending_tasks)
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&(Map.get(&1, :session_mode, "oneshot") == "interactive"))

    grouped =
      Enum.group_by(all, fn task ->
        case Map.get(task, :project_path) do
          nil -> nil
          path -> Path.basename(path)
        end
      end)

    {others, named} = Map.pop(grouped, nil, [])

    sorted_named =
      Enum.sort(named, fn {a, _}, {b, _} ->
        String.downcase(a) <= String.downcase(b)
      end)

    sorted_groups =
      Enum.map(sorted_named, fn {name, tasks} ->
        {running, pending} = Enum.split_with(tasks, &live_task?/1)

        {name, running ++ pending}
      end)

    if others != [] do
      {running, pending} = Enum.split_with(others, &live_task?/1)

      [{"Other", running ++ pending} | sorted_groups]
    else
      sorted_groups
    end
  end

  # The "live" side of a project group: a task that is not finished renders
  # BEFORE its group's finished (reviewable) rows. The pause pair belongs here —
  # a paused task is non-terminal (resumable, `finished_at` nil) and must never
  # be ordered or rendered like a completed review candidate.
  defp live_task?(task),
    do:
      Map.get(task, :status) in [
        :running,
        :pending,
        :finalizing,
        :cancelling,
        :pausing,
        :paused
      ]
end
