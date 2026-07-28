defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Onboarding page for new users.

  The primary onboarding action is configuring a first LLM inline: a flat grid
  of all quick-setup models (across providers), API key entry, and save. When a
  model profile already exists, the page shows a friendly "you're ready" state.

  Version-state tracking shows a "new version" note once per upgrade.
  """

  use EvoDashWeb, :live_view

  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ModelProfileHelpers

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:welcome}
      simple_nav={false}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
    >
      <div class="flex flex-col items-center justify-center min-h-screen px-4 py-8">
        <!-- Main card -->
        <div class="w-full max-w-5xl bg-base-100 rounded-xl border border-base-200 shadow-sm p-8">
          <!-- Header -->
          <div class="flex flex-col items-center text-center mb-8">
            <div class="w-20 h-20 rounded-full bg-primary/10 flex items-center justify-center mb-6 text-4xl">
              {if @has_model?, do: "✨", else: "🚀"}
            </div>

            <h2 class="text-2xl font-bold mb-3">
              {if @has_model?,
                do: gettext("You're All Set!"),
                else: gettext("Welcome to Genesis")}
            </h2>

            <p class="text-base text-base-content/60 leading-relaxed max-w-md">
              {if @has_model?,
                do: gettext(
                  "Your LLM is configured and ready. You can now start building and evolving codebases with Genesis."
                ),
                else: gettext(
                  "Genesis is an AI-powered software development framework. Let's set up your first LLM to get started."
                )}
            </p>
          </div>

          <%= if @version_upgraded do %>
            <!-- New version note -->
            <div class="mb-6 bg-info/10 border border-info/20 rounded-xl p-4 flex items-start gap-3">
              <.icon name="hero-sparkles" class="size-5 text-info shrink-0 mt-0.5" />
              <div class="text-left">
                <h4 class="font-bold text-info text-sm mb-1">
                  {gettext("Welcome to the new version!")}
                </h4>
                <p class="text-xs text-base-content/60 leading-relaxed">
                  {gettext(
                    "You're running Genesis %{version}. What's new will be available here soon.",
                    version: @current_version
                  )}
                </p>
              </div>
            </div>
          <% end %>

          <%= if @has_model? do %>
            <!-- All-set state: ready to go -->
            <div class="flex flex-col items-center gap-6">
              <div class="bg-success/10 border border-success/20 rounded-xl p-6 flex items-center gap-3 w-full">
                <.icon name="hero-check-circle" class="size-8 text-success shrink-0" />
                <div class="text-left">
                  <p class="font-bold text-success">
                    {gettext("Ready to build!")}
                  </p>
                  <p class="text-sm text-base-content/60 mt-1">
                    {gettext("Your LLM is configured. You can manage it anytime in Settings.")}
                  </p>
                </div>
              </div>

              <div class="flex items-center gap-3 w-full justify-center">
                <button phx-click="get_started" class="btn btn-primary rounded-xl px-8">
                  {gettext("Go to Dashboard")}
                </button>
                <a href={~p"/settings"} class="btn btn-ghost rounded-xl">
                  {gettext("Open Settings")}
                </a>
              </div>
            </div>
          <% else %>
            <!-- Setup state: flat model grid + API key -->
            <div class="mb-6">
              <h3 class="text-lg font-bold mb-1">
                {gettext("Add your first LLM")}
              </h3>
              <p class="text-sm text-base-content/60 mb-4">
                {gettext("Pick a model below, then enter your API key. Keys are stored locally, never sent anywhere.")}
              </p>

              <p class="text-xs font-bold uppercase tracking-wider text-base-content/70 mb-3">
                {gettext("Choose a model:")}
              </p>

              <!-- Models grouped by provider -->
              <%= for group <- @grouped_models do %>
                <div class="mb-5">
                  <p class="text-sm font-bold text-base-content/70 mb-2.5">{group.provider_display_name}</p>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
                    <%= for entry <- group.models do %>
                      <% selected = @selected_entry && @selected_entry.model_string == entry.model_string %>
                      <button
                        phx-click="select_welcome_model"
                        phx-value-model_string={entry.model_string}
                        class={[
                          "btn btn-sm rounded-xl font-medium transition-all duration-200 text-left flex flex-col items-start gap-0.5 h-auto py-2.5",
                          selected && "btn-primary shadow-md",
                          !selected && "btn-ghost bg-primary/10 hover:bg-primary/20 text-primary"
                        ]}
                      >
                        <span class="font-semibold text-sm">{entry.model_display_name}</span>
                        <span class={[
                          "text-[11px] leading-tight",
                          selected && "text-primary-content/80",
                          !selected && "text-base-content/50"
                        ]}>
                          {entry.provider_display_name}{variant_suffix(entry)}
                        </span>
                      </button>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <!-- Selected model: API key + save -->
              <%= if @selected_entry do %>
                <div class="bg-base-50 rounded-xl border border-base-200 p-5">
                  <% key_is_set = Map.get(@credentials, @selected_entry.credential_key) not in [nil, ""] %>

                  <div class="flex items-center gap-2 mb-4">
                    <.icon name="hero-key" class="size-4 text-primary" />
                    <span class="text-sm font-semibold">
                      {gettext("Enter your API key")}
                    </span>
                  </div>

                  <!-- API key form (credentials are stored independently of model config) -->
                  <form phx-submit="save_api_key">
                    <input type="hidden" name="credential_key" value={@selected_entry.credential_key} />
                    <label class="label">
                      <span class="label-text font-semibold text-sm">
                        {@selected_entry.credential_key}
                      </span>
                      <%= if key_is_set do %>
                        <span class="label-text-alt text-success text-xs font-bold">✓ {gettext("Set")}</span>
                      <% end %>
                    </label>
                    <div class="flex items-stretch gap-3">
                      <input
                        type="password"
                        name="api_key"
                        placeholder={
                          if key_is_set,
                            do: gettext("API key is already set"),
                            else: gettext("Enter your API key")
                        }
                        class={[
                          "input input-bordered flex-1 rounded-xl shadow-sm bg-base-100",
                          key_is_set && "input-success"
                        ]}
                      />
                      <button type="submit" class="btn btn-primary btn-sm rounded-xl">
                        {gettext("Save Key")}
                      </button>
                    </div>
                    <p class="text-[11px] text-base-content/70 mt-1.5">
                      {gettext("Enter your API key for %{provider}.", provider: @selected_entry.provider_display_name)}
                    </p>
                  </form>

                  <!-- Confirm model selection -->
                  <div class="mt-4 pt-4 border-t border-base-200">
                    <button phx-click="save_quick_setup" phx-value-model_string={@selected_entry.model_string} phx-value-provider_id={Atom.to_string(@selected_entry.provider_id)} phx-value-variant_id={@selected_entry.variant_id && Atom.to_string(@selected_entry.variant_id) || ""} class="btn btn-primary btn-sm rounded-xl w-full">
                      {gettext("Use this model")}
                      <span class="text-primary-content/80 font-normal ml-1">{@selected_entry.model_display_name}</span>
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- Skip link -->
          <div class="flex justify-center mt-6">
            <button
              phx-click="skip"
              class="text-sm text-base-content/50 hover:text-base-content/70 transition-colors"
            >
              {gettext("Skip")}
            </button>
          </div>
        </div>

        <!-- Version footer -->
        <div class="mt-6 text-xs text-base-content/40">
          {gettext("Genesis %{version}", version: @current_version)}
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    file_config = ConfigIO.load_file_config()
    model_profiles = get_in(file_config, [:llm, :models]) || []
    llm_providers = EvoGit.Config.LLMCatalog.providers()
    flat_models = flatten_models(llm_providers)

    # Version-state tracking (sibling EvoGit.Config.VersionState module — may
    # not be compiled yet in parallel builds, but the project compiles as a
    # whole once it lands).
    version_upgraded = version_state_upgraded?()
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
        selected_entry: nil,
        version_upgraded: version_upgraded,
        current_version: current_version
      )

    # Record the current version once the user has seen this welcome page, so
    # the upgrade note is only shown once per upgrade.
    if connected?(socket) do
      record_current_version()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_welcome_model", params, socket) do
    model_string = params["model_string"]

    entry =
      Enum.find(socket.assigns.flat_models, fn e ->
        e.model_string == model_string
      end)

    {:noreply, assign(socket, :selected_entry, entry)}
  end

  @impl true
  def handle_event("save_quick_setup", params, socket) do
    model_string = params["model_string"]
    base_url = params["base_url"]
    provider_id_str = params["provider_id"]
    variant_id_str = params["variant_id"]

    provider = Map.get(ConfigIO.provider_by_id_str(), provider_id_str)

    result =
      cond do
        is_nil(provider) ->
          {:error, gettext("Unknown provider.")}

        String.trim(model_string || "") == "" ->
          {:error, gettext("Model name cannot be empty.")}

        true ->
          # The model_string from buttons is in "provider:model" format.
          # resolve_model_spec expects just the model id portion.
          model_name =
            if String.contains?(model_string, ":") do
              [_provider_prefix, name] = :binary.split(model_string, ":")
              name
            else
              model_string
            end

          # Validate base_url requirement
          requires_base_url = EvoGit.Config.LLMCatalog.requires_base_url?(provider.id)

          if requires_base_url and String.trim(base_url || "") == "" do
            {:error, gettext("Base URL cannot be empty.")}
          else
            # Build opts: base_url (if present) + variant (if selected).
            # We pass the BASE provider_atom + :variant opt to resolve_model_spec
            # so it resolves variants correctly (e.g. :alibaba + :cn → :alibaba_cn).
            provider_atom = hd(provider.provider_atoms)

            opts =
              if String.trim(base_url || "") == "",
                do: [],
                else: [base_url: String.trim(base_url)]

            opts =
              if variant_id_str != nil and variant_id_str != "" do
                variant_atom = Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id_str)
                Keyword.put(opts, :variant, variant_atom)
              else
                opts
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

        persist_file_config(file_config, socket, gettext("Model selected and saved."))
    end
  end

  @impl true
  def handle_event("save_api_key", %{"credential_key" => credential_key, "api_key" => api_key}, socket) do
    if String.trim(api_key) == "" do
      {:noreply, put_flash(socket, :error, gettext("API key cannot be empty."))}
    else
      case EvoGit.Config.save_credentials(%{credential_key => String.trim(api_key)}) do
        :ok ->
          {:noreply,
           socket
           |> assign(:credentials, EvoGit.Config.credentials())
           |> put_flash(:info, gettext("API key saved successfully."))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to save API key: %{reason}", reason: inspect(reason))
           )}
      end
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

  # ───────────────────────────────────────────────────────────────────────────
  # Private: model flattening
  # ───────────────────────────────────────────────────────────────────────────

  # Flattens the LLMCatalog provider list into a single flat list of model
  # entries, each carrying enough data to render a button and drive the
  # `save_quick_setup` params. Providers with variants are expanded so each
  # variant is a separate entry (each variant has its own credential_key).
  # Custom-model-only providers (OpenRouter, OpenAI-Compatible) have empty
  # model lists and are omitted from the flat grid — the focus is preset
  # models.
  defp flatten_models(providers) do
    providers
    |> Enum.reject(&(&1[:custom_model] == true))
    |> Enum.flat_map(&flatten_provider/1)
  end

  # Groups the flat model list by provider_display_name while preserving the
  # provider order in which they first appear (catalog order). Returns a list
  # of `%{provider_display_name: binary(), models: [entry, ...]}` maps. The
  # flat list is kept as the canonical data source for model lookups.
  defp group_models_by_provider(flat_models) do
    grouped = Enum.group_by(flat_models, & &1.provider_display_name)

    flat_models
    |> Enum.map(& &1.provider_display_name)
    |> Enum.uniq()
    |> Enum.map(fn name -> %{provider_display_name: name, models: grouped[name]} end)
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

  # ───────────────────────────────────────────────────────────────────────────
  # Private: version-state
  # ───────────────────────────────────────────────────────────────────────────

  # Wraps the VersionState call so the welcome page degrades gracefully if the
  # sibling module is not yet compiled (parallel build). Returns false (no
  # upgrade note) when unavailable.
  defp version_state_upgraded? do
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.upgraded?()
    else
      false
    end
  end

  defp record_current_version do
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.record_current_version()
    end
  end

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
