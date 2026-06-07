defmodule EvoDashWeb.SettingsLive do
  use EvoDashWeb, :live_view
  alias EvoGit.Config.Schema

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status}>
      <%!-- Header --%>
      <div class="flex items-center gap-5 mb-8 animate-fade-in-up mt-2">
        <div class="relative flex items-center justify-center size-16 rounded-2xl bg-gradient-to-br from-primary/20 to-primary/5 text-primary shadow-[0_8px_30px_rgb(0,0,0,0.04)] border border-primary/10">
          <.icon name="hero-cog-8-tooth" class="size-8" />
          <div class="absolute inset-0 rounded-2xl bg-primary/10 blur-xl -z-10"></div>
        </div>
        <div>
          <h1 class="text-3xl font-extrabold tracking-tight text-base-content">{gettext("Settings")}</h1>
          <p class="text-sm text-base-content/60 mt-1 font-medium">{gettext("Runtime configuration and file settings")}</p>
        </div>
      </div>

      <%!-- Runtime Controls banner --%>
      <div class="mb-8 bg-base-100 rounded-3xl shadow-sm border border-base-200/70 overflow-hidden animate-fade-in-up animation-delay-100 relative group">
        <div class="absolute inset-0 bg-gradient-to-r from-base-200/30 to-transparent pointer-events-none"></div>
        <div class="relative p-6 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-6 transition-all duration-300">
          <div class="flex items-center gap-5">
            <div class={[
              "p-4 rounded-2xl flex items-center justify-center transition-colors duration-500",
              if(@scheduler_paused, do: "bg-warning/15 text-warning shadow-[0_0_20px_rgba(251,189,35,0.15)]", else: "bg-success/15 text-success shadow-[0_0_20px_rgba(54,211,153,0.15)]")
            ]}>
              <.icon
                name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"}
                class={"size-8" <> if(!@scheduler_paused, do: " animate-pulse", else: "")}
              />
            </div>
            <div>
              <h2 class="text-xl font-bold tracking-tight mb-1">
                {if @scheduler_paused, do: gettext("Scheduler Paused"), else: gettext("Scheduler Active")}
              </h2>
              <p class="text-sm text-base-content/60 font-medium leading-relaxed max-w-lg">
                <%= if @scheduler_paused do %>
                  {gettext("Running agents continue. No new slots or agents will be granted until resumed.")}
                <% else %>
                  {gettext("Agents and slots are being granted normally.")}
                <% end %>
              </p>
            </div>
          </div>
          <button
            type="button"
            phx-click="toggle_pause"
            class={[
              "btn btn-lg rounded-2xl font-bold tracking-wide shadow-sm hover:shadow-md transition-all duration-300 border-none shrink-0",
              if(@scheduler_paused, do: "bg-success/20 hover:bg-success/30 text-success-content", else: "bg-warning/20 hover:bg-warning/30 text-warning-content")
            ]}
          >
            <.icon name={if @scheduler_paused, do: "hero-play", else: "hero-pause"} class="size-5 mr-2" />
            {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")}
          </button>
        </div>
      </div>

      <%!-- Config Status Warning --%>
      <%= if not @config_status.ok? do %>
        <div class="mb-8 bg-warning/5 border border-warning/20 rounded-3xl p-6 animate-fade-in-up animation-delay-100 flex gap-4 items-start shadow-sm">
          <div class="p-3 bg-warning/20 text-warning rounded-2xl shrink-0 mt-0.5">
            <.icon name="hero-exclamation-triangle" class="size-6" />
          </div>
          <div>
            <h3 class="font-bold text-lg text-warning mb-2">{gettext("Missing Configuration")}</h3>
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
        <div class="mb-8 bg-error/5 border border-error/20 rounded-3xl p-6 animate-fade-in-up animation-delay-100 flex gap-4 items-start shadow-sm">
          <div class="p-3 bg-error/20 text-error rounded-2xl shrink-0 mt-0.5">
            <.icon name="hero-exclamation-triangle" class="size-6" />
          </div>
          <div>
            <h3 class="font-bold text-lg text-error mb-2">{gettext("No LLM Model Configured")}</h3>
            <p class="text-sm font-medium text-error/80 mb-4 leading-relaxed max-w-3xl">
              {gettext("Agents cannot run until you set a model. Go to the LLM category and fill in the Model field.")}
            </p>
            <div class="flex items-center gap-3 flex-wrap">
              <span class="text-xs font-bold uppercase tracking-wider text-base-content/50">{gettext("Example model names:")}</span>
              <span class="badge badge-ghost font-mono text-xs px-3 py-3 rounded-xl bg-base-200 border-base-300">anthropic/claude-3-5-sonnet-20241022</span>
              <span class="badge badge-ghost font-mono text-xs px-3 py-3 rounded-xl bg-base-200 border-base-300">openai/gpt-4o</span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Two-column sidebar + content layout --%>
      <div class="flex bg-base-100 rounded-[2rem] shadow-sm hover:shadow-md border border-base-200/70 overflow-hidden animate-fade-in-up animation-delay-200 min-h-[75vh] max-h-[80vh] transition-all duration-500">
        <%!-- Sidebar --%>
        <EvoDashWeb.SettingsComponents.settings_sidebar
          categories={@schemas_by_category}
          active_category={@active_category}
          search_text={@search_text}
        />

        <%!-- Content area --%>
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
          />
        </.form>
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
      |> assign(:scheduler_paused, load_paused_state())
      |> assign(:config_status, config_status)
      |> assign(:file_config, file_config)
      |> assign(:config_path, config_path)
      |> assign(:config_file_exists, config_file_exists)

    {:ok, socket}
  end

  @impl true
  def handle_info({:scheduler_config_updated}, socket) do
    {:noreply,
     socket
     |> assign(:scheduler_config, load_scheduler_config())
     |> assign(:scheduler_paused, load_paused_state())}
  end

  @impl true
  def handle_event("select_category", %{"category" => cat_str}, socket) do
    cat = String.to_existing_atom(cat_str)

    {:noreply,
     socket
     |> assign(:active_category, cat)
     |> assign(:per_category_errors, %{})}
  end

  @impl true
  def handle_event("search", %{"value" => text}, socket) do
    {:noreply, assign(socket, :search_text, text)}
  end

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
  def handle_event("toggle_pause", _params, socket) do
    if socket.assigns.scheduler_paused do
      EvoGit.AgentScheduler.resume()

      {:noreply,
       socket
       |> assign(:scheduler_paused, false)
       |> put_flash(:info, gettext("Scheduler resumed. New agents and slots are being granted."))}
    else
      EvoGit.AgentScheduler.pause()

      {:noreply,
       socket
       |> assign(:scheduler_paused, true)
       |> put_flash(
         :info,
         gettext(
           "Scheduler paused. Running agents continue, but no new slots or agents will be granted."
         )
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

  defp safe_config_status do
    try do
      EvoGit.Config.config_status()
    rescue
      _ -> %{missing: [], warnings: [], ok?: true}
    catch
      _, _ -> %{missing: [], warnings: [], ok?: true}
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

  defp load_paused_state do
    try do
      EvoGit.AgentScheduler.get_config()[:paused] || false
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config building from params
  # ───────────────────────────────────────────────────────────────────────────

  defp build_config_from_category_params(params, category, schemas, file_config) do
    # Build a nested map from flat params for this category
    category_config = params_to_category_config(params, category, schemas)

    # Deep merge into file_config
    deep_merge(file_config, category_config)
  end

  defp params_to_category_config(params, _category, schemas) do
    Enum.reduce(schemas, %{}, fn schema, acc ->
      value = Map.get(params, Enum.join(schema.key_path, "."))

      parsed =
        cond do
          is_nil(value) or value == "" ->
            nil

          schema.type in [:pos_integer, :non_neg_integer, :integer] ->
            parse_int(value)

          schema.type == :float ->
            parse_float(value)

          schema.type == :string ->
            value

          schema.type == :atom ->
            parse_atom(value)
        end

      if is_nil(parsed) do
        acc
      else
        deep_put(acc, schema.key_path, parsed)
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
      |> maybe_add_kw(:llm_model, get_in(file_config, [:llm, :model]))

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

  defp maybe_add_kw(list, _key, nil), do: list
  defp maybe_add_kw(list, key, value), do: Keyword.put(list, key, value)
end
