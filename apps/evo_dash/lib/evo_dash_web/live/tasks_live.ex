defmodule EvoDashWeb.TasksLive do
  @moduledoc """
  Cross-project task list with filtering by status, project, and review state.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext
  alias EvoGit.TaskRegistry
  use EvoDashWeb.ModalHelpers

  @default_page_size 25

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:tasks} config_status={@config_status} current_node_id={@current_node_id} current_node_name={@current_node_name} running_tasks={@running_tasks} pending_tasks={@pending_tasks}>
      <%= if @current_node != node() do %>
        <!-- Remote node: task history is local-only -->
        <div class="mt-6 text-center py-10 text-base-content/50 animate-fade-in-up">
          <div class="animate-float">
            <.icon name="hero-inbox" class="size-14 mx-auto mb-3 opacity-50" />
          </div>
          <p class="text-base font-medium">{gettext("Task history is only available when viewing the local node.")}</p>
          <p class="text-sm mt-1">
            {gettext("Remote agents can be viewed on the Agents page.")}
          </p>
        </div>
      <% else %>
      <!-- Filter Bar -->
      <div class="rounded-lg border border-base-200 bg-base-100 p-3 sm:p-4 mb-4">
        <form id="task-filters" phx-submit="noop">
          <div class="flex flex-col sm:flex-row gap-3">
          <!-- Status Filter -->
          <div class="form-control">
            <select
              name="status_filter"
              class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
              phx-change="filter_tasks"
            >
              <option value="all" selected={@status_filter == "all"}>{gettext("All Statuses")}</option>
              <option value="running" selected={@status_filter == "running"}>{gettext("Running")}</option>
              <option value="pending" selected={@status_filter == "pending"}>{gettext("Pending")}</option>
              <option value="completed" selected={@status_filter == "completed"}>{gettext("Completed")}</option>
              <option value="failed" selected={@status_filter == "failed"}>{gettext("Failed")}</option>
              <option value="cancelled" selected={@status_filter == "cancelled"}>{gettext("Cancelled")}</option>
            </select>
          </div>

          <!-- Project Filter -->
          <div class="form-control">
            <select
              name="project_filter"
              class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
              phx-change="filter_tasks"
            >
              <option value="all" selected={@project_filter == "all"}>{gettext("All Projects")}</option>
              <%= for path <- @project_paths do %>
                <option value={path} selected={@project_filter == path}>
                  <%= Path.basename(path) %> (<%= String.slice(path, 0, 30) %>...)
                </option>
              <% end %>
            </select>
          </div>

          <!-- Review Status Filter -->
          <div class="form-control">
            <select
              name="review_filter"
              class="select select-bordered select-md rounded-md bg-base-100 sm:w-48 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
              phx-change="filter_review"
            >
              <option value="all" selected={@review_status_filter == "all"}>{gettext("All Reviews")}</option>
              <option value="pending" selected={@review_status_filter == "pending"}>{gettext("Pending Review")}</option>
              <option value="merged" selected={@review_status_filter == "merged"}>{gettext("Merged")}</option>
              <option value="rejected" selected={@review_status_filter == "rejected"}>{gettext("Rejected")}</option>
              <option value="continued" selected={@review_status_filter == "continued"}>{gettext("Continued")}</option>
            </select>
          </div>

          <!-- Search -->
          <div class="form-control flex-1">
            <div class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-base-content/40 pointer-events-none z-10"
              />
              <input
                type="text"
                name="search_query"
                value={@search_query}
                class="input input-bordered input-md rounded-md bg-base-100 pl-10 w-full focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary shadow-sm"
                placeholder={gettext("Search by task ID, prompt, or objective...")}
                phx-change="search_tasks"
                phx-debounce="200"
              />
            </div>
          </div>

          <!-- Actions -->
          <div class="flex items-center gap-2 shrink-0">
            <button
              type="button"
              class="btn btn-ghost btn-md"
              phx-click="reset_filters"
              title={gettext("Reset all filters")}
            >
              <.icon name="hero-x-mark" class="size-4" /> {gettext("Reset")}
            </button>
          </div>
          </div>
        </form>

        <!-- Active filters indicator -->
        <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" do %>
          <div class="flex items-center gap-2 mt-3 pt-3 border-t border-base-200/50">
            <span class="text-xs text-base-content/50">{gettext("Active filters:")}</span>
            <%= if @status_filter != "all" do %>
              <span class="badge badge-primary gap-1 rounded-md">
                {@status_filter}
                <button phx-click="clear_filter" phx-value-filter="status" class="hover:opacity-70">×</button>
              </span>
            <% end %>
            <%= if @project_filter != "all" do %>
              <span class="badge badge-secondary gap-1 rounded-md">
                {Path.basename(@project_filter)}
                <button phx-click="clear_filter" phx-value-filter="project" class="hover:opacity-70">×</button>
              </span>
            <% end %>
            <%= if @search_query != "" do %>
              <span class="badge badge-accent gap-1 rounded-md">
                "{String.slice(@search_query, 0, 20)}{if String.length(@search_query) > 20, do: "..."}"
                <button phx-click="clear_filter" phx-value-filter="search" class="hover:opacity-70">×</button>
              </span>
            <% end %>
            <%= if @review_status_filter != "all" do %>
              <span class="badge badge-accent gap-1 rounded-md">
                <%= case @review_status_filter do %>
                  <% "pending" -> %>{gettext("Pending Review")}
                  <% "merged" -> %>{gettext("Merged")}
                  <% "rejected" -> %>{gettext("Rejected")}
                  <% "continued" -> %>{gettext("Continued")}
                  <% _ -> %>{@review_status_filter}
                <% end %>
                <button phx-click="clear_filter" phx-value-filter="review" class="hover:opacity-70">×</button>
              </span>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Task Count -->
      <div class="flex items-center justify-between mb-4">
        <p class="text-sm text-base-content/60">
          {dngettext("default", "%{count} task found", "%{count} tasks found", length(@filtered_tasks))}
        </p>
      </div>

      <!-- Task List -->
      <div class="space-y-4 lg:space-y-5">
        <%= if @filtered_tasks == [] do %>
          <div class="text-center py-12 sm:py-16 text-base-content/50">
            <.icon name="hero-inbox" class="size-10 mx-auto mb-4 opacity-50" />
            <p class="text-lg font-medium">{gettext("No tasks found")}</p>
            <p class="text-sm mt-1">
              <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" do %>
                {gettext("Try adjusting your filters or search query.")}
              <% else %>
                {gettext("Tasks will appear here once you start them from the dashboard.")}
              <% end %>
            </p>
          </div>
        <% else %>
          <%= for {task, idx} <- Enum.with_index(@filtered_tasks) do %>
            <div class={["relative z-10 has-[[open]]:z-30 animate-fade-in-up", animation_delay_class(idx)]}>
              <EvoDashWeb.TaskCardComponents.task_card
                task={task}
                show_details={MapSet.member?(@expanded_task_ids, task.id)}
              />
            </div>
          <% end %>
        <% end %>
      </div>

      <!-- Pagination Controls -->
      <%= if @total_count > 0 do %>
        <% offset = (@current_page - 1) * @page_size %>
        <% range_start = offset + 1 %>
        <% range_end = min(offset + @page_size, @total_count) %>
        <% pages = page_window(@current_page, @total_pages) %>
        <div class="mt-4 flex flex-col items-center gap-3">
          <p class="text-sm text-base-content/60">
            {gettext("Showing %{start}–%{end} of %{total} tasks",
              start: range_start,
              end: range_end,
              total: @total_count
            )}
          </p>
          <div class="flex items-center gap-2">
            <div class="join">
              <button
                class="join-item btn btn-sm"
                phx-click="prev_page"
                disabled={@current_page <= 1}
              >
                <.icon name="hero-chevron-left" class="size-4" />
              </button>
              <%= for p <- pages do %>
                <%= if p == @current_page do %>
                  <button class="join-item btn btn-sm btn-primary" disabled>
                    {p}
                  </button>
                <% else %>
                  <button
                    class="join-item btn btn-sm"
                    phx-click="goto_page"
                    phx-value-page={p}
                  >
                    {p}
                  </button>
                <% end %>
              <% end %>
              <button
                class="join-item btn btn-sm"
                phx-click="next_page"
                disabled={@current_page >= @total_pages}
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </button>
            </div>
          </div>
          <p class="text-xs text-base-content/50">
            {gettext("Page %{current} of %{total}", current: @current_page, total: @total_pages)}
          </p>
        </div>
      <% end %>

      <!-- Clear History (moved to bottom for safety) -->
      <div class="mt-6 flex justify-center sm:justify-end">
        <button type="button" class="btn btn-ghost btn-sm text-error/60 hover:text-error gap-1" phx-click="clear_task_history" phx-confirm={gettext("Clear all finished task history? This cannot be undone.")}>
          <.icon name="hero-trash" class="size-3.5" /> {gettext("Clear History")}
        </button>
      </div>

      <!-- Full Result Modal -->
      <%= if @selected_result do %>
        <EvoDashWeb.Helpers.modal on_close="close_result_modal">
          <:title>
            <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
            {gettext("Task Result")}
          </:title>
          {EvoDashWeb.TaskCardComponents.render_result_full(@selected_result)}
        </EvoDashWeb.Helpers.modal>
      <% end %>

      <!-- Full Options Modal -->
      <%= if @selected_options do %>
        <EvoDashWeb.Helpers.modal on_close="close_options_modal">
          <:title>
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-5 text-primary" />
            {gettext("Full Objective")}
          </:title>
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @selected_options %></pre>
        </EvoDashWeb.Helpers.modal>
      <% end %>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    # Project paths are cheap-ish and needed for the filter dropdown regardless
    # of pagination. Tasks are loaded in handle_params (server-side pagination).
    project_paths = TaskRegistry.get_unique_paths()

    config_status = config_status()

    socket =
      socket
      |> assign(
        tasks: [],
        project_paths: project_paths,
        status_filter: "all",
        project_filter: "all",
        search_query: "",
        review_status_filter: "all",
        expanded_task_ids: MapSet.new(),
        selected_result: nil,
        selected_options: nil,
        config_status: config_status,
        current_page: 1,
        page_size: @default_page_size,
        total_count: 0,
        total_pages: 1
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    requested_page = parse_page(params["page"])

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/tasks")
      |> load_page_into_socket(requested_page)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:tasks_updated}, socket) do
    socket = reload_current_page(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.load_running_and_pending_tasks(socket)}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    # Task status transitions (e.g. :finalizing, :running) are broadcast on the
    # "tasks" PubSub topic. Re-fetch the current page so the UI reflects the change.
    socket = reload_current_page(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.load_running_and_pending_tasks(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_tasks", params, socket) do
    status_filter = params["status_filter"] || socket.assigns.status_filter
    project_filter = params["project_filter"] || socket.assigns.project_filter

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> assign(:project_filter, project_filter)
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("filter_review", %{"review_filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, filter)
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("search_tasks", %{"search_query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_page_into_socket(1)}
  end

  # Prevents page reload when pressing Enter in the filter/search form
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(
       status_filter: "all",
       project_filter: "all",
       search_query: "",
       review_status_filter: "all"
     )
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "status"}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, "all")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "project"}, socket) do
    {:noreply,
     socket
     |> assign(:project_filter, "all")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "search"}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "review"}, socket) do
    {:noreply,
     socket
     |> assign(:review_status_filter, "all")
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks?page=#{page}")}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    page = max(1, socket.assigns.current_page - 1)
    {:noreply, push_patch(socket, to: ~p"/tasks?page=#{page}")}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    page = min(socket.assigns.total_pages, socket.assigns.current_page + 1)
    {:noreply, push_patch(socket, to: ~p"/tasks?page=#{page}")}
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    TaskRegistry.clear_finished_tasks()

    {:noreply,
     socket
     |> assign(:expanded_task_ids, MapSet.new())
     |> load_page_into_socket(1)}
  end

  @impl true
  def handle_event("toggle_task_details", %{"task_id" => task_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_task_ids, task_id) do
        MapSet.delete(socket.assigns.expanded_task_ids, task_id)
      else
        MapSet.put(socket.assigns.expanded_task_ids, task_id)
      end

    {:noreply, assign(socket, :expanded_task_ids, expanded)}
  end

  @impl true
  def handle_event("view_full_result", %{"task_id" => task_id}, socket) do
    view_full_result(socket, task_id)
  end

  @impl true
  def handle_event("close_result_modal", _params, socket) do
    close_result_modal(socket)
  end

  @impl true
  def handle_event("view_full_options", %{"task_id" => task_id}, socket) do
    view_full_options(socket, task_id)
  end

  @impl true
  def handle_event("close_options_modal", _params, socket) do
    close_options_modal(socket)
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

        {:noreply,
         socket
         |> assign(:expanded_task_ids, expanded)
         |> reload_current_page()}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to cancel task: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

    {:noreply,
     socket
     |> assign(:expanded_task_ids, expanded)
     |> reload_current_page()}
  end

  # Helpers

  # Parses the ?page= query param into a positive integer (default 1).
  # Uses Integer.parse/1 (returns :error for non-integers) — no try/rescue,
  # no String.to_existing_atom.
  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  # Fetches one page of tasks (server-side LIMIT/OFFSET). Returns
  # {tasks, clamped_page, total_count, total_pages}. The requested page is
  # clamped against the actual total_pages derived from the returned count.
  # If clamping changes the page, a second fetch is performed for the
  # clamped page. This is at most one extra fetch and only on edge cases
  # (e.g. a stale/high page number).
  defp load_page(requested_page, page_size, filters) do
    offset = (requested_page - 1) * page_size
    {tasks, total_count} = TaskRegistry.list_tasks_paginated(limit: page_size, offset: offset, filters: filters)
    total_pages = total_pages(total_count, page_size)
    clamped_page = min(max(1, requested_page), total_pages)

    if clamped_page != requested_page do
      clamped_offset = (clamped_page - 1) * page_size

      {clamped_tasks, ^total_count} =
        TaskRegistry.list_tasks_paginated(limit: page_size, offset: clamped_offset, filters: filters)

      {clamped_tasks, clamped_page, total_count, total_pages}
    else
      {tasks, clamped_page, total_count, total_pages}
    end
  end

  defp total_pages(total_count, page_size) when page_size > 0 do
    max(1, ceil(total_count / page_size))
  end

  # Returns a windowed range of page numbers around the current page for the
  # pagination button group. Shows up to 7 page buttons centered on the
  # current page, clamped to the valid range 1..total_pages.
  defp page_window(current_page, total_pages) do
    window = 3
    start_page = max(1, current_page - window)
    end_page = min(total_pages, current_page + window)
    Enum.to_list(start_page..end_page)
  end

  # Reloads the current page's tasks into the socket assigns and recomputes
  # the filtered view. Used by PubSub handlers and mutating events so the UI
  # stays consistent after changes.
  defp reload_current_page(socket) do
    load_page_into_socket(socket, socket.assigns.current_page)
  end

  defp load_page_into_socket(socket, page) do
    filters = build_filters_from_assigns(socket)
    {tasks, current_page, total_count, total_pages} =
      load_page(page, socket.assigns.page_size, filters)

    socket
    |> assign(:tasks, tasks)
    |> assign(:current_page, current_page)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:project_paths, TaskRegistry.get_unique_paths())
    |> assign(:filtered_tasks, tasks)
  end

  defp build_filters_from_assigns(socket) do
    [
      status: socket.assigns.status_filter,
      project_path: socket.assigns.project_filter,
      review_status: socket.assigns.review_status_filter,
      search: socket.assigns.search_query
    ]
  end

  defp animation_delay_class(idx) when idx <= 5, do: "animation-delay-#{div(idx, 1) * 100}"
  defp animation_delay_class(_), do: ""
end
