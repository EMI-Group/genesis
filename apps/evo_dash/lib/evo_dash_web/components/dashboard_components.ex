defmodule EvoDashWeb.DashboardComponents do
  use EvoDashWeb, :html
  alias EvoGit.Core.ForeignRepo

  # ---------------------------------------------------------------------------
  # project_selector/1 — Project selection bar
  # ---------------------------------------------------------------------------

  attr :active_project, :map, default: nil
  attr :recent_projects, :list, default: []
  attr :is_desktop, :boolean, default: false
  attr :show_open_form, :boolean, default: false
  attr :path_suggestions, :list, default: []

  def project_selector(assigns) do
    ~H"""
    <div class="bg-base-200/50 rounded-xl p-4 border border-base-200">
      <div class="flex items-center gap-3 flex-wrap">
        <!-- Project icon + info -->
        <div class="flex items-center gap-2">
          <div class="bg-primary/15 text-primary p-2 rounded-lg">
            <.icon name="hero-folder-open" class="size-5" />
          </div>
          <div>
            <%= if @active_project do %>
              <p class="font-semibold text-sm">{@active_project.name}</p>
              <p class="text-xs text-base-content/50 font-mono truncate max-w-[300px]">{@active_project.path}</p>
            <% else %>
              <p class="font-semibold text-sm text-base-content/50">{gettext("No project selected")}</p>
              <p class="text-xs text-base-content/40">{gettext("Open a project to get started")}</p>
            <% end %>
          </div>
        </div>

        <!-- Spacer -->
        <div class="flex-1"></div>

        <!-- Recent projects dropdown (if any) -->
        <%= if @recent_projects != [] do %>
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-sm btn-ghost gap-1">
              <.icon name="hero-clock" class="size-4" />
              {gettext("Recent")}
              <.icon name="hero-chevron-down" class="size-3" />
            </div>
            <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-[1] w-72 p-2 shadow-lg border border-base-200 mt-2">
              <%= for project <- Enum.take(@recent_projects, 8) do %>
                <li>
                  <button phx-click="select_project" phx-value-path={project.path} class="flex items-center gap-2">
                    <.icon name="hero-folder" class="size-4 text-base-content/50" />
                    <div class="flex-1 min-w-0 text-left">
                      <p class="text-sm font-medium truncate">{project.name}</p>
                      <p class="text-xs text-base-content/40 font-mono truncate">{project.path}</p>
                    </div>
                    <%= if @active_project && @active_project.path == project.path do %>
                      <.icon name="hero-check" class="size-4 text-success" />
                    <% end %>
                  </button>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <!-- Open / Change project button -->
        <button class="btn btn-sm btn-primary gap-1" phx-click="toggle_open_project_form">
          <.icon name="hero-folder-open" class="size-4" />
          <%= if @active_project do %>
            {gettext("Change")}
          <% else %>
            {gettext("Open Project")}
          <% end %>
        </button>
      </div>

      <!-- Inline Open Project Form (expandable) -->
      <%= if @show_open_form do %>
        <div class="mt-3 pt-3 border-t border-base-300/50 animate-slide-down">
          <.form for={%{}} phx-submit="open_project" class="flex flex-col sm:flex-row gap-2">
            <div class="picker-container relative flex-1">
              <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-base-content/40">
                <.icon name="hero-folder" class="size-4" />
              </div>
              <input
                type="text"
                name="path"
                class="input input-bordered input-sm w-full pl-9 pr-9 focus:outline-none focus:ring-2 focus:ring-primary/30 font-mono text-sm"
                placeholder={gettext("/path/to/your/repo")}
                autofocus
                phx-hook="PathAutocomplete"
                phx-change="path_input"
                phx-debounce="150"
                id="project-path-input"
                list="path-suggestions"
              />
              <button
                type="button"
                id="project-path-picker-button"
                class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-primary transition-colors"
                phx-click="pick_directory"
                phx-hook="DirectoryPicker"
                data-is-desktop={to_string(@is_desktop)}
                data-picker-id="project"
                title={gettext("Browse for directory")}
              >
                <.icon name="hero-folder-open" class="size-4" />
              </button>
              <datalist id="path-suggestions">
                <%= for suggestion <- @path_suggestions do %>
                  <option value={suggestion}></option>
                <% end %>
              </datalist>
            </div>
            <button type="submit" class="btn btn-primary btn-sm gap-1">
              <.icon name="hero-check" class="size-4" /> {gettext("Open")}
            </button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle_open_project_form">
              {gettext("Cancel")}
            </button>
          </.form>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # task_form/1 — Modern card with gradient hero, tooltips, and better UX
  # ---------------------------------------------------------------------------

  attr :prompt, :string, default: ""
  attr :mode, :string, default: "genesis_new"
  attr :mode_info, :string, default: ""
  attr :node_path, :string, default: ""
  attr :seeds, :string, default: ""
  attr :starting_commit, :string, default: ""
  attr :disabled, :boolean, default: false

  def task_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-submit="task_submit"
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
              <h2 class="text-lg font-bold">{gettext("Configure Task")}</h2>
              <p class="text-xs text-base-content/60">{gettext("Bootstrap, analyze, or evolve your codebase")}</p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/60 whitespace-nowrap">{gettext("Task Mode")}</span>
            <select
              name="mode"
              phx-change="task_change"
              class="select select-bordered select-sm focus:outline-none focus:ring-2 focus:ring-primary/30 font-medium bg-base-200/30"
            >
              <optgroup label={gettext("Genesis (Bootstrap & Analyze)")}>
                <option value="genesis_new" selected={@mode == "genesis_new"}>{gettext("New Codebase")}</option>
                <option value="genesis_existing" selected={@mode == "genesis_existing"}>{gettext("Existing Codebase")}</option>
              </optgroup>
              <optgroup label={gettext("Evolve (Mutate Code)")}>
                <option value="evolve_simple" selected={@mode == "evolve_simple"}>{gettext("Simple (Top-down)")}</option>
              </optgroup>
            </select>
            <.tip text={mode_description(@mode)} />
          </div>
        </div>
      </div>

      <!-- Body -->
      <div class={["p-6 md:p-8 pt-4 md:pt-6 space-y-4", @disabled && "opacity-50 pointer-events-none select-none"]}>
        <!-- Mode info banner -->
        <div class="bg-info/10 border border-info/20 rounded-lg p-3 text-sm text-info flex items-start gap-2">
          <.icon name="hero-information-circle" class="size-4 shrink-0 mt-0.5" />
          <span>{mode_description(@mode)}</span>
        </div>

        <%= if String.starts_with?(@mode, "evolve") do %>
          <div class="flex flex-col md:flex-row gap-4">
            <div class="form-control flex-1">
              <label class="label">
                <span class="label-text font-semibold text-base-content">{gettext("Starting Node")} <.tip text={gettext("The subdirectory within the project to start evolution from. Use './' for root.")} /></span>
              </label>
              <input
                type="text"
                name="node_path"
                value={@node_path}
                phx-debounce="300"
                class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
                placeholder={gettext("e.g., ./src/components")}
              />
              <label class="label">
                <span class="label-text-alt text-base-content/50">{gettext("Subdirectory to start evolution from (optional)")}</span>
              </label>
            </div>
            <div class="form-control flex-1">
              <label class="label">
                <span class="label-text font-semibold text-base-content">{gettext("Starting Commit")} <.tip text={gettext("A Git commit SHA, branch name, or tag to use as the base. Defaults to HEAD.")} /></span>
              </label>
              <input
                type="text"
                name="starting_commit"
                value={@starting_commit}
                phx-debounce="300"
                class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
                placeholder={gettext("e.g., abc1234 or HEAD")}
              />
              <label class="label">
                <span class="label-text-alt text-base-content/50">{gettext("Commit SHA or ref to start from (defaults to HEAD)")}</span>
              </label>
            </div>
          </div>
        <% end %>
        <%= if @mode == "evolve_complex" do %>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-base-content">
                {gettext("Seed Code")} <span class="badge badge-ghost">{gettext("optional")}</span>
                <.tip text={gettext("Provide seed code content for evolutionary selection. Multiple seeds improve diversity.")} />
              </span>
            </label>
            <textarea
              name="seeds"
              phx-debounce="300"
              class="textarea textarea-bordered w-full min-h-[120px] text-sm font-mono leading-relaxed focus:outline-none focus:ring-2 focus:ring-primary/30 resize-y bg-base-200/30"
              placeholder={gettext("Paste seed code here. Separate multiple fragments with blank lines...")}
            ><%= @seeds %></textarea>
            <label class="label">
              <span class="label-text-alt text-base-content/50">{gettext("User seeds are preferred over built-in seeds during evolution")}</span>
            </label>
          </div>
        <% end %>
        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold text-base-content">
              <%= if String.starts_with?(@mode, "evolve") do %>
                {gettext("Objective")}
              <% else %>
                {gettext("Prompt")}
              <% end %>
            </span>
          </label>
          <textarea
            name="prompt"
            phx-debounce="300"
            class="textarea textarea-bordered w-full min-h-[160px] sm:min-h-[240px] text-base leading-relaxed focus:outline-none focus:ring-2 focus:ring-primary/30 resize-y bg-base-200/30"
            placeholder={
              if String.starts_with?(@mode, "evolve") do
                gettext("Describe what you want to change or improve...")
              else
                gettext("Describe the codebase you want to create...")
              end
            }
          ><%= @prompt %></textarea>
        </div>
      </div>

      <!-- Footer action bar -->
      <div class="bg-base-200/50 px-6 py-4 md:px-8 border-t border-base-200 flex flex-col sm:flex-row items-center justify-between gap-4">
        <span class="text-sm text-base-content/60 flex items-center gap-2">
          <.icon name="hero-light-bulb" class="size-5 text-warning" />
          {gettext("Ready to execute. Mode was auto-detected based on project state.")}
        </span>
        <button
          type="submit"
          class="btn btn-primary px-8 h-12 text-base shadow-md hover:shadow-lg transition-all w-full sm:w-auto"
          disabled={@disabled}
        >
          <.icon name="hero-rocket-launch" class="size-5" /> {gettext("Execute Task")}
        </button>
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # project_settings_panel/1 — Integrated project settings
  # ---------------------------------------------------------------------------

  attr :active_project, :string, required: true
  attr :show, :boolean, default: false
  attr :project_config, :map, default: nil
  attr :worktree_script, :string, default: nil
  attr :commands, :map, default: %{}
  attr :foreign_repos, :list, default: []
  attr :show_add_foreign_repo, :boolean, default: false
  attr :new_repo_id, :string, default: ""
  attr :new_repo_path, :string, default: ""
  attr :new_repo_name, :string, default: ""
  attr :is_desktop, :boolean, default: false

  def project_settings_panel(assigns) do
    ~H"""
    <details class="group" open={@show}>
      <summary class="bg-base-100 rounded-2xl shadow-sm border border-base-200 p-4 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-3 list-none">
        <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/60" />
        <span class="font-semibold">{gettext("Project Settings")}</span>
        <div class="flex-1"></div>
        <!-- Config status indicator -->
        <%= if @project_config do %>
          <span class="badge badge-success badge-sm gap-1">
            <.icon name="hero-check-circle" class="size-3" /> {gettext("evogit.toml")}
          </span>
        <% else %>
          <span class="badge badge-ghost badge-sm gap-1">
            <.icon name="hero-document-text" class="size-3" /> {gettext("Defaults")}
          </span>
        <% end %>
        <.icon name="hero-chevron-down" class="size-4 text-base-content/40 group-open:rotate-180 transition-transform" />
      </summary>

      <div class="bg-base-100 rounded-b-2xl border border-t-0 border-base-200 p-4 sm:p-6 space-y-4">
        <!-- Config Info -->
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
            <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{gettext("Project Root")}</p>
            <p class="text-sm font-mono mt-1 truncate">{@active_project}</p>
          </div>
          <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
            <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{gettext("Configuration")}</p>
            <p class="text-sm mt-1">
              <%= if @project_config do %>
                <span class="text-success flex items-center gap-1">
                  <.icon name="hero-check-circle" class="size-4" /> {gettext("evogit.toml found — using project settings")}
                </span>
              <% else %>
                <span class="text-base-content/50 flex items-center gap-1">
                  <.icon name="hero-information-circle" class="size-4" /> {gettext("No evogit.toml — using global defaults")}
                </span>
              <% end %>
            </p>
          </div>
        </div>

        <%= if @worktree_script do %>
          <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
            <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{gettext("Worktree Init Script")}</p>
            <p class="text-sm font-mono mt-1">{@worktree_script}</p>
          </div>
        <% end %>

        <%= if @commands != %{} do %>
          <div class="border-t border-base-200 pt-4">
            <h3 class="text-sm font-semibold flex items-center gap-2 mb-3">
              <.icon name="hero-terminal" class="size-4 text-secondary" /> {gettext("Dev Commands")}
              <.tip text={gettext("Quick shortcuts for common development commands. Click Run to execute.")} />
            </h3>
            <div class="space-y-2">
              <%= for {name, cmd} <- Enum.sort(@commands) do %>
                <div class="flex items-center gap-2 bg-base-200/40 rounded-lg p-2.5 border border-base-200">
                  <span class="badge badge-accent badge-sm font-mono">{name}</span>
                  <span class="text-sm font-mono flex-1 truncate">{cmd}</span>
                  <button class="btn btn-ghost btn-xs btn-primary" phx-click="run_command" phx-value-command={name}>
                    <.icon name="hero-play" class="size-3" /> {gettext("Run")}
                  </button>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <!-- Foreign Repos -->
        <div class="border-t border-base-200 pt-4">
          <h3 class="text-sm font-semibold flex items-center gap-2 mb-3">
            <.icon name="hero-server-stack" class="size-4 text-secondary" /> {gettext("Foreign Repositories")}
            <.tip text={gettext("Foreign repos are additional codebases accessible to agents during task execution. Useful for referencing original code or related projects.")} />
          </h3>

          <%= if @foreign_repos == [] do %>
            <p class="text-sm text-base-content/40 py-2">{gettext("No foreign repositories registered")}</p>
          <% else %>
            <div class="space-y-2">
              <%= for repo <- @foreign_repos do %>
                <div class="flex items-center gap-2 bg-base-200/40 rounded-lg p-2.5 border border-base-200">
                  <span class={"badge #{if ForeignRepo.primary?(repo.id), do: "badge-primary", else: "badge-ghost"} badge-sm font-mono"}>
                    {repo.id}
                  </span>
                  <span class="text-sm font-mono flex-1 truncate">{repo.root}</span>
                  <%= if repo.name && repo.name != Atom.to_string(repo.id) do %>
                    <span class="text-xs text-base-content/50">{repo.name}</span>
                  <% end %>
                  <%= unless ForeignRepo.primary?(repo.id) do %>
                    <button class="btn btn-ghost btn-xs text-error" phx-click="remove_foreign_repo" phx-value-repo_id={repo.id}>
                      <.icon name="hero-trash" class="size-3" />
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- Add Foreign Repo -->
          <%= if @show_add_foreign_repo do %>
            <div class="mt-3 border border-base-200 rounded-lg p-3 bg-base-200/20 animate-slide-down">
              <.form for={%{}} phx-submit="add_foreign_repo" class="space-y-3">
                <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
                  <div>
                    <label class="label py-1">
                      <span class="label-text text-xs font-medium">{gettext("Repo ID")} <.tip text={gettext("A unique identifier for this repository (e.g., 'original', 'upstream')")} /></span>
                    </label>
                    <input type="text" name="repo_id" value={@new_repo_id} placeholder="e.g., original"
                      class="input input-bordered input-sm w-full font-mono" required />
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text text-xs font-medium">{gettext("Path")} <.tip text={gettext("Absolute path to the repository root on this machine")} /></span>
                    </label>
                    <div class="picker-container relative">
                      <input type="text" name="path" value={@new_repo_path} placeholder="/absolute/path/to/repo"
                        class="input input-bordered input-sm w-full font-mono pr-8" required
                        id="foreign-repo-path-input" />
                      <button type="button"
                        id="foreign-repo-path-picker-button"
                        class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-primary transition-colors"
                        phx-click="pick_directory"
                        phx-hook="DirectoryPicker"
                        data-is-desktop={to_string(@is_desktop)}
                        data-picker-id="foreign-repo"
                        title={gettext("Browse for directory")}
                      >
                        <.icon name="hero-folder-open" class="size-4" />
                      </button>
                    </div>
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text text-xs font-medium">{gettext("Name (optional)")}</span>
                    </label>
                    <input type="text" name="name" value={@new_repo_name} placeholder={gettext("Human-readable name")}
                      class="input input-bordered input-sm w-full" />
                  </div>
                </div>
                <div class="flex gap-2">
                  <button type="submit" class="btn btn-primary btn-sm gap-1">
                    <.icon name="hero-plus" class="size-3" /> {gettext("Add")}
                  </button>
                  <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle_add_foreign_repo_form">
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </div>
          <% else %>
            <button class="btn btn-sm btn-outline btn-secondary gap-1 mt-3" phx-click="toggle_add_foreign_repo_form">
              <.icon name="hero-plus-circle" class="size-4" /> {gettext("Add Foreign Repo")}
            </button>
          <% end %>
        </div>
      </div>
    </details>
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
            <h2 class="text-xl font-bold">{gettext("Scheduler Settings")}</h2>
            <p class="text-sm text-base-content/60">{gettext("Runtime configuration for agent execution")}</p>
          </div>
        </div>
      </div>
      <div class="p-6 md:p-8 pt-4 md:pt-6">
        <.form for={%{}} phx-submit="update_scheduler_config" phx-change="scheduler_config_change" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 md:gap-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">{gettext("LLM Concurrency")}</span>
              </label>
              <input type="number" name="max_concurrency" value={@config[:max_concurrency]} min="1" max="100"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Max parallel LLM calls")}</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">{gettext("Tool Concurrency")}</span>
              </label>
              <input type="number" name="max_tool_concurrency" value={@config[:max_tool_concurrency]} min="1" max="100"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Max parallel tool executions")}</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">{gettext("Agent Max Retries")}</span>
              </label>
              <input type="number" name="agent_max_retries" value={@config[:agent_max_retries]} min="0" max="20"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Crash-retries per agent")}</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">{gettext("Max Depth")}</span>
              </label>
              <input type="number" name="max_agent_depth" value={@config[:max_agent_depth]} min="1" max="20"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Max subagent recursion")}</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">{gettext("LLM Retries")}</span>
              </label>
              <input type="number" name="max_retries" value={@config[:max_retries]} min="1" max="100"
                class="input input-bordered input-sm w-full font-mono" />
              <label class="label"><span class="label-text-alt text-base-content/50">{gettext("API call retries")}</span></label>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">{gettext("LLM Model")}</span>
              </label>
              <input type="text" name="llm_model" value={@config[:llm_model] || ""} 
                class="input input-bordered input-sm w-full font-mono" placeholder={gettext("Configure in config.toml")} />
              <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Model identifier")}</span></label>
            </div>
          </div>
          <div class="pt-2">
            <button type="submit" class="btn btn-secondary">
              <.icon name="hero-arrow-path" class="size-4" /> {gettext("Update Settings")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # sandbox_settings/1 — Sandbox configuration panel
  # ---------------------------------------------------------------------------

  attr :config, :map, required: true

  def sandbox_settings(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
      <div class="bg-gradient-to-br from-accent/10 via-accent/5 to-transparent p-6 md:p-8">
        <div class="flex items-center gap-3">
          <div class="bg-accent/15 text-accent p-3 rounded-xl">
            <.icon name="hero-shield-check" class="size-6" />
          </div>
          <div>
            <h2 class="text-xl font-bold">{gettext("Sandbox Settings")}</h2>
            <p class="text-sm text-base-content/60">{gettext("Resource isolation for agent-executed commands")}</p>
          </div>
        </div>
      </div>

      <!-- Backend Status Banner -->
      <div class="px-6 md:px-8 pt-2">
        <%= case @config[:sandbox_backend] do %>
          <% :systemd_run -> %>
            <div class="flex items-center gap-2 p-3 rounded-lg bg-success/10 border border-success/20">
              <span class="badge badge-success badge-sm">systemd-run</span>
              <span class="text-sm text-success/80">{gettext("Full sandboxing: filesystem isolation, resource limits, syscall filtering")}</span>
            </div>
          <% :sandbox_exec -> %>
            <div class="flex items-center gap-2 p-3 rounded-lg bg-warning/10 border border-warning/20">
              <span class="badge badge-warning badge-sm">sandbox-exec</span>
              <span class="text-sm text-warning/80">{gettext("Filesystem isolation only. Resource limits not available on macOS.")}</span>
            </div>
          <% _ -> %>
            <div class="flex items-center gap-2 p-3 rounded-lg bg-error/10 border border-error/20">
              <span class="badge badge-error badge-sm">{gettext("Not Available")}</span>
              <span class="text-sm text-error/80">{gettext("No sandbox support on this platform. Commands run directly.")}</span>
            </div>
        <% end %>
      </div>

      <%= if @config[:sandbox_backend] != :none do %>
        <div class="p-6 md:p-8 pt-4 md:pt-6">
          <.form for={%{}} phx-submit="update_sandbox_config" phx-change="sandbox_config_change" class="space-y-4">
            <div class="space-y-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-sm font-medium">{gettext("Sandbox Mode")}</span>
                </label>
                <select name="sandbox_mode" class="select select-bordered select-sm w-full font-mono">
                  <option value="auto" selected={(@config[:sandbox_mode] || :auto) == :auto}>{gettext("Auto (default)")}</option>
                  <option value="enabled" selected={@config[:sandbox_mode] == :enabled}>{gettext("Enabled")}</option>
                  <option value="disabled" selected={@config[:sandbox_mode] == :disabled}>{gettext("Disabled")}</option>
                </select>
                <label class="label"><span class="label-text-alt text-base-content/50">
                  <%= cond do %>
                    <% @config[:sandbox_backend] == :systemd_run -> %>
                      {gettext("Auto enables systemd-run on Linux when available")}
                    <% @config[:sandbox_backend] == :sandbox_exec -> %>
                      {gettext("Auto enables sandbox-exec on macOS when available")}
                    <% true -> %>
                      {gettext("Controls sandbox activation")}
                  <% end %>
                </span></label>
              </div>

              <%= if @config[:sandbox_backend] == :systemd_run do %>
                <div class={if @config[:sandbox_mode] == :disabled, do: "opacity-50 pointer-events-none select-none", else: ""}>
                  <!-- Shared Slice Resources -->
                  <div class="mb-4">
                    <h3 class="text-sm font-semibold text-base-content/70 mb-1">{gettext("Shared Slice Resources")}</h3>
                    <p class="text-xs text-base-content/50 mb-3">{gettext("Aggregate limits for the entire evogit.slice (all sandboxed processes combined)")}</p>
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3 md:gap-4">
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("CPU Quota")}</span>
                        </label>
                        <input type="text" name="cpu_quota" value={@config[:sandbox_resources][:cpu_quota] || "1000%"}
                          class="input input-bordered input-sm w-full font-mono" placeholder="e.g. 1000% (10 cores)" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Total CPU quota (e.g. 1000% = 10 cores)")}</span></label>
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("CPU Weight")}</span>
                        </label>
                        <input type="number" name="cpu_weight" value={@config[:sandbox_resources][:cpu_weight] || 30} min="1" max="10000"
                          class="input input-bordered input-sm w-full font-mono" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("CPU allocation weight (1-10000)")}</span></label>
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("Memory Max")}</span>
                        </label>
                        <input type="text" name="memory_max" value={@config[:sandbox_resources][:memory_max] || "16G"}
                          class="input input-bordered input-sm w-full font-mono" placeholder="e.g. 16G, 8G, 512M" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Total memory for all processes")}</span></label>
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("Tasks Max")}</span>
                        </label>
                        <input type="number" name="tasks_max" value={@config[:sandbox_resources][:tasks_max] || 8196} min="1"
                          class="input input-bordered input-sm w-full font-mono" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Max concurrent tasks/processes")}</span></label>
                      </div>
                    </div>
                  </div>

                  <div class="divider my-2"></div>

                  <!-- Per-Process Limits -->
                  <div>
                    <h3 class="text-sm font-semibold text-base-content/70 mb-1">{gettext("Per-Process Limits")}</h3>
                    <p class="text-xs text-base-content/50 mb-3">{gettext("Individual caps applied to each tool call (systemd-run invocation)")}</p>
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3 md:gap-4">
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("CPU Quota")}</span>
                        </label>
                        <input type="text" name="process_cpu_quota" value={@config[:sandbox_process_resources][:cpu_quota] || "800%"}
                          class="input input-bordered input-sm w-full font-mono" placeholder="e.g. 800% (8 cores)" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Per-process CPU quota (e.g. 800% = 8 cores)")}</span></label>
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("Memory Max")}</span>
                        </label>
                        <input type="text" name="process_memory_max" value={@config[:sandbox_process_resources][:memory_max] || "12G"}
                          class="input input-bordered input-sm w-full font-mono" placeholder="e.g. 12G, 8G" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Memory limit per tool call")}</span></label>
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("Open Files Limit")}</span>
                        </label>
                        <input type="number" name="process_limit_nofile" value={@config[:sandbox_process_resources][:limit_nofile] || 65536} min="1"
                          class="input input-bordered input-sm w-full font-mono" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("Max open file descriptors")}</span></label>
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-sm font-medium">{gettext("OOM Score Adjust")}</span>
                        </label>
                        <input type="number" name="process_oom_score_adjust" value={@config[:sandbox_process_resources][:oom_score_adjust] || 1000} min="-1000" max="1000"
                          class="input input-bordered input-sm w-full font-mono" />
                        <label class="label"><span class="label-text-alt text-base-content/50">{gettext("OOM killer preference (-1000 to 1000)")}</span></label>
                      </div>
                    </div>
                  </div>
                </div>
              <% else %>
                <%!-- macOS or other non-none, non-systemd backend: show note about resource limits --%>
                <div class={if @config[:sandbox_mode] == :disabled, do: "opacity-50 pointer-events-none select-none", else: ""}>
                  <div class="bg-info/10 border border-info/20 rounded-lg p-3">
                    <p class="text-sm text-info/80">
                      <.icon name="hero-information-circle" class="size-4 inline-block mr-1" />
                      {gettext("Resource limits are only available on Linux with systemd-run. Only filesystem isolation is active on this platform.")}
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
            <div class="pt-2">
              <button type="submit" class="btn btn-accent">
                <.icon name="hero-shield-check" class="size-4" /> {gettext("Update Sandbox Settings")}
              </button>
            </div>
          </.form>
        </div>
      <% else %>
        <%!-- Windows / no backend --%>
        <div class="p-6 md:p-8 pt-4 md:pt-6">
          <div class="bg-base-200/50 rounded-lg p-4 text-center">
            <.icon name="hero-shield-exclamation" class="size-8 text-base-content/30 mb-2" />
            <p class="text-sm text-base-content/60">{gettext("Sandbox is not available on this platform. All commands run directly without isolation.")}</p>
          </div>
        </div>
      <% end %>
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
      task_card_tint(@task)
    ]}>
      <!-- Three-dot kebab menu -->
      <details class="dropdown dropdown-end absolute top-3 right-3 z-[1]">
        <summary class="btn btn-sm btn-ghost btn-circle">
          <.icon name="hero-ellipsis-vertical" class="size-4" />
        </summary>
        <ul class="menu menu-sm dropdown-content mt-1 z-[1] p-2 shadow-lg bg-base-100 rounded-box w-40 border border-base-200">
          <li>
            <button class="text-error" phx-click="delete_task" phx-value-task_id={@task.id} phx-confirm={gettext("Delete this task?")}>
              <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
            </button>
          </li>
        </ul>
      </details>

      <div class="flex">
        <!-- Left accent bar -->
        <div class={["w-1 shrink-0", task_accent_color(@task)]}></div>

        <div class="flex-1 p-3 md:p-4 min-w-0">
          <!-- Compact header — single row: type · mode | status · short ID -->
          <div class="flex items-center justify-between gap-3 mb-1 pr-7">
            <div class="flex items-center gap-1 text-xs text-base-content/60 min-w-0">
              <span class="capitalize font-medium text-base-content/80">{@task.type}</span>
              <span class="text-base-content/30">·</span>
              <span class="font-mono">{@task.opts[:mode]}</span>
            </div>
            <div class="flex items-center gap-1 shrink-0">
              <span class={task_status_badge(@task.status)}>
                <%= if @task.status == :running do %>
                  <span class="relative flex h-2 w-2 mr-1.5">
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75" style="animation-duration: 2s"></span>
                    <span class="relative inline-flex rounded-full h-2 w-2 bg-success"></span>
                  </span>
                <% end %>
                <%= if @task.status == :finalizing do %>
                  <span class="loading loading-spinner loading-xs mr-1.5"></span>
                <% end %>
                <%= cond do %>
                  <% @task.status == :finalizing -> %>Finalizing
                  <% true -> %>{@task.status}
                <% end %>
              </span>
              <%= if Map.get(@task, :review_status) do %>
                <span class="text-base-content/30">·</span>
                <span class={["badge badge-sm", review_status_badge(Map.get(@task, :review_status))]}>
                  <.icon name={review_status_icon(Map.get(@task, :review_status))} class="size-3 mr-1" />
                  {review_status_label(Map.get(@task, :review_status))}
                </span>
              <% end %>
              <span class="text-xs text-base-content/30">·</span>
              <span class="text-xs font-mono text-base-content/40">
                {String.slice(@task.id, 0, 8)}
              </span>
            </div>
          </div>

          <!-- Objective with line-clamp-1 + HTML tooltip -->
          <% objective_text = @task.opts[:prompt] || @task.opts[:objective] || "" %>
          <%= if objective_text != "" do %>
            <p class="text-sm text-base-content/80 leading-snug line-clamp-1" title={objective_text}>
              {objective_text}
            </p>
          <% else %>
            <p class="text-sm text-base-content/80 leading-snug line-clamp-1" title={task_description(@task)}>
              {task_description(@task)}
            </p>
          <% end %>

          <!-- Compact footer — single row: relative timestamps | actions -->
          <div class="flex items-center justify-between gap-3 mt-1 pt-1 border-t border-base-200/50">
            <div class="flex items-center gap-1 text-xs text-base-content/50 min-w-0">
              <span class="flex items-center gap-1 shrink-0">
                {gettext("Started")} {relative_time(@task.started_at)}
              </span>
              <%= if Map.get(@task, :finished_at) do %>
                <span class="text-base-content/30">·</span>
                <span class="flex items-center gap-1 shrink-0">
                  {gettext("Finished")} {relative_time(@task.finished_at)}
                </span>
              <% end %>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <%= if show_review_button?(@task) do %>
                <.link
                  navigate={~p"/review/#{@task.id}"}
                  class="btn btn-primary shadow-sm"
                >
                  <.icon name="hero-eye" class="size-4" /> {gettext("Review")}
                </.link>
              <% end %>
              <%= if @task.status in [:running, :finalizing] do %>
                <button
                  class="btn btn-outline btn-error shadow-sm"
                  phx-click="cancel_task"
                  phx-value-task_id={@task.id}
                  phx-confirm={gettext("Are you sure you want to cancel this task?")}
                >
                  <.icon name="hero-x-mark" class="size-4" /> {gettext("Cancel")}
                </button>
              <% end %>
              <button
                class="btn btn-ghost bg-base-200/50 hover:bg-base-200"
                phx-click="toggle_task_details"
                phx-value-task_id={@task.id}
              >
                <%= if @show_details do %>
                  {gettext("Hide Details")} <.icon name="hero-chevron-up" class="size-4 ml-1" />
                <% else %>
                  {gettext("View Details")} <.icon name="hero-chevron-down" class="size-4 ml-1" />
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
                        <.icon name="hero-cog-8-tooth" class="size-4 text-primary" /> {gettext("Options")}
                      </h4>
                      <button
                        class="btn btn-sm btn-ghost"
                        phx-click="view_full_options"
                        phx-value-task_id={@task.id}
                      >
                        <.icon name="hero-arrows-pointing-out" class="size-4" />
                        {gettext("View Full")}
                      </button>
                    </div>
                    {render_options(@task.opts)}
                  </div>
                  <%= if Map.get(@task, :result) do %>
                    <div class="bg-base-200/20 p-4 rounded-xl border border-base-200/60">
                      <div class="flex items-center justify-between mb-3">
                        <h4 class="text-sm font-bold flex items-center gap-2">
                          <.icon name="hero-check-badge" class="size-4 text-success" /> {gettext("Result")}
                        </h4>
                        <button
                          class="btn btn-sm btn-ghost"
                          phx-click="view_full_result"
                          phx-value-task_id={@task.id}
                        >
                          <.icon name="hero-arrows-pointing-out" class="size-4" />
                          {gettext("View Full")}
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
                      {gettext("Logs")} (<%= if log_count > 20, do: gettext("last 20 of %{count}", count: log_count), else: gettext("%{count} entries", count: log_count) %>)
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

  defp status_accent_color(:running), do: "bg-success"
  defp status_accent_color(:finalizing), do: "bg-orange-500"
  defp status_accent_color(:completed), do: "bg-info"
  defp status_accent_color(:failed), do: "bg-error"
  defp status_accent_color(:cancelled), do: "bg-warning"
  defp status_accent_color(_), do: "bg-base-300"

  defp task_accent_color(%{status: :completed, review_status: :merged}), do: "bg-success"
  defp task_accent_color(%{status: :completed, review_status: :rejected}), do: "bg-error"
  defp task_accent_color(%{status: :completed, review_status: :continued}), do: "bg-info"
  defp task_accent_color(%{status: status}), do: status_accent_color(status)

  defp task_card_tint(%{status: :running}), do: "bg-success/5"
  defp task_card_tint(%{status: :completed, review_status: :merged}), do: "bg-success/5"
  defp task_card_tint(%{status: :completed, review_status: :rejected}), do: "bg-error/5"
  defp task_card_tint(%{status: :completed, review_status: :continued}), do: "bg-info/5"
  defp task_card_tint(%{status: :completed}), do: "bg-info/5"
  defp task_card_tint(%{status: :finalizing}), do: "bg-orange-500/5"
  defp task_card_tint(_), do: ""

  defp review_status_badge(:merged), do: "badge-success"
  defp review_status_badge(:rejected), do: "badge-error"
  defp review_status_badge(:continued), do: "badge-info"
  defp review_status_badge(_), do: "badge-ghost"

  defp review_status_icon(:merged), do: "hero-check-circle"
  defp review_status_icon(:rejected), do: "hero-x-circle"
  defp review_status_icon(:continued), do: "hero-arrow-path"
  defp review_status_icon(_), do: "hero-question-mark-circle"

  defp review_status_label(:merged), do: "Merged"
  defp review_status_label(:rejected), do: "Rejected"
  defp review_status_label(:continued), do: "Continued"
  defp review_status_label(_), do: "Unknown"

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
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Objective")}
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
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Error")}
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
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Crashed")}
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
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Agent Message")}
        </h5>
        <div class="text-sm whitespace-pre-wrap break-words">
          {String.slice(@result, 0, 300)}{if String.length(@result) > 300, do: "..."}
        </div>
      </div>
      <div class="bg-warning/10 border border-warning/20 p-3 rounded-lg">
        <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-information-circle" class="size-3" /> {gettext("No Changes")}
        </h5>
        <p class="text-sm text-warning">{gettext("The agent completed without making any changes to the codebase.")}</p>
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
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Agent Message")}
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
            {gettext("View PR")}
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
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Objective")}
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
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Error")}
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
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Crashed")}
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
          <.icon name="hero-information-circle" class="size-3" /> {gettext("No Changes")}
        </h5>
        <p class="text-sm text-warning">{gettext("The agent completed without making any changes to the codebase.")}</p>
      </div>
      <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
        <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Agent Message")}
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
            {gettext("View PR")}
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

  defp show_review_button?(%{status: :completed, result: {:ok, %{branch_name: branch}}}) when is_binary(branch) and branch != "", do: true
  defp show_review_button?(_), do: false
end
