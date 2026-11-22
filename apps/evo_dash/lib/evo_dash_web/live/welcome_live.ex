defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Local-only provider onboarding, as a step-by-step wizard.

  One decision per step (provider → authentication → model → reasoning &
  schedule → test → done), rendered through the shared pure step components in
  `EvoDashWeb.SettingsComponents.ProviderWizard`, whose per-step bodies live in
  `EvoDashWeb.WelcomeLive.Steps`, and driven by the pure draft model
  `EvoDashWeb.WelcomeLive.Wizard`. View-model derivation lives in
  `EvoDashWeb.WelcomeLive.Presentation`, so this module only owns the socket,
  the event vocabulary and the one save path.

  Every mutating event is refused while a remote node is being viewed: welcome
  setup configures THIS machine only.
  """
  use EvoDashWeb, :live_view

  alias EvoDashWeb.LLMSetup.{ChatGPT, Reasoning}
  alias EvoDashWeb.SettingsComponents.ProviderWizard
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.WelcomeLive.Presentation
  alias EvoDashWeb.WelcomeLive.Setup
  alias EvoDashWeb.WelcomeLive.Steps
  alias EvoDashWeb.WelcomeLive.ViewModel
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
     socket
     |> assign(
       has_model?: Setup.has_model?(config),
       credentials: EvoGit.Config.credentials(),
       llm_providers: providers,
       flat_models: Setup.flatten_models(providers),
       chatgpt_accounts: %{},
       chatgpt_sign_in: ChatGPTSignInState.new(),
       chatgpt_sign_in_manual: manual_sign_in?(socket),
       current_version: Application.spec(:evo_git, :vsn) |> to_string(),
       draft: Wizard.new(),
       step: :provider,
       wizard_active: false,
       error: nil,
       llm_test_status: :idle,
       llm_test_seq: 0,
       search_query: "",
       preset_dismissed: false
     )
     # The on-mount hooks seed these (NodeAware / Appearance); `assign_new` keeps
     # the render a strict `@key` read without ever overwriting a hook value.
     |> assign_new(:remote_targets, fn -> [] end)
     |> assign_new(:connection_statuses, fn -> %{} end)
     |> assign_new(:session_list, fn -> [] end)
     |> assign_new(:session_list_loading, fn -> false end)
     |> assign_new(:session_list_error, fn -> nil end)
     |> assign_new(:current_session_id, fn -> nil end)
     |> assign_new(:accent_color, fn -> "blue" end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous = socket.assigns.current_node_id
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)

    socket =
      if socket.assigns.current_node_id == previous do
        socket
      else
        # The account list and any sign-in belong to the PREVIOUSLY viewed node.
        viewed = socket

        viewed
        |> assign(:chatgpt_accounts, %{})
        |> assign(:chatgpt_sign_in, ChatGPTSignInState.new())
        |> assign(:chatgpt_sign_in_manual, manual_sign_in?(viewed))
        |> invalidate_test()
      end

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

    {:noreply,
     socket
     |> assign(step: Wizard.prev_step(draft, step), error: nil)
     |> reset_sign_in()}
  end

  def handle_event("wizard_next", _params, socket) do
    %{draft: draft, step: step} = socket.assigns

    case validate_step(step, draft, socket.assigns.chatgpt_accounts) do
      {:error, reason} ->
        {:noreply, assign(socket, error: Presentation.gate_message(reason))}

      :ok ->
        cond do
          step == :test ->
            save_and_finish(socket)

          step == :done ->
            {:noreply, socket}

          true ->
            {:noreply,
             socket
             |> assign(step: Wizard.next_step(draft, step), error: nil)
             |> reset_sign_in()}
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
          |> Wizard.put("auth_mode", auth_mode_for(entry))

        chatgpt? = ChatGPT.provider?(value)

        socket =
          socket
          |> assign(draft: draft, error: nil)
          # The draft restarts at the provider step, so every sign-in state
          # (waiting, ok, error) belongs to the previous run and is dropped.
          |> assign(:chatgpt_sign_in, ChatGPTSignInState.new())
          |> assign(
            :chatgpt_accounts,
            if(chatgpt?, do: ChatGPT.accounts(node()), else: %{})
          )
          |> invalidate_test()

        socket = assign(socket, wizard_active: true)

        if Wizard.valid?(:provider, draft, Wizard.capabilities(draft)) do
          {:noreply, assign(socket, step: Wizard.next_step(draft, :provider))}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("select_wizard_variant", %{"variant" => value}, socket)
      when is_binary(value) do
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

  def handle_event("refresh_chatgpt_setup", _params, socket) do
    {:noreply, assign(socket, :chatgpt_accounts, ChatGPT.accounts(node()))}
  end

  def handle_event("select_chatgpt_account", %{"siwc_account" => account}, socket) do
    %{draft: draft, chatgpt_accounts: accounts} = socket.assigns

    if ChatGPT.provider?(draft["provider"]) and Map.has_key?(accounts, account) do
      draft =
        draft
        |> Wizard.put("siwc_account", account)
        |> reset_model_choices()

      {:noreply, socket |> assign(draft: draft, error: nil) |> invalidate_test()}
    else
      {:noreply, socket}
    end
  end

  # Starts ONE in-browser sign-in for the account the draft already points at
  # (its current pick, else the store's default registration).
  # `ChatGPTSignInState.begin/4` is the SAME lifecycle `/settings` uses: it
  # abandons a previous waiting attempt, starts the poll BEFORE answering (so a
  # result can never arrive while the page is not yet waiting for that flow id)
  # and records the flow's redirect identity (`port`/`mode`) the manual paste
  # fallback explains.
  def handle_event("chatgpt_sign_in", _params, socket) do
    account = ChatGPT.account_name(socket.assigns.draft["siwc_account"])
    state = ChatGPTSignInState.begin(socket.assigns.chatgpt_sign_in, account, :wizard, self())
    {:noreply, assign(socket, :chatgpt_sign_in, state)}
  end

  def handle_event("chatgpt_sign_in_cancel", _params, socket) do
    state = ChatGPTSignInState.cancel(socket.assigns.chatgpt_sign_in)
    {:noreply, assign(socket, :chatgpt_sign_in, state)}
  end

  # The waiting panel's manual "paste the redirect URL" fallback. `/welcome`
  # renders ONE sign-in surface (the wizard's auth step), so the SAME shared
  # transitions `/settings` uses apply: recording the typed text is cheap and
  # never touches the flow, and the submit hands it back to the SAME attempt.
  def handle_event("chatgpt_sign_in_paste", params, socket) do
    state = socket.assigns.chatgpt_sign_in

    state =
      if ChatGPTSignInState.paste_target?(state, :wizard),
        do: ChatGPTSignInState.put_paste(state, Map.get(params, "value")),
        else: state

    {:noreply, assign(socket, :chatgpt_sign_in, state)}
  end

  def handle_event("chatgpt_sign_in_submit", params, socket) do
    state = socket.assigns.chatgpt_sign_in

    state =
      if ChatGPTSignInState.paste_target?(state, :wizard),
        do: ChatGPTSignInState.submit_paste(state, params),
        else: state

    {:noreply, assign(socket, :chatgpt_sign_in, state)}
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

    {:noreply,
     socket |> assign(draft: Wizard.put(draft, "default_model", model)) |> invalidate_test()}
  end

  def handle_event("toggle_wizard_model", %{"model" => model}, socket) when is_binary(model) do
    {:noreply,
     socket
     |> assign(draft: Wizard.toggle_model(socket.assigns.draft, model))
     |> invalidate_test()}
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
    {:noreply,
     socket
     |> assign(draft: Wizard.put(socket.assigns.draft, "api_key", key))
     |> invalidate_test()}
  end

  def handle_event("wizard_field_changed", params, socket) do
    case Map.get(params, "base_url") do
      url when is_binary(url) ->
        {:noreply,
         socket
         |> assign(draft: Wizard.put(socket.assigns.draft, "base_url", url))
         |> invalidate_test()}

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
          Wizard.put(
            draft,
            "model_reasoning",
            merge_model_reasoning(draft, extra, inventory, effort)
          )
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
    draft = socket.assigns.draft

    # The preset id is client input: only a preset the DRAFT's provider
    # publishes may touch its account schedule, so another provider's window
    # can never be applied here.
    if preset_allowed?(socket, draft, preset_id) do
      {draft, _snapshot} = Wizard.apply_preset(draft, preset_id)
      {:noreply, assign(socket, draft: draft, preset_dismissed: false)}
    else
      {:noreply, socket}
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
       chatgpt_sign_in: ChatGPTSignInState.new(),
       has_model?: true
     )
     |> invalidate_test()}
  end

  def handle_event("skip_test", _params, socket), do: save_and_finish(socket)

  def handle_event("test_connection", _params, socket) do
    %{draft: draft} = socket.assigns
    provider = Presentation.provider_entry(socket.assigns.llm_providers, draft["provider"])

    socket = refresh_chatgpt_accounts(socket)

    with {:ok, current} <- Setup.read_config(),
         {:ok, _config, profile, entry, key} <-
           Setup.prepare(current, setup_assigns(socket, provider), draft_params(draft)),
         :ok <- save_key(entry, key, draft["auth_mode"]) do
      seq = socket.assigns.llm_test_seq + 1
      effort = tested_effort(draft, entry)

      runner =
        Application.get_env(:evo_dash, :welcome_llm_test_runner, &EvoGit.SystemCheck.llm_test/2)

      case EvoDash.SafeCall.start(self(), {:welcome_llm_test_result, seq}, fn ->
             {model, opts} = Setup.test_request(profile, entry, effort)
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
           assign(socket,
             llm_test_seq: seq,
             llm_test_status: {:error, Presentation.display_error(reason)}
           )}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, llm_test_status: {:error, Presentation.display_error(reason)})}
    end
  end

  @impl true
  def handle_info({{:welcome_llm_test_result, seq}, guarded}, socket) do
    handle_info({:welcome_llm_test_result, seq, test_answer(guarded)}, socket)
  end

  def handle_info({:welcome_llm_test_result, seq, result}, socket) do
    if seq == socket.assigns.llm_test_seq and socket.assigns.current_node_id == nil do
      status =
        case result do
          {:ok, detail} -> {:ok, detail}
          {:error, reason} -> {:error, Presentation.display_error(reason)}
        end

      {:noreply,
       assign(socket, llm_test_status: status, credentials: EvoGit.Config.credentials())}
    else
      {:noreply, socket}
    end
  end

  # The bounded authorization poll reports exactly one result per flow. A result
  # for a flow this page no longer waits for (cancelled, superseded, or dropped
  # by a step/provider transition) is stale and changes nothing.
  def handle_info({:chatgpt_signin_result, flow_id, result}, socket) do
    if current_sign_in_flow?(socket, flow_id) do
      {:noreply, apply_sign_in_result(socket, result)}
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
  def terminate(_reason, socket) do
    # A page that goes away with a WAITING sign-in must close it now: the poll
    # task dies with its owner, but the loopback listener lives in the flow
    # module until its own timeout. `ChatGPTSignInState.cancel/1` is the SAME
    # entry point `/settings` uses (no second cancel implementation) and is
    # total and quiet — a missing/garbage assign, a non-waiting phase (idle, ok,
    # error) or a flow that is already gone cancels nothing and never raises.
    _state = ChatGPTSignInState.cancel(assigned_sign_in(socket))
    :ok
  end

  @impl true
  def render(assigns) do
    assigns = ViewModel.prepare_view(assigns)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:welcome}
      simple_nav={false}
      current_node_id={@current_node_id}
      remote_targets={@remote_targets}
      connection_statuses={@connection_statuses}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      session_list={@session_list}
      session_list_loading={@session_list_loading}
      session_list_error={@session_list_error}
      current_session_id={@current_session_id}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={@accent_color}
    >
      <div class="min-h-full max-w-3xl mx-auto px-4 lg:px-6 py-4 space-y-5">
        <div class="flex items-center justify-between gap-3">
          <button
            type="button"
            onclick="if (window.history.length > 1) { history.back(); } else { window.location.href = '/'; }"
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />{gettext("Back")}
          </button>
          <button
            :if={
              @current_node_id == nil and not ViewModel.all_set?(@step, @has_model?, @wizard_active)
            }
            phx-click="skip"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Skip")}
          </button>
        </div>

        <div>
          <h1 class="text-xl font-semibold">
            {if ViewModel.all_set?(@step, @has_model?, @wizard_active),
              do: gettext("You're All Set!"),
              else: gettext("Welcome to Genesis")}
          </h1>
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
              <a href={~p"/welcome"} class="btn btn-primary">{gettext("Switch to Local")}</a>
            </div>
          <% ViewModel.all_set?(@step, @has_model?, @wizard_active) -> %>
            <div class="bg-success/10 border border-success/20 rounded-xl p-5 flex gap-3">
              <.icon name="hero-check-circle" class="size-7 text-success" />
              <div class="space-y-2">
                <p class="font-semibold text-success">{gettext("Ready to build!")}</p>
                <p class="text-sm text-base-content/70">
                  {gettext("Your LLM is configured. You can manage it anytime in Settings.")}
                </p>
                <div class="flex flex-wrap gap-2">
                  <button type="button" phx-click="get_started" class="btn btn-primary">
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
              next_label={ViewModel.next_label(@step)}
              next_disabled={validate_step(@step, @draft, @chatgpt_accounts) != :ok}
              cancel_event="skip"
              cancel_label={gettext("Skip")}
              error={@error}
            >
              <%= case @step do %>
                <% :provider -> %>
                  <Steps.step_provider_body
                    provider_options={@provider_options}
                    draft={@draft}
                    variant_options={@variant_options}
                  />
                <% :auth -> %>
                  <Steps.step_auth_body
                    draft={@draft}
                    auth_modes={@auth_modes}
                    oauth_only={@oauth_only?}
                    login_instructions={@login_instructions}
                    key_placeholder={@key_placeholder}
                    key_present={@key_present?}
                    chatgpt={@chatgpt?}
                    chatgpt_accounts={@chatgpt_accounts}
                    chatgpt_sign_in={@chatgpt_sign_in}
                    chatgpt_sign_in_manual={@chatgpt_sign_in_manual}
                  />
                <% :model -> %>
                  <Steps.step_model_body
                    model_rows={@model_rows}
                    all_model_rows={@all_model_rows}
                    draft={@draft}
                    search_query={@search_query}
                    chatgpt={@chatgpt?}
                    api_key_only={@auth_modes == ["api_key"]}
                    key_placeholder={@key_placeholder}
                    key_present={@key_present?}
                  />
                <% :reasoning_schedule -> %>
                  <Steps.step_reasoning_schedule_body
                    inventory={@inventory}
                    default_effort={@default_effort}
                    presets={@presets}
                    preset_applied={@preset_applied}
                    holidays={@holidays}
                    holiday_options={@holiday_options}
                    holiday_help={@holiday_help}
                    schedule_rows={@schedule_rows}
                    inventory_name={@inventory_name}
                    default_name={@default_name}
                    extra_models={@extra_models}
                  />
                <% :test -> %>
                  <Steps.step_test_body llm_test_status={@llm_test_status} />
                <% :done -> %>
                  <Steps.step_done_body summary={@summary} />
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

  # `Setup.auth_mode/1` asks the catalog whether the WIRE provider atom is
  # OAuth-only, so the entry map is resolved to that atom first (a variant can
  # change the wire provider); an unresolvable entry degrades to `nil`, which
  # `Setup.auth_mode/1` treats as API-key.
  defp auth_mode_for(entry) do
    entry
    |> Presentation.wire_atom(Presentation.variant_id(entry, Presentation.first_variant(entry)))
    |> Setup.auth_mode()
  end

  # ── Draft helpers ────────────────────────────────────────────────────────

  defp preset_allowed?(socket, draft, preset_id) do
    provider = Presentation.provider_entry(socket.assigns.llm_providers, draft["provider"])
    variant_id = Presentation.variant_id(provider, draft["variant"])
    Presentation.preset_allowed?(provider, variant_id, preset_id)
  end

  defp invalidate_test(socket) do
    assign(socket, llm_test_seq: socket.assigns.llm_test_seq + 1, llm_test_status: :idle)
  end

  # ── In-browser ChatGPT sign-in ───────────────────────────────────────────

  # `/welcome` configures THIS machine only: its provider preflight and its
  # account list are resolved locally, so a REMOTE-node view (which refuses
  # every mutating event anyway) renders the CLI instruction instead of a
  # button that could never open a loopback listener here.
  defp manual_sign_in?(socket), do: Map.get(socket.assigns, :current_node_id) != nil

  # Dropping the flow id is the WHOLE invalidation: the poll's result is matched
  # against the current flow id, and the flow itself expires on its own window.
  defp reset_sign_in(socket),
    do: assign(socket, :chatgpt_sign_in, ChatGPTSignInState.new())

  # TOTAL: the assigned sign-in state, else the idle state (which cancels
  # nothing). `terminate/2` runs after the socket is gone, so a shape this page
  # never assigns must answer a value instead of raising.
  defp assigned_sign_in(%{assigns: assigns}) when is_map(assigns) do
    case assigns[:chatgpt_sign_in] do
      %{} = state -> state
      _state -> ChatGPTSignInState.new()
    end
  end

  defp assigned_sign_in(_socket), do: ChatGPTSignInState.new()

  defp current_sign_in_flow?(socket, flow_id) do
    is_binary(flow_id) and Map.get(socket.assigns.chatgpt_sign_in, :flow_id) == flow_id
  end

  defp apply_sign_in_result(socket, {:ok, %{account: account}}) when is_binary(account) do
    draft = socket.assigns.draft
    accounts = ChatGPT.accounts(node())
    previous_account = ChatGPT.account_name(draft["siwc_account"])

    # The account's nested model inventory is account-scoped, so a registration
    # installed under a DIFFERENT name than the draft's pick drops the model
    # choices — exactly like `select_chatgpt_account`.
    draft =
      draft
      |> Wizard.put("siwc_account", account)
      |> maybe_reset_model_choices(previous_account)

    socket
    |> assign(:chatgpt_accounts, accounts)
    |> assign(:draft, draft)
    |> assign(:chatgpt_sign_in, sign_in_phase(socket, :ok, nil))
    # A connection test started against the previous authentication state can no
    # longer describe what is about to be saved.
    |> invalidate_test()
  end

  defp apply_sign_in_result(socket, {:error, reason}),
    do: assign(socket, :chatgpt_sign_in, sign_in_phase(socket, :error, reason))

  defp apply_sign_in_result(socket, _unexpected),
    do: assign(socket, :chatgpt_sign_in, sign_in_phase(socket, :error, :sign_in_unavailable))

  # The terminal phase keeps the flow's redirect identity (`port`/`mode`) and
  # the wizard surface, and clears the manual-fallback input: a finished attempt
  # has nothing left to paste into.
  defp sign_in_phase(socket, phase, reason) do
    socket
    |> assigned_sign_in()
    |> Map.merge(%{phase: phase, reason: reason, paste: "", paste_error: nil})
  end

  defp maybe_reset_model_choices(draft, previous_account) do
    if ChatGPT.account_name(draft["siwc_account"]) == previous_account,
      do: draft,
      else: reset_model_choices(draft)
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
      # An extra model's select submits only its default, so the recorded
      # inventory is read back through the shared unwrap (never dropped) and the
      # submitted value is accepted in either recorded shape.
      entry = Map.get(acc, model)

      Map.put(acc, model, %{
        "efforts" => Wizard.model_effort_inventory(entry),
        "default" => Wizard.model_default_effort(value)
      })
    end)
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
    setup = setup_assigns(refresh_chatgpt_accounts(socket), provider)

    with {:ok, current} <- Setup.read_config(),
         {:ok, config, _profile, entry, key} <- Setup.prepare(current, setup, draft_params(draft)),
         :ok <- save_key(entry, key, setup.auth_mode),
         :ok <- Setup.write(fn -> EvoGit.Config.save_user_config(config) end) do
      config = ConfigIO.load_file_config()

      socket =
        socket
        |> assign(
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
    _ = ConfigIO.update_runtime_from_file_config(config, socket)
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
      flat_models: selected_model_catalog(socket, draft),
      siwc_account: selected_chatgpt_account(socket, draft),
      default_model: draft["default_model"],
      schedule: ensure_map(draft["schedule"])
    }
  end

  defp validate_step(:auth, %{"provider" => "openai_codex"} = draft, accounts) do
    if Map.has_key?(accounts, ChatGPT.account_name(draft["siwc_account"])),
      do: :ok,
      else: {:error, :chatgpt_login_required}
  end

  defp validate_step(step, draft, _accounts),
    do: Wizard.validate(step, draft, Wizard.capabilities(draft))

  defp refresh_chatgpt_accounts(%{assigns: %{draft: %{"provider" => "openai_codex"}}} = socket),
    do: assign(socket, :chatgpt_accounts, ChatGPT.accounts(node()))

  defp refresh_chatgpt_accounts(socket), do: socket

  defp selected_model_catalog(socket, %{"provider" => "openai_codex"} = draft),
    do: Setup.chatgpt_models(socket.assigns.chatgpt_accounts, draft["siwc_account"])

  defp selected_model_catalog(socket, _draft), do: socket.assigns.flat_models

  defp selected_chatgpt_account(socket, %{"provider" => "openai_codex"} = draft) do
    account = ChatGPT.account_name(draft["siwc_account"])
    if Map.has_key?(socket.assigns.chatgpt_accounts, account), do: account
  end

  defp selected_chatgpt_account(_socket, _draft), do: nil

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

  # `SafeCall` wraps the provider's OWN `{:ok, detail} | {:error, message}`
  # answer, so exactly one level is unwrapped: only a genuine provider success
  # may render success, and a provider-side `{:error, message}` stays an error.
  defp test_answer({:ok, {:ok, detail}}), do: {:ok, detail}
  defp test_answer({:ok, {:error, reason}}), do: {:error, reason}
  defp test_answer({:ok, other}), do: {:error, {:unexpected_result, other}}
  defp test_answer({:error, reason}), do: {:error, reason}
  defp test_answer(other), do: {:error, other}

  # The reasoning level the SAVE path will persist for the tested model, read
  # through the SAME unwrap (`Wizard.model_default_effort/2`) the model row and
  # the reasoning select use — so "Test connection" exercises the configuration
  # that is about to be written. `""` (the user kept "Provider default") sends
  # no `reasoning_effort` at all.
  defp tested_effort(draft, entry) do
    Wizard.model_default_effort(draft, Setup.value(entry, :model_string))
  end

  # ── Small total helpers ──────────────────────────────────────────────────

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_map), do: %{}
end
