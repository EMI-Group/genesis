defmodule EvoDashWeb.SettingsComponents.SectionHeader do
  @moduledoc """
  `section_header/1` — Sticky top section header for the settings content
  panes (category sections and search results): icon + title + description.
  """

  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # section_header/1 — Sticky top section header
  # ───────────────────────────────────────────────────────────────────────────

  attr(:icon, :string, required: true)
  attr(:title, :string, required: true)
  attr(:description, :string, required: true)

  def section_header(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-xl border-b border-base-200/60 px-8 py-6">
      <div class="flex items-center gap-3 mb-1">
        <div class="text-primary/60">
          <.icon name={@icon} class="size-5" />
        </div>
        <h2 class="text-lg font-bold tracking-tight text-base-content">
          {@title}
        </h2>
      </div>
      <p class="text-sm font-medium text-base-content/80">{@description}</p>
    </div>
    """
  end
end
