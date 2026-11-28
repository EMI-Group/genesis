defmodule EvoDashWeb.DesktopTitlebar do
  @moduledoc """
  Desktop-only layer-0 chrome: the custom window title bar of the Tauri shell.

  The shell KEEPS the native OS decorations until the dashboard explicitly asks
  for frameless chrome through the Tauri command `set_custom_titlebar` with
  `%{active: true}`, which the `DesktopTitlebar` JS hook calls once the strip is
  live.
  Sending `%{active: false}` — or starting any navigation — restores the native
  chrome, so a strip that never mounts leaves the native OS title bar in place
  instead of an unclosable chrome-less window.
  macOS additionally uses an overlay title bar with a hidden title, so the
  native traffic lights hover over the dashboard's own strip, which reserves
  that space through CSS.
  The strip is rendered for every desktop page (only when the `:desktop?`
  on-mount assign is true) as the FIRST child of the app shell.
  It is IN FLOW — the first child of `#app-layout`, which is a flex column — so
  it needs no z-index; its surface and hairline come from `--surface-shell` /
  `--border-hairline` and its height from `--shell-titlebar-h` in
  `assets/css/workbench.css`.

  Stable element contract (the `DesktopTitlebar` JS hook only reads
  attributes, never text):

    * `#desktop-titlebar` — the strip root, `data-os` (`linux|macos|windows|unknown`)
    * `.desktop-titlebar-brand` — the shared brand link (`brand/1`)
    * `.desktop-titlebar-drag` — the flex spacer between brand and controls
    * `.desktop-titlebar-controls` — rendered on EVERY non-macOS OS
      (`windows`, `linux` and an `unknown` OS, which is treated as windowed);
      macOS renders none because its native traffic lights hover over the strip
    * `#desktop-titlebar-minimize` / `#desktop-titlebar-maximize` /
      `#desktop-titlebar-close` — the three window controls
    * `.desktop-titlebar-glyph-maximize` / `.desktop-titlebar-glyph-restore` —
      the maximize button's two glyphs; the hook toggles the `hidden` CLASS
      because an SVG element ignores the `hidden` attribute

  The `DesktopTitlebar` JS hook owns pointer dragging and title-bar
  double-click maximize, so there is exactly ONE drag path.
  There is deliberately NO `data-tauri-drag-region` attribute anywhere in this
  markup: Tauri injects its own document-level drag handler whenever that
  attribute is present, which would double-fire against the hook's pointer
  handler.
  """

  use EvoDashWeb, :html

  @doc """
  The window title bar strip — brand, drag spacer, and the minimize /
  maximize / close controls (every OS except macOS).
  """
  attr(:os, :atom,
    default: :unknown,
    doc:
      "the host OS (`:linux | :macos | :windows | :unknown`); every OS except macOS renders the window controls, and an `unknown` OS is treated as windowed"
  )

  attr(:current_node_id, :string,
    default: nil,
    doc: "the SSH remote target id, threaded into the brand link"
  )

  def titlebar(assigns) do
    ~H"""
    <div
      id="desktop-titlebar"
      class="desktop-titlebar"
      data-os={to_string(@os)}
      role="group"
      aria-label={gettext("Application window")}
      phx-hook="DesktopTitlebar"
    >
      <.brand
        current_node_id={@current_node_id}
        class="h-5 w-auto"
        label_class="text-sm"
        link_class="desktop-titlebar-brand"
      />
      <div class="desktop-titlebar-drag" aria-hidden="true"></div>
      <div :if={@os not in [:macos]} class="desktop-titlebar-controls">
        <button
          id="desktop-titlebar-minimize"
          type="button"
          class="desktop-titlebar-control"
          aria-label={gettext("Minimize")}
          title={gettext("Minimize")}
        >
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.2"
            stroke-linecap="round"
            width="16"
            height="16"
            aria-hidden="true"
            focusable="false"
          >
            <line x1="3" y1="8" x2="13" y2="8" />
          </svg>
        </button>
        <button
          id="desktop-titlebar-maximize"
          type="button"
          class="desktop-titlebar-control"
          data-maximized="false"
          aria-label={gettext("Maximize")}
          title={gettext("Maximize")}
        >
          <svg
            class="desktop-titlebar-glyph-maximize"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.2"
            stroke-linecap="round"
            width="16"
            height="16"
            aria-hidden="true"
            focusable="false"
          >
            <rect x="3" y="3" width="10" height="10" rx="1" />
          </svg>
          <svg
            class="desktop-titlebar-glyph-restore hidden"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.2"
            stroke-linecap="round"
            width="16"
            height="16"
            aria-hidden="true"
            focusable="false"
          >
            <rect x="2.5" y="5.5" width="8" height="8" rx="1" />
            <path d="M5.5 5.5v-2a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-2" />
          </svg>
        </button>
        <button
          id="desktop-titlebar-close"
          type="button"
          class="desktop-titlebar-control desktop-titlebar-control-close"
          aria-label={gettext("Close")}
          title={gettext("Close")}
        >
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.2"
            stroke-linecap="round"
            width="16"
            height="16"
            aria-hidden="true"
            focusable="false"
          >
            <line x1="3" y1="3" x2="13" y2="13" />
            <line x1="13" y1="3" x2="3" y2="13" />
          </svg>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The ONE brand markup of the shell (logo + wordmark), reused by the title bar
  and by the sidebar's brand row outside desktop mode.

  `class` carries the `<img>` sizing, `label_class` the wordmark span classes
  (so the sidebar keeps its `text-base`/`sidebar-label` wordmark while the
  strip uses `text-sm`) and `link_class` any extra link classes — the title bar
  marks its link with `desktop-titlebar-brand` and the sidebar stays untouched.
  """
  attr(:current_node_id, :string, default: nil, doc: "the SSH remote target id")
  attr(:class, :string, default: nil, doc: "the <img> sizing")
  attr(:label_class, :string, default: nil, doc: "the wordmark span classes")
  attr(:link_class, :string, default: nil, doc: "extra brand link classes")

  def brand(assigns) do
    ~H"""
    <.link
      navigate={with_node_param(~p"/", @current_node_id)}
      class={[
        "flex items-center gap-2 rounded-md hover:opacity-80 transition-opacity min-w-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone",
        @link_class
      ]}
    >
      <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
      <img
        src={~p"/images/logo.svg"}
        class={[@class, "block dark:hidden shrink-0"]}
        alt={gettext("EvoX Genesis")}
      />
      <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
      <img
        src={~p"/images/logo-alt.svg"}
        class={[@class, "hidden dark:block shrink-0"]}
        alt={gettext("EvoX Genesis")}
      />
      <span class={["font-semibold tracking-tight text-base-content truncate", @label_class]}>
        <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
        {gettext("EvoX Genesis")}
      </span>
    </.link>
    """
  end
end
