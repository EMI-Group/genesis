defmodule EvoDashWeb.DashboardLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.flash_group flash={@flash} />

    <div class="container mx-auto px-4 py-8">
      <.header>
        EvoGit Dashboard
        <:subtitle>
          Manage your evolutionary software development tasks
        </:subtitle>
        <:actions>
          <a href="https://github.com/your-repo/evogit" class="btn btn-sm btn-ghost" target="_blank">
            <.icon name="hero-document-text" class="size-4" />
            Docs
          </a>
        </:actions>
      </.header>

      <div class="tabs tabs-boxed mb-6">
        <button
          class={["tab", @selected_tab == :genesis && "tab-active"]}
          phx-click="set_tab"
          phx-value-tab="genesis"
        >
          <.icon name="hero-cube" class="size-4" />
          Genesis
        </button>
        <button
          class={["tab", @selected_tab == :evolve && "tab-active"]}
          phx-click="set_tab"
          phx-value-tab="evolve"
        >
          <.icon name="hero-arrow-path" class="size-4" />
          Evolve
        </button>
      </div>

      <%= if @selected_tab == :genesis do %>
        <EvoDashWeb.DashboardComponents.genesis_form
          path={@genesis_path}
          prompt={@genesis_prompt}
          mode={@genesis_mode}
          concurrency={@genesis_concurrency}
          retries={@genesis_retries}
        />
      <% else %>
        <EvoDashWeb.DashboardComponents.evolve_form
          path={@evolve_path}
          objective={@evolve_objective}
          mode={@evolve_mode}
          concurrency={@evolve_concurrency}
          retries={@evolve_retries}
        />
      <% end %>

      <div class="divider">Running & Recent Tasks</div>

      <div class="space-y-4">
        <%= if @tasks == [] do %>
          <div class="text-center py-12 text-base-content/50">
            <.icon name="hero-inbox" class="size-16 mx-auto mb-4" />
            <p>No tasks yet. Start by creating a new Genesis or Evolve task.</p>
          </div>
        <% else %>
          <%= for task <- Enum.sort_by(@tasks, & &1.started_at, :desc) do %>
            <EvoDashWeb.DashboardComponents.task_card task={task} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :refresh_tasks)
    end

    socket =
      socket
      |> assign(:tasks, TaskRegistry.list_tasks())
      |> assign(:selected_tab, :genesis)
      |> assign_form_defaults()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_tab = case params["tab"] do
      "evolve" -> :evolve
      "genesis" -> :genesis
      _ -> :genesis
    end

    {:noreply, assign(socket, selected_tab: selected_tab)}
  end

  @impl true
  def handle_info(:refresh_tasks, socket) do
    {:noreply, assign(socket, :tasks, TaskRegistry.list_tasks())}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?tab=#{tab}")}
  end

  @impl true
  def handle_event("genesis_submit", %{"path" => path, "prompt" => prompt, "mode" => mode, "concurrency" => concurrency, "retries" => retries}, socket) do
    opts = [
      path: path,
      prompt: prompt,
      mode: mode,
      concurrency: String.to_integer(concurrency),
      retries: String.to_integer(retries)
    ]

    case TaskRegistry.start_task(:genesis, opts) do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Genesis task started with ID: #{task.id}")
         |> assign(:tasks, TaskRegistry.list_tasks())
         |> assign(:genesis_prompt, "")
         |> assign(:genesis_mode, "new")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("evolve_submit", %{"path" => path, "objective" => objective, "mode" => mode, "concurrency" => concurrency, "retries" => retries}, socket) do
    opts = [
      path: path,
      objective: objective,
      mode: mode,
      concurrency: String.to_integer(concurrency),
      retries: String.to_integer(retries)
    ]

    case TaskRegistry.start_task(:evolve, opts) do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Evolve task started with ID: #{task.id}")
         |> assign(:tasks, TaskRegistry.list_tasks())
         |> assign(:evolve_objective, "")
         |> assign(:evolve_mode, "simple")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        {:noreply, assign(socket, :tasks, TaskRegistry.list_tasks())}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_task_details", %{"task_id" => task_id}, socket) do
    tasks = Enum.map(socket.assigns.tasks, fn task ->
      if task.id == task_id do
        Map.update(task, :show_details, false, &(!&1))
      else
        Map.put(task, :show_details, false)
      end
    end)

    {:noreply, assign(socket, tasks: tasks)}
  end

  @impl true
  def handle_event("browse_path", _params, socket) do
    # In a real app, you might open a file dialog or show a directory picker
    {:noreply, socket}
  end

  defp assign_form_defaults(socket) do
    socket
    |> assign(:genesis_path, File.cwd!())
    |> assign(:genesis_prompt, "")
    |> assign(:genesis_mode, "new")
    |> assign(:genesis_concurrency, "3")
    |> assign(:genesis_retries, "3")
    |> assign(:evolve_path, File.cwd!())
    |> assign(:evolve_objective, "")
    |> assign(:evolve_mode, "simple")
    |> assign(:evolve_concurrency, "3")
    |> assign(:evolve_retries, "3")
  end
end
