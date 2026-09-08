defmodule EvoDashWeb.SettingsComponents.SettingCard do
  @moduledoc """
  `setting_card/1` — Single config key card component and its helpers.
  """

  use EvoDashWeb, :html

  # ───────────────────────────────────────────────────────────────────────────
  # Appearance accent-color palette ([:appearance, :accent_color])
  # ───────────────────────────────────────────────────────────────────────────
  #
  # The ten GNOME/libadwaita accent NAMES, delegated to the core schema
  # definition (the same list backs the schema's `validation: [in: [...]]`
  # whitelist) — the single source of truth; this module carries NO copy and
  # NO hexes. Every visual comes from the tuned `[data-accent-color="<name>"]`
  # rules in assets/css/app.css: each swatch chip carries
  # `data-accent-color={name}`, so its fill (`bg-primary`), check glyph
  # (`text-primary-content` — the per-accent contrast-safe on-fill color, which
  # is what made the old yellow→text-black special case unnecessary), and
  # focus ring all resolve in CSS and inherit the page's `data-theme` (set on
  # `<html>`) for the dark-mode variants.
  defmacrop accent_palette_list do
    quote do: EvoGit.Config.Schema.Definitions.accent_palette()
  end

  # Public so SettingsLive can whitelist-validate the `select_appearance_accent`
  # payload against the palette (untrusted client input) and tests can pin it.
  def accent_palette, do: accent_palette_list()

  # Whitelist membership check for a single accent name (see accent_palette/0).
  def accent_name?(name), do: is_binary(name) and name in accent_palette()

  # Resolves the ACTIVE accent name: the current value when it is one of the
  # palette names, else the schema default when that is in the palette, else
  # "blue". nil (the config file does not set the key) → schema default.
  def accent_active(nil, schema_default), do: accent_in_palette(schema_default)

  def accent_active(value, _schema_default) when is_binary(value) and value != "",
    do: accent_in_palette(value)

  def accent_active(_value, schema_default), do: accent_in_palette(schema_default)

  defp accent_in_palette(name) do
    if name in accent_palette(), do: name, else: "blue"
  end

  # Localized display labels for the swatches (aria-label / tooltip text).
  # zh_CN: Blue → "蓝色", Teal → "青色", Green → "绿色", Yellow → "黄色",
  # Orange → "橙色", Red → "红色", Pink → "粉色", Purple → "紫色",
  # Brown → "棕色", Slate → "石板灰"
  def accent_label("blue"), do: gettext("Blue")
  def accent_label("teal"), do: gettext("Teal")
  def accent_label("green"), do: gettext("Green")
  def accent_label("yellow"), do: gettext("Yellow")
  def accent_label("orange"), do: gettext("Orange")
  def accent_label("red"), do: gettext("Red")
  def accent_label("pink"), do: gettext("Pink")
  def accent_label("purple"), do: gettext("Purple")
  def accent_label("brown"), do: gettext("Brown")
  def accent_label("slate"), do: gettext("Slate")
  def accent_label(_), do: gettext("Accent")

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
      "relative flex items-center gap-4 px-4 py-3 border-b border-base-200/60 last:border-b-0 group hover:bg-base-200/30 transition-colors",
      @disabled && "opacity-60 pointer-events-none"
    ]}>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <code class="font-mono text-xs font-medium text-primary-standalone">{Enum.join(
            @schema.key_path,
            "."
          )}</code>
          <button
            type="button"
            phx-click="reset_key"
            phx-value-key_path={Enum.join(@schema.key_path, ".")}
            class="opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs text-base-content/70 hover:text-primary-standalone transition-opacity"
            title={gettext("Reset to default")}
          >
            <.icon name="hero-arrow-path" class="size-3.5" />
          </button>
        </div>
        <p
          class="text-xs text-base-content/70 truncate mt-0.5"
          title={Gettext.gettext(EvoDashWeb.Gettext, @schema.description)}
        >
          {Gettext.gettext(EvoDashWeb.Gettext, @schema.description)}
        </p>
        <p class="text-[11px] text-base-content/70 mt-0.5">
          <span class="uppercase tracking-wider">{gettext("Default")}</span>
          <span class="font-mono">{default_label(@schema.default)}</span>
        </p>
      </div>

      <div class="shrink-0 w-full sm:w-auto">
        <div class="form-control w-full">
          <%= if @schema.key_path == [:appearance, :accent_color] do %>
            <%!-- Accent-color swatch picker (appearance.accent_color). A row of
                 round swatch chips mirroring the GNOME/libadwaita palette; the
                 ACTIVE color (config value, nil → schema default "blue", or
                 the pending draft threaded from SettingsLive) gets a ring +
                 check glyph. The chip itself carries data-accent-color={name},
                 so EVERYTHING visual resolves in CSS from the tuned
                 [data-accent-color] rules in app.css: fill = bg-primary (that
                 accent's own --color-primary), check glyph =
                 text-primary-content (per-accent contrast-safe on-fill color —
                 this is what replaced the old yellow→text-black special case),
                 and the active/focus rings — including the dark-theme variants
                 for free (the chip inherits data-theme from <html>). A hidden
                 input named `appearance.accent_color` carries the active
                 selection so the generic save_category flow persists it. The
                 visible swatch buttons are type="button" with
                 phx-click="select_appearance_accent" — a server-driven draft
                 update that never submits the enclosing form and never wipes
                 unsaved edits in sibling cards. --%>
            <% active = accent_active(@value, @schema.default) %>
            <input type="hidden" name={Enum.join(@schema.key_path, ".")} value={active} />
            <div class="flex flex-wrap items-center gap-2">
              <%= for name <- accent_palette() do %>
                <button
                  type="button"
                  phx-click="select_appearance_accent"
                  phx-value-accent={name}
                  data-accent-color={name}
                  aria-label={accent_label(name)}
                  title={accent_label(name)}
                  class={[
                    "size-7 rounded-full border-2 border-white/40 shadow-sm flex items-center justify-center bg-primary transition-transform hover:scale-110 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-primary-standalone",
                    active == name && "ring-2 ring-offset-2 ring-base-content/70 scale-110"
                  ]}
                >
                  <%= if active == name do %>
                    <%!-- text-primary-content = THIS accent's contrast-safe
                         on-fill color (CSS-resolved; yellow is dark-on-yellow,
                         blue white-on-blue, …). --%>
                    <.icon name="hero-check" class="size-3.5 text-primary-content" />
                  <% end %>
                </button>
              <% end %>
            </div>
          <% else %>
            <%= if @schema.key_path == [:llm, :reasoning_effort] do %>
              <%!-- Special dropdown for llm.reasoning_effort (string type with constrained values) --%>
              <div class="relative w-full sm:w-52">
                <select
                  name={Enum.join(@schema.key_path, ".")}
                  class="select select-bordered select-sm rounded-md w-full font-mono text-base appearance-none pr-8"
                >
                  <option value="" selected={is_nil(@value)}>
                    <%!-- zh_CN: provider → "服务商" --%>{gettext("(provider default)")}
                  </option>
                  <%= for opt <- ~w(none minimal low medium high xhigh default) do %>
                    <option value={opt} selected={to_string(@value) == opt}>
                      {opt}
                    </option>
                  <% end %>
                </select>
                <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2 text-base-content/70">
                  <.icon name="hero-chevron-down" class="size-4" />
                </div>
              </div>
            <% else %>
              <%= case @schema.type do %>
                <% :pos_integer -> %>
                  <input
                    type="number"
                    name={Enum.join(@schema.key_path, ".")}
                    value={input_value(@value)}
                    min={@schema.validation[:min] || 1}
                    max={@schema.validation[:max]}
                    placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                    class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-base"
                  />
                <% :non_neg_integer -> %>
                  <input
                    type="number"
                    name={Enum.join(@schema.key_path, ".")}
                    value={input_value(@value)}
                    min={@schema.validation[:min] || 0}
                    max={@schema.validation[:max]}
                    placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                    class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-base"
                  />
                <% :integer -> %>
                  <input
                    type="number"
                    name={Enum.join(@schema.key_path, ".")}
                    value={input_value(@value)}
                    min={@schema.validation[:min]}
                    max={@schema.validation[:max]}
                    placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                    class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-base"
                  />
                <% :float -> %>
                  <input
                    type="number"
                    step="0.01"
                    name={Enum.join(@schema.key_path, ".")}
                    value={input_value(@value)}
                    min={@schema.validation[:min]}
                    max={@schema.validation[:max]}
                    placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                    class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-base"
                  />
                <% :string -> %>
                  <input
                    type="text"
                    name={Enum.join(@schema.key_path, ".")}
                    value={@value || ""}
                    placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                    class="input input-bordered input-sm rounded-md w-full font-mono text-base"
                  />
                <% :atom -> %>
                  <div class="relative w-full sm:w-52">
                    <select
                      name={Enum.join(@schema.key_path, ".")}
                      class="select select-bordered select-sm rounded-md w-full font-mono text-base appearance-none pr-8"
                    >
                      <%= for opt <- @schema.validation[:in] || [] do %>
                        <option value={to_string(opt)} selected={to_string(@value) == to_string(opt)}>
                          {to_string(opt)}
                        </option>
                      <% end %>
                    </select>
                    <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2 text-base-content/70">
                      <.icon name="hero-chevron-down" class="size-4" />
                    </div>
                  </div>
                <% :boolean -> %>
                  <%!-- Hidden field ensures "false" is submitted when checkbox is unchecked --%>
                  <input type="hidden" name={Enum.join(@schema.key_path, ".")} value="false" />
                  <input
                    type="checkbox"
                    name={Enum.join(@schema.key_path, ".")}
                    value="true"
                    class="toggle toggle-primary toggle-sm"
                    checked={@value in [true, "true"]}
                  />
                <% :model_spec -> %>
                  <%!-- Editable model field: can be typed manually or set via Quick Setup above --%>
                  <div class="w-full">
                    <input
                      type="text"
                      name={Enum.join(@schema.key_path, ".")}
                      value={model_display(@value)}
                      placeholder={gettext("e.g. anthropic:claude-opus-4-7 or openai:gpt-5.5")}
                      class="input input-bordered input-sm rounded-md w-full font-mono text-base"
                    />
                    <p class="text-[11px] text-base-content/70 mt-1">
                      {gettext("Type a model string or use Quick Setup above")}
                    </p>
                  </div>
                <% :model_profiles -> %>
                  <% profiles = @value || [] %>
                  <div class="w-full text-right">
                    <span class="badge badge-primary badge-sm gap-1 font-mono">
                      <.icon name="hero-cpu-chip" class="size-3" />
                      {gettext("%{count} model profiles", count: length(profiles))}
                    </span>
                    <p class="text-[11px] text-base-content/70 mt-1">
                      {gettext("Configure via the editor below")}
                    </p>
                  </div>
                <% :list_of_strings -> %>
                  <% key = Enum.join(@schema.key_path, ".") %>
                  <% entries = list_entries(@value) %>
                  <div class="w-full sm:w-96">
                    <%= if entries == nil do %>
                      <p class="text-[11px] text-base-content/70 flex items-start gap-1.5">
                        <.icon name="hero-information-circle" class="size-3.5 shrink-0 mt-0.5" />
                        {gettext("Not set — platform default writable paths are used.")}
                      </p>
                    <% else %>
                      <%!-- Hidden sentinel keeps a SET list (even an empty one)
                         distinct from an UNSET (nil) list on submit: a set list
                         always submits at least [""], which parses to [] and is
                         stored as [] (meaningful: replaces the defaults with
                         nothing), while an absent param means "unset" (nil). --%>
                      <input type="hidden" name={key} value="" />
                      <div class="space-y-1.5">
                        <%= for {entry, idx} <- Enum.with_index(entries) do %>
                          <div class="flex items-center gap-2">
                            <input
                              type="text"
                              name={key}
                              value={entry}
                              placeholder={gettext("e.g. ~/.cache/genesis")}
                              class="input input-bordered input-sm rounded-md w-full font-mono text-base"
                            />
                            <button
                              type="button"
                              phx-click="remove_list_entry"
                              phx-value-key_path={key}
                              phx-value-index={idx}
                              class="btn btn-ghost btn-xs btn-square text-base-content/60 hover:text-error shrink-0"
                              title={gettext("Remove entry")}
                            >
                              <.icon name="hero-x-mark" class="size-4" />
                            </button>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <button
                      type="button"
                      phx-click="add_list_entry"
                      phx-value-key_path={key}
                      class="btn btn-ghost btn-xs gap-1 mt-1.5 text-primary-standalone hover:bg-primary/10"
                    >
                      <.icon name="hero-plus" class="size-3.5" />
                      {gettext("Add path")}
                    </button>
                  </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
        <%= if @error do %>
          <p class="text-xs text-error font-medium mt-1.5 flex items-center gap-1">
            <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />
            {@error.message}
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private Helpers
  # ───────────────────────────────────────────────────────────────────────────

  # LLM key paths that are managed by the Model Profiles editor (per-profile
  # generation params) or the read-only models badge — they should NOT render as
  # flat cards. Only [:llm, :compression_threshold_tokens] remains as a flat card.
  @flat_llm_excluded_key_paths [
    [:llm, :model],
    [:llm, :temperature],
    [:llm, :max_tokens],
    [:llm, :reasoning_effort],
    [:llm, :top_p],
    [:llm, :top_k],
    [:llm, :frequency_penalty],
    [:llm, :presence_penalty],
    [:llm, :models]
  ]

  # Made public because category_section/1 in the parent module calls it.
  def flat_llm_schemas(schemas) do
    Enum.reject(schemas, &(&1.key_path in @flat_llm_excluded_key_paths))
  end

  defp input_value(nil), do: ""
  defp input_value(value), do: to_string(value)

  def model_display(nil), do: ""
  def model_display(value) when is_binary(value), do: value

  def model_display(value) when is_map(value) do
    provider = to_string(value[:provider] || value["provider"] || "")
    id = to_string(value[:id] || value["id"] || "")
    base_url = value[:base_url] || value["base_url"]

    cond do
      id != "" and base_url not in [nil, ""] ->
        if provider != "", do: "#{provider}:#{id} @ #{base_url}", else: "#{id} @ #{base_url}"

      id != "" and provider != "" ->
        "#{provider}:#{id}"

      id != "" ->
        id

      true ->
        inspect(value)
    end
  end

  def model_display(value), do: to_string(value)

  # Normalizes a :list_of_strings value for the list editor. nil (unset) → nil
  # (renders the "not set" hint); a list → its string elements (non-binary
  # elements degrade to inspect/1 so an invalid config can never crash the
  # render); any other non-nil value (e.g. a single string from an invalid
  # config.toml) → a one-element list so the user can see and correct it.
  defp list_entries(nil), do: nil
  defp list_entries(value) when is_list(value), do: Enum.map(value, &entry_str/1)
  defp list_entries(value), do: [entry_str(value)]

  defp entry_str(entry) when is_binary(entry), do: entry
  defp entry_str(entry), do: inspect(entry)

  defp default_label(nil), do: gettext("empty")
  defp default_label([]), do: gettext("(none)")
  defp default_label(value) when is_list(value), do: Enum.join(value, ", ")
  defp default_label(value) when is_atom(value), do: to_string(value)
  defp default_label(value), do: to_string(value)
end
