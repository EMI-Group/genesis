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
    <div class="flex h-screen overflow-hidden bg-slate-50 dark:bg-slate-950 transition-colors duration-300" id="app-layout">
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
      <div id="sidebar-overlay" class="fixed inset-0 z-40 bg-slate-900/50 backdrop-blur-sm opacity-0 pointer-events-none transition-opacity duration-300 lg:hidden">
      </div>

      <!-- Sidebar -->
      <aside
        id="sidebar"
        data-sidebar-collapsed="false"
        class="fixed lg:relative z-50 lg:z-auto h-screen flex flex-col bg-white dark:bg-slate-900 border-r border-slate-200 dark:border-slate-800 shadow-sm lg:shadow-none transition-all duration-300 ease-in-out w-60 -translate-x-full lg:translate-x-0 overflow-hidden"
      >
        <!-- Branding -->
        <div class="flex items-center h-14 px-4 border-b border-slate-200 dark:border-slate-800 shrink-0">
          <.link
            navigate={with_node_param(~p"/", @current_node_id)}
            class="flex items-center gap-2.5 hover:opacity-80 transition-opacity min-w-0"
          >
            <%!-- zh_CN: Genesis → "启元" --%>
            <img
              src={~p"/images/logo.svg"}
              class="h-7 w-auto block dark:hidden shrink-0"
              alt={gettext("Genesis")}
            />
            <%!-- zh_CN: Genesis → "启元" --%>
            <img
              src={~p"/images/logo-alt.svg"}
              class="h-7 w-auto hidden dark:block shrink-0"
              alt={gettext("Genesis")}
            />
            <span class="text-lg font-extrabold tracking-tight bg-gradient-to-r from-slate-900 to-slate-700 dark:from-white dark:to-slate-300 bg-clip-text text-transparent truncate sidebar-label">
              <%!-- zh_CN: Genesis → "启元" --%>
              {gettext("Genesis")}
            </span>
          </.link>
        </div>

        <!-- Node Selector -->
        <div class="px-3 py-2 border-b border-slate-200 dark:border-slate-800 shrink-0">
          <.live_component
            module={EvoDashWeb.NodeSelectorComponent}
            id="node-selector"
            current_node_id={@current_node_id}
            current_node_name={@current_node_name}
          />
        </div>

        <!-- Navigation Links -->
        <%= if !@simple_nav do %>
        <nav class="flex-1 px-2 py-3 space-y-0.5 overflow-y-auto">
          <.sidebar_nav_link
            navigate={with_node_param(~p"/", @current_node_id)}
            current={@current_page == :dashboard}
            icon="hero-squares-2x2"
          >{gettext("Projects")}</.sidebar_nav_link>
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
          <.sidebar_nav_link
            navigate={with_node_param(~p"/settings", @current_node_id)}
            current={@current_page == :settings}
            icon="hero-cog-6-tooth"
          >{gettext("Settings")}</.sidebar_nav_link>
          <.sidebar_nav_link
            navigate={with_node_param(~p"/system", @current_node_id)}
            current={@current_page == :system}
            icon="hero-server-stack"
          >{gettext("System")}</.sidebar_nav_link>

          <!-- Task Indicators Section -->
          <div :if={@running_tasks != [] or @pending_tasks != []} class="pt-4 mt-3 border-t border-slate-200 dark:border-slate-800">
            <div class="px-3 mb-2">
              <span class="text-xs font-semibold uppercase tracking-wider text-slate-400 dark:text-slate-500 sidebar-label">
                {gettext("Active Tasks")}
              </span>
            </div>
            <div class="space-y-0.5">
              <!-- Running tasks: green dot -->
              <%= for task <- @running_tasks do %>
                <.link
                  navigate={~p"/tasks?task_id=#{task.id}"}
                  class="flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs text-slate-600 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors group"
                >
                  <span class="w-2 h-2 rounded-full bg-green-500 shrink-0 animate-pulse" title={gettext("Running")}></span>
                  <span class="truncate sidebar-label group-hover:text-slate-900 dark:group-hover:text-white transition-colors">
                    {String.slice(task.id, 0, 8)}
                  </span>
                </.link>
              <% end %>
              <!-- Pending review tasks: amber dot -->
              <%= for task <- @pending_tasks do %>
                <.link
                  navigate={~p"/tasks?task_id=#{task.id}"}
                  class="flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs text-slate-600 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors group"
                >
                  <span class="w-2 h-2 rounded-full bg-amber-500 shrink-0" title={gettext("Pending Review")}></span>
                  <span class="truncate sidebar-label group-hover:text-slate-900 dark:group-hover:text-white transition-colors">
                    {String.slice(task.id, 0, 8)}
                  </span>
                </.link>
              <% end %>
            </div>
          </div>
        </nav>

        <!-- Bottom section: Language + Theme + Collapse -->
        <div class="px-3 py-3 border-t border-slate-200 dark:border-slate-800 shrink-0">
          <div class="flex items-center justify-between gap-1">
            <div class="flex items-center gap-1">
              <.language_selector />
              <.theme_toggle_compact />
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
      <div class="flex-1 flex flex-col overflow-auto min-w-0">
        <main class="flex-1 px-4 sm:px-5 lg:px-6 py-4 w-full mx-auto max-w-7xl xl:max-w-[1600px] 2xl:max-w-[1920px]">
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

    <script>
      (() => {
        const sidebar = document.getElementById('sidebar');
        const overlay = document.getElementById('sidebar-overlay');
        const mobileToggle = document.getElementById('sidebar-mobile-toggle');
        const collapseToggle = document.getElementById('sidebar-collapse-toggle');

        if (!sidebar) return;

        const isCollapsed = () => localStorage.getItem('sidebar-collapsed') === 'true';

        const applyCollapsed = (collapsed) => {
          if (collapsed) {
            sidebar.classList.add('w-16');
            sidebar.classList.remove('w-60');
            sidebar.querySelectorAll('.sidebar-label').forEach(el => el.classList.add('hidden'));
            if (collapseToggle) {
              collapseToggle.innerHTML = collapseToggle.innerHTML.replace(/hero-chevron-double-left/g, 'hero-chevron-double-right');
            }
          } else {
            sidebar.classList.remove('w-16');
            sidebar.classList.add('w-60');
            sidebar.querySelectorAll('.sidebar-label').forEach(el => el.classList.remove('hidden'));
            if (collapseToggle) {
              collapseToggle.innerHTML = collapseToggle.innerHTML.replace(/hero-chevron-double-right/g, 'hero-chevron-double-left');
            }
          }
        };

        // Init collapsed state
        applyCollapsed(isCollapsed());

        // Collapse toggle (desktop only)
        if (collapseToggle) {
          collapseToggle.addEventListener('click', () => {
            const next = !isCollapsed();
            localStorage.setItem('sidebar-collapsed', String(next));
            applyCollapsed(next);
          });
        }

        // Mobile toggle
        const openMobile = () => {
          sidebar.classList.remove('-translate-x-full');
          overlay.classList.add('opacity-100', 'pointer-events-auto');
          overlay.classList.remove('opacity-0', 'pointer-events-none');
        };
        const closeMobile = () => {
          sidebar.classList.add('-translate-x-full');
          overlay.classList.remove('opacity-100', 'pointer-events-auto');
          overlay.classList.add('opacity-0', 'pointer-events-none');
        };

        if (mobileToggle) mobileToggle.addEventListener('click', openMobile);
        if (overlay) overlay.addEventListener('click', closeMobile);
      })();
    </script>
    """
  end

  # Appends the ?node= query param to a path when a remote node is selected,
  # so nav links preserve the node context across pages. No-op for local node.
  defp with_node_param(path, nil), do: path
  defp with_node_param(path, node_id), do: path <> "?node=" <> node_id

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
      />
      <span class="sidebar-label">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  # Compact theme toggle for sidebar bottom bar — a single button with a dropdown
  # containing the three theme options: system, light, dark.
  defp theme_toggle_compact(assigns) do
    ~H"""
    <details class="dropdown dropdown-end">
      <summary
        class="btn btn-sm btn-ghost btn-circle rounded-full hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        title={gettext("Change theme")}
      >
        <.icon name="hero-swatch" class="size-4" />
      </summary>
      <div class="dropdown-content mt-2 z-50 w-40 rounded-xl border border-base-200 bg-base-100/95 backdrop-blur-md shadow-xl p-1">
        <div class="flex flex-col gap-0.5">
          <button
            class="flex items-center gap-3 w-full px-3 py-2 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="system"
          >
            <.icon name="hero-computer-desktop-micro" class="w-4 h-4" />
            <span>{gettext("System")}</span>
          </button>
          <button
            class="flex items-center gap-3 w-full px-3 py-2 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="light"
          >
            <.icon name="hero-sun-micro" class="w-4 h-4" />
            <span>{gettext("Light")}</span>
          </button>
          <button
            class="flex items-center gap-3 w-full px-3 py-2 rounded-lg text-sm font-medium transition-colors cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-300"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="dark"
          >
            <.icon name="hero-moon-micro" class="w-4 h-4" />
            <span>{gettext("Dark")}</span>
          </button>
        </div>
      </div>
    </details>
    """
  end

  @doc """
  Maps current page atom to its route path.
  """
  def current_page(:dashboard), do: "/"
  def current_page(:phx_dashboard), do: "/dashboard"
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
    <div id={@id} aria-live="polite">
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
    <details class={["dropdown", "dropdown-end", @drop_up && "dropdown-top"]}>
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
end
