defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Local-only provider onboarding, as a step-by-step wizard.

  One decision per step (provider → authentication → model → reasoning &
  schedule → test → done), rendered through the shared pure step components in
  `EvoDashWeb.SettingsComponents.ProviderWizard` and driven by the pure draft
  model `EvoDashWeb.WelcomeLive.Wizard`. View-model derivation lives in
  `EvoDashWeb.WelcomeLive.Presentation`, so this module only owns the socket,
  the event vocabulary and the one save path.

  Every mutating event is refused while a remote node is being viewed: welcome
  setup configures THIS machine only.
  """
  use EvoDashWeb, :live_view

  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.LLMSetup.Schedule
  alias EvoDashWeb.SettingsComponents.ProviderWizard
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.WelcomeLive.Presentation
  alias EvoDashWeb.WelcomeLive.Setup
  alias EvoDashWeb.WelcomeLive.Wizard
  alias EvoGit.Config.LLMCatalog, as: Catalog

  # Pure navigation events stay usable on a remote-node view; every mutating
  # event is rejected by the guard clause below.
  @navigation_events ~w(wizard_back wizard_next skip get_started noop)

  @impl true
  def mount(_params, _session, socket) do
    config = ConfigIO.load_file_config()
    providers = Catalog.providers()

    {:ok,
     assign(socket,
       file_config: config,
       has_model?: Setup.has_model?(config),
       credentials: EvoGit.Config.credentials(),
       llm_providers: providers,
       flat_models: Setup.flatten_models(providers),
       current_version: Application.spec(:evo_git, :vsn) |> to_string(),
       draft: Wizard.new(),
       step: :provider,
       wizard_active: false,
       error: nil,
       llm_test_status: :idle,
       llm_test_seq: 0,
       search_query: "",
       preset_dismissed: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous = socket.assigns.current_node_id
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)

    socket =
      if socket.assigns.current_node_id == previous,
        do: socket,
        else: invalidate_test(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{current_node_id: id}} = socket)
      when not is_nil(id) and event not in @navigation_events do
    {:noreply, put_flash(socket, :error, gettext("Use Settings to configure the remote node."))}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("skip", _params, socket),
    do: {:noreply, redirect(socket, to: "/welcome/complete")}

  def handle_event("get_started", _params, socket),
    do: {:noreply, redirect(socket, to: "/welcome/complete")}

  def handle_event("wizard_back", _params, socket) do
    %{draft: draft, step: step} = socket.assigns
    {:noreply, assign(socket, step: Wizard.prev_step(draft, step), error: nil)}
  end

  def handle_event("wizard_next", _params, socket) do
    %{draft: draft, step: step} = socket.assigns

    case Wizard.validate(step, draft, Wizard.capabilities(draft)) do
      {:error, reason} ->
        {:noreply, assign(socket, error: Presentation.gate_message(reason))}

      :ok ->
        cond do
          step == :test -> save_and_finish(socket)
          step == :done -> {:noreply, socket}
          true -> {:noreply, assign(socket, step: Wizard.next_step(draft, step), error: nil)}
        end
    end
  end

  def handle_event("select_wizard_provider", %{"provider" => value}, socket)
      when is_binary(value) do
    case Presentation.provider_entry(socket.assigns.llm_providers, value) do
      nil ->
        {:noreply, socket}

      entry ->
        draft =
          Wizard.new()
          |> Wizard.put("provider", value)
          |> Wizard.put("variant", Presentation.first_variant(entry))
          |> Wizard.put("auth_mode", Setup.auth_mode(entry))

        socket = socket |> assign(draft: draft, error: nil) |> invalidate_test()
        socket = assign(socket, wizard_active: true)

        if Wizard.valid?(:provider, draft, Wizard.capabilities(draft)) do
          {:noreply, assign(socket, step: Wizard.next_step(draft, :provider))}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("select_wizard_variant", %{"variant" => value}, socket) when is_binary(value) do
    draft = socket.assigns.draft
    provider = Presentation.provider_entry(socket.assigns.llm_providers, draft["provider"])

    case Presentation.variant_id(provider, value) do
      nil ->
        {:noreply, socket}

      variant_id ->
        draft =
          draft
          |> Wizard.put("variant", variant_id)
          |> reset_model_choices()

        {:noreply, socket |> assign(draft: draft) |> invalidate_test()}
    end
  end

  def handle_event("select_wizard_auth", %{"mode" => mode}, socket)
      when mode in ["api_key", "oauth"] do
    draft = socket.assigns.draft
    modes = Map.get(Wizard.capabilities(draft), :auth_modes, ["api_key"])

    if mode in modes do
      draft = draft |> Wizard.put("auth_mode", mode) |> Wizard.put("api_key", "")
      {:noreply, socket |> assign(draft: draft) |> invalidate_test()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("wizard_model_search", params, socket) do
    query = params |> Map.get("query", "") |> to_string()
    {:noreply, assign(socket, search_query: query)}
  end

  def handle_event("select_wizard_model", %{"model" => model}, socket) when is_binary(model) do
    draft = socket.assigns.draft

    draft =
      if model in List.wrap(draft["models"]),
        do: draft,
        else: Wizard.toggle_model(draft, model)

    {:noreply, socket |> assign(draft: Wizard.put(draft, "default_model", model)) |> invalidate_test()}
  end

  def handle_event("toggle_wizard_model", %{"model" => model}, socket) when is_binary(model) do
    {:noreply,
     socket |> assign(draft: Wizard.toggle_model(socket.assigns.draft, model)) |> invalidate_test()}
  end

  def handle_event("wizard_custom_model", params, socket) do
    name = params |> Map.get("custom_model", "") |> to_string()

    {:noreply,
     socket
     |> assign(draft: Wizard.set_custom_model(socket.assigns.draft, name))
     |> invalidate_test()}
  end

  def handle_event("wizard_api_key", params, socket) do
    key = params |> Map.get("api_key", "") |> to_string()
    # Transient draft state only — never persisted to browser state or a push payload.
    {:noreply, socket |> assign(draft: Wizard.put(socket.assigns.draft, "api_key", key)) |> invalidate_test()}
  end

  def handle_event("wizard_field_changed", params, socket) do
    case Map.get(params, "base_url") do
      url when is_binary(url) ->
        {:noreply,
         socket |> assign(draft: Wizard.put(socket.assigns.draft, "base_url", url)) |> invalidate_test()}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("wizard_reasoning", params, socket) do
    draft = socket.assigns.draft
    inventory = inventory_from(params)
    effort = params |> Map.get("default_reasoning_effort", "") |> to_string()
    effort = if effort in inventory, do: effort, else: ""
    extra = Map.get(params, "model_reasoning", %{})
    extra = if is_map(extra), do: extra, else: %{}

    draft =
      cond do
        Presentation.custom_primary?(draft) ->
          draft
          |> Wizard.put("reasoning_efforts", inventory)
          |> Wizard.put("default_reasoning_effort", effort)

        true ->
          Wizard.put(draft, "model_reasoning", merge_model_reasoning(draft, extra, inventory, effort))
      end

    {:noreply, socket |> assign(draft: draft) |> invalidate_test()}
  end

  def handle_event("wizard_schedule_changed", params, socket) do
    draft = socket.assigns.draft
    value = params |> Map.get("off_peak_holidays", "") |> to_string() |> String.trim()
    schedule = ensure_map(draft["schedule"])

    schedule =
      case value do
        "" -> Map.delete(schedule, "off_peak_holidays")
        holiday -> Map.put(schedule, "off_peak_holidays", holiday)
      end

    # A manual edit: `Wizard.preset_state/1` remains the only judge of whether
    # the applied preset still matches, so nothing is silently re-applied.
    {:noreply, assign(socket, draft: Wizard.put(draft, "schedule", schedule))}
  end

  def handle_event("apply_schedule_preset", params, socket) do
    preset_id = params |> Map.get("preset_id", "") |> to_string()

    case Wizard.apply_preset(socket.assigns.draft, preset_id) do
      {draft, _snapshot} -> {:noreply, assign(socket, draft: draft, preset_dismissed: false)}
      draft -> {:noreply, assign(socket, draft: draft, preset_dismissed: false)}
    end
  end

  def handle_event("undo_schedule_preset", _params, socket) do
    {:noreply, assign(socket, draft: Wizard.undo_preset(socket.assigns.draft))}
  end

  def handle_event("dismiss_schedule_preset", _params, socket) do
    {:noreply, assign(socket, preset_dismissed: true)}
  end

  def handle_event("add_another_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(
       draft: Wizard.new(),
       step: :provider,
       wizard_active: true,
       error: nil,
       search_query: "",
       preset_dismissed: false,
       has_model?: true
     )
     |> invalidate_test()}
  end

  def handle_event("skip_test", _params, socket), do: save_and_finish(socket)

  def handle_event("test_connection", _params, socket) do
    %{draft: draft} = socket.assigns
    provider = Presentation.provider_entry(socket.assigns.llm_providers, draft["provider"])

    with {:ok, current} <- Setup.read_config(),
         {:ok, _config, profile, entry, key} <-
           Setup.prepare(current, setup_assigns(socket, provider), draft_params(draft)),
         :ok <- save_key(entry, key, draft["auth_mode"]) do
      seq = socket.assigns.llm_test_seq + 1
      reasoning = draft["default_reasoning_effort"]
      runner = Application.get_env(:evo_dash, :welcome_llm_test_runner, &EvoGit.SystemCheck.llm_test/2)

      case EvoDash.SafeCall.start(self(), {:welcome_llm_test_result, seq}, fn ->
             {model, opts} = Setup.test_request(profile, entry, reasoning)
             runner.(model, opts)
           end) do
        {:ok, _pid} ->
          {:noreply,
           assign(socket,
             llm_test_seq: seq,
             llm_test_status: :testing,
             draft: Wizard.put(draft, "api_key", ""),
             credentials: EvoGit.Config.credentials()
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket, llm_test_seq: seq, llm_test_status: {:error, Presentation.display_error(reason)})}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, llm_test_status: {:error, Presentation.display_error(reason)})}
    end
  end

  @impl true
  def handle_info({{:welcome_llm_test_result, seq}, guarded}, socket) do
    result =
      case guarded do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end

    handle_info({:welcome_llm_test_result, seq, result}, socket)
  end

  def handle_info({:welcome_llm_test_result, seq, result}, socket) do
    if seq == socket.assigns.llm_test_seq and socket.assigns.current_node_id == nil do
      status =
        case result do
          {:ok, detail} -> {:ok, detail}
          {:error, reason} -> {:error, Presentation.display_error(reason)}
        end

      {:noreply, assign(socket, llm_test_status: status, credentials: EvoGit.Config.credentials())}
    else
      {:noreply, socket}
    end
  end

  # Legacy unscoped test results must never touch a scoped draft.
  def handle_info({:llm_test_result, _result}, socket), do: {:noreply, socket}

  def handle_info({:task_updated, _, _, _} = msg, socket),
    do: EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)

  def handle_info({:task_deleted, _, _} = msg, socket),
    do: EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)

  def handle_info(:node_aware_reload_tasks, socket),
    do: {:noreply, EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)}

  def handle_info({:node_selected, id}, socket),
    do: EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, id)

  def handle_info({:remote_connection_status, _, _} = msg, socket),
    do: EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = prepare_view(assigns)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:welcome}
      simple_nav={false}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      session_list={assigns[:session_list] || []}
      session_list_loading={assigns[:session_list_loading] == true}
      session_list_error={assigns[:session_list_error]}
      current_session_id={assigns[:current_session_id]}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <div class="min-h-screen max-w-5xl mx-auto px-4 lg:px-6 py-4 space-y-5">
        <div class="flex items-center justify-between gap-3">
          <button
            type="button"
            onclick="if (window.history.length > 1) { history.back(); } else { window.location.href = '/'; }"
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />{gettext("Back")}
          </button>
          <button
            :if={@current_node_id == nil and not all_set?(@step, @has_model?, @wizard_active)}
            phx-click="skip"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Skip")}
          </button>
        </div>

        <div>
          <h2 class="text-xl font-bold">
            {if all_set?(@step, @has_model?, @wizard_active),
              do: gettext("You're All Set!"),
              else: gettext("Welcome to Genesis")}
          </h2>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext("Configure a provider and its models to start building with Genesis.")}
          </p>
        </div>

        <%= cond do %>
          <% @current_node_id != nil -> %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="size-5" />
              <span>
                {gettext(
                  "Welcome setup configures this machine only. Switch to Local or use Settings for the remote node."
                )}
              </span>
              <a href={~p"/welcome"} class="btn btn-primary btn-sm">{gettext("Switch to Local")}</a>
            </div>
          <% all_set?(@step, @has_model?, @wizard_active) -> %>
            <div class="bg-success/10 border border-success/20 rounded-xl p-5 flex gap-3">
              <.icon name="hero-check-circle" class="size-7 text-success" />
              <div class="space-y-2">
                <p class="font-bold text-success">{gettext("Ready to build!")}</p>
                <p class="text-sm text-base-content/70">
                  {gettext("Your LLM is configured. You can manage it anytime in Settings.")}
                </p>
                <div class="flex flex-wrap gap-2">
                  <button type="button" phx-click="get_started" class="btn btn-primary btn-sm">
                    {gettext("Go to Dashboard")}
                  </button>
                  <a href={~p"/settings"} class="btn btn-ghost btn-sm">{gettext("Open Settings")}</a>
                </div>
              </div>
            </div>
          <% true -> %>
            <ProviderWizard.wizard_shell
              step={@step}
              steps={Wizard.steps(@draft)}
              title={Presentation.step_title(@step)}
              subtitle={Presentation.step_subtitle(@step)}
              progress={Wizard.progress(@draft, @step)}
              back_event="wizard_back"
              next_event="wizard_next"
              next_label={next_label(@step)}
              next_disabled={not Wizard.valid?(@step, @draft, Wizard.capabilities(@draft))}
              cancel_event="skip"
              cancel_label={gettext("Skip")}
              error={@error}
            >
              <%= case @step do %>
                <% :provider -> %>
                  <form phx-change="wizard_field_changed" phx-submit="noop" class="space-y-4">
                    <ProviderWizard.step_provider
                      providers={@provider_options}
                      selected={@draft["provider"]}
                      provider_event="select_wizard_provider"
                      custom_value={Presentation.custom_value()}
                      base_url={@draft["base_url"]}
                      base_url_name="base_url"
                    />
                    <div :if={@variant_options != []} class="flex flex-wrap gap-2">
                      <button
                        :for={variant <- @variant_options}
                        type="button"
                        phx-click="select_wizard_variant"
                        phx-value-variant={variant["id"]}
                        class={"btn btn-sm " <> if(variant["selected"], do: "btn-primary", else: "btn-outline")}
                      >
                        {variant["label"]}
                      </button>
                    </div>
                  </form>
                <% :auth -> %>
                  <ProviderWizard.step_auth
                    selected={@draft["auth_mode"]}
                    auth_event="select_wizard_auth"
                    modes={@auth_modes}
                    oauth_only={@oauth_only?}
                  >
                    <:auth_detail>
                      <%= if @draft["auth_mode"] == "oauth" do %>
                        <p class="text-xs text-base-content/70">
                          {gettext(
                            "Log in once with the vendor CLI; Genesis imports the credentials lazily."
                          )}
                        </p>
                        <pre class="mt-2 whitespace-pre-wrap rounded-lg border border-base-300 bg-base-200/50 p-3 text-xs text-base-content/80">{@login_instructions}</pre>
                      <% else %>
                        <form phx-change="wizard_api_key" phx-submit="noop" class="space-y-2">
                          <label class="text-xs font-medium" for="wizard-api-key">
                            {gettext("API key")}
                          </label>
                          <input
                            id="wizard-api-key"
                            type="password"
                            name="api_key"
                            value={@draft["api_key"]}
                            autocomplete="off"
                            class="input input-sm w-full"
                            placeholder={@key_placeholder}
                          />
                          <p :if={@key_present?} class="text-xs text-base-content/60">
                            {gettext("A key is already stored for this provider.")}
                          </p>
                        </form>
                      <% end %>
                    </:auth_detail>
                  </ProviderWizard.step_auth>
                <% :model -> %>
                  <div class="space-y-4">
                    <ProviderWizard.step_model
                      models={@model_rows}
                      selected={@draft["default_model"]}
                      query={@search_query}
                      model_event="select_wizard_model"
                      model_search_event="wizard_model_search"
                      search_name="query"
                      custom_model_event="wizard_custom_model"
                      custom_model_name="custom_model"
                      custom_model={@draft["custom_model"]}
                      custom_model_value={@draft["custom_model"]}
                    />
                    <details :if={@all_model_rows != []} class="rounded-lg border border-base-300 p-3">
                      <summary class="cursor-pointer text-sm font-medium">
                        {gettext("Add another model")}
                      </summary>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <label
                          :for={row <- @all_model_rows}
                          class="flex items-center gap-2 rounded-lg border border-base-300 px-2 py-1 text-xs"
                        >
                          <input
                            type="checkbox"
                            phx-click="toggle_wizard_model"
                            phx-value-model={row["id"]}
                            checked={row["id"] in List.wrap(@draft["models"])}
                          />
                          <span>{row["label"]}</span>
                        </label>
                      </div>
                    </details>
                  </div>
                <% :reasoning_schedule -> %>
                  <form phx-change="wizard_reasoning" phx-submit="noop" class="space-y-4">
                    <ProviderWizard.step_reasoning_schedule
                      inventory={@inventory}
                      default_effort={@default_effort}
                      presets={@presets}
                      preset_applied={@preset_applied}
                      preset_apply_event="apply_schedule_preset"
                      preset_undo_event="undo_schedule_preset"
                      preset_dismiss_event="dismiss_schedule_preset"
                      off_peak_holidays={@holidays}
                      holiday_options={@holiday_options}
                      holiday_help={@holiday_help}
                      schedule_rows={@schedule_rows}
                      inventory_name={@inventory_name}
                      default_name={@default_name}
                    />
                    <div :if={@extra_models != []} class="space-y-2 border-t border-base-300 pt-3">
                      <p class="text-xs font-medium">{gettext("Other selected models")}</p>
                      <div
                        :for={row <- @extra_models}
                        class="flex items-center justify-between gap-3 text-sm"
                      >
                        <span class="truncate">{row["label"]}</span>
                        <select
                          name={"model_reasoning[#{row["id"]}]"}
                          class="select select-sm w-40"
                          aria-label={gettext("Default reasoning effort")}
                        >
                          <option value="">{gettext("Provider default")}</option>
                          <option
                            :for={effort <- row["efforts"]}
                            value={effort}
                            selected={effort == row["default"]}
                          >
                            {Reasoning.label(effort)}
                          </option>
                        </select>
                      </div>
                    </div>
                  </form>
                <% :test -> %>
                  <ProviderWizard.step_test
                    test_state={@llm_test_status}
                    test_event="test_connection"
                    skip_event="skip_test"
                  />
                <% :done -> %>
                  <ProviderWizard.step_done
                    summary={@summary}
                    dashboard_path={~p"/welcome/complete"}
                  >
                    <:secondary>
                      <button
                        type="button"
                        phx-click="add_another_provider"
                        class="btn btn-outline btn-sm"
                      >
                        {gettext("Add another provider")}
                      </button>
                      <a href={~p"/settings"} class="btn btn-ghost btn-sm">
                        {gettext("Open Settings")}
                      </a>
                    </:secondary>
                  </ProviderWizard.step_done>
              <% end %>
            </ProviderWizard.wizard_shell>
        <% end %>

        <p class="text-xs text-base-content/60">
          {gettext("Genesis %{version}", version: @current_version)}
        </p>
      </div>
    </Layouts.app>
    """
  end

  # ── View model ───────────────────────────────────────────────────────────

  defp prepare_view(assigns) do
    draft = if is_map(assigns.draft), do: assigns.draft, else: Wizard.new()
    provider = Presentation.provider_entry(assigns.llm_providers, draft["provider"])
    provider_id = provider && Map.get(provider, :id)
    variant_id = Presentation.variant_id(provider, draft["variant"])
    capabilities = Wizard.capabilities(draft)
    scoped = Setup.provider_models(assigns.flat_models, provider_id, variant_id)
    wire = Presentation.wire_atom(provider, variant_id)
    primary = draft["default_model"]

    extra_models =
      draft
      |> Map.get("models")
      |> List.wrap()
      |> Enum.reject(&(&1 == primary))
      |> Enum.map(fn model ->
        entry = Presentation.model_entry(scoped, model)

        %{
          "id" => model,
          "label" => map_field(entry, :model_display_name) || model,
          "efforts" => map_field(entry, :reasoning_efforts) || [],
          "default" => model_reasoning_default(draft, model)
        }
      end)

    assigns
    |> assign(:draft, draft)
    |> assign(:provider_options, Presentation.provider_options(assigns.llm_providers))
    |> assign(:variant_options, variant_options(provider, draft))
    |> assign(:auth_modes, Map.get(capabilities, :auth_modes, ["api_key"]))
    |> assign(:oauth_only?, oauth_only?(wire))
    |> assign(:login_instructions, Presentation.login_instructions(wire))
    |> assign(:model_rows, scoped |> Setup.filtered_models(assigns.search_query) |> Presentation.model_rows())
    |> assign(:all_model_rows, Presentation.model_rows(scoped))
    |> assign(:inventory, Presentation.primary_inventory(draft, provider))
    |> assign(:default_effort, Presentation.primary_effort(draft))
    |> assign(:presets, Presentation.schedule_presets(provider, variant_id))
    |> assign(:preset_applied, Presentation.preset_applied(draft, assigns.preset_dismissed))
    |> assign(:holidays, Wizard.holiday_value(draft))
    |> assign(:holiday_options, Schedule.holiday_options())
    |> assign(:holiday_help, Schedule.holiday_help())
    |> assign(:schedule_rows, Wizard.schedule_rows(draft))
    |> assign(:inventory_name, Reasoning.inventory_input_name())
    |> assign(:default_name, Reasoning.default_input_name())
    |> assign(:extra_models, extra_models)
    |> assign(:summary, Wizard.summary_rows(draft))
    |> assign(:key_present?, key_present?(assigns.credentials, provider))
    |> assign(:key_placeholder, key_placeholder(provider))
  end

  defp variant_options(provider, draft) do
    current = draft["variant"]

    provider
    |> Presentation.variant_options()
    |> Enum.map(fn row -> Map.put(row, "selected", row["id"] == to_string(current || "")) end)
  end

  defp all_set?(:provider, has_model?, wizard_active?),
    do: has_model? and not wizard_active?

  defp all_set?(_step, _has_model?, _wizard_active?), do: false

  defp next_label(:test), do: gettext("Save and finish")
  defp next_label(_step), do: nil

  defp key_present?(credentials, provider) when is_map(credentials) do
    key = map_field(provider, :credential_key)
    not is_nil(key) and Map.get(credentials, key) not in [nil, ""]
  end

  defp key_present?(_credentials, _provider), do: false

  defp key_placeholder(provider) do
    case map_field(provider, :display_name) do
      name when is_binary(name) and name != "" ->
        gettext("Paste your %{provider} API key", provider: name)

      _other ->
        gettext("Paste your API key")
    end
  end

  defp oauth_only?(wire) when is_atom(wire) and not is_nil(wire),
    do: Catalog.oauth_only?(wire) == true

  defp oauth_only?(_wire), do: false

  # ── Draft helpers ────────────────────────────────────────────────────────

  defp invalidate_test(socket) do
    assign(socket, llm_test_seq: socket.assigns.llm_test_seq + 1, llm_test_status: :idle)
  end

  defp reset_model_choices(draft) do
    draft
    |> Wizard.put("models", [])
    |> Wizard.put("default_model", nil)
    |> Wizard.put("custom_model", "")
    |> Wizard.put("model_reasoning", %{})
    |> Wizard.put("reasoning_efforts", [])
    |> Wizard.put("default_reasoning_effort", "")
    |> Wizard.put("schedule", %{})
    |> Wizard.put("schedule_snapshot", nil)
    |> Wizard.put("preset_id", nil)
  end

  defp inventory_from(params) do
    params
    |> Map.get("reasoning_efforts", Map.get(params, "reasoning_efforts[]", []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Reasoning.normalize_inventory()
  end

  defp merge_model_reasoning(draft, extra, inventory, effort) do
    existing = ensure_map(draft["model_reasoning"])

    existing =
      case draft["default_model"] do
        model when is_binary(model) and model != "" ->
          Map.put(existing, model, %{"efforts" => inventory, "default" => effort})

        _other ->
          existing
      end

    Enum.reduce(extra, existing, fn {model, value}, acc ->
      current = ensure_map(Map.get(acc, model, %{}))
      Map.put(acc, model, Map.put(current, "default", to_string(value)))
    end)
  end

  defp model_reasoning_default(draft, model) do
    draft
    |> Map.get("model_reasoning")
    |> ensure_map()
    |> Map.get(model, %{})
    |> ensure_map()
    |> Map.get("default", "")
  end

  # ── Save / test plumbing ─────────────────────────────────────────────────

  defp save_and_finish(socket) do
    case save_draft(socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  defp save_draft(socket) do
    draft = socket.assigns.draft
    provider = Presentation.provider_entry(socket.assigns.llm_providers, draft["provider"])
    setup = setup_assigns(socket, provider)

    with {:ok, current} <- Setup.read_config(),
         {:ok, config, _profile, entry, key} <- Setup.prepare(current, setup, draft_params(draft)),
         :ok <- save_key(entry, key, setup.auth_mode),
         :ok <- Setup.write(fn -> EvoGit.Config.save_user_config(config) end) do
      config = ConfigIO.load_file_config()

      socket =
        socket
        |> assign(
          file_config: config,
          has_model?: true,
          credentials: EvoGit.Config.credentials(),
          error: nil,
          step: :done,
          draft: Wizard.put(draft, "api_key", "")
        )
        |> push_runtime(config)

      {:ok,
       put_flash(
         socket,
         :info,
         gettext("Provider and models saved. You're all set!")
       )}
    else
      {:error, reason} -> {:error, Presentation.display_error(reason)}
    end
  end

  defp push_runtime(socket, config) do
    _ = ConfigIO.update_runtime_from_file_config(socket, config)
    socket
  end

  defp setup_assigns(socket, provider) do
    draft = socket.assigns.draft

    %{
      selected_provider_id: provider && Map.get(provider, :id),
      selected_variant_id: draft["variant"],
      selected_models: List.wrap(draft["models"]),
      model_reasoning: ensure_map(draft["model_reasoning"]),
      custom_model: draft["custom_model"] || "",
      reasoning_efforts: List.wrap(draft["reasoning_efforts"]),
      default_reasoning_effort: draft["default_reasoning_effort"] || "",
      base_url_input: draft["base_url"] || "",
      api_key_input: draft["api_key"] || "",
      auth_mode: draft["auth_mode"] || "api_key",
      credentials: socket.assigns.credentials,
      flat_models: socket.assigns.flat_models,
      default_model: draft["default_model"],
      schedule: ensure_map(draft["schedule"])
    }
  end

  defp draft_params(draft) do
    %{
      "custom_model" => draft["custom_model"] || "",
      "reasoning_efforts" => List.wrap(draft["reasoning_efforts"]),
      "default_reasoning_effort" => draft["default_reasoning_effort"] || "",
      "default_model" => draft["default_model"] || "",
      "base_url" => draft["base_url"] || "",
      "api_key" => draft["api_key"] || "",
      "auth_mode" => draft["auth_mode"] || "api_key",
      "schedule" => ensure_map(draft["schedule"])
    }
  end

  defp save_key(_entry, _key, "oauth"), do: :ok
  defp save_key(nil, _key, _mode), do: :ok
  defp save_key(_entry, "", _mode), do: :ok

  defp save_key(entry, key, _mode) do
    Setup.write(fn -> EvoGit.Config.save_credentials(%{entry.credential_key => key}) end)
  end

  # ── Small total helpers ──────────────────────────────────────────────────

  defp map_field(map, key) when is_map(map), do: Map.get(map, key)
  defp map_field(_map, _key), do: nil

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_map), do: %{}
end
