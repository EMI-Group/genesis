defmodule EvoDashWeb.DashboardLive do
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.flash_group flash={@flash} />

    <div class="container mx-auto px-4 py-8 max-w-6xl">
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

    <!-- Full Result Modal -->
    <%= if @selected_result do %>
      <div class="modal modal-open bg-black/50">
        <div class="modal-box w-11/12 max-w-5xl">
          <%= case @selected_result do %>
            <% {:ok, %{result: result, no_changes: true}} when is_binary(result) -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-information-circle" class="size-5 text-warning" />
                No Changes
              </h3>
              <div class="bg-warning/10 border border-warning/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <p class="text-sm text-warning">The agent completed without making any changes to the codebase.</p>
              </div>
              <div class="mt-4 bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <h4 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide">Agent Message</h4>
                <pre class="text-sm whitespace-pre-wrap break-words"><%= result %></pre>
              </div>

            <% {:ok, %{result: result, branch_name: branch_name} = data} when is_binary(result) -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="flex flex-wrap gap-2 mb-4">
                <%= if branch_name do %>
                  <span class="badge badge-primary font-mono text-sm">
                    <.icon name="hero-code-bracket-square" class="size-4 mr-1" />
                    <%= branch_name %>
                  </span>
                <% end %>
                <%= if Map.get(data, :pr_url) do %>
                  <a href={Map.get(data, :pr_url)} target="_blank" class="badge badge-success font-mono text-sm hover:opacity-80 transition-opacity">
                    <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-1" />
                    View PR
                  </a>
                <% end %>
              </div>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= result %></pre>
              </div>

            <% {%{result: result}} when is_binary(result) -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= result %></pre>
              </div>

            <% {:error, reason} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-x-circle" class="size-5 text-error" />
                Task Failed
              </h3>
              <div class="bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm text-error whitespace-pre-wrap break-words"><%= inspect(reason, limit: :infinity) %></pre>
              </div>

            <% {:exit, reason} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-x-circle" class="size-5 text-error" />
                Task Crashed
              </h3>
              <div class="bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm text-error whitespace-pre-wrap break-words"><%= inspect(reason, limit: :infinity) %></pre>
              </div>

            <% {:ok, %{result: result}} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= inspect(result, limit: :infinity) %></pre>
              </div>

            <% %{result: result} -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                Agent Message
              </h3>
              <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm whitespace-pre-wrap break-words"><%= inspect(result, limit: :infinity) %></pre>
              </div>

            <% _ -> %>
              <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
                <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
                Result
              </h3>
              <div class="bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
                <pre class="text-sm overflow-x-auto"><%= inspect(@selected_result, pretty: true, limit: :infinity) %></pre>
              </div>
          <% end %>

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
      |> assign(:selected_result, nil)
      |> assign(:selected_options, nil)
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
