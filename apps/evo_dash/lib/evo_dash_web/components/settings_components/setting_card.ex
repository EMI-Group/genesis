defmodule EvoDashWeb.SettingsComponents.SettingCard do
  @moduledoc """
  `setting_card/1` — Single config key card component and its helpers.
  """

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
      "relative flex items-center gap-4 px-4 py-3 border-b border-base-200/60 last:border-b-0 group hover:bg-base-200/30 transition-colors",
      @disabled && "opacity-60 pointer-events-none"
    ]}>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <code class="font-mono text-xs font-medium text-primary">{Enum.join(@schema.key_path, ".")}</code>
          <button
            type="button"
            phx-click="reset_key"
            phx-value-key_path={Enum.join(@schema.key_path, ".")}
            class="opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs text-base-content/70 hover:text-primary transition-opacity"
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
                    <.icon name="hero-cpu-chip" class="size-3" /> {gettext("%{count} model profiles",
                      count: length(profiles)
                    )}
                  </span>

                  <p class="text-[11px] text-base-content/70 mt-1">
                    {gettext("Configure via the editor below")}
                  </p>
                </div>
            <% end %>
          <% end %>
        </div>

        <%= if @error do %>
          <p class="text-xs text-error font-medium mt-1.5 flex items-center gap-1">
            <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" /> {@error.message}
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

  def model_display({provider, opts}) when is_atom(provider) and is_list(opts) do
    id = Keyword.get(opts, :id, "")
    provider_str = to_string(provider)
    overrides = Keyword.drop(opts, [:id])

    cond do
      id != "" and overrides != [] ->
        "#{provider_str}:#{id} (+overrides)"

      id != "" ->
        "#{provider_str}:#{id}"

      true ->
        inspect({provider, opts})
    end
  end

  def model_display(value), do: to_string(value)

  defp default_label(nil), do: gettext("empty")
  defp default_label(value) when is_atom(value), do: to_string(value)
  defp default_label(value), do: to_string(value)
end
