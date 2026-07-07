defmodule EvoDashWeb.ProjectComponents do
  @moduledoc """
  Project selection and settings components for the dashboard.
  """
  use EvoDashWeb, :html
  alias EvoGit.Core.ForeignRepo

  # ---------------------------------------------------------------------------
  # project_selector/1 — Project selection bar
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
    <div class="bg-base-100 rounded-xl p-4 border border-primary/20 shadow-sm">
      <div class="flex items-center gap-3 flex-wrap">
        <!-- Project icon + info -->
        <div class="flex items-center gap-2">
          <div class="bg-base-content/10 text-base-content/60 p-2 rounded-lg">
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

        <!-- New Project button -->
        <button class="btn btn-sm btn-outline btn-primary gap-1" phx-click="toggle_new_project_form">
          <.icon name="hero-plus-circle" class="size-4" />
          {gettext("New Project")}
        </button>
      </div>

      <!-- Inline Open Project Form (expandable) -->
      <%= if @show_open_form do %>
        <div class="mt-3 pt-3 border-t border-base-300/50 animate-slide-down">
          <.form for={%{}} phx-submit="open_project" class="flex flex-col sm:flex-row gap-2">
            <div class="flex-1 flex items-center gap-2">
              <%= if @tauri_detected do %>
                <button type="button" id="project-path-browse-button" class="btn btn-sm btn-warning gap-1" phx-click="pick_directory" phx-hook="DirectoryPicker" data-picker-id="project">
                  <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
                </button>
              <% end %>
              <div class="picker-container relative flex-1">
                <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-base-content/40">
                  <.icon name="hero-folder" class="size-4" />
                </div>
                <input
                  type="text"
                  name="path"
                  class="input input-bordered input-sm w-full pl-9 pr-9 focus:outline-none focus:ring-2 focus:ring-base-content/20 font-mono text-sm"
                  placeholder={platform_placeholder(@platform)}
                  autofocus
                  phx-hook="PathAutocomplete"
                  phx-change="path_input"
                  phx-debounce="150"
                  id="project-path-input"
                  list="path-suggestions"
                />
                <span class="label-text-alt text-base-content/50 text-xs mt-1 block">{gettext("Repository path on this machine")}</span>
                <datalist id="path-suggestions">
                  <%= for suggestion <- @path_suggestions do %>
                    <option value={suggestion}></option>
                  <% end %>
                </datalist>
              </div>
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

      <!-- Inline New Project Form (expandable) -->
      <%= if @show_new_project_form do %>
        <div class="mt-3 pt-3 border-t border-base-300/50 animate-slide-down">
          <.form for={%{}} phx-submit="create_project" class="flex flex-col gap-2">
            <!-- Location (parent directory) -->
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Location (parent directory)")}</span>
              </label>
              <div class="flex items-center gap-2">
                <%= if @tauri_detected do %>
                  <button type="button" id="new-project-location-browse-button" class="btn btn-sm btn-warning gap-1" phx-click="pick_directory" phx-hook="DirectoryPicker" data-picker-id="new-project">
                    <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
                  </button>
                <% end %>
                <div class="picker-container relative flex-1">
                  <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-base-content/40">
                    <.icon name="hero-folder" class="size-4" />
                  </div>
                  <input
                    type="text"
                    name="location"
                    class="input input-bordered input-sm w-full pl-9 pr-9 focus:outline-none focus:ring-2 focus:ring-base-content/20 font-mono text-sm"
                    placeholder={platform_parent_placeholder(@platform)}
                    autofocus
                    id="new-project-location-input"
                  />
                  <span class="label-text-alt text-base-content/50 text-xs mt-1 block">{gettext("Repository path on this machine")}</span>
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
              <button type="submit" class="btn btn-primary btn-sm gap-1">
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
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")

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
                    class="btn btn-ghost btn-xs"
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
                    <div class="flex items-center gap-2">
                      <%= if @tauri_detected do %>
                        <button type="button" id="foreign-repo-path-browse-button" class="btn btn-sm btn-warning gap-1" phx-click="pick_directory" phx-hook="DirectoryPicker" data-picker-id="foreign-repo">
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
                        <span class="label-text-alt text-base-content/50 text-xs mt-1 block">{gettext("Repository path on this machine")}</span>
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

  defp platform_placeholder("mac"), do: "/Users/username/my-project"
  defp platform_placeholder("windows"), do: "C:\\Users\\username\\my-project"
  defp platform_placeholder(_), do: "/home/user/my-project"

  defp platform_parent_placeholder("mac"), do: "/Users/username/projects"
  defp platform_parent_placeholder("windows"), do: "C:\\Users\\username\\projects"
  defp platform_parent_placeholder(_), do: "/home/user/projects"
end
