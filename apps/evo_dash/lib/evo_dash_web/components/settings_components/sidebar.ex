defmodule EvoDashWeb.SettingsComponents.Sidebar do
  @moduledoc """
  `settings_sidebar/1` — Category sidebar component.
  """

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.CategoryMetadata,
    only: [
      category_icon: 1,
      category_display_name: 1,
      sort_categories: 1,
      category_match_count: 3
    ]

  # ───────────────────────────────────────────────────────────────────────────
  # settings_sidebar/1 — Category sidebar
  # ───────────────────────────────────────────────────────────────────────────

  attr(:categories, :map, required: true)
  attr(:active_category, :atom, required: true)
  attr(:search_text, :string, default: "")

  def settings_sidebar(assigns) do
    ~H"""
    <div class="w-full md:w-72 bg-base-100 md:flex-shrink-0 md:h-full overflow-y-auto p-4 border-b md:border-b-0 md:border-r border-base-200/70 relative">
      <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-md pb-4 pt-2 -mx-4 px-4">
        <div class="relative group">
          <div class="absolute inset-y-0 left-0 flex items-center pl-3.5 pointer-events-none">
            <.icon
              name="hero-magnifying-glass"
              class="size-4 text-base-content/70 group-focus-within:text-primary transition-colors"
            />
          </div>

          <form id="settings-search" class="contents" phx-submit="noop">
            <input
              type="text"
              name="value"
              value={@search_text}
              placeholder={gettext("Filter settings...")}
              phx-change="search"
              class="input w-full pl-10 pr-9 bg-base-200/50 border-transparent hover:bg-base-200 focus:bg-base-100 focus:border-primary/30 focus:ring-2 focus:ring-primary/20 transition-all duration-200 rounded-md font-medium text-sm h-10"
            />
          </form>

          <%= if @search_text != "" do %>
            <button
              type="button"
              phx-click="search"
              phx-value-value=""
              class="absolute inset-y-0 right-0 flex items-center pr-3 text-base-content/70 hover:text-base-content transition-colors"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          <% end %>
        </div>
      </div>

      <nav class="space-y-2 mt-2 pb-4">
        <%= for {category, schemas} <- sort_categories(@categories) do %>
          <% match_count = category_match_count(category, schemas, @search_text) %> <% total =
            length(schemas) %>
          <button
            type="button"
            phx-click="select_category"
            phx-value-category={to_string(category)}
            class={[
              "w-full text-left px-4 py-3 rounded-lg flex items-center gap-3 transition-all duration-200 text-sm font-semibold group relative overflow-hidden",
              category == @active_category && "bg-primary text-primary-content",
              category != @active_category &&
                "hover:bg-base-200/70 text-base-content/90 hover:text-base-content",
              (@search_text != "" and match_count == 0) && "opacity-30"
            ]}
          >
            <%= if category == @active_category do %>
              <div class="absolute inset-0 bg-white/10 opacity-0 group-hover:opacity-100 transition-opacity">
              </div>
            <% end %>
            <.icon name={category_icon(category)} class="size-5 shrink-0 relative z-10" />
            <span class="flex-1 relative z-10 tracking-wide">{category_display_name(category)}</span>
            <%= if @search_text != "" and match_count != total do %>
              <span class={[
                "text-xs font-bold tabular-nums px-2.5 py-1 rounded-lg relative z-10 transition-colors",
                category == @active_category && "bg-primary-content/20 text-primary-content",
                category != @active_category && "bg-primary/10 text-primary"
              ]}>{match_count}/{total}</span>
            <% else %>
              <span class={[
                "text-xs font-bold tabular-nums px-2.5 py-1 rounded-lg relative z-10 transition-colors",
                category == @active_category && "bg-primary-content/20 text-primary-content",
                category != @active_category &&
                  "bg-base-300/50 text-base-content/70 group-hover:bg-base-300"
              ]}>{total}</span>
            <% end %>
          </button>
        <% end %>
      </nav>
    </div>
    """
  end
end
