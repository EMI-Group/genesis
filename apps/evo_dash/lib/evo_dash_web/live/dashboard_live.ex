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
          <a href="/agents" class="btn btn-sm btn-ghost">
            <.icon name="hero-server" class="size-4" /> Agents
          </a>
          <a href="https://github.com/your-repo/evogit" class="btn btn-sm btn-ghost" target="_blank">
            <.icon name="hero-document-text" class="size-4" /> Docs
          </a>
        </:actions>
      </.header>

      <div class="mt-6 mb-8">
        <EvoDashWeb.DashboardComponents.task_form
          path={@task_path}
          prompt={@task_prompt}
          mode={@task_mode}
          concurrency={@task_concurrency}
          retries={@task_retries}
          agent_max_retries={@task_agent_max_retries}
        />
      </div>

      <div class="divider">Running & Recent Tasks</div>

      <div class="space-y-4">
        <%= if @tasks == [] do %>
          <div class="text-center py-12 text-base-content/50">
            <.icon name="hero-inbox" class="size-16 mx-auto mb-4" />
            <p>No tasks yet. Start by creating a new Genesis or Evolve task.</p>
          </div>
        <% else %>
          <%= for task <- Enum.sort_by(@tasks, & &1.started_at, :desc) do %>
            <EvoDashWeb.DashboardComponents.task_card
              task={task}
              show_details={MapSet.member?(@expanded_task_ids, task.id)}
            />
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

    tasks = TaskRegistry.list_tasks()

    socket =
      socket
      |> assign(:tasks, tasks)
      |> assign(:expanded_task_ids, MapSet.new())
      |> assign_form_defaults()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_tasks, socket) do
    new_tasks = TaskRegistry.list_tasks()
    {:noreply, assign(socket, :tasks, new_tasks)}
  end

  @impl true
  def handle_event("task_change", params, socket) do
    {:noreply,
     socket
     |> assign(:task_mode, params["mode"] || socket.assigns.task_mode)
     |> assign(:task_prompt, params["prompt"] || socket.assigns.task_prompt)
     |> assign(:task_path, params["path"] || socket.assigns.task_path)
     |> assign(:task_concurrency, params["concurrency"] || socket.assigns.task_concurrency)
     |> assign(:task_retries, params["retries"] || socket.assigns.task_retries)
     |> assign(:task_agent_max_retries, params["agent_max_retries"] || socket.assigns.task_agent_max_retries)}
  end

  @impl true
  def handle_event(
        "task_submit",
        %{
          "path" => path,
          "prompt" => prompt,
          "mode" => combined_mode,
          "concurrency" => concurrency,
          "retries" => retries,
          "agent_max_retries" => agent_max_retries
        },
        socket
      ) do
    {task_type, mode} =
      case combined_mode do
        "genesis_new" -> {:genesis, "new"}
        "genesis_existing" -> {:genesis, "existing"}
        "evolve_simple" -> {:evolve, "simple"}
        "evolve_complex" -> {:evolve, "complex"}
      end

    opts = [
      path: path,
      mode: mode,
      concurrency: String.to_integer(concurrency),
      retries: String.to_integer(retries),
      agent_max_retries: String.to_integer(agent_max_retries)
    ]

    opts =
      if task_type == :genesis do
        Keyword.put(opts, :prompt, prompt)
      else
        Keyword.put(opts, :objective, prompt)
      end

    case TaskRegistry.start_task(task_type, opts) do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{String.capitalize(to_string(task_type))} task started with ID: #{task.id}")
         |> assign(:tasks, TaskRegistry.list_tasks())
         |> assign(:task_path, path)
         |> assign(:task_prompt, prompt)
         |> assign(:task_mode, combined_mode)
         |> assign(:task_concurrency, concurrency)
         |> assign(:task_retries, retries)
         |> assign(:task_agent_max_retries, agent_max_retries)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start task: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_task", %{"task_id" => task_id}, socket) do
    case TaskRegistry.cancel_task(task_id) do
      :ok ->
        expanded = MapSet.delete(socket.assigns.expanded_task_ids, task_id)

        {:noreply,
         socket
         |> assign(:tasks, TaskRegistry.list_tasks())
         |> assign(:expanded_task_ids, expanded)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel task: #{inspect(reason)}")}
    end
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

  defp assign_form_defaults(socket) do
    socket
    |> assign(:task_path, File.cwd!())
    |> assign(:task_prompt, "")
    |> assign(:task_mode, "genesis_new")
    |> assign(:task_concurrency, to_string(EvoGit.Defaults.max_concurrency()))
    |> assign(:task_retries, to_string(EvoGit.Defaults.max_retries()))
    |> assign(:task_agent_max_retries, to_string(EvoGit.Defaults.agent_max_retries()))
  end
end
