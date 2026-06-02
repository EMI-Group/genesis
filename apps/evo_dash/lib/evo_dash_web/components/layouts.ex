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
    <!-- Sticky Navigation Bar -->
    <header class="sticky top-0 z-50 bg-base-100/80 backdrop-blur-md border-b border-base-200/50">
      <nav class="navbar px-6 sm:px-8 lg:px-12 xl:px-16">
        <!-- Left: Logo -->
        <div class="flex-1">
          <.link navigate={~p"/"} class="flex items-center gap-2.5 hover:opacity-80 transition-opacity group">
            <img src={~p"/images/logo.svg"} class="h-8 w-auto block dark:hidden" alt="EvoGit" />
            <img src={~p"/images/logo-alt.svg"} class="h-8 w-auto hidden dark:block" alt="EvoGit" />
            <span class="text-xl font-extrabold tracking-tight">
              Evo<span class="text-primary">Git</span>
            </span>
          </.link>
        </div>

        <!-- Right: Desktop Nav Links + Theme Toggle -->
        <div class="flex-none hidden lg:flex items-center gap-1">
          <ul class="flex items-center gap-1 px-2">
            <li>
              <.link
                navigate={~p"/"}
                class={["btn btn-ghost gap-2", @current_page == :dashboard && "btn-active"]}
                aria-current={@current_page == :dashboard && "page"}
              >
                <.icon name="hero-squares-2x2" class="size-4" /> {gettext("Dashboard")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/tasks"}
                class={["btn btn-ghost gap-2", @current_page == :tasks && "btn-active"]}
                aria-current={@current_page == :tasks && "page"}
              >
                <.icon name="hero-clipboard-document-list" class="size-4" /> {gettext("Tasks")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/agents"}
                class={["btn btn-ghost gap-2", @current_page == :agents && "btn-active"]}
                aria-current={@current_page == :agents && "page"}
              >
                <.icon name="hero-server" class="size-4" /> {gettext("Agents")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/settings"}
                class={["btn btn-ghost gap-2", @current_page == :settings && "btn-active"]}
                aria-current={@current_page == :settings && "page"}
              >
                <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("Settings")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/help"}
                class={["btn btn-ghost gap-2", @current_page == :help && "btn-active"]}
                aria-current={@current_page == :help && "page"}
              >
                <.icon name="hero-question-mark-circle" class="size-4" /> {gettext("Help")}
              </.link>
            </li>
          </ul>
          <div class="divider divider-horizontal mx-1 h-6"></div>
          <.theme_toggle />
        </div>

        <!-- Mobile: Hamburger Menu -->
        <details class="dropdown dropdown-end lg:hidden flex-none">
          <summary class="btn btn-ghost">
            <.icon name="hero-bars-3" class="size-5" />
          </summary>
          <ul class="menu menu-sm dropdown-content mt-3 z-[1] p-2 shadow-lg bg-base-100 rounded-box w-52 border border-base-200">
            <li>
              <.link
                navigate={~p"/"}
                class={@current_page == :dashboard && "active"}
                aria-current={@current_page == :dashboard && "page"}
              >
                <.icon name="hero-squares-2x2" class="size-4" /> {gettext("Dashboard")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/tasks"}
                class={@current_page == :tasks && "active"}
                aria-current={@current_page == :tasks && "page"}
              >
                <.icon name="hero-clipboard-document-list" class="size-4" /> {gettext("Tasks")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/agents"}
                class={@current_page == :agents && "active"}
                aria-current={@current_page == :agents && "page"}
              >
                <.icon name="hero-server" class="size-4" /> {gettext("Agents")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/settings"}
                class={@current_page == :settings && "active"}
                aria-current={@current_page == :settings && "page"}
              >
                <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("Settings")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/help"}
                class={@current_page == :help && "active"}
                aria-current={@current_page == :help && "page"}
              >
                <.icon name="hero-question-mark-circle" class="size-4" /> {gettext("Help")}
              </.link>
            </li>
            <li class="mt-2 flex justify-center">
              <.theme_toggle />
            </li>
          </ul>
        </details>
      </nav>
    </header>

    <!-- Main Content Area -->
    <main class="px-4 pt-8 pb-12 sm:px-6 lg:px-8">
      <div class="mx-auto space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <!-- Config Warning Banner -->
    <%= if @config_status && not @config_status.ok? do %>
      <div class="fixed bottom-4 left-4 right-4 sm:left-auto sm:right-4 sm:max-w-md z-40">
        <div class="bg-warning/95 text-warning-content rounded-xl shadow-2xl p-4 border border-warning/50">
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm">{gettext("Missing Configuration")}</p>
              <ul class="mt-1 space-y-0.5">
                <%= for warning <- @config_status.warnings do %>
                  <li class="text-xs opacity-90">{warning}</li>
                <% end %>
              </ul>
              <.link navigate={~p"/settings"} class="text-xs underline mt-1 inline-block opacity-80 hover:opacity-100">{gettext("Configure now →")}</.link>
            </div>
            <button class="btn btn-sm btn-ghost text-warning-content" onclick="this.closest('.fixed').remove()">
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
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
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
