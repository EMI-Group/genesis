defmodule EvoDashWeb.SettingsComponents.CardShell do
  @moduledoc """
  `card_shell/1` — Editor card wrapper: header row (title, optional
  description, optional actions slot) + body. Consumed by the settings
  editors: `ModelProfilesEditor`, `CustomAgentsEditor`, and
  `ModelSelectionEditor`.
  """

  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # card_shell/1 — Editor card shell
  # ───────────────────────────────────────────────────────────────────────────

  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  # Extra classes appended to the outer div (e.g. contextual margins like
  # `mb-6`). The base shell classes are fixed for cross-editor consistency.
  attr(:class, :string, default: "")
  slot(:actions)
  slot(:inner_block)

  def card_shell(assigns) do
    ~H"""
    <div class={"rounded-lg border border-base-200 bg-base-100 p-5 #{@class}"}>
      <div class="flex items-center justify-between mb-4">
        <div>
          <h3 class="text-lg font-bold text-base-content mb-0.5">{@title}</h3>
          <%= if @description do %>
            <p class="text-sm text-base-content/80">{@description}</p>
          <% end %>
        </div>
        <div class="shrink-0">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
