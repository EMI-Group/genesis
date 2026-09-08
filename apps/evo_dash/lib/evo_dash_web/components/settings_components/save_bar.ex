defmodule EvoDashWeb.SettingsComponents.SaveBar do
  @moduledoc """
  `save_bar/1` — Minimal pinned bottom-right save bar for the settings
  content panes (generic category sections, the LLM category, and search
  results).

  Rendered as a NON-scrolling flex sibling of the pane's `flex-1
  overflow-y-auto` scroll body; the button is `type="submit"`.

  When rendered inside the owning `<.form>`/`<form>` (no `form` attr), it
  submits the enclosing form. Pass `form="<form-id>"` to place the bar
  OUTSIDE its owning form and still submit it via the HTML form-association
  attribute (the LLM category pins its bar at the pane bottom while its flat
  fields stay inside the scrolling `settings-form-llm` form).

  The `sticky bottom-0 z-10` classes are load-bearing only where the bar
  sits inside a scrolling container (the SearchResults bar lives inside the
  `overflow-y-auto` `settings-form-search` form); elsewhere they are
  inert-but-harmless — KEEP them.
  """

  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # save_bar/1 — Minimal pinned bottom-right save bar
  # ───────────────────────────────────────────────────────────────────────────

  attr(:label, :string, required: true)
  attr(:form, :string, default: nil)

  def save_bar(assigns) do
    ~H"""
    <div class="shrink-0 sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 px-8 py-2.5 flex justify-end">
      <button type="submit" form={@form} class="btn btn-primary rounded-md min-w-32 font-bold">
        <.icon name="hero-document-check" class="size-5 mr-1.5" />
        {@label}
      </button>
    </div>
    """
  end
end
