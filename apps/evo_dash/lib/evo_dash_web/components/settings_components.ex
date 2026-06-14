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
      "relative bg-base-100 rounded-[1.5rem] border border-base-200 shadow-sm hover:shadow-md transition-all duration-300 p-6 flex flex-col group min-w-[320px] flex-1",
      @disabled && "opacity-60 pointer-events-none grayscale-[20%]"
    ]}>
      <div class="flex-1">
        <div class="flex items-start justify-between gap-4 mb-4">
          <div class="flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-primary/40 group-hover:bg-primary transition-colors duration-300"></div>
            <span class="font-mono text-xs font-bold tracking-wider text-base-content/80">
              {Enum.join(@schema.key_path, ".")}
            </span>
          </div>
          <button
            type="button"
            phx-click="reset_key"
            phx-value-key_path={Enum.join(@schema.key_path, ".")}
            class="opacity-0 group-hover:opacity-100 btn btn-ghost btn-circle btn-sm text-base-content/40 hover:text-primary hover:bg-primary/10 transition-all duration-200 -mt-1 -mr-1"
            title={gettext("Reset to default")}
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </div>
        
        <p class="text-sm text-base-content/60 mb-6 leading-relaxed font-medium">{Gettext.gettext(EvoDashWeb.Gettext, @schema.description)}</p>
      </div>

      <div class="mt-auto flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div class="form-control flex-1 w-full">
          <%= case @schema.type do %>
            <% :pos_integer -> %>
              <input
                type="number"
                name={Enum.join(@schema.key_path, ".")}
                value={input_value(@value)}
                min={@schema.validation[:min] || 1}
                max={@schema.validation[:max]}
                placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                class="input input-bordered w-full sm:max-w-[180px] font-mono shadow-sm hover:border-primary/40 focus:border-primary focus:ring-4 focus:ring-primary/10 transition-all duration-200 rounded-xl bg-base-50 text-base"
              />
            <% :non_neg_integer -> %>
              <input
                type="number"
                name={Enum.join(@schema.key_path, ".")}
                value={input_value(@value)}
                min={@schema.validation[:min] || 0}
                max={@schema.validation[:max]}
                placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                class="input input-bordered w-full sm:max-w-[180px] font-mono shadow-sm hover:border-primary/40 focus:border-primary focus:ring-4 focus:ring-primary/10 transition-all duration-200 rounded-xl bg-base-50 text-base"
              />
            <% :integer -> %>
              <input
                type="number"
                name={Enum.join(@schema.key_path, ".")}
                value={input_value(@value)}
                min={@schema.validation[:min]}
                max={@schema.validation[:max]}
                placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                class="input input-bordered w-full sm:max-w-[180px] font-mono shadow-sm hover:border-primary/40 focus:border-primary focus:ring-4 focus:ring-primary/10 transition-all duration-200 rounded-xl bg-base-50 text-base"
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
                class="input input-bordered w-full sm:max-w-[180px] font-mono shadow-sm hover:border-primary/40 focus:border-primary focus:ring-4 focus:ring-primary/10 transition-all duration-200 rounded-xl bg-base-50 text-base"
              />
            <% :string -> %>
              <input
                type="text"
                name={Enum.join(@schema.key_path, ".")}
                value={@value || ""}
                placeholder={if is_nil(@value), do: gettext("empty"), else: ""}
                class="input input-bordered w-full font-mono shadow-sm hover:border-primary/40 focus:border-primary focus:ring-4 focus:ring-primary/10 transition-all duration-200 rounded-xl bg-base-50 text-base"
              />
            <% :atom -> %>
              <div class="relative w-full sm:max-w-[220px]">
                <select
                  name={Enum.join(@schema.key_path, ".")}
                  class="select select-bordered w-full font-mono shadow-sm hover:border-primary/40 focus:border-primary focus:ring-4 focus:ring-primary/10 transition-all duration-200 rounded-xl bg-base-50 appearance-none pr-10 text-base"
                >
                  <%= for opt <- @schema.validation[:in] || [] do %>
                    <option value={to_string(opt)} selected={to_string(@value) == to_string(opt)}>
                      {to_string(opt)}
                    </option>
                  <% end %>
                </select>
                <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center px-3 text-base-content/50">
                  <.icon name="hero-chevron-down" class="size-4" />
                </div>
              </div>
          <% end %>
        </div>

        <div class="sm:text-right shrink-0 mt-2 sm:mt-0">
          <p class="text-[11px] font-semibold text-base-content/40 flex items-center sm:justify-end gap-2">
            <span class="uppercase tracking-wider opacity-80">{gettext("Default")}</span>
            <span class="badge badge-sm badge-ghost font-mono opacity-90 px-2 py-2">{default_label(@schema.default)}</span>
          </p>
        </div>
      </div>

      <%= if @error do %>
        <div class="mt-4 p-3 bg-error/10 text-error text-sm rounded-xl flex items-start gap-2.5 border border-error/20">
          <.icon name="hero-exclamation-circle" class="size-5 shrink-0 mt-0.5" />
          <p class="font-semibold">{@error.message}</p>
        </div>
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
  attr(:llm_providers, :list, default: [])
  attr(:selected_provider_id, :atom, default: nil)
  attr(:selected_provider_models, :list, default: [])
  attr(:selected_variant_id, :atom, default: nil)
  attr(:llm_test_status, :any, default: :idle)

  def category_section(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col h-full bg-base-100/50" id={"category-#{@category}"}>
      <%!-- Sticky Header --%>
      <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-xl border-b border-base-200/60 px-8 py-6">
        <div class="flex items-center gap-4 mb-2">
          <div class="p-2.5 bg-gradient-to-br from-primary/20 to-primary/5 text-primary rounded-xl shadow-sm border border-primary/10">
            <.icon name={category_icon(@category)} class="size-6" />
          </div>
          <h2 class="text-2xl font-extrabold tracking-tight text-base-content">{category_display_name(@category)}</h2>
        </div>
        <p class="text-sm font-medium text-base-content/60 ml-1.5">{category_description(@category)}</p>
      </div>

      <%!-- Scrollable Content --%>
      <div class="flex-1 overflow-y-auto px-8 py-8 relative">
        <div class="">
          <%= if @category == :llm do %>
            <%!-- LLM Provider Quick Setup --%>
            <div class="mb-8 bg-gradient-to-br from-primary/5 to-primary/0 rounded-3xl border border-primary/10 p-6">
              <h3 class="text-lg font-bold text-base-content mb-1">{gettext("Quick Setup")}</h3>
              <p class="text-sm text-base-content/60 mb-5">{gettext("Select a provider to quickly configure your model and API key.")}</p>

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
                      @selected_provider_id != provider.id && "btn-ghost bg-base-200/50 hover:bg-base-200"
                    ]}
                  >
                    {provider.display_name}
                  </button>
                <% end %>
              </div>

              <%!-- Variant and model shortcuts when provider is selected --%>
              <%= if @selected_provider_id != nil do %>
                <% provider = EvoGit.Config.LLMCatalog.find_provider(@selected_provider_id) %>
                <% variants = provider[:variants] %>
                <% has_variants = is_list(variants) and length(variants) > 0 %>
                <% show_models = not has_variants or (@selected_variant_id != nil) %>
                <% current_model = get_in(@file_config, [:llm, :model]) %>

                <%!-- Variant selection (only if provider has variants) --%>
                <%= if has_variants do %>
                  <div class="mb-5">
                    <p class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">{gettext("Select a variant:")}</p>
                    <div class="flex flex-wrap gap-2">
                      <%= for variant <- variants do %>
                        <button
                          type="button"
                          phx-click="select_llm_variant"
                          phx-value-variant_id={variant.id}
                          class={[
                            "btn btn-xs rounded-xl font-medium transition-all duration-200",
                            @selected_variant_id == variant.id && "btn-secondary shadow-md",
                            @selected_variant_id != variant.id && "btn-ghost bg-secondary/10 hover:bg-secondary/20 text-secondary"
                          ]}
                        >
                          {variant.display_name}
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%!-- Model shortcuts (show only if no variants needed, or variant selected) --%>
                <%= if show_models do %>
                  <div class="mb-5">
                    <p class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">{gettext("Quick-select a model:")}</p>
                    <div class="flex flex-wrap gap-2">
                      <%= for model <- @selected_provider_models do %>
                        <% resolved_atom = EvoGit.Config.LLMCatalog.resolve_provider_atom(@selected_provider_id, @selected_variant_id) %>
                        <% model_string = "#{resolved_atom}:#{model.id}" %>
                        <button
                          type="button"
                          phx-click="select_llm_model_shortcut"
                          phx-value-model_string={model_string}
                          class={[
                            "btn btn-sm rounded-xl font-medium transition-all duration-200",
                            current_model == model_string && "btn-primary shadow-md",
                            current_model != model_string && "btn-ghost bg-primary/10 hover:bg-primary/20 text-primary"
                          ]}
                        >
                          {model.display_name}
                        </button>
                      <% end %>
                    </div>
                  </div>
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
                      <p class="text-[11px] text-base-content/40 mt-1.5">
                        <%= if prefix = api_key_prefix_hint(provider.id) do %>
                          {gettext("Enter your API key. It should start with")} <code class="font-mono bg-base-200 px-1 py-0.5 rounded text-[10px]"><%= prefix %></code>
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

            <%!-- LLM Connection Test --%>
            <div class="mb-6 bg-base-100 rounded-2xl border border-base-200/60 p-5">
              <div class="flex items-center gap-3 mb-3">
                <div class="bg-info/15 text-info p-2 rounded-xl">
                  <.icon name="hero-signal" class="size-5" />
                </div>
                <div>
                  <h4 class="font-semibold text-sm">{gettext("Connection Test")}</h4>
                  <p class="text-xs text-base-content/50">{gettext("Verify your LLM configuration is working")}</p>
                </div>
              </div>
              <div class="flex items-center gap-3">
                <%= case @llm_test_status do %>
                  <% :idle -> %>
                    <span class="text-sm text-base-content/60">{gettext("Not tested — click to verify LLM connectivity")}</span>
                    <button phx-click="test_llm" class="btn btn-primary btn-sm gap-2">
                      <.icon name="hero-signal" class="size-4" />
                      {gettext("Test Connection")}
                    </button>
                  <% :testing -> %>
                    <span class="loading loading-spinner loading-sm text-primary"></span>
                    <span class="text-sm text-base-content/60">{gettext("Testing LLM connection...")}</span>
                  <% {:ok, data} -> %>
                    <.icon name="hero-check-circle" class="size-5 text-success" />
                    <span class="text-sm text-success font-medium">{gettext("Connected")}</span>
                    <span class="text-xs text-base-content/40">({data.model})</span>
                    <span class="text-xs text-base-content/50 bg-base-200/50 px-2 py-0.5 rounded">"{truncate_string(data.response, 50)}"</span>
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
            <div class="mb-6 bg-base-200/30 rounded-2xl p-4 border border-base-200/50">
              <p class="text-xs text-base-content/50 leading-relaxed">
                {raw(gettext("<strong>Don't see your provider?</strong> You can enter any model string manually in the Model field below using the format <code class=\"font-mono bg-base-200 px-1.5 py-0.5 rounded\">provider:model-name</code>. Look up your model at <a href=\"https://llmdb.xyz/\" target=\"_blank\" class=\"link link-primary\">llmdb.xyz</a> or see <a href=\"https://req-llm.hexdocs.pm/req_llm/ReqLLM.Providers.html\" target=\"_blank\" class=\"link link-primary\">supported providers</a>."))}
              </p>
            </div>

            <%!-- Render the regular setting cards for LLM --%>
            <div class="flex flex-wrap gap-6 items-stretch">
              <%= for schema <- @schemas do %>
                <.setting_card
                  schema={schema}
                  value={get_in(@file_config, schema.key_path)}
                  error={Enum.find(@errors, &(&1.key_path == schema.key_path))}
                  disabled={@disabled}
                />
              <% end %>
            </div>
          <% else %>
            <%= if @category == :sandbox do %>
              <%!-- Sandbox backend banner --%>
              <div class="mb-8 relative overflow-hidden rounded-3xl">
                <div class="absolute inset-0 bg-gradient-to-br opacity-10 pointer-events-none"></div>
                <%= case @sandbox_backend do %>
                  <% :systemd_run -> %>
                    <div class="flex items-start gap-4 p-5 bg-success/5 border-success/20">
                      <div class="p-2 bg-success/20 text-success rounded-xl mt-0.5 shadow-sm">
                        <.icon name="hero-check-badge" class="size-5" />
                      </div>
                      <div>
                        <h3 class="font-bold text-success mb-1 flex items-center gap-2">
                          systemd-run
                          <span class="badge badge-success badge-sm text-[10px] uppercase tracking-wider font-bold">Active</span>
                        </h3>
                        <p class="text-sm font-medium text-success/80 leading-relaxed">
                          {gettext("Full sandboxing is enabled: filesystem isolation, resource limits, and syscall filtering are active.")}
                        </p>
                      </div>
                    </div>
                  <% :sandbox_exec -> %>
                    <div class="flex items-start gap-4 p-5 bg-warning/5 border-warning/20">
                      <div class="p-2 bg-warning/20 text-warning rounded-xl mt-0.5 shadow-sm">
                        <.icon name="hero-shield-exclamation" class="size-5" />
                      </div>
                      <div>
                        <h3 class="font-bold text-warning mb-1 flex items-center gap-2">
                          sandbox-exec
                          <span class="badge badge-warning badge-sm text-[10px] uppercase tracking-wider font-bold">Active</span>
                        </h3>
                        <p class="text-sm font-medium text-warning/80 leading-relaxed">
                          {gettext("Filesystem isolation is active. Note: Resource limits are not available on macOS.")}
                        </p>
                      </div>
                    </div>
                  <% _ -> %>
                    <div class="flex items-start gap-4 p-5 bg-error/5 border-error/20">
                      <div class="p-2 bg-error/20 text-error rounded-xl mt-0.5 shadow-sm">
                        <.icon name="hero-x-circle" class="size-5" />
                      </div>
                      <div>
                        <h3 class="font-bold text-error mb-1 flex items-center gap-2">
                          {gettext("Not Available")}
                          <span class="badge badge-error badge-sm text-[10px] uppercase tracking-wider font-bold">Disabled</span>
                        </h3>
                        <p class="text-sm font-medium text-error/80 leading-relaxed">
                          {gettext("No sandbox support on this platform. Commands will run directly on the host.")}
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
                  <h3 class="text-xs font-black uppercase tracking-widest text-base-content/40">{gettext("Resources")}</h3>
                  <div class="h-px bg-base-200 flex-1"></div>
                </div>

                <%= if @sandbox_backend != :systemd_run do %>
                  <div class="bg-info/5 border border-info/20 rounded-2xl p-4 mb-6 flex items-start gap-3">
                    <.icon name="hero-information-circle" class="size-5 text-info mt-0.5" />
                    <p class="text-sm font-medium text-info/90 leading-relaxed">
                      {gettext("Resource limits are only available on Linux with systemd-run.")}
                    </p>
                  </div>
                <% end %>

                <div class="flex flex-wrap gap-6 mb-8 items-stretch">
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
                  <h3 class="text-xs font-black uppercase tracking-widest text-base-content/40">{gettext("Process Limits")}</h3>
                  <div class="h-px bg-base-200 flex-1"></div>
                </div>

                <%= if @sandbox_backend != :systemd_run do %>
                  <div class="bg-info/5 border border-info/20 rounded-2xl p-4 mb-6 flex items-start gap-3">
                    <.icon name="hero-information-circle" class="size-5 text-info mt-0.5" />
                    <p class="text-sm font-medium text-info/90 leading-relaxed">
                      {gettext("Process limits are only available on Linux with systemd-run.")}
                    </p>
                  </div>
                <% end %>

                <div class="flex flex-wrap gap-6 mb-8 items-stretch">
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
              <div class="flex flex-wrap gap-6 items-stretch">
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
          <% end %>
        </div>
      </div>

      <%!-- Sticky Footer --%>
      <div class="sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 p-6 flex justify-end">
        <button type="submit" class="btn btn-primary rounded-2xl shadow-[0_8px_20px_-6px_rgba(6,81,237,0.4)] hover:shadow-[0_12px_25px_-6px_rgba(6,81,237,0.5)] hover:-translate-y-0.5 transition-all duration-300 min-w-[240px] font-bold tracking-wide text-[15px] h-14">
          <.icon name="hero-document-check" class="size-5 mr-2" />
          {gettext("Save %{category} Settings", category: category_display_name(@category))}
        </button>
      </div>
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
        <div class="flex items-center gap-4 mb-2">
          <div class="p-2.5 bg-gradient-to-br from-primary/20 to-primary/5 text-primary rounded-xl shadow-sm border border-primary/10">
            <.icon name="hero-magnifying-glass" class="size-6" />
          </div>
          <h2 class="text-2xl font-extrabold tracking-tight text-base-content">{gettext("Search Results")}</h2>
        </div>
        <p class="text-sm font-medium text-base-content/60 ml-1.5">
          <%= if @total_matches == 0 do %>
            {gettext("No settings found matching \"%{query}\"", query: @search_text)}
          <% else %>
            {gettext("%{count} setting(s) matching \"%{query}\"", count: @total_matches, query: @search_text)}
          <% end %>
        </p>
      </div>

      <%!-- Scrollable Content --%>
      <div class="flex-1 overflow-y-auto px-8 py-8">
        <%= if @total_matches == 0 do %>
          <div class="flex flex-col items-center justify-center py-20 text-center">
            <div class="p-4 bg-base-200/50 rounded-3xl mb-4">
              <.icon name="hero-magnifying-glass" class="size-10 text-base-content/30" />
            </div>
            <p class="text-base-content/50 font-medium">{gettext("Try a different search term.")}</p>
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
                  <h3 class="text-lg font-bold tracking-tight text-base-content">{category_display_name(category)}</h3>
                  <span class="text-xs font-bold tabular-nums px-2.5 py-1 rounded-lg bg-base-300/50 text-base-content/40">{length(matching)}</span>
                  <div class="h-px bg-base-200 flex-1"></div>
                </div>
                <div class="flex flex-wrap gap-6 items-stretch">
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
      <div class="sticky bottom-0 z-10 bg-base-100/90 backdrop-blur-xl border-t border-base-200/60 p-6 flex justify-end">
        <button type="submit" class="btn btn-primary rounded-2xl shadow-[0_8px_20px_-6px_rgba(6,81,237,0.4)] hover:shadow-[0_12px_25px_-6px_rgba(6,81,237,0.5)] hover:-translate-y-0.5 transition-all duration-300 min-w-[240px] font-bold tracking-wide text-[15px] h-14">
          <.icon name="hero-document-check" class="size-5 mr-2" />
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
            <.icon name="hero-magnifying-glass" class="size-4 text-base-content/40 group-focus-within:text-primary transition-colors" />
          </div>
          <input
            type="text"
            name="search"
            value={@search_text}
            placeholder={gettext("Filter settings...")}
            phx-change="search"
            class="input w-full pl-10 pr-9 bg-base-200/50 border-transparent hover:bg-base-200 focus:bg-base-100 focus:border-primary/30 focus:ring-2 focus:ring-primary/20 transition-all duration-300 rounded-2xl font-medium text-sm h-12"
          />
          <%= if @search_text != "" do %>
            <button
              type="button"
              phx-click="search"
              phx-value-value=""
              class="absolute inset-y-0 right-0 flex items-center pr-3 text-base-content/40 hover:text-base-content transition-colors"
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
              "w-full text-left px-4 py-3.5 rounded-2xl flex items-center gap-3.5 transition-all duration-300 text-[15px] font-semibold group relative overflow-hidden",
              category == @active_category && "bg-primary text-primary-content shadow-[0_4px_15px_-3px_rgba(6,81,237,0.3)]",
              category != @active_category && "hover:bg-base-200/70 text-base-content/70 hover:text-base-content",
              @search_text != "" and match_count == 0 && "opacity-30"
            ]}
          >
            <%= if category == @active_category do %>
              <div class="absolute inset-0 bg-white/10 opacity-0 group-hover:opacity-100 transition-opacity"></div>
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
                category != @active_category && "bg-base-300/50 text-base-content/40 group-hover:bg-base-300"
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

  defp input_value(nil), do: ""
  defp input_value(value), do: to_string(value)

  defp default_label(nil), do: gettext("empty")
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
