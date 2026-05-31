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

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

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
    <div class="flex h-full">
      <!-- Desktop Sidebar (lg+) -->
      <aside class="hidden lg:flex flex-col w-16 hover:w-56 transition-all duration-300 ease-in-out bg-base-200/50 border-r border-base-200/50 shrink-0 overflow-hidden group/sidebar z-40">
        <!-- Logo -->
        <div class="flex items-center gap-3 px-4 h-16 shrink-0 border-b border-base-200/50">
          <.link navigate={~p"/"} class="flex items-center gap-3 text-lg font-bold tracking-tight hover:opacity-80 transition-opacity">
            <.icon name="hero-code-bracket-square" class="size-6 text-primary shrink-0" />
            <span class="whitespace-nowrap opacity-0 group-hover/sidebar:opacity-100 transition-opacity duration-200">EvoGit</span>
          </.link>
        </div>

        <!-- Nav Links -->
        <nav class="flex-1 py-4 space-y-1 px-2">
          <.link navigate={~p"/"} class={["sidebar-nav-item flex items-center gap-3 px-3 py-3 rounded-xl text-sm font-medium", @current_page == :dashboard && "bg-primary/10 text-primary", @current_page != :dashboard && "text-base-content/60 hover:bg-base-200/80 hover:text-base-content"]}>
            <.icon name="hero-squares-2x2" class="size-5 shrink-0" />
            <span class="whitespace-nowrap opacity-0 group-hover/sidebar:opacity-100 transition-opacity duration-200">Dashboard</span>
          </.link>
          <.link navigate={~p"/agents"} class={["sidebar-nav-item flex items-center gap-3 px-3 py-3 rounded-xl text-sm font-medium", @current_page == :agents && "bg-primary/10 text-primary", @current_page != :agents && "text-base-content/60 hover:bg-base-200/80 hover:text-base-content"]}>
            <.icon name="hero-server" class="size-5 shrink-0" />
            <span class="whitespace-nowrap opacity-0 group-hover/sidebar:opacity-100 transition-opacity duration-200">Agents</span>
          </.link>
          <.link navigate={~p"/settings"} class={["sidebar-nav-item flex items-center gap-3 px-3 py-3 rounded-xl text-sm font-medium", @current_page == :settings && "bg-primary/10 text-primary", @current_page != :settings && "text-base-content/60 hover:bg-base-200/80 hover:text-base-content"]}>
            <.icon name="hero-cog-6-tooth" class="size-5 shrink-0" />
            <span class="whitespace-nowrap opacity-0 group-hover/sidebar:opacity-100 transition-opacity duration-200">Settings</span>
          </.link>
          <.link navigate={~p"/help"} class={["sidebar-nav-item flex items-center gap-3 px-3 py-3 rounded-xl text-sm font-medium", @current_page == :help && "bg-primary/10 text-primary", @current_page != :help && "text-base-content/60 hover:bg-base-200/80 hover:text-base-content"]}>
            <.icon name="hero-question-mark-circle" class="size-5 shrink-0" />
            <span class="whitespace-nowrap opacity-0 group-hover/sidebar:opacity-100 transition-opacity duration-200">Help</span>
          </.link>
        </nav>

        <!-- Theme toggle at bottom of sidebar -->
        <div class="py-4 px-2 border-t border-base-200/50 flex justify-center group-hover/sidebar:justify-start group-hover/sidebar:px-3 transition-all duration-200">
          <div class="opacity-0 group-hover/sidebar:opacity-100 transition-opacity duration-200">
            <.theme_toggle />
          </div>
          <div class="group-hover/sidebar:hidden flex items-center justify-center w-10 h-10">
            <.icon name="hero-swatch" class="size-5 text-base-content/40" />
          </div>
        </div>
      </aside>

      <!-- Main Content Area -->
      <div class="flex-1 flex flex-col min-w-0 h-full">
        <!-- Mobile Top Bar (header, < lg) -->
        <header class="lg:hidden sticky top-0 z-40 bg-base-100/80 backdrop-blur-xl border-b border-base-200/50 shrink-0">
          <div class="flex items-center justify-between px-4 h-14">
            <.link navigate={~p"/"} class="flex items-center gap-2 text-lg font-bold tracking-tight">
              <.icon name="hero-code-bracket-square" class="size-6 text-primary" />
              <span>EvoGit</span>
            </.link>
            <.theme_toggle />
          </div>
        </header>

        <!-- Page Content (scroll region managed by pages) -->
        <main class="flex-1 overflow-hidden pb-0 lg:pb-0">
          <div class="h-full pb-20 lg:pb-0">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <!-- Mobile Bottom Navigation (< lg) -->
    <nav class="lg:hidden fixed bottom-0 inset-x-0 z-50 bg-base-100/80 backdrop-blur-xl border-t border-base-200/50 pb-safe">
      <div class="flex items-center justify-around h-16">
        <.link navigate={~p"/"} class={["flex flex-col items-center justify-center gap-0.5 min-w-[44px] min-h-[44px] press-scale", @current_page == :dashboard && "text-primary", @current_page != :dashboard && "text-base-content/50"]}>
          <.icon name="hero-squares-2x2" class="size-5" />
          <span class="text-[10px] font-medium">Dashboard</span>
        </.link>
        <.link navigate={~p"/agents"} class={["flex flex-col items-center justify-center gap-0.5 min-w-[44px] min-h-[44px] press-scale", @current_page == :agents && "text-primary", @current_page != :agents && "text-base-content/50"]}>
          <.icon name="hero-server" class="size-5" />
          <span class="text-[10px] font-medium">Agents</span>
        </.link>
        <.link navigate={~p"/settings"} class={["flex flex-col items-center justify-center gap-0.5 min-w-[44px] min-h-[44px] press-scale", @current_page == :settings && "text-primary", @current_page != :settings && "text-base-content/50"]}>
          <.icon name="hero-cog-6-tooth" class="size-5" />
          <span class="text-[10px] font-medium">Settings</span>
        </.link>
        <.link navigate={~p"/help"} class={["flex flex-col items-center justify-center gap-0.5 min-w-[44px] min-h-[44px] press-scale", @current_page == :help && "text-primary", @current_page != :help && "text-base-content/50"]}>
          <.icon name="hero-question-mark-circle" class="size-5" />
          <span class="text-[10px] font-medium">Help</span>
        </.link>
      </div>
    </nav>

    <!-- Config Warning Banner -->
    <%= if @config_status && not @config_status.ok? do %>
      <div class="fixed bottom-20 lg:bottom-4 left-4 right-4 sm:left-auto sm:right-4 sm:max-w-md z-40 fade-in">
        <div class="bg-warning/95 text-warning-content rounded-xl shadow-2xl p-4 border border-warning/50">
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm">Missing Configuration</p>
              <ul class="mt-1 space-y-0.5">
                <%= for warning <- @config_status.warnings do %>
                  <li class="text-xs opacity-90">{warning}</li>
                <% end %>
              </ul>
              <.link navigate={~p"/help"} class="text-xs underline mt-1 inline-block opacity-80 hover:opacity-100">Configure now →</.link>
            </div>
            <button class="btn btn-xs btn-ghost text-warning-content" onclick="this.closest('.fixed').remove()">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>
      </div>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
