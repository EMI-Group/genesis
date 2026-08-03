defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Onboarding page for new users.

  The primary onboarding action is configuring a first LLM inline: a flat grid
  of all quick-setup models (across providers), API key entry, and save. When a
  model profile already exists, the page shows a friendly "you're ready" state.
  """

  use EvoDashWeb, :live_view

  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ModelProfileHelpers

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.simple flash={@flash}>
      <div class="flex-1 flex flex-col items-center px-4 py-10 sm:py-16">
        <div class="w-full max-w-xl flex flex-col">
          <!-- Header -->
          <div class="text-center mb-8">
            <h2 class="text-2xl font-bold tracking-tight text-slate-900">
              {if @has_model?,
                do: gettext("You're All Set!"),
                else: gettext("Set up your LLM")}
            </h2>

            <p class="text-sm text-slate-500 mt-2">
              {if @has_model?,
                do:
                  gettext(
                    "Your LLM is configured and ready. You can now start building and evolving codebases with Genesis."
                  ),
                else:
                  gettext(
                    "Pick a model below, then enter your API key. Keys are stored locally, never sent anywhere."
                  )}
            </p>
          </div>

          <%= if @has_model? do %>
            <!-- All-set state: ready to go -->
            <div class="flex flex-col items-center gap-6">
              <div class="flex items-center gap-3 text-slate-700">
                <.icon name="hero-check-circle" class="size-6 text-green-600 shrink-0" />
                <p class="text-sm">
                  {gettext("Your LLM is configured. You can manage it anytime in Settings.")}
                </p>
              </div>

              <div class="flex items-center gap-4">
                <button
                  id="welcome-get-started"
                  phx-click="get_started"
                  class="btn btn-primary rounded-full px-8"
                >
                  {gettext("Get started")}
                </button>

                <a
                  href={~p"/settings"}
                  class="text-sm text-slate-400 hover:text-slate-600 transition-colors"
                >
                  {gettext("Open Settings")}
                </a>
              </div>
            </div>
          <% else %>
            <!-- Setup state: search + model list + API key -->
            <div class="relative mb-4">
              <.icon
                name="hero-magnifying-glass"
                class="size-4 text-slate-400 absolute left-3.5 top-1/2 -translate-y-1/2 pointer-events-none"
              />
              <form id="welcome-search" class="contents" phx-submit="noop">
                <input
                  type="text"
                  phx-change="search_models"
                  phx-debounce="150"
                  name="search_query"
                  value={@search_query}
                  placeholder={gettext("Search models or providers…")}
                  class="w-full rounded-full border border-slate-200 bg-white pl-10 pr-9 py-2.5 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-slate-400"
                />
              </form>

              <%= if @search_query != "" do %>
                <button
                  type="button"
                  phx-click="search_models"
                  phx-value-search_query=""
                  class="absolute inset-y-0 right-0 flex items-center pr-3.5 text-slate-400 hover:text-slate-600 transition-colors"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              <% end %>
            </div>
            <!-- Model list -->
            <div class="max-h-[46vh] overflow-y-auto pr-1">
              <%= if filtered_groups(@grouped_models, @search_query) == [] do %>
                <div class="py-10 text-center">
                  <.icon name="hero-magnifying-glass" class="size-8 text-slate-300 mx-auto mb-2" />
                  <p class="text-sm text-slate-400">
                    {gettext("No models match your search.")}
                  </p>
                </div>
              <% else %>
                <%= for group <- filtered_groups(@grouped_models, @search_query) do %>
                  <div class="mb-4">
                    <p class="text-xs font-semibold text-slate-500 mb-1.5 px-1">
                      {t_provider(group.provider_display_name)}
                    </p>

                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-1.5">
                      <%= for entry <- group.models do %>
                        <% selected =
                          @selected_entry && @selected_entry.model_string == entry.model_string %>
                        <button
                          phx-click="select_welcome_model"
                          phx-value-model_string={entry.model_string}
                          class={[
                            "rounded-xl border px-3 py-2 text-left transition-colors",
                            selected && "border-slate-900 bg-slate-900 text-white",
                            !selected &&
                              "border-slate-200 bg-white text-slate-700 hover:border-slate-400"
                          ]}
                        >
                          <span class="block text-sm font-medium">{entry.model_display_name}</span>
                          <span class={[
                            "block text-[11px] leading-tight",
                            selected && "text-slate-300",
                            !selected && "text-slate-400"
                          ]}>
                            {t_provider(entry.provider_display_name)}{variant_suffix(entry)}
                          </span>
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <p class="text-[11px] text-slate-400 leading-relaxed px-1 mt-2">
                {gettext(
                  "Need a different model, a custom API base URL, or advanced settings? Skip this page and visit the full"
                )}
                <a href={~p"/settings"} class="underline">
                  {gettext("Settings page")}
                </a>
                .
              </p>
            </div>
            <!-- Selected model: API key + save -->
            <div class="mt-4 pt-4 border-t border-slate-100">
              <%= if @selected_entry do %>
                <% key_is_set = Map.get(@credentials, @selected_entry.credential_key) not in [nil, ""] %> <% can_save =
                  @api_key_input != "" or key_is_set %>
                <form phx-submit="save_welcome_setup" id="welcome-save-form">
                  <input type="hidden" name="credential_key" value={@selected_entry.credential_key} />
                  <input type="hidden" name="model_string" value={@selected_entry.model_string} />
                  <input
                    type="hidden"
                    name="provider_id"
                    value={Atom.to_string(@selected_entry.provider_id)}
                  />
                  <input
                    type="hidden"
                    name="variant_id"
                    value={
                      if(@selected_entry.variant_id,
                        do: Atom.to_string(@selected_entry.variant_id),
                        else: ""
                      )
                    }
                  />
                  <label class="flex items-center gap-2 mb-1.5 text-sm font-medium text-slate-700">
                    <.icon name="hero-key" class="size-4 text-slate-400" />
                    <span>{@selected_entry.credential_key}</span>
                    <%= if key_is_set do %>
                      <span class="text-green-600 text-xs font-bold">✓ {gettext("Set")}</span>
                    <% end %>
                  </label>

                  <input
                    type="password"
                    name="api_key"
                    phx-change="api_key_changed"
                    value={@api_key_input}
                    placeholder={
                      if key_is_set,
                        do: gettext("API key is already set"),
                        else: gettext("Enter your API key")
                    }
                    class={[
                      "w-full rounded-xl border bg-white px-3.5 py-2.5 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none",
                      if(key_is_set,
                        do: "border-green-500 focus:border-green-600",
                        else: "border-slate-200 focus:border-slate-400"
                      )
                    ]}
                  />
                  <p class="text-[11px] text-slate-400 mt-1.5">
                    {gettext("Enter your API key for %{provider}.",
                      provider: t_provider(@selected_entry.provider_display_name)
                    )}
                  </p>

                  <button
                    type="submit"
                    disabled={!can_save}
                    class={[
                      "btn btn-primary rounded-full w-full mt-3",
                      !can_save && "btn-disabled opacity-50 cursor-not-allowed"
                    ]}
                  >
                    {gettext("Save & Use this model")}
                  </button>
                </form>
              <% else %>
                <p class="text-xs text-slate-400 text-center py-2">
                  {gettext("Select a model above to enter your API key.")}
                </p>
              <% end %>
            </div>
          <% end %>
          <!-- Skip link + version -->
          <div class="flex items-center justify-between mt-8">
            <button
              id="welcome-skip"
              phx-click="skip"
              class="text-xs text-slate-400 hover:text-slate-600 transition-colors"
            >
              {gettext("Skip")}
            </button>

            <span class="text-xs text-slate-300">
              {gettext("Genesis %{version}", version: @current_version)}
            </span>
          </div>
        </div>
      </div>
      <EvoDashWeb.Layouts.simple_corner />
    </EvoDashWeb.Layouts.simple>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    file_config = ConfigIO.load_file_config()
    model_profiles = get_in(file_config, [:llm, :models]) || []
    llm_providers = EvoGit.Config.LLMCatalog.providers()
    flat_models = flatten_models(llm_providers)

    current_version = Application.spec(:evo_git, :vsn) |> to_string()

    socket =
      assign(socket,
        file_config: file_config,
        model_profiles: model_profiles,
        has_model?: model_profiles != [],
        credentials: EvoGit.Config.credentials(),
        llm_providers: llm_providers,
        flat_models: flat_models,
        grouped_models: group_models_by_provider(flat_models),
        search_query: "",
        api_key_input: "",
        selected_entry: nil,
        current_version: current_version
      )

    {:ok, socket}
  end

  @impl true
  def handle_info(:advance_to_home, socket) do
    {:noreply, redirect(socket, to: "/welcome/complete")}
  end

  @impl true
  def handle_event("search_models", %{"search_query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query || "")}
  end

  # Prevents page reload when the user presses Enter inside the search form.
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("api_key_changed", %{"api_key" => key}, socket) do
    {:noreply, assign(socket, :api_key_input, key || "")}
  end

  @impl true
  def handle_event("select_welcome_model", params, socket) do
    model_string = params["model_string"]

    entry =
      Enum.find(socket.assigns.flat_models, fn e ->
        e.model_string == model_string
      end)

    # Reset the typed key input when switching models — the credential_key
    # context changes.
    {:noreply, assign(socket, selected_entry: entry, api_key_input: "")}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Merged save: API key + model profile in one action
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event(
        "save_welcome_setup",
        %{
          "credential_key" => credential_key,
          "api_key" => api_key,
          "model_string" => model_string,
          "provider_id" => provider_id_str,
          "variant_id" => variant_id_str
        },
        socket
      ) do
    api_key = String.trim(api_key || "")
    key_already_set = Map.get(socket.assigns.credentials, credential_key) not in [nil, ""]

    cond do
      # No new key typed AND no existing key → block the save (button should be
      # disabled, but guard server-side too).
      api_key == "" and not key_already_set ->
        {:noreply, put_flash(socket, :error, gettext("Please enter your API key first."))}

      # Save the credential if a new key was entered.
      api_key != "" ->
        case EvoGit.Config.save_credentials(%{credential_key => api_key}) do
          :ok ->
            socket =
              socket
              |> assign(:credentials, EvoGit.Config.credentials())
              |> assign(:api_key_input, "")

            do_save_model_profile(model_string, provider_id_str, variant_id_str, socket)

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to save API key: %{reason}", reason: inspect(reason))
             )}
        end

      # An existing key is already set — skip credential save, just save model.
      true ->
        do_save_model_profile(model_string, provider_id_str, variant_id_str, socket)
    end
  end

  @impl true
  def handle_event("skip", _, socket) do
    {:noreply, redirect(socket, to: "/welcome/complete")}
  end

  @impl true
  def handle_event("get_started", _, socket) do
    {:noreply, redirect(socket, to: "/welcome/complete")}
  end

  # Resolves the model spec from provider + model + variant, then adds the
  # model profile, mirrors the default, and persists. Shows a combined success
  # flash. Returns {:noreply, socket}.
  #
  # Note: the welcome page does not collect a base_url (custom-model-only
  # providers with base_url are excluded from the flat grid). If a provider
  # somehow requires one, an error flash is shown.
  defp do_save_model_profile(model_string, provider_id_str, variant_id_str, socket) do
    provider = Map.get(ConfigIO.provider_by_id_str(), provider_id_str)

    result =
      cond do
        is_nil(provider) ->
          {:error, gettext("Unknown provider.")}

        String.trim(model_string || "") == "" ->
          {:error, gettext("Model name cannot be empty.")}

        true ->
          model_name =
            if String.contains?(model_string, ":") do
              [_provider_prefix, name] = :binary.split(model_string, ":")
              name
            else
              model_string
            end

          if EvoGit.Config.LLMCatalog.requires_base_url?(provider.id) do
            {:error, gettext("Base URL cannot be empty.")}
          else
            provider_atom = hd(provider.provider_atoms)

            opts =
              if variant_id_str != nil and variant_id_str != "" do
                variant_atom = Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id_str)
                Keyword.put([], :variant, variant_atom)
              else
                []
              end

            {:ok, EvoGit.Config.LLMCatalog.resolve_model_spec(provider_atom, model_name, opts)}
          end
      end

    case result do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:ok, model_value} ->
        file_config =
          socket.assigns.file_config
          |> ModelProfileHelpers.add_model_profile(model_value)
          |> ModelProfileHelpers.mirror_default_model()

        persist_file_config(
          file_config,
          socket,
          gettext("Model and API key saved. You're all set!")
        )
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private: model flattening
  # ───────────────────────────────────────────────────────────────────────────

  # Flattens the LLMCatalog provider list into a single flat list of model
  # entries, each carrying enough data to render a button and drive the
  # `save_welcome_setup` params. Providers with variants are expanded so each
  # variant is a separate entry (each variant has its own credential_key).
  # Custom-model-only providers (OpenRouter, OpenAI-Compatible) have empty
  # model lists and are omitted from the flat grid — the focus is preset
  # models.
  defp flatten_models(providers) do
    providers
    |> Enum.reject(&(&1[:custom_model] == true))
    |> Enum.flat_map(&flatten_provider/1)
  end

  # Groups the flat model list by provider_display_name, sorted alphabetically
  # (case-insensitive). Returns a list of
  # `%{provider_display_name: binary(), models: [entry, ...]}` maps. The flat
  # list is kept as the canonical data source for model lookups.
  defp group_models_by_provider(flat_models) do
    grouped = Enum.group_by(flat_models, & &1.provider_display_name)

    grouped
    |> Enum.sort_by(fn {name, _models} -> String.downcase(name) end)
    |> Enum.map(fn {name, models} -> %{provider_display_name: name, models: models} end)
  end

  defp flatten_provider(provider) do
    variants = provider[:variants]

    if variants do
      # Expand each variant as a separate entry for each model.
      Enum.flat_map(variants, fn variant ->
        Enum.map(provider.models, fn model ->
          build_flat_entry(provider, model, variant)
        end)
      end)
    else
      Enum.map(provider.models, fn model ->
        build_flat_entry(provider, model, nil)
      end)
    end
  end

  defp build_flat_entry(provider, model, variant) do
    provider_atom = hd(provider.provider_atoms)

    resolved_atom =
      if variant do
        EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom, variant.id)
      else
        EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom)
      end

    model_string = "#{resolved_atom}:#{model.id}"

    %{
      provider_id: provider.id,
      provider_display_name: provider.display_name,
      variant_id: variant && variant.id,
      variant_display_name: variant && variant.display_name,
      credential_key: if(variant, do: variant.credential_key, else: provider.credential_key),
      model_id: model.id,
      model_display_name: model.display_name,
      resolved_atom: resolved_atom,
      model_string: model_string,
      requires_base_url: provider[:requires_base_url] == true
    }
  end

  # Renders a subtle suffix for variant providers (e.g. " · Global").
  defp variant_suffix(%{variant_display_name: nil}), do: ""
  defp variant_suffix(%{variant_display_name: name}), do: " · #{name}"

  # Filters the grouped model list by a case-insensitive substring match
  # against provider display name, model display name, or variant display
  # name. Returns the filtered list of group maps (preserving alphabetical
  # order). Groups with no matching models are omitted entirely.
  defp filtered_groups(grouped_models, query) do
    trimmed = String.trim(query || "")

    if trimmed == "" do
      grouped_models
    else
      needle = String.downcase(trimmed)

      grouped_models
      |> Enum.map(fn %{models: models} = group ->
        matching =
          Enum.filter(models, fn entry ->
            String.downcase(entry.model_display_name) =~ needle or
              String.downcase(entry.provider_display_name) =~ needle or
              (entry.variant_display_name != nil and
                 String.downcase(entry.variant_display_name) =~ needle)
          end)

        %{group | models: matching}
      end)
      |> Enum.reject(fn %{models: models} -> models == [] end)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private: provider name i18n
  # ───────────────────────────────────────────────────────────────────────────

  # Provider display names — wrapped in gettext for i18n.
  #
  # Most LLM provider brand names are NOT translated in practice — "OpenAI"
  # stays "OpenAI" in most languages. That's fine; leave them untranslated
  # (the gettext call is still present so the extractor picks them up and a
  # translator CAN localize them if an established localized name exists).
  #
  # The clauses below are intentionally one-per-literal-name so that each
  # `gettext("…")` call uses a literal msgid (the extractor only harvests
  # literal msgids — `gettext(variable)` is ignored). Chinese references are
  # provided as inline comments for translators.
  defp t_provider("Anthropic"), do: gettext("Anthropic")
  # zh: 谷歌
  defp t_provider("Google"), do: gettext("Google")
  # zh: 深度求索
  defp t_provider("DeepSeek"), do: gettext("DeepSeek")
  # zh: 阿里云（通义千问）
  defp t_provider("Alibaba Cloud (Qwen)"), do: gettext("Alibaba Cloud (Qwen)")
  # zh: 智谱（Z.ai）
  defp t_provider("Z.ai (Zhipu AI)"), do: gettext("Z.ai (Zhipu AI)")
  # zh: 稀宇科技
  defp t_provider("MiniMax"), do: gettext("MiniMax")
  # zh: 月之暗面（Kimi）
  defp t_provider("Moonshot AI (Kimi)"), do: gettext("Moonshot AI (Kimi)")
  defp t_provider("xAI"), do: gettext("xAI")
  defp t_provider("OpenRouter"), do: gettext("OpenRouter")
  # zh: OpenAI 兼容 API
  defp t_provider("OpenAI-Compatible API"), do: gettext("OpenAI-Compatible API")
  defp t_provider("OpenAI"), do: gettext("OpenAI")
  # Fallback for any provider not explicitly listed above.
  defp t_provider(name), do: name

  # ───────────────────────────────────────────────────────────────────────────
  # Private: config persistence
  # ───────────────────────────────────────────────────────────────────────────

  defp persist_file_config(file_config, socket, success_msg) do
    # Always update in-memory state so the UI reflects the change immediately.
    socket = assign(socket, :file_config, file_config)

    case EvoGit.Config.save_user_config(file_config) do
      :ok ->
        file_config = ConfigIO.load_file_config()
        model_profiles = get_in(file_config, [:llm, :models]) || []

        socket =
          socket
          |> assign(:file_config, file_config)
          |> assign(:model_profiles, model_profiles)
          |> assign(:has_model?, model_profiles != [])
          |> put_flash(:info, success_msg)

        # Auto-advance to the home page shortly after a successful save —
        # no extra click needed.
        Process.send_after(self(), :advance_to_home, 1200)

        {:noreply, ConfigIO.update_runtime_from_file_config(file_config, socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
         )}
    end
  end
end
