defmodule EvoDashWeb.SettingsLive do
  @moduledoc """
  Settings page with two tabs: runtime scheduler/sandbox controls and a
  GUI editor for the user configuration file (config.toml).

  This module is the page's stateful ORCHESTRATOR: it owns the HEEx shell, the
  mount/`handle_params` assign flow (built by
  `EvoDashWeb.SettingsLive.PageState`) and the routing of every event/message to
  the module that owns it. The extracted concerns are:

    * `PageState` — mount assign construction, config-scope transitions and the
      node-aware read helpers;
    * `CategoryEvents` — the generic category/config event vocabulary plus the
      single `persist_file_config/4` write path and its receipts;
    * `LlmTestEvents` — the LLM connection-test flow;
    * `RemoteEvents` — the remote-connection surface and bootstrap progress;
    * `RemotePanel` — the `:remote_connections` category HEEx and its
      render-only helpers;
    * `AsyncResults` — every async result and broadcast the page consumes.
  """

  use EvoDashWeb, :live_view

  alias EvoGit.Config.Schema
  alias EvoDashWeb.SettingsLive.AsyncResults
  alias EvoDashWeb.SettingsLive.AuthStatus
  alias EvoDashWeb.SettingsLive.CategoryEvents
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ConfigSave
  alias EvoDashWeb.SettingsLive.CustomAgentEvents
  alias EvoDashWeb.SettingsLive.LlmTestEvents
  alias EvoDashWeb.SettingsLive.ModelProfileEvents
  alias EvoDashWeb.SettingsLive.Navigation
  alias EvoDashWeb.SettingsLive.PageState
  alias EvoDashWeb.SettingsLive.ProviderPanelEvents
  alias EvoDashWeb.SettingsLive.RemoteEvents
  alias EvoDashWeb.SettingsLive.RemotePanel
  alias EvoDashWeb.SettingsLive.SearchEvents

  # This deliberately long page keeps the Settings shell/HEEx and node-aware
  # transport boundary together; detached editors, parsing and loaders live in
  # settings_live/. Canonical UI event aliases belong here, not in those helpers.

  # Tag for the async node-data load result message (see
  # EvoDashWeb.SettingsLive.NodeData). Tests that deliver results
  # deterministically must use this same atom; `PageState` owns it.
  @node_data_tag PageState.node_data_tag()

  # The event vocabularies each extracted module owns (one routing clause each).
  @category_events CategoryEvents.events()
  @llm_test_events LlmTestEvents.events()
  @remote_events RemoteEvents.events()

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:settings}
      workbench_window={@live_action == :window}
      remote_targets={assigns[:remote_targets] || []}
      connection_statuses={assigns[:connection_statuses] || %{}}
      config_status={@config_status}
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
      <header :if={@live_action == :window} class="workbench-window-header">
        <h1 class="min-w-0 flex-1 text-sm font-semibold">{gettext("Settings")}</h1>
        <.form
          :if={!Navigation.client_category?(@active_category)}
          for={@settings_server_form}
          id="workbench-settings-server-form"
          phx-change="select_settings_server"
          class="workbench-settings-server-picker"
        >
          <.input
            field={@settings_server_form[:node]}
            type="select"
            label={gettext("Settings server")}
            options={
              [{gettext("Local"), "local"}] ++
                Enum.map(@remote_targets, &{&1.name, &1.id})
            }
            class="select select-sm"
          />
        </.form>
      </header>
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <div class={[
          "flex flex-col min-h-0",
          if(@live_action == :window, do: "flex-1", else: "md:h-full")
        ]}>
          <%!-- ConfigSave runs local and remote writes outside the LiveView.
           Keep feedback visible until the owned settings_config_saved result
           settles, rather than relying on the Save button's pending state. --%>
          <%= if @config_saving do %>
            <div
              id="settings-config-saving"
              class="mb-4 shrink-0 rounded-lg border border-base-300 bg-base-100 p-3 flex items-center gap-3"
            >
              <span class="loading loading-spinner loading-sm text-primary-standalone"></span>
              <span class="text-sm font-medium text-base-content/80">
                {gettext("Saving configuration…")}
              </span>
            </div>
          <% end %>

          <%!-- Config Status Warning --%>
          <%= if @config_status && not @config_status.ok? do %>
            <div class="mb-4 shrink-0 rounded-lg border border-warning/30 bg-warning/5 p-3 flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
              <div>
                <h3 class="font-bold text-sm text-warning mb-2">
                  {gettext("Missing Configuration")}
                </h3>
                <ul class="space-y-1.5 mb-3">
                  <%= for line <- EvoDashWeb.ConfigIssues.lines(@config_status) do %>
                    <li class="text-sm font-medium text-warning/80 flex items-start gap-2">
                      <.icon name="hero-chevron-right" class="size-4 mt-0.5 shrink-0 opacity-70" />
                      <span>{line}</span>
                    </li>
                  <% end %>
                </ul>
                <p class="text-sm font-semibold text-base-content/80">
                  <%= if EvoDashWeb.ConfigIssues.model_unconfigured?(@config_status) do %>
                    {gettext("Configure your LLM model in the LLM category to resolve these issues.")}
                  <% else %>
                    <%!-- zh_CN: "the settings listed above" 指上方列出的配置项（含 schema 校验错误），
                      不一定只是缺失值，也可能只是取值无效（例如时区/并发数）。 --%>
                    {gettext("Fix the settings listed above to resolve these issues.")}
                  <% end %>
                </p>
              </div>
            </div>
          <% end %>

          <%!-- Remote config load error — the remote node's config could not be
           fetched (node unreachable, RPC failure, ...). Shown INSTEAD of the
           "No LLM Model Configured" warning below so the user sees the real
           problem rather than a bogus unconfigured-model message. --%>
          <%= if @remote_config_error do %>
            <div class="mb-4 shrink-0 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
              <div>
                <h3 class="font-bold text-sm text-error mb-2">
                  {gettext("Remote Configuration Unavailable")}
                </h3>
                <p class="text-sm font-medium text-error/80 leading-relaxed max-w-3xl">
                  {@remote_config_error}
                </p>
              </div>
            </div>
          <% end %>

          <%!-- No LLM Model Warning (gated off while a remote config load error is
           shown — otherwise "No LLM Model Configured" would render on top of
           the real problem) --%>
          <%= if @remote_config_error == nil and ConfigIO.model_selections(@file_config) == [] do %>
            <div class="mb-4 shrink-0 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
              <div>
                <h3 class="font-bold text-sm text-error mb-2">
                  {gettext("No LLM Model Configured")}
                </h3>
                <p class="text-sm font-medium text-error/80 mb-3 leading-relaxed max-w-3xl">
                  {gettext(
                    "Agents cannot run until you set a model. Go to the LLM category and fill in the Model field."
                  )}
                </p>
                <div class="flex items-center gap-3 flex-wrap">
                  <span class="text-xs font-bold uppercase tracking-wider text-base-content/70">{gettext(
                    "Example model names:"
                  )}</span>
                  <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">anthropic:claude-opus-5-5</span>
                  <span class="badge badge-ghost font-mono text-xs px-3 py-2 rounded-md bg-base-200 border-base-300">openai:gpt-5.6-terra</span>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Settings card: two-column sidebar + content layout.

             md+ INDEPENDENT-SCROLL HEIGHT CHAIN: `#main-content` (layouts.ex)
             is `flex-1 min-h-0` inside the `h-dvh` app shell, so this
             wrapper's `md:h-full` is bounded to the shell content box
             (viewport minus the persistent top bar and the main padding);
             the two-column row below is `md:flex-1 md:min-h-0`. The sidebar
             (sidebar.ex — `md:h-full` bounded column whose `flex-1
             overflow-y-auto min-h-0` nav scrolls on its own) and each
             content column are bounded by that row and scroll independently
             of the outer page. TWO height rules govern the content columns
             (full detail: `components/CONTEXT.md` → "Settings two-column
             layout"):

             (1) A content-column root must NEVER carry `h-full` — the row
             has no definite `height` property (it is flex-sized), so a
             percentage `h-full` resolves to auto → the column grows to its
             content → the whole page inflates past the viewport → the BODY
             scrolls and the two panes scroll LINKED instead of
             independently. Content columns are sized by `flex-1` ALONE
             (+ `overflow-y-auto` on the column or its inner scroll div).

             (2) Every main-axis (column-direction) NON-scroll flex item
             between the bounded column and the inner scroll container MUST
             carry `min-h-0` — a non-scroll flex item defaults to
             `min-height: auto` (the content-based automatic minimum, which
             INCLUDES the overflow content of a nested `overflow-y-auto`
             body), so it cannot shrink below its content and the inner
             scroll body never engages; content spills to `#main-scroll`
             and the panes scroll LINKED.

             Every category column now has ONE unified shape
             (components/settings_components.ex `category_section/1`): a
             root `<div class="flex-1 flex flex-col min-w-0 min-h-0
             bg-base-100" id="category-<cat>">` → `.section_header` top
             sibling → a scroll body `<div class="flex-1 overflow-y-auto
             px-8 py-8 relative">` that owns the pane scroll and holds all
             config content → ONE minimal pinned bottom-right save bar
             (`.save_bar`: `shrink-0 sticky bottom-0 z-10` container,
             `btn btn-primary rounded-md min-w-32 font-bold` +
             document-check icon) as a NON-scrolling flex sibling of that
             scroll body. How the rules land on the actual shapes:

             The GENERIC categories' `save_category` `<.form>` (class
             `flex-1 flex flex-col min-w-0 min-h-0 relative`, id
             `settings-form-<cat>`) wraps the scroll body AND a nested
             `<.save_bar>` — the form is the main-axis non-scroll flex item
             between the `category_section` root and the inner scroll body,
             so BOTH the form and the section root carry `min-h-0`. The
             `:llm` category instead keeps its flat `<.form
             id="settings-form-llm">` (hidden category input + flat setting
             cards such as compression_threshold_tokens) INSIDE the scroll
             body (its old in-form save bar is gone); its pinned `<.save_bar
             form={"settings-form-#{@category}"} ...>` is a direct child of
             the column root AFTER the scroll body — OUTSIDE the form,
             submitting it via the HTML `form` association attribute (safe
             because LiveView binds window-level submit listeners on the
             form target). LLM's scroll body is still a DIRECT child of the
             column root, so it needs no intermediate `min-h-0` (a scroll
             container's own automatic min size is 0) — that part of the
             old reasoning stays true. search (the `<.form
             id="settings-form-search">`, whose class string
             `flex-1 flex flex-col min-w-0 overflow-y-auto relative` is
             TEST-PINNED) and the `:remote_connections`/`:agents`
             pseudo-category shells (both `<div class="flex-1 flex flex-col
             min-w-0 overflow-y-auto">`) work because the column/form ITSELF
             is the scroll container — no intermediate `min-h-0` needed
             there, and they deliberately carry NO category-wide save bar
             (their actions are per-item inline form actions).

             The `.section_header` (`sticky top-0`) is the top non-scroll
             sibling: in the self-scrolling search/
             `:remote_connections`/`:agents` columns it sticks within that
             column's own scroll, and in the category_section shape it never
             scrolls away because the inner scroll body scrolls beneath it.
             The save bar's own `sticky bottom-0 z-10` is load-bearing only
             where the bar sits INSIDE a scrolling container (the
             SearchResults bar lives inside `settings-form-search`); it is
             inert-but-harmless elsewhere. Below md the row stacks naturally
             and the whole page scrolls via `#main-scroll`. Warning banners
             above are direct children of the wrapper (shrink-0 so they
             never squish). Note: after editing Tailwind classes here,
             rebuild assets with `mix tailwind evo_dash` (dev) or
             `mix assets.deploy` (prod) — the CSS build
             (`priv/static/assets/css/`) is gitignored, so a stale bundle
             silently no-ops new utility classes. --%>
          <%!-- Two-column sidebar + content layout --%>
          <div class="flex flex-col md:flex-row md:flex-1 md:min-h-0 bg-base-100">
            <%!-- Sidebar --%>
            <EvoDashWeb.SettingsComponents.settings_sidebar
              window={@live_action == :window}
              categories={@schemas_by_category}
              active_category={@active_category}
              search_text={@search_text}
              config_path={@config_path}
              config_file_exists={@config_file_exists}
            />

            <%!-- Content area --%>
            <%= if @search_text != "" do %>
              <.form
                for={%{}}
                phx-submit="save_search"
                class="flex-1 flex flex-col min-w-0 overflow-y-auto relative"
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
              <%!-- The active category pane is RE-KEYED per category so a swap
               inserts a fresh element and replays the shared
               `wizard-step-enter` entrance keyframe (no JS, no new CSS). The
               wrapper takes the pane's place in the flex row, keeping the
               documented height chain (flex-1 + min-h-0 on a non-scroll item). --%>
              <div
                id={"settings-pane-" <> to_string(@active_category)}
                class="wizard-step-enter flex-1 flex flex-col min-w-0 min-h-0"
              >
                <%= if @active_category == :remote_connections do %>
                  {RemotePanel.remote_connections_panel(assigns)}
                <% else %>
                  <%!-- Custom Agents UI — same design as category_section but for
                 the special :agents pseudo-category. Both editors contain
                 their own <form> elements (save_custom_agent,
                 save_model_selection_script), so they are NOT wrapped in a
                 save_category form (nested <form> elements are invalid
                 HTML). --%>
                  <%= if @active_category == :agents do %>
                    <div
                      class="flex-1 flex flex-col min-w-0 overflow-y-auto"
                      id="category-agents"
                    >
                      <EvoDashWeb.SettingsComponents.SectionHeader.section_header
                        icon="hero-user-group"
                        title={gettext("Agents")}
                        description={
                          gettext(
                            "Create custom agents and configure the per-agent model selection script."
                          )
                        }
                      />

                      <div class="px-8 py-8 space-y-5">
                        <%!-- Note about the separate TOML file --%>
                        <div class="rounded-lg border border-info/30 bg-info/5 p-3 flex items-start gap-3">
                          <.icon
                            name="hero-information-circle"
                            class="size-5 text-info shrink-0 mt-0.5"
                          />
                          <p class="text-sm text-base-content/80">
                            {gettext(
                              "Custom agents are stored in `agents.toml`, next to the main configuration file."
                            )}
                          </p>
                        </div>

                        <%!-- The custom-agent store is loaded ASYNCHRONOUSLY, so a
                       loading placeholder stands in for the editor: rendering
                       the editor's "no custom agents" empty state before the
                       result lands would claim the node has none. --%>
                        <%= if @custom_agents_loading do %>
                          <div
                            id="custom-agents-loading"
                            class="rounded-lg border border-base-200 bg-base-100 p-4"
                            aria-busy="true"
                          >
                            <div class="skeleton h-5 w-40 mb-3"></div>
                            <div class="skeleton h-10 w-full mb-2"></div>
                            <div class="skeleton h-10 w-full"></div>
                          </div>
                        <% else %>
                          <EvoDashWeb.SettingsComponents.CustomAgentsEditor.custom_agents_editor
                            agents={@custom_agents}
                            editing_agent_id={@editing_agent_id}
                            model_profiles={PageState.custom_agent_model_choices(@file_config)}
                            custom_tool_names={
                              EvoDashWeb.SettingsComponents.CustomToolsPanel.custom_tool_names(
                                @custom_tools_status
                              )
                            }
                          />
                        <% end %>

                        <EvoDashWeb.SettingsComponents.CustomToolsPanel.custom_tools_panel
                          status={@custom_tools_status}
                          loading={@custom_tools_loading}
                        />

                        <EvoDashWeb.SettingsComponents.ModelSelectionEditor.model_selection_editor
                          script={@model_selection_script}
                          script_status={@script_status}
                          script_save_error={@script_save_error}
                          test_results={@script_test_results}
                        />
                      </div>
                    </div>
                  <% else %>
                    <%!-- category_section renders its own <form phx-submit="save_category">
               internally. The LLM category's provider-account panel and its
               inline wizards contain their own nested forms
               (save_provider_profile, provider_profile_form_change,
               provider_wizard_change), so they must NOT be wrapped in the
               outer save_category form (nested <form> elements are invalid
               HTML — browsers ignore the inner <form> tag, causing the
               account editor's Save button to submit save_category instead
               of save_provider_profile). --%>
                    <EvoDashWeb.WorkbenchPreferences.panel :if={
                      @live_action == :window and @active_category == :appearance
                    } />
                    <EvoDashWeb.SettingsComponents.category_section
                      :if={@live_action != :window or @active_category != :appearance}
                      category={@active_category}
                      schemas={Map.get(@schemas_by_category, @active_category, [])}
                      file_config={@file_config}
                      errors={Map.get(@per_category_errors, @active_category, [])}
                      sandbox_backend={PageState.sandbox_backend(assigns)}
                      sandbox_mode={get_in(@file_config, [:sandbox, :mode])}
                      provider_wizard={@provider_wizard}
                      provider_schedule={@provider_schedule}
                      llm_test_status={@llm_test_status}
                      provider_profiles={Schema.provider_profiles(@file_config)}
                      model_selections={ConfigIO.model_selections(@file_config)}
                      editing_profile_id={@editing_profile_id}
                      profile_form_draft={@profile_form_draft}
                      provider_profile_errors={@profile_form_errors}
                      profile_advanced_open={@profile_advanced_open}
                      appearance_accent_draft={@appearance_accent_draft}
                      test_profile_id={@test_profile_id}
                      credentials={@credentials}
                      auth_statuses={@auth_statuses}
                      chatgpt_sign_in={@chatgpt_sign_in}
                      chatgpt_sign_in_manual={@chatgpt_sign_in_manual}
                    />
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
    end

    socket =
      socket
      |> assign(PageState.initial_assigns(socket.assigns[:current_node]))
      # Page-owned keys this module reads with `@key`: seeded here so a missing
      # assign can never be silently papered over by an `assigns[:key] || …`
      # read. Values are the ones `PageState.initial_assigns/1` already
      # provides; `assign_new/3` only keeps them present.
      |> assign_new(:platform_os, fn -> :unknown end)
      |> assign_new(:known_schemas_by_category, fn -> %{} end)
      |> assign_new(:auth_status_seq, fn -> 0 end)
      |> assign_new(:chatgpt_sign_in, fn -> ChatGPTSignInState.new() end)
      |> assign_new(:editing_profile_id, fn -> nil end)
      |> assign(
        chatgpt_sign_in: ChatGPTSignInState.new(),
        chatgpt_sign_in_manual: ChatGPTSignInState.manual?(socket.assigns)
      )

    # BOTH custom-agent surfaces load ASYNCHRONOUSLY, and only on the CONNECTED
    # mount: the dead render must never spawn a cross-node RPC and the page has
    # to paint before either answer arrives. The loading flags stay true until
    # the stale-guarded results land (see `AsyncResults.custom_agents_loaded/3`
    # and `AsyncResults.custom_tools_loaded/3`).
    socket =
      if connected?(socket) do
        socket
        |> refresh_custom_agents()
        |> refresh_custom_tools()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Detach save ownership BEFORE replacing the selected target, including
    # aliases that resolve to the same BEAM. NodeAware refreshes remote_status.
    requested_target = if params["node"] in [nil, "local"], do: nil, else: params["node"]
    node_changed? = requested_target != socket.assigns[:current_node_id]

    socket =
      if node_changed?,
        do: PageState.reset_config_scope(socket),
        else: socket

    settings_path =
      if socket.assigns.live_action == :window, do: ~p"/settings/window", else: ~p"/settings"

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(
        current_path: settings_path,
        workbench_reconnect_params: Map.take(params, ["category"]),
        settings_server_form:
          to_form(%{"node" => requested_target || "local"}, as: :settings_server)
      )
      |> PageState.reconcile_config_scope()
      |> sync_sign_in_scope(node_changed?)

    # The sidebar/content map is ALWAYS the last-known PLATFORM-FILTERED map —
    # never the unfiltered snapshot. The platform OS of a (possibly remote) node
    # and its re-filtered map arrive asynchronously in the node-data task below
    # (NodeData); until then the shell renders the LAST-KNOWN filtered nav, so
    # the seeded render advertises exactly what the settled page advertises (no
    # category appears then disappears, and the nav can never shrink to empty).
    socket =
      assign(
        socket,
        :schemas_by_category,
        socket.assigns.known_schemas_by_category
      )

    # The OAuth auth-status assigns must SURVIVE navigation (category switch,
    # push_patch): seed them only when missing, never overwrite a loaded map.
    socket =
      if Map.has_key?(socket.assigns, :auth_statuses) do
        socket
      else
        assign(socket, auth_statuses: %{}, auth_status_seq: 0)
      end

    # Seed the active category against the LAST-KNOWN filtered map: an explicit
    # (and displayable) `?category=` wins immediately with zero flash, an absent
    # / unknown / platform-gated one keeps the category the user is already
    # looking at while it is still displayable, else falls back to the default.
    # The captured param is therefore never able to hide a visible category or
    # rewrite the URL it resolves away from.
    category =
      Navigation.seed(
        params,
        socket.assigns.active_category,
        socket.assigns.schemas_by_category
      )

    socket =
      if category != socket.assigns.active_category do
        assign(socket, :active_category, category)
      else
        socket
      end

    # Tag every load with a generation and full target identity. A save
    # invalidates older snapshots, and category navigation during a write must
    # not race its authoritative receipt. A category-only navigation (our own
    # `select_category` push_patch) is NOT scope-relevant: it neither needs a
    # fresh config read nor may it cancel the load already in flight, so the
    # marker it left behind suppresses the redundant load exactly once.
    {category_patch?, socket} = PageState.consume_category_patch(socket, params)

    socket =
      cond do
        ConfigSave.busy?(socket) -> socket
        category_patch? -> socket
        true -> PageState.start_node_data_load(socket, params["category"])
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({{@node_data_tag, seq, scope}, requested_node, category_param, result}, socket) do
    AsyncResults.node_data_loaded(socket, seq, scope, requested_node, category_param, result)
  end

  # Old node-only responses cannot prove target or generation ownership.
  def handle_info({@node_data_tag, _node, _category, _result}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({{:settings_config_saved, _token, _scope}, _result} = message, socket),
    do: AsyncResults.config_saved(socket, message)

  @impl true
  def handle_info({{:settings_saved_status, token, scope}, result}, socket),
    do: AsyncResults.saved_status_loaded(socket, token, scope, result)

  @impl true
  def handle_info({{:credentials_saved, saved_node, _credential_key}, result}, socket),
    do: AsyncResults.credentials_saved(socket, saved_node, result)

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
      when ref == socket.assigns.config_load_wait_ref,
      do: AsyncResults.config_load_wait_down(socket)

  @impl true
  def handle_info({:custom_agents_loaded, requested_node, result}, socket),
    do: AsyncResults.custom_agents_loaded(socket, requested_node, result)

  @impl true
  def handle_info({:custom_tools_loaded, requested_node, result}, socket),
    do: AsyncResults.custom_tools_loaded(socket, requested_node, result)

  @impl true
  def handle_info({:settings_auth_status_loaded, requested_node, seq, statuses}, socket),
    do: AsyncResults.auth_status_loaded(socket, requested_node, seq, statuses)

  @impl true
  def handle_info({{:llm_test_result, seq, scope}, result}, socket),
    do: AsyncResults.llm_test_result(socket, seq, scope, result)

  # Old/unscoped responses cannot establish which account or node was tested.
  def handle_info({:llm_test_result, _result}, socket), do: {:noreply, socket}

  # The ONE result of the wizard's in-browser ChatGPT sign-in poll (the tag is
  # `EvoDashWeb.LLMSetup.ChatGPTSignIn.result_tag/0`; spelled literally because
  # a pattern cannot call a function). The flow-id stale guard lives with the
  # wizard state it protects.
  @impl true
  def handle_info({:chatgpt_signin_result, flow_id, result}, socket),
    do: ProviderPanelEvents.chatgpt_signin_result(socket, flow_id, result)

  @impl true
  def handle_info({:scheduler_config_updated, node}, socket),
    do: AsyncResults.scheduler_config_updated(socket, node)

  @impl true
  def handle_info({:node_selected, node_id}, socket),
    do: AsyncResults.node_selected(socket, node_id)

  @impl true
  def handle_info({:remote_connection_status, _target_id, _status} = message, socket),
    do: AsyncResults.remote_connection_status(socket, message)

  @impl true
  def handle_info({:remote_connect_result, target_id, {:error, _reason} = error}, socket),
    do: AsyncResults.remote_connect_result(socket, target_id, error)

  @impl true
  def handle_info({:bootstrap_complete, id, result}, socket),
    do: AsyncResults.bootstrap_complete(socket, id, result)

  @impl true
  def handle_info({:task_updated, _task_id, _status, _node} = message, socket),
    do: AsyncResults.task_info(socket, message)

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = message, socket),
    do: AsyncResults.task_info(socket, message)

  @impl true
  def handle_info(:node_aware_reload_tasks, socket), do: AsyncResults.reload_tasks(socket)

  @impl true
  def handle_event("select_category", %{"category" => cat_str}, socket) do
    # Whitelist lookup against the PLATFORM-FILTERED map: a category the viewed
    # node does not have (or an unknown/forged value) is a NO-OP — the current
    # category and the current URL are kept, so a hidden category can never be
    # activated and the highlight can never snap back.
    case Navigation.category_from_param(cat_str, socket.assigns.schemas_by_category) do
      nil ->
        {:noreply, socket}

      cat ->
        socket =
          assign(socket,
            active_category: cat,
            search_text: "",
            per_category_errors: %{},
            # Marker for the handle_params/3 re-run this push_patch causes: the
            # click already chose the category, so that re-entry must not start
            # a second node-data load.
            category_patch: {ConfigSave.scope(socket), to_string(cat)}
          )

        socket =
          if cat == :remote_connections do
            socket
            |> assign(:remote_targets, PageState.safe_list_targets())
            |> assign(:remote_statuses, PageState.safe_connection_statuses())
          else
            socket
          end

        # The URL is the source of truth for the category, so a later
        # handle_params (node switch, connection-status patch, retry) re-reads
        # the SAME category instead of undoing the click.
        target =
          unless socket.assigns.live_action == :window and Navigation.client_category?(cat),
            do: PageState.nav_node(socket)

        {:noreply,
         push_patch(socket,
           to: Navigation.path(cat, %{"node" => target}, socket.assigns.current_path)
         )}
    end
  end

  @impl true
  def handle_event(
        "select_settings_server",
        %{"settings_server" => %{"node" => target}},
        %{assigns: %{live_action: :window} = assigns} = socket
      ) do
    if target == "local" or Enum.any?(assigns.remote_targets, &(&1.id == target)) do
      node = if target != "local", do: target
      to = Navigation.path(assigns.active_category, %{"node" => node}, assigns.current_path)
      {:noreply, push_patch(socket, to: to)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("search", params, socket), do: SearchEvents.handle_search(socket, params)

  # Prevents page reload when pressing Enter in the search form
  @impl true
  def handle_event("noop", params, socket), do: SearchEvents.handle_noop(socket, params)

  # ── Provider-account panel (delegated to ProviderPanelEvents) ──
  #
  # Every event below belongs to the canonical provider-account panel
  # (`SettingsComponents.ProviderProfiles.*`): the FROZEN presentation modules
  # emit this vocabulary and `EvoDashWeb.SettingsLive.ProviderPanelEvents` owns
  # the wizard state machine, the recommended-schedule strip and both save
  # paths. The page only routes.

  @impl true
  def handle_event(event, params, socket)
      when event in [
             "add_provider_profile",
             "provider_wizard_change",
             "provider_wizard_next",
             "provider_wizard_back",
             "provider_wizard_cancel",
             "provider_wizard_save",
             "start_add_provider_model",
             "provider_model_change",
             "provider_model_cancel",
             "provider_model_save",
             "edit_provider_profile",
             "cancel_edit_provider_profile",
             "save_provider_profile",
             "provider_profile_form_change",
             "set_default_provider_profile",
             "delete_provider_profile",
             "add_provider_peak_hours_row",
             "remove_provider_peak_hours_row",
             "apply_provider_schedule",
             "undo_provider_schedule",
             "dismiss_schedule_applied",
             "chatgpt_sign_in",
             "chatgpt_sign_in_cancel"
           ],
      do: ProviderPanelEvents.dispatch(event, params, socket)

  # The model-row buttons are spelled both canonically ("provider") and with
  # the legacy editor names; both act on the expanded account's rows.
  @impl true
  def handle_event(event, params, socket)
      when event in ["add_provider_model", "add_profile_model"],
      do: ProviderPanelEvents.add_provider_model(socket, params)

  @impl true
  def handle_event(event, params, socket)
      when event in ["remove_provider_model", "remove_profile_model"],
      do: ProviderPanelEvents.remove_provider_model(socket, params)

  # Refresh button on the panel's auth-status badges — re-reads the viewed
  # node's OAuth credential state ASYNCHRONOUSLY (a cross-node RPC on remote
  # nodes). Result arrives as `{:settings_auth_status_loaded, node, seq,
  # statuses}`.
  @impl true
  def handle_event("refresh_auth_status", params, socket),
    do: ProviderPanelEvents.refresh_auth_status(socket, params)

  @impl true
  def handle_event("toggle_profile_advanced", params, socket),
    do: ProviderPanelEvents.toggle_profile_advanced(socket, params)

  # ── Legacy provider/model-profile event names ──
  #
  # Kept for the historical profile-editor vocabulary still exercised by the
  # Settings test suites; the rendered provider-account panel uses the
  # canonical names above.
  @impl true
  def handle_event("edit_model_profile", params, socket),
    do: ModelProfileEvents.edit_model_profile(socket, params)

  @impl true
  def handle_event("cancel_edit_model_profile", params, socket),
    do: ModelProfileEvents.cancel_edit_model_profile(socket, params)

  @impl true
  def handle_event("save_model_profile", params, socket),
    do: ModelProfileEvents.save_model_profile(socket, params)

  @impl true
  def handle_event("model_profile_form_change", params, socket),
    do: ModelProfileEvents.model_profile_form_change(socket, params)

  @impl true
  def handle_event("delete_model_profile", params, socket),
    do: ModelProfileEvents.delete_model_profile(socket, params)

  @impl true
  def handle_event("move_model_profile", params, socket),
    do: ModelProfileEvents.move_model_profile(socket, params)

  @impl true
  def handle_event("add_peak_hours_row", params, socket) do
    # Peak-hours row editor is only meaningful while a profile is being edited
    # (the rows live in the editing profile's in-memory peak_hours).
    if socket.assigns.editing_profile_id do
      ModelProfileEvents.add_peak_hours_row(socket, params)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_peak_hours_row", %{"index" => _idx} = params, socket) do
    if socket.assigns.editing_profile_id do
      ModelProfileEvents.remove_peak_hours_row(socket, params)
    else
      {:noreply, socket}
    end
  end

  # ── Custom Agents category events (delegated to CustomAgentEvents) ──

  @impl true
  def handle_event("add_custom_agent", params, socket) do
    CustomAgentEvents.add_custom_agent(socket, params)
  end

  @impl true
  def handle_event("edit_custom_agent", params, socket) do
    CustomAgentEvents.edit_custom_agent(socket, params)
  end

  @impl true
  def handle_event("cancel_edit_custom_agent", params, socket) do
    CustomAgentEvents.cancel_edit_custom_agent(socket, params)
  end

  @impl true
  def handle_event("save_custom_agent", params, socket) do
    CustomAgentEvents.save_custom_agent(socket, params)
  end

  @impl true
  def handle_event("delete_custom_agent", params, socket) do
    CustomAgentEvents.delete_custom_agent(socket, params)
  end

  @impl true
  def handle_event("save_model_selection_script", params, socket) do
    CustomAgentEvents.save_model_selection_script(socket, params)
  end

  @impl true
  def handle_event("test_model_selection_script", params, socket) do
    CustomAgentEvents.test_model_selection_script(socket, params)
  end

  # Refresh button on the Custom Tools panel — re-fetch the custom-tools status
  # for the currently-viewed node ASYNCHRONOUSLY (a cross-node RPC on remote
  # nodes). Result arrives as `{:custom_tools_loaded, node, result}`.
  @impl true
  def handle_event("reload_custom_tools", _params, socket) do
    {:noreply, refresh_custom_tools(socket)}
  end

  # ── Category / generic config events (delegated to CategoryEvents) ──
  @impl true
  def handle_event(event, params, socket) when event in @category_events,
    do: CategoryEvents.handle_event(event, params, socket)

  # ── LLM connection test (delegated to LlmTestEvents) ──
  @impl true
  def handle_event(event, params, socket) when event in @llm_test_events,
    do: LlmTestEvents.handle_event(event, params, socket)

  # ── Remote Connections event handlers (delegated to RemoteEvents) ──
  @impl true
  def handle_event(event, params, socket) when event in @remote_events,
    do: RemoteEvents.handle_event(event, params, socket)

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  # The page's public persistence surface (ModelProfileEvents,
  # ProviderPanelEvents and SearchEvents call it); the write path itself lives
  # in EvoDashWeb.SettingsLive.CategoryEvents.
  @doc false
  def persist_file_config(file_config, socket, success_msg),
    do: CategoryEvents.persist_file_config(file_config, socket, success_msg)

  @doc false
  def persist_file_config(file_config, socket, success_msg, opts) when is_list(opts),
    do: CategoryEvents.persist_file_config(file_config, socket, success_msg, opts)

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Node-aware custom agents + custom tools loading
  # ───────────────────────────────────────────────────────────────────────────

  # Re-fetches the custom-agents data (agent definitions, model-selection
  # script, script compile status) for the currently-viewed node in a
  # SUPERVISED task — never inline in the LiveView process (a cross-node RPC on
  # remote nodes) — then reports back `{:custom_agents_loaded, node, result}`.
  # Non-blocking: the agents editor renders its loading placeholder with
  # `@custom_agents_loading` true until the result lands, and the result handler
  # stale-guards on the node. Called by the connected mount and by the
  # custom-agent mutation flows.
  #
  # `NodeData.fetch_custom_agents/1` is TOTAL: `EvoDash.NodeContext.list_custom_agents/1`
  # already degrades a failure to an empty result, and `EvoDash.SafeCall` inside
  # it additionally covers an EXIT (a dead remote-registry GenServer call exits
  # its caller, which a rescue cannot catch).
  @doc false
  def refresh_custom_agents(socket) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoDashWeb.SettingsLive.NodeData.fetch_custom_agents(node)
      send(parent, {:custom_agents_loaded, node, result})
    end)

    assign(socket, :custom_agents_loading, true)
  end

  # Re-fetches the custom-tools status for the currently-viewed node in a
  # SUPERVISED task — never inline in the LiveView process (a cross-node RPC on
  # remote nodes) — then reports back `{:custom_tools_loaded, node, result}`.
  # Non-blocking: the panel renders with `@custom_tools_loading` true until the
  # result lands. The result handler stale-guards on the node. Called by the
  # panel's Refresh button and by the custom-agent mutation flows.
  @doc false
  def refresh_custom_tools(socket) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoDashWeb.SettingsLive.NodeData.fetch_custom_tools_status(node)
      send(parent, {:custom_tools_loaded, node, result})
    end)

    assign(socket, :custom_tools_loading, true)
  end

  # Fires the ASYNC OAuth/subscription credential-status load for the currently
  # viewed node (see EvoDashWeb.SettingsLive.AuthStatus). Fire-and-forget: the
  # result arrives as `{:settings_auth_status_loaded, node, seq, statuses}` and
  # is stale-guarded by node + seq. `AuthStatus.start/2` is total — it returns
  # `:ok` even when the task supervisor is unavailable — so `:ok =` is a
  # deliberate assertion, not a case.
  #
  # Public because `ProviderPanelEvents.refresh_auth_status/2` (the provider
  # panel's Refresh button) reuses it.
  @doc "Fires the ASYNC OAuth credential-status reload for the viewed node."
  def start_auth_status_load(socket) do
    seq = socket.assigns.auth_status_seq + 1
    socket = assign(socket, :auth_status_seq, seq)
    profiles = Schema.provider_profiles(socket.assigns.file_config || %{})
    :ok = AuthStatus.start(socket, profiles)
    socket
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: page-level in-browser ChatGPT sign-in state
  # ───────────────────────────────────────────────────────────────────────────

  # A node switch changes which BEAM the sign-in would serve: the live flow (a
  # loopback listener on the OLD node's BEAM) is abandoned and the state reset,
  # so a late poll result can never land on the new node's surfaces. The
  # last-known surface identity is kept, so that surface renders its fresh idle
  # button. The local/remote verdict is recomputed on EVERY handle_params, since
  # it depends on the node context `assign_node/2` just resolved.
  defp sync_sign_in_scope(socket, node_changed?) do
    socket =
      if node_changed?,
        do: assign(socket, :chatgpt_sign_in, ChatGPTSignInState.cancel(page_sign_in(socket))),
        else: socket

    assign(socket, :chatgpt_sign_in_manual, ChatGPTSignInState.manual?(socket.assigns))
  end

  # TOTAL: a missing/garbage assign reads as the idle page state.
  defp page_sign_in(socket) do
    case socket.assigns[:chatgpt_sign_in] do
      %{} = state -> state
      _state -> ChatGPTSignInState.new()
    end
  end

  @impl true
  def terminate(_reason, socket) do
    # The poll task already dies with its owner, but the loopback listener lives
    # in the flow module — close it instead of waiting for its timeout.
    _state = ChatGPTSignInState.cancel(page_sign_in(socket))
    :ok
  end
end
