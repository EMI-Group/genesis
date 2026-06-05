defmodule EvoDashWeb.SettingsComponents do
  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # setting_card/1 — Single config key card
  # ───────────────────────────────────────────────────────────────────────────

  attr(:schema, :map, required: true)
  attr(:value, :any, required: true)
  attr(:error, :map, default: nil)
  attr(:disabled, :boolean, default: false)

  def setting_card(assigns) do
    ~H"""
    <div class={[
      "bg-base-100 rounded-xl border border-base-200 shadow-sm hover:shadow-md transition-shadow duration-200 p-4",
      @disabled && "opacity-50 pointer-events-none"
    ]}>
      <div class="flex items-center justify-between gap-2 mb-1">
        <span class="badge badge-sm badge-ghost font-mono text-xs">
          {Enum.join(@schema.key_path, ".")}
        </span>
        <button
          phx-click="reset_key"
          phx-value-key_path={Enum.join(@schema.key_path, ".")}
          class="btn btn-ghost btn-xs text-base-content/50 hover:text-primary transition-colors"
        >
          {gettext("reset")}
        </button>
      </div>

      <p class="text-xs text-base-content/60 mt-1 mb-4">{@schema.description}</p>

      <div class="form-control">
        <%= case @schema.type do %>
          <% :pos_integer -> %>
            <input
              type="number"
              name={Enum.join(@schema.key_path, ".")}
              value={input_value(@value)}
              min={@schema.validation[:min] || 1}
              max={@schema.validation[:max]}
              class="input input-bordered input-sm w-full font-mono focus:ring-2 focus:ring-primary/20 transition-shadow"
            />
          <% :non_neg_integer -> %>
            <input
              type="number"
              name={Enum.join(@schema.key_path, ".")}
              value={input_value(@value)}
              min={@schema.validation[:min] || 0}
              max={@schema.validation[:max]}
              class="input input-bordered input-sm w-full font-mono focus:ring-2 focus:ring-primary/20 transition-shadow"
            />
          <% :integer -> %>
            <input
              type="number"
              name={Enum.join(@schema.key_path, ".")}
              value={input_value(@value)}
              min={@schema.validation[:min]}
              max={@schema.validation[:max]}
              class="input input-bordered input-sm w-full font-mono focus:ring-2 focus:ring-primary/20 transition-shadow"
            />
          <% :float -> %>
            <input
              type="number"
              step="0.01"
              name={Enum.join(@schema.key_path, ".")}
              value={input_value(@value)}
              min={@schema.validation[:min]}
              max={@schema.validation[:max]}
              class="input input-bordered input-sm w-full font-mono focus:ring-2 focus:ring-primary/20 transition-shadow"
            />
          <% :string -> %>
            <input
              type="text"
              name={Enum.join(@schema.key_path, ".")}
              value={@value || ""}
              class="input input-bordered input-sm w-full font-mono focus:ring-2 focus:ring-primary/20 transition-shadow"
            />
          <% :atom -> %>
            <select
              name={Enum.join(@schema.key_path, ".")}
              class="select select-bordered select-sm w-full font-mono focus:ring-2 focus:ring-primary/20 transition-shadow"
            >
              <%= for opt <- @schema.validation[:in] || [] do %>
                <option value={to_string(opt)} selected={to_string(@value) == to_string(opt)}>
                  {to_string(opt)}
                </option>
              <% end %>
            </select>
        <% end %>
      </div>

      <p class="text-xs text-base-content/50 mt-1.5">
        {gettext("Default:")} {default_label(@schema.default)}
      </p>

      <%= if @error do %>
        <p class="text-xs text-error mt-2 font-medium">
          <.icon name="hero-exclamation-circle" class="size-3 inline" /> {@error.message}
        </p>
      <% end %>
    </div>
    """
  end

  # ───────────────────────────────────────────────────────────────────────────
  # category_section/1 — Right content area for a category
  # ───────────────────────────────────────────────────────────────────────────

  attr(:category, :atom, required: true)
  attr(:schemas, :list, required: true)
  attr(:file_config, :map, required: true)
  attr(:errors, :list, default: [])
  attr(:disabled, :boolean, default: false)
  attr(:sandbox_backend, :atom, default: nil)
  attr(:sandbox_mode, :atom, default: nil)

  def category_section(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6" id={"category-#{@category}"}>
      <div class="flex items-center gap-2.5 mb-1">
        <.icon name={category_icon(@category)} class="size-5 text-primary" />
        <h2 class="text-lg font-bold">{category_display_name(@category)}</h2>
      </div>
      <p class="text-xs text-base-content/50 mb-6">{category_description(@category)}</p>

      <%= if @category == :sandbox do %>
        <%!-- Sandbox backend banner --%>
        <div class="mb-4">
          <%= case @sandbox_backend do %>
            <% :systemd_run -> %>
              <div class="flex items-center gap-2 p-3 rounded-lg bg-success/10 border border-success/20">
                <span class="badge badge-success badge-sm">systemd-run</span>
                <span class="text-sm text-success/80">
                  {gettext("Full sandboxing: filesystem isolation, resource limits, syscall filtering")}
                </span>
              </div>
            <% :sandbox_exec -> %>
              <div class="flex items-center gap-2 p-3 rounded-lg bg-warning/10 border border-warning/20">
                <span class="badge badge-warning badge-sm">sandbox-exec</span>
                <span class="text-sm text-warning/80">
                  {gettext("Filesystem isolation only. Resource limits not available on macOS.")}
                </span>
              </div>
            <% _ -> %>
              <div class="flex items-center gap-2 p-3 rounded-lg bg-error/10 border border-error/20">
                <span class="badge badge-error badge-sm">{gettext("Not Available")}</span>
                <span class="text-sm text-error/80">
                  {gettext("No sandbox support on this platform. Commands run directly.")}
                </span>
              </div>
          <% end %>
        </div>

        <%!-- Sandbox mode (sub_category: nil) at top --%>
        <%= for schema <- Enum.filter(@schemas, &(&1.sub_category == nil and &1.key_path == [:sandbox, :mode])) do %>
          <div class="mb-6">
            <.setting_card
              schema={schema}
              value={get_in(@file_config, schema.key_path)}
              error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
              disabled={false}
            />
          </div>
        <% end %>

        <%!-- Resources sub-header --%>
        <% resources_schemas = Enum.filter(@schemas, &(&1.sub_category == :resources)) %>
        <%= if resources_schemas != [] do %>
          <h3 class="text-sm font-semibold text-base-content/70 mb-3 mt-6">{gettext("Resources")}</h3>

          <%= if @sandbox_backend != :systemd_run do %>
            <div class="bg-info/10 border border-info/20 rounded-lg p-3 mb-4">
              <p class="text-sm text-info/80">
                <.icon name="hero-information-circle" class="size-4 inline-block mr-1" />
                {gettext("Resource limits are only available on Linux with systemd-run.")}
              </p>
            </div>
          <% end %>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-5 mb-4">
            <%= for schema <- resources_schemas do %>
              <.setting_card
                schema={schema}
                value={get_in(@file_config, schema.key_path)}
                error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
                disabled={@sandbox_mode == :disabled}
              />
            <% end %>
          </div>
        <% end %>

        <%!-- Process Limits sub-header --%>
        <% process_schemas = Enum.filter(@schemas, &(&1.sub_category == :process)) %>
        <%= if process_schemas != [] do %>
          <h3 class="text-sm font-semibold text-base-content/70 mb-3 mt-6">{gettext("Process Limits")}</h3>

          <%= if @sandbox_backend != :systemd_run do %>
            <div class="bg-info/10 border border-info/20 rounded-lg p-3 mb-4">
              <p class="text-sm text-info/80">
                <.icon name="hero-information-circle" class="size-4 inline-block mr-1" />
                {gettext("Resource limits are only available on Linux with systemd-run.")}
              </p>
            </div>
          <% end %>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-5 mb-4">
            <%= for schema <- process_schemas do %>
              <.setting_card
                schema={schema}
                value={get_in(@file_config, schema.key_path)}
                error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
                disabled={@sandbox_mode == :disabled}
              />
            <% end %>
          </div>
        <% end %>
      <% else %>
        <%!-- Other categories: just list all setting cards --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
          <%= for schema <- @schemas do %>
            <.setting_card
              schema={schema}
              value={get_in(@file_config, schema.key_path)}
              error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
              disabled={@disabled}
            />
          <% end %>
        </div>
      <% end %>

      <div class="mt-6 flex justify-end">
        <button type="submit" class="btn btn-primary btn-wide gap-2 min-w-[200px]">
          <.icon name="hero-document-arrow-down" class="size-5" />
          {gettext("Save %{category}", category: category_display_name(@category))}
        </button>
      </div>
    </div>
    """
  end

  # ───────────────────────────────────────────────────────────────────────────
  # settings_sidebar/1 — Category sidebar
  # ───────────────────────────────────────────────────────────────────────────

  attr(:categories, :map, required: true)
  attr(:active_category, :atom, required: true)
  attr(:search_text, :string, default: "")

  def settings_sidebar(assigns) do
    ~H"""
    <div class="w-60 bg-base-200 border-r border-base-300 flex-shrink-0 h-full overflow-y-auto p-3">
      <div class="mb-2">
        <div class="relative">
          <div class="absolute inset-y-0 left-0 flex items-center pl-2.5 pointer-events-none">
            <.icon name="hero-magnifying-glass" class="size-3.5 text-base-content/40" />
          </div>
          <input
            type="text"
            name="search"
            value={@search_text}
            placeholder={gettext("Filter settings...")}
            phx-change="search"
            class="input input-bordered input-sm w-full pl-8 pr-7 transition-all duration-150"
          />
          <%= if @search_text != "" do %>
            <button
              type="button"
              phx-click="search"
              phx-value-value=""
              class="absolute inset-y-0 right-0 flex items-center pr-2 text-base-content/40 hover:text-base-content transition-colors"
            >
              <span class="text-sm leading-none">×</span>
            </button>
          <% end %>
        </div>
      </div>

      <hr class="border-base-300 mb-2" />

      <nav class="space-y-1">
        <%= for {category, schemas} <- sort_categories(@categories) do %>
          <% match_count = category_match_count(category, schemas, @search_text) %>
          <% total = length(schemas) %>
          <button
            phx-click="select_category"
            phx-value-category={to_string(category)}
            class={[
              "w-full text-left px-3 py-2 rounded-lg flex items-center gap-2.5 transition-all duration-150 text-sm",
              category == @active_category && "bg-primary/10 text-primary font-semibold border-l-2 border-primary",
              category != @active_category && "hover:bg-base-300 text-base-content/70 border-l-2 border-transparent",
              @search_text != "" and match_count == 0 && "opacity-30"
            ]}
          >
            <.icon name={category_icon(category)} class="size-4 shrink-0" />
            <span class="flex-1">{category_display_name(category)}</span>
            <%= if @search_text != "" and match_count != total do %>
              <span class="text-xs text-primary font-medium tabular-nums badge badge-xs">{match_count}/{total}</span>
            <% else %>
              <span class="text-xs text-base-content/40 tabular-nums">{total}</span>
            <% end %>
          </button>
        <% end %>
      </nav>
    </div>
    """
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private Helpers
  # ───────────────────────────────────────────────────────────────────────────

  defp input_value(nil), do: ""
  defp input_value(value), do: to_string(value)

  defp default_label(nil), do: gettext("none")
  defp default_label(value) when is_atom(value), do: to_string(value)
  defp default_label(value), do: to_string(value)

  def category_display_name(:scheduler), do: gettext("Scheduler")
  def category_display_name(:llm), do: gettext("LLM")
  def category_display_name(:user), do: gettext("User")
  def category_display_name(:sandbox), do: gettext("Sandbox")
  def category_display_name(:truncation), do: gettext("Truncation")
  def category_display_name(:task_history), do: gettext("Task History")

  def category_icon(:scheduler), do: "hero-cog-6-tooth"
  def category_icon(:llm), do: "hero-sparkles"
  def category_icon(:user), do: "hero-user"
  def category_icon(:sandbox), do: "hero-shield-check"
  def category_icon(:truncation), do: "hero-scissors"
  def category_icon(:task_history), do: "hero-clock"

  defp category_description(:scheduler),
    do: gettext("Control agent concurrency, retry behavior, and depth limits.")

  defp category_description(:llm),
    do: gettext("Configure the language model provider and token compression.")

  defp category_description(:user),
    do: gettext("Set your user identity for Git commits and collaboration.")

  defp category_description(:sandbox),
    do: gettext("Manage sandbox isolation, resource limits, and process constraints.")

  defp category_description(:truncation),
    do: gettext("Configure output truncation limits for tool and context windows.")

  defp category_description(:task_history),
    do: gettext("Manage how many past tasks are retained and for how long.")

  defp sort_categories(categories) do
    order = [:scheduler, :llm, :user, :sandbox, :truncation, :task_history]
    Enum.sort_by(categories, fn {cat, _} -> Enum.find_index(order, &(&1 == cat)) || 99 end)
  end

  defp category_match_count(_category, schemas, "") do
    length(schemas)
  end

  defp category_match_count(_category, schemas, search_text) do
    lower = String.downcase(search_text)

    Enum.count(schemas, fn s ->
      String.contains?(String.downcase(Enum.join(s.key_path, ".")), lower) or
        String.contains?(String.downcase(s.description), lower)
    end)
  end
end
