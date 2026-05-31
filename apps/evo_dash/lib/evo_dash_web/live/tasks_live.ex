defmodule EvoDashWeb.TasksLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:tasks} config_status={@config_status}>
      <div class="animate-fade-in">
        <!-- Page Header -->
        <div class="flex items-center justify-between mb-6">
          <div class="flex items-center gap-3">
            <div class="bg-info/15 text-info p-3 rounded-xl">
              <.icon name="hero-clipboard-document-list" class="size-6" />
            </div>
            <div>
              <h1 class="text-xl font-bold">All Tasks</h1>
              <p class="text-sm text-base-content/60">
                <%= if @active_project do %>
                  Tasks for {Map.get(@projects[@active_project] || %{}, :name, @active_project)}
                <% else %>
                  All projects
                <% end %>
                · {length(@tasks)} total
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/"} class="btn btn-sm btn-ghost gap-2 active:scale-[0.98] transition-transform">
              <.icon name="hero-arrow-left" class="size-4" /> Dashboard
            </.link>
            <details class="dropdown dropdown-end">
              <summary class="btn btn-sm btn-ghost btn-circle">
                <.icon name="hero-ellipsis-vertical" class="size-5" />
              </summary>
              <ul class="menu menu-sm dropdown-content mt-1 z-[1] p-2 shadow-lg bg-base-100 rounded-box w-48 border border-base-200">
                <li>
                  <button class="text-error" phx-click="clear_task_history" phx-confirm="Clear all finished task history? This cannot be undone.">
                    <.icon name="hero-trash" class="size-4" /> Clear History
                  </button>
                </li>
              </ul>
            </details>
          </div>
        </div>

        <!-- Task Groups -->
        <%= if @tasks == [] do %>
          <div class="text-center py-16 text-base-content/50">
            <.icon name="hero-inbox" class="size-16 mx-auto mb-4 opacity-40" />
            <p class="text-lg font-medium">No tasks yet</p>
            <p class="text-sm mt-1">Start by creating a new task from the dashboard.</p>
            <.link navigate={~p"/"} class="btn btn-primary btn-sm mt-4 gap-2">
              <.icon name="hero-arrow-left" class="size-4" /> Go to Dashboard
            </.link>
          </div>
        <% else %>
          <!-- Running/Pending Tasks -->
          <%= if @active_tasks != [] do %>
            <section class="mb-8">
              <div class="flex items-center gap-3 mb-4">
                <h2 class="text-base font-semibold flex items-center gap-2">
                  <.icon name="hero-bolt" class="size-5 text-info" /> Active
                </h2>
                <span class="badge badge-info badge-sm pulse-glow">{length(@active_tasks)}</span>
              </div>
              <div class="space-y-3">
                <%= for {task, idx} <- Enum.with_index(@active_tasks) do %>
                  <div style={"--stagger-delay: #{idx * 60}ms"} class="stagger-item">
                    <EvoDashWeb.DashboardComponents.task_card
                      task={task}
                      show_details={MapSet.member?(@expanded_task_ids, task.id)}
                    />
                  </div>
                <% end %>
              </div>
            </section>
          <% end %>

          <!-- Finished Tasks -->
          <%= if @finished_tasks != [] do %>
            <section>
              <div class="flex items-center gap-3 mb-4">
                <h2 class="text-base font-semibold flex items-center gap-2">
                  <.icon name="hero-clock" class="size-5 text-base-content/50" /> History
                </h2>
                <span class="text-xs text-base-content/40">{length(@finished_tasks)} tasks</span>
              </div>
              <div class="space-y-3">
                <%= for {task, idx} <- Enum.with_index(@finished_tasks) do %>
                  <div style={"--stagger-delay: #{idx * 40}ms"} class="stagger-item">
                    <EvoDashWeb.DashboardComponents.task_card
                      task={task}
                      show_details={MapSet.member?(@expanded_task_ids, task.id)}
                    />
                  </div>
                <% end %>
              </div>
            </section>
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
  def mount(params, session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :refresh_tasks)
    end

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    active_project = params["project"]
    tasks = load_tasks(active_project)

    socket =
      socket
      |> assign(:is_desktop, Map.get(session, "is_desktop", false))
      |> assign(:active_project, active_project)
      |> assign(:projects, %{})
      |> assign_tasks(tasks)
      |> assign(:expanded_task_ids, MapSet.new())
      |> assign(:selected_result, nil)
      |> assign(:selected_options, nil)
      |> assign(:config_status, config_status)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_tasks, socket) do
    tasks = load_tasks(socket.assigns.active_project)
    {:noreply, assign_tasks(socket, tasks)}
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
  def handle_event("clear_task_history", _params, socket) do
    TaskRegistry.clear_finished_tasks()
    tasks = load_tasks(socket.assigns.active_project)
    {:noreply, socket |> assign_tasks(tasks) |> assign(:expanded_task_ids, MapSet.new())}
  end

  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    TaskRegistry.delete_task(task_id)
    expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)
    tasks = load_tasks(socket.assigns.active_project)
    {:noreply, socket |> assign_tasks(tasks) |> assign(:expanded_task_ids, expanded)}
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)
        tasks = load_tasks(socket.assigns.active_project)
        {:noreply, socket |> assign_tasks(tasks) |> assign(:expanded_task_ids, expanded)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel task: #{inspect(reason)}")}
    end
  end

  # Helpers

  defp load_tasks(nil) do
    TaskRegistry.list_tasks()
  end

  defp load_tasks(project_path) when is_binary(project_path) do
    TaskRegistry.list_tasks_by_path(project_path)
  end

  defp load_tasks(_), do: TaskRegistry.list_tasks()

  defp assign_tasks(socket, tasks) do
    active = Enum.filter(tasks, &(&1.status in [:running, :pending]))
    finished = tasks
      |> Enum.reject(&(&1.status in [:running, :pending]))
      |> Enum.sort_by(&(&1.finished_at || &1.started_at), {:desc, DateTime})

    socket
    |> assign(:tasks, tasks)
    |> assign(:active_tasks, active)
    |> assign(:finished_tasks, finished)
  end
end
