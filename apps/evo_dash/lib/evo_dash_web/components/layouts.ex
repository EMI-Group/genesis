defmodule EvoDashWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
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

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <div class="relative min-h-screen bg-slate-50 dark:bg-slate-950 transition-colors duration-300">
      <input id="mobile-nav-drawer" type="checkbox" class="hidden peer" />

      <div class="flex flex-col min-h-screen">
        <!-- Sticky Navigation Bar -->
        <header class="sticky top-0 z-40 bg-white/80 dark:bg-slate-900/80 backdrop-blur-md border-b border-slate-200 dark:border-slate-800 shadow-sm">
          <nav class="flex items-center justify-between px-4 sm:px-6 lg:px-8 h-16">
            <!-- Left: Logo -->
            <div class="flex-shrink-0">
              <%!-- Brand name: Genesis (启元/啟元) --%>
              <.link navigate={~p"/"} class="flex items-center gap-2 hover:opacity-80 transition-opacity">
                <img src={~p"/images/logo.svg"} class="h-8 w-auto block dark:hidden" alt="Genesis" />
                <img src={~p"/images/logo-alt.svg"} class="h-8 w-auto hidden dark:block" alt="Genesis" />
                <span class="text-xl font-bold tracking-tight text-slate-900 dark:text-white">
                  Gen<span class="text-indigo-600 dark:text-indigo-400">esis</span>
                </span>
              </.link>
            </div>

            <!-- Right: Desktop Nav Links + Theme Toggle -->
            <div class="hidden lg:flex items-center gap-2">
              <div class="flex items-center gap-1">
                <.nav_link navigate={~p"/"} current={@current_page == :dashboard} icon="hero-squares-2x2">{gettext("Projects")}</.nav_link>
                <.nav_link navigate={~p"/agents"} current={@current_page == :agents} icon="hero-server">{gettext("Agents")}</.nav_link>
                <.nav_link navigate={~p"/tasks"} current={@current_page == :tasks} icon="hero-clipboard-document-list">{gettext("Tasks")}</.nav_link>
                <.nav_link navigate={~p"/settings"} current={@current_page == :settings} icon="hero-cog-6-tooth">{gettext("Settings")}</.nav_link>
                <.nav_link navigate={~p"/help"} current={@current_page == :help} icon="hero-question-mark-circle">{gettext("Help")}</.nav_link>
              </div>
              <div class="w-px h-6 bg-slate-200 dark:bg-slate-700 mx-2"></div>
              <.theme_toggle />
            </div>

            <!-- Mobile: Hamburger button -->
            <div class="flex lg:hidden items-center">
              <label for="mobile-nav-drawer" class="p-2 -mr-2 text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-white cursor-pointer rounded-md hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors">
                <.icon name="hero-bars-3" class="w-6 h-6" />
              </label>
            </div>
          </nav>
        </header>

        <!-- Main Content Area -->
        <main class="flex-1 px-4 sm:px-6 lg:px-8 py-8 w-full mx-auto max-w-7xl xl:max-w-[1600px] 2xl:max-w-[1920px]">
          {render_slot(@inner_block)}
        </main>
      </div>

      <!-- Drawer Overlay -->
      <label for="mobile-nav-drawer" class="fixed inset-0 z-50 bg-slate-900/50 backdrop-blur-sm opacity-0 pointer-events-none peer-checked:opacity-100 peer-checked:pointer-events-auto transition-opacity duration-300 lg:hidden"></label>

      <!-- Drawer Sidebar -->
      <div class="fixed top-0 right-0 z-50 h-full w-72 bg-white dark:bg-slate-900 shadow-2xl transform translate-x-full peer-checked:translate-x-0 transition-transform duration-300 ease-in-out lg:hidden border-l border-slate-200 dark:border-slate-800 flex flex-col">
        <div class="flex items-center justify-between h-16 px-4 border-b border-slate-200 dark:border-slate-800">
          <span class="text-lg font-bold text-slate-900 dark:text-white">Menu</span>
          <label for="mobile-nav-drawer" class="p-2 text-slate-500 hover:text-slate-900 dark:hover:text-white cursor-pointer rounded-md hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors">
            <.icon name="hero-x-mark" class="w-6 h-6" />
          </label>
        </div>

        <nav class="flex-1 px-4 py-6 space-y-2 overflow-y-auto">
          <.mobile_nav_link navigate={~p"/"} current={@current_page == :dashboard} icon="hero-squares-2x2">{gettext("Projects")}</.mobile_nav_link>
          <.mobile_nav_link navigate={~p"/agents"} current={@current_page == :agents} icon="hero-server">{gettext("Agents")}</.mobile_nav_link>
          <.mobile_nav_link navigate={~p"/tasks"} current={@current_page == :tasks} icon="hero-clipboard-document-list">{gettext("Tasks")}</.mobile_nav_link>
          <.mobile_nav_link navigate={~p"/settings"} current={@current_page == :settings} icon="hero-cog-6-tooth">{gettext("Settings")}</.mobile_nav_link>
          <.mobile_nav_link navigate={~p"/help"} current={@current_page == :help} icon="hero-question-mark-circle">{gettext("Help")}</.mobile_nav_link>
        </nav>

        <div class="p-4 border-t border-slate-200 dark:border-slate-800">
          <div class="flex justify-center">
            <.theme_toggle />
          </div>
        </div>
      </div>

      <!-- Config Warning Banner -->
      <%= if @config_status && not @config_status.ok? do %>
        <div class="fixed bottom-4 right-4 z-40 max-w-sm w-full animate-fade-in-up">
          <div class="bg-amber-50 dark:bg-amber-900/30 text-amber-900 dark:text-amber-200 rounded-xl shadow-lg border border-amber-200 dark:border-amber-800 p-4">
            <div class="flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0 mt-0.5 text-amber-600 dark:text-amber-500" />
              <div class="flex-1 min-w-0">
                <p class="font-semibold text-sm">{gettext("Missing Configuration")}</p>
                <ul class="mt-1 space-y-0.5">
                  <%= for warning <- @config_status.warnings do %>
                    <li class="text-xs opacity-90">{warning}</li>
                  <% end %>
                </ul>
                <.link navigate={~p"/settings"} class="text-xs font-medium underline mt-2 inline-block hover:text-amber-700 dark:hover:text-amber-300">{gettext("Configure now →")}</.link>
              </div>
              <button class="p-1 rounded-md hover:bg-amber-100 dark:hover:bg-amber-800/50 transition-colors" onclick="this.closest('.fixed').remove()">
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

  attr(:navigate, :string, required: true)
  attr(:current, :boolean, default: false)
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "group flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium transition-all duration-200",
        @current && "bg-white dark:bg-slate-800 text-slate-900 dark:text-white shadow-sm ring-1 ring-slate-200 dark:ring-slate-700",
        !@current && "text-slate-600 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800/50 hover:text-slate-900 dark:hover:text-white"
      ]}
      aria-current={if @current, do: "page", else: false}
    >
      <.icon name={@icon} class={
        "w-4 h-4 transition-colors " <>
        if(@current, do: "text-indigo-600 dark:text-indigo-400", else: "text-slate-400 dark:text-slate-500 group-hover:text-slate-600 dark:group-hover:text-slate-400")
      } />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:navigate, :string, required: true)
  attr(:current, :boolean, default: false)
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp mobile_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 px-4 py-3 rounded-xl text-base font-medium transition-colors",
        @current && "bg-indigo-50 dark:bg-indigo-500/10 text-indigo-700 dark:text-indigo-400",
        !@current && "text-slate-600 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800/50 hover:text-slate-900 dark:hover:text-white"
      ]}
      aria-current={if @current, do: "page", else: false}
    >
      <.icon name={@icon} class={
        "w-5 h-5 " <>
        if(@current, do: "text-indigo-600 dark:text-indigo-400", else: "text-slate-400 dark:text-slate-500")
      } />
      {render_slot(@inner_block)}
    </.link>
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
  def current_page(:help), do: "/help"
  def current_page(:review), do: "/review/:task_id"

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
      <div class="absolute inset-y-1 left-1 w-8 rounded-full bg-white dark:bg-slate-700 shadow transition-transform duration-300 ease-out z-0
        [[data-theme=light]_&]:translate-x-9
        [[data-theme=dark]_&]:translate-x-[4.5rem]"
      />

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
end
