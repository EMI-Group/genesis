defmodule EvoDashWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """

  # zh_CN: Genesis → "启元"

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
    doc: "the current page atom (:dashboard, :agents) for active nav highlighting"
  )

  attr(:config_status, :map, default: nil)

  attr(:simple_nav, :boolean,
    default: false,
    doc: "when true, shows simplified nav (brand only)"
  )

  attr(:current_node, :any, default: nil)
  attr(:current_node_id, :string, default: nil)
  attr(:current_node_name, :string, default: "Local")
  attr(:remote_targets, :list, default: [])
  attr(:connection_statuses, :map, default: %{})

  attr(:tasks, :list, default: [])
  attr(:running_tasks, :list, default: [])
  attr(:pending_tasks, :list, default: [])

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <div
      class="flex h-screen overflow-hidden bg-slate-50 dark:bg-slate-950 transition-colors duration-300"
      id="app-layout"
    >
      <!-- Mobile hamburger button (visible on < lg screens) -->
      <div class="lg:hidden fixed top-0 left-0 z-50 p-2">
        <button
          id="sidebar-mobile-toggle"
          class="p-2 rounded-lg bg-white dark:bg-slate-900 shadow-md border border-slate-200 dark:border-slate-800 text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-white transition-colors"
          aria-label={gettext("Toggle navigation")}
        >
          <.icon name="hero-bars-3" class="w-5 h-5" />
        </button>
      </div>
      <!-- Mobile overlay (hidden by default, JS-controlled) -->
      <div
        id="sidebar-overlay"
        class="fixed inset-0 z-40 bg-slate-900/50 backdrop-blur-sm opacity-0 pointer-events-none transition-opacity duration-300 lg:hidden"
      >
      </div>
      <!-- Sidebar -->
      <aside
        id="sidebar"
        data-sidebar-collapsed="false"
        phx-hook="SidebarCollapse"
        class="fixed lg:relative z-50 h-screen flex flex-col bg-white dark:bg-slate-900 border-r border-slate-200 dark:border-slate-800 shadow-sm lg:shadow-none transition-all duration-300 ease-in-out w-60 -translate-x-full lg:translate-x-0 overflow-visible!"
      >
        <%!-- overflow-visible! is pinned with !important: the SidebarCollapse
          hook re-applies overflow-hidden on expand, which clips the SSH
          node-selector dropdown (288px) at the 240px sidebar edge. --%>
        <!-- Branding -->
        <div class="flex items-center h-14 px-4 border-b border-slate-200 dark:border-slate-800 shrink-0">
          <.link
            navigate={with_node_param(~p"/dashboard", @current_node_id)}
            class="flex items-center gap-2.5 hover:opacity-80 transition-opacity min-w-0"
          >
            <%!-- zh_CN: Genesis → "启元" --%>
            <img
              src={~p"/images/evox-logo.svg"}
              class="h-6 w-auto block dark:hidden shrink-0"
              alt={gettext("Genesis")}
            /> <%!-- zh_CN: Genesis → "启元" --%>
            <img
              src={~p"/images/evox-logo-white.svg"}
              class="h-6 w-auto hidden dark:block shrink-0"
              alt={gettext("Genesis")}
            />
            <span class="text-lg font-extrabold tracking-tight bg-gradient-to-r from-slate-900 to-slate-700 dark:from-white dark:to-slate-300 bg-clip-text text-transparent truncate sidebar-label">
              <%!-- zh_CN: Genesis → "启元" --%> {gettext("Genesis")}
            </span>
          </.link>
        </div>
        <!-- Navigation Links -->
        <%= if !@simple_nav do %>
          <nav class="flex-1 px-2 py-3 space-y-0.5 overflow-y-auto">
            <.sidebar_nav_link
              navigate={with_node_param(~p"/dashboard", @current_node_id)}
              current={@current_page == :dashboard}
              icon="hero-squares-2x2"
            >{gettext("Tasks")}</.sidebar_nav_link>
            <.sidebar_nav_link
              navigate={with_node_param(~p"/agents", @current_node_id)}
              current={@current_page == :agents}
              icon="hero-server"
            >{gettext("Agents")}</.sidebar_nav_link>
            <.sidebar_nav_link
              navigate={with_node_param(~p"/settings", @current_node_id)}
              current={@current_page == :settings}
              icon="hero-cog-6-tooth"
            >{gettext("Settings")}</.sidebar_nav_link>
            <!-- Task Indicators Section -->
            <div
              :if={@running_tasks != [] or @pending_tasks != []}
              class="pt-5 mt-4 border-t border-slate-200 dark:border-slate-800"
            >
              <div class="px-3 mb-3 mt-1">
                <span class="text-sm font-semibold uppercase tracking-wider text-slate-400 dark:text-slate-500 sidebar-label">
                  {gettext("Active Tasks")}
                </span>
              </div>

              <div class="space-y-1">
                <%= for {project_name, tasks} <- group_tasks_by_project(@running_tasks, @pending_tasks) do %>
                  <!-- Project group header -->
                  <div class="px-3 pt-2 pb-1 first:pt-0">
                    <span class="flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-slate-400 dark:text-slate-500 sidebar-label">
                      <.icon name="hero-folder" class="w-3 h-3 shrink-0" /> {project_name}
                    </span>
                  </div>
                  <!-- Tasks in this group -->
                  <%= for task <- tasks do %>
                    <% is_running = task.status in [:running, :pending, :finalizing] %>
                    <.link
                      navigate={
                        if is_running,
                          do: with_node_param(~p"/agents", @current_node_id),
                          else: with_node_param(~p"/review/#{task.id}", @current_node_id)
                      }
                      data-sidebar-task-link
                      title={task_label(task) <> " — " <> (if is_running, do: format_elapsed(task.started_at), else: gettext("completed") <> " " <> format_elapsed(task.finished_at))}
                      class="flex items-center gap-2 px-3 py-2.5 rounded-lg text-sm text-slate-600 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors group"
                    >
                      <span
                        class={[
                          "w-2.5 h-2.5 rounded-full shrink-0",
                          task_status_dot_color(task),
                          is_running && "animate-pulse"
                        ]}
                        title={if is_running, do: gettext("Running"), else: gettext("Pending Review")}
                      ></span>
                      <div class="min-w-0 flex-1 sidebar-label">
                        <span class="block truncate group-hover:text-slate-900 dark:group-hover:text-white transition-colors">
                          {task_label(task)}
                        </span>

                        <span class="block text-xs text-slate-400 dark:text-slate-500 mt-0.5">
                          <%= if is_running do %>
                            {format_elapsed(task.started_at)}
                          <% else %>
                            {gettext("completed")} {format_elapsed(task.finished_at)}
                          <% end %>
                        </span>
                      </div>
                    </.link>
                  <% end %>
                <% end %>
              </div>
            </div>
          </nav>
          <!-- Bottom section: Language + Theme + Collapse -->
          <div class="px-3 py-3 border-t border-slate-200 dark:border-slate-800 shrink-0">
            <div data-sidebar-bottom-bar class="flex items-center justify-between gap-1">
              <div data-sidebar-bottom-group class="flex items-center gap-1">
                <.language_selector drop_up={true} /> <.art_style_selector drop_up={true} />
                <.link
                  navigate={~p"/"}
                  id="sidebar-simple-mode-link"
                  class="btn btn-sm btn-ghost btn-circle rounded-full hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
                  title={gettext("Simple mode")}
                >
                  <.icon name="hero-home" class="size-5" />
                </.link>
              </div>

              <button
                id="sidebar-collapse-toggle"
                class="p-1.5 rounded-lg text-slate-400 dark:text-slate-500 hover:text-slate-600 dark:hover:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors hidden lg:flex"
                title={gettext("Collapse sidebar")}
              >
                <.icon name="hero-chevron-double-left" class="w-4 h-4" />
              </button>
            </div>
          </div>
        <% end %>
      </aside>
      <!-- Main Content Area -->
      <div id="main-scroll" class="flex-1 flex flex-col overflow-auto min-w-0 z-0">
        <main
          id="main-content"
          class="flex-1 px-4 sm:px-5 lg:px-6 py-4 w-full bg-white dark:bg-slate-900"
          phx-hook="NodeSwitchFade"
          data-node-id={@current_node_id || "local"}
        >
          {render_slot(@inner_block)}
        </main>
      </div>
      <!-- Config Warning Banner -->
      <%= if @config_status && not @config_status.ok? do %>
        <div class="fixed bottom-4 right-4 z-40 max-w-sm w-full animate-fade-in-up">
          <div class="bg-amber-50 dark:bg-amber-900/30 text-amber-900 dark:text-amber-200 rounded-xl shadow-lg border border-amber-200 dark:border-amber-800 p-4">
            <div class="flex items-start gap-3">
              <.icon
                name="hero-exclamation-triangle"
                class="w-5 h-5 shrink-0 mt-0.5 text-amber-600 dark:text-amber-500"
              />
              <div class="flex-1 min-w-0">
                <p class="font-semibold text-sm">{gettext("Missing Configuration")}</p>

                <ul class="mt-1 space-y-0.5">
                  <%= for warning <- @config_status.warnings do %>
                    <li class="text-xs opacity-90">{warning}</li>
                  <% end %>
                </ul>

                <.link
                  navigate={~p"/settings"}
                  class="text-xs font-medium underline mt-2 inline-block hover:text-amber-700 dark:hover:text-amber-300"
                >{gettext("Configure now →")}</.link>
              </div>

              <button
                class="p-1 rounded-md hover:bg-amber-100 dark:hover:bg-amber-800/50 transition-colors"
                onclick="this.closest('.fixed').remove()"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders the minimal "simple mode" layout: no sidebar, no navigation, just
  flash messages and the page content inside a fixed light `.simple-ui` scope
  that is isolated from the `data-art` art-style system.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  slot(:inner_block, required: true)

  def simple(assigns) do
    ~H"""
    <div class="simple-ui relative h-screen overflow-y-auto flex flex-col bg-white text-slate-900">
      <div class="fixed top-3 right-4 z-50 flex items-center gap-3">
        <.link
          id="nav-tree"
          navigate={~p"/tree"}
          class="text-xs text-slate-400 hover:text-slate-600 transition-colors"
        >
          {gettext("Agent tree")}
        </.link>
        <.simple_theme_selector />
      </div>
      {render_slot(@inner_block)} <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Simple-mode theme switcher (白天/黑夜/水墨/终端), fixed top-right on all
  simple pages. Client-side only — persisted as `phx:simple-theme` in
  localStorage and applied as `data-simple-theme` on <html>; the active option
  is marked client-side via the `.simple-theme-active` class.
  """
  def simple_theme_selector(assigns) do
    ~H"""
    <details id="simple-theme-selector" class="dropdown dropdown-end">
      <summary
        class="btn btn-sm btn-ghost btn-circle rounded-full"
        title={gettext("Art style")}
      >
        <.icon name="hero-swatch" class="size-5" />
      </summary>
      <div class="dropdown-content mt-2 z-50 w-44 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-2">
        <div class="flex flex-col gap-0.5">
          <button
            :for={{id, label} <- simple_themes()}
            class="simple-theme-option flex items-center gap-3 w-full px-3 py-2 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-base-200 text-base-content"
            phx-click={JS.dispatch("phx:set-simple-theme")}
            data-phx-simple-theme={id}
          >
            <span class="flex-1 text-left">{label}</span>
            <.icon name="hero-check-solid" class="simple-theme-check size-4 text-indigo-500 shrink-0" />
          </button>
        </div>
      </div>
    </details>
    """
  end

  # {data-simple-theme value, label} — labels reuse the existing art-style
  # msgids so translations are shared with the pro-mode style selector.
  defp simple_themes do
    [
      {"day", gettext("Default Light")},
      {"night", gettext("Default Dark")},
      {"ink", gettext("Ink Wash")},
      {"terminal", gettext("Terminal")}
    ]
  end

  @doc """
  Small fixed corner link that enters the pro (full) dashboard. Used by all
  simple-mode pages.
  """
  attr(:navigate, :string, default: "/dashboard")

  def pro_corner(assigns) do
    ~H"""
    <.link
      id="pro-corner"
      navigate={@navigate}
      class="fixed bottom-4 right-4 z-50 text-xs text-slate-400 hover:text-slate-600 transition-colors"
    >
      {gettext("Pro")}
    </.link>
    """
  end

  @doc """
  Fixed bottom-right Pro entry for simple-mode pages. (The 任务树 navigation
  link lives in the top-right group next to the theme selector — navigation
  and mode-switch are intentionally separate corners.)
  """
  attr(:navigate, :string, default: "/dashboard")

  def simple_corner(assigns) do
    ~H"""
    <.link
      id="pro-corner"
      navigate={@navigate}
      class="fixed bottom-4 right-4 z-50 text-xs text-slate-400 hover:text-slate-600 transition-colors"
    >
      {gettext("Pro")}
    </.link>
    """
  end

  # Appends the ?node= query param to a path when a remote node is selected,
  # so nav links preserve the node context across pages. No-op for local node.
  defp with_node_param(path, nil), do: path
  defp with_node_param(path, node_id), do: path <> "?node=" <> node_id

  # Extract a display label for a task: objective > prompt > truncated task ID
  defp task_label(task) do
    label = task.opts[:objective] || task.opts[:prompt] || String.slice(task.id, 0, 8)

    if String.length(label) > 30 do
      String.slice(label, 0, 30) <> "..."
    else
      label
    end
  end

  # Format a DateTime as a relative elapsed string like "2m ago", "1h ago"
  defp format_elapsed(nil), do: ""

  defp format_elapsed(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 30 -> gettext("just now")
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  # Returns a Tailwind color class for a task status dot
  defp task_status_dot_color(%{status: :running}), do: "bg-green-500"
  defp task_status_dot_color(%{status: :finalizing}), do: "bg-orange-500"
  defp task_status_dot_color(%{status: :pending}), do: "bg-amber-500"
  defp task_status_dot_color(%{status: :completed}), do: "bg-blue-500"
  defp task_status_dot_color(%{status: :failed}), do: "bg-red-500"
  defp task_status_dot_color(%{status: :cancelled}), do: "bg-amber-500"
  defp task_status_dot_color(_), do: "bg-slate-400"

  # Groups running and pending tasks by project name for sidebar display.
  # Returns a list of {project_name, tasks} tuples sorted alphabetically by
  # project name, with unpathed tasks at the top as "Other".
  defp group_tasks_by_project(running_tasks, pending_tasks) do
    all = running_tasks ++ pending_tasks

    grouped =
      Enum.group_by(all, fn task ->
        case task.opts[:path] do
          nil -> nil
          path -> Path.basename(path)
        end
      end)

    {others, named} = Map.pop(grouped, nil, [])

    sorted_named =
      Enum.sort(named, fn {a, _}, {b, _} ->
        String.downcase(a) <= String.downcase(b)
      end)

    sorted_groups =
      Enum.map(sorted_named, fn {name, tasks} ->
        {running, pending} =
          Enum.split_with(tasks, &(&1.status in [:running, :pending, :finalizing]))

        {name, running ++ pending}
      end)

    if others != [] do
      {running, pending} =
        Enum.split_with(others, &(&1.status in [:running, :pending, :finalizing]))

      [{"Other", running ++ pending} | sorted_groups]
    else
      sorted_groups
    end
  end

  attr(:navigate, :string, required: true)
  attr(:current, :boolean, default: false)
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp sidebar_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-all duration-200 w-full",
        @current &&
          "bg-indigo-50 dark:bg-indigo-500/10 text-indigo-700 dark:text-indigo-300 shadow-sm",
        !@current &&
          "text-slate-600 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800 hover:text-slate-900 dark:hover:text-white"
      ]}
      aria-current={if @current, do: "page", else: false}
    >
      <.icon
        name={@icon}
        class={
        "w-5 h-5 transition-colors " <>
        if(@current, do: "text-indigo-500 dark:text-indigo-400", else: "text-slate-400 dark:text-slate-500")
      }
      /> <span class="sidebar-label">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc """
  Maps current page atom to its route path.
  """
  def current_page(:home), do: "/"
  def current_page(:dashboard), do: "/dashboard"
  def current_page(:phx_dashboard), do: "/phoenix/dashboard"
  def current_page(:agents), do: "/agents"
  def current_page(:tasks), do: "/tasks"
  def current_page(:settings), do: "/settings"
  def current_page(:system), do: "/system"
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
      <.flash kind={:info} flash={@flash} /> <.flash kind={:success} flash={@flash} />
      <.flash kind={:error} flash={@flash} /> <.flash kind={:warning} flash={@flash} />
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
    <div class="relative flex p-1 bg-slate-100 dark:bg-slate-800 rounded-full ring-1 ring-slate-200 dark:ring-slate-700 shadow-inner overflow-hidden">
      <!-- Background slider -->
      <div class="absolute inset-y-1 left-1 w-9 rounded-full bg-white dark:bg-slate-700 shadow transition-transform duration-300 ease-out z-0
        [[data-theme-mode=light]_&]:translate-x-9
        [[data-theme-mode=dark]_&]:translate-x-[4.5rem]" />
      <button
        class="relative z-10 p-2 w-9 h-8 flex items-center justify-center rounded-full text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-white transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="w-4 h-4" />
      </button>

      <button
        class="relative z-10 p-2 w-9 h-8 flex items-center justify-center rounded-full text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-white transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="w-4 h-4" />
      </button>

      <button
        class="relative z-10 p-2 w-9 h-8 flex items-center justify-center rounded-full text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-white transition-colors"
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
        class="btn btn-sm btn-ghost btn-circle rounded-full hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
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
                "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300",
              @locale != code &&
                "hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            ]}
            phx-click={JS.dispatch("phx:set-locale", detail: %{locale: code})}
          >
            <span class="flex-1 text-left">{name}</span>
            <.icon
              :if={@locale == code}
              name="hero-check-solid"
              class="size-4 text-indigo-500 shrink-0"
            />
          </button>
        </div>
      </div>
    </details>
    """
  end

  @doc """
  Art style selector dropdown (默认白天 / 默认黑夜 + 23 种艺术风格).
  Client-side only — persisted to localStorage as `phx:art` and applied as the
  `data-art` attribute on <html>; choosing a style also drives `data-theme`
  (default-dark → dark, everything else → light). There is NO separate
  light/dark toggle anymore. The active option is marked client-side via the
  `.art-active` class (toggled by the root.html.heex setArt script).
  """
  attr(:drop_up, :boolean, default: false)

  def art_style_selector(assigns) do
    ~H"""
    <details class={["dropdown", !@drop_up && "dropdown-end", @drop_up && "dropdown-top"]}>
      <summary
        class="btn btn-sm btn-ghost btn-circle rounded-full hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        title={gettext("Art style")}
      >
        <.icon name="hero-swatch" class="size-5" />
      </summary>

      <div class={[
        "dropdown-content",
        (@drop_up && "mb-2") || "mt-2",
        "z-50 w-60 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-2"
      ]}>
        <div class="max-h-80 overflow-y-auto flex flex-col gap-0.5">
          <button
            :for={{id, label, swatch} <- art_styles()}
            class="flex items-center gap-3 w-full px-3 py-2.5 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            phx-click={JS.dispatch("phx:set-art")}
            data-phx-art={id}
          >
            <span class="w-4 h-4 shrink-0 border border-black/25" style={swatch}></span>
            <span class="flex-1 text-left">{label}</span>
            <.icon name="hero-check-solid" class="art-check size-4 text-indigo-500 shrink-0" />
          </button>
        </div>
      </div>
    </details>
    """
  end

  # {data-art value, label, swatch inline style}
  defp art_styles do
    [
      {"default", gettext("Default Light"),
       "background: linear-gradient(135deg, #ffffff 50%, oklch(55% 0.2 265) 50%); border-radius: 50%"},
      {"default-dark", gettext("Default Dark"),
       "background: linear-gradient(135deg, oklch(22% 0.015 260) 50%, oklch(70% 0.2 265) 50%); border-radius: 50%"},
      {"constructivism", gettext("Constructivism"),
       "background: linear-gradient(135deg, oklch(48% 0.21 28) 50%, oklch(92% 0.025 95) 50%)"},
      {"swiss", gettext("Swiss International"),
       "background: #fff; box-shadow: inset 4px 0 0 oklch(54% 0.22 27); border: 1px solid #111"},
      {"terminal", gettext("Terminal"),
       "background: #000; box-shadow: inset 0 -3px 0 oklch(85% 0.28 145); border: 1px solid oklch(85% 0.28 145)"},
      {"ink", gettext("Ink Wash"),
       "background: oklch(94% 0.02 95); box-shadow: inset -4px -3px 0 oklch(45% 0.16 30); border: 1px solid oklch(45% 0.02 60)"},
      {"bauhaus", gettext("Bauhaus"),
       "background: linear-gradient(135deg, oklch(45% 0.18 255) 33%, oklch(55% 0.22 28) 33% 66%, oklch(75% 0.18 90) 66%); border: 1px solid #111"},
      {"memphis", gettext("Memphis"),
       "background: linear-gradient(135deg, oklch(55% 0.25 350) 33%, oklch(70% 0.15 190) 33% 66%, oklch(80% 0.18 95) 66%); border: 2px solid #111"},
      {"brutalism", gettext("Brutalism"),
       "background: linear-gradient(180deg, #f4f4f4, #dcdcdc); border: 2px outset #fff"},
      {"glass", gettext("Glassmorphism"),
       "background: linear-gradient(135deg, oklch(45% 0.15 290), oklch(50% 0.15 330)); border: 1px solid rgba(255,255,255,0.5); border-radius: 4px"},
      {"neumorphism", gettext("Neumorphism"),
       "background: oklch(90% 0.012 250); box-shadow: 2px 2px 4px oklch(75% 0.015 250), -2px -2px 4px #fff; border-radius: 4px"},
      {"cyberpunk", gettext("Cyberpunk"),
       "background: oklch(12% 0.03 290); box-shadow: inset 0 -3px 0 oklch(85% 0.2 195), inset 3px 0 0 oklch(70% 0.28 330)"},
      {"vaporwave", gettext("Vaporwave"),
       "background: linear-gradient(180deg, oklch(30% 0.1 310), oklch(55% 0.18 350))"},
      {"nord", gettext("Nord"),
       "background: oklch(24% 0.02 250); box-shadow: inset 0 -3px 0 oklch(75% 0.1 215)"},
      {"gruvbox", gettext("Gruvbox"),
       "background: oklch(24% 0.025 70); box-shadow: inset 0 -3px 0 oklch(75% 0.15 90)"},
      {"solarized-light", gettext("Solarized Light"),
       "background: oklch(95% 0.025 95); box-shadow: inset 0 -3px 0 oklch(50% 0.12 230)"},
      {"solarized-dark", gettext("Solarized Dark"),
       "background: oklch(22% 0.03 220); box-shadow: inset 0 -3px 0 oklch(65% 0.12 230)"},
      {"mono", gettext("Monochrome"),
       "background: linear-gradient(135deg, #fff 50%, #111 50%); border: 1px solid #111"},
      {"blueprint", gettext("Blueprint"),
       "background: oklch(30% 0.1 255); border: 1px dashed rgba(255,255,255,0.85)"},
      {"kraft", gettext("Kraft Paper"),
       "background: oklch(80% 0.05 85); box-shadow: inset -3px -3px 0 oklch(50% 0.14 30); border: 1px solid oklch(45% 0.08 70)"}
    ] ++
      [
        {"botanical", gettext("Botanical"),
         "background: oklch(95% 0.02 120); box-shadow: inset 0 -3px 0 oklch(40% 0.08 145)"},
        {"noir", gettext("Film Noir"), "background: #0c0c0c; box-shadow: inset 3px 0 0 #fff"},
        {"pastel", gettext("Pastel"),
         "background: oklch(97% 0.015 340); box-shadow: inset 0 -3px 0 oklch(70% 0.1 340); border-radius: 4px"},
        {"ocean", gettext("Ocean"),
         "background: oklch(20% 0.05 230); box-shadow: inset 0 -3px 0 oklch(70% 0.14 210)"},
        {"desert", gettext("Desert"),
         "background: oklch(90% 0.035 90); box-shadow: inset 0 -3px 0 oklch(48% 0.14 40); border: 1px solid oklch(48% 0.14 40)"},
        {"artdeco", gettext("Art Deco"),
         "background: oklch(18% 0.04 220); border: 1px solid oklch(70% 0.12 90)"}
      ]
  end
end
