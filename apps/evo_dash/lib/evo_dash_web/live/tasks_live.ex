defmodule EvoDashWeb.TasksLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:tasks} config_status={@config_status}>
      <!-- Page Header -->
      <div class="flex items-center justify-between mb-6 animate-fade-in-up">
        <div class="flex items-center gap-3">
          <div class="bg-accent/15 text-accent p-3 rounded-xl">
            <.icon name="hero-clipboard-document-list" class="size-6" />
          </div>
          <div>
            <h1 class="text-xl font-bold">Task History</h1>
            <p class="text-sm text-base-content/60">View and manage all tasks across projects</p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/"} class="btn btn-sm btn-ghost gap-2">
            <.icon name="hero-arrow-left" class="size-4" /> Dashboard
          </.link>
        </div>
      </div>

      <!-- Filter Bar -->
      <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 p-4 sm:p-5 mb-6 animate-fade-in-up animation-delay-100">
        <div class="flex flex-col sm:flex-row gap-3">
          <!-- Status Filter -->
          <div class="form-control">
            <select
              name="status_filter"
              class="select select-bordered select-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
              phx-change="filter_tasks"
            >
              <option value="all" selected={@status_filter == "all"}>All Statuses</option>
              <option value="running" selected={@status_filter == "running"}>Running</option>
              <option value="pending" selected={@status_filter == "pending"}>Pending</option>
              <option value="completed" selected={@status_filter == "completed"}>Completed</option>
              <option value="failed" selected={@status_filter == "failed"}>Failed</option>
              <option value="cancelled" selected={@status_filter == "cancelled"}>Cancelled</option>
            </select>
          </div>

          <!-- Project Filter -->
          <div class="form-control">
            <select
              name="project_filter"
              class="select select-bordered select-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
              phx-change="filter_tasks"
            >
              <option value="all" selected={@project_filter == "all"}>All Projects</option>
              <%= for path <- @project_paths do %>
                <option value={path} selected={@project_filter == path}>
                  <%= Path.basename(path) %> (<%= String.slice(path, 0, 30) %>...)
                </option>
              <% end %>
            </select>
          </div>

          <!-- Search -->
          <div class="form-control flex-1">
            <input
              type="text"
              name="search_query"
              value={@search_query}
              class="input input-bordered input-sm w-full focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
              placeholder="Search by task ID, prompt, or objective..."
              phx-change="search_tasks"
              phx-debounce="200"
            />
          </div>

          <!-- Actions -->
          <div class="flex items-center gap-2 shrink-0">
            <button
              class="btn btn-sm btn-ghost"
              phx-click="reset_filters"
              title="Reset all filters"
            >
              <.icon name="hero-x-mark" class="size-4" /> Reset
            </button>
            <button
              class="btn btn-sm btn-outline btn-error"
              phx-click="clear_task_history"
              phx-confirm="Clear all finished task history? This cannot be undone."
            >
              <.icon name="hero-trash" class="size-4" /> Clear History
            </button>
          </div>
        </div>

        <!-- Active filters indicator -->
        <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" do %>
          <div class="flex items-center gap-2 mt-3 pt-3 border-t border-base-200/50">
            <span class="text-xs text-base-content/50">Active filters:</span>
            <%= if @status_filter != "all" do %>
              <span class="badge badge-primary badge-sm gap-1">
                {@status_filter}
                <button phx-click="clear_filter" phx-value-filter="status" class="hover:opacity-70">×</button>
              </span>
            <% end %>
            <%= if @project_filter != "all" do %>
              <span class="badge badge-secondary badge-sm gap-1">
                {Path.basename(@project_filter)}
                <button phx-click="clear_filter" phx-value-filter="project" class="hover:opacity-70">×</button>
              </span>
            <% end %>
            <%= if @search_query != "" do %>
              <span class="badge badge-accent badge-sm gap-1">
                "{String.slice(@search_query, 0, 20)}{if String.length(@search_query) > 20, do: "..."}"
                <button phx-click="clear_filter" phx-value-filter="search" class="hover:opacity-70">×</button>
              </span>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Task Count -->
      <div class="flex items-center justify-between mb-4">
        <p class="text-sm text-base-content/60">
          {length(@filtered_tasks)} task<%= if length(@filtered_tasks) != 1, do: "s" %> found
        </p>
      </div>

      <!-- Task List -->
      <div class="space-y-3">
        <%= if @filtered_tasks == [] do %>
          <div class="text-center py-12 sm:py-16 text-base-content/50 animate-fade-in-up">
            <div class="animate-float">
              <.icon name="hero-inbox" class="size-16 mx-auto mb-4 opacity-50" />
            </div>
            <p class="text-lg font-medium">No tasks found</p>
            <p class="text-sm mt-1">
              <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" do %>
                Try adjusting your filters or search query.
              <% else %>
                Tasks will appear here once you start them from the dashboard.
              <% end %>
            </p>
          </div>
        <% else %>
          <%= for {task, idx} <- Enum.with_index(@filtered_tasks) do %>
            <div class="animate-fade-in-up <%= if idx > 0, do: animation_delay_class(idx) %>">
              <EvoDashWeb.DashboardComponents.task_card
                task={task}
                show_details={MapSet.member?(@expanded_task_ids, task.id)}
              />
            </div>
          <% end %>
        <% end %>
      </div>

      <!-- Full Result Modal -->
      <%= if @selected_result do %>
        <div class="modal modal-open bg-black/50">
          <div class="modal-box w-11/12 max-w-5xl">
            <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
              <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
              Task Result
            </h3>
            <div class="bg-base-200 p-4 rounded-lg overflow-x-auto max-h-[70vh] overflow-y-auto">
              {EvoDashWeb.DashboardComponents.render_result_full(@selected_result)}
            </div>
            <div class="modal-action">
              <button class="btn" phx-click="close_result_modal">Close</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_result_modal">
            <button class="cursor-default">close</button>
          </div>
        </div>
      <% end %>

      <!-- Full Options Modal -->
      <%= if @selected_options do %>
        <div class="modal modal-open bg-black/50">
          <div class="modal-box w-11/12 max-w-5xl">
            <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5 text-primary" />
              Full Objective
            </h3>
            <div class="bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
              <pre class="text-sm whitespace-pre-wrap break-words"><%= @selected_options %></pre>
            </div>
            <div class="modal-action">
              <button class="btn" phx-click="close_options_modal">Close</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_options_modal">
            <button class="cursor-default">close</button>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :refresh_tasks)
    end

    tasks = TaskRegistry.list_tasks()
    project_paths = TaskRegistry.get_unique_paths()

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    socket =
      socket
      |> assign(:tasks, tasks)
      |> assign(:project_paths, project_paths)
      |> assign(:status_filter, "all")
      |> assign(:project_filter, "all")
      |> assign(:search_query, "")
      |> assign(:expanded_task_ids, MapSet.new())
      |> assign(:selected_result, nil)
      |> assign(:selected_options, nil)
      |> assign(:config_status, config_status)
      |> assign_filtered_tasks()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_tasks, socket) do
    tasks = TaskRegistry.list_tasks()
    project_paths = TaskRegistry.get_unique_paths()

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:project_paths, project_paths)
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("filter_tasks", params, socket) do
    status_filter = params["status_filter"] || socket.assigns.status_filter
    project_filter = params["project_filter"] || socket.assigns.project_filter

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> assign(:project_filter, project_filter)
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("search_tasks", %{"search_query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("reset_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, "all")
     |> assign(:project_filter, "all")
     |> assign(:search_query, "")
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "status"}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, "all")
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "project"}, socket) do
    {:noreply,
     socket
     |> assign(:project_filter, "all")
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "search"}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign_filtered_tasks()}
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    TaskRegistry.clear_finished_tasks()
    tasks = TaskRegistry.list_tasks()

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:expanded_task_ids, MapSet.new())
     |> assign_filtered_tasks()}
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
    task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
    result = Map.get(task || %{}, :result)
    {:noreply, assign(socket, :selected_result, result)}
  end

  @impl true
  def handle_event("close_result_modal", _params, socket) do
    {:noreply, assign(socket, :selected_result, nil)}
  end

  @impl true
  def handle_event("view_full_options", %{"task_id" => task_id}, socket) do
    task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
    opts = Map.get(task || %{}, :opts, [])
    primary_text = opts[:prompt] || opts[:objective] || ""
    {:noreply, assign(socket, :selected_options, primary_text)}
  end

  @impl true
  def handle_event("close_options_modal", _params, socket) do
    {:noreply, assign(socket, :selected_options, nil)}
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)
        tasks = TaskRegistry.list_tasks()

        {:noreply,
         socket
         |> assign(:tasks, tasks)
         |> assign(:expanded_task_ids, expanded)
         |> assign_filtered_tasks()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)
    tasks = TaskRegistry.list_tasks()

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:expanded_task_ids, expanded)
     |> assign_filtered_tasks()}
  end

  # Helpers

  defp assign_filtered_tasks(socket) do
    filtered =
      socket.assigns.tasks
      |> filter_by_status(socket.assigns.status_filter)
      |> filter_by_project(socket.assigns.project_filter)
      |> filter_by_search(socket.assigns.search_query)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    assign(socket, :filtered_tasks, filtered)
  end

  defp filter_by_status(tasks, "all"), do: tasks
  defp filter_by_status(tasks, status) when is_binary(status) do
    status_atom = String.to_existing_atom(status)
    Enum.filter(tasks, &(&1.status == status_atom))
  end
  defp filter_by_status(tasks, _), do: tasks

  defp filter_by_project(tasks, "all"), do: tasks
  defp filter_by_project(tasks, path) when is_binary(path) do
    Enum.filter(tasks, fn task ->
      task.opts[:path] == path
    end)
  end
  defp filter_by_project(tasks, _), do: tasks

  defp filter_by_search(tasks, ""), do: tasks
  defp filter_by_search(tasks, query) when is_binary(query) do
    query_lower = String.downcase(query)

    Enum.filter(tasks, fn task ->
      String.contains?(String.downcase(task.id), query_lower) or
        String.contains?(
          String.downcase(task.opts[:prompt] || task.opts[:objective] || ""),
          query_lower
        )
    end)
  end
  defp filter_by_search(tasks, _), do: tasks

  defp animation_delay_class(idx) when idx <= 5, do: "animation-delay-#{div(idx, 1) * 100}"
  defp animation_delay_class(_), do: ""
end
