defmodule EvoDashWeb.DashboardComponents do
  use EvoDashWeb, :html

  @default_concurrency to_string(EvoGit.Defaults.max_concurrency())
  @default_retries to_string(EvoGit.Defaults.max_retries())
  @default_agent_max_retries to_string(EvoGit.Defaults.agent_max_retries())

  # ---------------------------------------------------------------------------
  # task_form/1 — Modern card with gradient hero, better spacing
  # ---------------------------------------------------------------------------

  attr :prompt, :string, default: ""
  attr :mode, :string, default: "genesis_new"
  attr :mode_info, :string, default: ""
  attr :concurrency, :string, default: @default_concurrency
  attr :retries, :string, default: @default_retries
  attr :agent_max_retries, :string, default: @default_agent_max_retries

  def task_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-submit="task_submit"
      phx-change="task_change"
      class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden"
    >
      <!-- Hero Header -->
      <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent p-6 md:p-8">
        <div class="flex items-center gap-3">
          <div class="bg-primary/15 text-primary p-3 rounded-xl">
            <.icon name="hero-sparkles" class="size-6" />
          </div>
          <div>
            <h2 class="text-xl font-bold">Configure Task</h2>
            <p class="text-sm text-base-content/60">Bootstrap, analyze, or evolve your codebase</p>
          </div>
        </div>
      </div>

      <!-- Body -->
      <div class="p-6 md:p-8 pt-4 md:pt-6">
        <div class="grid grid-cols-1 md:grid-cols-12 gap-8">
          <!-- Left Column: Prompt -->
          <div class="md:col-span-8 flex flex-col gap-6">
            <div class="form-control flex-1">
              <label class="label">
                <span class="label-text font-semibold text-base-content">Prompt / Objective</span>
              </label>
              <textarea
                name="prompt"
                class="textarea textarea-bordered w-full min-h-[240px] text-base leading-relaxed focus:outline-none focus:ring-2 focus:ring-primary/30 resize-y bg-base-200/30"
                placeholder="Describe the software you want to create or the change you want to make..."
              ><%= @prompt %></textarea>
            </div>
          </div>

          <!-- Right Column: Mode & Options -->
          <div class="md:col-span-4 flex flex-col gap-6">
            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold text-base-content">Task Mode</span>
              </label>
              <select
                name="mode"
                class="select select-bordered w-full focus:outline-none focus:ring-2 focus:ring-primary/30 font-medium bg-base-200/30"
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
              <label class="label">
                <span class="label-text-alt text-base-content/50 text-xs">Mode auto-detected. Change if needed.</span>
              </label>
            </div>

            <div>
              <div class="divider text-xs text-base-content/40 uppercase tracking-widest my-2">
                Advanced Config
              </div>

              <div class="space-y-4 bg-base-200/30 p-4 rounded-xl border border-base-200/50">
                <div class="form-control">
                  <label class="flex justify-between items-center mb-1">
                    <span class="label-text text-xs font-medium text-base-content/70">Concurrency Limit</span>
                    <span class="text-xs text-base-content/40" title="Max parallel tasks">
                      <.icon name="hero-information-circle" class="size-3" />
                    </span>
                  </label>
                  <input
                    type="number"
                    name="concurrency"
                    value={@concurrency}
                    min="1"
                    max="10000"
                    class="input input-sm input-bordered w-full focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono bg-base-100/50"
                  />
                </div>
                <div class="form-control">
                  <label class="flex justify-between items-center mb-1">
                    <span class="label-text text-xs font-medium text-base-content/70">Max Retries</span>
                  </label>
                  <input
                    type="number"
                    name="retries"
                    value={@retries}
                    min="1"
                    max="10000"
                    class="input input-sm input-bordered w-full focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono bg-base-100/50"
                  />
                </div>
                <div class="form-control">
                  <label class="flex justify-between items-center mb-1">
                    <span class="label-text text-xs font-medium text-base-content/70">Agent Max Retries</span>
                  </label>
                  <input
                    type="number"
                    name="agent_max_retries"
                    value={@agent_max_retries}
                    min="1"
                    max="100"
                    class="input input-sm input-bordered w-full focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono bg-base-100/50"
                  />
                </div>
              </div>
            </div>
          </div>
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
              "flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium cursor-pointer transition-all whitespace-nowrap",
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

  def open_project_form(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
        <!-- Hero section -->
        <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent p-8 text-center">
          <div class="bg-primary/15 text-primary p-4 rounded-2xl w-fit mx-auto mb-4">
            <.icon name="hero-folder-open" class="size-10" />
          </div>
          <h2 class="text-2xl font-bold">Open a Project</h2>
          <p class="text-base-content/60 mt-2">Enter the path to a Git repository to get started</p>
        </div>

        <!-- Form -->
        <div class="p-6 pt-2">
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
                  class="input input-bordered w-full pl-11 pr-4 h-12 focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono text-sm bg-base-200/50"
                  placeholder="/path/to/your/repo"
                  autofocus
                  phx-hook="PathAutocomplete"
                  id="initial-project-path-input"
                  list="path-suggestions"
                />
                <datalist id="path-suggestions">
                  <%= for project <- @recent_projects do %>
                    <option value={project.path}></option>
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
  # task_card/1 — Modern card with accent bar, pulse animation, better logs
  # ---------------------------------------------------------------------------

  attr :task, :map, required: true
  attr :show_details, :boolean, default: false

  def task_card(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 hover:shadow-md transition-all duration-200 overflow-hidden">
      <div class="flex">
        <!-- Left accent bar -->
        <div class={["w-1 shrink-0", status_accent_color(@task.status)]}></div>

        <div class="flex-1 p-5 md:p-6">
          <div class="flex items-start justify-between gap-4">
            <div class="flex items-start gap-4 flex-1">
              <div class="avatar placeholder mt-0.5">
                <div class="bg-primary/10 text-primary rounded-xl w-12 h-12">
                  <.icon name={task_type_icon(@task.type)} class="size-6" />
                </div>
              </div>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-3 flex-wrap">
                  <h3 class="font-bold capitalize text-lg">{@task.type}</h3>
                  <span class="flex items-center gap-1.5">
                    <span class={task_status_badge(@task.status)}>
                      <%= if @task.status == :running do %>
                        <span class="relative flex h-2 w-2 mr-1.5">
                          <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-info opacity-75"></span>
                          <span class="relative inline-flex rounded-full h-2 w-2 bg-info"></span>
                        </span>
                      <% end %>
                      {@task.status}
                    </span>
                  </span>
                </div>
                <p class="text-xs text-base-content/60 mt-1 flex items-center gap-1">
                  <.icon name="hero-hashtag" class="size-3" />
                  <code class="bg-base-200 px-1.5 py-0.5 rounded font-mono">{@task.id}</code>
                </p>
                <p class="text-sm mt-3 text-base-content/90 font-medium line-clamp-2 leading-relaxed">
                  {task_description(@task)}
                </p>
                <div class="flex items-center gap-5 mt-4 text-xs font-medium text-base-content/60">
                  <span class="flex items-center gap-1.5">
                    <.icon name="hero-clock" class="size-4" />
                    Started: {format_datetime(@task.started_at)}
                  </span>
                  <%= if Map.get(@task, :finished_at) do %>
                    <span class="flex items-center gap-1.5">
                      <.icon name="hero-check-circle" class="size-4 text-success" />
                      Finished: {format_datetime(@task.finished_at)}
                    </span>
                  <% end %>
                </div>
              </div>
            </div>
            <div class="flex flex-col sm:flex-row items-center gap-2">
              <%= if @task.status == :running do %>
                <button
                  class="btn btn-sm btn-outline btn-error shadow-sm"
                  phx-click="cancel_task"
                  phx-value-task_id={@task.id}
                  phx-confirm="Are you sure you want to cancel this task?"
                >
                  <.icon name="hero-x-mark" class="size-4" /> Cancel
                </button>
              <% end %>
              <button
                class="btn btn-sm btn-ghost bg-base-200/50 hover:bg-base-200"
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
            <div class="divider my-4"></div>
            <div class="space-y-4">
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="bg-base-200/40 p-4 rounded-xl border border-base-200">
                  <div class="flex items-center justify-between mb-3">
                    <h4 class="text-sm font-bold flex items-center gap-2">
                      <.icon name="hero-cog-8-tooth" class="size-4 text-primary" /> Options
                    </h4>
                    <button
                      class="btn btn-xs btn-ghost"
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
                  <div class="bg-base-200/40 p-4 rounded-xl border border-base-200">
                    <div class="flex items-center justify-between mb-3">
                      <h4 class="text-sm font-bold flex items-center gap-2">
                        <.icon name="hero-check-badge" class="size-4 text-success" /> Result
                      </h4>
                      <button
                        class="btn btn-xs btn-ghost"
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
                <div class="bg-base-200/40 p-4 rounded-xl border border-base-200">
                  <h4 class="text-sm font-bold mb-3 flex items-center gap-2">
                    <.icon name="hero-command-line" class="size-4 text-base-content/70" /> Logs
                  </h4>
                  <div class="bg-base-300/50 p-3 rounded-lg max-h-64 overflow-y-auto text-xs font-mono space-y-px border border-base-300 shadow-inner">
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
                </div>
              <% end %>
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
  # Private helpers — render_options/1 (component-specific)
  # ---------------------------------------------------------------------------

  defp render_options(opts) do
    primary_text = opts[:prompt] || opts[:objective] || ""
    mode = opts[:mode] || ""
    path = opts[:path] || ""
    concurrency = opts[:concurrency]
    retries = opts[:retries]
    agent_max_retries = opts[:agent_max_retries]

    assigns = %{
      primary_text: primary_text,
      mode: mode,
      path: path,
      concurrency: concurrency,
      retries: retries,
      agent_max_retries: agent_max_retries
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
        <%= if @concurrency do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-arrow-path-rounded-square" class="size-3 mr-1" />
            concurrency: <%= @concurrency %>
          </span>
        <% end %>
        <%= if @retries do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-arrow-uturn-right" class="size-3 mr-1" />
            retries: <%= @retries %>
          </span>
        <% end %>
        <%= if @agent_max_retries do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-arrow-uturn-down" class="size-3 mr-1" />
            agent retries: <%= @agent_max_retries %>
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers — render_result/1 (component-specific)
  # ---------------------------------------------------------------------------

  defp render_result({:ok, %{result: result} = data}) when is_binary(result) do
    render_result(data)
  end

  defp render_result({:error, reason}) do
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

  defp render_result({:exit, reason}) do
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

  defp render_result(%{result: result, no_changes: true} = _data) when is_binary(result) do
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

  defp render_result(%{result: result, commit_sha: commit_sha} = data) when is_binary(result) do
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

  defp render_result(result) do
    assigns = %{result: inspect(result, pretty: true)}

    ~H"""
    <pre class="text-xs bg-base-100 p-3 rounded-lg border border-base-200 overflow-x-auto shadow-inner"><%= @result %></pre>
    """
  end
end
