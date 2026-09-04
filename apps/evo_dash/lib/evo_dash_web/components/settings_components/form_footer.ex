defmodule EvoDashWeb.SettingsComponents.FormFooter do
  @moduledoc """
  `form_footer/1` — Border-t right-aligned footer for the settings inline
  edit forms (Cancel ghost button + primary submit button with check icon).

  Must be rendered INSIDE the edit `<form>` — the right button is
  `type="submit"` and submits the enclosing form; the Cancel button is a
  `type="button"` firing the given `phx-click` event.
  """

  # zh_CN: Cancel → "取消"

  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # form_footer/1 — Edit-form action footer
  # ───────────────────────────────────────────────────────────────────────────

  attr(:cancel_event, :string, required: true)
  attr(:save_label, :string, required: true)

  def form_footer(assigns) do
    ~H"""
    <div class="flex items-center justify-end gap-2 pt-2 border-t border-base-200">
      <button type="button" phx-click={@cancel_event} class="btn btn-ghost btn-sm">
        <%!-- zh_CN: Cancel → "取消" --%>{gettext("Cancel")}
      </button>
      <button type="submit" class="btn btn-primary btn-sm gap-1">
        <.icon name="hero-check" class="size-4" />
        {@save_label}
      </button>
    </div>
    """
  end
end
