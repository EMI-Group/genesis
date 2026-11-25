defmodule EvoDashWeb.WorkbenchActiveTasks do
  @moduledoc """
  The sidebar's task sections, rendered from the `EvoDashWeb.LiveHooks.NodeAware`
  Active Tasks feed.

  TWO disjoint sections, so neither can be mistaken for the other:

    * `#workbench-active-tasks` — LIVE tasks only (running/pending/finalizing/
      cancelling/pausing/paused), grouped per project. A finished task never
      appears here: it is not active, and its row would have nowhere honest to
      go.
    * `#workbench-needs-review` — the feed's review candidates (`:completed`
      with a nil `review_status`), as its OWN compact section with a count, at
      most `@review_limit` newest rows and a "View all" link to the tasks page.

  Interactive agent sessions appear in NEITHER section: the sidebar's
  Conversations block (`EvoDashWeb.HomeLive.SessionList`) is their one list, so
  a session is never duplicated here.
  """

  use EvoDashWeb, :html

  # Review candidates are a "what needs me next" nudge, not a second task list:
  # the section stays short and hands the rest to the tasks page.
  @review_limit 5

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

    # The feed's two buckets mean different things (`running` = live statuses,
    # `pending` = reviewable completions); each section takes only what its own
    # meaning allows, so a live task is never dropped just because the hub put it
    # in the other bucket, and a review candidate never leaks into Active Tasks.
    groups = build_groups(live_tasks(running_tasks, pending_tasks), now, node_id)
    review_tasks = review_tasks(running_tasks, pending_tasks)
    review_rows = review_tasks |> Enum.take(@review_limit) |> Enum.map(&row(&1, now, node_id))

    # The `ListEnter` hook's SCOPE: the viewed node only, and one scope per
    # section, so a new review candidate can never animate an Active Tasks row
    # (or re-seed that list's baseline). Both lists are cross-project (they
    # group EVERY project of the node), so a project must not be part of the
    # scope. The value must be NONEMPTY for the local node too (an empty scope is
    # deliberately inert in the hook), and a node change is what makes the hook
    # re-seed instead of animating everything.
    node_scope = node_id || "local"

    assigns =
      assign(assigns,
        groups: groups,
        review_rows: review_rows,
        review_count: length(review_tasks),
        review_more_href: with_node_param(~p"/tasks", node_id),
        list_enter_scope: "sidebar|" <> node_scope,
        review_list_enter_scope: "sidebar-review|" <> node_scope
      )

    ~H"""
    <section
      :if={@groups != []}
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
    <%!-- Review candidates are NOT active tasks: they get their own section,
         their own heading (with the honest total) and a link to the full
         tasks page instead of unbounded rows. --%>
    <section
      :if={@review_rows != []}
      id="workbench-needs-review"
      class="workbench-needs-review"
      aria-label={gettext("Needs review")}
    >
      <div class="workbench-section-heading">
        <%!-- zh_CN: 待审核 — 已完成但尚未合并/拒绝的任务，需要用户去 review 页面处理 --%>
        <span class="sidebar-label">{gettext("Needs review")}</span>
        <span
          id="workbench-needs-review-count"
          class="sidebar-label text-xs font-semibold text-base-content/60 tabular-nums"
        >
          {@review_count}
        </span>
      </div>
      <div
        id="workbench-needs-review-rows"
        class="space-y-1"
        phx-hook="ListEnter"
        data-list-enter-scope={@review_list_enter_scope}
      >
        <%= for row <- @review_rows do %>
          <.task_row row={row} />
        <% end %>
      </div>
      <div class="px-3 py-1.5">
        <.link
          id="workbench-needs-review-more"
          navigate={@review_more_href}
          class="flex items-center gap-1.5 rounded-lg text-xs font-semibold text-primary-standalone hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
        >
          <.icon name="hero-arrow-right" class="w-3.5 h-3.5 shrink-0" />
          <%!-- zh_CN: 查看全部 — 打开任务列表页看全部待审核任务 --%>
          <span class="sidebar-label">{gettext("View all")}</span>
        </.link>
      </div>
    </section>
    """
  end

  # ONE row renderer for both sections: an active row and a review row differ
  # only in their view-model fields, never in their markup. `status_title` is nil
  # for a session row (no session rows are rendered here anymore), and a nil
  # attribute is not rendered at all.
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

  # Per-project groups as `{project_name, rows}`, in sidebar order: "Other"
  # first, then case-insensitive alphabetical by project basename.
  defp build_groups(tasks, now, node_id) do
    tasks
    |> group_tasks_by_project()
    |> Enum.map(fn {project_name, tasks} ->
      {project_name, Enum.map(tasks, &row(&1, now, node_id))}
    end)
  end

  # A row of either section. `live?` decides the destination: a LIVE task opens
  # the run that actually focuses it — the tasks page's `?task=<id>` focus mode
  # (`/agents` takes no task param, so it would drop the user on the whole
  # inspector) — while a review candidate opens its review page. It covers the
  # pause pair because `:paused`/`:pausing` are NON-terminal, so they must NEVER
  # be titled or routed like a reviewable finished task.
  defp row(task, now, node_id) do
    live? = live_task?(task)
    label = task_label(task)

    {href, sub_line, status_title, pulse?} =
      if live? do
        {tasks_focus_href(task, node_id), format_elapsed(task.started_at, now),
         active_status_title(task.status), pulsing_status?(task.status)}
      else
        {review_href(task, node_id),
         gettext("completed") <> " " <> format_elapsed(task.finished_at, now),
         gettext("Pending Review"), false}
      end

    %{
      key: task_key(task),
      label: label,
      sub_line: sub_line,
      href: href,
      dot_class: task_status_dot_class(task.status),
      pulse?: pulse?,
      title: label <> " — " <> sub_line,
      status_title: status_title
    }
  end

  # A LIVE task's destination: the tasks page's FOCUS mode (`?task=<id>`), which
  # filters that page to the one task and opens its card. `with_node_param/2`
  # appends its own `?node=`, so the second parameter is joined with `&` by
  # building the whole query at once. A summary with no usable id cannot be
  # focused, so it falls back to the unfiltered page.
  defp tasks_focus_href(task, node_id) do
    case Enum.reject([node: node_id, task: task_key(task)], fn {_key, value} -> is_nil(value) end) do
      [] -> ~p"/tasks"
      query -> ~p"/tasks" <> "?" <> URI.encode_query(query)
    end
  end

  # A review candidate's destination: its review page, node-preserving. Without
  # an id there is nothing to review, so it degrades to the tasks page.
  defp review_href(task, node_id) do
    case task_key(task) do
      nil -> tasks_focus_href(task, node_id)
      id -> with_node_param(~p"/review/#{id}", node_id)
    end
  end

  # The `ListEnter` ROW key — the task id, never anything derived from the row's
  # href, sub-line or label: those change when a task moves from running to
  # `:awaiting_input` or from live to reviewable, and a STATUS change must not
  # replay the entrance animation. Keys are unique per render because the two
  # sections partition the feed disjointly (live statuses vs `:completed`
  # candidates) and each group holds one entry per task — so the hook's "first
  # element per key wins" rule never drops a row. A summary without a usable id
  # simply yields no key (the row is then ignored by the hook instead of
  # crashing the layout).
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
  # family colour `task_status_dot_class/1` gives it, rendered static). A review
  # candidate is finished, so it never pulses either (see `row/3`).
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

  # The Active Tasks section's rows: NON-map entries skipped (the hub is
  # shape-agnostic), interactive sessions dropped (they belong to the sidebar's
  # Conversations block — never duplicated here), and anything that is not a
  # live status dropped (a finished entry must not render as active). Both feed
  # buckets are considered, in feed order (running then pending), so a live task
  # is listed wherever the hub decided to put it.
  defp live_tasks(running_tasks, pending_tasks) do
    (running_tasks ++ pending_tasks)
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&session?/1)
    |> Enum.filter(&live_task?/1)
  end

  # The review candidates of the feed, newest first. The feed's `pending` bucket
  # holds only `:completed` + nil `review_status` reviewable tasks and arrives
  # sorted the same way (`NodeAware.partition_active_tasks/1`); the filter and the
  # sort are repeated here so the section can never list a live task and its
  # "newest N" promise never depends on an upstream order, and the sort key is
  # nil-safe (both timestamps absent → epoch).
  defp review_tasks(running_tasks, pending_tasks) do
    (running_tasks ++ pending_tasks)
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&session?/1)
    |> Enum.filter(&(Map.get(&1, :status) == :completed))
    |> Enum.sort_by(
      &(Map.get(&1, :finished_at) || Map.get(&1, :started_at) || ~U[1970-01-01 00:00:00Z]),
      {:desc, DateTime}
    )
  end

  # An interactive agent session, as the summary's `session_mode` string marks it.
  # A summary without the key is a one-shot task.
  defp session?(task), do: Map.get(task, :session_mode, "oneshot") == "interactive"

  # Groups live tasks by project name for sidebar display. Returns a list of
  # {project_name, tasks} tuples sorted alphabetically by project name, with
  # unpathed tasks at the top as "Other". Interactive sessions never reach this
  # function (`live_tasks/1` drops them).
  defp group_tasks_by_project(tasks) do
    grouped =
      Enum.group_by(tasks, fn task ->
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

    if others != [] do
      [{"Other", others} | sorted_named]
    else
      sorted_named
    end
  end

  # A task that is still LIVE — non-terminal, so it belongs in Active Tasks and
  # gets the live destination. The pause pair belongs here: a paused task is
  # resumable (`finished_at` nil) and must never be ordered or rendered like a
  # completed review candidate. `:awaiting_input` is deliberately absent: it is
  # the interactive-session status, and those rows live in the sidebar's
  # Conversations block.
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
