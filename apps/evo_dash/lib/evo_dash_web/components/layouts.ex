defmodule EvoDashWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """

  # zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元)

  use EvoDashWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_page, :atom,
    default: nil,
    doc: "the current page atom (:dashboard, :agents, :assistant) for active nav highlighting"
  )

  attr(:config_status, :map, default: nil)

  attr(:simple_nav, :boolean,
    default: false,
    doc: "when true, renders the page without the workbench navigation"
  )

  attr(:current_node, :any, default: nil)
  attr(:current_node_id, :string, default: nil)
  attr(:current_node_name, :string, default: "Local")
  attr(:remote_targets, :list, default: [])
  attr(:connection_statuses, :map, default: %{})

  attr(:workbench_window, :boolean, default: false)
  attr(:workbench_project, :string, default: nil)
  attr(:workbench_title, :string, default: nil)
  attr(:workbench_task, :string, default: nil)
  attr(:workbench_draft, :string, default: nil)
  attr(:workbench_draft_project, :string, default: nil)
  attr(:workbench_git_project, :string, default: nil)
  attr(:github_status, :map, default: nil, doc: "the active project's GitHub upstream status")
  attr(:workbench_git_branch, :string, default: nil)
  attr(:workbench_starting_commit, :string, default: nil)

  attr(:running_tasks, :list, default: [])
  attr(:pending_tasks, :list, default: [])

  attr(:current_session_id, :any,
    default: nil,
    doc:
      "the session id of the Assistant conversation the page is showing (nil on every other page); " <>
        "renders that row as current in the sidebar Conversations list"
  )

  attr(:session_list, :any,
    default: [],
    doc:
      "the sidebar Conversations rows (seeded by EvoDashWeb.LiveHooks.NodeAware and rendered by " <>
        "EvoDashWeb.HomeLive.SessionList.session_list/1)"
  )

  attr(:session_list_loading, :boolean,
    default: false,
    doc: "whether a Conversations load is in flight (renders the sidebar loading line)"
  )

  attr(:session_list_error, :any,
    default: nil,
    doc:
      "the last Conversations load error (renders the sidebar alert); nil when the last load succeeded"
  )

  attr(:desktop_quit_confirm, :boolean,
    default: false,
    doc:
      "when true, renders the desktop tray quit confirmation dialog (seeded by EvoDashWeb.LiveHooks.DesktopQuit)"
  )

  attr(:update_status, :map,
    default: nil,
    doc:
      "the EvoDash.UpdateStatus state map (seeded by EvoDashWeb.LiveHooks.UpdateStatus); " <>
        "drives the notification dot on the System sidebar item when the phase is :available or :ready"
  )

  attr(:guide, :map,
    default: nil,
    doc:
      "the active Genesis Guide panel payload (seeded by EvoDashWeb.LiveHooks.Guide from the core guide_user tool broadcasts); " <>
        "renders the floating guide panel when present"
  )

  attr(:accent_color, :string,
    default: "blue",
    doc:
      "the user-configured accent color name (seeded by EvoDashWeb.LiveHooks.Appearance from " <>
        "EvoGit.Config.resolve([:appearance, :accent_color])); set as data-accent-color on #app-layout " <>
        "so the app.css [data-accent-color] override rules retarget --color-primary/--color-accent for the shell"
  )

  slot(:inner_block, required: true)

  def app(%{workbench_window: true} = assigns) do
    ~H"""
    <div
      id="workbench-window-content"
      phx-hook="WorkbenchWindow"
      data-accent-color={@accent_color}
      data-workbench-accent-default={@accent_color}
    >
      <main id="main-content" class="workbench-window-page flex flex-col">
        {render_slot(@inner_block)}
      </main>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  def app(assigns) do
    target =
      EvoDashWeb.WorkbenchComponent.target(assigns.current_node_id, assigns.connection_statuses)

    assigns =
      assign(assigns,
        workbench_target: target,
        workbench_git_available?: is_binary(assigns.workbench_git_project) and not is_nil(target)
      )

    ~H"""
    <div
      class="flex h-dvh overflow-hidden bg-base-200 transition-colors duration-300"
      id="app-layout"
      data-accent-color={@accent_color}
      data-workbench-accent-default={@accent_color}
      phx-hook={unless @simple_nav, do: "Workbench"}
      data-workbench-node={@current_node_id || ""}
      data-workbench-node-name={if @current_node_id, do: @current_node_name, else: gettext("Local")}
      data-workbench-project={@workbench_project || ""}
      data-workbench-title={@workbench_title}
      data-workbench-page={@current_page}
      data-workbench-task={@workbench_task}
      data-workbench-session={@current_session_id}
      data-workbench-draft={@workbench_draft}
      data-workbench-draft-project={@workbench_draft_project}
      data-workbench-git-branch={@workbench_git_branch}
      data-workbench-starting-commit={@workbench_starting_commit}
      data-workbench-new-task={gettext("New task")}
      data-workbench-new-chat={gettext("New conversation")}
      data-workbench-close={gettext("Close tab")}
      data-workbench-chats={gettext("Conversations")}
    >
      <%!-- Mobile hamburger button (visible on < lg screens) --%>
      <div :if={!@simple_nav} class="lg:hidden fixed top-0 left-0 z-50 p-1.5">
        <button
          id="sidebar-mobile-toggle"
          type="button"
          aria-controls="sidebar"
          aria-expanded="false"
          class="grid size-11 place-items-center rounded-lg bg-base-200 border border-base-300 text-base-content/70 hover:text-base-content transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
          aria-label={gettext("Toggle navigation")}
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
      </div>

      <%!-- Mobile overlay (hidden by default, JS-controlled) --%>
      <div
        :if={!@simple_nav}
        id="sidebar-overlay"
        class="fixed inset-0 z-40 bg-black/35 opacity-0 pointer-events-none transition-opacity duration-200 motion-reduce:transition-none lg:hidden"
        aria-hidden="true"
      >
      </div>

      <%!-- Sidebar
        NOTE: `overflow-visible!` (important) is deliberate defense-in-depth so
        the sidebar's overflowing <details> dropdown panels (SSH node selector
        w-72 = 288px, language, theme) are never clipped at the sidebar edge
        (w-60 = 240px expanded / w-16 = 64px collapsed). The !important
        modifier pins overflow to visible regardless of any other class
        changes. The SidebarCollapse hook (assets/js/hooks/sidebar_collapse.js)
        keeps overflow visible in BOTH collapsed and expanded states, so the
        pin protects the same invariant independently of hook class changes. The sidebar is a z-50 stacking context above the main
        content (z-0), so overflowing menus paint above the main body. The
        node selector lives in the sidebar's bottom bar, leftmost, with its
        dropdown opening upward. --%>
      <aside
        :if={!@simple_nav}
        id="sidebar"
        data-sidebar-collapsed="false"
        phx-hook="SidebarCollapse"
        class="fixed lg:relative z-50 h-dvh flex flex-col bg-base-200 border-r border-base-300 shadow-sm lg:shadow-none transition-[translate,width] duration-200 ease-out motion-reduce:transition-none w-60 -translate-x-full lg:translate-x-0 overflow-visible!"
      >
        <%!-- Branding --%>
        <div class="flex items-center justify-between gap-2 h-14 px-4 shrink-0">
          <.link
            navigate={with_node_param(~p"/", @current_node_id)}
            class="flex items-center gap-2 rounded-md hover:opacity-80 transition-opacity min-w-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
          >
            <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
            <img
              src={~p"/images/logo.svg"}
              class="h-6 w-auto block dark:hidden shrink-0"
              alt={gettext("EvoX Genesis")}
            />
            <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
            <img
              src={~p"/images/logo-alt.svg"}
              class="h-6 w-auto hidden dark:block shrink-0"
              alt={gettext("EvoX Genesis")}
            />
            <span class="text-base font-semibold tracking-tight text-base-content truncate sidebar-label">
              <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
              {gettext("EvoX Genesis")}
            </span>
          </.link>
          <button
            id="sidebar-mobile-close"
            type="button"
            class="workbench-icon-button shrink-0"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <%!-- Navigation Links --%>
        <nav class="workbench-sidebar-nav flex-1 px-2 py-2 overflow-y-auto">
          <%!-- Active Tasks — a first-class section, never nested in Tools, so a
             running task stays reachable from every sidebar page. --%>
          <EvoDashWeb.WorkbenchActiveTasks.active_tasks
            running_tasks={@running_tasks}
            pending_tasks={@pending_tasks}
            current_node_id={@current_node_id}
          />
          <.sidebar_nav_link
            navigate={with_node_param(~p"/assistant", @current_node_id)}
            current={@current_page == :assistant}
            icon="hero-sparkles"
          >{gettext("Assistant")}</.sidebar_nav_link>
          <.live_component
            module={EvoDashWeb.WorkbenchComponent}
            id="workbench-projects"
            mode={:projects}
            patch_links={@current_page == :dashboard}
            node_id={@current_node_id}
            targets={@remote_targets}
            statuses={@connection_statuses}
            project={@workbench_project}
          />
          <div class="workbench-sidebar-utilities">
            <%!-- `motion-disclosure` + the DisclosureMotion hook smooth BOTH
               directions: a native <details> snaps open and shut, and the hook
               only defers the `open` removal so motion.css can play the exit.
               `group` exists solely for the summary caret's `group-open:`
               rotation (motion.css has no rule for it, and the global
               reduced-motion backstop already neutralizes the transition).
               The id is required by LiveView on any element carrying phx-hook. --%>
            <details
              id="workbench-tools"
              class="workbench-tools motion-disclosure group"
              phx-hook="DisclosureMotion"
              open={
                is_nil(@workbench_task) and
                  @current_page in [:agents, :tasks, :processes, :settings, :system]
              }
            >
              <summary class="workbench-row">
                <.icon name="hero-ellipsis-horizontal" class="size-5 shrink-0" />
                <span class="sidebar-label text-sm font-medium">{gettext("Tools")}</span>
                <.icon
                  name="hero-chevron-right"
                  class="ml-auto size-3.5 shrink-0 text-base-content/50 transition-transform duration-[var(--motion-base)] ease-[var(--motion-ease-out)] group-open:rotate-90"
                />
              </summary>
              <.sidebar_nav_link
                navigate={with_node_param(~p"/agents", @current_node_id)}
                current={@current_page == :agents}
                icon="hero-server"
              >{gettext("Agents")}</.sidebar_nav_link>
              <.sidebar_nav_link
                navigate={with_node_param(~p"/tasks", @current_node_id)}
                current={@current_page == :tasks}
                icon="hero-clipboard-document-list"
              >{gettext("Tasks")}</.sidebar_nav_link>
              <%!-- zh_CN: "进程" — 指 Genesis 跟踪的操作系统进程（智能体工具调用与后台任务），不是 Erlang 进程 --%>
              <.sidebar_nav_link
                navigate={with_node_param(current_page(:processes), @current_node_id)}
                current={@current_page == :processes}
                icon="hero-cpu-chip"
                data_nav="processes"
              ><span class="sidebar-label">{gettext("Processes")}</span></.sidebar_nav_link>
              <.sidebar_nav_link
                navigate={with_node_param(~p"/system", @current_node_id)}
                current={@current_page == :system}
                icon="hero-server-stack"
                notification={update_status_notification(@update_status)}
              >{gettext("System")}</.sidebar_nav_link>
            </details>
            <details
              id="workbench-conversations"
              class="workbench-tools motion-disclosure group"
              phx-hook="DisclosureMotion"
              open={@current_page == :assistant}
            >
              <summary class="workbench-row">
                <.icon name="hero-chat-bubble-left-right" class="size-5 shrink-0" />
                <span class="sidebar-label text-sm font-medium">{gettext("Conversations")}</span>
                <.icon
                  name="hero-chevron-right"
                  class="ml-auto size-3.5 shrink-0 text-base-content/50 transition-transform duration-[var(--motion-base)] ease-[var(--motion-ease-out)] group-open:rotate-90"
                />
              </summary>
              {EvoDashWeb.HomeLive.SessionList.session_list(assigns)}
            </details>
          </div>
        </nav>

        <div class="px-3 py-3 border-t border-base-300 shrink-0">
          <div data-sidebar-bottom-bar class="flex items-center justify-between gap-1">
            <div data-sidebar-bottom-group class="flex items-center gap-1">
              <button
                type="button"
                id="workbench-settings"
                class="workbench-row workbench-settings-button"
                data-workbench-settings={~p"/settings/window"}
                aria-label={gettext("Settings")}
                title={gettext("Settings")}
              >
                <.icon name="hero-cog-6-tooth" class="size-5 shrink-0" />
                <span class="sidebar-label text-sm font-medium">{gettext("Settings")}</span>
                <span
                  :if={@config_status && !@config_status.ok?}
                  class="workbench-settings-indicator"
                  title={gettext("Missing Configuration")}
                  aria-label={gettext("Missing Configuration")}
                ></span>
              </button>
            </div>
            <div data-sidebar-bottom-group class="flex items-center gap-1">
              <button
                id="sidebar-collapse-toggle"
                class="p-1.5 rounded-lg text-base-content/70 hover:text-base-content hover:bg-base-300 transition-colors hidden lg:flex focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
                title={gettext("Collapse sidebar")}
              >
                <.icon name="hero-chevron-double-left" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      </aside>
      <div
        :if={!@simple_nav}
        id="workbench-left-resize"
        class="workbench-resizer"
        data-workbench-resize="left"
        role="separator"
        tabindex="0"
        aria-orientation="vertical"
        aria-controls="sidebar"
        aria-label={gettext("Resize project sidebar")}
      >
      </div>

      <div class="workbench-main">
        <div class="workbench-center">
          <header :if={!@simple_nav} class="workbench-top">
            <div class="workbench-tab-rail">
              <div
                id="workbench-tabs"
                class="workbench-tabs"
                phx-update="ignore"
                role="navigation"
                aria-label={gettext("Open tabs")}
              >
              </div>
              <details
                id="workbench-create"
                class="workbench-create"
                phx-mounted={JS.ignore_attributes("open")}
              >
                <summary
                  id="workbench-create-toggle"
                  class="workbench-icon-button"
                  aria-label={gettext("Create")}
                  title={gettext("Create")}
                >
                  <.icon name="hero-plus" class="size-5" />
                </summary>
                <div class="workbench-create-menu">
                  <%= if @workbench_project && @workbench_target do %>
                    <.link
                      navigate={
                        EvoDashWeb.WorkbenchComponent.navigation_path("/projects", @current_node_id,
                          project: @workbench_project,
                          wb_task: "1"
                        )
                      }
                      class="workbench-row"
                      data-workbench-new-task
                    >
                      <.icon name="hero-clipboard-document" class="size-4 shrink-0" />
                      {gettext("New task")}
                    </.link>
                    <button type="button" class="workbench-row" data-workbench-new-conversation>
                      <.icon name="hero-chat-bubble-left" class="size-4 shrink-0" />
                      {gettext("New conversation")}
                    </button>
                  <% else %>
                    <button type="button" class="workbench-row" data-workbench-project-window="create">
                      <.icon name="hero-plus" class="size-4 shrink-0" />
                      {gettext("Create New Project")}
                    </button>
                    <button type="button" class="workbench-row" data-workbench-project-window="open">
                      <.icon name="hero-folder-open" class="size-4 shrink-0" />
                      {gettext("Open Existing Project")}
                    </button>
                  <% end %>
                </div>
              </details>
            </div>
            <button
              :if={@workbench_git_available?}
              id="workbench-git-toggle"
              type="button"
              class="workbench-icon-button workbench-git-toggle"
              aria-controls="workbench-git"
              aria-expanded="false"
              title={gettext("Project Git")}
              aria-label={gettext("Project Git")}
            >
              <.icon name="hero-code-bracket" class="size-4 shrink-0" />
              <span id="workbench-git-toggle-label" phx-update="ignore">Git</span>
              <.icon name="hero-chevron-down" class="size-3 shrink-0" />
            </button>
            <button
              :if={@workbench_project}
              id="workbench-history-toggle"
              type="button"
              class="workbench-icon-button"
              aria-controls="workbench-history"
              aria-expanded="false"
              title={gettext("Project history")}
              aria-label={gettext("Project history")}
            >
              <.icon name="hero-clock" class="size-5" />
            </button>
          </header>
          <%!-- Main Content Area --%>
          <div class="workbench-content-stack">
            <div id="main-scroll" class="flex-1 flex flex-col overflow-auto min-w-0 z-0 bg-base-100">
              <%!-- The DesktopQuit hook wrapper listens for the Tauri shell's
             "quit-requested" tray event on every page: hooks only mount on
             elements inside the LiveView root DOM, and this wrapper is part of
             the shared app layout, so it is re-established on every navigation. --%>
              <div
                id="desktop-quit-hook"
                phx-hook="DesktopQuit"
                class="flex-1 flex flex-col min-w-0 min-h-0"
              >
                <main
                  id="main-content"
                  class="flex-1 min-h-0 px-4 sm:px-5 lg:px-6 pt-4 pb-4 w-full bg-base-100"
                  phx-hook="NodeSwitchFade"
                  data-node-id={@current_node_id || "local"}
                >
                  {render_slot(@inner_block)}
                </main>
              </div>
              <%!-- The UpdateStatus hook wrapper bridges the Tauri updater to the
             server (startup + periodic checks, phx:update_* event listeners).
             Hooks only mount on elements inside the LiveView root DOM, and
             this wrapper is part of the shared app layout, so it is
             re-established on every page navigation. A no-op outside the
             Tauri desktop shell. --%>
              <div id="update-status-hook" phx-hook="UpdateStatus" />
              <%!-- The Guide hook wrapper bridges the core guide_user tool broadcasts
             to the floating Genesis Guide panel. Hooks only mount on elements
             inside the LiveView root DOM, and this wrapper is part of the
             shared app layout, so it is re-established on every page
             navigation. --%>
              <div id="guide-hook" phx-hook="Guide" />
            </div>
            <div :if={!@simple_nav && @workbench_git_available?} id="workbench-git-diff-host" />
          </div>
        </div>

        <button
          :if={!@simple_nav}
          id="workbench-history-overlay"
          type="button"
          tabindex="-1"
          aria-hidden="true"
          hidden
        ></button>
        <div
          :if={!@simple_nav}
          id="workbench-right-resize"
          class="workbench-resizer"
          data-workbench-resize="right"
          role="separator"
          tabindex="0"
          aria-orientation="vertical"
          aria-controls="workbench-history workbench-git"
          aria-label={gettext("Resize right sidebar")}
          hidden
        >
        </div>
        <aside
          :if={!@simple_nav}
          id="workbench-history"
          class="workbench-history"
          aria-label={gettext("Project history")}
          data-panel-state="closed"
          hidden
        >
          <div class="workbench-section-heading">
            <div class="text-sm font-semibold">{gettext("Project history")}</div>
            <div class="flex items-center gap-1">
              <button
                type="button"
                data-workbench-close-history
                class="workbench-icon-button"
                aria-label={gettext("Close history")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>
          <.live_component
            module={EvoDashWeb.WorkbenchComponent}
            id="workbench-history-content"
            mode={:history}
            node_id={@current_node_id}
            target={@workbench_target}
            project={@workbench_project}
          />
        </aside>
        <aside
          :if={!@simple_nav && @workbench_project}
          id="workbench-git"
          class="workbench-history workbench-git"
          aria-label={gettext("Project Git")}
          data-panel-state="closed"
          hidden
        >
          <.live_component
            module={EvoDashWeb.ProjectGit}
            id="workbench-git-content"
            node_id={@current_node_id}
            target={@workbench_target}
            project={@workbench_git_project}
            server={workbench_git_server(assigns)}
            github_status={@github_status}
          />
        </aside>
      </div>

      <.live_component
        :if={!@simple_nav}
        module={EvoDashWeb.ProjectWindow}
        id="workbench-project-window-component"
        node_id={@current_node_id}
        targets={@remote_targets}
        statuses={@connection_statuses}
      />

      <dialog
        :if={!@simple_nav}
        id="workbench-settings-window"
        class="workbench-window workbench-settings-window"
        aria-labelledby="workbench-settings-window-title"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <h2 id="workbench-settings-window-title" class="sr-only">{gettext("Settings")}</h2>
        <button
          type="button"
          class="workbench-icon-button workbench-settings-close"
          data-workbench-close-window
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <div id="workbench-settings-window-panel" phx-update="ignore">
          <iframe
            id="workbench-settings-frame"
            title={gettext("Settings")}
            referrerpolicy="same-origin"
          ></iframe>
        </div>
      </dialog>

      <%!-- Onboarding configuration warning. The workbench uses the settings indicator. --%>
      <%= if @config_status && not @config_status.ok? do %>
        <div
          hidden={!@simple_nav}
          class="fixed bottom-4 right-4 z-40 w-[calc(100%-2rem)] max-w-sm animate-fade-in-up"
        >
          <div class="bg-base-100 text-warning rounded-lg shadow-sm border border-warning/30 p-4">
            <div class="flex items-start gap-3">
              <.icon
                name="hero-exclamation-triangle"
                class="size-5 shrink-0 mt-0.5"
              />
              <div class="flex-1 min-w-0">
                <p class="font-semibold text-sm">{gettext("Missing Configuration")}</p>
                <ul class="mt-1 space-y-0.5">
                  <%= for line <- EvoDashWeb.ConfigIssues.lines(@config_status) do %>
                    <li class="text-xs break-words">{line}</li>
                  <% end %>
                </ul>
                <.link
                  navigate={with_node_param(~p"/settings", @current_node_id)}
                  data-workbench-settings={if !@simple_nav, do: ~p"/settings/window"}
                  class="text-xs font-medium underline mt-2 inline-block hover:opacity-80"
                >{gettext("Configure now →")}</.link>
              </div>
              <button
                class="p-1 rounded-md hover:bg-warning/20 transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
                aria-label={gettext("Close")}
                onclick="this.closest('.fixed').remove()"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Desktop tray quit confirm dialog — driven by the DesktopQuit
           on-mount hook (EvoDashWeb.LiveHooks.DesktopQuit) from the Tauri
           shell's tray "Quit Genesis" item. Rendered in the app layout so it
           can appear on ANY page (including Welcome/WelcomeComplete). --%>
      <%= if @desktop_quit_confirm do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="desktop_quit_cancelled">
          </div>
          <div class="relative bg-base-100 rounded-xl shadow-2xl border border-base-300 max-w-lg w-full p-5 sm:p-6">
            <div class="flex items-center gap-3 mb-4">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
              <h3 class="text-lg font-semibold">{gettext("Quit Genesis?")}</h3>
            </div>

            <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
              {gettext(
                "This will gracefully shut down the Erlang VM. All applications will be stopped in order."
              )}
            </p>
            <p class="text-sm text-error/80 font-semibold mb-5 leading-relaxed">
              {gettext(
                "Running tasks will be interrupted and may lose progress. The VM will stop and must be restarted again from the desktop app. This cannot be undone."
              )}
            </p>

            <div class="flex justify-end gap-3 pt-2">
              <button
                type="button"
                class="btn btn-ghost rounded-md px-6"
                phx-click="desktop_quit_cancelled"
              >
                {gettext("Cancel")}
              </button>
              <button
                type="button"
                id="desktop-quit-confirm-btn"
                class="btn btn-error rounded-md px-6 gap-2"
                phx-hook="DesktopQuitConfirm"
              >
                <.icon name="hero-power" class="size-4.5" />
                {gettext("Quit")}
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Floating "Genesis Guide" panel — driven by the Guide on-mount hook
           (EvoDashWeb.LiveHooks.Guide) from the core guide_user tool
           broadcasts of a running reflect task. Rendered in the shared app
           layout so it can appear on ANY page. Top-right (fixed top-4 right-4
           z-50) so it never overlaps the config-warning banner
           (fixed bottom-4 right-4 z-40). Not auto-dismissed on navigation —
           the guide continues across pages (retention handled by the hook's
           session + the JS highlight re-apply). --%>
      <%= if @guide do %>
        <div class="fixed top-4 right-4 z-50 w-80 max-w-[calc(100vw-2rem)] bg-base-100 border border-base-300 rounded-xl shadow-lg p-4">
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-sparkles" class="w-4 h-4 text-primary-standalone shrink-0" />
            <%!-- 自省智能体向导 — 由运行中的 reflect 任务推送的引导提示 --%>
            <h3 class="text-sm font-semibold flex-1 min-w-0">{gettext("Genesis Guide")}</h3>
            <%= if @guide.dismissible do %>
              <%!-- 关闭向导提示 --%>
              <button
                type="button"
                class="p-1 rounded-md hover:bg-base-200 transition-colors shrink-0"
                phx-click="guide_dismissed"
                aria-label={gettext("Dismiss guide")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
          <p class="text-sm text-base-content/70 leading-relaxed">{@guide.message}</p>
          <%= if is_binary(@guide.page) do %>
            <div class="mt-3">
              <.link
                navigate={with_node_param(@guide.page, @current_node_id)}
                class="btn btn-primary btn-sm"
              >
                <%!-- 跳转到引导指向的页面 --%>
                {gettext("Go")}
              </.link>
            </div>
          <% end %>
        </div>
      <% end %>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp workbench_git_server(%{current_node_id: nil}), do: gettext("Local")

  defp workbench_git_server(assigns) do
    case Enum.find(assigns.remote_targets, &(&1.id == assigns.current_node_id)) do
      nil -> assigns.current_node_id
      target -> target.name
    end
  end

  attr(:navigate, :string, required: true)
  attr(:current, :boolean, default: false)
  attr(:icon, :string, required: true)
  attr(:data_nav, :string, default: nil, doc: "optional data-nav marker on the link")

  attr(:notification, :atom,
    default: nil,
    doc: "a phase atom (:available, :ready) that renders a notification dot at the right edge"
  )

  slot(:inner_block, required: true)

  defp sidebar_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 px-3 py-2 min-h-[var(--row-h)] rounded-lg text-sm font-medium transition-colors duration-200 w-full focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone",
        @current && "bg-primary/10 text-primary-standalone",
        !@current &&
          "text-base-content/80 hover:bg-base-300/70 hover:text-base-content"
      ]}
      aria-current={if @current, do: "page", else: false}
      data-nav={@data_nav}
    >
      <.icon
        name={@icon}
        class={
        "size-5 transition-colors " <>
        if(@current, do: "text-primary-standalone", else: "text-base-content/60")
      }
      />
      <span class="sidebar-label">{render_slot(@inner_block)}</span>
      <%= if @notification do %>
        <span
          class={["ml-auto w-2.5 h-2.5 rounded-full shrink-0", update_notification_dot(@notification)]}
          title={
            if @notification == :ready,
              do: gettext("Update ready to install"),
              else: gettext("Update available")
          }
        ></span>
      <% end %>
    </.link>
    """
  end

  # Tailwind color class for the System sidebar item's update notification dot:
  # :available → static warning amber, :ready → success with a ping animation
  # (token family — mirrors Helpers.task_status_dot_class/1). Any other phase
  # renders no dot.
  defp update_notification_dot(:available), do: "bg-warning"
  defp update_notification_dot(:ready), do: "bg-success animate-ping"
  defp update_notification_dot(_), do: "bg-base-content/40"

  # Notification phase for the System nav link: nil unless the update status
  # phase is :available (amber dot) or :ready (blue ping dot).
  defp update_status_notification(%{phase: phase}) when phase in [:available, :ready], do: phase
  defp update_status_notification(_), do: nil

  # Compact theme toggle for sidebar bottom bar — a single button with a dropdown
  # containing the three theme options: system, light, dark.
  @doc """
  Maps current page atom to its route path.
  """
  def current_page(:dashboard), do: "/projects"
  def current_page(:phx_dashboard), do: "/dashboard"
  def current_page(:agents), do: "/agents"
  def current_page(:tasks), do: "/tasks"
  def current_page(:processes), do: "/processes"
  def current_page(:settings), do: "/settings"
  def current_page(:system), do: "/system"
  def current_page(:assistant), do: "/assistant"
  def current_page(:review), do: "/review/:task_id"
  def current_page(:welcome), do: "/welcome"

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="fixed top-4 right-4 z-[60] flex flex-col gap-2 w-80 sm:w-96 pointer-events-none"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:success} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash kind={:warning} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin inline" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin inline" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex p-1 bg-base-300 rounded-full ring-1 ring-base-content/10 shadow-inner overflow-hidden">
      <!-- Background slider -->
      <div class="absolute inset-y-1 left-1 w-9 rounded-full bg-base-100 shadow transition-transform duration-300 ease-out z-0
        [[data-theme-mode=light]_&]:translate-x-9
        [[data-theme-mode=dark]_&]:translate-x-[4.5rem]" />

      <button
        class="relative z-10 p-2 w-9 h-8 flex items-center justify-center rounded-full text-base-content/70 hover:text-base-content transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="w-4 h-4" />
      </button>

      <button
        class="relative z-10 p-2 w-9 h-8 flex items-center justify-center rounded-full text-base-content/70 hover:text-base-content transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="w-4 h-4" />
      </button>

      <button
        class="relative z-10 p-2 w-9 h-8 flex items-center justify-center rounded-full text-base-content/70 hover:text-base-content transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  @doc """
  Returns the list of supported languages as `{code, name}` tuples.
  Shared between `language_selector/1` and the welcome modal language switcher.
  """
  def supported_languages do
    [
      {"en", "English"},
      {"ar", "العربية"},
      {"de", "Deutsch"},
      {"zh_CN", "中文 (简体)"},
      {"zh_HK", "中文 (繁體)"},
      {"ja", "日本語"},
      {"es", "español"},
      {"ru", "русский"},
      {"pt", "português"},
      {"id", "Bahasa Indonesia"},
      {"ko", "한국어"},
      {"th", "ภาษาไทย"},
      {"vi", "Tiếng Việt"},
      {"fr", "Français"},
      {"it", "Italiano"}
    ]
  end

  @doc """
  Provides a language/locale selector dropdown with globe icon button.
  """
  attr(:drop_up, :boolean, default: false)

  def language_selector(assigns) do
    locale = Gettext.get_locale(EvoDashWeb.Gettext)
    languages = supported_languages()

    assigns = assign(assigns, :locale, locale)
    assigns = assign(assigns, :languages, languages)

    ~H"""
    <details class={["dropdown", !@drop_up && "dropdown-end", @drop_up && "dropdown-top"]}>
      <summary
        class="btn btn-sm btn-ghost btn-circle rounded-full hover:bg-base-300 transition-colors"
        title={gettext("Change language")}
      >
        <.icon name="hero-language" class="size-5" />
      </summary>
      <div class={[
        "dropdown-content",
        (@drop_up && "mb-2") || "mt-2",
        "z-50 w-56 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-2"
      ]}>
        <div class="max-h-48 overflow-y-auto flex flex-col gap-0.5">
          <button
            :for={{code, name} <- @languages}
            class={[
              "flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer",
              @locale == code &&
                "bg-primary/10 text-primary-standalone",
              @locale != code &&
                "hover:bg-base-200 text-base-content/80"
            ]}
            phx-click={JS.dispatch("phx:set-locale", detail: %{locale: code})}
          >
            <span class="flex-1 text-left">{name}</span>
            <.icon
              :if={@locale == code}
              name="hero-check-solid"
              class="size-4 text-primary-standalone shrink-0"
            />
          </button>
        </div>
      </div>
    </details>
    """
  end
end
