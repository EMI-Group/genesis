defmodule EvoDashWeb.DashboardComponents do
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # task_form/1 — Modern card with gradient hero, better spacing
  # ---------------------------------------------------------------------------

  attr :prompt, :string, default: ""
  attr :mode, :string, default: "genesis_new"
  attr :mode_info, :string, default: ""
  attr :node_path, :string, default: ""
  attr :seeds, :string, default: ""

  def task_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-submit="task_submit"
      phx-change="task_change"
      class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden"
    >
      <!-- Hero Header with inline mode select -->
      <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent px-6 py-4 md:px-8 md:py-5">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 sm:gap-4">
          <div class="flex items-center gap-3">
            <div class="bg-primary/15 text-primary p-2.5 rounded-xl">
              <.icon name="hero-sparkles" class="size-5" />
            </div>
            <div>
              <h2 class="text-lg font-bold">Configure Task</h2>
              <p class="text-xs text-base-content/60">Bootstrap, analyze, or evolve your codebase</p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/60 whitespace-nowrap">Task Mode</span>
            <select
              name="mode"
              class="select select-bordered select-sm focus:outline-none focus:ring-2 focus:ring-primary/30 font-medium bg-base-200/30"
            >
              <optgroup label="Genesis (Bootstrap & Analyze)">
                <option value="genesis_new" selected={@mode == "genesis_new"}>New Codebase</option>
                <option value="genesis_existing" selected={@mode == "genesis_existing"}>Existing Codebase</option>
              </optgroup>
              <optgroup label="Evolve (Mutate Code)">
                <option value="evolve_simple" selected={@mode == "evolve_simple"}>Simple (Top-down)</option>
                <option value="evolve_complex" selected={@mode == "evolve_complex"}>Complex (Bottom-up)</option>
              </optgroup>
            </select>
          </div>
        </div>
      </div>

      <!-- Body -->
      <div class="p-6 md:p-8 pt-4 md:pt-6 space-y-4">
        <%= if String.starts_with?(@mode, "evolve") do %>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-base-content">Starting Node</span>
            </label>
            <input
              type="text"
              name="node_path"
              value={@node_path}
              class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
              placeholder="e.g., ./src/components"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">Subdirectory to start evolution from (optional)</span>
            </label>
          </div>
        <% end %>
        <%= if @mode == "evolve_complex" do %>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-base-content">Seed Code <span class="badge badge-ghost">optional</span></span>
            </label>
            <textarea
              name="seeds"
              class="textarea textarea-bordered w-full min-h-[120px] text-sm font-mono leading-relaxed focus:outline-none focus:ring-2 focus:ring-primary/30 resize-y bg-base-200/30"
              placeholder="Paste seed code here. Separate multiple fragments with blank lines..."
            ><%= @seeds %></textarea>
            <label class="label">
              <span class="label-text-alt text-base-content/50">User seeds are preferred over built-in seeds during evolution</span>
            </label>
          </div>
        <% end %>
        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold text-base-content">Prompt / Objective</span>
          </label>
          <textarea
            name="prompt"
            class="textarea textarea-bordered w-full min-h-[160px] sm:min-h-[240px] text-base leading-relaxed focus:outline-none focus:ring-2 focus:ring-primary/30 resize-y bg-base-200/30"
            placeholder="Describe the software you want to create or the change you want to make..."
          ><%= @prompt %></textarea>
        </div>
      </div>

      <!-- Footer action bar -->
      <div class="bg-base-200/50 px-6 py-4 md:px-8 border-t border-base-200 flex flex-col sm:flex-row items-center justify-between gap-4">
        <span class="text-sm text-base-content/60 flex items-center gap-2">
          <.icon name="hero-light-bulb" class="size-5 text-warning" />
          Ready to execute. Mode was auto-detected based on project state.
        </span>
        <button
          type="submit"
          class="btn btn-primary px-8 h-12 text-base shadow-md hover:shadow-lg transition-all w-full sm:w-auto"
        >
          <.icon name="hero-rocket-launch" class="size-5" /> Execute Task
        </button>
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # scheduler_settings/1 — Runtime scheduler configuration panel
  # ---------------------------------------------------------------------------

  attr :config, :map, required: true

  def scheduler_settings(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
      <div class="bg-gradient-to-br from-secondary/10 via-secondary/5 to-transparent p-6 md:p-8">
        <div class="flex items-center gap-3">
          <div class="bg-secondary/15 text-secondary p-3 rounded-xl">
            <.icon name="hero-cog-6-tooth" class="size-6" />
          </div>
          <div>
            <h2 class="text-xl font-bold">Scheduler Settings</h2>
            <p class="text-sm text-base-content/60">Runtime configuration for agent execution</p>
          </div>
        </div>
      </div>
      <div class="p-6 md:p-8 pt-4 md:pt-6">
        <.form for={%{}} phx-submit="update_scheduler_config" phx-change="scheduler_config_change" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 md:gap-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">LLM Concurrency</span>
              </label>
              <input type="number" name="max_concurrency" value={@config[:max_concurrency]} min="1" max="100"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">Max parallel LLM calls</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">Tool Concurrency</span>
              </label>
              <input type="number" name="max_tool_concurrency" value={@config[:max_tool_concurrency]} min="1" max="100"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">Max parallel tool executions</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">Agent Max Retries</span>
              </label>
              <input type="number" name="agent_max_retries" value={@config[:agent_max_retries]} min="0" max="20"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">Crash-retries per agent</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">Max Depth</span>
              </label>
              <input type="number" name="max_agent_depth" value={@config[:max_agent_depth]} min="1" max="20"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">Max subagent recursion</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">LLM Retries</span>
              </label>
              <input type="number" name="max_retries" value={@config[:max_retries]} min="1" max="100"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">API call retries</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">LLM Model</span>
              </label>
              <input type="text" name="llm_model" value={@config[:llm_model] || ""} 
                class="input input-bordered input-sm w-full font-mono" placeholder="Configure in config.toml" />
              <label class="label"><span class="label-text-alt text-base-content/50">Model identifier</span></label>
            </div>
          </div>
          <div class="pt-2">
            <button type="submit" class="btn btn-secondary">
              <.icon name="hero-arrow-path" class="size-4" /> Update Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # project_tabs/1 — Pill-shaped tabs with smooth transitions
  # ---------------------------------------------------------------------------

  attr :projects, :map, required: true
  attr :active_project, :string, default: nil

  def project_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-2 overflow-x-auto pb-1 scrollbar-thin">
      <%= for {_path, project} <- @projects do %>
        <div class="flex items-center">
          <button
            phx-click="switch_project"
            phx-value-path={project.path}
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium cursor-pointer transition-all whitespace-nowrap hover-lift",
              @active_project == project.path && "bg-primary text-primary-content shadow-md",
              @active_project != project.path &&
                "bg-base-200/70 hover:bg-base-300 text-base-content/70 hover:text-base-content"
            ]}
          >
            <.icon name="hero-folder" class="size-4" />
            {project.name}
          </button>
          <button
            phx-click="close_project"
            phx-value-path={project.path}
            class={[
              "-ml-1 flex items-center justify-center w-6 h-6 rounded-full transition-all",
              @active_project == project.path &&
                "text-primary-content/70 hover:text-primary-content hover:bg-primary-content/20",
              @active_project != project.path &&
                "text-base-content/30 hover:text-error hover:bg-error/10"
            ]}
            title="Close project"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      <% end %>
      <!-- Add project button -->
      <button
        class="flex items-center justify-center w-8 h-8 rounded-full bg-base-200/50 hover:bg-base-300 text-base-content/50 hover:text-primary transition-all"
        phx-click="show_open_project"
        title="Open Project"
      >
        <.icon name="hero-plus" class="size-4" />
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # open_project_form/1 — Gradient hero, autocomplete, recent projects
  # ---------------------------------------------------------------------------

  attr :path, :string, default: ""
  attr :recent_projects, :list, default: []
  attr :path_suggestions, :list, default: []

  def open_project_form(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
        <!-- Hero section -->
        <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent p-6 sm:p-8 text-center">
          <div class="bg-primary/15 text-primary p-4 rounded-2xl w-fit mx-auto mb-4">
            <.icon name="hero-folder-open" class="size-10" />
          </div>
          <h2 class="text-2xl font-bold">Open a Project</h2>
          <p class="text-base-content/60 mt-2">Enter the path to a Git repository to get started</p>
        </div>

        <!-- Form -->
        <div class="p-4 sm:p-6 pt-2">
          <.form for={%{}} phx-submit="open_project" class="space-y-4">
            <div class="form-control relative">
              <div class="relative">
                <div class="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none text-base-content/40">
                  <.icon name="hero-folder" class="size-5" />
                </div>
                <input
                  type="text"
                  name="path"
                  value={@path}
                  class="input input-bordered w-full pl-11 pr-12 h-12 focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono text-sm bg-base-200/50"
                  placeholder="/path/to/your/repo"
                  autofocus
                  phx-hook="PathAutocomplete"
                  phx-change="path_input"
                  phx-debounce="150"
                  id="initial-project-path-input"
                  list="path-suggestions"
                />
                <button
                  type="button"
                  id="project-path-picker-button"
                  class="absolute right-10 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-primary transition-colors"
                  phx-click="pick_directory"
                  phx-hook="DirectoryPicker"
                  title="Browse for directory"
                >
                  <.icon name="hero-folder-open" class="size-5" />
                </button>
                <datalist id="path-suggestions">
                  <%= for suggestion <- @path_suggestions do %>
                    <option value={suggestion}></option>
                  <% end %>
                </datalist>
              </div>
            </div>
            <button type="submit" class="btn btn-primary w-full h-12 text-base">
              <.icon name="hero-folder-open" class="size-5" /> Open Project
            </button>
          </.form>

          <!-- Recent Projects -->
          <%= if @recent_projects != [] do %>
            <div class="mt-6">
              <h3 class="text-sm font-semibold text-base-content/50 uppercase tracking-wider mb-3">
                Recent Projects
              </h3>
              <div class="space-y-1">
                <%= for project <- Enum.take(@recent_projects, 5) do %>
                  <button
                    class="w-full flex items-center gap-3 p-3 rounded-xl hover:bg-base-200/70 transition-colors text-left group"
                    phx-click="open_project"
                    phx-value-path={project.path}
                  >
                    <div class="bg-base-200 p-2 rounded-lg group-hover:bg-base-300 transition-colors">
                      <.icon name="hero-folder" class="size-4 text-base-content/60" />
                    </div>
                    <div class="flex-1 min-w-0">
                      <p class="font-medium text-sm truncate">{project.name}</p>
                      <p class="text-xs text-base-content/40 font-mono truncate">{project.path}</p>
                    </div>
                    <.icon
                      name="hero-chevron-right"
                      class="size-4 text-base-content/30 group-hover:text-base-content/60 transition-colors"
                    />
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # task_card/1 — Compact card with accent bar, relative timestamps
  # ---------------------------------------------------------------------------

  attr :task, :map, required: true
  attr :show_details, :boolean, default: false

  def task_card(assigns) do
    ~H"""
    <div class={[
      "bg-base-100 rounded-2xl shadow-sm border border-base-200 hover:shadow-md transition-all duration-200 overflow-hidden relative hover-lift",
      @task.status == :completed && "bg-success/5",
      @task.status == :running && "bg-info/5"
    ]}>
      <!-- Three-dot kebab menu -->
      <details class="dropdown dropdown-end absolute top-3 right-3 z-[1]">
        <summary class="btn btn-sm btn-ghost btn-circle">
          <.icon name="hero-ellipsis-vertical" class="size-4" />
        </summary>
        <ul class="menu menu-sm dropdown-content mt-1 z-[1] p-2 shadow-lg bg-base-100 rounded-box w-40 border border-base-200">
          <li>
            <button class="text-error" phx-click="delete_task" phx-value-task_id={@task.id} phx-confirm="Delete this task?">
              <.icon name="hero-trash" class="size-4" /> Delete
            </button>
          </li>
        </ul>
      </details>

      <div class="flex">
        <!-- Left accent bar -->
        <div class={["w-1 shrink-0", status_accent_color(@task.status)]}></div>

        <div class="flex-1 p-4 md:p-5">
          <!-- Compact header — single row: type · mode | status · short ID -->
          <div class="flex items-center justify-between gap-3 mb-2 pr-7">
            <div class="flex items-center gap-1 text-xs text-base-content/60 min-w-0">
              <span class="capitalize font-medium text-base-content/80">{@task.type}</span>
              <span class="text-base-content/30">·</span>
              <span class="font-mono">{@task.opts[:mode]}</span>
            </div>
            <div class="flex items-center gap-1 shrink-0">
              <span class={task_status_badge(@task.status)}>
                <%= if @task.status == :running do %>
                  <span class="relative flex h-2 w-2 mr-1.5">
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-info opacity-75"></span>
                    <span class="relative inline-flex rounded-full h-2 w-2 bg-info"></span>
                  </span>
                <% end %>
                {@task.status}
              </span>
              <span class="text-xs text-base-content/30">·</span>
              <span class="text-xs font-mono text-base-content/40">
                {String.slice(@task.id, 0, 8)}
              </span>
            </div>
          </div>

          <!-- Objective with line-clamp-1 + HTML tooltip -->
          <% objective_text = @task.opts[:prompt] || @task.opts[:objective] || "" %>
          <%= if objective_text != "" do %>
            <p class="text-sm text-base-content/80 leading-relaxed line-clamp-1" title={objective_text}>
              {objective_text}
            </p>
          <% else %>
            <p class="text-sm text-base-content/80 leading-relaxed line-clamp-1" title={task_description(@task)}>
              {task_description(@task)}
            </p>
          <% end %>

          <!-- Compact footer — single row: relative timestamps | actions -->
          <div class="flex items-center justify-between gap-3 mt-2 pt-2 border-t border-base-200/50">
            <div class="flex items-center gap-1 text-xs text-base-content/50 min-w-0">
              <span class="flex items-center gap-1 shrink-0">
                Started {relative_time(@task.started_at)}
              </span>
              <%= if Map.get(@task, :finished_at) do %>
                <span class="text-base-content/30">·</span>
                <span class="flex items-center gap-1 shrink-0">
                  Finished {relative_time(@task.finished_at)}
                </span>
              <% end %>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <%= if @task.status == :running do %>
                <button
                  class="btn btn-outline btn-error shadow-sm"
                  phx-click="cancel_task"
                  phx-value-task_id={@task.id}
                  phx-confirm="Are you sure you want to cancel this task?"
                >
                  <.icon name="hero-x-mark" class="size-4" /> Cancel
                </button>
              <% end %>
              <button
                class="btn btn-ghost bg-base-200/50 hover:bg-base-200"
                phx-click="toggle_task_details"
                phx-value-task_id={@task.id}
              >
                <%= if @show_details do %>
                  Hide Details <.icon name="hero-chevron-up" class="size-4 ml-1" />
                <% else %>
                  View Details <.icon name="hero-chevron-down" class="size-4 ml-1" />
                <% end %>
              </button>
            </div>
          </div>

          <%= if @show_details do %>
            <div class="border-t border-base-200 pt-3 mt-3">
              <div class="space-y-3">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3 md:gap-4">
                  <div class="bg-base-200/20 p-4 rounded-xl border border-base-200/60">
                    <div class="flex items-center justify-between mb-3">
                      <h4 class="text-sm font-bold flex items-center gap-2">
                        <.icon name="hero-cog-8-tooth" class="size-4 text-primary" /> Options
                      </h4>
                      <button
                        class="btn btn-sm btn-ghost"
                        phx-click="view_full_options"
                        phx-value-task_id={@task.id}
                      >
                        <.icon name="hero-arrows-pointing-out" class="size-4" />
                        View Full
                      </button>
                    </div>
                    {render_options(@task.opts)}
                  </div>
                  <%= if Map.get(@task, :result) do %>
                    <div class="bg-base-200/20 p-4 rounded-xl border border-base-200/60">
                      <div class="flex items-center justify-between mb-3">
                        <h4 class="text-sm font-bold flex items-center gap-2">
                          <.icon name="hero-check-badge" class="size-4 text-success" /> Result
                        </h4>
                        <button
                          class="btn btn-sm btn-ghost"
                          phx-click="view_full_result"
                          phx-value-task_id={@task.id}
                        >
                          <.icon name="hero-arrows-pointing-out" class="size-4" />
                          View Full
                        </button>
                      </div>
                      {render_result(@task.result)}
                    </div>
                  <% end %>
                </div>
                <%= if @task.logs != [] do %>
                  <% log_count = length(@task.logs) %>
                  <details class="bg-base-200/20 p-4 rounded-xl border border-base-200/60">
                    <summary class="cursor-pointer text-sm font-bold flex items-center gap-2 select-none">
                      <.icon name="hero-command-line" class="size-4 text-base-content/70" />
                      Logs (<%= if log_count > 20, do: "last 20 of #{log_count}", else: "#{log_count} entries" %>)
                    </summary>
                    <div class="bg-base-300/50 p-3 rounded-lg max-h-64 overflow-y-auto text-xs font-mono space-y-px border border-base-300 shadow-inner mt-3">
                      <%= for {log, idx} <- Enum.with_index(Enum.reverse(@task.logs)) do %>
                        <div class={[
                          "flex items-start gap-2 p-1.5 rounded transition-colors",
                          rem(idx, 2) == 0 && "bg-base-200/30",
                          log.level == :error && "text-error bg-error/5",
                          log.level == :warn && "text-warning bg-warning/5"
                        ]}>
                          <span class="text-base-content/40 shrink-0">
                            [{format_datetime(log.timestamp, :time)}]
                          </span>
                          <span class={[
                            "font-bold shrink-0 w-12",
                            log.level == :error && "text-error",
                            log.level == :warn && "text-warning",
                            log.level == :info && "text-info"
                          ]}>
                            {String.upcase(to_string(log.level))}
                          </span>
                          <span class="break-words">
                            {log.message}
                          </span>
                        </div>
                      <% end %>
                    </div>
                  </details>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers — accent color for task_card status bar
  # ---------------------------------------------------------------------------

  defp status_accent_color(:running), do: "bg-info"
  defp status_accent_color(:completed), do: "bg-success"
  defp status_accent_color(:failed), do: "bg-error"
  defp status_accent_color(:cancelled), do: "bg-warning"
  defp status_accent_color(_), do: "bg-base-300"

  # ---------------------------------------------------------------------------
  # Public helpers — render_options/1
  # ---------------------------------------------------------------------------

  def render_options(opts) do
    primary_text = opts[:prompt] || opts[:objective] || ""
    mode = opts[:mode] || ""
    path = opts[:path] || ""

    assigns = %{
      primary_text: primary_text,
      mode: mode,
      path: path
    }

    ~H"""
    <div class="space-y-3">
      <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
        <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> Objective
        </h5>
        <div class="text-sm whitespace-pre-wrap break-words">
          {String.slice(@primary_text, 0, 300)}{if String.length(@primary_text) > 300, do: "..."}
        </div>
      </div>
      <div class="flex flex-wrap gap-2 text-xs">
        <%= if @mode != "" do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-cog-6-tooth" class="size-3 mr-1" />
            <%= @mode %>
          </span>
        <% end %>
        <%= if @path != "" do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-folder" class="size-3 mr-1" />
            <%= @path %>
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helpers — render_result/1
  # ---------------------------------------------------------------------------

  def render_result({:ok, %{result: result} = data}) when is_binary(result) do
    render_result(data)
  end

  def render_result({:error, reason}) do
    assigns = %{reason: inspect(reason, limit: 100)}

    ~H"""
    <div class="bg-error/10 border border-error/20 p-3 rounded-lg">
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> Error
      </h5>
      <pre class="text-xs text-error whitespace-pre-wrap break-words"><%= @reason %></pre>
    </div>
    """
  end

  def render_result({:exit, reason}) do
    assigns = %{reason: inspect(reason, limit: 100)}

    ~H"""
    <div class="bg-error/10 border border-error/20 p-3 rounded-lg">
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> Crashed
      </h5>
      <pre class="text-xs text-error whitespace-pre-wrap break-words"><%= @reason %></pre>
    </div>
    """
  end

  def render_result(%{result: result, no_changes: true} = _data) when is_binary(result) do
    assigns = %{result: result}

    ~H"""
    <div class="space-y-3">
      <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
        <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> Agent Message
        </h5>
        <div class="text-sm whitespace-pre-wrap break-words">
          {String.slice(@result, 0, 300)}{if String.length(@result) > 300, do: "..."}
        </div>
      </div>
      <div class="bg-warning/10 border border-warning/20 p-3 rounded-lg">
        <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-information-circle" class="size-3" /> No Changes
        </h5>
        <p class="text-sm text-warning">The agent completed without making any changes to the codebase.</p>
      </div>
    </div>
    """
  end

  def render_result(%{result: result, commit_sha: commit_sha} = data) when is_binary(result) do
    assigns = %{
      result: result,
      commit_sha: commit_sha,
      tag: Map.get(data, :tag),
      branch_name: Map.get(data, :branch_name),
      pr_url: Map.get(data, :pr_url)
    }

    ~H"""
    <div class="space-y-3">
      <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
        <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> Agent Message
        </h5>
        <div class="text-sm whitespace-pre-wrap break-words">
          {String.slice(@result, 0, 300)}{if String.length(@result) > 300, do: "..."}
        </div>
      </div>
      <div class="flex flex-wrap gap-2 text-xs">
        <%= if @commit_sha do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-code-bracket" class="size-3 mr-1" />
            <%= String.slice(@commit_sha, 0..7) %>
          </span>
        <% end %>
        <%= if @tag do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-tag" class="size-3 mr-1" />
            <%= @tag %>
          </span>
        <% end %>
        <%= if @branch_name do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-code-bracket-square" class="size-3 mr-1" />
            <%= @branch_name %>
          </span>
        <% end %>
        <%= if @pr_url do %>
          <a
            href={@pr_url}
            target="_blank"
            class="badge badge-success font-mono hover:opacity-80 transition-opacity"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3 mr-1" />
            View PR
          </a>
        <% end %>
      </div>
    </div>
    """
  end

  def render_result(result) do
    assigns = %{result: inspect(result, pretty: true)}

    ~H"""
    <pre class="text-xs bg-base-100 p-3 rounded-lg border border-base-200 overflow-x-auto shadow-inner"><%= @result %></pre>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helpers — render_options_full/1 (no truncation, for modal use)
  # ---------------------------------------------------------------------------

  def render_options_full(opts) do
    primary_text = opts[:prompt] || opts[:objective] || ""
    mode = opts[:mode] || ""
    path = opts[:path] || ""

    assigns = %{
      primary_text: primary_text,
      mode: mode,
      path: path
    }

    ~H"""
    <div class="space-y-3">
      <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
        <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> Objective
        </h5>
        <div class="text-sm whitespace-pre-wrap break-words">
          <%= @primary_text %>
        </div>
      </div>
      <div class="flex flex-wrap gap-2 text-xs">
        <%= if @mode != "" do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-cog-6-tooth" class="size-3 mr-1" />
            <%= @mode %>
          </span>
        <% end %>
        <%= if @path != "" do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-folder" class="size-3 mr-1" />
            <%= @path %>
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helpers — render_result_full/1 (no truncation, for modal use)
  # ---------------------------------------------------------------------------

  def render_result_full({:ok, %{result: result} = data}) when is_binary(result) do
    render_result_full(data)
  end

  def render_result_full({:error, reason}) do
    assigns = %{reason: inspect(reason)}

    ~H"""
    <div class="bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> Error
      </h5>
      <pre class="text-sm text-error whitespace-pre-wrap break-words"><%= @reason %></pre>
    </div>
    """
  end

  def render_result_full({:exit, reason}) do
    assigns = %{reason: inspect(reason)}

    ~H"""
    <div class="bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> Crashed
      </h5>
      <pre class="text-sm text-error whitespace-pre-wrap break-words"><%= @reason %></pre>
    </div>
    """
  end

  def render_result_full(%{result: result, no_changes: true} = _data) when is_binary(result) do
    assigns = %{result: result}

    ~H"""
    <div class="space-y-4">
      <div class="bg-warning/10 border border-warning/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
        <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-information-circle" class="size-3" /> No Changes
        </h5>
        <p class="text-sm text-warning">The agent completed without making any changes to the codebase.</p>
      </div>
      <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
        <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> Agent Message
        </h5>
        <pre class="text-sm whitespace-pre-wrap break-words"><%= @result %></pre>
      </div>
    </div>
    """
  end

  def render_result_full(%{result: result, commit_sha: commit_sha} = data) when is_binary(result) do
    assigns = %{
      result: result,
      commit_sha: commit_sha,
      tag: Map.get(data, :tag),
      branch_name: Map.get(data, :branch_name),
      pr_url: Map.get(data, :pr_url)
    }

    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap gap-2 mb-4">
        <%= if @branch_name do %>
          <span class="badge badge-primary font-mono text-sm">
            <.icon name="hero-code-bracket-square" class="size-4 mr-1" />
            <%= @branch_name %>
          </span>
        <% end %>
        <%= if @commit_sha do %>
          <span class="badge badge-ghost font-mono text-sm">
            <.icon name="hero-code-bracket" class="size-4 mr-1" />
            <%= String.slice(@commit_sha, 0..7) %>
          </span>
        <% end %>
        <%= if @tag do %>
          <span class="badge badge-ghost font-mono text-sm">
            <.icon name="hero-tag" class="size-4 mr-1" />
            <%= @tag %>
          </span>
        <% end %>
        <%= if @pr_url do %>
          <a
            href={@pr_url}
            target="_blank"
            class="badge badge-success font-mono text-sm hover:opacity-80 transition-opacity"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-1" />
            View PR
          </a>
        <% end %>
      </div>
      <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
        <pre class="text-sm whitespace-pre-wrap break-words"><%= @result %></pre>
      </div>
    </div>
    """
  end

  def render_result_full(%{result: result}) do
    assigns = %{result: inspect(result, limit: :infinity)}

    ~H"""
    <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
      <pre class="text-sm whitespace-pre-wrap break-words"><%= @result %></pre>
    </div>
    """
  end

  def render_result_full(result) do
    assigns = %{result: inspect(result, pretty: true, limit: :infinity)}

    ~H"""
    <div class="bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
      <pre class="text-sm overflow-x-auto"><%= @result %></pre>
    </div>
    """
  end
end
