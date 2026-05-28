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
  embed_templates "layouts/*"

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
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_page, :atom,
    default: nil,
    doc: "the current page atom (:dashboard, :agents, :config_help) for active nav highlighting"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <!-- Sticky Navigation Bar -->
    <header class="sticky top-0 z-50 bg-base-100/80 backdrop-blur-md border-b border-base-200/50">
      <nav class="navbar px-4 sm:px-6 lg:px-8 max-w-7xl mx-auto">
        <!-- Left: Logo -->
        <div class="flex-1">
          <a href="/" class="flex items-center gap-2 text-lg font-bold tracking-tight hover:opacity-80 transition-opacity">
            <.icon name="hero-code-bracket-square" class="size-6 text-primary" />
            <span>EvoGit</span>
          </a>
        </div>

        <!-- Right: Desktop Nav Links + Theme Toggle -->
        <div class="flex-none hidden lg:flex items-center gap-1">
          <ul class="flex items-center gap-1 px-2">
            <li>
              <a
                href="/"
                class={["btn btn-sm btn-ghost gap-2", @current_page == :dashboard && "btn-active"]}
                aria-current={@current_page == :dashboard && "page"}
              >
                <.icon name="hero-squares-2x2" class="size-4" /> Dashboard
              </a>
            </li>
            <li>
              <a
                href="/agents"
                class={["btn btn-sm btn-ghost gap-2", @current_page == :agents && "btn-active"]}
                aria-current={@current_page == :agents && "page"}
              >
                <.icon name="hero-server" class="size-4" /> Agents
              </a>
            </li>
            <li>
              <a
                href="/config-help"
                class={["btn btn-sm btn-ghost gap-2", @current_page == :config_help && "btn-active"]}
                aria-current={@current_page == :config_help && "page"}
              >
                <.icon name="hero-cog-6-tooth" class="size-4" /> Config
              </a>
            </li>
          </ul>
          <div class="divider divider-horizontal mx-1 h-6"></div>
          <.theme_toggle />
        </div>

        <!-- Mobile: Hamburger Menu -->
        <details class="dropdown dropdown-end lg:hidden flex-none">
          <summary class="btn btn-ghost btn-sm">
            <.icon name="hero-bars-3" class="size-5" />
          </summary>
          <ul class="menu menu-sm dropdown-content mt-3 z-[1] p-2 shadow-lg bg-base-100 rounded-box w-52 border border-base-200">
            <li>
              <a
                href="/"
                class={@current_page == :dashboard && "active"}
                aria-current={@current_page == :dashboard && "page"}
              >
                <.icon name="hero-squares-2x2" class="size-4" /> Dashboard
              </a>
            </li>
            <li>
              <a
                href="/agents"
                class={@current_page == :agents && "active"}
                aria-current={@current_page == :agents && "page"}
              >
                <.icon name="hero-server" class="size-4" /> Agents
              </a>
            </li>
            <li>
              <a
                href="/config-help"
                class={@current_page == :config_help && "active"}
                aria-current={@current_page == :config_help && "page"}
              >
                <.icon name="hero-cog-6-tooth" class="size-4" /> Config Help
              </a>
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
      <div class="mx-auto max-w-7xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash kind={:warning} flash={@flash} />

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
