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
      <%= if @active_category != :remote_connections do %>
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

      <%!-- No LLM Model Warning (local only — remote config_status covers this) --%>
      <%= if not @remote_config and is_nil(get_in(@file_config, [:llm, :model])) do %>
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
        <%!-- Remote read-only banner: when viewing a remote node, config is
             read-only — it can only be changed on that node directly or via
             a config push (not yet implemented in the dashboard). --%>
        <%= if @remote_config do %>
          <div class="rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-3">
            <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
            <div>
              <h3 class="font-bold text-sm text-info mb-0.5">
                {gettext("Remote Configuration — Read Only")}
              </h3>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "You are viewing the configuration of a remote node. Changes cannot be saved from here — use config push to update the remote node."
                )}
              </p>
            </div>
          </div>
        <% end %>

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
            <%= if @active_category == :remote_connections do %>
              <%!-- Remote Connections UI — same design as category_section but
                   for the special :remote_connections pseudo-category --%>
              <div class="flex-1 flex flex-col min-w-0">
                <div class="sticky top-0 z-10 bg-base-100/90 backdrop-blur-md px-6 py-4 border-b border-base-200/70">
                  <div class="flex items-center gap-3 mb-1">
                    <.icon name="hero-globe-alt" class="size-5 text-base-content/70" />
                    <h2 class="text-lg font-bold text-base-content">
                      {gettext("Remote Connections")}
                    </h2>
                  </div>
                  <p class="text-sm text-base-content/60">
                    {gettext("Manage SSH connections to remote Genesis daemons.")}
                  </p>
                </div>

                <div class="p-6 space-y-5">
                  <%!-- Note about separate TOML file --%>
                  <div class="rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-3">
                    <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
                    <p class="text-sm text-base-content/80">
                      {gettext("Connection data is stored in `~/.config/genesis/remote_connections.toml`, separate from the main configuration file.")}
                    </p>
                  </div>

                  <%!-- Remote node mode: disable all actions --%>
                  <%= if @remote_config do %>
                    <div class="rounded-lg border border-warning/30 bg-warning/5 p-3 flex items-start gap-3">
                      <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
                      <p class="text-sm text-base-content/80">
                        {gettext("Remote connection management is not available when viewing a remote node.")}
                      </p>
                    </div>
                  <% end %>

                  <%!-- Existing targets --%>
                  <div :if={@remote_targets != []} class="space-y-3">
                    <div :for={target <- @remote_targets} class="rounded-lg border border-base-200 bg-base-100 p-4">
                      <div class="flex items-start justify-between gap-2">
                        <div class="flex items-center gap-3 min-w-0">
                          <span class={["w-2.5 h-2.5 rounded-full shrink-0 mt-1", remote_target_dot_color(target.id, @remote_statuses)]}></span>
                          <div class="min-w-0">
                            <p class="font-semibold text-sm truncate">{target.name}</p>
                            <p class="text-xs text-base-content/50 font-mono truncate">
                              {target[:ssh_target] || "#{target[:user]}@#{target[:host]}#{if target[:port] && target[:port] != 22, do: ":#{target[:port]}", else: ""}"}
                            </p>
                          </div>
                        </div>
                        <span class={remote_status_badge_class(target.id, @remote_statuses)}>
                          {remote_status_label(target.id, @remote_statuses)}
                        </span>
                      </div>

                      <div class="flex items-center gap-1 mt-3 flex-wrap">
                        <button
                          class="btn btn-xs btn-ghost gap-1"
                          phx-click="edit_remote_target"
                          phx-value-id={target.id}
                          disabled={@remote_config}
                        >
                          <.icon name="hero-pencil-square" class="size-3.5" />
                          {gettext("Edit")}
                        </button>
                        <button
                          class="btn btn-xs btn-ghost gap-1"
                          phx-click="delete_remote_target"
                          phx-value-id={target.id}
                          disabled={@remote_config}
                        >
                          <.icon name="hero-trash" class="size-3.5" />
                          {gettext("Delete")}
                        </button>
                        <div class="flex-1"></div>
                        <%= if remote_connected?(target.id, @remote_statuses) do %>
                          <button
                            class="btn btn-xs btn-ghost gap-1 text-warning"
                            phx-click="disconnect_remote_target"
                            phx-value-id={target.id}
                            disabled={@remote_config}
                          >
                            <.icon name="hero-arrow-left-end-on-rectangle" class="size-3.5" />
                            {gettext("Disconnect")}
                          </button>
                        <% else %>
                          <button
                            class="btn btn-xs btn-ghost gap-1"
                            phx-click="bootstrap_remote_target"
                            phx-value-id={target.id}
                            disabled={@remote_config}
                          >
                            <.icon name="hero-rocket-launch" class="size-3.5" />
                            {gettext("Bootstrap")}
                          </button>
                          <button
                            class="btn btn-xs btn-primary gap-1"
                            phx-click="connect_remote_target"
                            phx-value-id={target.id}
                            disabled={@remote_config}
                          >
                            <.icon name="hero-arrow-right-end-on-rectangle" class="size-3.5" />
                            {gettext("Connect")}
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div :if={@remote_targets == []} class="text-center py-10 text-base-content/50">
                    <.icon name="hero-server-stack" class="size-12 mx-auto mb-3 opacity-40" />
                    <p class="text-sm">{gettext("No remote connections configured.")}</p>
                  </div>

                  <%!-- SSH config help banner --%>
                  <div class="rounded-lg border border-base-300 bg-base-200 p-3 flex items-start gap-3">
                    <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
                    <div class="space-y-1.5">
                      <p class="text-sm text-base-content/80">
                        {gettext("Configure your SSH server in `~/.ssh/config` and set up SSH key authentication.")}
                      </p>
                      <p class="text-sm text-base-content/80">
                        {gettext("Enter the SSH target (the same string you'd type after `ssh`, e.g. `gpu-server` or `user@host`).")}
                      </p>
                      <p class="text-sm text-base-content/80">
                        {gettext("SSH port, identity file, and other options are read from your SSH config — no need to enter them here.")}
                      </p>
                    </div>
                  </div>

                  <%!-- Add / Edit target form --%>
                  <div class="border-t border-base-200 pt-5">
                    <%= if @remote_form_target do %>
                      <h4 class="font-semibold text-sm mb-4">
                        <%= if @remote_form_target[:id] do %>
                          {gettext("Edit Connection")}
                        <% else %>
                          {gettext("Add Connection")}
                        <% end %>
                      </h4>
                      <form phx-submit="save_remote_target" class="space-y-4">
                        <input type="hidden" name="_id" value={@remote_form_target[:id]} />
                        <div class="grid grid-cols-2 gap-4">
                          <div class="form-control col-span-2">
                            <label class="label">
                              <span class="label-text font-semibold text-xs">{gettext("Name")}</span>
                            </label>
                            <input
                              type="text"
                              name="name"
                              value={@remote_form_target[:name]}
                              placeholder={gettext("e.g. GPU Server")}
                              class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                              disabled={@remote_config}
                            />
                          </div>
                          <div class="form-control col-span-2">
                            <label class="label">
                              <span class="label-text font-semibold text-xs">{gettext("SSH Target")}</span>
                            </label>
                            <input
                              type="text"
                              name="ssh_target"
                              value={@remote_form_target[:ssh_target]}
                              placeholder={gettext("gpu-server or user@host")}
                              class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                              disabled={@remote_config}
                            />
                          </div>
                          <div class="form-control col-span-2">
                            <label class="label">
                              <span class="label-text font-semibold text-xs">{gettext("Local Binary Path")}</span>
                            </label>
                            <input
                              type="text"
                              name="local_binary_path"
                              value={@remote_form_target[:local_binary_path]}
                              placeholder="burrito_out/genesis_remote_linux_x64"
                              class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                              disabled={@remote_config}
                            />
                          </div>
                          <div class="form-control">
                            <label class="label">
                              <span class="label-text font-semibold text-xs">{gettext("Dist Port")}</span>
                            </label>
                            <input
                              type="number"
                              name="dist_port"
                              value={@remote_form_target[:dist_port]}
                              placeholder="9000"
                              class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                              disabled={@remote_config}
                            />
                          </div>
                          <div class="form-control">
                            <label class="label">
                              <span class="label-text font-semibold text-xs">{gettext("Remote Path")}</span>
                            </label>
                            <input
                              type="text"
                              name="remote_path"
                              value={@remote_form_target[:remote_path]}
                              placeholder="/tmp/genesis_remote"
                              class="input input-bordered input-sm w-full rounded-lg bg-base-50 font-mono text-sm"
                              disabled={@remote_config}
                            />
                          </div>
                        </div>
                        <div class="flex items-center justify-end gap-2 pt-1">
                          <button
                            type="button"
                            class="btn btn-ghost btn-sm rounded-lg"
                            phx-click="cancel_edit_remote"
                            disabled={@remote_config}
                          >
                            {gettext("Cancel")}
                          </button>
                          <button type="submit" class="btn btn-primary btn-sm rounded-lg" disabled={@remote_config}>
                            <%= if @remote_form_target[:id] do %>
                              {gettext("Save")}
                            <% else %>
                              {gettext("Add")}
                            <% end %>
                          </button>
                        </div>
                      </form>
                    <% else %>
                      <button
                        class="btn btn-ghost btn-sm gap-2 w-full border border-dashed border-base-300 rounded-lg"
                        phx-click="add_remote_target"
                        disabled={@remote_config}
                      >
                        <.icon name="hero-plus" class="size-4" />
                        {gettext("Add Connection")}
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
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
              test_profile_id={@test_profile_id}
              credentials={@credentials}
              disabled={@remote_config}
            />
            <% end %>
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

    models = get_in(file_config, [:llm, :models]) || []
    test_profile_id = if models != [], do: ModelProfileHelpers.profile_id(hd(models))

    schemas_by_category = Map.put(schemas_by_category, :remote_connections, [])

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
        editing_profile_id: nil,
        test_profile_id: test_profile_id,
        remote_config: false,
        remote_targets: EvoDash.NodeContext.list_targets(),
        remote_statuses: EvoDash.NodeContext.connection_status(),
        remote_form_target: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/settings")
      |> load_node_config()

    # Map the raw query param to a known category atom via a whitelist lookup
    # built from the existing schemas_by_category map (atom keys). Stringify
    # the keys so we compare string-to-string — no String.to_existing_atom on
    # untrusted input, fully crash-safe for unknown values.
    category_str_to_atom = ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category)

    category =
      case params["category"] do
        "remote_connections" -> :remote_connections
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
    {:noreply, socket} = EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)

    socket =
      if socket.assigns.active_category == :remote_connections do
        socket
        |> assign(:remote_targets, EvoDash.NodeContext.list_targets())
        |> assign(:remote_statuses, EvoDash.NodeContext.connection_status())
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    {:noreply, socket} = EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)

    if socket.assigns.active_category == :remote_connections do
      {:noreply, assign(socket, :remote_statuses, EvoDash.NodeContext.connection_status())}
    else
      {:noreply, socket}
    end
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
        (if cat_str == "remote_connections", do: :remote_connections) ||
        socket.assigns.active_category

    socket =
      assign(socket,
        active_category: cat,
        search_text: "",
        per_category_errors: %{}
      )

    socket =
      if cat == :remote_connections do
        socket
        |> assign(:remote_targets, EvoDash.NodeContext.list_targets())
        |> assign(:remote_statuses, EvoDash.NodeContext.connection_status())
      else
        socket
      end

    {:noreply, socket}
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
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
        ConfigIO.build_config_from_category_params(
          params,
          category,
          schemas,
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
  end

  @impl true
  def handle_event("save_search", params, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
  end

  @impl true
  def handle_event("reset_key", %{"key_path" => path_str}, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      # Add a new model profile using the selected model string, and mirror it to
      # the flat [:llm, :model] for backward compatibility (older code paths and
      # the config-status check still read the flat field).
      file_config =
        socket.assigns.file_config
        |> ModelProfileHelpers.add_model_profile(model_string)
        |> ModelProfileHelpers.mirror_default_model()

      persist_file_config(file_config, socket, gettext("Model selected and saved."))
    end
  end

  @impl true
  def handle_event("save_custom_model", params, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
  end

  @impl true
  def handle_event("save_quick_setup", params, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
            # Resolve the canonical provider atom. Start from hd(provider_atoms)
            # then apply variant resolution if a variant was selected.
            provider_atom = hd(provider.provider_atoms)

            resolved_atom =
              if variant_id_str != nil and variant_id_str != "" do
                # Whitelist variant lookup via variant_id_by_str (safe Map.get,
                # no String.to_existing_atom on untrusted input). Falls back
                # to the canonical provider atom for unknown/empty values.
                variant_atom = Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id_str)
                EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom, variant_atom)
              else
                EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom)
              end

            # The model_string from shortcut buttons is in "provider:model"
            # format (e.g. "openai:gpt-5.5"). resolve_model_spec expects
            # just the model id portion, so we strip the provider prefix.
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
              opts =
                if String.trim(base_url || "") == "",
                  do: [],
                  else: [base_url: String.trim(base_url)]

              {:ok,
               EvoGit.Config.LLMCatalog.resolve_model_spec(resolved_atom, model_name, opts)}
            end
        end

      case result do
        {:error, msg} ->
          {:noreply, put_flash(socket, :error, msg)}

        {:ok, model_value} ->
          # Add a new model profile using the selected model, and mirror it to the
          # flat [:llm, :model] for backward compatibility.
          file_config =
            socket.assigns.file_config
            |> ModelProfileHelpers.add_model_profile(model_value)
            |> ModelProfileHelpers.mirror_default_model()

          persist_file_config(file_config, socket, gettext("Model selected and saved."))
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Model Profiles editor events
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("add_model_profile", _params, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
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
  end

  @impl true
  def handle_event("delete_model_profile", %{"profile_id" => id}, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      models = get_in(socket.assigns.file_config, [:llm, :models]) || []
      new_models = Enum.reject(models, fn p -> ModelProfileHelpers.profile_id(p) == id end)

      file_config =
        socket.assigns.file_config
        |> ModelProfileHelpers.put_in_model_profiles(new_models)
        |> ModelProfileHelpers.mirror_default_model()

      socket = socket |> assign(:editing_profile_id, nil)

      persist_file_config(file_config, socket, gettext("Model profile deleted."))
    end
  end

  @impl true
  def handle_event("save_api_key", %{"credential_key" => credential_key, "api_key" => api_key}, socket) do
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      if String.trim(api_key) == "" do
        {:noreply, put_flash(socket, :error, gettext("API key cannot be empty."))}
      else
        case EvoGit.Config.save_credentials(%{credential_key => String.trim(api_key)}) do
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
  end

  @impl true
  def handle_event("test_llm", params, socket) do
    # The connection test button renders outside the disabled form, so it
    # remains clickable on a remote node. Guard the handler: EvoGit.SystemCheck
    # .llm_test/0 tests the LOCAL LLM, returning a misleading result when the
    # user is viewing a remote node's read-only config.
    if socket.assigns.remote_config do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("LLM connection test is not available for remote nodes")
       )}
    else
      profile_id = params["profile_id"]
      models = get_in(socket.assigns.file_config, [:llm, :models])

      profile = Enum.find(models, fn p -> ModelProfileHelpers.profile_id(p) == profile_id end)

      model_string =
        if profile, do: profile_model_string(profile)

      if model_string do
        parent = self()

        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          result = EvoGit.SystemCheck.llm_test(model_string)
          send(parent, {:llm_test_result, result})
        end)

        {:noreply, assign(socket, :llm_test_status, :testing)}
      else
        {:noreply, put_flash(socket, :error, gettext("Selected profile has no model configured."))}
      end
    end
  end

  @impl true
  def handle_event("select_test_profile", %{"value" => profile_id}, socket) do
    {:noreply, assign(socket, :test_profile_id, profile_id)}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Remote Connections event handlers
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("add_remote_target", _params, socket) do
    if socket.assigns.remote_config do
      {:noreply, put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      {:noreply, assign(socket, :remote_form_target, %{dist_port: 9000, remote_path: "/tmp/genesis_remote"})}
    end
  end

  @impl true
  def handle_event("cancel_edit_remote", _params, socket) do
    {:noreply, assign(socket, :remote_form_target, nil)}
  end

  @impl true
  def handle_event("edit_remote_target", %{"id" => id}, socket) do
    form_target =
      case EvoDash.NodeContext.get_target(id) do
        {:ok, target} ->
          target
          |> Map.put_new(:dist_port, 9000)
          |> Map.put_new(:remote_path, "/tmp/genesis_remote")

        {:error, :not_found} ->
          nil
      end

    {:noreply, assign(socket, :remote_form_target, form_target)}
  end

  @impl true
  def handle_event("save_remote_target", params, socket) do
    if socket.assigns.remote_config do
      {:noreply, put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      target = build_remote_target_from_params(params)

      case EvoDash.NodeContext.save_target(target) do
        {:ok, _saved} ->
          socket =
            socket
            |> assign(:remote_form_target, nil)
            |> put_flash(:info, gettext("Connection saved."))
            |> reload_remote_targets()

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to save: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  @impl true
  def handle_event("delete_remote_target", %{"id" => id}, socket) do
    if socket.assigns.remote_config do
      {:noreply, put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      case EvoDash.NodeContext.delete_target(id) do
        :ok ->
          socket =
            socket
            |> put_flash(:info, gettext("Connection deleted."))
            |> reload_remote_targets()

          {:noreply, socket}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Connection not found."))}
      end
    end
  end

  @impl true
  def handle_event("bootstrap_remote_target", %{"id" => id}, socket) do
    if socket.assigns.remote_config do
      {:noreply, put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      result = EvoDash.NodeContext.bootstrap(id)

      socket =
        socket
        |> reload_remote_statuses()
        |> flash_remote_lifecycle_result(result, gettext("Bootstrap"))

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("connect_remote_target", %{"id" => id}, socket) do
    if socket.assigns.remote_config do
      {:noreply, put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      result = EvoDash.NodeContext.connect(id)

      socket =
        socket
        |> reload_remote_statuses()
        |> flash_remote_lifecycle_result(result, gettext("Connect"))

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("disconnect_remote_target", %{"id" => id}, socket) do
    if socket.assigns.remote_config do
      {:noreply, put_flash(socket, :error, gettext("Configuration is read-only on a remote node."))}
    else
      result = EvoDash.NodeContext.disconnect(id)

      socket =
        socket
        |> reload_remote_statuses()
        |> flash_remote_lifecycle_result(result, gettext("Disconnect"))

      {:noreply, socket}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Model profile string composition
  # ───────────────────────────────────────────────────────────────────────────

  # Composes a model string like "provider:id" from a profile's :model field.
  # Handles map specs (%{provider: a, id: s}), tuples ({:provider, opts}),
  # and legacy binary strings.
  defp profile_model_string(%{model: model}) when is_map(model) do
    provider = model[:provider] || model["provider"]
    id = model[:id] || model["id"]
    if provider && id, do: "#{provider}:#{id}"
  end

  defp profile_model_string(%{model: {provider, opts}})
       when is_atom(provider) and is_list(opts) do
    id = Keyword.get(opts, :id)
    if id && id != "", do: "#{provider}:#{id}"
  end

  defp profile_model_string(%{model: model}) when is_binary(model) and model != "", do: model
  defp profile_model_string(_), do: nil

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

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Node-aware config loading
  # ───────────────────────────────────────────────────────────────────────────

  # Loads the config to display based on the current node context.
  #
  # On the local node (`socket.assigns.current_node == node()`), config is loaded
  # from the local file system exactly as before (editable). On a remote node, the
  # resolved scheduler config is fetched via `EvoDash.NodeContext.get_remote_config/1`
  # and displayed read-only — the form inputs are disabled and saves are blocked.
  #
  # `@remote_config` is a boolean flag the template uses to show the read-only
  # banner and disable form inputs.
  defp load_node_config(socket) do
    if socket.assigns.current_node == node() do
      # Local node — load from disk exactly as mount/1 does.
      socket
      |> assign(:remote_config, false)
      |> assign(:file_config, ConfigIO.load_file_config())
      |> assign(:config_status, config_status())
    else
      # Remote node — fetch the resolved scheduler config via RPC. This returns
      # a flat map (e.g. %{max_concurrency: 3, llm_model: "...", ...}), which we
      # surface read-only. We DON'T attempt to reconstruct the full nested
      # file_config structure — instead we put the remote values into a
      # best-effort nested map so the schema-driven cards display them.
      remote_cfg = EvoDash.NodeContext.get_remote_config(socket.assigns.current_node)

      file_config = remote_config_to_file_config(remote_cfg)

      socket
      |> assign(:remote_config, true)
      |> assign(:file_config, file_config)
      |> assign(
        :config_status,
        EvoDash.NodeContext.get_remote_config_status(socket.assigns.current_node)
      )
    end
  end

  # Maps the flat scheduler config map (from get_remote_config/1) into the nested
  # %{scheduler: ..., llm: ...} structure the schema-driven setting cards expect.
  # Only the keys present in the scheduler config are populated; the rest fall
  # back to schema defaults when rendered. This is best-effort display data for
  # the read-only remote view.
  defp remote_config_to_file_config(remote_cfg) when is_map(remote_cfg) do
    scheduler =
      %{}
      |> maybe_put(:max_concurrency, remote_cfg[:max_concurrency])
      |> maybe_put(:max_tool_concurrency, remote_cfg[:max_tool_concurrency])
      |> maybe_put(:agent_max_retries, remote_cfg[:agent_max_retries])
      |> maybe_put(:max_agent_depth, remote_cfg[:max_agent_depth])
      |> maybe_put(:max_retries, remote_cfg[:max_retries])
      |> maybe_put(:max_turns, remote_cfg[:max_turns])
      |> maybe_put(:max_turns_root, remote_cfg[:max_turns_root])

    llm =
      %{}
      |> maybe_put(:model, remote_cfg[:llm_model])

    # Model profiles come as a list of maps; surface them for display.
    llm =
      case remote_cfg[:model_profiles] do
        nil -> llm
        [] -> llm
        profiles -> Map.put(llm, :models, profiles)
      end

    %{}
    |> Map.put(:scheduler, scheduler)
    |> Map.put(:llm, llm)
  end

  defp remote_config_to_file_config(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Remote Connections
  # ───────────────────────────────────────────────────────────────────────────

  defp reload_remote_targets(socket) do
    assign(socket, :remote_targets, EvoDash.NodeContext.list_targets())
  end

  defp reload_remote_statuses(socket) do
    assign(socket, :remote_statuses, EvoDash.NodeContext.connection_status())
  end

  defp build_remote_target_from_params(params) do
    id = params["_id"]
    id = if id && id != "", do: id, else: generate_remote_id(params["name"])

    %{
      id: id,
      name: params["name"] || "",
      ssh_target: params["ssh_target"] || "",
      local_binary_path: params["local_binary_path"] || "",
      dist_port: parse_remote_port(params["dist_port"]),
      remote_path: params["remote_path"] || "/tmp/genesis_remote"
    }
  end

  defp parse_remote_port(nil), do: nil
  defp parse_remote_port(""), do: nil

  defp parse_remote_port(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_remote_port(num) when is_integer(num), do: num

  defp generate_remote_id(nil), do: generate_remote_id("")

  defp generate_remote_id(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "" do
      "target-#{System.system_time(:second)}"
    else
      slug
    end
  end

  defp flash_remote_lifecycle_result(socket, result, action) do
    case result do
      {:error, :remote_connection_unavailable} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} unavailable — the remote connection subsystem is not running.",
            action: action
          )
        )

      :ok ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:ok, _} ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:error, reason} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))
        )

      _other ->
        put_flash(socket, :info, gettext("%{action} completed.", action: action))
    end
  end

  defp remote_target_dot_color(target_id, statuses) do
    status = Map.get(statuses, target_id, :disconnected)

    case status do
      :connected -> "bg-emerald-500"
      :connecting -> "bg-amber-500 animate-pulse"
      :disconnecting -> "bg-amber-500 animate-pulse"
      :error -> "bg-rose-500"
      :disconnected -> "bg-slate-400"
      _ -> "bg-slate-400"
    end
  end

  defp remote_connected?(target_id, statuses) do
    Map.get(statuses, target_id, :disconnected) == :connected
  end

  defp remote_status_badge_class(target_id, statuses) do
    status = Map.get(statuses, target_id, :disconnected)

    case status do
      :connected -> "badge badge-success badge-sm"
      :connecting -> "badge badge-warning badge-sm"
      :disconnecting -> "badge badge-warning badge-sm"
      :error -> "badge badge-error badge-sm"
      :disconnected -> "badge badge-ghost badge-sm"
      _ -> "badge badge-ghost badge-sm"
    end
  end

  defp remote_status_label(target_id, statuses) do
    status = Map.get(statuses, target_id, :disconnected)

    case status do
      :connected -> gettext("Connected")
      :connecting -> gettext("Connecting...")
      :disconnecting -> gettext("Disconnecting...")
      :error -> gettext("Error")
      :disconnected -> gettext("Disconnected")
      _ -> gettext("Unknown")
    end
  end
end
