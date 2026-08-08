defmodule EvoDashWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.

  The old sidebar-based `app/1` shell is RETIRED (archived with the classic
  dashboard interface): every page now renders the pad chrome directly —
  `EvoDashWeb.PadComponents.pad_top_bar/1` + a `<main>` wrapper — and calls
  `flash_group/1` itself.
  """

  # zh_CN: Genesis → "启元"

  use EvoDashWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

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
end
