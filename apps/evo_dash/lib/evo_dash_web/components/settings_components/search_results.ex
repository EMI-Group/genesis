defmodule EvoDashWeb.SettingsComponents.SearchResults do
  @moduledoc """
  `search_results/1` — Search results across all categories.
  """

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.CategoryMetadata,
    only: [schema_matches?: 2, category_icon: 1, category_display_name: 1, sort_categories: 1]

  import EvoDashWeb.SettingsComponents.SettingCard, only: [setting_card: 1]

  # ───────────────────────────────────────────────────────────────────────────
  # search_results/1 — Search results across all categories
  # ───────────────────────────────────────────────────────────────────────────

  attr(:categories, :map, required: true)
  attr(:search_text, :string, required: true)
  attr(:file_config, :map, required: true)
  attr(:errors, :list, default: [])

  def search_results(assigns) do
    total_matches =
      assigns.categories
      |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
      |> Enum.count(&schema_matches?(&1, assigns.search_text))

    assigns = assign(assigns, :total_matches, total_matches)

    ~H"""
    <div class="flex-1 flex flex-col h-full bg-base-100/50" id="search-results">
      <%!-- Sticky Header --%>
      <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-xl border-b border-base-200/60 px-8 py-6">
        <div class="flex items-center gap-3 mb-1">
          <div class="text-primary/60">
            <.icon name="hero-magnifying-glass" class="size-5" />
          </div>
          <h2 class="text-lg font-bold tracking-tight text-base-content">
            {gettext("Search Results")}
          </h2>
        </div>
        <p class="text-sm font-medium text-base-content/80">
          <%= if @total_matches == 0 do %>
            {gettext("No settings found matching \"%{query}\"", query: @search_text)}
          <% else %>
            {gettext("%{count} setting(s) matching \"%{query}\"",
              count: @total_matches,
              query: @search_text
            )}
          <% end %>
        </p>
      </div>

      <%!-- Scrollable Content --%>
      <div class="flex-1 overflow-y-auto px-8 py-8">
        <%= if @total_matches == 0 do %>
          <div class="flex flex-col items-center justify-center py-20 text-center">
            <div class="text-base-content/30 mb-4">
              <.icon name="hero-magnifying-glass" class="size-10" />
            </div>
            <p class="text-base-content/70 font-medium">{gettext("Try a different search term.")}</p>
          </div>
        <% else %>
          <%= for {category, schemas} <- sort_categories(@categories) do %>
            <% matching = Enum.filter(schemas, &schema_matches?(&1, @search_text)) %>
            <%= if matching != [] do %>
              <div class="mb-10">
                <div class="flex items-center gap-4 mb-6">
                  <div class="p-2 bg-primary/10 text-primary rounded-xl">
                    <.icon name={category_icon(category)} class="size-5" />
                  </div>
                  <h3 class="text-lg font-bold tracking-tight text-base-content">
                    {category_display_name(category)}
                  </h3>
                  <span class="text-xs font-bold tabular-nums px-2.5 py-1 rounded-lg bg-base-300/50 text-base-content/70">{length(
                    matching
                  )}</span>
                  <div class="h-px bg-base-200 flex-1"></div>
                </div>
                <div class="rounded-lg border border-base-200 overflow-hidden">
                  <%= for schema <- matching do %>
                    <.setting_card
                      schema={schema}
                      value={get_in(@file_config, schema.key_path)}
                      error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
                    />
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>

      <%!-- Sticky Footer --%>
      <div class="sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 p-4 flex justify-end">
        <button type="submit" class="btn btn-primary rounded-md min-w-[200px] font-bold">
          <.icon name="hero-document-check" class="size-5 mr-1.5" />
          {gettext("Save Changes")}
        </button>
      </div>
    </div>
    """
  end
end
