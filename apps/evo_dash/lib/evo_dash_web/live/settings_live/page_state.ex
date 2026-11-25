defmodule EvoDashWeb.SettingsLive.PageState do
  @moduledoc """
  Mount-time page state, config-scope transitions and the node-aware read
  helpers behind `/settings`.

  `SettingsLive.mount/3` assigns exactly the keyword list `initial_assigns/1`
  returns (the pre-existing assign set, unchanged), and the page's config scope
  is owned here: `reset_config_scope/1` detaches config ownership when the
  viewed node/target/connection phase changes, `reconcile_config_scope/1`
  detects such a change and `start_node_data_load/2` spawns the authoritative
  async read (`EvoDashWeb.SettingsLive.NodeData`).

  It also hosts the pure, node-aware read helpers the page and its extracted
  event modules share: `safe_config_status/0`, `safe_list_targets/0`,
  `safe_connection_statuses/0`, `pending_remote_target?/1`,
  `test_config_scope/1`, `target_node/1` — the last two delegating to the ONE
  config-scope derivation in `ConfigSave.scope/1`, so a LOCAL context follows
  `node()` at call time — the `?category=` push_patch marker helpers
  (`nav_node/1`, `consume_category_patch/2`), plus the render-only
  `sandbox_backend/1`, `custom_agent_model_choices/1` and the legacy
  `remote_config_to_file_config/1` adapter.

  Nothing here owns a save, an event vocabulary or any async result: those live
  in `CategoryEvents`, `RemoteEvents`, `LlmTestEvents` and `AsyncResults`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias EvoGit.Config.Schema
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ConfigSave
  alias EvoDashWeb.SettingsLive.LlmTestEvents
  alias EvoDashWeb.SettingsLive.ModelProfileEvents
  alias EvoDashWeb.SettingsLive.NodeData
  alias EvoDashWeb.SettingsLive.ProviderPanelEvents

  # Tag for the async node-data load result message (see
  # EvoDashWeb.SettingsLive.NodeData). Tests that deliver results
  # deterministically must use this same atom.
  @node_data_tag :settings_node_data_loaded

  @doc """
  The tag of the async node-data load result message.

  `SettingsLive.handle_info/2` matches it (via the compile-time attribute) and
  `EvoDashWeb.SettingsLive.NodeData.start/3` sends it back.
  """
  @spec node_data_tag() :: atom()
  def node_data_tag, do: @node_data_tag

  @doc """
  The complete mount-time assign list for the Settings page.

  `current_node` is the assign the socket carries at mount time (nil/local
  unless a node context was already resolved) and is only used for the
  platform-aware schema filtering, exactly as before.
  """
  def initial_assigns(current_node) do
    config_status = safe_config_status()
    config_path = EvoGit.Config.config_path()
    config_file_exists = File.exists?(config_path)
    file_config = ConfigIO.load_file_config()
    schemas_by_category = Schema.schemas_by_category()

    selections = ConfigIO.model_selections(file_config)

    test_profile_id =
      case selections do
        [selection | _] -> EvoDashWeb.SettingsComponents.model_selection_value(selection)
        [] -> nil
      end

    schemas_by_category = Map.put(schemas_by_category, :remote_connections, [])
    schemas_by_category = Map.put(schemas_by_category, :agents, [])

    # Snapshot of the UNFILTERED schemas map (all schema categories plus the
    # two pseudo-categories, BEFORE the platform-OS/nix filtering below). Only
    # the search/save whitelists and the async load's error funnel read it; the
    # RENDERED nav always comes from the filtered map (see below and
    # `SettingsLive.handle_params/3`).
    all_schemas_by_category = schemas_by_category

    # Platform-aware schema filtering: hide the sandbox category (or its
    # Linux-only sub-sections) on platforms where they don't apply. This is
    # BOTH the display mechanism and the save round-trip protection —
    # save_category only processes schemas present in this filtered list, so
    # hidden fields can never clobber saved sandbox config. Mount's own
    # filtering is local-only/cheap (current_node is nil/local at mount time);
    # the per-node filtering for navigations runs in the async task.
    platform_os = EvoDashWeb.PlatformInfo.os_for_node(current_node)

    schemas_by_category =
      EvoDashWeb.PlatformInfo.filter_schemas_by_category(schemas_by_category, platform_os)

    # Hide the Nix category when the nix binary is missing on this node AND
    # the user hasn't explicitly set `[nix] enabled` in the raw config file
    # (an explicit true OR false keeps it visible — the schema default of
    # false alone is not "configured").
    schemas_by_category =
      EvoDashWeb.PlatformInfo.filter_nix_category(schemas_by_category, current_node)

    [
      schemas_by_category: schemas_by_category,
      # The LAST-KNOWN platform-filtered map. It is the ONLY source of the
      # rendered sidebar/content map (`handle_params/3` re-seeds
      # `schemas_by_category` from it, never from the unfiltered snapshot), so
      # the shell can never advertise a platform-gated category and a
      # navigation can never shrink the nav to empty. Refreshed by
      # `AsyncResults.apply_node_data_results/3` (node switches re-filter for
      # the new node).
      known_schemas_by_category: schemas_by_category,
      all_schemas_by_category: all_schemas_by_category,
      platform_os: platform_os,
      active_category: :llm,
      search_text: "",
      per_category_errors: %{},
      scheduler_config: ConfigIO.load_scheduler_config(),
      config_status: config_status,
      file_config: file_config,
      config_path: config_path,
      config_file_exists: config_file_exists,
      # ConfigSave owns these across scope changes, including live workers.
      config_saving: false,
      config_save_request: nil,
      config_save_owner: nil,
      config_load_wait_ref: nil,
      settings_load_seq: 0,
      settings_scope: {nil, node()},
      settings_connection_phase: nil,
      config_loaded_scope: {nil, node()},
      config_status_token: nil,
      credentials: EvoGit.Config.credentials(),
      llm_test_status: :idle,
      llm_test_seq: 0,
      # The mount's config is NOT yet authoritative for the connection test:
      # `file_config` is still the synchronous seed until the node-data snapshot
      # is APPLIED. Only that apply (`LlmTestEvents.assign_test_config/2`, from
      # the node-data result or a save receipt) or `reset_config_scope/1`'s nil
      # installs a scope, so a `test_llm` click arriving earlier is REFUSED with
      # "Wait for this node's configuration to load before testing." instead of
      # starting a test whose result the pending apply would silently discard
      # (it bumps `llm_test_seq`, so the in-flight result no longer matches).
      test_config_scope: nil,
      # Per-profile OAuth/subscription credential status (see
      # EvoDashWeb.SettingsLive.AuthStatus): `%{profile_id => %{state:, expires:,
      # account_id:, login_instructions:, oauth_file:}}`. Loaded
      # asynchronously for the viewed node and stale-guarded by node + seq.
      auth_statuses: %{},
      auth_status_seq: 0,
      editing_profile_id: nil,
      profile_form_draft: nil,
      profile_form_errors: %{},
      profile_save_token: nil,
      # User-authoritative open state of the profile edit form's "Advanced
      # settings" disclosure (nil = follow the auto rule). Reset to nil by
      # every edit-session identity change in ModelProfileEvents.
      profile_advanced_open: nil,
      # `/settings` provider-account panel state (see
      # EvoDashWeb.SettingsLive.ProviderPanelEvents): the add-account /
      # add-model wizard (`nil` when closed) and the expanded account's
      # recommended-schedule strip.
      provider_wizard: nil,
      provider_schedule: ProviderPanelEvents.empty_schedule(),
      # Pending accent-color selection for the :appearance category (nil = no
      # pending draft). Set by `select_appearance_accent`; cleared whenever
      # file_config is replaced by an authoritative load (see
      # apply_node_data_results, save paths, reset_key).
      appearance_accent_draft: nil,
      test_profile_id: test_profile_id,
      # Custom-agents editor state (agent definitions + model-selection script
      # from the node's agents.toml). NEVER read inline: the dead render seeds
      # these empty/degraded defaults with `custom_agents_loading: true` and the
      # CONNECTED mount kicks `SettingsLive.refresh_custom_agents/1`, whose
      # node-stale-guarded result replaces them.
      custom_agents: [],
      model_selection_script: "",
      script_status: :ok,
      custom_agents_loading: true,
      editing_agent_id: nil,
      script_save_error: nil,
      script_test_results: [],
      # Custom-tools panel state (tool modules discovered in the node's
      # `<config_dir>/tools/`). `custom_tools_loading: true` is the panel's
      # LOADING treatment (its Refresh button spins/disabled, no error banner);
      # the connected mount kicks `SettingsLive.refresh_custom_tools/1` and the
      # node-stale-guarded result replaces the status.
      custom_tools_status: %{ok: [], errors: []},
      custom_tools_loading: true,
      remote_config: false,
      remote_config_error: nil,
      bootstrap_progress: %{},
      # Per-target pending-connect markers (id → true) set by
      # connect_remote_target while the async connect is in flight. Cleared
      # by the terminal "remote_connections" broadcast handler (or the
      # {:remote_connect_result, ...} sync-error fallback); doubles as the
      # duplicate-click guard.
      remote_connect_pending: %{},
      bootstrap_restart_confirm: nil,
      remote_targets: safe_list_targets(),
      remote_statuses: safe_connection_statuses(),
      remote_form_target: nil,
      remote_show_advanced: false
    ]
  end

  @doc """
  Detaches config ownership from the previous scope and clears every assign
  that described it.

  Retains ConfigSave's live-worker guard and waits event-driven for an
  invalidated writer before loading another whole-file candidate.
  """
  def reset_config_scope(socket) do
    socket =
      case {socket.assigns[:config_save_owner], socket.assigns[:config_load_wait_ref]} do
        {pid, nil} when is_pid(pid) -> assign(socket, :config_load_wait_ref, Process.monitor(pid))
        _ -> socket
      end

    socket = ConfigSave.invalidate(socket)
    {:noreply, socket} = ModelProfileEvents.cancel_edit_model_profile(socket, %{})

    socket
    |> invalidate_config_load()
    |> LlmTestEvents.invalidate_llm_test()
    |> assign(
      config_loaded_scope: nil,
      file_config: %{},
      test_config_scope: nil,
      test_profile_id: nil,
      config_status: NodeData.degraded_config_status(),
      per_category_errors: %{},
      appearance_accent_draft: nil,
      provider_wizard: nil,
      provider_schedule: ProviderPanelEvents.empty_schedule(),
      auth_statuses: %{},
      auth_status_seq: socket.assigns.auth_status_seq + 1
    )
  end

  @doc """
  Detects a config-scope or connection-phase change and resets the scope when
  one happened, then records the observed scope/phase.
  """
  def reconcile_config_scope(socket) do
    # A LOCAL context's scope follows `node()`, so a runtime distribution
    # start/stop changes it here and resets the page's old-scope state.
    scope = ConfigSave.scope(socket)

    phase =
      if socket.assigns[:current_node_id], do: get_in(socket.assigns, [:remote_status, :phase])

    socket =
      if scope != socket.assigns[:settings_scope] or
           phase != socket.assigns[:settings_connection_phase],
         do: reset_config_scope(socket),
         else: socket

    assign(socket, settings_scope: scope, settings_connection_phase: phase)
  end

  @doc """
  Bumps the load generation and drops the pending config-status token, so an
  older load/save snapshot can never be applied.
  """
  def invalidate_config_load(socket) do
    assign(socket,
      settings_load_seq: (socket.assigns[:settings_load_seq] || 0) + 1,
      config_status_token: nil
    )
  end

  @doc """
  Starts the authoritative async node-data load for the viewed node (unless a
  remote target is still pending, in which case there is nothing truthful to
  load yet).
  """
  def start_node_data_load(socket, category_param) do
    socket = invalidate_config_load(socket)

    unless pending_remote_target?(socket) do
      NodeData.start(
        socket,
        {@node_data_tag, socket.assigns.settings_load_seq, ConfigSave.scope(socket)},
        category_param
      )
    end

    socket
  end

  @doc """
  True while a `?node=` target is requested but not yet connected: NodeAware
  falls back to the local BEAM until then, so every node-scoped read would
  describe the wrong node.
  """
  def pending_remote_target?(socket) do
    # A LOCAL context (`current_node_id == nil`) is never pending, so a stale
    # recorded local atom can never gate a load through this helper.
    not is_nil(socket.assigns[:current_node_id]) and
      (socket.assigns[:current_node] || node()) == node() and
      not match?(%{phase: :connected}, socket.assigns[:remote_status])
  end

  @doc """
  The `{target_id, target_node}` scope a test/config read describes — the save
  scope, from the ONE derivation in `ConfigSave.scope/1`.
  """
  def test_config_scope(socket), do: ConfigSave.scope(socket)

  @doc """
  The node this page's reads and writes are scoped to RIGHT NOW (a LOCAL
  context follows `node()`).
  """
  def target_node(socket) do
    {_target_id, target_node} = ConfigSave.scope(socket)
    target_node
  end

  @doc """
  The `?node=` of the current view (nil for the local context) — carried into
  the `select_category` push_patch so a category click never loses the node.
  """
  def nav_node(socket), do: socket.assigns[:current_node_id]

  @doc """
  Consumes the one-shot marker `select_category` leaves behind.

  `select_category` push_patches the URL itself; `handle_params` then runs for
  the params it produced. That re-entry must not start a second config load
  (nothing scope-relevant changed) and must not re-resolve the category from a
  stale snapshot. The marker is scoped to the socket's config scope and the
  exact category it was minted for, and is consumed exactly once.
  """
  def consume_category_patch(socket, params) do
    case socket.assigns[:category_patch] do
      {scope, category_param} ->
        matched? = scope == ConfigSave.scope(socket) and category_param == params["category"]
        {matched?, assign(socket, :category_patch, nil)}

      _ ->
        {false, socket}
    end
  end

  @doc """
  Local config-completeness status (mount + local saves).

  Exit-safe: the core reads the resolved config / scheduler state, so a dead
  core process would EXIT the caller. The degraded shape (`ok?: false`, no
  warnings) is the conservative fallback — it renders the same "Missing
  Configuration" box the page shows for an unconfigured install, never a false
  "all configured".
  """
  def safe_config_status do
    EvoDash.SafeCall.run(
      fn -> EvoDashWeb.Helpers.config_status() end,
      NodeData.degraded_config_status()
    )
  end

  @doc """
  Saved remote-connection targets (mount + the remote-connections category
  switch). A failing registry read degrades to "no targets".
  """
  def safe_list_targets do
    EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.list_targets() end, [])
  end

  @doc """
  Per-target connection-status map (mount + the remote-connections category
  switch). A failing read degrades to an empty map (every target renders as
  unknown, the pre-existing "no status" rendering).
  """
  def safe_connection_statuses do
    EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.connection_status() end, %{})
  end

  @doc """
  Compatibility adapter for callers holding a legacy FLAT scheduler map.

  Normal navigation and save reconciliation use the FULL resolved file config;
  runtime :model_profiles are converted here, never used as editor rows.
  """
  def remote_config_to_file_config(remote_cfg) when is_map(remote_cfg) do
    scheduler =
      %{}
      |> maybe_put(:default_llm_max_concurrency, remote_cfg[:default_llm_max_concurrency])
      |> maybe_put(:max_tool_concurrency, remote_cfg[:max_tool_concurrency])
      |> maybe_put(:agent_max_retries, remote_cfg[:agent_max_retries])
      |> maybe_put(:max_agent_depth, remote_cfg[:max_agent_depth])
      |> maybe_put(:max_retries, remote_cfg[:max_retries])
      |> maybe_put(:max_turns, remote_cfg[:max_turns])
      |> maybe_put(:max_turns_root, remote_cfg[:max_turns_root])

    llm =
      %{}
      |> maybe_put(:model, remote_cfg[:llm_model])

    # Feed legacy runtime rows through the migration boundary, not the editor.
    llm =
      case remote_cfg[:model_profiles] do
        nil -> llm
        [] -> llm
        profiles -> Map.put(llm, :models, profiles)
      end

    %{}
    |> Map.put(:scheduler, scheduler)
    |> Map.put(:llm, llm)
    |> ConfigIO.canonicalize_file_config()
  end

  def remote_config_to_file_config(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  The sandbox backend banner to show for the currently-viewed node.

  Local node: `scheduler_config[:sandbox_backend]` is accurate (it reflects the
  actual binary availability on this VM). Remote node: `scheduler_config` is
  loaded from the LOCAL scheduler only (`ConfigIO.load_scheduler_config()` at
  mount), so it would show the wrong platform's banner — derive the backend
  from the remote node's detected OS instead.
  """
  def sandbox_backend(assigns) do
    if assigns.current_node in [nil, node()] do
      assigns.scheduler_config[:sandbox_backend]
    else
      EvoDashWeb.PlatformInfo.sandbox_backend_for(assigns.platform_os)
    end
  end

  @doc """
  The custom-agent editor's account-level model choices.

  The custom-agent store still accepts only a provider/legacy id, selecting
  that account's default model. Deduplicate the canonical model inventory by
  account rather than manufacturing unsupported per-model model_id strings.
  """
  def custom_agent_model_choices(config) do
    config
    |> ConfigIO.model_selections()
    |> Enum.uniq_by(& &1.provider_profile_id)
    |> Enum.map(&%{id: &1.provider_profile_id})
  end
end
