defmodule EvoDashWeb.WorkbenchActiveTasks do
  @moduledoc false

  use EvoDashWeb, :html

  attr(:running_tasks, :list, default: [])
  attr(:pending_tasks, :list, default: [])
  attr(:current_node_id, :string, default: nil)

  def active_tasks(assigns) do
    # ONE clock read per render: every elapsed label of the sidebar shares the
    # same "now", so two rows of one render can never disagree about the time
    # (and no row reads the clock twice: the tooltip and the sub-line agree by
    # construction, because they are built from the same string).
    now = DateTime.utc_now()

    # The view models are built ONCE, before the template: a row's label,
    # sub-line, route, dot class and tooltips are pure functions of its task
    # summary, so computing them inside HEEx would repeat that work per row on
    # every re-render of the layout.
    running_tasks = List.wrap(Map.get(assigns, :running_tasks, []))
    pending_tasks = List.wrap(Map.get(assigns, :pending_tasks, []))
    node_id = Map.get(assigns, :current_node_id)

    sessions = build_sessions(running_tasks, pending_tasks, now, node_id)
    groups = build_groups(running_tasks, pending_tasks, now, node_id)

    # The `ListEnter` hook's SCOPE: the viewed node only. This list is
    # cross-project (it groups EVERY project of the node), so a project must not
    # be part of the scope — otherwise a project group appearing would re-seed
    # the baseline and animate the whole list. The value must be NONEMPTY for the
    # local node too (an empty scope is deliberately inert in the hook), and a
    # node change is what makes the hook re-seed instead of animating everything.
    list_enter_scope = "sidebar|" <> (node_id || "local")

    assigns =
      assign(assigns, sessions: sessions, groups: groups, list_enter_scope: list_enter_scope)

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
      <%!-- The `ListEnter` hook lives on this WRAPPER, never on a row: morphdom
           keeps the hook element (and therefore its `seen` baseline) mounted
           while rows come and go, whereas a hook on a row would remount with
           every row and forget the baseline. Rows only carry
           `data-list-enter-key`; the group headers stay unkeyed, and a row that
           is new in the unchanged scope gets `motion-list-enter` (defined in
           assets/css/app.css over the motion.css keyframes). The `id` exists
           only because LiveView refuses a `phx-hook` without one. --%>
      <div
        id="workbench-active-tasks-rows"
        class="space-y-1"
        phx-hook="ListEnter"
        data-list-enter-scope={@list_enter_scope}
      >
        <%!-- Interactive agent sessions live in their OWN group, above
           the per-project one-shot task groups (design record
           docs/agent-runtime-refactor.md §4.9 — sessions never fall
           into "Other"). `session_tasks/2` is fed by the same Active
           Tasks feed as the project rows. --%>
        <%= if @sessions != [] do %>
          <%!-- Sessions group header --%>
          <div class="workbench-task-group-header">
            <span class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-base-content/60 sidebar-label">
              <%!-- zh_CN: 会话 — 指可交互的智能体会话（等待用户输入），不是一次性任务 --%>
              <.icon name="hero-chat-bubble-left-right" class="w-3 h-3 shrink-0" />
              {gettext("Sessions")}
            </span>
          </div>
          <%= for row <- @sessions do %>
            <.task_row row={row} />
          <% end %>
        <% end %>
        <%= for {project_name, rows} <- @groups do %>
          <%!-- Project group header --%>
          <div class="workbench-task-group-header">
            <span class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-base-content/60 sidebar-label">
              <.icon name="hero-folder" class="w-3 h-3 shrink-0" />
              {project_name}
            </span>
          </div>
          <%!-- Tasks in this group --%>
          <%= for row <- rows do %>
            <.task_row row={row} />
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # ONE row renderer for both groups: session rows and project rows differ only
  # in their view-model fields, never in their markup. `status_title` is nil for
  # a session row, and a nil attribute is not rendered at all.
  attr(:row, :map, required: true)

  defp task_row(assigns) do
    ~H"""
    <.link
      navigate={@row.href}
      data-sidebar-task-link
      data-list-enter-key={@row.key}
      title={@row.title}
      class="flex items-center gap-2 px-3 py-2.5 rounded-lg text-sm text-base-content/80 hover:bg-base-300/70 hover:text-base-content transition-colors group"
    >
      <span
        class={[
          "w-2.5 h-2.5 rounded-full shrink-0",
          @row.dot_class,
          @row.pulse? && "animate-pulse"
        ]}
        title={@row.status_title}
      ></span>
      <div class="min-w-0 flex-1 sidebar-label">
        <span class="block truncate text-sm group-hover:text-base-content transition-colors">
          {@row.label}
        </span>
        <span class="block text-xs text-base-content/60 mt-1">
          {@row.sub_line}
        </span>
      </div>
    </.link>
    """
  end

  # Session rows, in feed order (running then pending). A session is always
  # "live" (it is a waiting interactive agent), so its row links to the task
  # list, its dot pulses and it carries no status tooltip.
  defp build_sessions(running_tasks, pending_tasks, now, node_id) do
    # Row-independent: every session links to the same node-aware task list.
    href = with_node_param(~p"/tasks", node_id)

    Enum.map(session_tasks(running_tasks, pending_tasks), fn task ->
      status = Map.get(task, :status)

      sub_line =
        if status == :awaiting_input,
          do: gettext("Waiting for you"),
          else: format_elapsed(Map.get(task, :started_at), now)

      label = task_label(task)

      %{
        key: task_key(task),
        label: label,
        sub_line: sub_line,
        href: href,
        dot_class: task_status_dot_class(status),
        pulse?: true,
        title: label <> " — " <> sub_line,
        status_title: nil
      }
    end)
  end

  # Per-project groups as `{project_name, rows}`, in sidebar order: "Other"
  # first, then case-insensitive alphabetical by project basename, with the
  # live rows of each group before its finished (reviewable) ones.
  defp build_groups(running_tasks, pending_tasks, now, node_id) do
    running_tasks
    |> group_tasks_by_project(pending_tasks)
    |> Enum.map(fn {project_name, tasks} ->
      {project_name, Enum.map(tasks, &project_row(&1, now, node_id))}
    end)
  end

  # A project group's row. `live?` = LIVE (not finished) and therefore links to
  # the agent inspector; it covers the pause pair because `:paused`/`:pausing`
  # are NON-terminal, so they must NEVER be titled or routed like a reviewable
  # finished task.
  defp project_row(task, now, node_id) do
    live? = live_task?(task)
    label = task_label(task)

    {href, sub_line, status_title} =
      if live? do
        {with_node_param(~p"/agents", node_id), format_elapsed(task.started_at, now),
         active_status_title(task.status)}
      else
        {with_node_param(~p"/review/#{task.id}", node_id),
         gettext("completed") <> " " <> format_elapsed(task.finished_at, now),
         gettext("Pending Review")}
      end

    %{
      key: task_key(task),
      label: label,
      sub_line: sub_line,
      href: href,
      dot_class: task_status_dot_class(task.status),
      pulse?: pulsing_status?(task.status),
      title: label <> " — " <> sub_line,
      status_title: status_title
    }
  end

  # The `ListEnter` ROW key — the task id, never anything derived from the row's
  # href, sub-line or label: those change when a task moves from running to
  # `:awaiting_input` or from live to reviewable, and a STATUS change must not
  # replay the entrance animation. Keys are unique per render because
  # `session_tasks/2` (interactive only) and `group_tasks_by_project/2`
  # (interactive rejected) partition the same feed disjointly, and each group
  # holds one entry per task — so the hook's "first element per key wins" rule
  # never drops a row. A summary without a usable id simply yields no key (the
  # row is then ignored by the hook instead of crashing the layout).
  defp task_key(task) do
    case Map.get(task, :id) do
      id when is_binary(id) -> id
      id when is_integer(id) -> Integer.to_string(id)
      _id -> nil
    end
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

  # Format a DateTime as a relative elapsed string like "2m ago", "1h ago".
  # `now` is read ONCE per render by `active_tasks/1` and threaded in, so every
  # row of a render measures against the same instant instead of calling
  # `DateTime.utc_now()` twice per row.
  defp format_elapsed(nil, _now), do: ""

  defp format_elapsed(dt, now) do
    diff = DateTime.diff(now, dt)

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
