defmodule EvoDashWeb.SettingsComponents do
  @moduledoc """
  Components for the settings GUI editor: config-key cards, category
  sections, and schema-driven inputs.
  """

  # zh_CN: Agent → "智能体", Token → "词元", Provider → "服务商",
  # Tool call → "工具调用", Sandbox → "沙箱", Context window → "上下文窗口"

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.CategoryMetadata,
    only: [
      category_icon: 1,
      category_display_name: 1,
      category_description: 1,
      api_key_prefix_hint: 1
    ]

  import EvoDashWeb.SettingsComponents.SettingCard,
    only: [setting_card: 1, flat_llm_schemas: 1]

  import EvoDashWeb.SettingsComponents.ModelProfilesEditor,
    only: [model_profiles_editor: 1]

  # ── Delegates for public APIs NOT already imported above.
  #    Functions imported above (category_display_name, category_icon,
  #    category_description, api_key_prefix_hint, setting_card,
  #    model_profiles_editor, flat_llm_schemas) are already callable
  #    as EvoDashWeb.SettingsComponents.func/arity via import. ──

  defdelegate schema_matches?(schema, search_text), to: EvoDashWeb.SettingsComponents.CategoryMetadata
  defdelegate model_display(value), to: EvoDashWeb.SettingsComponents.SettingCard
  defdelegate search_results(assigns), to: EvoDashWeb.SettingsComponents.SearchResults
  defdelegate settings_sidebar(assigns), to: EvoDashWeb.SettingsComponents.Sidebar

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
  attr(:credentials, :map, default: %{})

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
                <%!-- zh_CN: provider → "服务商" --%>{gettext("Select a provider to quickly configure your model and API key.")}
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
                  <% requires_base_url = EvoGit.Config.LLMCatalog.requires_base_url?(@selected_provider_id) %>
                  <%!-- Pre-fill helpers: read the current flat model for the selected provider --%>
                  <% custom_prefill_id =
                    if is_map(current_model) do
                      to_string(current_model[:id] || current_model["id"] || "")
                    else
                      if is_binary(current_model) and String.contains?(current_model, ":") do
                        [_provider, id] = :binary.split(current_model, ":")
                        id
                      else
                        if is_binary(current_model), do: current_model, else: ""
                      end
                    end %>
                  <% custom_prefill_base_url =
                    if is_map(current_model) do
                      to_string(current_model[:base_url] || current_model["base_url"] || "")
                    else
                      ""
                    end %>
                  <form phx-submit="save_custom_model" class="mb-5 space-y-4">
                    <input type="hidden" name="provider_id" value={@selected_provider_id} />
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text font-bold text-sm mb-2 block">{gettext("Model Name")}</span>
                      </label>
                      <input
                        type="text"
                        name="model_name"
                        value={custom_prefill_id}
                        placeholder={gettext("e.g. gpt-4o or anthropic/claude-3.5-sonnet")}
                        class="input input-bordered w-full rounded-xl shadow-sm bg-base-50 font-mono text-sm"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text font-bold text-sm mb-2 block">
                          {gettext("Base URL")}
                          <%= if requires_base_url do %>
                            <span class="text-error">*</span>
                          <% end %>
                        </span>
                      </label>
                      <input
                        type="text"
                        name="base_url"
                        value={custom_prefill_base_url}
                        placeholder={gettext("https://api.my-provider.com/v1")}
                        class="input input-bordered w-full rounded-xl shadow-sm bg-base-50 font-mono text-sm"
                      />
                      <p class="text-xs text-base-content/70 leading-relaxed mt-1">
                        <%!-- zh_CN: provider → "服务商" --%>{gettext(
                          "For proxy/aggregator endpoints. Leave empty for standard provider endpoints."
                        )}
                      </p>
                    </div>
                    <%= if requires_base_url do %>
                      <div class="bg-warning/5 border border-warning/20 rounded-xl p-3 flex gap-2 items-start">
                        <.icon
                          name="hero-exclamation-triangle"
                          class="size-5 text-warning shrink-0 mt-0.5"
                        />
                        <p class="text-xs font-medium text-warning/80 leading-relaxed">
                          <%!-- zh_CN: tool calls → "工具调用", provider → "服务商" --%>{gettext(
                            "Warning: OpenAI-compatible APIs vary in compatibility. Some features (tool calls, streaming, structured output) may not work depending on the provider."
                          )}
                        </p>
                      </div>
                    <% end %>
                    <button type="submit" class="btn btn-primary btn-sm rounded-xl">
                      {gettext("Set Model")}
                    </button>
                  </form>
                <% end %>

                <%!-- API Key input --%>
                <% key_is_set = api_key_present?(provider.env_var, @credentials) %>
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
                    <button phx-click="test_llm" class="btn btn-primary btn-sm gap-2" disabled={@disabled}>
                      <.icon name="hero-signal" class="size-4" />
                      {gettext("Test Connection")}
                    </button>
                  <% :testing -> %>
                    <span class="loading loading-spinner loading-sm text-primary"></span>
                    <span class="text-sm text-base-content/80">{gettext("Testing LLM connection...")}</span>
                  <% {:ok, data} -> %>
                    <.icon name="hero-check-circle" class="size-5 text-success" />
                    <span class="text-sm text-success font-medium">{gettext("Connected")}</span>
                    <span class="text-xs text-base-content/70">({model_display(data.model)})</span>
                    <span class="text-xs text-base-content/70 bg-base-200/50 px-2 py-0.5 rounded">"{truncate_string(
                      data.response,
                      50
                    )}"</span>
                    <button phx-click="test_llm" class="btn btn-ghost btn-xs gap-1 ml-2" disabled={@disabled}>
                      <.icon name="hero-arrow-path" class="size-3" />
                      {gettext("Retest")}
                    </button>
                  <% {:error, reason} -> %>
                    <.icon name="hero-x-circle" class="size-5 text-error" />
                    <span class="text-sm text-error">{reason}</span>
                    <button phx-click="test_llm" class="btn btn-ghost btn-xs gap-1 ml-2" disabled={@disabled}>
                      <.icon name="hero-arrow-path" class="size-3" />
                      {gettext("Retry")}
                    </button>
                <% end %>
              </div>
            </div>

            <%!-- Help text for other providers --%>
            <div class="mb-6 bg-base-200/30 rounded-lg p-4 border border-base-200">
              <p class="text-xs text-base-content/70 leading-relaxed">
                <%!-- zh_CN: provider → "服务商" --%>{raw(
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
                            <%!-- zh_CN: sandbox → "沙箱" --%>{gettext(
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
                            <%!-- zh_CN: sandbox → "沙箱" --%>{gettext(
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
                      disabled={@disabled}
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
                        disabled={@disabled or @sandbox_mode == :disabled}
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
                        disabled={@disabled or @sandbox_mode == :disabled}
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

  # Checks whether a specific provider's API key env var is already configured —
  # either as an OS environment variable OR as a non-nil, non-empty value in the
  # parsed credentials.toml map (obtained from EvoGit.Config.credentials/0).
  # This keeps the quick-setup UI consistent with EvoGit.Config.config_status/0,
  # which treats both sources as valid.
  defp api_key_present?(env_var, credentials) do
    System.get_env(env_var) != nil or
      case Map.get(credentials, env_var) do
        nil -> false
        "" -> false
        _ -> true
      end
  end
end
