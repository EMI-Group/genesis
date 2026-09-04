defmodule EvoDashWeb.SettingsComponents.SaveBar do
  @moduledoc """
  `save_bar/1` — Sticky bottom save bar for the settings content panes
  (generic category sections, the LLM flat-cards form, and search results).

  Must be rendered INSIDE a `<.form>`/`<form>` — the button is
  `type="submit"` and submits the enclosing form.
  """

  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # save_bar/1 — Sticky bottom save bar
  # ───────────────────────────────────────────────────────────────────────────

  attr(:label, :string, required: true)

  def save_bar(assigns) do
    ~H"""
    <div class="sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 p-4 flex justify-end">
      <button type="submit" class="btn btn-primary rounded-md min-w-[200px] font-bold">
        <.icon name="hero-document-check" class="size-5 mr-1.5" />
        {@label}
      </button>
    </div>
    """
  end
end
