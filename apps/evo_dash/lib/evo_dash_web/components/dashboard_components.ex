defmodule EvoDashWeb.DashboardComponents do
  @moduledoc """
  Domain-specific components for the dashboard: task forms, task cards,
  project selector/tabs, and config-status badges.
  """
  use EvoDashWeb, :html
  alias EvoGit.Core.ForeignRepo

  # ---------------------------------------------------------------------------
  # project_selector/1 — Project selection bar
  # ---------------------------------------------------------------------------

  attr(:active_project, :map, default: nil)
  attr(:recent_projects, :list, default: [])
  attr(:show_open_form, :boolean, default: false)
  attr(:path_suggestions, :list, default: [])

  def project_selector(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-xl p-4 border border-primary/20 shadow-sm">
      <div class="flex items-center gap-3 flex-wrap">
        <!-- Project icon + info -->
        <div class="flex items-center gap-2">
          <div class="bg-primary/15 text-primary p-2 rounded-lg">
            <.icon name="hero-folder-open" class="size-5" />
          </div>
          <div>
            <%= if @active_project do %>
              <p class="text-base font-bold">{@active_project.name}</p>
              <p class="text-sm text-base-content/50 font-mono truncate max-w-[300px]">
                {@active_project.path}
              </p>
            <% else %>
              <p class="font-semibold text-sm text-base-content/50">
                {gettext("No project selected")}
              </p>
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
            <ul
              tabindex="0"
              class="dropdown-content menu bg-base-100 rounded-box z-[1] w-72 p-2 shadow-lg border border-base-200 mt-2 overflow-hidden"
            >
              <%= for project <- Enum.take(@recent_projects, 8) do %>
                <li>
                  <button
                    phx-click="select_project"
                    phx-value-path={project.path}
                    class="flex items-center gap-2"
                  >
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

  attr(:prompt, :string, default: "")
  attr(:mode, :string, default: "genesis_new")
  attr(:mode_info, :string, default: "")
  attr(:node_path, :string, default: "")
  attr(:seeds, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:show_advanced, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:archive, :boolean, default: false)
  attr(:model_profiles, :list, default: [])
  attr(:selected_model_id, :string, default: nil)

  def task_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-submit="task_submit"
      class="bg-base-100 rounded-2xl shadow-sm border border-base-200"
    >
      <!-- Body -->
      <div class={["p-4 sm:p-5 space-y-4", @disabled && "opacity-50 pointer-events-none select-none"]}>
        <!-- Task mode & model selectors in one card -->
        <div class="bg-base-200/50 rounded-xl p-4 border border-base-300">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <!-- Task Mode -->
            <div class="flex flex-col sm:flex-row sm:items-center gap-3">
              <label class="text-base font-bold text-base-content whitespace-nowrap flex items-center gap-2">
                <.icon name="hero-cpu-chip" class="size-5 text-primary" />
                {gettext("Task Mode")}
              </label>
              <select
                name="mode"
                phx-change="task_change"
                class="select select-bordered select-md w-full sm:w-auto flex-1 focus:outline-none focus:ring-2 focus:ring-primary/50 font-semibold bg-base-100 shadow-sm"
              >
                <option value="genesis_existing" selected={@mode == "genesis_existing"}>
                  {gettext("Initialize Existing Codebase")}
                </option>
                <option value="genesis_new" selected={@mode == "genesis_new"}>
                  {gettext("Create New Codebase")}
                </option>
                <option value="evolve_simple" selected={@mode == "evolve_simple"}>
                  {gettext("Evolution")}
                </option>
              </select>
              <div class="hidden sm:block">
                <.tip text={mode_description(@mode)} />
              </div>
              <p class="text-sm text-base-content/60 mt-1 sm:hidden">{mode_description(@mode)}</p>
            </div>

            <!-- Model -->
            <%= if @model_profiles != [] do %>
              <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                <label class="text-base font-bold text-base-content whitespace-nowrap flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="size-5 text-primary" />
                  {gettext("Model")}
                </label>
                <select
                  name="model_id"
                  phx-change="select_model"
                  class="select select-bordered select-md w-full sm:w-auto flex-1 focus:outline-none focus:ring-2 focus:ring-primary/50 font-semibold bg-base-100 shadow-sm"
                >
                  <%= for profile <- @model_profiles do %>
                    <option value={profile.id} selected={@selected_model_id == profile.id}>
                      {profile.id <> " (" <> (profile.model || "") <> ")"}
                    </option>
                  <% end %>
                </select>
                <div class="hidden sm:block">
                  <.tip text={gettext("Select which model profile to use for this task")} />
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%= if String.starts_with?(@mode, "evolve") do %>
          <div class="rounded-xl border border-base-200 bg-base-200/30">
            <button
              type="button"
              class={"w-full px-4 py-3 cursor-pointer hover:bg-base-200/50 transition-colors flex items-center gap-2 rounded-t-xl #{if @show_advanced, do: "", else: "rounded-b-xl"}"}
              phx-click="toggle_advanced"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/60" />
              <span class="text-sm font-semibold text-base-content">{gettext("Advanced Options")}</span>
              <.icon
                name="hero-chevron-down"
                class={"size-4 text-base-content/40 ml-auto transition-transform #{if @show_advanced, do: "rotate-180", else: ""}"}
              />
            </button>
            <%= if @show_advanced do %>
              <div class="px-4 pb-4 pt-2 space-y-4 border-t border-base-200 rounded-b-xl">
                <div class="flex flex-col md:flex-row gap-4">
                  <div class="form-control flex-1">
                    <label class="label">
                      <span class="label-text font-semibold text-base-content">{gettext(
                        "Starting Node"
                      )}
                      <.tip text={
                        gettext(
                          "The subdirectory within the project to start evolution from. Use './' for root."
                        )
                      } /></span>
                    </label>
                    <input
                      type="text"
                      name="node_path"
                      value={@node_path}
                      class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
                      placeholder={gettext("e.g., ./src/components")}
                    />
                    <label class="label">
                      <span class="label-text-alt text-base-content/50">{gettext(
                        "Subdirectory to start evolution from (optional)"
                      )}</span>
                    </label>
                  </div>
                  <div class="form-control flex-1">
                    <label class="label">
                      <span class="label-text font-semibold text-base-content">{gettext(
                        "Starting Commit"
                      )}
                      <.tip text={
                        gettext(
                          "A Git commit SHA, branch name, or tag to use as the base. Defaults to HEAD."
                        )
                      } /></span>
                    </label>
                    <input
                      type="text"
                      name="starting_commit"
                      value={@starting_commit}
                      class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
                      placeholder={gettext("e.g., abc1234 or HEAD")}
                    />
                    <label class="label">
                      <span class="label-text-alt text-base-content/50">{gettext(
                        "Commit SHA or ref to start from (defaults to HEAD)"
                      )}</span>
                    </label>
                  </div>
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold text-base-content">{gettext("Resume from")}
                    <.tip text={
                      gettext(
                        "The ID of a previous task to continue from. Injects the previous task's context (commits, objective, and result) into this task's objective."
                      )
                    } /></span>
                  </label>
                  <input
                    type="text"
                    name="resume_from"
                    value={@resume_from}
                    class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary/30 bg-base-200/30"
                    placeholder="a1b2c3d4"
                  />
                  <label class="label">
                    <span class="label-text-alt text-base-content/50">{gettext(
                      "Previous task ID to continue from (optional)"
                    )}</span>
                  </label>
                </div>
              </div>
            <% end %>
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

        <!-- Inline execute button -->
        <div class="flex items-center justify-between gap-4">
          <label class="label cursor-pointer flex items-center gap-3 justify-start">
            <input
              type="checkbox"
              name="archive"
              value="true"
              class="checkbox checkbox-sm checkbox-primary"
            />
            <span class="label-text text-sm font-medium text-base-content/70">{gettext(
              "Archive agent details"
            )}</span>
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full sm:w-auto"
            disabled={@disabled}
          >
            <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Execute Task")}
          </button>
        </div>
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # project_settings_panel/1 — Integrated project settings
  # ---------------------------------------------------------------------------

  attr(:active_project, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:project_config, :map, default: nil)
  attr(:worktree_script, :string, default: nil)
  attr(:commands, :map, default: %{})
  attr(:foreign_repos, :list, default: [])
  attr(:show_add_foreign_repo, :boolean, default: false)
  attr(:new_repo_id, :string, default: "")
  attr(:new_repo_path, :string, default: "")
  attr(:new_repo_description, :string, default: "")

  def project_settings_panel(assigns) do
    ~H"""
    <details class="group rounded-2xl overflow-hidden" open={@show}>
      <summary class="bg-base-100 shadow-sm border border-base-200 p-4 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-3 list-none">
        <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/60" />
        <span class="font-semibold">{gettext("Project Settings")}</span>
        <div class="flex-1"></div>
        <!-- Config status indicator -->
        <%= if @project_config do %>
          <span class="badge badge-success badge-sm gap-1">
            <.icon name="hero-check-circle" class="size-3" /> {gettext("genesis.toml")}
          </span>
        <% else %>
          <span class="badge badge-ghost badge-sm gap-1">
            <.icon name="hero-document-text" class="size-3" /> {gettext("Defaults")}
          </span>
        <% end %>
        <.icon
          name="hero-chevron-down"
          class="size-4 text-base-content/40 group-open:rotate-180 transition-transform"
        />
      </summary>

      <div class="bg-base-100 border border-t-0 border-base-200 p-4 sm:p-6 space-y-4">
        <!-- Config Info -->
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
            <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">
              {gettext("Project Root")}
            </p>
            <p class="text-sm font-mono mt-1 truncate">{@active_project}</p>
          </div>
          <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
            <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">
              {gettext("Configuration")}
            </p>
            <p class="text-sm mt-1">
              <%= if @project_config do %>
                <span class="text-success flex items-center gap-1">
                  <.icon name="hero-check-circle" class="size-4" /> {gettext(
                    "genesis.toml found — using project settings"
                  )}
                </span>
              <% else %>
                <span class="text-base-content/50 flex items-center gap-1">
                  <.icon name="hero-information-circle" class="size-4" /> {gettext(
                    "No genesis.toml — using global defaults"
                  )}
                </span>
              <% end %>
            </p>
          </div>
        </div>

        <%= if @worktree_script do %>
          <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
            <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">
              {gettext("Worktree Init Script")}
            </p>
            <p class="text-sm font-mono mt-1">{@worktree_script}</p>
          </div>
        <% end %>

        <%= if @commands != %{} do %>
          <div class="border-t border-base-200 pt-4">
            <h3 class="text-base font-semibold flex items-center gap-2 mb-3">
              <.icon name="hero-terminal" class="size-4 text-secondary" /> {gettext("Dev Commands")}
              <.tip text={
                gettext("Quick shortcuts for common development commands. Click Run to execute.")
              } />
            </h3>
            <div class="space-y-2">
              <%= for {name, cmd} <- Enum.sort(@commands) do %>
                <div class="flex items-center gap-2 bg-base-200/40 rounded-lg p-2.5 border border-base-200 border-l-2 border-l-accent/40">
                  <span class="badge badge-accent badge-sm font-mono">{name}</span>
                  <span class="text-sm font-mono flex-1 truncate">{cmd}</span>
                  <button
                    class="btn btn-ghost btn-xs btn-primary"
                    phx-click="run_command"
                    phx-value-command={name}
                  >
                    <.icon name="hero-play" class="size-3" /> {gettext("Run")}
                  </button>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <!-- Foreign Repos -->
        <div class="border-t border-base-200 pt-4">
          <h3 class="text-base font-semibold flex items-center gap-2 mb-3">
            <.icon name="hero-server-stack" class="size-4 text-secondary" /> {gettext(
              "Foreign Repositories"
            )}
            <.tip text={
              gettext(
                "Foreign repos are additional codebases accessible to agents during task execution. Useful for referencing original code or related projects."
              )
            } />
          </h3>

          <%= if @foreign_repos == [] do %>
            <div class="border-2 border-dashed border-base-300 rounded-xl p-6 text-center text-base-content/50">
              <.icon name="hero-server-stack" class="size-8 mx-auto mb-2 opacity-30" />
              <p class="text-sm font-medium">{gettext("No foreign repositories registered")}</p>
              <p class="text-xs mt-1">
                {gettext("Add repositories to allow agents to reference external code.")}
              </p>
            </div>
          <% else %>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <%= for repo <- @foreign_repos do %>
                <div class="bg-base-100 rounded-xl p-3 border border-base-200 shadow-sm relative group flex flex-col gap-1 hover:border-secondary/30 transition-colors">
                  <div class={"absolute left-0 top-0 bottom-0 w-1 rounded-l-xl #{if ForeignRepo.primary?(repo.id), do: "bg-primary", else: "bg-secondary/60"}"}>
                  </div>
                  <div class="flex items-center justify-between ml-2">
                    <span class={"badge #{if ForeignRepo.primary?(repo.id), do: "badge-primary", else: "badge-ghost"} badge-sm font-mono"}>
                      {repo.id}
                    </span>
                    <%= unless ForeignRepo.primary?(repo.id) do %>
                      <button
                        class="btn btn-ghost btn-xs text-error opacity-0 group-hover:opacity-100 transition-opacity"
                        phx-click="remove_foreign_repo"
                        phx-value-repo_id={repo.id}
                      >
                        <.icon name="hero-trash" class="size-3" />
                      </button>
                    <% end %>
                  </div>
                  <div class="ml-2 mt-1">
                    <span class="text-sm font-mono block truncate" title={repo.root}>{repo.root}</span>
                    <%= if repo.description do %>
                      <span class="text-xs text-base-content/50 block mt-1">{repo.description}</span>
                    <% end %>
                  </div>
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
                      <span class="label-text text-xs font-medium">{gettext("Repo ID")}
                      <.tip text={
                        gettext(
                          "A unique identifier for this repository (e.g., 'original', 'upstream')"
                        )
                      } /></span>
                    </label>
                    <input
                      type="text"
                      name="repo_id"
                      value={@new_repo_id}
                      placeholder="e.g., original"
                      class="input input-bordered input-sm w-full font-mono"
                      required
                    />
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text text-xs font-medium">{gettext("Path")}
                      <.tip text={gettext("Absolute path to the repository root on this machine")} /></span>
                    </label>
                    <div class="picker-container relative">
                      <input
                        type="text"
                        name="path"
                        value={@new_repo_path}
                        placeholder="/absolute/path/to/repo"
                        class="input input-bordered input-sm w-full font-mono pr-8"
                        required
                        id="foreign-repo-path-input"
                      />
                      <button
                        type="button"
                        id="foreign-repo-path-picker-button"
                        class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-primary transition-colors"
                        phx-click="pick_directory"
                        phx-hook="DirectoryPicker"
                        data-picker-id="foreign-repo"
                        title={gettext("Browse for directory")}
                      >
                        <.icon name="hero-folder-open" class="size-4" />
                      </button>
                    </div>
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text text-xs font-medium">{gettext("Description (optional)")}</span>
                    </label>
                    <input
                      type="text"
                      name="description"
                      value={@new_repo_description}
                      placeholder={gettext("Short description of what this repo does")}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                </div>
                <div class="flex gap-2">
                  <button type="submit" class="btn btn-primary btn-sm gap-1">
                    <.icon name="hero-plus" class="size-3" /> {gettext("Add")}
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm"
                    phx-click="toggle_add_foreign_repo_form"
                  >
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </div>
          <% else %>
            <button
              class="btn btn-sm btn-outline btn-secondary gap-1 mt-3"
              phx-click="toggle_add_foreign_repo_form"
            >
              <.icon name="hero-plus-circle" class="size-4" /> {gettext("Add Foreign Repo")}
            </button>
          <% end %>
        </div>
      </div>
    </details>
    """
  end

  # ---------------------------------------------------------------------------
  # task_card/1 — Compact card with accent bar, relative timestamps
  # ---------------------------------------------------------------------------

  attr(:task, :map, required: true)
  attr(:show_details, :boolean, default: false)

  def task_card(assigns) do
    ~H"""
    <div class={[
      "bg-base-100 rounded-lg shadow-sm hover:shadow-md transition-shadow border border-base-200/60 relative z-10 group has-[[open]]:z-30",
      task_card_tint(@task)
    ]}>
      <!-- Accent Top Border — clipped by inner wrapper so it respects rounded corners -->
      <div class="absolute inset-0 rounded-lg overflow-hidden pointer-events-none">
        <div class={["absolute top-0 left-0 right-0 h-1 opacity-80", task_accent_color(@task)]}></div>
      </div>

      <div class="p-4 flex flex-col gap-5">
        <!-- Top row: Metatags & Status -->
        <div class="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
          <div class="flex flex-wrap items-center gap-2.5 mt-1">
            <span class="text-xs font-bold tracking-widest uppercase text-base-content/50">{@task.type}</span>
            <span class="w-1 h-1 rounded-full bg-base-content/20"></span>
            <span class="text-xs font-mono font-medium text-base-content/50">{@task.opts[:mode]}</span>
            <span class="w-1 h-1 rounded-full bg-base-content/20"></span>
            <span class="text-xs font-mono text-base-content/40">#{String.slice(@task.id, 0, 8)}</span>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <%= if Map.get(@task, :review_status) do %>
              <span class={[
                "badge border-0 font-medium px-2.5 py-2 rounded-md",
                review_status_badge(Map.get(@task, :review_status))
              ]}>
                <.icon
                  name={review_status_icon(Map.get(@task, :review_status))}
                  class="size-4 mr-1.5"
                />
                {review_status_label(Map.get(@task, :review_status))}
              </span>
            <% end %>
            <span class={[
              "badge",
              task_status_badge(@task.status),
              "font-medium border-0 px-2.5 py-2 rounded-md"
            ]}>
              <%= if @task.status == :running do %>
                <span class="relative flex h-2.5 w-2.5 mr-2">
                  <span
                    class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75"
                    style="animation-duration: 2s"
                  ></span>
                  <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-success"></span>
                </span>
              <% end %>
              <%= if @task.status == :finalizing do %>
                <span class="loading loading-spinner loading-xs mr-2"></span>
              <% end %>
              <%= cond do %>
                <% @task.status == :finalizing -> %>
                  Finalizing
                <% true -> %>
                  {@task.status}
              <% end %>
            </span>
          </div>
        </div>

        <!-- Middle row: Objective text -->
        <div class="pr-2 -mt-2">
          <% objective_text = @task.opts[:prompt] || @task.opts[:objective] || "" %>
          <%= if objective_text != "" do %>
            <p
              class="text-base text-base-content/90 font-medium leading-relaxed line-clamp-2"
              title={objective_text}
            >
              {objective_text}
            </p>
          <% else %>
            <p
              class="text-base text-base-content/90 font-medium leading-relaxed line-clamp-2"
              title={task_description(@task)}
            >
              {task_description(@task)}
            </p>
          <% end %>
        </div>

        <!-- Bottom row: Time, Actions, Menu -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pt-4 border-t border-base-200/60">
          <div class="flex items-center gap-4 text-xs font-medium text-base-content/50">
            <span class="flex items-center gap-1.5">
              <.icon name="hero-play" class="size-4 opacity-60" />
              {gettext("Started")} {relative_time(@task.started_at)}
            </span>
            <%= if Map.get(@task, :finished_at) do %>
              <span class="flex items-center gap-1.5">
                <.icon name="hero-stop" class="size-4 opacity-60" />
                {gettext("Finished")} {relative_time(@task.finished_at)}
              </span>
            <% end %>
            <%= if Map.get(@task, :agent_count) do %>
              <span class="flex items-center gap-1.5">
                <.icon name="hero-user-group" class="size-4 opacity-60" />
                {gettext("%{count} Agents", count: @task.agent_count)}
              </span>
            <% end %>
          </div>

          <div class="flex items-center gap-2 sm:gap-3">
            <%= if @task.status in [:running, :finalizing] do %>
              <button
                class="btn btn-sm btn-outline btn-error border-error/30 hover:border-error hover:bg-error/10 hover:text-error rounded-md px-4"
                phx-click="cancel_task"
                phx-value-task_id={@task.id}
                phx-confirm={gettext("Are you sure you want to cancel this task?")}
              >
                <.icon name="hero-x-mark" class="size-4 mr-1" /> {gettext("Cancel")}
              </button>
            <% end %>

            <%= if show_review_button?(@task) do %>
              <.link
                navigate={~p"/review/#{@task.id}"}
                class="btn btn-sm btn-primary rounded-md px-5 shadow-sm hover:shadow-md hover:-translate-y-0.5 transition-all"
              >
                <.icon name="hero-eye" class="size-4 mr-1" /> {gettext("Review")}
              </.link>
            <% end %>

            <button
              class={[
                "btn btn-sm rounded-md px-4 font-medium transition-all",
                (@show_details && "btn-neutral shadow-sm") ||
                  "btn-ghost bg-base-200/50 hover:bg-base-200"
              ]}
              phx-click="toggle_task_details"
              phx-value-task_id={@task.id}
            >
              <%= if @show_details do %>
                {gettext("Hide Details")} <.icon name="hero-chevron-up" class="size-4 ml-1.5" />
              <% else %>
                {gettext("Details")} <.icon name="hero-chevron-down" class="size-4 ml-1.5" />
              <% end %>
            </button>

            <details class="dropdown dropdown-end dropdown-top sm:dropdown-bottom">
              <summary class="btn btn-sm btn-ghost btn-circle rounded-md hover:bg-base-200">
                <.icon name="hero-ellipsis-vertical" class="size-4" />
              </summary>
              <ul class="menu menu-sm dropdown-content mt-1 z-50 p-2 shadow-lg bg-base-100 rounded-lg w-40 border border-base-200">
                <li>
                  <button
                    class="text-error hover:bg-error/10 hover:text-error rounded-md"
                    phx-click="delete_task"
                    phx-value-task_id={@task.id}
                    phx-confirm={gettext("Delete this task?")}
                  >
                    <.icon name="hero-trash" class="size-4 mr-2" /> {gettext("Delete")}
                  </button>
                </li>
              </ul>
            </details>
          </div>
        </div>

        <%= if @show_details do %>
          <div class="border-t border-base-200 pt-3 mt-1">
            <div class="space-y-4">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <div class="flex items-center justify-between mb-4">
                    <h4 class="text-sm font-bold flex items-center gap-2">
                      <.icon name="hero-cog-8-tooth" class="size-4.5 text-primary" /> {gettext(
                        "Options"
                      )}
                    </h4>
                    <button
                      class="btn btn-xs btn-ghost rounded-md"
                      phx-click="view_full_options"
                      phx-value-task_id={@task.id}
                    >
                      <.icon name="hero-arrows-pointing-out" class="size-3.5 mr-1" /> {gettext("Full")}
                    </button>
                  </div>
                  {render_options(@task.opts)}
                </div>
                <%= if Map.get(@task, :result) do %>
                  <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                    <div class="flex items-center justify-between mb-4">
                      <h4 class="text-sm font-bold flex items-center gap-2">
                        <.icon name="hero-check-badge" class="size-4.5 text-success" /> {gettext(
                          "Result"
                        )}
                      </h4>
                      <button
                        class="btn btn-xs btn-ghost rounded-md"
                        phx-click="view_full_result"
                        phx-value-task_id={@task.id}
                      >
                        <.icon name="hero-arrows-pointing-out" class="size-3.5 mr-1" /> {gettext(
                          "Full"
                        )}
                      </button>
                    </div>
                    {render_result(@task.result)}
                  </div>
                <% end %>
              </div>

              <%= if Map.get(@task, :usage) do %>
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <h4 class="text-sm font-bold flex items-center gap-2 mb-4">
                    <.icon name="hero-currency-dollar" class="size-4.5 text-primary" /> {gettext(
                      "Token & Cost Usage"
                    )}
                  </h4>
                  <div class="grid grid-cols-3 gap-3">
                    <div>
                      <div class="text-xs text-base-content/50 mb-1">{gettext("Input Tokens")}</div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.input_tokens)}
                      </div>
                    </div>
                    <div>
                      <div class="text-xs text-base-content/50 mb-1">{gettext("Output Tokens")}</div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.output_tokens)}
                      </div>
                    </div>
                    <div>
                      <div class="text-xs text-base-content/50 mb-1">{gettext("Total Tokens")}</div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.total_tokens)}
                      </div>
                    </div>
                  </div>
                  <%= if Map.get(@task.usage, :cached_tokens, 0) > 0 or Map.get(@task.usage, :cache_creation_tokens, 0) > 0 do %>
                    <div class="mt-4 pt-4 border-t border-base-200">
                      <div class="grid grid-cols-3 gap-3">
                        <div>
                          <div class="text-xs text-base-content/50 mb-1">
                            {gettext("Cached Tokens")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(@task.usage, :cached_tokens, 0))}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/50 mb-1">
                            {gettext("Cache Creation")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(@task.usage, :cache_creation_tokens, 0))}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/50 mb-1">
                            {gettext("Cache Hit Rate")}
                          </div>
                          <div class="text-sm font-semibold text-success">
                            {format_cache_hit_rate(@task.usage)}
                          </div>
                          <progress
                            class="progress progress-success w-full mt-1"
                            value={
                              if @task.usage.input_tokens > 0,
                                do:
                                  min(
                                    round(
                                      Map.get(@task.usage, :cached_tokens, 0) /
                                        @task.usage.input_tokens * 100
                                    ),
                                    100
                                  ),
                                else: 0
                            }
                            max="100"
                          ></progress>
                        </div>
                      </div>
                    </div>
                  <% end %>
                  <div class="mt-4 pt-4 border-t border-base-200">
                    <div class="grid grid-cols-3 gap-3">
                      <div>
                        <div class="text-xs text-base-content/50 mb-1">{gettext("Input Cost")}</div>
                        <div class="text-sm font-semibold">
                          ${format_cost(@task.usage.input_cost)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-base-content/50 mb-1">{gettext("Output Cost")}</div>
                        <div class="text-sm font-semibold">
                          ${format_cost(@task.usage.output_cost)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-base-content/50 mb-1">{gettext("Total Cost")}</div>
                        <div class="text-sm font-semibold text-primary">
                          ${format_cost(@task.usage.total_cost)}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <%= if Map.get(@task, :agent_count) do %>
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <h4 class="text-sm font-bold flex items-center justify-between gap-2 mb-4">
                    <span class="flex items-center gap-2">
                      <.icon name="hero-user-group" class="size-4.5 text-primary" /> {gettext(
                        "Agents Spawned"
                      )}
                    </span>
                    <%= if @task.opts[:model_id] do %>
                      <span class="text-xs font-medium text-base-content/50">
                        {gettext("Model")}: {@task.opts[:model_id]}
                      </span>
                    <% end %>
                  </h4>
                  <div class="flex items-center gap-3">
                    <span class="text-2xl font-bold text-primary">{format_number(@task.agent_count)}</span>
                    <span class="text-xs text-base-content/50">{gettext(
                      "total agents (incl. subagents)"
                    )}</span>
                  </div>
                </div>
              <% end %>

              <%= if @task.logs != [] do %>
                <% log_count = length(@task.logs) %>
                <details class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors group/logs">
                  <summary class="cursor-pointer text-sm font-bold flex items-center gap-2 select-none outline-none">
                    <.icon
                      name="hero-command-line"
                      class="size-4.5 text-base-content/70 group-hover/logs:text-primary transition-colors"
                    />
                    {gettext("Execution Logs")}
                    <span class="text-xs font-medium text-base-content/50 bg-base-300 px-2 py-0.5 rounded-md ml-2">
                      {if log_count > 20,
                        do: gettext("last 20 of %{count}", count: log_count),
                        else: gettext("%{count}", count: log_count)}
                    </span>
                  </summary>
                  <div class="bg-neutral text-neutral-content p-4 rounded-md max-h-72 overflow-y-auto text-xs font-mono space-y-1 mt-4 shadow-inner">
                    <%= for {log, idx} <- Enum.with_index(Enum.reverse(@task.logs)) do %>
                      <div class={[
                        "flex items-start gap-3 p-1.5 rounded transition-colors",
                        rem(idx, 2) == 0 && "bg-black/10",
                        log.level == :error && "text-error-content bg-error/20",
                        log.level == :warn && "text-warning-content bg-warning/20"
                      ]}>
                        <span class="opacity-50 shrink-0 select-none">
                          [{format_datetime(log.timestamp, :time)}]
                        </span>
                        <span class={[
                          "font-bold shrink-0 w-12 select-none",
                          log.level == :error && "text-error",
                          log.level == :warn && "text-warning",
                          log.level == :info && "text-info"
                        ]}>
                          {String.upcase(to_string(log.level))}
                        </span>
                        <span class="break-words font-medium opacity-90">
                          {log.message}
                        </span>
                      </div>
                    <% end %>
                  </div>
                </details>
              <% end %>

              <%= if Map.get(@task, :archive_metadata) not in [nil, []] do %>
                <.archive_details
                  archive_metadata={Map.get(@task, :archive_metadata)}
                  task_id={@task.id}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_details/1 — Per-agent archive records section (opt-in)
  # ---------------------------------------------------------------------------

  attr(:archive_metadata, :list, default: nil)
  attr(:task_id, :string, default: nil)

  def archive_details(assigns) do
    ~H"""
    <%= if @archive_metadata != nil and @archive_metadata != [] do %>
      <div class="bg-base-200/30 p-5 rounded-2xl border border-base-200/80 hover:border-base-300 transition-colors">
        <div class="flex items-center justify-between mb-4">
          <h4 class="text-sm font-bold flex items-center gap-2">
            <.icon name="hero-archive-box" class="size-4.5 text-primary" /> {gettext(
              "Archived Agent Details"
            )}
          </h4>
          <%= if @task_id do %>
            <.link
              href={"/tasks/#{@task_id}/export"}
              class="btn btn-sm btn-outline btn-primary rounded-full"
              download
            >
              <.icon name="hero-arrow-down-tray" class="size-4 mr-1" /> {gettext("Export JSON")}
            </.link>
          <% end %>
        </div>
        <.archive_tree agents={@archive_metadata} />
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_tree/1 — Renders the nested parent-child agent hierarchy
  # ---------------------------------------------------------------------------

  attr(:agents, :list, required: true)

  def archive_tree(assigns) do
    roots = build_archive_tree(assigns.agents)
    assigns = assign(assigns, :roots, roots)

    ~H"""
    <div class="space-y-3">
      <%= for node <- @roots do %>
        <.archive_tree_node agent={node.agent} children={node.children} />
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_tree_node/1 — Recursive node renderer for a single archived agent
  # ---------------------------------------------------------------------------

  attr(:agent, :map, required: true)
  attr(:children, :list, default: [])

  def archive_tree_node(assigns) do
    ~H"""
    <div class="border border-base-200 rounded-xl bg-base-100/60 overflow-hidden">
      <div class="p-4 space-y-3">
        <!-- Agent ID + depth badge -->
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-bold font-mono text-sm text-base-content">{@agent[:agent_id]}</span>
          <%= if @agent[:depth] do %>
            <span class="badge badge-ghost badge-sm font-mono">{gettext("Depth")}: {@agent[:depth]}</span>
          <% end %>
        </div>

        <!-- Objective -->
        <%= if @agent[:objective] not in [nil, ""] do %>
          <div>
            <div class="text-xs text-base-content/50 mb-0.5">{gettext("Objective")}</div>
            <div class="text-sm text-base-content/90 whitespace-pre-wrap break-words">
              {@agent[:objective]}
            </div>
          </div>
        <% end %>

        <!-- Result -->
        <%= if @agent[:result] not in [nil, ""] do %>
          <div>
            <div class="text-xs text-base-content/50 mb-0.5">{gettext("Result")}</div>
            <div class="text-sm text-base-content/90 whitespace-pre-wrap break-words">
              {@agent[:result]}
            </div>
          </div>
        <% end %>

        <!-- Commits -->
        <div class="flex flex-wrap gap-x-6 gap-y-1">
          <%= if @agent[:base_commit] not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/50">{gettext("Start Commit")}: </span>
              <span class="text-xs font-mono">{@agent[:base_commit]}</span>
            </div>
          <% end %>
          <%= if @agent[:final_commit] not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/50">{gettext("End Commit")}: </span>
              <span class="text-xs font-mono">{@agent[:final_commit]}</span>
            </div>
          <% end %>
        </div>

        <!-- Archive refs -->
        <div class="flex flex-wrap gap-x-6 gap-y-1">
          <%= if @agent[:archive_ref_start] not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/50">{gettext("Archive Start Ref")}: </span>
              <span class="text-xs font-mono">{@agent[:archive_ref_start]}</span>
            </div>
          <% end %>
          <%= if @agent[:archive_ref_final] not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/50">{gettext("Archive Final Ref")}: </span>
              <span class="text-xs font-mono">{@agent[:archive_ref_final]}</span>
            </div>
          <% end %>
        </div>

        <%= if @agent[:branch_name] not in [nil, ""] do %>
          <div>
            <span class="text-xs text-base-content/50">{gettext("Branch")}: </span>
            <span class="text-xs font-mono">{@agent[:branch_name]}</span>
          </div>
        <% end %>

        <!-- Token usage -->
        <%= if @agent[:usage] do %>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 pt-2 border-t border-base-200">
            <div>
              <div class="text-xs text-base-content/50">{gettext("Input Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(@agent[:usage][:input_tokens] || 0)}
              </div>
            </div>
            <div>
              <div class="text-xs text-base-content/50">{gettext("Output Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(@agent[:usage][:output_tokens] || 0)}
              </div>
            </div>
            <div>
              <div class="text-xs text-base-content/50">{gettext("Total Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(@agent[:usage][:total_tokens] || 0)}
              </div>
            </div>
            <div>
              <div class="text-xs text-base-content/50">{gettext("Cost")}</div>
              <div class="text-sm font-semibold">${format_cost(@agent[:usage][:cost] || 0)}</div>
            </div>
          </div>
        <% end %>

        <!-- Timestamps -->
        <%= if @agent[:started_at] || @agent[:completed_at] do %>
          <div class="flex flex-wrap gap-x-6 gap-y-1 pt-2 border-t border-base-200">
            <%= if @agent[:started_at] do %>
              <div>
                <span class="text-xs text-base-content/50">{gettext("Started")}: </span>
                <span class="text-xs">{format_datetime(@agent[:started_at])}</span>
              </div>
            <% end %>
            <%= if @agent[:completed_at] do %>
              <div>
                <span class="text-xs text-base-content/50">{gettext("Completed")}: </span>
                <span class="text-xs">{format_datetime(@agent[:completed_at])}</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%= if @children != [] do %>
        <div class="pl-5 border-l-2 border-base-200 ml-4 space-y-3 mb-3">
          <%= for child <- @children do %>
            <.archive_tree_node agent={child.agent} children={child.children} />
          <% end %>
        </div>
      <% end %>
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
  defp task_accent_color(%{status: :completed, review_status: :ignored}), do: "bg-base-300"
  defp task_accent_color(%{status: status}), do: status_accent_color(status)

  defp task_card_tint(%{status: :running}), do: "bg-success/5 shadow-success/10 border-success/20"

  defp task_card_tint(%{status: :completed, review_status: :merged}),
    do: "bg-success/5 shadow-success/10 border-success/20"

  defp task_card_tint(%{status: :completed, review_status: :rejected}),
    do: "bg-error/5 shadow-error/10 border-error/20"

  defp task_card_tint(%{status: :completed, review_status: :continued}),
    do: "bg-info/5 shadow-info/10 border-info/20"

  defp task_card_tint(%{status: :completed, review_status: :ignored}),
    do: "bg-base-200/40 shadow-base-300/10 border-base-300/20"

  defp task_card_tint(%{status: :completed}), do: "bg-info/5 shadow-info/10 border-info/20"

  defp task_card_tint(%{status: :finalizing}),
    do: "bg-orange-500/5 shadow-orange-500/10 border-orange-500/20"

  defp task_card_tint(%{status: :failed}), do: "bg-error/5 shadow-error/10 border-error/20"
  defp task_card_tint(_), do: ""

  defp review_status_badge(:merged), do: "bg-success/10 text-success"
  defp review_status_badge(:rejected), do: "bg-error/10 text-error"
  defp review_status_badge(:continued), do: "bg-info/10 text-info"
  defp review_status_badge(:ignored), do: "bg-warning/10 text-warning"
  defp review_status_badge(_), do: "bg-base-200 text-base-content/70"

  defp review_status_icon(:merged), do: "hero-check-circle"
  defp review_status_icon(:rejected), do: "hero-x-circle"
  defp review_status_icon(:continued), do: "hero-arrow-path"
  defp review_status_icon(:ignored), do: "hero-eye-slash"
  defp review_status_icon(_), do: "hero-question-mark-circle"

  defp review_status_label(:merged), do: gettext("Merged")
  defp review_status_label(:rejected), do: gettext("Rejected")
  defp review_status_label(:continued), do: gettext("Continued")
  defp review_status_label(:ignored), do: gettext("Ignored")
  defp review_status_label(_), do: gettext("Unknown")

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
            {@mode}
          </span>
        <% end %>
        <%= if @path != "" do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-folder" class="size-3 mr-1" />
            {@path}
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
        <p class="text-sm text-warning">
          {gettext("The agent completed without making any changes to the codebase.")}
        </p>
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
            {String.slice(@commit_sha, 0..7)}
          </span>
        <% end %>
        <%= if @tag do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-tag" class="size-3 mr-1" />
            {@tag}
          </span>
        <% end %>
        <%= if @branch_name do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-code-bracket-square" class="size-3 mr-1" />
            {@branch_name}
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
          {@primary_text}
        </div>
      </div>
      <div class="flex flex-wrap gap-2 text-xs">
        <%= if @mode != "" do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-cog-6-tooth" class="size-3 mr-1" />
            {@mode}
          </span>
        <% end %>
        <%= if @path != "" do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-folder" class="size-3 mr-1" />
            {@path}
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
        <p class="text-sm text-warning">
          {gettext("The agent completed without making any changes to the codebase.")}
        </p>
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

  def render_result_full(%{result: result, commit_sha: commit_sha} = data)
      when is_binary(result) do
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
            {@branch_name}
          </span>
        <% end %>
        <%= if @commit_sha do %>
          <span class="badge badge-ghost font-mono text-sm">
            <.icon name="hero-code-bracket" class="size-4 mr-1" />
            {String.slice(@commit_sha, 0..7)}
          </span>
        <% end %>
        <%= if @tag do %>
          <span class="badge badge-ghost font-mono text-sm">
            <.icon name="hero-tag" class="size-4 mr-1" />
            {@tag}
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

  defp show_review_button?(%{status: :completed, result: {:ok, %{branch_name: branch}}})
       when is_binary(branch) and branch != "", do: true

  defp show_review_button?(_), do: false

  # ---------------------------------------------------------------------------
  # Private helpers — archive tree construction
  # ---------------------------------------------------------------------------

  defp build_archive_tree(agents) when is_list(agents) do
    agents = Enum.map(agents, &normalize_agent_keys/1)
    by_parent = Enum.group_by(agents, &agent_key(&1, :parent_id))

    by_parent
    |> Map.get(nil, [])
    |> Enum.filter(&(agent_key(&1, :agent_id) not in [nil, ""]))
    |> Enum.map(fn agent -> build_archive_node(agent, by_parent, MapSet.new()) end)
  end

  defp build_archive_node(agent, by_parent, visited) do
    id = agent_key(agent, :agent_id)

    children =
      if id in [nil, ""] do
        []
      else
        new_visited = MapSet.put(visited, id)

        by_parent
        |> Map.get(id, [])
        |> Enum.filter(fn child ->
          child_id = agent_key(child, :agent_id)
          child_id not in [nil, ""] and not MapSet.member?(new_visited, child_id)
        end)
        |> Enum.map(fn child -> build_archive_node(child, by_parent, new_visited) end)
      end

    %{agent: agent, children: children}
  end

  # Read a value from an agent map regardless of whether keys are atoms or strings.
  defp agent_key(agent, key) when is_atom(key) do
    case Map.fetch(agent, key) do
      {:ok, v} -> v
      :error -> Map.get(agent, Atom.to_string(key))
    end
  end

  # Normalize an agent map's top-level string keys to atoms so that both
  # tree-building and the HEEx renderers (which use atom-key access) work
  # uniformly. Only known keys (in the whitelist below) are converted; unknown
  # string keys are left as-is. This avoids both dynamic atom creation and the
  # try/rescue around String.to_existing_atom/1.
  #
  # The data originates from the runtime archive_records (in-memory, atom keys)
  # or after a DB round-trip through Jason.decode (string keys). The whitelist
  # enumerates every key actually consumed by the tree-building and rendering
  # code in this module.
  @known_agent_keys %{
    "agent_id" => :agent_id,
    "parent_id" => :parent_id,
    "depth" => :depth,
    "started_at" => :started_at,
    "completed_at" => :completed_at,
    "objective" => :objective,
    "result" => :result,
    "base_commit" => :base_commit,
    "final_commit" => :final_commit,
    "archive_ref_start" => :archive_ref_start,
    "archive_ref_final" => :archive_ref_final,
    "branch_name" => :branch_name,
    "usage" => :usage,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "total_tokens" => :total_tokens,
    "cost" => :cost,
    "model" => :model,
    "spec" => :spec
  }

  defp normalize_agent_keys(agent) when is_map(agent) do
    Map.new(agent, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        {Map.get(@known_agent_keys, key, key), value}
    end)
  end

  defp normalize_agent_keys(agent), do: agent
end
