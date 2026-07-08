defmodule EvoDashWeb.SettingsLive do
  @moduledoc """
  Settings page with two tabs: runtime scheduler/sandbox controls and a
  GUI editor for the user configuration file (config.toml).
  """
  use EvoDashWeb, :live_view
  alias EvoGit.Config.Schema
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ModelProfileHelpers

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status} current_node_id={@current_node_id} current_node_name={@current_node_name}>
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
      <%= if @config_status && not @config_status.ok? do %>
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
                errors={ConfigIO.all_errors(@per_category_errors)}
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
              credentials={@credentials}
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
    file_config = ConfigIO.load_file_config()
    schemas_by_category = Schema.schemas_by_category()

    socket =
      assign(socket,
        schemas_by_category: schemas_by_category,
        active_category: :llm,
        search_text: "",
        per_category_errors: %{},
        scheduler_config: ConfigIO.load_scheduler_config(),
        config_status: config_status,
        file_config: file_config,
        config_path: config_path,
        config_file_exists: config_file_exists,
        credentials: EvoGit.Config.credentials(),
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
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/settings")

    # Map the raw query param to a known category atom via a whitelist lookup
    # built from the existing schemas_by_category map (atom keys). Stringify
    # the keys so we compare string-to-string — no String.to_existing_atom on
    # untrusted input, fully crash-safe for unknown values.
    category_str_to_atom = ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category)

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
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:scheduler_config_updated}, socket) do
    {:noreply, assign(socket, :scheduler_config, ConfigIO.load_scheduler_config())}
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
      Map.get(ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category), cat_str) ||
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
          Map.get(ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category), cat_str)

        _ ->
          nil
      end

    category = category || socket.assigns.active_category

    schemas = Map.get(socket.assigns.schemas_by_category, category, [])

    # Build config from params and merge into full file_config
    config =
      ConfigIO.build_config_from_category_params(params, category, schemas, socket.assigns.file_config)

    case Schema.validate(config) do
      {:ok, _validated} ->
        case EvoGit.Config.save_user_config(config) do
          :ok ->
            file_config = ConfigIO.load_file_config()
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
                ConfigIO.update_runtime_from_file_config(file_config, socket)
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
      ConfigIO.build_config_from_category_params(
        params,
        nil,
        all_matching_schemas,
        socket.assigns.file_config
      )

    case Schema.validate(config) do
      {:ok, _validated} ->
        case EvoGit.Config.save_user_config(config) do
          :ok ->
            file_config = ConfigIO.load_file_config()
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
                ConfigIO.update_runtime_from_file_config(file_config, socket)
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
    key_path = ConfigIO.parse_key_path(path_str, socket.assigns.schemas_by_category)
    schema = ConfigIO.find_schema(key_path, socket.assigns.schemas_by_category)

    # An unknown or stale key_path / schema means untrusted client input did not
    # resolve to a known setting — surface a friendly flash instead of crashing
    # on put_in with a nil path or a nil schema.default.
    if is_nil(key_path) or is_nil(schema) do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      config = put_in(socket.assigns.file_config, key_path, schema.default)

      case EvoGit.Config.save_user_config(config) do
        :ok ->
          file_config = ConfigIO.load_file_config()
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
    provider = Map.get(ConfigIO.provider_by_id_str(), id_str)

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
        provider_atom -> Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id_str)
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
      |> ModelProfileHelpers.add_model_profile(model_string)
      |> ModelProfileHelpers.mirror_default_model()

    persist_file_config(file_config, socket, gettext("Model selected and saved."))
  end

  @impl true
  def handle_event("save_custom_model", params, socket) do
    model_name = params["model_name"]
    base_url = params["base_url"]
    provider_id_str = params["provider_id"]

    # Build a whitelist map keyed by the string form of each provider's atom id,
    # so untrusted POST data is matched without String.to_existing_atom.
    provider = Map.get(ConfigIO.provider_by_id_str(), provider_id_str)

    result =
      cond do
        is_nil(provider) ->
          {:error, gettext("Unknown provider.")}

        String.trim(model_name || "") == "" ->
          {:error, gettext("Model name cannot be empty.")}

        true ->
          # Resolve the canonical provider atom from the catalog entry's
          # provider_atoms list directly (e.g. :openai_compatible entry → :openai
          # atom, :openrouter → :openrouter). We use hd/1 on provider_atoms
          # because resolve_provider_atom/1 looks up by membership, NOT by
          # catalog id — it would leave :openai_compatible unchanged (the bug).
          provider_atom = hd(provider.provider_atoms)

          # Validate base_url requirement using the catalog function (NOT the
          # dead provider[:requires_base_url] struct field).
          requires_base_url = EvoGit.Config.LLMCatalog.requires_base_url?(provider.id)

          if requires_base_url and String.trim(base_url || "") == "" do
            {:error, gettext("Base URL cannot be empty.")}
          else
            # Build the map spec via resolve_model_spec/3 — it omits nil/empty
            # base_url and resolves model shortcuts/variants. Produces a MAP for
            # ALL providers (including OpenRouter), not a legacy string.
            opts =
              if String.trim(base_url || "") == "",
                do: [],
                else: [base_url: String.trim(base_url)]

            {:ok, EvoGit.Config.LLMCatalog.resolve_model_spec(provider_atom, model_name, opts)}
          end
      end

    case result do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:ok, model_value} ->
        # Add a new model profile using the custom model, and mirror it to the
        # flat [:llm, :model] for backward compatibility.
        file_config =
          socket.assigns.file_config
          |> ModelProfileHelpers.add_model_profile(model_value)
          |> ModelProfileHelpers.mirror_default_model()

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
      |> ModelProfileHelpers.add_model_profile(nil)

    models = get_in(file_config, [:llm, :models]) || []
    new_id = models |> List.last() |> ModelProfileHelpers.profile_id()

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
      ModelProfileHelpers.id_collision?(models, old_id, new_id) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A profile with id \"%{id}\" already exists.", id: new_id)
         )}

      true ->
        case ModelProfileHelpers.parse_model_profile_params(params, new_id) do
          {:ok, updated_profile} ->
            file_config =
              socket.assigns.file_config
              |> ModelProfileHelpers.update_model_profile(old_id, updated_profile)
              |> ModelProfileHelpers.mirror_default_model()

            socket = socket |> assign(:editing_profile_id, nil)

            persist_file_config(file_config, socket, gettext("Model profile saved."))

          {:error, "model_id_empty"} ->
            {:noreply, put_flash(socket, :error, gettext("Model ID cannot be empty."))}
        end
    end
  end

  @impl true
  def handle_event("delete_model_profile", %{"profile_id" => id}, socket) do
    models = get_in(socket.assigns.file_config, [:llm, :models]) || []
    new_models = Enum.reject(models, fn p -> ModelProfileHelpers.profile_id(p) == id end)

    file_config =
      socket.assigns.file_config
      |> ModelProfileHelpers.put_in_model_profiles(new_models)
      |> ModelProfileHelpers.mirror_default_model()

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
  def handle_event("test_llm", _params, socket) do
    parent = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoGit.SystemCheck.llm_test()
      send(parent, {:llm_test_result, result})
    end)

    {:noreply, assign(socket, :llm_test_status, :testing)}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  defp persist_file_config(file_config, socket, success_msg) do
    # Always update in-memory state so the UI reflects the change immediately
    socket = assign(socket, :file_config, file_config)

    case EvoGit.Config.save_user_config(file_config) do
      :ok ->
        file_config = ConfigIO.load_file_config()
        config_status = config_status()
        config_file_exists = File.exists?(socket.assigns.config_path)

        socket =
          socket
          |> assign(:file_config, file_config)
          |> assign(:config_status, config_status)
          |> assign(:config_file_exists, config_file_exists)
          |> assign(:per_category_errors, %{})
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
