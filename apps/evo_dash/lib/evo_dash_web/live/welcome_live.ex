defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Local-only onboarding for a provider profile with multiple models, a default
  model and per-model reasoning defaults, using API-key or subscription auth.
  """
  use EvoDashWeb, :live_view

  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.WelcomeLive.Setup
  alias EvoGit.Config.LLMCatalog, as: Catalog

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
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <div class="min-h-screen max-w-5xl mx-auto px-4 lg:px-6 py-4 space-y-5">
        <button
          type="button"
          onclick="if (window.history.length > 1) { history.back(); } else { window.location.href = '/'; }"
          class="btn btn-ghost btn-sm gap-2"
        >
          <.icon name="hero-arrow-left" class="size-4" />{gettext("Back")}
        </button>
        <header>
          <h2 class="text-xl font-bold">
            {if @has_model?, do: gettext("You're All Set!"), else: gettext("Welcome to Genesis")}
          </h2>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext("Configure a provider and its models to start building with Genesis.")}
          </p>
        </header>

        <%= cond do %>
          <% @current_node_id != nil -> %>
            <div class="alert alert-info">
              {gettext(
                "Welcome setup configures this machine only. Switch to Local or use Settings for the remote node."
              )}
            </div>
            <a href={~p"/welcome"} class="btn btn-primary btn-sm">{gettext("Switch to Local")}</a>
          <% @has_model? -> %>
            <div class="bg-success/10 border border-success/20 rounded-lg p-5 flex gap-3">
              <.icon name="hero-check-circle" class="size-7 text-success" />
              <div>
                <p class="font-bold text-success">{gettext("Ready to build!")}</p>
                <p class="text-sm text-base-content/70">
                  {gettext("Your LLM is configured. You can manage it anytime in Settings.")}
                </p>
              </div>
            </div>
            <div class="flex gap-3">
              <button phx-click="get_started" class="btn btn-primary btn-sm">{gettext(
                "Go to Dashboard"
              )}</button>
              <a href={~p"/settings"} class="btn btn-ghost btn-sm">{gettext("Open Settings")}</a>
            </div>
          <% true -> %>
            <section class="space-y-3">
              <h3 class="text-lg font-bold">{gettext("Add your first LLM")}</h3>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "Pick a provider, select one or more models, then choose API key or subscription authentication."
                )}
              </p>
              <p class="text-xs font-bold uppercase text-base-content/70">
                {gettext("Choose a provider:")}
              </p>
              <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-2">
                <%= for provider <- welcome_providers(@llm_providers) do %>
                  <button
                    type="button"
                    phx-click="select_welcome_provider"
                    phx-value-provider_id={provider.id}
                    class={[
                      "btn btn-sm h-auto py-2 text-left",
                      @selected_provider_id == provider.id && "btn-primary",
                      @selected_provider_id != provider.id &&
                        "btn-ghost bg-primary/10 text-primary-standalone"
                    ]}
                  >
                    {t_provider(provider.display_name)}
                  </button>
                <% end %>
              </div>

              <%= if @selected_provider_id do %>
                <% provider = Enum.find(@llm_providers, &(&1.id == @selected_provider_id)) %>
                <%= if provider[:variants] do %>
                  <p class="text-xs font-bold text-base-content/70">{gettext("Select a variant:")}</p>
                  <div class="flex flex-wrap gap-2">
                    <%= for variant <- provider.variants do %>
                      <button
                        type="button"
                        phx-click="select_welcome_variant"
                        phx-value-variant_id={variant.id}
                        class={["btn btn-xs", @selected_variant_id == variant.id && "btn-secondary"]}
                      >{variant.display_name}</button>
                    <% end %>
                  </div>
                <% end %>
                <form id="welcome-search" phx-submit="noop">
                  <input
                    type="search"
                    name="search_query"
                    value={@search_query}
                    phx-change="search_models"
                    phx-debounce="150"
                    placeholder={gettext("Search models…")}
                    class="input input-bordered w-full"
                  />
                </form>
                <p class="text-xs font-bold text-base-content/70">{gettext("Choose a model:")}</p>
                <% entries =
                  Setup.provider_models(@flat_models, @selected_provider_id, @selected_variant_id) %>
                <% filtered = Setup.filtered_models(entries, @search_query) %>
                <%= if filtered == [] do %>
                  <p class="text-sm text-base-content/70 py-4">
                    {gettext("No models match your search.")}
                  </p>
                <% else %>
                  <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-2">
                    <%= for entry <- filtered do %>
                      <% selected = entry.model_string in @selected_models %>
                      <button
                        type="button"
                        phx-click="select_welcome_model"
                        phx-value-model_string={entry.model_string}
                        aria-pressed={to_string(selected)}
                        class={[
                          "btn btn-xs h-auto py-2 flex-col items-start text-left",
                          selected && "btn-primary",
                          !selected && "btn-ghost bg-primary/10 text-primary-standalone"
                        ]}
                      >
                        <span>{entry.model_display_name}</span>
                        <%= if entry.variant_display_name do %>
                          <span class="text-xs">{t_provider(entry.provider_display_name)} · {entry.variant_display_name}</span>
                        <% end %>
                      </button>
                    <% end %>
                  </div>
                <% end %>
                <p class="text-xs text-base-content/70">
                  {gettext("Need a custom model or advanced settings?")}
                  <a href={~p"/settings"} class="link link-primary">{gettext("Settings page")}</a>
                </p>
              <% end %>
            </section>

            <%= if @selected_entry do %>
              <section class="bg-base-200 border border-base-300 rounded-lg p-5 space-y-4">
                <form id="welcome-defaults" phx-change="welcome_defaults_changed" class="space-y-3">
                  <label class="block text-sm font-semibold" for="welcome-default-model">{gettext(
                    "Default model"
                  )}</label>
                  <select
                    id="welcome-default-model"
                    name="default_model"
                    class="select select-bordered w-full"
                  >
                    <%= for entry <- selected_entries(assigns) do %>
                      <option
                        value={entry.model_string}
                        selected={@default_model == entry.model_string}
                      >
                        {entry.model_display_name}
                      </option>
                    <% end %>
                  </select>
                  <%= for entry <- selected_entries(assigns) do %>
                    <label class="block text-sm text-base-content/80">
                      {gettext("Default reasoning for %{model}", model: entry.model_display_name)}
                      <select
                        name={"reasoning[#{entry.model_string}]"}
                        class="select select-bordered select-sm w-full mt-1"
                      >
                        <option
                          value=""
                          selected={Map.get(@model_reasoning, entry.model_string, "") == ""}
                        >
                          {gettext("Provider default")}
                        </option>
                        <%= for effort <- reasoning_choices(entry) do %>
                          <option
                            value={effort}
                            selected={Map.get(@model_reasoning, entry.model_string) == effort}
                          >
                            {effort}
                          </option>
                        <% end %>
                      </select>
                    </label>
                  <% end %>
                </form>

                <%= if Catalog.supports_oauth?(@selected_entry.resolved_atom) do %>
                  <%= if Catalog.oauth_only?(@selected_entry.resolved_atom) do %>
                    <span class="badge badge-info">{gettext("Subscription (OAuth)")}</span>
                  <% else %>
                    <form id="welcome-auth" phx-change="welcome_auth_changed">
                      <label class="block text-sm font-semibold" for="welcome-auth-mode">{gettext(
                        "Authentication"
                      )}</label>
                      <select
                        id="welcome-auth-mode"
                        name="auth_mode"
                        class="select select-bordered w-full"
                      >
                        <option value="api_key" selected={@auth_mode == "api_key"}>
                          {gettext("API key")}
                        </option>
                        <option value="oauth" selected={@auth_mode == "oauth"}>
                          {gettext("Subscription (OAuth)")}
                        </option>
                      </select>
                    </form>
                  <% end %>
                <% end %>
                <%= if @auth_mode == "oauth" do %>
                  <p class="text-sm text-base-content/80">
                    {gettext(
                      "Log in once with the vendor CLI on this machine, then test the connection. No API key is required."
                    )}
                  </p>
                  <pre class="text-xs whitespace-pre-wrap bg-base-100 p-3 rounded-md">{EvoGit.Auth.login_instructions(@selected_entry.resolved_atom)}</pre>
                <% end %>

                <% key_is_set = Map.get(@credentials, @selected_entry.credential_key) not in [nil, ""] %>
                <% can_save = Setup.can_save?(assigns) %>
                <form id="welcome-save" phx-submit="save_welcome_setup" class="space-y-3">
                  <%= if @auth_mode == "api_key" do %>
                    <label class="block text-sm font-semibold" for="welcome-api-key">
                      {gettext("Enter your API key")} · {@selected_entry.credential_key}
                      <%= if key_is_set do %>
                        <span class="text-success">✓ {gettext("Set")}</span>
                      <% end %>
                    </label>
                    <input
                      id="welcome-api-key"
                      type="password"
                      name="api_key"
                      phx-change="api_key_changed"
                      value={@api_key_input}
                      placeholder={
                        if key_is_set,
                          do: gettext("API key is already set"),
                          else: gettext("Enter your API key")
                      }
                      class="input input-bordered w-full"
                    />
                    <p class="text-xs text-base-content/70">
                      {gettext("Enter your API key for %{provider}.",
                        provider: t_provider(@selected_entry.provider_display_name)
                      )}
                    </p>
                  <% end %>
                  <%= if Catalog.requires_base_url?(@selected_entry.provider_id) do %>
                    <label class="block text-sm font-semibold">{gettext("Base URL")}</label>
                    <input
                      type="url"
                      name="base_url"
                      phx-change="base_url_changed"
                      value={@base_url_input}
                      placeholder={gettext("https://...")}
                      class="input input-bordered w-full"
                    />
                    <p class="text-xs text-base-content/70">
                      {gettext("Required for this provider.")}
                    </p>
                  <% else %>
                    <input type="hidden" name="base_url" value={@base_url_input} />
                  <% end %>
                  <button type="submit" disabled={!can_save} class="btn btn-primary btn-sm w-full">{gettext(
                    "Save provider and models"
                  )}</button>
                </form>
                <div class="border-t border-base-300 pt-3">
                  <%= case @llm_test_status do %>
                    <% :testing -> %>
                      <p class="text-sm text-base-content/80">
                        <span class="loading loading-spinner loading-sm"></span> {gettext(
                          "Testing LLM connection..."
                        )}
                      </p>
                    <% {:ok, _} -> %>
                      <p class="text-sm text-success">
                        {gettext("Connected")} ({@selected_entry.model_display_name})
                      </p>
                    <% {:error, reason} -> %>
                      <p class="text-sm text-error">{reason}</p>
                    <% _ -> %>
                  <% end %>
                  <button
                    type="button"
                    phx-click="test_llm"
                    disabled={!can_save or @llm_test_status == :testing}
                    class="btn btn-ghost btn-sm gap-2 w-full"
                  >
                    <.icon name="hero-signal" class="size-4" />{gettext("Test Connection")}
                  </button>
                </div>
              </section>
            <% else %>
              <p class="text-sm text-base-content/70">
                {gettext("Select a provider and models above to configure authentication.")}
              </p>
            <% end %>
        <% end %>
        <button phx-click="skip" class="btn btn-ghost btn-sm">{gettext("Skip")}</button>
        <footer class="text-xs text-base-content/60">
          {gettext("Genesis %{version}", version: @current_version)}
        </footer>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

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
       search_query: "",
       selected_provider_id: nil,
       selected_variant_id: nil,
       selected_entry: nil,
       selected_models: [],
       default_model: nil,
       model_reasoning: %{},
       auth_mode: "api_key",
       api_key_input: "",
       base_url_input: "",
       llm_test_status: :idle,
       llm_test_seq: 0,
       current_version: Application.spec(:evo_git, :vsn) |> to_string()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous = socket.assigns.current_node_id
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)

    socket =
      if previous == socket.assigns.current_node_id, do: socket, else: invalidate_test(socket)

    {:noreply, socket}
  end

  # Onboarding is deliberately local-only. In particular a disconnected remote
  # target resolving temporarily to node() must never write the local config.
  @impl true
  def handle_event(event, _params, %{assigns: %{current_node_id: id}} = socket)
      when not is_nil(id) and event not in ["skip", "get_started", "noop"] do
    {:noreply, put_flash(socket, :error, gettext("Use Settings to configure the remote node."))}
  end

  def handle_event("noop", _, socket), do: {:noreply, socket}

  def handle_event("search_models", params, socket),
    do: {:noreply, assign(socket, :search_query, params["search_query"] || "")}

  def handle_event("api_key_changed", params, socket) do
    {:noreply, socket |> invalidate_test() |> assign(:api_key_input, params["api_key"] || "")}
  end

  def handle_event("base_url_changed", params, socket) do
    {:noreply, socket |> invalidate_test() |> assign(:base_url_input, params["base_url"] || "")}
  end

  def handle_event("select_welcome_provider", params, socket) do
    provider =
      Enum.find(
        welcome_providers(socket.assigns.llm_providers),
        &(Atom.to_string(&1.id) == params["provider_id"])
      )

    if provider do
      variant =
        case provider[:variants] do
          [first | _] -> first.id
          _ -> nil
        end

      {:noreply, reset_selection(socket, provider.id, variant)}
    else
      {:noreply, put_flash(socket, :error, gettext("Unknown provider."))}
    end
  end

  def handle_event("select_welcome_variant", params, socket) do
    provider =
      Enum.find(socket.assigns.llm_providers, &(&1.id == socket.assigns.selected_provider_id))

    variant =
      Enum.find(
        (provider && provider[:variants]) || [],
        &(Atom.to_string(&1.id) == params["variant_id"])
      )

    {:noreply, if(variant, do: reset_selection(socket, provider.id, variant.id), else: socket)}
  end

  def handle_event("select_welcome_model", params, socket) do
    entries =
      Setup.provider_models(
        socket.assigns.flat_models,
        socket.assigns.selected_provider_id,
        socket.assigns.selected_variant_id
      )

    entry = Enum.find(entries, &(&1.model_string == params["model_string"]))

    if entry do
      selected = socket.assigns.selected_models

      selected =
        if entry.model_string in selected,
          do: List.delete(selected, entry.model_string),
          else: selected ++ [entry.model_string]

      default =
        if socket.assigns.default_model in selected,
          do: socket.assigns.default_model,
          else: List.first(selected)

      default_entry = Enum.find(entries, &(&1.model_string == default))

      {:noreply,
       socket
       |> invalidate_test()
       |> assign(
         selected_models: selected,
         default_model: default,
         selected_entry: default_entry,
         model_reasoning: Map.take(socket.assigns.model_reasoning, selected)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("welcome_defaults_changed", params, socket) do
    default = Map.get(params, "default_model", socket.assigns.default_model)
    reasoning = Map.get(params, "reasoning", socket.assigns.model_reasoning)
    selected = socket.assigns.selected_models

    if default in selected and is_map(reasoning) and
         Enum.all?(reasoning, fn {model, effort} ->
           entry = Enum.find(socket.assigns.flat_models, &(&1.model_string == model))

           model in selected and not is_nil(entry) and
             effort in ["" | reasoning_choices(entry)]
         end) do
      entry = Enum.find(socket.assigns.flat_models, &(&1.model_string == default))

      {:noreply,
       socket
       |> invalidate_test()
       |> assign(default_model: default, selected_entry: entry, model_reasoning: reasoning)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("welcome_auth_changed", %{"auth_mode" => mode}, socket) do
    entry = socket.assigns.selected_entry

    if entry && mode in ["api_key", "oauth"] && Catalog.supports_oauth?(entry.resolved_atom) &&
         not Catalog.oauth_only?(entry.resolved_atom) do
      {:noreply, socket |> invalidate_test() |> assign(auth_mode: mode, api_key_input: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_welcome_setup", params, socket) do
    with {:ok, current} <- Setup.read_config(),
         {:ok, config, _profile, entry, key} <- Setup.prepare(current, socket.assigns, params),
         :ok <- save_key(entry, key, socket.assigns.auth_mode),
         :ok <- Setup.write(fn -> EvoGit.Config.save_user_config(config) end) do
      config = ConfigIO.load_file_config()

      socket =
        socket
        |> invalidate_test()
        |> assign(
          file_config: config,
          has_model?: true,
          api_key_input: "",
          credentials: EvoGit.Config.credentials()
        )

      {:noreply,
       config
       |> ConfigIO.update_runtime_from_file_config(socket)
       |> put_flash(:info, gettext("Provider and models saved. You're all set!"))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, display_error(reason))}
    end
  end

  def handle_event("test_llm", _params, socket) do
    with {:ok, current} <- Setup.read_config(),
         {:ok, _config, profile, entry, key} <- Setup.prepare(current, socket.assigns, %{}),
         :ok <- save_key(entry, key, socket.assigns.auth_mode) do
      seq = socket.assigns.llm_test_seq + 1
      reasoning = socket.assigns.model_reasoning

      started =
        EvoDash.SafeCall.start(self(), {:welcome_llm_test_result, seq}, fn ->
          {model, opts} = Setup.test_request(profile, entry, reasoning)

          runner =
            Application.get_env(
              :evo_dash,
              :welcome_llm_test_runner,
              &EvoGit.SystemCheck.llm_test/2
            )

          runner.(model, opts)
        end)

      status =
        case started do
          {:ok, _pid} -> :testing
          {:error, reason} -> {:error, display_error(reason)}
        end

      {:noreply,
       assign(socket,
         llm_test_seq: seq,
         llm_test_status: status,
         api_key_input: "",
         credentials: EvoGit.Config.credentials()
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, display_error(reason))}
    end
  end

  def handle_event(event, _, socket) when event in ["skip", "get_started"] do
    {:noreply, redirect(socket, to: "/welcome/complete")}
  end

  @impl true
  def handle_info({{:welcome_llm_test_result, seq}, guarded}, socket) do
    result =
      case guarded do
        {:ok, value} -> value
        {:error, reason} -> {:error, reason}
      end

    handle_info({:welcome_llm_test_result, seq, result}, socket)
  end

  def handle_info({:welcome_llm_test_result, seq, result}, socket) do
    if seq == socket.assigns.llm_test_seq and socket.assigns.current_node_id == nil do
      status =
        case result do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, display_error(reason)}
          other -> {:error, display_error(other)}
        end

      {:noreply, assign(socket, :llm_test_status, status)}
    else
      {:noreply, socket}
    end
  end

  # Old/unscoped results cannot establish connectivity for the current draft.
  def handle_info({:llm_test_result, _}, socket), do: {:noreply, socket}

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

  defp reset_selection(socket, provider, variant) do
    socket
    |> invalidate_test()
    |> assign(
      selected_provider_id: provider,
      selected_variant_id: variant,
      selected_entry: nil,
      selected_models: [],
      default_model: nil,
      model_reasoning: %{},
      auth_mode: Setup.auth_mode(provider),
      api_key_input: "",
      base_url_input: "",
      search_query: ""
    )
  end

  defp invalidate_test(socket),
    do: assign(socket, llm_test_seq: socket.assigns.llm_test_seq + 1, llm_test_status: :idle)

  # An empty inventory is unrestricted, not unsupported. Expand it only for
  # display and event validation; Setup keeps [] in the persisted model row.
  defp reasoning_choices(entry) do
    case Setup.reasoning_efforts(entry) do
      [] -> Setup.reasoning_efforts()
      efforts -> efforts
    end
  end

  defp selected_entries(assigns),
    do: Enum.filter(assigns.flat_models, &(&1.model_string in assigns.selected_models))

  defp welcome_providers(providers),
    do:
      providers
      |> Enum.reject(&(&1[:custom_model] == true))
      |> Enum.sort_by(&String.downcase(&1.display_name))

  # Provider names retain the existing localized brand labels.
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
  defp t_provider(name), do: name

  defp save_key(_, _, "oauth"), do: :ok
  defp save_key(_, "", _), do: :ok

  defp save_key(entry, key, _),
    do: Setup.write(fn -> EvoGit.Config.save_credentials(%{entry.credential_key => key}) end)

  defp display_error(reason) when is_binary(reason), do: reason

  defp display_error(reason),
    do: gettext("Configuration or connection failed: %{reason}", reason: inspect(reason))
end
