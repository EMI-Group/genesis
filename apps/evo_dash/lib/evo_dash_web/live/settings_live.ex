defmodule EvoDashWeb.SettingsLive do
  @moduledoc """
  Settings page with two tabs: runtime scheduler/sandbox controls and a
  GUI editor for the user configuration file (config.toml).
  """
  use EvoDashWeb, :live_view
  alias EvoGit.Config.Schema

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status}>
      <%!-- Header --%>
      <div class="mb-6 mt-2">
        <h1 class="text-xl font-bold tracking-tight text-base-content">{gettext("Settings")}</h1>
        <p class="text-sm text-base-content/60 mt-0.5">{gettext("Runtime configuration and file settings")}</p>
      </div>

      <%!-- Config file path display --%>
      <div class="mb-4 rounded-lg border border-base-200 bg-base-100 p-3 flex items-center gap-3">
        <.icon name="hero-document-text" class="size-4 text-base-content/40 shrink-0" />
        <span class="text-xs font-medium text-base-content/50 shrink-0">{gettext("Configuration file")}</span>
        <code class="font-mono text-sm text-base-content/80 flex-1 truncate">{@config_path}</code>
        <button id="settings-config-path-copy" phx-hook="ClipboardCopy" data-content={@config_path} class="btn btn-ghost btn-sm btn-square" title={gettext("Copy path")}>
          <.icon name="hero-clipboard-document" class="size-4" />
        </button>
      </div>
      <%= if not @config_file_exists do %>
        <p class="mb-4 text-xs text-base-content/50">{gettext("File does not exist yet")}</p>
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
            <p class="text-sm font-semibold text-base-content/60">
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
              {gettext("Agents cannot run until you set a model. Go to the LLM category and fill in the Model field.")}
            </p>
            <div class="flex items-center gap-3 flex-wrap">
              <span class="text-xs font-bold uppercase tracking-wider text-base-content/50">{gettext("Example model names:")}</span>
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
          <.form
            for={%{}}
            phx-submit="save_category"
            class="flex-1 flex flex-col min-w-0 relative"
            id={"settings-form-#{@active_category}"}
          >
            <input type="hidden" name="category" value={@active_category} />

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
            />
          </.form>
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

    config_status = safe_config_status()
    config_path = EvoGit.Config.config_path()
    config_file_exists = File.exists?(config_path)
    file_config = load_file_config()
    schemas_by_category = Schema.schemas_by_category()

    socket =
      socket
      |> assign(:schemas_by_category, schemas_by_category)
      |> assign(:active_category, :scheduler)
      |> assign(:search_text, "")
      |> assign(:per_category_errors, %{})
      |> assign(:scheduler_config, load_scheduler_config())
      |> assign(:config_status, config_status)
      |> assign(:file_config, file_config)
      |> assign(:config_path, config_path)
      |> assign(:config_file_exists, config_file_exists)
      |> assign(:llm_providers, EvoGit.Config.LLMCatalog.providers())
      |> assign(:selected_provider_id, nil)
      |> assign(:selected_provider_models, [])
      |> assign(:selected_variant_id, nil)
      |> assign(:llm_test_status, :idle)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    category =
      case params["category"] do
        cat when is_binary(cat) ->
          try do
            String.to_existing_atom(cat)
          rescue
            ArgumentError -> socket.assigns.active_category
          end

        _ ->
          socket.assigns.active_category
      end

    # Only update if category is valid and different
    valid_categories = Map.keys(socket.assigns.schemas_by_category)
    category = if category in valid_categories, do: category, else: socket.assigns.active_category

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
    cat = String.to_existing_atom(cat_str)

    {:noreply,
     socket
     |> assign(:active_category, cat)
     |> assign(:search_text, "")
     |> assign(:per_category_errors, %{})}
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
    category =
      case params["category"] do
        cat_str when is_binary(cat_str) -> String.to_existing_atom(cat_str)
        _ -> socket.assigns.active_category
      end

    schemas = Map.get(socket.assigns.schemas_by_category, category, [])

    # Build config from params and merge into full file_config
    config =
      build_config_from_category_params(params, category, schemas, socket.assigns.file_config)

    case Schema.validate(config) do
      {:ok, _validated} ->
        case EvoGit.Config.save_user_config(config) do
          :ok ->
            file_config = load_file_config()
            config_status = safe_config_status()
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
            config_status = safe_config_status()
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
    key_path = parse_key_path(path_str)
    schema = find_schema(key_path, socket.assigns.schemas_by_category)
    config = put_in(socket.assigns.file_config, key_path, schema.default)

    case EvoGit.Config.save_user_config(config) do
      :ok ->
        file_config = load_file_config()
        config_status = safe_config_status()
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
         |> put_flash(:error, gettext("Failed to reset key: %{reason}", reason: inspect(reason)))}
    end
  end

  @impl true
  def handle_event("select_llm_provider", %{"provider_id" => id_str}, socket) do
    provider_id = String.to_existing_atom(id_str)
    models = EvoGit.Config.LLMCatalog.provider_models(provider_id)
    _variants = EvoGit.Config.LLMCatalog.provider_variants(provider_id)

    socket =
      socket
      |> assign(:selected_provider_id, provider_id)
      |> assign(:selected_provider_models, models)
      |> assign(:selected_variant_id, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_llm_variant", %{"variant_id" => variant_id_str}, socket) do
    variant_id = String.to_existing_atom(variant_id_str)
    {:noreply, assign(socket, :selected_variant_id, variant_id)}
  end

  @impl true
  def handle_event("select_llm_model_shortcut", %{"model_string" => model_string}, socket) do
    file_config = put_in(socket.assigns.file_config, [:llm, :model], model_string)
    persist_file_config(file_config, socket, gettext("Model selected and saved."))
  end

  @impl true
  def handle_event("save_custom_model", params, socket) do
    model_name = params["model_name"]
    base_url = params["base_url"]
    provider_id_str = params["provider_id"]

    try do
      provider_id = String.to_existing_atom(provider_id_str)
      provider = Enum.find(EvoGit.Config.LLMCatalog.providers(), &(&1.id == provider_id))

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
          file_config = put_in(socket.assigns.file_config, [:llm, :model], model_value)
          persist_file_config(file_config, socket, gettext("Custom model saved."))
      end
    rescue
      ArgumentError ->
        {:noreply, put_flash(socket, :error, gettext("Unknown provider."))}
    end
  end

  @impl true
  def handle_event("save_api_key", %{"env_var" => env_var, "api_key" => api_key}, socket) do
    if String.trim(api_key) == "" do
      {:noreply, put_flash(socket, :error, gettext("API key cannot be empty."))}
    else
      case EvoGit.Config.save_credentials(%{env_var => String.trim(api_key)}) do
        :ok ->
          config_status = safe_config_status()

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
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  defp persist_file_config(file_config, socket, success_msg) do
    # Always update in-memory state so the UI reflects the change immediately
    socket = assign(socket, :file_config, file_config)

    case EvoGit.Config.save_user_config(file_config) do
      :ok ->
        file_config = load_file_config()
        config_status = safe_config_status()
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
    try do
      EvoGit.Config.resolve()
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp load_scheduler_config do
    try do
      EvoGit.AgentScheduler.get_config()
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config building from params
  # ───────────────────────────────────────────────────────────────────────────

  defp build_config_from_category_params(params, category, schemas, file_config) do
    # Build a nested map from flat params for this category
    {category_config, emptied_paths} = params_to_category_config(params, category, schemas)

    # Deep merge into file_config
    merged = deep_merge(file_config, category_config)

    # Delete keys that were explicitly emptied
    Enum.reduce(emptied_paths, merged, fn key_path, acc ->
      deep_delete(acc, key_path)
    end)
  end

  defp params_to_category_config(params, _category, schemas) do
    Enum.reduce(schemas, {%{}, []}, fn schema, {config_acc, emptied_acc} ->
      value = Map.get(params, Enum.join(schema.key_path, "."))

      parsed =
        cond do
          is_nil(value) or value == "" ->
            :explicitly_empty

          schema.type in [:pos_integer, :non_neg_integer, :integer] ->
            parse_int(value)

          schema.type == :float ->
            parse_float(value)

          schema.type in [:string, :model_spec] ->
            value

          schema.type == :atom ->
            parse_atom(value)
        end

      cond do
        parsed == :explicitly_empty ->
          {config_acc, [schema.key_path | emptied_acc]}

        is_nil(parsed) ->
          {config_acc, emptied_acc}

        true ->
          {deep_put(config_acc, schema.key_path, parsed), emptied_acc}
      end
    end)
  end

  defp update_runtime_from_file_config(file_config, socket) do
    updates =
      []
      |> maybe_add_kw(:max_concurrency, get_in(file_config, [:scheduler, :max_concurrency]))
      |> maybe_add_kw(
        :max_tool_concurrency,
        get_in(file_config, [:scheduler, :max_tool_concurrency])
      )
      |> maybe_add_kw(:agent_max_retries, get_in(file_config, [:scheduler, :agent_max_retries]))
      |> maybe_add_kw(:max_agent_depth, get_in(file_config, [:scheduler, :max_agent_depth]))
      |> maybe_add_kw(:max_retries, get_in(file_config, [:scheduler, :max_retries]))
      |> maybe_add_kw(:max_turns, get_in(file_config, [:scheduler, :max_turns]))
      |> maybe_add_kw(:max_turns_root, get_in(file_config, [:scheduler, :max_turns_root]))
      |> maybe_add_kw(:llm_model, get_in(file_config, [:llm, :model]))

    # Always include LLM generation params (even when empty, to allow clearing)
    llm_gen_params = EvoGit.Config.Schema.llm_generation_params(file_config)
    updates = updates ++ [{:llm_generation_params, llm_gen_params}]

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

  defp parse_key_path(path_str) when is_binary(path_str) do
    path_str
    |> String.split(".")
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp find_schema(key_path, schemas_by_category) do
    schemas_by_category
    |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
    |> Enum.find(&(&1.key_path == key_path))
  end

  defp all_errors(per_category_errors) do
    Enum.flat_map(per_category_errors, fn {_cat, errors} -> errors end)
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_atom(value) when is_binary(value) and value != "" do
    String.to_atom(value)
  end

  defp parse_atom(_), do: nil

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: map operations
  # ───────────────────────────────────────────────────────────────────────────

  defp deep_put(map, [key], value) do
    Map.put(map, key, value)
  end

  defp deep_put(map, [key | rest], value) do
    existing = Map.get(map, key, %{})
    Map.put(map, key, deep_put(existing, rest, value))
  end

  defp deep_merge(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end

  defp deep_delete(map, [key]) do
    Map.delete(map, key)
  end

  defp deep_delete(map, [key | rest]) do
    case Map.get(map, key) do
      nested when is_map(nested) ->
        updated = deep_delete(nested, rest)

        if updated == %{} do
          Map.delete(map, key)
        else
          Map.put(map, key, updated)
        end

      _ ->
        map
    end
  end

  defp maybe_add_kw(list, _key, nil), do: list
  defp maybe_add_kw(list, key, value), do: Keyword.put(list, key, value)
end
