defmodule EvoDashWeb.DashboardLive.RemoteView do
  @moduledoc """
  Remote-node chrome for the dashboard.

  `top_bar/1` is the immersive sticky app header with command palette project
  control (extracted from `EvoDashWeb.DashboardLive` when the dashboard gained
  remote-node support). When `remote` is set it shows the target-name badge on
  the right (where the Configure dropdown lives locally) and hides the
  Configure dropdown entirely.

  `connecting_state/1` and `error_state/1` are the full-page states shown
  while a selected remote target is connecting/bootstrapping or has failed
  (`:error`/`:disconnected` phase). They render NO project data and no task
  form — task launching and project management are local dashboard features.
  """

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # top_bar/1 — Immersive sticky app header with command palette project control.
  #
  # LEFT: command palette trigger (click to open centered overlay with search,
  # recent projects, open-by-path, and create-new-project).
  # RIGHT: a single "Configure" dropdown showing BOTH sections at once —
  # "Task Options" and "Project Settings" — with no tab bar. When `remote` is
  # set the Configure dropdown is replaced by the remote target-name badge.
  # ---------------------------------------------------------------------------

  attr(:active_project, :map, default: nil)
  attr(:active_project_path, :string, default: nil)
  attr(:recent_projects, :list, default: [])
  attr(:palette_open, :boolean, default: false)
  attr(:palette_search, :string, default: "")
  attr(:palette_mode, :atom, default: :menu)
  attr(:palette_selected_index, :integer, default: 0)
  attr(:path_suggestions, :list, default: [])
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")
  attr(:show_project_settings, :boolean, default: false)
  attr(:task_mode, :string, default: "genesis_new")
  attr(:task_node_path, :string, default: "")
  attr(:task_starting_commit, :string, default: "")
  attr(:task_resume_from, :string, default: "")
  attr(:task_archive, :boolean, default: false)
  attr(:build_systems, :list, default: [])
  attr(:task_build_system, :string, default: nil)
  attr(:project_config, :map, default: nil)
  attr(:worktree_script, :string, default: nil)
  attr(:commands, :map, default: %{})
  attr(:foreign_repos, :list, default: [])
  attr(:foreign_repo_path_suggestions, :list, default: [])
  attr(:show_add_foreign_repo_form, :boolean, default: false)
  attr(:new_repo_id, :string, default: "")
  attr(:new_repo_path, :string, default: "")
  attr(:new_repo_description, :string, default: "")
  attr(:disabled, :boolean, default: false)
  attr(:show_configure_dropdown, :boolean, default: false)
  attr(:remote, :boolean, default: false)
  attr(:current_node_name, :string, default: "Local")

  def top_bar(assigns) do
    ~H"""
    <div
      class="dashboard-topbar shrink-0 sticky top-0 z-30 w-full flex items-center justify-between gap-3 px-4 py-3"
      data-remote={@remote}
    >
      <!-- LEFT: command palette project control -->
      <div class="flex-1 min-w-0">
        <EvoDashWeb.ProjectComponents.project_omnibox
          active_project={@active_project}
          recent_projects={@recent_projects}
          palette_open={@palette_open}
          palette_search={@palette_search}
          palette_mode={@palette_mode}
          palette_selected_index={@palette_selected_index}
          path_suggestions={@path_suggestions}
          tauri_detected={@tauri_detected}
          platform={@platform}
          remote={@remote}
        />
      </div>

      <!-- RIGHT: remote target badge (Configure dropdown is local-only) -->
      <%= if @remote do %>
        <div class="flex items-center gap-2 shrink-0">
          <span class="badge badge-info gap-1.5">
            <.icon name="hero-server-stack" class="size-4" />
            {@current_node_name}
          </span>
        </div>
      <% else %>
        <!-- RIGHT: Configure dropdown — server-managed open state -->
        <div class="relative shrink-0">
          <button
            type="button"
            class="btn btn-md btn-ghost gap-2"
            title={gettext("Configure")}
            phx-click="toggle_configure_dropdown"
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" />
            <span class="hidden sm:inline">{gettext("Configure")}</span>
          </button>

          <%= if @show_configure_dropdown do %>
            <!-- Full-screen invisible click-catcher overlay -->
            <div class="fixed inset-0 z-40" phx-click="close_configure_dropdown"></div>
          <% end %>

          <!-- Dropdown content — always in DOM, hidden when closed.
               Using class-based toggling (not conditional render) so content
               stays in the DOM and phx events inside still work reliably. -->
          <div class={[
            "absolute right-0 z-50 w-80 sm:w-96 mt-2 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl overflow-hidden",
            !@show_configure_dropdown && "hidden"
          ]}>
            <div class="p-3 max-h-[60vh] overflow-y-auto overflow-x-hidden">
              <!-- Section 1: Task Options -->
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-2">
                  {gettext("Task Options")}
                </p>
                <EvoDashWeb.TaskFormComponents.task_options_tab
                  mode={@task_mode}
                  node_path={@task_node_path}
                  starting_commit={@task_starting_commit}
                  resume_from={@task_resume_from}
                  archive={@task_archive}
                  build_systems={@build_systems}
                  selected_build_system={@task_build_system}
                  disabled={@disabled}
                />
              </div>

              <!-- Section 2: Project Settings (only when a project is active) -->
              <%= if @active_project != nil do %>
                <div class="mt-4 pt-4 border-t border-base-200">
                  <p class="text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-2">
                    {gettext("Project Settings")}
                  </p>
                  <EvoDashWeb.ProjectComponents.project_settings_tab
                    active_project={@active_project_path}
                    project_config={@project_config}
                    worktree_script={@worktree_script}
                    commands={@commands}
                    foreign_repos={@foreign_repos}
                    foreign_repo_path_suggestions={@foreign_repo_path_suggestions}
                    show_add_foreign_repo={@show_add_foreign_repo_form}
                    new_repo_id={@new_repo_id}
                    new_repo_path={@new_repo_path}
                    new_repo_description={@new_repo_description}
                    tauri_detected={@tauri_detected}
                    platform={@platform}
                  />
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # connecting_state/1 — Spinner shown while a selected remote target is
  # connecting/bootstrapping. No project data, no task form.
  # ---------------------------------------------------------------------------

  attr(:current_node_name, :string, default: "Local")

  def connecting_state(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col items-center justify-center gap-3 py-16 animate-fade-in-up">
      <span class="loading loading-spinner loading-lg text-info"></span>
      <p class="text-sm text-base-content/70">
        {gettext("Connecting to %{name}…", name: @current_node_name)}
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # error_state/1 — Prominent error state for a failed/disconnected remote
  # target. Shows the connection error (when the connection manager reported
  # one) plus Retry / Manage Connections / Switch to Local actions.
  # ---------------------------------------------------------------------------

  attr(:current_node_name, :string, default: "Local")
  attr(:last_error, :string, default: nil)

  def error_state(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col items-center justify-center gap-4 py-16 px-4 animate-fade-in-up">
      <div role="alert" class="alert alert-error max-w-xl w-full">
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <div class="min-w-0">
          <h3 class="font-bold text-sm">
            {gettext("Cannot connect to %{name}", name: @current_node_name)}
          </h3>
          <p class="text-sm break-words">{@last_error || gettext("Connection lost or failed")}</p>
        </div>
      </div>

      <div class="flex items-center gap-2 flex-wrap justify-center">
        <button
          type="button"
          phx-click="retry_remote_connection"
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-arrow-path" class="size-4" />
          {gettext("Retry")}
        </button>
        <a href="/settings?category=remote_connections" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-cog-6-tooth" class="size-4" />
          {gettext("Manage Connections")}
        </a>
        <button type="button" phx-click="switch_to_local" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-home" class="size-4" />
          {gettext("Switch to Local")}
        </button>
      </div>
    </div>
    """
  end
end
