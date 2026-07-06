defmodule EvoDashWeb.SettingsComponents do
  @moduledoc """
  Components for the settings GUI editor: config-key cards, category
  sections, and schema-driven inputs.
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
                  {gettext("(provider default)")}
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
  # model_profiles_editor/1 — List editor for [[llm.models]] profiles
  # ───────────────────────────────────────────────────────────────────────────

  attr(:profiles, :list, default: [])
  attr(:editing_profile_id, :any, default: nil)

  def model_profiles_editor(assigns) do
    ~H"""
    <div class="mb-6 rounded-lg border border-base-200 bg-base-100 p-5">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h3 class="text-lg font-bold text-base-content mb-0.5">{gettext("Model Profiles")}</h3>
          <p class="text-sm text-base-content/80">
            {gettext(
              "Configure one or more LLM models. Each profile can have its own concurrency and generation parameters."
            )}
          </p>
        </div>
        <button
          type="button"
          phx-click="add_model_profile"
          class="btn btn-primary btn-sm gap-2 shrink-0"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add Model")}
        </button>
      </div>

      <%= if @profiles == [] do %>
        <div class="flex flex-col items-center justify-center py-10 text-center border-2 border-dashed border-base-300 rounded-lg">
          <div class="text-base-content/30 mb-3">
            <.icon name="hero-cpu-chip" class="size-8" />
          </div>
          <p class="text-sm text-base-content/70 font-medium mb-1">
            {gettext("No model profiles configured")}
          </p>
          <p class="text-xs text-base-content/60">
            {gettext("Add a profile to get started, or use Quick Setup above.")}
          </p>
        </div>
      <% else %>
        <div class="space-y-3">
          <%= for profile <- @profiles do %>
            <% id = profile_id_string(profile) %>
            <%= if @editing_profile_id == id do %>
              <.model_profile_edit_form profile={profile} />
            <% else %>
              <.model_profile_row profile={profile} />
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Read-only summary row for a single profile ──

  attr(:profile, :map, required: true)

  defp model_profile_row(assigns) do
    ~H"""
    <div class="flex items-start gap-4 p-4 rounded-lg border border-base-200 bg-base-100 hover:bg-base-200/30 transition-colors">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1.5">
          <.icon name="hero-cpu-chip" class="size-4 text-primary shrink-0" />
          <code class="font-mono text-sm font-bold text-base-content">{profile_id_string(@profile)}</code>
          <%= if profile_concurrency(@profile) do %>
            <span class="badge badge-ghost badge-sm gap-1 font-mono text-xs">
              <.icon name="hero-arrows-right-left" class="size-3" />
              {gettext("%{n} slots", n: profile_concurrency(@profile))}
            </span>
          <% end %>
        </div>
        <div class="flex items-center gap-2 mb-1.5">
          <code class="font-mono text-xs text-primary/80 break-all">{model_display(
            @profile[:model] || @profile["model"]
          )}</code>
        </div>
        <%= if summary = profile_params_summary(@profile) do %>
          <p class="text-xs text-base-content/60 font-mono mt-1">{summary}</p>
        <% end %>
      </div>
      <div class="flex items-center gap-1 shrink-0">
        <button
          type="button"
          phx-click="edit_model_profile"
          phx-value-profile_id={profile_id_string(@profile)}
          class="btn btn-ghost btn-sm gap-1"
        >
          <.icon name="hero-pencil-square" class="size-4" />
          {gettext("Edit")}
        </button>
        <button
          type="button"
          phx-click="delete_model_profile"
          phx-value-profile_id={profile_id_string(@profile)}
          class="btn btn-ghost btn-sm text-error gap-1"
          data-confirm={gettext("Delete this model profile?")}
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete")}
        </button>
      </div>
    </div>
    """
  end

  # ── Editable form for a single profile ──

  attr(:profile, :map, required: true)

  defp model_profile_edit_form(assigns) do
    ~H"""
    <form
      phx-submit="save_model_profile"
      class="p-4 rounded-lg border-2 border-primary/40 bg-base-100 space-y-4"
    >
      <input type="hidden" name="profile_id" value={profile_id_string(@profile)} />

      <div class="flex items-center gap-2 mb-1">
        <.icon name="hero-pencil-square" class="size-5 text-primary" />
        <h4 class="font-bold text-sm text-base-content">{gettext("Edit Profile")}</h4>
      </div>

      <%!-- id + model (required fields) ── side by side ── --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Profile ID")}
            <span class="text-error">*</span></span>
          </label>
          <input
            type="text"
            name="profile_id_new"
            value={profile_id_string(@profile)}
            placeholder="default"
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            required
          />
          <p class="text-[11px] text-base-content/60 mt-1">
            {gettext("A unique identifier for this profile")}
          </p>
        </div>
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Model")}
            <span class="text-error">*</span></span>
          </label>
          <input
            type="text"
            name="model"
            value={model_display(@profile[:model] || @profile["model"])}
            placeholder={gettext("e.g. anthropic:claude-sonnet-4-6")}
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            required
          />
          <p class="text-[11px] text-base-content/60 mt-1">
            {gettext("Format: provider:model-name")}
          </p>
        </div>
      </div>

      <%!-- concurrency ── --%>
      <div class="form-control">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs">{gettext("Concurrency")}</span>
        </label>
        <input
          type="number"
          name="concurrency"
          value={profile_concurrency(@profile) || 3}
          min="1"
          class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-sm"
        />
        <p class="text-[11px] text-base-content/60 mt-1">
          {gettext("Number of parallel LLM request slots")}
        </p>
      </div>

      <%!-- Generation params ── collapsible-ish section ── --%>
      <div class="pt-2">
        <div class="flex items-center gap-3 mb-3">
          <div class="h-px bg-base-200 flex-1"></div>
          <span class="text-xs font-bold uppercase tracking-widest text-base-content/60">{gettext(
            "Generation Parameters"
          )}</span>
          <span class="text-[11px] text-base-content/50">{gettext("optional")}</span>
          <div class="h-px bg-base-200 flex-1"></div>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <%!-- Temperature ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Temperature")}</span>
            </label>
            <input
              type="number"
              step="0.01"
              name="temperature"
              value={profile_param(@profile, :temperature)}
              min="0"
              max="2"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Reasoning effort ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Reasoning Effort")}</span>
            </label>
            <div class="relative">
              <select
                name="reasoning_effort"
                class="select select-bordered select-sm rounded-md w-full font-mono text-sm appearance-none pr-8"
              >
                <option value="" selected={is_nil(profile_param(@profile, :reasoning_effort))}>
                  {gettext("(provider default)")}
                </option>
                <%= for opt <- ~w(none minimal low medium high xhigh default) do %>
                  <option
                    value={opt}
                    selected={to_string(profile_param(@profile, :reasoning_effort)) == opt}
                  >
                    {opt}
                  </option>
                <% end %>
              </select>
              <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2 text-base-content/70">
                <.icon name="hero-chevron-down" class="size-4" />
              </div>
            </div>
          </div>
          <%!-- Max tokens ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Max Tokens")}</span>
            </label>
            <input
              type="number"
              name="max_tokens"
              value={profile_param(@profile, :max_tokens)}
              min="1"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Top P ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Top P")}</span>
            </label>
            <input
              type="number"
              step="0.01"
              name="top_p"
              value={profile_param(@profile, :top_p)}
              min="0"
              max="1"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Top K ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Top K")}</span>
            </label>
            <input
              type="number"
              name="top_k"
              value={profile_param(@profile, :top_k)}
              min="1"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Frequency penalty ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Frequency Penalty")}</span>
            </label>
            <input
              type="number"
              step="0.01"
              name="frequency_penalty"
              value={profile_param(@profile, :frequency_penalty)}
              min="-2"
              max="2"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Presence penalty ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Presence Penalty")}</span>
            </label>
            <input
              type="number"
              step="0.01"
              name="presence_penalty"
              value={profile_param(@profile, :presence_penalty)}
              min="-2"
              max="2"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
        </div>
      </div>

      <%!-- Action buttons ── --%>
      <div class="flex items-center justify-end gap-2 pt-2 border-t border-base-200">
        <button type="button" phx-click="cancel_edit_model_profile" class="btn btn-ghost btn-sm">
          {gettext("Cancel")}
        </button>
        <button type="submit" class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-check" class="size-4" />
          {gettext("Save Profile")}
        </button>
      </div>
    </form>
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
  attr(:llm_providers, :list, default: [])
  attr(:selected_provider_id, :atom, default: nil)
  attr(:selected_provider_models, :list, default: [])
  attr(:selected_variant_id, :atom, default: nil)
  attr(:llm_test_status, :any, default: :idle)
  attr(:model_profiles, :list, default: [])
  attr(:editing_profile_id, :any, default: nil)

  def category_section(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-w-0 h-full bg-base-100/50" id={"category-#{@category}"}>
      <%!-- Sticky Header --%>
      <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-xl border-b border-base-200/60 px-8 py-6">
        <div class="flex items-center gap-3 mb-1">
          <div class="text-primary/60">
            <.icon name={category_icon(@category)} class="size-5" />
          </div>
          <h2 class="text-lg font-bold tracking-tight text-base-content">
            {category_display_name(@category)}
          </h2>
        </div>
        <p class="text-sm font-medium text-base-content/80">{category_description(@category)}</p>
      </div>

      <%= if @category == :llm do %>
        <%!-- LLM category: the Quick Setup panel and Model Profiles editor
             contain their own nested <form> elements (save_api_key,
             save_custom_model, save_model_profile). They must NOT be nested
             inside a save_category form (invalid HTML). Only the flat cards
             (compression_threshold_tokens) are wrapped in the save_category
             form below. --%>
        <div class="flex-1 overflow-y-auto px-8 py-8 relative">
          <div class="">
            <%!-- LLM Provider Quick Setup --%>
            <div class="mb-8 rounded-lg border border-base-200 bg-base-100 p-5">
              <h3 class="text-lg font-bold text-base-content mb-1">{gettext("Quick Setup")}</h3>
              <p class="text-sm text-base-content/80 mb-5">
                {gettext("Select a provider to quickly configure your model and API key.")}
              </p>

              <%!-- Provider buttons --%>
              <div class="flex flex-wrap gap-2 mb-5">
                <%= for provider <- @llm_providers do %>
                  <button
                    type="button"
                    phx-click="select_llm_provider"
                    phx-value-provider_id={provider.id}
                    class={[
                      "btn btn-sm rounded-xl font-semibold transition-all duration-200",
                      @selected_provider_id == provider.id && "btn-primary shadow-md",
                      @selected_provider_id != provider.id &&
                        "btn-ghost bg-base-200/50 hover:bg-base-200"
                    ]}
                  >
                    {provider.display_name}
                  </button>
                <% end %>
              </div>

              <%!-- Variant and model shortcuts when provider is selected --%>
              <%= if @selected_provider_id != nil do %>
                <% provider =
                  Enum.find(EvoGit.Config.LLMCatalog.providers(), &(&1.id == @selected_provider_id)) %>
                <% variants = provider[:variants] %>
                <% has_variants = is_list(variants) and length(variants) > 0 %>
                <% show_models = not has_variants or @selected_variant_id != nil %>
                <% current_model = get_in(@file_config, [:llm, :model]) %>
                <% show_custom_input = provider[:custom_model] == true %>
                <% show_model_buttons = show_models and not show_custom_input %>
                <% openrouter_prefill =
                  if is_binary(current_model) and String.starts_with?(current_model, "openrouter:") do
                    String.replace_prefix(current_model, "openrouter:", "")
                  else
                    ""
                  end %>
                <% openai_prefill_id =
                  if is_map(current_model) and
                       (current_model[:provider] == :openai or current_model["provider"] == "openai") do
                    to_string(current_model[:id] || current_model["id"] || "")
                  else
                    ""
                  end %>
                <% openai_prefill_base_url =
                  if is_map(current_model) and
                       (current_model[:provider] == :openai or current_model["provider"] == "openai") do
                    to_string(current_model[:base_url] || current_model["base_url"] || "")
                  else
                    ""
                  end %>

                <%!-- Variant selection (only if provider has variants) --%>
                <%= if has_variants do %>
                  <div class="mb-5">
                    <p class="text-xs font-bold uppercase tracking-wider text-base-content/70 mb-3">
                      {gettext("Select a variant:")}
                    </p>
                    <div class="flex flex-wrap gap-2">
                      <%= for variant <- variants do %>
                        <button
                          type="button"
                          phx-click="select_llm_variant"
                          phx-value-variant_id={variant.id}
                          class={[
                            "btn btn-xs rounded-xl font-medium transition-all duration-200",
                            @selected_variant_id == variant.id && "btn-secondary shadow-md",
                            @selected_variant_id != variant.id &&
                              "btn-ghost bg-secondary/10 hover:bg-secondary/20 text-secondary"
                          ]}
                        >
                          {variant.display_name}
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%!-- Model shortcuts (show only if no variants needed, or variant selected, and not a custom-model provider) --%>
                <%= if show_model_buttons do %>
                  <div class="mb-5">
                    <p class="text-xs font-bold uppercase tracking-wider text-base-content/70 mb-3">
                      {gettext("Quick-select a model:")}
                    </p>
                    <div class="flex flex-wrap gap-2">
                      <%= for model <- @selected_provider_models do %>
                        <% resolved_atom =
                          EvoGit.Config.LLMCatalog.resolve_provider_atom(
                            @selected_provider_id,
                            @selected_variant_id
                          ) %>
                        <% model_string = "#{resolved_atom}:#{model.id}" %>
                        <button
                          type="button"
                          phx-click="select_llm_model_shortcut"
                          phx-value-model_string={model_string}
                          class={[
                            "btn btn-sm rounded-xl font-medium transition-all duration-200",
                            current_model == model_string && "btn-primary shadow-md",
                            current_model != model_string &&
                              "btn-ghost bg-primary/10 hover:bg-primary/20 text-primary"
                          ]}
                        >
                          {model.display_name}
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%!-- Custom model input (for providers with custom_model: true, e.g. OpenRouter / OpenAI-Compatible) --%>
                <%= if show_custom_input do %>
                  <%= if provider[:requires_base_url] == true do %>
                    <form phx-submit="save_custom_model" class="mb-5 space-y-4">
                      <input type="hidden" name="provider_id" value={@selected_provider_id} />
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text font-bold text-sm mb-2 block">{gettext("Model Name")}</span>
                        </label>
                        <input
                          type="text"
                          name="model_name"
                          value={openai_prefill_id}
                          placeholder={gettext("e.g. gpt-4o or my-custom-model")}
                          class="input input-bordered w-full rounded-xl shadow-sm bg-base-50"
                        />
                      </div>
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text font-bold text-sm mb-2 block">{gettext("Base URL")}</span>
                        </label>
                        <input
                          type="text"
                          name="base_url"
                          value={openai_prefill_base_url}
                          placeholder={gettext("https://api.my-provider.com/v1")}
                          class="input input-bordered w-full rounded-xl shadow-sm bg-base-50 font-mono text-sm"
                        />
                      </div>
                      <div class="bg-warning/5 border border-warning/20 rounded-xl p-3 flex gap-2 items-start">
                        <.icon
                          name="hero-exclamation-triangle"
                          class="size-5 text-warning shrink-0 mt-0.5"
                        />
                        <p class="text-xs font-medium text-warning/80 leading-relaxed">
                          {gettext(
                            "Warning: OpenAI-compatible APIs vary in compatibility. Some features (tool calls, streaming, structured output) may not work depending on the provider."
                          )}
                        </p>
                      </div>
                      <button type="submit" class="btn btn-primary btn-sm rounded-xl">
                        {gettext("Set Model")}
                      </button>
                    </form>
                  <% else %>
                    <form phx-submit="save_custom_model" class="mb-5 space-y-4">
                      <input type="hidden" name="provider_id" value={@selected_provider_id} />
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text font-bold text-sm mb-2 block">{gettext("Model Name")}</span>
                        </label>
                        <input
                          type="text"
                          name="model_name"
                          value={openrouter_prefill}
                          placeholder={gettext("anthropic/claude-3.5-sonnet")}
                          class="input input-bordered w-full rounded-xl shadow-sm bg-base-50 font-mono text-sm"
                        />
                      </div>
                      <p class="text-xs text-base-content/70 leading-relaxed">
                        {gettext("The model will be saved as")} <code class="font-mono bg-base-200 px-1.5 py-0.5 rounded text-[11px]">{gettext("openrouter:<model-name>")}</code>.
                      </p>
                      <button type="submit" class="btn btn-primary btn-sm rounded-xl">
                        {gettext("Set Model")}
                      </button>
                    </form>
                  <% end %>
                <% end %>

                <%!-- API Key input --%>
                <% key_is_set = System.get_env(provider.env_var) %>
                <form phx-submit="save_api_key" class="flex items-end gap-3 pt-6 pb-4">
                  <input type="hidden" name="env_var" value={provider.env_var} />
                  <div class="form-control flex-1">
                    <label class="label">
                      <span class="label-text font-semibold text-sm">{provider.env_var}</span>
                      <%= if key_is_set do %>
                        <span class="label-text-alt text-success text-xs font-bold">✓ {gettext("Set")}</span>
                      <% end %>
                    </label>
                    <input
                      type="password"
                      name="api_key"
                      placeholder={
                        if key_is_set,
                          do: gettext("API key is already set"),
                          else: api_key_prefix_hint(provider.id) || gettext("Enter your API key")
                      }
                      class={[
                        "input input-bordered w-full rounded-xl shadow-sm bg-base-50 mt-2",
                        key_is_set && "input-success"
                      ]}
                    />
                    <%= if key_is_set do %>
                      <p class="text-[11px] text-success/70 mt-1.5 font-medium">
                        ✓ {gettext("Your API key is configured and ready to use.")}
                      </p>
                    <% else %>
                      <p class="text-[11px] text-base-content/70 mt-1.5">
                        <%= if prefix = api_key_prefix_hint(provider.id) do %>
                          {gettext("Enter your API key. It should start with")}
                          <code class="font-mono bg-base-200 px-1 py-0.5 rounded text-[10px]">{prefix}</code>
                        <% else %>
                          {gettext("Enter your API key.")}
                        <% end %>
                      </p>
                    <% end %>
                  </div>
                  <button type="submit" class="btn btn-primary btn-sm rounded-xl mt-2">
                    {gettext("Save Key")}
                  </button>
                </form>
              <% end %>
            </div>

            <%!-- Model Profiles List Editor --%>
            <.model_profiles_editor
              profiles={@model_profiles}
              editing_profile_id={@editing_profile_id}
            />

            <%!-- LLM Connection Test --%>
            <div class="mb-6 bg-base-100 rounded-lg border border-base-200 p-4">
              <div class="flex items-center gap-3 mb-3">
                <div class="text-info/60">
                  <.icon name="hero-signal" class="size-5" />
                </div>
                <div>
                  <h4 class="font-semibold text-sm">{gettext("Connection Test")}</h4>
                  <p class="text-xs text-base-content/70">
                    {gettext("Verify your LLM configuration is working")}
                  </p>
                </div>
              </div>
              <div class="flex items-center gap-3">
                <%= case @llm_test_status do %>
                  <% :idle -> %>
                    <span class="text-sm text-base-content/80">{gettext(
                      "Not tested — click to verify LLM connectivity"
                    )}</span>
                    <button phx-click="test_llm" class="btn btn-primary btn-sm gap-2">
                      <.icon name="hero-signal" class="size-4" />
                      {gettext("Test Connection")}
                    </button>
                  <% :testing -> %>
                    <span class="loading loading-spinner loading-sm text-primary"></span>
                    <span class="text-sm text-base-content/80">{gettext("Testing LLM connection...")}</span>
                  <% {:ok, data} -> %>
                    <.icon name="hero-check-circle" class="size-5 text-success" />
                    <span class="text-sm text-success font-medium">{gettext("Connected")}</span>
                    <span class="text-xs text-base-content/70">({data.model})</span>
                    <span class="text-xs text-base-content/70 bg-base-200/50 px-2 py-0.5 rounded">"{truncate_string(
                      data.response,
                      50
                    )}"</span>
                    <button phx-click="test_llm" class="btn btn-ghost btn-xs gap-1 ml-2">
                      <.icon name="hero-arrow-path" class="size-3" />
                      {gettext("Retest")}
                    </button>
                  <% {:error, reason} -> %>
                    <.icon name="hero-x-circle" class="size-5 text-error" />
                    <span class="text-sm text-error">{reason}</span>
                    <button phx-click="test_llm" class="btn btn-ghost btn-xs gap-1 ml-2">
                      <.icon name="hero-arrow-path" class="size-3" />
                      {gettext("Retry")}
                    </button>
                <% end %>
              </div>
            </div>

            <%!-- Help text for other providers --%>
            <div class="mb-6 bg-base-200/30 rounded-lg p-4 border border-base-200">
              <p class="text-xs text-base-content/70 leading-relaxed">
                {raw(
                  gettext(
                    "<strong>Don't see your provider?</strong> You can enter any model string manually in the Model field below using the format <code class=\"font-mono bg-base-200 px-1.5 py-0.5 rounded\">provider:model-name</code>. Look up your model at <a href=\"https://llmdb.xyz/\" target=\"_blank\" class=\"link link-primary\">llmdb.xyz</a> or see <a href=\"https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html\" target=\"_blank\" class=\"link link-primary\">supported providers</a>."
                  )
                )}
              </p>
            </div>

            <%!-- Flat LLM setting cards (only compression_threshold_tokens
                 remains after filtering). Wrapped in its own save_category
                 form so the Save button submits these flat fields. --%>
            <.form
              for={%{}}
              phx-submit="save_category"
              id={"settings-form-#{@category}"}
            >
              <input type="hidden" name="category" value={@category} />

              <% reordered = flat_llm_schemas(@schemas) %>
              <%= if reordered != [] do %>
                <div class="rounded-lg border border-base-200 overflow-hidden mb-8">
                  <%= for schema <- reordered do %>
                    <.setting_card
                      schema={schema}
                      value={get_in(@file_config, schema.key_path)}
                      error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
                      disabled={@disabled}
                    />
                  <% end %>
                </div>
              <% end %>

              <%!-- Sticky Footer --%>
              <div class="sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 p-4 flex justify-end">
                <button type="submit" class="btn btn-primary rounded-md min-w-[200px] font-bold">
                  <.icon name="hero-document-check" class="size-5 mr-1.5" />
                  {gettext("Save %{category} Settings", category: category_display_name(@category))}
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% else %>
        <%!-- All other categories: wrap the full content + footer in a single
             save_category form (these categories have only plain fields, no
             nested forms). --%>
        <.form
          for={%{}}
          phx-submit="save_category"
          class="flex-1 flex flex-col min-w-0 relative"
          id={"settings-form-#{@category}"}
        >
          <input type="hidden" name="category" value={@category} />

          <%!-- Scrollable Content --%>
          <div class="flex-1 overflow-y-auto px-8 py-8 relative">
            <div class="">
              <%= if @category == :sandbox do %>
                <%!-- Sandbox backend banner --%>
                <div class="mb-8 rounded-lg border border-base-200 overflow-hidden">
                  <%= case @sandbox_backend do %>
                    <% :systemd_run -> %>
                      <div class="flex items-start gap-4 p-5 bg-success/5 border-success/20">
                        <div class="text-success mt-0.5">
                          <.icon name="hero-check-badge" class="size-5" />
                        </div>
                        <div>
                          <h3 class="font-bold text-success mb-1 flex items-center gap-2">
                            systemd-run
                            <span class="badge badge-success badge-sm text-[10px] uppercase tracking-wider font-bold">Active</span>
                          </h3>
                          <p class="text-sm font-medium text-success/80 leading-relaxed">
                            {gettext(
                              "Full sandboxing is enabled: filesystem isolation, resource limits, and syscall filtering are active."
                            )}
                          </p>
                        </div>
                      </div>
                    <% :sandbox_exec -> %>
                      <div class="flex items-start gap-4 p-5 bg-warning/5 border-warning/20">
                        <div class="text-warning mt-0.5">
                          <.icon name="hero-shield-exclamation" class="size-5" />
                        </div>
                        <div>
                          <h3 class="font-bold text-warning mb-1 flex items-center gap-2">
                            sandbox-exec
                            <span class="badge badge-warning badge-sm text-[10px] uppercase tracking-wider font-bold">Active</span>
                          </h3>
                          <p class="text-sm font-medium text-warning/80 leading-relaxed">
                            {gettext(
                              "Filesystem isolation is active. Note: Resource limits are not available on macOS."
                            )}
                          </p>
                        </div>
                      </div>
                    <% _ -> %>
                      <div class="flex items-start gap-4 p-5 bg-error/5 border-error/20">
                        <div class="text-error mt-0.5">
                          <.icon name="hero-x-circle" class="size-5" />
                        </div>
                        <div>
                          <h3 class="font-bold text-error mb-1 flex items-center gap-2">
                            {gettext("Not Available")}
                            <span class="badge badge-error badge-sm text-[10px] uppercase tracking-wider font-bold">Disabled</span>
                          </h3>
                          <p class="text-sm font-medium text-error/80 leading-relaxed">
                            {gettext(
                              "No sandbox support on this platform. Commands will run directly on the host."
                            )}
                          </p>
                        </div>
                      </div>
                  <% end %>
                </div>

                <%!-- Sandbox mode (sub_category: nil) at top --%>
                <%= for schema <- Enum.filter(@schemas, &(&1.sub_category == nil and &1.key_path == [:sandbox, :mode])) do %>
                  <div class="mb-10">
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
                  <div class="flex items-center gap-4 mb-6 mt-10">
                    <div class="h-px bg-base-200 flex-1"></div>
                    <h3 class="text-xs font-black uppercase tracking-widest text-base-content/70">
                      {gettext("Resources")}
                    </h3>
                    <div class="h-px bg-base-200 flex-1"></div>
                  </div>

                  <%= if @sandbox_backend != :systemd_run do %>
                    <div class="bg-info/5 border border-info/20 rounded-lg p-4 mb-6 flex items-start gap-3">
                      <.icon name="hero-information-circle" class="size-5 text-info mt-0.5" />
                      <p class="text-sm font-medium text-info/90 leading-relaxed">
                        {gettext("Resource limits are only available on Linux with systemd-run.")}
                      </p>
                    </div>
                  <% end %>

                  <div class="rounded-lg border border-base-200 overflow-hidden mb-8">
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
                  <div class="flex items-center gap-4 mb-6 mt-10">
                    <div class="h-px bg-base-200 flex-1"></div>
                    <h3 class="text-xs font-black uppercase tracking-widest text-base-content/70">
                      {gettext("Process Limits")}
                    </h3>
                    <div class="h-px bg-base-200 flex-1"></div>
                  </div>

                  <%= if @sandbox_backend != :systemd_run do %>
                    <div class="bg-info/5 border border-info/20 rounded-lg p-4 mb-6 flex items-start gap-3">
                      <.icon name="hero-information-circle" class="size-5 text-info mt-0.5" />
                      <p class="text-sm font-medium text-info/90 leading-relaxed">
                        {gettext("Process limits are only available on Linux with systemd-run.")}
                      </p>
                    </div>
                  <% end %>

                  <div class="rounded-lg border border-base-200 overflow-hidden mb-8">
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
                <div class="rounded-lg border border-base-200 overflow-hidden">
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
            </div>
          </div>

          <%!-- Sticky Footer --%>
          <div class="sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 p-4 flex justify-end">
            <button type="submit" class="btn btn-primary rounded-md min-w-[200px] font-bold">
              <.icon name="hero-document-check" class="size-5 mr-1.5" />
              {gettext("Save %{category} Settings", category: category_display_name(@category))}
            </button>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end

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
          <% match_count = category_match_count(category, schemas, @search_text) %>
          <% total = length(schemas) %>
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

  defp flat_llm_schemas(schemas) do
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

  # ── Model profile helpers ──
  # These safely read from profile maps that may have atom OR string keys
  # (TOML-parsed profiles can arrive with string keys before normalization).

  defp profile_id_string(profile) when is_map(profile) do
    case Map.get(profile, :id) || Map.get(profile, "id") do
      nil -> ""
      id -> to_string(id)
    end
  end

  defp profile_id_string(_), do: ""

  defp profile_concurrency(profile) when is_map(profile) do
    Map.get(profile, :concurrency) || Map.get(profile, "concurrency")
  end

  defp profile_concurrency(_), do: nil

  defp profile_param(profile, key) when is_map(profile) and is_atom(key) do
    Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
  end

  defp profile_param(_, _), do: nil

  # Builds a compact summary string of generation params, e.g.
  # "temp: 0.7, max_tokens: 4096". Returns nil if no params are set.
  defp profile_params_summary(profile) when is_map(profile) do
    parts =
      [
        {:temperature, gettext("temp")},
        {:max_tokens, gettext("max_tokens")},
        {:reasoning_effort, gettext("reasoning")},
        {:top_p, gettext("top_p")},
        {:top_k, gettext("top_k")},
        {:frequency_penalty, gettext("freq_penalty")},
        {:presence_penalty, gettext("pres_penalty")}
      ]
      |> Enum.map(fn {key, label} ->
        value = profile_param(profile, key)
        if is_nil(value), do: nil, else: "#{label}: #{value}"
      end)
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, ", ")
  end

  defp profile_params_summary(_), do: nil

  defp default_label(nil), do: gettext("empty")
  defp default_label(value) when is_atom(value), do: to_string(value)
  defp default_label(value), do: to_string(value)

  def category_display_name(:scheduler), do: gettext("Scheduler")
  def category_display_name(:llm), do: gettext("LLM")
  def category_display_name(:user), do: gettext("User")
  def category_display_name(:sandbox), do: gettext("Sandbox")
  def category_display_name(:truncation), do: gettext("Truncation")
  def category_display_name(:task_history), do: gettext("Task History")
  def category_display_name(:tools), do: gettext("Tools")
  def category_display_name(:server), do: gettext("Server")
  def category_display_name(:nix), do: gettext("Nix")

  def category_icon(:scheduler), do: "hero-cog-6-tooth"
  def category_icon(:llm), do: "hero-sparkles"
  def category_icon(:user), do: "hero-user"
  def category_icon(:sandbox), do: "hero-shield-check"
  def category_icon(:truncation), do: "hero-scissors"
  def category_icon(:task_history), do: "hero-clock"
  def category_icon(:tools), do: "hero-wrench-screwdriver"
  def category_icon(:server), do: "hero-server"
  def category_icon(:nix), do: "hero-cube-transparent"

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

  defp category_description(:tools),
    do: gettext("Configure external tool integrations such as web search.")

  defp category_description(:server),
    do: gettext("Configure the web dashboard listen address and port.")

  defp category_description(:nix),
    do: gettext("Configure Nix develop environment integration for tool calls.")

  defp sort_categories(categories) do
    order = [:llm, :scheduler, :user, :sandbox, :truncation, :task_history, :server, :tools, :nix]
    Enum.sort_by(categories, fn {cat, _} -> Enum.find_index(order, &(&1 == cat)) || 99 end)
  end

  defp category_match_count(_category, schemas, search_text) do
    Enum.count(schemas, &schema_matches?(&1, search_text))
  end

  def schema_matches?(_schema, ""), do: true

  def schema_matches?(schema, search_text) do
    lower = String.downcase(search_text)

    String.contains?(String.downcase(Enum.join(schema.key_path, ".")), lower) or
      String.contains?(String.downcase(schema.description), lower)
  end

  defp api_key_prefix_hint(:openai), do: "sk-proj-..."
  defp api_key_prefix_hint(:anthropic), do: "sk-ant-api03-..."
  defp api_key_prefix_hint(:google), do: "AIzaSy..."
  defp api_key_prefix_hint(:deepseek), do: "sk-..."
  defp api_key_prefix_hint(:alibaba), do: "sk-..."
  defp api_key_prefix_hint(:zai), do: gettext("No prefix (hexadecimal)")
  defp api_key_prefix_hint(:minimax), do: "sk-cp-... or sk-..."
  defp api_key_prefix_hint(_other), do: nil
end
