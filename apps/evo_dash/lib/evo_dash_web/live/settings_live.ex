defmodule EvoDashWeb.SettingsLive do
  @moduledoc """
  Settings page with two tabs: runtime scheduler/sandbox controls and a
  GUI editor for the user configuration file (config.toml).
  """
  use EvoDashWeb, :live_view
  alias EvoGit.Config.Schema
  alias EvoDash.SettingsUtils

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status}>
      <%!-- Header --%>
      <div class="mb-6 mt-2">
        <h1 class="text-xl font-bold tracking-tight text-base-content">{gettext("Settings")}</h1>
        <p class="text-sm text-base-content/80 mt-0.5">
          {gettext("Runtime configuration and file settings")}
        </p>
      </div>

      <%!-- Config file path display --%>
      <div class="mb-4 rounded-lg border border-base-200 bg-base-100 p-3 flex items-center gap-3">
        <.icon name="hero-document-text" class="size-4 text-base-content/70 shrink-0" />
        <span class="text-xs font-medium text-base-content/70 shrink-0">{gettext("Configuration file")}</span>
        <code class="font-mono text-sm text-base-content/80 flex-1 truncate">{@config_path}</code>
        <button
          id="settings-config-path-copy"
          phx-hook="ClipboardCopy"
          data-content={@config_path}
          class="btn btn-ghost btn-sm btn-square"
          title={gettext("Copy path")}
        >
          <.icon name="hero-clipboard-document" class="size-4" />
        </button>
      </div>
      <%= if not @config_file_exists do %>
        <p class="mb-4 text-xs text-base-content/70">{gettext("File does not exist yet")}</p>
      <% end %>

      <%!-- Config Status Warning --%>
      <%= if not @config_status.ok? do %>
        <div class="mb-4 rounded-lg border border-warning/30 bg-warning/5 p-3 flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
          <div>
            <h3 class="font-bold text-sm text-warning mb-2">{gettext("Missing Configuration")}</h3>
            <ul class="space-y-1.5 mb-3">
              <%= for warning <- @config_status.warnings do %>
                <li class="text-sm font-medium text-warning/80 flex items-start gap-2">
                  <.icon name="hero-chevron-right" class="size-4 mt-0.5 shrink-0 opacity-70" />
                  <span>{warning}</span>
                </li>
              <% end %>
            </ul>
            <p class="text-sm font-semibold text-base-content/80">
              {gettext("Configure your LLM model in the LLM category to resolve these issues.")}
            </p>
          </div>
        </div>
      <% end %>

      <%!-- No LLM Model Warning --%>
      <%= if is_nil(get_in(@file_config, [:llm, :model])) do %>
        <div class="mb-4 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
          <div>
            <h3 class="font-bold text-sm text-error mb-2">{gettext("No LLM Model Configured")}</h3>
            <p class="text-sm font-medium text-error/80 mb-3 leading-relaxed max-w-3xl">
              {gettext(
                "Agents cannot run until you set a model. Go to the LLM category and fill in the Model field."
              )}
            </p>
            <div class="flex items-center gap-3 flex-wrap">
              <span class="text-xs font-bold uppercase tracking-wider text-base-content/70">{gettext(
                "Example model names:"
              )}</span>
              <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">anthropic:claude-opus-4-7</span>
              <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">openai:gpt-5.5</span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Settings card: two-column sidebar + content layout.
           Note: `gap-8` generates correctly in Tailwind v4 via
           `calc(var(--spacing) * N)` (with `--spacing: 0.25rem` at `:root`).
           The cards ARE direct children (HEEx comments emit no DOM nodes).
           The earlier spacing fixes (commits 08c3ec35 and 6a48e9e2) appeared to
           fail only because the gitignored CSS build (`priv/static/assets/css/`)
           was never regenerated after the HEEx edits, so the app served a stale
           bundle lacking the new utility classes. After editing Tailwind classes
           here, rebuild assets with `mix tailwind evo_dash` (dev) or
           `mix assets.deploy` (prod) so the new utilities are emitted. --%>
      <div class="flex flex-col gap-8">
        <%!-- Two-column sidebar + content layout --%>
        <div class="flex flex-col md:flex-row bg-base-100 rounded-lg border border-base-200 shadow-sm overflow-hidden">
          <%!-- Sidebar --%>
          <EvoDashWeb.SettingsComponents.settings_sidebar
            categories={@schemas_by_category}
            active_category={@active_category}
            search_text={@search_text}
          />

          <%!-- Content area --%>
          <%= if @search_text != "" do %>
            <.form
              for={%{}}
              phx-submit="save_search"
              class="flex-1 flex flex-col min-w-0 relative"
              id="settings-form-search"
            >
              <EvoDashWeb.SettingsComponents.search_results
                categories={@schemas_by_category}
                search_text={@search_text}
                file_config={@file_config}
                errors={all_errors(@per_category_errors)}
              />
            </.form>
          <% else %>
            <%!-- category_section renders its own <form phx-submit="save_category">
                 internally. The LLM category's Quick Setup panel and Model
                 Profiles editor contain their own nested forms (save_api_key,
                 save_custom_model, save_model_profile), so they must NOT be
                 wrapped in the outer save_category form (nested <form> elements
                 are invalid HTML — browsers ignore the inner <form> tag, causing
                 the profile editor's Save button to submit save_category instead
                 of save_model_profile, which deletes the models list). --%>
            <EvoDashWeb.SettingsComponents.category_section
              category={@active_category}
              schemas={Map.get(@schemas_by_category, @active_category, [])}
              file_config={@file_config}
              errors={Map.get(@per_category_errors, @active_category, [])}
              sandbox_backend={@scheduler_config[:sandbox_backend]}
              sandbox_mode={get_in(@file_config, [:sandbox, :mode])}
              llm_providers={@llm_providers}
              selected_provider_id={@selected_provider_id}
              selected_provider_models={@selected_provider_models}
              selected_variant_id={@selected_variant_id}
              llm_test_status={@llm_test_status}
              model_profiles={@file_config[:llm][:models] || []}
              editing_profile_id={@editing_profile_id}
            />
          <% end %>
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
    end

    config_status = config_status()
    config_path = EvoGit.Config.config_path()
    config_file_exists = File.exists?(config_path)
    file_config = load_file_config()
    schemas_by_category = Schema.schemas_by_category()

    socket =
      assign(socket,
        schemas_by_category: schemas_by_category,
        active_category: :llm,
        search_text: "",
        per_category_errors: %{},
        scheduler_config: load_scheduler_config(),
        config_status: config_status,
        file_config: file_config,
        config_path: config_path,
        config_file_exists: config_file_exists,
        llm_providers: EvoGit.Config.LLMCatalog.providers(),
        selected_provider_id: nil,
        selected_provider_models: [],
        selected_variant_id: nil,
        llm_test_status: :idle,
        editing_profile_id: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Map the raw query param to a known category atom via a whitelist lookup
    # built from the existing schemas_by_category map (atom keys). Stringify
    # the keys so we compare string-to-string — no String.to_existing_atom on
    # untrusted input, fully crash-safe for unknown values.
    category_str_to_atom = category_str_to_atom(socket.assigns.schemas_by_category)

    category =
      case params["category"] do
        cat when is_binary(cat) -> Map.get(category_str_to_atom, cat)
        _ -> nil
      end

    # Fall back to active_category for unknown/missing input
    category = category || socket.assigns.active_category

    socket =
      if category != socket.assigns.active_category do
        assign(socket, :active_category, category)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:scheduler_config_updated}, socket) do
    {:noreply, assign(socket, :scheduler_config, load_scheduler_config())}
  end

  @impl true
  def handle_info({:llm_test_result, result}, socket) do
    status =
      case result do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, assign(socket, :llm_test_status, status)}
  end

  @impl true
  def handle_event("select_category", %{"category" => cat_str}, socket) do
    # Whitelist lookup: validate the client-supplied category string against the
    # known schema category atoms. Unknown value → nil → keep current category.
    cat =
      Map.get(category_str_to_atom(socket.assigns.schemas_by_category), cat_str) ||
        socket.assigns.active_category

    {:noreply,
     assign(socket,
       active_category: cat,
       search_text: "",
       per_category_errors: %{}
     )}
  end

  @impl true
  def handle_event("search", %{"value" => text}, socket) do
    {:noreply, assign(socket, :search_text, text)}
  end

  # Prevents page reload when pressing Enter in the search form
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_category", params, socket) do
    # Whitelist lookup: validate the category string against known schema atoms.
    # Unknown value → nil → fall back to the current active_category.
    category =
      case params["category"] do
        cat_str when is_binary(cat_str) ->
          Map.get(category_str_to_atom(socket.assigns.schemas_by_category), cat_str)

        _ ->
          nil
      end

    category = category || socket.assigns.active_category

    schemas = Map.get(socket.assigns.schemas_by_category, category, [])

    # Build config from params and merge into full file_config
    config =
      build_config_from_category_params(params, category, schemas, socket.assigns.file_config)

    case Schema.validate(config) do
      {:ok, _validated} ->
        case EvoGit.Config.save_user_config(config) do
          :ok ->
            file_config = load_file_config()
            config_status = config_status()
            config_file_exists = File.exists?(socket.assigns.config_path)

            socket =
              socket
              |> assign(:file_config, file_config)
              |> assign(:config_status, config_status)
              |> assign(:config_file_exists, config_file_exists)
              |> assign(:per_category_errors, %{})
              |> put_flash(:info, gettext("Configuration saved successfully."))

            # Update runtime scheduler when LLM or scheduler categories change
            socket =
              if category in [:scheduler, :llm] do
                update_runtime_from_file_config(file_config, socket)
              else
                socket
              end

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
             )}
        end

      {:error, errors} ->
        category_errors = Enum.filter(errors, fn e -> List.first(e.key_path) == category end)

        {:noreply,
         socket
         |> assign(
           :per_category_errors,
           Map.put(socket.assigns.per_category_errors, category, category_errors)
         )
         |> put_flash(:error, gettext("Validation failed. Please fix the errors below."))}
    end
  end

  @impl true
  def handle_event("save_search", params, socket) do
    search_text = socket.assigns.search_text

    all_matching_schemas =
      socket.assigns.schemas_by_category
      |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
      |> Enum.filter(&EvoDashWeb.SettingsComponents.schema_matches?(&1, search_text))

    config =
      build_config_from_category_params(
        params,
        nil,
        all_matching_schemas,
        socket.assigns.file_config
      )

    case Schema.validate(config) do
      {:ok, _validated} ->
        case EvoGit.Config.save_user_config(config) do
          :ok ->
            file_config = load_file_config()
            config_status = config_status()
            config_file_exists = File.exists?(socket.assigns.config_path)

            socket =
              socket
              |> assign(:file_config, file_config)
              |> assign(:config_status, config_status)
              |> assign(:config_file_exists, config_file_exists)
              |> assign(:per_category_errors, %{})
              |> put_flash(:info, gettext("Configuration saved successfully."))

            # Update runtime scheduler when LLM or scheduler keys change
            socket =
              if Enum.any?(
                   all_matching_schemas,
                   &(List.first(&1.key_path) in [:scheduler, :llm])
                 ) do
                update_runtime_from_file_config(file_config, socket)
              else
                socket
              end

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
             )}
        end

      {:error, errors} ->
        # Group errors by category for display
        per_category_errors =
          Enum.reduce(errors, %{}, fn e, acc ->
            cat = List.first(e.key_path)
            Map.update(acc, cat, [e], fn existing -> existing ++ [e] end)
          end)

        {:noreply,
         socket
         |> assign(:per_category_errors, per_category_errors)
         |> put_flash(:error, gettext("Validation failed. Please fix the errors below."))}
    end
  end

  @impl true
  def handle_event("reset_key", %{"key_path" => path_str}, socket) do
    key_path = parse_key_path(path_str, socket.assigns.schemas_by_category)
    schema = find_schema(key_path, socket.assigns.schemas_by_category)

    # An unknown or stale key_path / schema means untrusted client input did not
    # resolve to a known setting — surface a friendly flash instead of crashing
    # on put_in with a nil path or a nil schema.default.
    if is_nil(key_path) or is_nil(schema) do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      config = put_in(socket.assigns.file_config, key_path, schema.default)

      case EvoGit.Config.save_user_config(config) do
        :ok ->
          file_config = load_file_config()
          config_status = config_status()
          config_file_exists = File.exists?(socket.assigns.config_path)

          {:noreply,
           socket
           |> assign(:file_config, file_config)
           |> assign(:config_status, config_status)
           |> assign(:config_file_exists, config_file_exists)
           |> assign(:per_category_errors, %{})
           |> put_flash(:info, gettext("Reset %{key} to default.", key: path_str))}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Failed to reset key: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  @impl true
  def handle_event("select_llm_provider", %{"provider_id" => id_str}, socket) do
    # Whitelist lookup: validate the client-supplied provider id against the
    # known LLMCatalog providers. Unknown value → nil → clear selection and
    # surface a friendly flash error instead of crashing.
    provider = Map.get(provider_by_id_str(), id_str)

    if provider do
      provider_id = provider.id
      models = provider.models
      _variants = provider[:variants]

      socket =
        socket
        |> assign(:selected_provider_id, provider_id)
        |> assign(:selected_provider_models, models)
        |> assign(:selected_variant_id, nil)

      {:noreply, socket}
    else
      # Unknown provider id — keep existing state, show an error flash.
      {:noreply,
       socket
       |> assign(:selected_provider_id, nil)
       |> assign(:selected_provider_models, [])
       |> assign(:selected_variant_id, nil)
       |> put_flash(:error, gettext("Unknown provider."))}
    end
  end

  @impl true
  def handle_event("select_llm_variant", %{"variant_id" => variant_id_str}, socket) do
    # Whitelist lookup: validate the client-supplied variant id against the
    # variants of the currently selected provider. Unknown value (or no
    # provider selected) → nil → no selection change.
    variant_id =
      case socket.assigns.selected_provider_id do
        nil -> nil
        provider_atom -> Map.get(variant_id_by_str(provider_atom), variant_id_str)
      end

    {:noreply, assign(socket, :selected_variant_id, variant_id)}
  end

  @impl true
  def handle_event("select_llm_model_shortcut", %{"model_string" => model_string}, socket) do
    # Add a new model profile using the selected model string, and mirror it to
    # the flat [:llm, :model] for backward compatibility (older code paths and
    # the config-status check still read the flat field).
    file_config =
      socket.assigns.file_config
      |> add_model_profile(model_string)
      |> mirror_default_model()

    persist_file_config(file_config, socket, gettext("Model selected and saved."))
  end

  @impl true
  def handle_event("save_custom_model", params, socket) do
    model_name = params["model_name"]
    base_url = params["base_url"]
    provider_id_str = params["provider_id"]

    # Build a whitelist map keyed by the string form of each provider's atom id,
    # so untrusted POST data is matched without String.to_existing_atom.
    provider = Map.get(provider_by_id_str(), provider_id_str)

    result =
      cond do
        is_nil(provider) ->
          {:error, gettext("Unknown provider.")}

        String.trim(model_name || "") == "" ->
          {:error, gettext("Model name cannot be empty.")}

        provider[:requires_base_url] == true ->
          if String.trim(base_url || "") == "" do
            {:error, gettext("Base URL cannot be empty.")}
          else
            {:ok,
             %{
               provider: :openai,
               id: String.trim(model_name),
               base_url: String.trim(base_url)
             }}
          end

        true ->
          {:ok, "openrouter:#{String.trim(model_name)}"}
      end

    case result do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:ok, model_value} ->
        # Add a new model profile using the custom model, and mirror it to the
        # flat [:llm, :model] for backward compatibility.
        file_config =
          socket.assigns.file_config
          |> add_model_profile(model_value)
          |> mirror_default_model()

        persist_file_config(file_config, socket, gettext("Custom model saved."))
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Model Profiles editor events
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("add_model_profile", _params, socket) do
    # Add the profile to the in-memory file_config (not persisted yet — the
    # profile has no model until the user fills in the edit form, and persisting
    # now would fail schema validation). Enter edit mode immediately so the
    # user can complete the profile, then save.
    file_config =
      socket.assigns.file_config
      |> add_model_profile(nil)

    models = get_in(file_config, [:llm, :models]) || []
    new_id = models |> List.last() |> profile_id()

    socket =
      socket
      |> assign(:file_config, file_config)
      |> assign(:editing_profile_id, new_id)
      |> put_flash(:info, gettext("New profile added — fill in the details and save."))

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_model_profile", %{"profile_id" => id}, socket) do
    {:noreply,
     assign(socket,
       editing_profile_id: if(socket.assigns.editing_profile_id == id, do: nil, else: id)
     )}
  end

  @impl true
  def handle_event("cancel_edit_model_profile", _params, socket) do
    {:noreply, assign(socket, :editing_profile_id, nil)}
  end

  @impl true
  def handle_event("save_model_profile", params, socket) do
    old_id = params["profile_id"]
    new_id = String.trim(params["profile_id_new"] || "")

    models = get_in(socket.assigns.file_config, [:llm, :models]) || []

    cond do
      new_id == "" ->
        {:noreply, put_flash(socket, :error, gettext("Profile id cannot be empty."))}

      # Duplicate id check: another profile (with a different old id) already
      # uses the requested id.
      id_collision?(models, old_id, new_id) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A profile with id \"%{id}\" already exists.", id: new_id)
         )}

      true ->
        updated_profile = parse_model_profile_params(params, new_id)

        file_config =
          socket.assigns.file_config
          |> update_model_profile(old_id, updated_profile)
          |> mirror_default_model()

        socket = socket |> assign(:editing_profile_id, nil)

        persist_file_config(file_config, socket, gettext("Model profile saved."))
    end
  end

  @impl true
  def handle_event("delete_model_profile", %{"profile_id" => id}, socket) do
    models = get_in(socket.assigns.file_config, [:llm, :models]) || []
    new_models = Enum.reject(models, fn p -> profile_id(p) == id end)

    file_config =
      socket.assigns.file_config
      |> put_in_model_profiles(new_models)
      |> mirror_default_model()

    socket = socket |> assign(:editing_profile_id, nil)

    persist_file_config(file_config, socket, gettext("Model profile deleted."))
  end

  @impl true
  def handle_event("save_api_key", %{"env_var" => env_var, "api_key" => api_key}, socket) do
    if String.trim(api_key) == "" do
      {:noreply, put_flash(socket, :error, gettext("API key cannot be empty."))}
    else
      case EvoGit.Config.save_credentials(%{env_var => String.trim(api_key)}) do
        :ok ->
          config_status = config_status()

          {:noreply,
           socket
           |> assign(:config_status, config_status)
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
  def handle_event("test_llm", _params, socket) do
    parent = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoGit.SystemCheck.llm_test()
      send(parent, {:llm_test_result, result})
    end)

    {:noreply, assign(socket, :llm_test_status, :testing)}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Model profiles list manipulation
  #
  # These operate on file_config maps before they are persisted. The models list
  # lives at file_config[:llm][:models]. We always normalize to a list of maps
  # with atom keys.
  # ───────────────────────────────────────────────────────────────────────────

  defp add_model_profile(file_config, model_value) do
    models = get_in(file_config, [:llm, :models]) || []
    id = generate_profile_id(models)

    profile =
      %{id: id, concurrency: 3}
      |> maybe_put_profile_model(model_value)

    put_in_model_profiles(file_config, models ++ [profile])
  end

  # Generates a unique profile id like "profile-2", "profile-3", ... based on
  # the count of existing profiles whose ids match the "profile-N" pattern.
  defp generate_profile_id(models) do
    existing_ids = Enum.map(models, &profile_id/1) |> MapSet.new()

    Stream.iterate(length(models) + 1, &(&1 + 1))
    |> Stream.map(&"profile-#{&1}")
    |> Enum.find(fn id -> not MapSet.member?(existing_ids, id) end)
  end

  # Only include :model key when a non-nil value is given (e.g. from a shortcut).
  # For "add_model_profile" with nil, we omit it so the user can fill it in.
  defp maybe_put_profile_model(profile, nil), do: profile
  defp maybe_put_profile_model(profile, ""), do: profile
  defp maybe_put_profile_model(profile, model_value), do: Map.put(profile, :model, model_value)

  defp update_model_profile(file_config, old_id, updated_profile) do
    models = get_in(file_config, [:llm, :models]) || []

    new_models =
      Enum.map(models, fn profile ->
        if profile_id(profile) == old_id, do: updated_profile, else: profile
      end)

    put_in_model_profiles(file_config, new_models)
  end

  defp put_in_model_profiles(file_config, models) do
    file_config
    |> ensure_llm_key()
    |> put_in([:llm, :models], models)
  end

  defp ensure_llm_key(file_config) do
    if is_map(get_in(file_config, [:llm])) do
      file_config
    else
      put_in(file_config, [:llm], %{})
    end
  end

  # Mirrors the first profile's model into the flat [:llm, :model] for backward
  # compatibility (config-status check and older code paths still read it).
  defp mirror_default_model(file_config) do
    models = get_in(file_config, [:llm, :models]) || []

    case models do
      [%{model: model} | _] -> put_in(file_config, [:llm, :model], model)
      _ -> file_config
    end
  end

  # Checks whether the new_id is already used by a profile OTHER than the one
  # being edited (old_id). Returns true on collision.
  defp id_collision?(models, old_id, new_id) do
    Enum.any?(models, fn profile ->
      pid = profile_id(profile)
      pid != old_id and pid == new_id
    end)
  end

  # Parses the form params for a single profile into a normalized map with atom
  # keys and correctly-typed values.
  defp parse_model_profile_params(params, id) do
    model = String.trim(params["model"] || "")

    profile =
      %{id: id}
      |> maybe_put_non_empty(:model, model)
      |> maybe_put_int(:concurrency, params["concurrency"], 3)
      |> maybe_put_float(:temperature, params["temperature"])
      |> maybe_put_string(:reasoning_effort, params["reasoning_effort"])
      |> maybe_put_int(:max_tokens, params["max_tokens"])
      |> maybe_put_float(:top_p, params["top_p"])
      |> maybe_put_int(:top_k, params["top_k"])
      |> maybe_put_float(:frequency_penalty, params["frequency_penalty"])
      |> maybe_put_float(:presence_penalty, params["presence_penalty"])

    profile
  end

  defp maybe_put_non_empty(map, _key, ""), do: map
  defp maybe_put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_int(map, key, raw, default) do
    case SettingsUtils.parse_int(raw) do
      nil -> Map.put(map, key, default)
      int -> Map.put(map, key, int)
    end
  end

  defp maybe_put_int(map, key, raw) do
    case SettingsUtils.parse_int(raw) do
      nil -> map
      int -> Map.put(map, key, int)
    end
  end

  defp maybe_put_float(map, key, raw) do
    case SettingsUtils.parse_float(raw) do
      nil -> map
      float -> Map.put(map, key, float)
    end
  end

  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  # Safely reads the id from a profile map whether the key is an atom or string
  # (TOML-parsed profiles may arrive with string keys before normalization).
  defp profile_id(profile) when is_map(profile) do
    case Map.get(profile, :id) || Map.get(profile, "id") do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp profile_id(_), do: nil

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  defp persist_file_config(file_config, socket, success_msg) do
    # Always update in-memory state so the UI reflects the change immediately
    socket = assign(socket, :file_config, file_config)

    case EvoGit.Config.save_user_config(file_config) do
      :ok ->
        file_config = load_file_config()
        config_status = config_status()
        config_file_exists = File.exists?(socket.assigns.config_path)

        socket =
          socket
          |> assign(:file_config, file_config)
          |> assign(:config_status, config_status)
          |> assign(:config_file_exists, config_file_exists)
          |> assign(:per_category_errors, %{})
          |> put_flash(:info, success_msg)

        {:noreply, update_runtime_from_file_config(file_config, socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config loading
  # ───────────────────────────────────────────────────────────────────────────

  defp load_file_config do
    EvoGit.Config.resolve()
  end

  defp load_scheduler_config do
    EvoGit.AgentScheduler.get_config()
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config building from params
  # ───────────────────────────────────────────────────────────────────────────

  defp build_config_from_category_params(params, category, schemas, file_config) do
    # Build a nested map from flat params for this category
    {category_config, emptied_paths} = params_to_category_config(params, category, schemas)

    # Deep merge into file_config
    merged = SettingsUtils.deep_merge(file_config, category_config)

    # Delete keys that were explicitly emptied
    Enum.reduce(emptied_paths, merged, fn key_path, acc ->
      SettingsUtils.deep_delete(acc, key_path)
    end)
  end

  defp params_to_category_config(params, _category, schemas) do
    # Skip :model_profiles type schemas entirely. These schemas (e.g. [:llm, :models])
    # are managed by dedicated event handlers (save_model_profile, delete_model_profile,
    # add_model_profile) and have no corresponding flat form field. If processed here,
    # they'd parse as :explicitly_empty (no matching form param) and get queued for
    # deletion via deep_delete, wiping the entire models list on every save_category.
    schemas = Enum.reject(schemas, &(&1.type == :model_profiles))

    Enum.reduce(schemas, {%{}, []}, fn schema, {config_acc, emptied_acc} ->
      value = Map.get(params, Enum.join(schema.key_path, "."))

      parsed =
        cond do
          schema.type == :boolean ->
            value == "true"

          is_nil(value) or value == "" ->
            :explicitly_empty

          schema.type in [:pos_integer, :non_neg_integer, :integer] ->
            SettingsUtils.parse_int(value)

          schema.type == :float ->
            SettingsUtils.parse_float(value)

          schema.type in [:string, :model_spec] ->
            value

          schema.type == :atom ->
            SettingsUtils.parse_atom(value, schema)
        end

      cond do
        parsed == :explicitly_empty ->
          {config_acc, [schema.key_path | emptied_acc]}

        is_nil(parsed) ->
          {config_acc, emptied_acc}

        true ->
          {SettingsUtils.deep_put(config_acc, schema.key_path, parsed), emptied_acc}
      end
    end)
  end

  defp update_runtime_from_file_config(file_config, socket) do
    updates =
      []
      |> SettingsUtils.maybe_add_kw(:max_concurrency, get_in(file_config, [:scheduler, :max_concurrency]))
      |> SettingsUtils.maybe_add_kw(
        :max_tool_concurrency,
        get_in(file_config, [:scheduler, :max_tool_concurrency])
      )
      |> SettingsUtils.maybe_add_kw(:agent_max_retries, get_in(file_config, [:scheduler, :agent_max_retries]))
      |> SettingsUtils.maybe_add_kw(:max_agent_depth, get_in(file_config, [:scheduler, :max_agent_depth]))
      |> SettingsUtils.maybe_add_kw(:max_retries, get_in(file_config, [:scheduler, :max_retries]))
      |> SettingsUtils.maybe_add_kw(:max_turns, get_in(file_config, [:scheduler, :max_turns]))
      |> SettingsUtils.maybe_add_kw(:max_turns_root, get_in(file_config, [:scheduler, :max_turns_root]))

    # Note: :tools config (e.g., web_search) is read from EvoGit.Config.resolve()
    # at execution time — no runtime push needed here.

    # LLM model profiles: the scheduler now accepts the full profiles list and
    # derives the model + generation params from the default profile internally.
    # We no longer push :llm_model / :llm_generation_params separately.
    updates =
      SettingsUtils.maybe_add_kw(updates, :model_profiles, Schema.model_profiles(file_config))

    if updates != [] do
      case EvoGit.AgentScheduler.update_config(updates) do
        :ok ->
          socket
          |> assign(:scheduler_config, load_scheduler_config())

        {:error, _msg} ->
          socket
      end
    else
      socket
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: parsing
  # ───────────────────────────────────────────────────────────────────────────

  defp parse_key_path(path_str, schemas_by_category) when is_binary(path_str) do
    # Build a whitelist of valid atom segments (string form -> atom) from every
    # known schema key_path, then validate each segment of the parsed path
    # against it. This avoids String.to_existing_atom/to_atom on untrusted
    # client input (atom-table exhaustion / ArgumentError crashes). Returns nil
    # when any segment is unknown so the caller can surface a friendly error
    # instead of crashing.
    valid_segment_str_to_atom =
      schemas_by_category
      |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
      |> Enum.flat_map(fn schema -> schema.key_path end)
      |> Enum.uniq()
      |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)

    segments = String.split(path_str, ".")

    if Enum.all?(segments, &Map.has_key?(valid_segment_str_to_atom, &1)) do
      Enum.map(segments, &Map.fetch!(valid_segment_str_to_atom, &1))
    else
      nil
    end
  end

  defp find_schema(nil, _schemas_by_category), do: nil

  defp find_schema(key_path, schemas_by_category) do
    schemas_by_category
    |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
    |> Enum.find(&(&1.key_path == key_path))
  end

  defp all_errors(per_category_errors) do
    Enum.flat_map(per_category_errors, fn {_cat, errors} -> errors end)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: untrusted-string → atom whitelists
  #
  # Each helper builds a map keyed by the *string* form of a known atom, so
  # client-supplied (untrusted) values can be validated via Map.get/2 without
  # ever calling String.to_existing_atom/1 or String.to_atom/1. Unknown values
  # resolve to nil so callers can surface a friendly default instead of crashing
  # with an ArgumentError (or risking atom-table exhaustion via to_atom/1).
  # ───────────────────────────────────────────────────────────────────────────

  defp category_str_to_atom(schemas_by_category) do
    Map.new(schemas_by_category, fn {cat_atom, _schemas} ->
      {Atom.to_string(cat_atom), cat_atom}
    end)
  end

  defp provider_by_id_str do
    Map.new(EvoGit.Config.LLMCatalog.providers(), fn p -> {Atom.to_string(p.id), p} end)
  end

  defp variant_id_by_str(provider_atom) when is_atom(provider_atom) do
    case EvoGit.Config.LLMCatalog.provider_variants(provider_atom) do
      nil -> %{}
      variants -> Map.new(variants, fn v -> {Atom.to_string(v.id), v.id} end)
    end
  end
end
