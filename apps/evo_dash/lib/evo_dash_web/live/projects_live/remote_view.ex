defmodule EvoDashWeb.ProjectsLive.RemoteView do
  @moduledoc """
  Task configuration shared by local and remote projects, and connection states
  for remote projects.
  """

  use EvoDashWeb, :html

  attr(:active_project_path, :string, required: true)
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")
  attr(:task_mode, :string, default: "genesis_new")
  attr(:task_node_path, :string, default: "")
  attr(:task_starting_commit, :string, default: "")
  attr(:task_resume_from, :string, default: "")
  attr(:task_archive, :boolean, default: false)
  # Persist agent state (default ON) — forwarded to task_options_tab/1, the
  # only render site of that component for BOTH local and remote views.
  attr(:persist_agent_state?, :boolean, default: true)
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
  attr(:remote, :boolean, default: false)
  attr(:inline, :boolean, default: false)

  @doc "Renders one set of task form controls, either inline or in the workbench dialog."
  def task_configuration(assigns) do
    ~H"""
    <.settings_shell inline={@inline}>
      <div class={["space-y-4", if(@inline, do: "py-4", else: "p-4")]}>
        <section>
          <.dynamic_tag
            tag_name={if(@inline, do: "h2", else: "h3")}
            id={@inline && "workbench-task-settings-title"}
            class="mb-2 text-base font-semibold"
          >
            {gettext("Task Options")}
          </.dynamic_tag>
          <EvoDashWeb.TaskFormComponents.task_options_tab
            mode={@task_mode}
            node_path={@task_node_path}
            starting_commit={@task_starting_commit}
            resume_from={@task_resume_from}
            archive={@task_archive}
            persist_agent_state?={@persist_agent_state?}
            build_systems={@build_systems}
            selected_build_system={@task_build_system}
          />
        </section>
        <section class="pt-4 border-t border-base-300">
          <.dynamic_tag
            tag_name={if(@inline, do: "h2", else: "h3")}
            class="mb-2 text-base font-semibold"
          >
            {gettext("Project Settings")}
          </.dynamic_tag>
          <EvoDashWeb.ProjectComponents.project_settings_tab
            remote={@remote}
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
        </section>
      </div>
    </.settings_shell>
    """
  end

  attr(:inline, :boolean, required: true)
  slot(:inner_block, required: true)

  defp settings_shell(%{inline: true} = assigns) do
    ~H"""
    <section id="workbench-task-settings" aria-labelledby="workbench-task-settings-title">
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp settings_shell(assigns) do
    ~H"""
    <dialog
      id="workbench-task-settings"
      class="workbench-window workbench-task-settings"
      aria-labelledby="workbench-task-settings-title"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <header class="workbench-window-header">
        <h2 id="workbench-task-settings-title">{gettext("Configure")}</h2>
        <button
          type="button"
          class="workbench-icon-button"
          data-workbench-close-window
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>
      {render_slot(@inner_block)}
    </dialog>
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
          <h3 class="font-semibold text-sm">
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
