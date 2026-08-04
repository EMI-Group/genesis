defmodule EvoDashWeb.ProjectComponents do
  @moduledoc """
  Project selection and settings components for the dashboard.

  `project_selector/1` renders an **address-bar-style project control** (like
  Finder/GNOME Files or a browser address bar): a clickable display of the
  current project path that expands inline to reveal a path input, recent
  projects, and a new-project option. Sits inside the immersive sticky header.

  `project_settings_panel/1` (genesis.toml status, worktree script, dev
  commands, foreign repos) is a collapsible accordion that works at any
  width within the centered hero column.
  """
  use EvoDashWeb, :html
  alias EvoGit.Core.ForeignRepo

  # ---------------------------------------------------------------------------
  # project_selector/1 — Project header / empty state + open/new forms
  # ---------------------------------------------------------------------------

  attr(:active_project, :map, default: nil)
  attr(:recent_projects, :list, default: [])
  attr(:show_open_form, :boolean, default: false)
  attr(:show_new_project_form, :boolean, default: false)
  attr(:path_suggestions, :list, default: [])
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")

  def project_selector(assigns) do
    ~H"""
    <div>
      <!-- Address-bar-style project control -->
      <!-- When no form is open: clickable display of current project (or placeholder) -->
      <%= if !@show_open_form and !@show_new_project_form do %>
        <button
          type="button"
          phx-click="toggle_open_project_form"
          class="flex items-center gap-2 w-full min-w-0 bg-base-200/50 hover:bg-base-200 rounded-lg px-3 py-1.5 cursor-pointer transition-colors text-left"
        >
          <%= if @active_project do %>
            <.icon name="hero-folder" class="size-4 text-primary shrink-0" />
            <span class="text-sm font-bold text-base-content truncate leading-tight">
              {@active_project.name}
            </span>
            <span class="text-xs text-base-content/50 font-mono truncate hidden md:inline">
              {@active_project.path}
            </span>
          <% else %>
            <.icon name="hero-folder-open" class="size-4 text-base-content/40 shrink-0" />
            <span class="text-sm text-base-content/50 truncate">
              {gettext("Open a project...")}
            </span>
          <% end %>
          <.icon name="hero-chevron-down" class="size-3.5 text-base-content/40 shrink-0 ml-auto" />
        </button>
      <% end %>

      <!-- Inline Open Project Form (address bar expanded) -->
      <%= if @show_open_form do %>
        <div class="animate-slide-down">
          <.form for={%{}} phx-submit="open_project" class="flex flex-col gap-2">
            <div class="flex-1 flex items-center gap-2">
              <%= if @tauri_detected do %>
                <button
                  type="button"
                  id="project-path-browse-button"
                  class="btn btn-sm btn-warning gap-1 shrink-0"
                  phx-click="pick_directory"
                  phx-hook="DirectoryPicker"
                  data-picker-id="project"
                >
                  <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
                </button>
              <% end %>
              <div class="picker-container flex-1">
                <input
                  type="text"
                  name="path"
                  class="input input-bordered input-sm w-full pr-8 focus:outline-none focus:ring-2 focus:ring-base-content/20 font-mono text-sm"
                  placeholder={platform_placeholder(@platform)}
                  autofocus
                  phx-hook="PathAutocomplete"
                  phx-change="path_input"
                  phx-debounce="150"
                  id="project-path-input"
                  list="path-suggestions"
                />
                <datalist id="path-suggestions">
                  <%= for suggestion <- @path_suggestions do %>
                    <option value={suggestion}></option>
                  <% end %>
                </datalist>
              </div>
              <button type="button" class="btn btn-ghost btn-sm btn-circle shrink-0" phx-click="toggle_open_project_form">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <!-- Recent projects quick-select -->
            <%= if @recent_projects != [] do %>
              <div class="flex flex-wrap gap-1.5 items-center">
                <span class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40">
                  {gettext("Recent")}
                </span>
                <%= for project <- Enum.take(@recent_projects, 8) do %>
                  <button
                    type="button"
                    phx-click="select_project"
                    phx-value-path={project.path}
                    class="btn btn-xs btn-ghost font-medium normal-case text-base-content/70 hover:bg-base-200"
                  >
                    {project.name}
                  </button>
                <% end %>
                <!-- New project entry integrated into this area -->
                <button
                  type="button"
                  phx-click="toggle_new_project_form"
                  class="btn btn-xs btn-outline btn-primary font-medium normal-case gap-1"
                >
                  <.icon name="hero-plus" class="size-3" /> {gettext("New Project")}
                </button>
              </div>
            <% else %>
              <!-- New project entry when no recent projects exist -->
              <button
                type="button"
                phx-click="toggle_new_project_form"
                class="btn btn-xs btn-outline btn-primary font-medium normal-case gap-1 self-start"
              >
                <.icon name="hero-plus" class="size-3" /> {gettext("New Project")}
              </button>
            <% end %>

            <button type="submit" class="btn btn-primary btn-sm gap-1 self-start">
              <.icon name="hero-check" class="size-4" /> {gettext("Open")}
            </button>
          </.form>
        </div>
      <% end %>

      <!-- Inline New Project Form -->
      <%= if @show_new_project_form do %>
        <div class="p-3 rounded-xl border border-base-200 bg-base-100 shadow-sm animate-slide-down">
          <.form for={%{}} phx-submit="create_project" class="flex flex-col gap-2">
            <!-- Location (parent directory) -->
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Location (parent directory)")}</span>
              </label>
              <div class="flex items-center gap-2">
                <%= if @tauri_detected do %>
                  <button
                    type="button"
                    id="new-project-location-browse-button"
                    class="btn btn-sm btn-warning gap-1 shrink-0"
                    phx-click="pick_directory"
                    phx-hook="DirectoryPicker"
                    data-picker-id="new-project"
                  >
                    <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
                  </button>
                <% end %>
                <div class="picker-container flex-1">
                  <input
                    type="text"
                    name="location"
                    class="input input-bordered input-sm w-full focus:outline-none focus:ring-2 focus:ring-base-content/20 font-mono text-sm"
                    placeholder={platform_parent_placeholder(@platform)}
                    autofocus
                    id="new-project-location-input"
                  />
                </div>
              </div>
            </div>

            <!-- Project name -->
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Project name")}</span>
              </label>
              <input
                type="text"
                name="name"
                class="input input-bordered input-sm w-full font-mono text-sm"
                placeholder="my-new-project"
              />
            </div>

            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm flex-1 gap-1">
                <.icon name="hero-check" class="size-4" /> {gettext("Create")}
              </button>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle_new_project_form">
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # project_settings_panel/1 — Collapsible settings accordion
  #
  # Uses a native <details> element with open={@show} for the toggle.
  # Styled identically to the Advanced Options accordion in
  # TaskFormComponents for visual consistency. Works at any width within
  # the centered hero column layout.
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
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")

  def project_settings_panel(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="rounded-xl bg-base-100 border border-base-200 shadow-sm overflow-hidden">
        <div
          class="p-3.5 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-2"
          phx-click="toggle_project_settings"
          phx-value-project={@active_project}
        >
          <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/60" />
          <span class="text-sm font-semibold flex-1">{gettext("Project Settings")}</span>
          <!-- Config status indicator -->
          <%= if @project_config do %>
            <span class="badge badge-success badge-xs gap-0.5">
              <.icon name="hero-check-circle" class="size-3" /> {gettext("genesis.toml")}
            </span>
          <% else %>
            <span class="badge badge-ghost badge-xs gap-0.5">
              <.icon name="hero-document-text" class="size-3" /> {gettext("Defaults")}
            </span>
          <% end %>
          <.icon name="hero-chevron-up" class="size-4 text-base-content/40" />
        </div>

        <div class="p-4 pt-2 space-y-4 border-t border-base-200">
          <.project_settings_body {assigns} />
        </div>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # project_settings_tab/1 — "Project Settings" tab content for the config
  # dropdown. Renders the same body as project_settings_panel/1 but WITHOUT the
  # collapsible accordion header (the dropdown tab provides the framing).
  # ---------------------------------------------------------------------------

  def project_settings_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.project_settings_body {assigns} />
    </div>
    """
  end

  # Shared body content for both the legacy panel and the dropdown tab.
  defp project_settings_body(assigns) do
    ~H"""
    <!-- Config status -->
    <p class="text-sm">
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

    <!-- Project Root -->
    <div class="bg-base-200/40 rounded-lg p-2.5 border border-base-200">
      <p class="text-[11px] text-base-content/50 font-medium uppercase tracking-wide">
        {gettext("Project Root")}
      </p>
      <p class="text-xs font-mono mt-0.5 truncate">{@active_project}</p>
    </div>

    <%= if @worktree_script do %>
      <div class="bg-base-200/40 rounded-lg p-2.5 border border-base-200">
        <p class="text-[11px] text-base-content/50 font-medium uppercase tracking-wide">
          {gettext("Worktree Init Script")}
        </p>
        <p class="text-xs font-mono mt-0.5">{@worktree_script}</p>
      </div>
    <% end %>

    <!-- Dev Commands -->
    <%= if @commands != %{} do %>
      <div class="border-t border-base-200 pt-3">
        <h3 class="text-sm font-semibold flex items-center gap-2 mb-2">
          <.icon name="hero-terminal" class="size-4 text-secondary" /> {gettext("Dev Commands")}
          <.tip text={
            gettext("Quick shortcuts for common development commands. Click Run to execute.")
          } />
        </h3>
        <div class="space-y-1.5">
          <%= for {name, cmd} <- Enum.sort(@commands) do %>
            <div class="flex items-center gap-2 bg-base-200/40 rounded-lg p-2 border border-base-200 border-l-2 border-l-accent/40">
              <span class="badge badge-accent badge-sm font-mono">{name}</span>
              <span class="text-xs font-mono flex-1 truncate">{cmd}</span>
              <button class="btn btn-ghost btn-xs" phx-click="run_command" phx-value-command={name}>
                <.icon name="hero-play" class="size-3" /> {gettext("Run")}
              </button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <!-- Foreign Repos -->
    <div class="border-t border-base-200 pt-3">
      <h3 class="text-sm font-semibold flex items-center gap-2 mb-2">
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
        <div class="border-2 border-dashed border-base-300 rounded-lg p-4 text-center text-base-content/50">
          <.icon name="hero-server-stack" class="size-6 mx-auto mb-1 opacity-30" />
          <p class="text-xs font-medium">{gettext("No foreign repositories registered")}</p>
        </div>
      <% else %>
        <div class="space-y-2">
          <%= for repo <- @foreign_repos do %>
            <% accent_class =
              if ForeignRepo.primary?(repo.id), do: "bg-primary", else: "bg-secondary/60" %>
            <% badge_class =
              if ForeignRepo.primary?(repo.id), do: "badge-primary", else: "badge-ghost" %>
            <div class="bg-base-100 rounded-lg p-2.5 border border-base-200 relative group flex flex-col gap-1 hover:border-secondary/30 transition-colors">
              <div class={"absolute left-0 top-0 bottom-0 w-1 rounded-l-lg #{accent_class}"}></div>
              <div class="flex items-center justify-between ml-2">
                <span class={"badge #{badge_class} badge-sm font-mono"}>
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
                <span class="text-xs font-mono block truncate" title={repo.root}>{repo.root}</span>
                <%= if repo.description do %>
                  <span class="text-xs text-base-content/50 block mt-0.5">{repo.description}</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Add Foreign Repo -->
      <%= if @show_add_foreign_repo do %>
        <div class="mt-2 border border-base-200 rounded-lg p-3 bg-base-200/20 animate-slide-down">
          <.form for={%{}} phx-submit="add_foreign_repo" class="space-y-2">
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Repo ID")}
                <.tip text={
                  gettext("A unique identifier for this repository (e.g., 'original', 'upstream')")
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
              <div class="flex items-center gap-2">
                <%= if @tauri_detected do %>
                  <button
                    type="button"
                    id="foreign-repo-path-browse-button"
                    class="btn btn-sm btn-warning gap-1 shrink-0"
                    phx-click="pick_directory"
                    phx-hook="DirectoryPicker"
                    data-picker-id="foreign-repo"
                  >
                    <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
                  </button>
                <% end %>
                <div class="picker-container relative flex-1">
                  <input
                    type="text"
                    name="path"
                    value={@new_repo_path}
                    placeholder={platform_placeholder(@platform)}
                    class="input input-bordered input-sm w-full font-mono pr-8"
                    required
                    id="foreign-repo-path-input"
                  />
                </div>
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
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm flex-1 gap-1">
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
          class="btn btn-sm btn-outline btn-secondary w-full gap-1 mt-2"
          phx-click="toggle_add_foreign_repo_form"
        >
          <.icon name="hero-plus-circle" class="size-4" /> {gettext("Add Foreign Repo")}
        </button>
      <% end %>
    </div>
    """
  end

  defp platform_placeholder("mac"), do: "/Users/username/my-project"
  defp platform_placeholder("windows"), do: "C:\\Users\\username\\my-project"
  defp platform_placeholder(_), do: "/home/user/my-project"

  defp platform_parent_placeholder("mac"), do: "/Users/username/projects"
  defp platform_parent_placeholder("windows"), do: "C:\\Users\\username\\projects"
  defp platform_parent_placeholder(_), do: "/home/user/projects"
end
